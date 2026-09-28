#!/usr/bin/env python3
"""Compare body framing, declared limits, streaming and SHA-256 through the Swift TLS proxy."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def validate(records):
    cap = 64 * 1024 * 1024
    digest = "98dc891b284e4d84ac25b0c0a24fdbe39a7f0dbd643ad5e8aa06e02fc6258254"
    expected = {}
    for provider in ["anthropic", "openai"]:
        for declared in [cap, cap + 1, None]:
            count = int(declared == cap)
            expected[(provider, declared)] = {
                "provider": provider, "declared_bytes": declared, "status": 411 if declared is None else (200 if count else 413),
                "upstream_connections": count, "upstream_requests": count,
                "upstream_body_bytes": cap if count else 0, "upstream_sha256": digest if count else None,
                "upstream_closed": count, "guest_closed": True,
            }
    assert len(records) == len(expected), "missing or duplicate boundary cases"
    actual = {}
    for record in records:
        assert record["declared_bytes"] is None or type(record["declared_bytes"]) is int
        for field in ["status", "upstream_connections", "upstream_requests",
                      "upstream_body_bytes", "upstream_closed"]:
            assert type(record[field]) is int, f"invalid observation type: {field}"
        assert type(record["guest_closed"]) is bool
        key = (record["provider"], record["declared_bytes"])
        assert key in expected and key not in actual, f"unexpected/duplicate case: {key}"
        assert record == expected[key], f"body-limit contract mismatch: {record}"
        actual[key] = record
    return [actual[key] for key in sorted(actual, key=lambda key: (key[0], key[1] or 0))]


def main():
    work = Path(tempfile.mkdtemp(prefix="coop-body-limit-"))
    print(f"Body-limit evidence: {work}", flush=True)
    commands = {
        "swift": ["swift", "test", "--package-path", "coop-proxy", "--filter",
                  "realTLSDeclaredBodyLimitAcceptsExactAndRefusesExcess"],
    }
    markers = {"swift": "Test realTLSDeclaredBodyLimitAcceptsExactAndRefusesExcess() passed"}
    observations = {}
    report = {}
    for implementation, command in commands.items():
        captured = work / f"{implementation}-observations.json"
        with (work / f"{implementation}.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT,
                env=dict(os.environ, COOP_BODY_LIMIT_OBSERVATIONS=str(captured)),
                stdout=log, stderr=subprocess.STDOUT)
        output = (work / f"{implementation}.log").read_text()
        passed = result.returncode == 0 and markers[implementation] in output
        report[implementation] = {"command": command, "exit_code": result.returncode,
                                  "selected_test_passed": passed}
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        if not passed:
            raise SystemExit(f"{implementation} body-limit test failed; inspect {work}")
        observations[implementation] = validate(json.loads(captured.read_text()))
        print(f"PASS {implementation}: six provider/framing boundary cases", flush=True)
    (work / "comparison.json").write_text(json.dumps(observations, indent=2) + "\n")
    print("PASS body-limit observations validated", flush=True)


if __name__ == "__main__":
    main()
