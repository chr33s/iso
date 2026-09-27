#!/usr/bin/env python3
"""Run the shared forwarding and TLS-failure corpus through local fixtures.

Requires macOS, Swift, Python 3 and OpenSSL. All credentials are synthetic;
provider traffic is redirected to test-only loopback listeners with verified TLS.
Records and validates observed forwarding behavior for the shared admitted cases.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "tests/fixtures/credential-proxy/forwarding.json"


def normalize(records):
    result = {}
    for item in records:
        record = dict(item)
        record.pop("elapsed_ms", None)  # Timing is checked against corpus bounds below.
        for key in ["request_body", "response_body"]:
            if key in record:
                record[key + "_sha256"] = hashlib.sha256(bytes(record.pop(key))).hexdigest()
        for key in ["request_headers", "response_headers"]:
            if key in record:
                record[key] = sorted([name.lower(), value] for name, value in record[key])
        result[record.pop("id")] = record
    return result


def save_observations(observations, destination):
    destination.write_text(json.dumps(observations, indent=2) + "\n")


def main():
    work = Path(tempfile.mkdtemp(prefix="coop-forwarding-corpus-"))
    print(f"Corpus evidence: {work}", flush=True)
    cases = json.loads(CORPUS.read_text())
    assert cases and len({case["id"] for case in cases}) == len(cases)
    commands = {
        "swift": ["swift", "test", "--package-path", "coop-proxy", "--filter",
                  "sharedForwardingCorpusThroughTLS"],
    }
    required = {
        "swift": "Test sharedForwardingCorpusThroughTLS() passed",
    }
    report = {"corpus_sha256": hashlib.sha256(CORPUS.read_bytes()).hexdigest(),
              "cases": [case["id"] for case in cases], "implementations": {}}
    observations = {}
    for implementation, command in commands.items():
        captured = work / f"{implementation}-observations.json"
        environment = dict(os.environ, COOP_FORWARD_OBSERVATIONS=str(captured))
        with (work / f"{implementation}.log").open("w") as log:
            result = subprocess.run(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)
        output = (work / f"{implementation}.log").read_text()
        passed = result.returncode == 0 and required[implementation] in output
        report["implementations"][implementation] = {"command": command,
            "exit_code": result.returncode, "passed": passed}
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        if not passed:
            raise SystemExit(f"{implementation} corpus failed; inspect {work}")
        raw = json.loads(captured.read_text())
        assert sorted(item["id"] for item in raw) == sorted(case["id"] for case in cases)
        by_id = {case["id"]: case for case in cases}
        for item in raw:
            expected = {"id", "upstream_count", "response_status", "connection_closed"}
            if not by_id[item["id"]].get("establishment_failure", False):
                expected |= {"method", "path", "request_headers", "request_body",
                             "response_headers", "response_body"}
            if by_id[item["id"]].get("stall_handshake", False):
                expected |= {"elapsed_ms", "upstream_closed"}
                case = by_id[item["id"]]
                assert case["minimum_elapsed_ms"] <= item["elapsed_ms"] <= case["maximum_elapsed_ms"], item
                assert item["upstream_closed"], item
            assert set(item) == expected, f"incomplete observation: {item['id']}"
        observations[implementation] = normalize(raw)
        print(f"PASS {implementation}: {len(cases)} forwarding/TLS cases", flush=True)
    save_observations(observations, work / "comparison.json")
    print("PASS observed forwarding validated for every case", flush=True)


if __name__ == "__main__":
    main()
