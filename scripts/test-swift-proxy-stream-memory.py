#!/usr/bin/env python3
"""Measure isolated RSS for 256 held TLS streams, including refill and cleanup."""
import json
import os
from pathlib import Path
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEST = "heldTLSStreamsBoundAggregateResidentMemory"
MEMORY_FIELDS = {"baseline_rss", "rss_samples", "peak_rss", "growth_rss", "growth_after_first_round"}


def validate(records):
    capacity = [{key: value for key, value in record.items() if key not in MEMORY_FIELDS}
                for record in records]
    runpy.run_path(str(ROOT / "scripts/test-proxy-stream-capacity.py"))["validate"](capacity)
    first_peaks = {}
    baselines = {}
    for record in sorted(records, key=lambda item: (item["provider"], item["round"])):
        samples = record["rss_samples"]
        assert len(samples) >= (200 if record["termination"] == "complete" else 2)
        assert all(type(value) is int and value > 0 for value in samples)
        for field in MEMORY_FIELDS - {"rss_samples"}:
            assert type(record[field]) is int and record[field] >= 0
        baseline = record["baseline_rss"]
        assert baseline > 0
        peak = max(baseline, *samples)
        provider = record["provider"]
        if record["round"] == 0:
            first_peaks[provider] = peak
            baselines[provider] = baseline
        assert baseline == baselines[provider]
        assert record["peak_rss"] == peak
        assert record["growth_rss"] == peak - baseline < 256 * 1024 * 1024
        assert record["growth_after_first_round"] == max(0, peak - first_peaks[provider]) < 64 * 1024 * 1024


def main():
    work = Path(tempfile.mkdtemp(prefix="coop-stream-memory-"))
    print(f"Stream memory evidence: {work}", flush=True)
    captured = work / "observations.json"
    logfile = work / "swift.log"
    command = ["swift", "test", "--package-path", "coop-proxy", "--filter", TEST]
    with logfile.open("w") as log:
        result = subprocess.run(command, cwd=ROOT,
            env=dict(os.environ, COOP_PROXY_STREAM_MEMORY_GATE="1", COOP_STREAM_OBSERVATIONS=str(captured)),
            stdout=log, stderr=subprocess.STDOUT, timeout=300)
    passed = result.returncode == 0 and f"Test {TEST}() passed" in logfile.read_text()
    (work / "report.json").write_text(json.dumps({
        "command": command, "exit_code": result.returncode, "selected_test_passed": passed,
    }, indent=2) + "\n")
    assert passed, f"stream memory gate failed; inspect {work}"
    records = json.loads(captured.read_text())
    validate(records)
    for record in records:
        print(f"PASS {record['provider']} round {record['round']}: "
              f"RSS growth={record['growth_rss']}, "
              f"growth after first round={record['growth_after_first_round']}", flush=True)


if __name__ == "__main__":
    main()
