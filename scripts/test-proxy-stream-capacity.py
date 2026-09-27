#!/usr/bin/env python3
"""Validate real Swift TLS stream admission and cleanup on macOS.

Runs both providers through disconnect/completion/disconnect rounds, each with
256 held streams and an excess authenticated request. Uses synthetic secrets
and temporary test trust anchors without modifying host trust.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def validate(records):
    expected = {}
    for provider in ["anthropic", "openai"]:
        for round_number, termination in enumerate(["disconnect", "complete", "disconnect"]):
            expected[(provider, round_number)] = {
                "provider": provider, "round": round_number, "termination": termination,
                "held_responses": 256, "upstream_requests": 256, "upstream_closed": 256,
                "excess_response_bytes": 0,
                "completed_responses": 256 if termination == "complete" else 0,
            }
    assert len(records) == len(expected), "missing or duplicate capacity rounds"
    actual = {}
    for captured in records:
        record = dict(captured)
        duration = record.pop("held_duration_ms")
        assert type(duration) is int, "invalid hold duration"
        if record["termination"] == "complete":
            assert 31000 <= duration <= 36000, f"invalid long-response duration: {duration}"
        else:
            assert duration == 0, "unexpected disconnect hold"
        for field in ["round", "held_responses", "upstream_requests", "upstream_closed",
                      "excess_response_bytes", "completed_responses"]:
            assert type(record[field]) is int, f"invalid observation type: {field}"
        key = (record["provider"], record["round"])
        assert key not in actual, f"duplicate round: {key}"
        assert record == expected[key], f"capacity contract mismatch: {record}"
        actual[key] = record
    assert set(actual) == set(expected), "incomplete capacity corpus"
    return [actual[key] for key in sorted(actual)]


def main():
    work = Path(tempfile.mkdtemp(prefix="coop-stream-capacity-"))
    print(f"Capacity evidence: {work}", flush=True)
    commands = {
        "swift": ["swift", "test", "--package-path", "coop-proxy", "--filter",
                  "realTLSStreamsHold256SlotsUntilCompletionOrDisconnect"],
    }
    markers = {"swift": "Test realTLSStreamsHold256SlotsUntilCompletionOrDisconnect() passed"}
    observations = {}
    report = {}
    for implementation, command in commands.items():
        captured = work / f"{implementation}-observations.json"
        with (work / f"{implementation}.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT,
                env=dict(os.environ, COOP_STREAM_OBSERVATIONS=str(captured)),
                stdout=log, stderr=subprocess.STDOUT)
        output = (work / f"{implementation}.log").read_text()
        passed = result.returncode == 0 and markers[implementation] in output
        report[implementation] = {"command": command, "exit_code": result.returncode,
                                  "selected_test_passed": passed}
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        if not passed:
            raise SystemExit(f"{implementation} capacity test failed; inspect {work}")
        observations[implementation] = validate(json.loads(captured.read_text()))
        print(f"PASS {implementation}: six stream-capacity rounds", flush=True)
    (work / "comparison.json").write_text(json.dumps(observations, indent=2) + "\n")
    print("PASS observed stream capacity and cleanup validated", flush=True)


if __name__ == "__main__":
    main()
