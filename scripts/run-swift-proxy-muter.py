#!/usr/bin/env python3
"""Run Muter on the spec's four policy files in a disposable package copy.

Supply a Muter executable built from the patched revision in docs/testing.md. Artifacts
are retained for survivor review. Build failures/timeouts/runtime failures are
reported separately and never silently counted as assertion-killed mutants.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "macos/coop-proxy"
FILES = ["Capability.swift", "OperationPolicy.swift", "HeaderPolicy.swift", "RequestTarget.swift"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--muter", required=True, type=Path)
    args = parser.parse_args()
    tool = args.muter.resolve(strict=True)
    work = Path(tempfile.mkdtemp(prefix="coop-proxy-muter-"))
    package = work / "package"
    shutil.copytree(PACKAGE, package, ignore=shutil.ignore_patterns(".build", ".swiftpm", "muter_tmp"))
    hashes = {name: hashlib.sha256((package / "Sources/CoopProxyCore" / name).read_bytes()).hexdigest()
              for name in FILES}
    (work / "source-sha256.json").write_text(json.dumps(hashes, indent=2) + "\n")
    (work / "tool-sha256.txt").write_text(hashlib.sha256(tool.read_bytes()).hexdigest() + "\n")
    print(f"Mutation artifacts: {work}", flush=True)
    report = work / "report.json"
    command = [str(tool), "run", "--skip-update-check", "--skip-coverage", "--format", "json",
               "--output", str(report)]
    for name in FILES:
        command.extend(["--files-to-mutate", "Sources/CoopProxyCore/" + name])
    with (work / "run.log").open("w") as log:
        result = subprocess.run(command, cwd=package, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode or not report.is_file():
        raise SystemExit(f"Muter failed or produced no report; inspect {work / 'run.log'}")
    data = json.loads(report.read_text())
    counts = Counter()
    found = set()
    for file in data["fileReports"]:
        found.add(file["fileName"])
        instrumented = work / "package_mutated/Sources/CoopProxyCore" / file["fileName"]
        switches = instrumented.read_text().count("ProcessInfo.processInfo.environment[")
        if switches != len(file["appliedOperators"]):
            raise SystemExit(f"Mutation instrumentation mismatch for {file['fileName']}: "
                             f"{switches} switches for {len(file['appliedOperators'])} mutants")
        outcomes = Counter(item["testSuiteOutcome"] for item in file["appliedOperators"])
        counts.update(outcomes)
        print(file["fileName"] + ": " + json.dumps(dict(outcomes), sort_keys=True))
    if found != set(FILES) or not counts:
        raise SystemExit("Mutation report does not cover all four required policy files")
    print("Outcomes: " + json.dumps(dict(counts), sort_keys=True))
    if any(outcome != "failed" and count for outcome, count in counts.items()):
        raise SystemExit(f"Mutation survivors or non-assertion outcomes require review: {report}")
    print("All generated mutants were killed by test assertions.")


if __name__ == "__main__":
    main()
