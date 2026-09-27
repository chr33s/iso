#!/usr/bin/env python3
"""Compare early upstream disconnects through the Swift production proxy bridge.

Uses verified loopback TLS and synthetic credentials. Local 502 message text is
implementation-specific; preserve it in artifacts and check each exact value.
"""
import itertools
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    work = Path(tempfile.mkdtemp(prefix="coop-upstream-disconnect-"))
    print(f"Disconnect evidence: {work}", flush=True)
    commands = {
        "swift": ["swift", "test", "--package-path", "macos/coop-proxy", "--filter",
                  "upstreamDisconnectClosesGuestAndRestoresPermits"],
    }
    markers = {
        "swift": "Test upstreamDisconnectClosesGuestAndRestoresPermits() passed",
    }
    matrix = list(itertools.product(
        ["anthropic", "openai"], ["beforeHeaders", "duringBody"],
        ["abruptTCP", "cleanTLS"], range(2)))
    expected_ids = {f"{provider}-{phase}-{closure}-{round_}"
                    for provider, phase, closure, round_ in matrix}
    report = {}
    normalized = {}
    for implementation, command in commands.items():
        artifact = work / f"{implementation}-observations.json"
        with (work / f"{implementation}.log").open("w") as log:
            result = subprocess.run(
                command, cwd=ROOT,
                env=dict(os.environ, COOP_DISCONNECT_OBSERVATIONS=str(artifact)),
                stdout=log, stderr=subprocess.STDOUT, timeout=180)
        output = (work / f"{implementation}.log").read_text()
        report[implementation] = {"command": command, "exit_code": result.returncode}
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        assert result.returncode == 0 and markers[implementation] in output, work
        records = json.loads(artifact.read_text())
        assert len(records) == len(matrix), records
        assert {record["id"] for record in records} == expected_ids, records
        normalized[implementation] = {}
        for record in records:
            before_headers = "-beforeHeaders-" in record["id"]
            local_message = ""
            assert record == {
                "id": record["id"], "response_status": 502 if before_headers else 200,
                "response_body": local_message if before_headers else "part",
                "connection_closed": True, "connection_slots": 1, "request_slots": 1,
            }, record
            comparable = dict(record)
            if before_headers:
                comparable.pop("response_body")
            normalized[implementation][record["id"]] = comparable
        print(f"PASS {implementation}: {len(records)} disconnect exchanges", flush=True)
    (work / "comparison.json").write_text(json.dumps(normalized, indent=2) + "\n")
    print("PASS status, partial body, guest EOF and capacity recovery validated", flush=True)


if __name__ == "__main__":
    main()
