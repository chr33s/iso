#!/usr/bin/env python3
"""Measure isolated Swift transport RSS and upstream backpressure on macOS."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def validate(record, offered, direction="response", connections=1):
    progress = "guest_sent" if direction == "upload" else "upstream_sent"
    extra = {"connections", "per_peer_sent"}
    if direction == "upload":
        extra |= {"provider_received_while_stalled", "per_peer_received"}
    assert record["connections"] == connections
    peers = record["per_peer_sent"]
    assert len(peers) == connections
    peer_limit = (8 if direction == "upload" else 16) * 1024 * 1024
    assert all(type(value) is int and 0 < value < peer_limit for value in peers)
    assert sum(peers) == record[progress]
    assert set(record) == {"offered_bytes", "baseline_rss", "peak_rss", "growth_rss",
                           progress, "samples", "plateau_ms", "upstream_closed", "producer_stopped"} | extra
    for key in ["offered_bytes", "baseline_rss", "peak_rss", "growth_rss", progress, "plateau_ms"]:
        assert type(record[key]) is int and record[key] >= 0, key
    assert record["offered_bytes"] == offered
    assert record["baseline_rss"] > 0
    samples = record["samples"]
    assert samples, "no RSS samples"
    previous = 0
    for sample in samples:
        assert set(sample) == {"resident_bytes", progress, "plateau_ms"}
        assert all(type(value) is int and value >= 0 for value in sample.values())
        assert sample[progress] >= previous
        previous = sample[progress]
    assert record["peak_rss"] == max(record["baseline_rss"], *(sample["resident_bytes"] for sample in samples))
    assert record["growth_rss"] == record["peak_rss"] - record["baseline_rss"]
    growth_budget = 256 if connections == 256 else 32
    assert record["growth_rss"] < growth_budget * 1024 * 1024, "excessive RSS growth"
    limit = (8 if direction == "upload" else 16) * 1024 * 1024 * connections
    assert 0 < record[progress] < limit, "unbounded producer progress"
    if direction == "upload":
        assert type(record["provider_received_while_stalled"]) is int
        received = record["per_peer_received"]
        assert len(received) == connections
        assert all(type(value) is int and 0 <= value <= 64 * 1024 for value in received)
        assert sum(received) == record["provider_received_while_stalled"]
    assert record[progress] == samples[-1][progress]
    assert record["plateau_ms"] == samples[-1]["plateau_ms"] >= 3000
    assert record["upstream_closed"] is True and record["producer_stopped"] is True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--direction", choices=["response", "upload", "both"], default="both")
    parser.add_argument("--connections", type=int, choices=[1, 256], default=1,
                        help="number of simultaneous stalled clients")
    args = parser.parse_args()
    work = Path(tempfile.mkdtemp(prefix="coop-memory-backpressure-"))
    print(f"Memory evidence: {work}", flush=True)
    report = []
    workloads = {
        "response": ([256 * 1024 * 1024, 1024 * 1024 * 1024],
                     "slowGuestBoundsResidentMemoryAndUpstreamProgress",
                     "COOP_PROXY_MEMORY_GATE", "COOP_MEMORY_RESPONSE_BYTES", "upstream_sent"),
        "upload": ([16 * 1024 * 1024, 64 * 1024 * 1024],
                   "slowProviderBoundsResidentMemoryAndGuestUploadProgress",
                   "COOP_PROXY_UPLOAD_MEMORY_GATE", "COOP_MEMORY_UPLOAD_BYTES", "guest_sent"),
    }
    for direction, (sizes, test, enabled, size_variable, progress) in workloads.items():
        if args.direction not in [direction, "both"]:
            continue
        for offered in sizes:
            captured = work / f"{direction}-{offered}.json"
            logfile = work / f"{direction}-{offered}.log"
            command = ["swift", "test", "--package-path", "coop-proxy", "--filter", test]
            environment = dict(os.environ, COOP_MEMORY_OBSERVATIONS=str(captured))
            environment.update({enabled: "1", size_variable: str(offered)})
            environment["COOP_MEMORY_CONNECTIONS"] = str(args.connections)
            with logfile.open("w") as log:
                result = subprocess.run(command, cwd=ROOT, env=environment,
                                        stdout=log, stderr=subprocess.STDOUT, timeout=300)
            output = logfile.read_text()
            passed = result.returncode == 0 and f"Test {test}() passed" in output
            report.append({"direction": direction, "offered_bytes": offered, "command": command,
                           "exit_code": result.returncode, "selected_test_passed": passed})
            (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            if not passed:
                raise SystemExit(f"memory gate failed; inspect {work}")
            record = json.loads(captured.read_text())
            validate(record, offered, direction, args.connections)
            print(f"PASS {direction} offered={offered}: RSS growth={record['growth_rss']}, "
                  f"producer sent={record[progress]}", flush=True)


if __name__ == "__main__":
    main()
