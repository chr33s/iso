#!/usr/bin/env python3
"""Measure isolated Swift RSS under repeated 256-client partial/malformed headers."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEST = "concurrentPartialAndMalformedHeadersBoundResidentMemory"


def validate(record, rounds):
    assert set(record) == {
        "rounds", "connections_per_round", "partial_bytes_per_connection", "baseline_rss",
        "peak_rss", "growth_rss", "growth_after_first_round", "samples", "refusals",
        "excess_closed", "forwarded_parts",
    }
    assert all(type(value) is int and value >= 0 for key, value in record.items() if key != "samples")
    assert record["rounds"] == rounds and record["connections_per_round"] == 256
    assert 48 * 1024 <= record["partial_bytes_per_connection"] < 64 * 1024
    assert record["refusals"] == rounds * 256
    assert record["excess_closed"] == rounds and record["forwarded_parts"] == 0
    samples = record["samples"]
    assert len(samples) == rounds * 4
    for index, sample in enumerate(samples):
        assert set(sample) == {"round", "resident_bytes"}
        assert type(sample["round"]) is int and sample["round"] == index // 4
        assert type(sample["resident_bytes"]) is int and sample["resident_bytes"] > 0
    peak = max(record["baseline_rss"], *(sample["resident_bytes"] for sample in samples))
    first_peak = max(sample["resident_bytes"] for sample in samples[:4])
    assert record["baseline_rss"] > 0 and record["peak_rss"] == peak
    assert record["growth_rss"] == peak - record["baseline_rss"] < 96 * 1024 * 1024
    assert record["growth_after_first_round"] == max(0, peak - first_peak) < 32 * 1024 * 1024


def main():
    work = Path(tempfile.mkdtemp(prefix="coop-aggregate-memory-"))
    print(f"Aggregate memory evidence: {work}", flush=True)
    report = []
    for rounds in [2, 8]:
        captured = work / f"{rounds}.json"
        logfile = work / f"{rounds}.log"
        command = ["swift", "test", "--package-path", "macos/coop-proxy", "--filter", TEST]
        environment = dict(os.environ, COOP_PROXY_AGGREGATE_MEMORY_GATE="1",
                           COOP_MEMORY_ROUNDS=str(rounds), COOP_MEMORY_OBSERVATIONS=str(captured))
        with logfile.open("w") as log:
            result = subprocess.run(command, cwd=ROOT, env=environment,
                                    stdout=log, stderr=subprocess.STDOUT, timeout=300)
        passed = result.returncode == 0 and f"Test {TEST}() passed" in logfile.read_text()
        report.append({"rounds": rounds, "command": command, "exit_code": result.returncode,
                       "selected_test_passed": passed})
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        assert passed, f"aggregate memory gate failed; inspect {work}"
        record = json.loads(captured.read_text())
        validate(record, rounds)
        print(f"PASS {rounds} rounds: RSS growth={record['growth_rss']}, "
              f"growth after first round={record['growth_after_first_round']}", flush=True)


if __name__ == "__main__":
    main()
