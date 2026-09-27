#!/usr/bin/env python3
"""Validate Swift partial-upload idle timeout and TLS cleanup."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def validate(records):
    assert len(records) == 2, "expected both providers"
    actual = {}
    for captured in records:
        record = dict(captured)
        elapsed = record.pop("elapsed_ms")
        assert type(elapsed) is int and 44000 <= elapsed <= 51000, "body idle deadline failed to reset"
        provider = record["provider"]
        assert provider in ["anthropic", "openai"] and provider not in actual
        assert type(record["status"]) is int
        for field in ["upload_complete", "guest_closed", "upstream_closed"]:
            assert type(record[field]) is bool, f"invalid observation type: {field}"
        assert all(type(byte) is int for byte in record["upstream_body"])
        assert record == {"provider": provider, "status": 408, "upstream_body": [97, 98],
                          "upload_complete": False, "guest_closed": True, "upstream_closed": True}, record
        actual[provider] = record
    return actual


def main():
    work = Path(tempfile.mkdtemp(prefix="coop-body-idle-"))
    print(f"Body-idle evidence: {work}", flush=True)
    commands = {
        "swift": ["swift", "test", "--package-path", "coop-proxy", "--filter",
                  "realTLSUploadIdleDeadlineResetsAndCancelsUpstream"],
    }
    markers = {"swift": "Test realTLSUploadIdleDeadlineResetsAndCancelsUpstream() passed"}
    observations = {}
    report = {}
    for implementation, command in commands.items():
        captured = work / f"{implementation}-observations.json"
        with (work / f"{implementation}.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT,
                env=dict(os.environ, COOP_IDLE_OBSERVATIONS=str(captured)),
                stdout=log, stderr=subprocess.STDOUT)
        output = (work / f"{implementation}.log").read_text()
        passed = result.returncode == 0 and markers[implementation] in output
        report[implementation] = {"command": command, "exit_code": result.returncode,
                                  "selected_test_passed": passed}
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        if not passed:
            raise SystemExit(f"{implementation} body-idle test failed; inspect {work}")
        observations[implementation] = validate(json.loads(captured.read_text()))
        print(f"PASS {implementation}: both provider body-idle cases", flush=True)
    (work / "comparison.json").write_text(json.dumps(observations, indent=2) + "\n")
    print("PASS body-idle observations validated", flush=True)


if __name__ == "__main__":
    main()
