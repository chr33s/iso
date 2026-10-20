#!/usr/bin/env python3
"""Install a NET-HANDOFF-1 evidence manifest for this host's service.

The host advertises `net-handoff-1` through `host.capabilities` only while a
manifest under its host-control root names the running tuple, every
release-blocking brokered test (N-T01..N-T16) passed, and the evidence has not
expired. This script turns a results file from a qualification run into that
manifest and refuses incomplete results; it never edits a test outcome.

Results file (JSON):

  {
    "tuple": {
      "host_os": "27.0.0", "iso_version": "0.6.0",
      "runtime": "iso-sandbox 0.6.0 (containerization 0.45.0, protocol 5)",
      "transport": "brokered", "image": "default@sha256:<image manifest digest hex>",
      "guest_kernel": "<kernel identity>", "broker": "iso-egress 0.6.0"
    },
    "tests": {"N-T01": "passed", ..., "N-T16": "passed"},
    "evidence": "optional reference to the run log or report"
  }

See docs/design/brokered-network-isolation.md (NET-HANDOFF-1) and
docs/remote-hosts.md.
"""

import argparse
import json
import os
import re
import sys
import tempfile
import time
from pathlib import Path

SCHEMA = "iso.qualification/v1"
CAPABILITY = "NET-HANDOFF-1"
TUPLE_KEYS = ["host_os", "iso_version", "runtime", "transport", "image", "guest_kernel", "broker"]
REQUIRED_TESTS = [f"N-T{n:02d}" for n in range(1, 17)]
BACKEND_ROOT = "backends/apple-container-v1"
MAX_VALID_DAYS = 365


def refuse(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(2)


def manifest(results, now, valid_days):
    if not isinstance(results, dict):
        refuse("the results file must be a JSON object")
    unknown = set(results) - {"tuple", "tests", "evidence"}
    if unknown:
        refuse(f"unknown results fields: {', '.join(sorted(unknown))}")
    tuple_ = results.get("tuple")
    tests = results.get("tests")
    if not isinstance(tuple_, dict) or not isinstance(tests, dict):
        refuse("results need a `tuple` object and a `tests` object")
    if set(tuple_) != set(TUPLE_KEYS):
        refuse(f"tuple must name exactly: {', '.join(TUPLE_KEYS)}")
    for key, value in tuple_.items():
        if not isinstance(value, str) or not 1 <= len(value.encode()) <= 256:
            refuse(f"tuple.{key} must be a 1-256 byte string")
    if tuple_["transport"] != "brokered":
        refuse("tuple.transport must be brokered")
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}@sha256:[0-9a-f]{64}", tuple_["image"]):
        refuse("tuple.image must be <image name>@sha256:<64 lowercase hex>")
    if set(tests) != set(REQUIRED_TESTS):
        refuse(f"tests must name exactly {REQUIRED_TESTS[0]}..{REQUIRED_TESTS[-1]}")
    failing = [test for test in REQUIRED_TESTS if tests[test] != "passed"]
    if failing:
        refuse(f"not passed: {', '.join(failing)}; skipped or unavailable cases are blocked")
    document = {
        "schema": SCHEMA,
        "capability": CAPABILITY,
        "recorded_at": now,
        "expires_at": now + valid_days * 86_400,
        "tuple": tuple_,
        "tests": tests,
    }
    evidence = results.get("evidence")
    if evidence is not None:
        if not isinstance(evidence, str) or len(evidence.encode()) > 1_024:
            refuse("evidence must be a string of at most 1024 bytes")
        document["evidence"] = evidence
    return document


def install(document, path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    fd, scratch = tempfile.mkstemp(dir=path.parent, prefix=".net-handoff-")
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(document, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(scratch, 0o600)
        os.replace(scratch, path)
    except BaseException:
        os.unlink(scratch)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--results", required=True, type=Path, help="qualification results JSON")
    parser.add_argument(
        "--data-dir", type=Path, default=Path.home() / ".iso",
        help="the host's iso data_dir (default: ~/.iso)")
    parser.add_argument(
        "--valid-days", type=int, default=90,
        help=f"days until the evidence expires (1-{MAX_VALID_DAYS}, default 90)")
    parser.add_argument("--dry-run", action="store_true", help="print the manifest, do not install")
    args = parser.parse_args()
    if not 1 <= args.valid_days <= MAX_VALID_DAYS:
        refuse(f"--valid-days must be 1-{MAX_VALID_DAYS}")
    try:
        results = json.loads(args.results.read_text(), object_pairs_hook=reject_duplicates)
    except (OSError, ValueError) as error:
        refuse(f"cannot read {args.results}: {error}")
    document = manifest(results, int(time.time()), args.valid_days)
    if args.dry_run:
        json.dump(document, sys.stdout, indent=2, sort_keys=True)
        print()
        return
    target = args.data_dir / BACKEND_ROOT / "host-control" / "qualification" / "net-handoff-1.json"
    install(document, target)
    print(f"Installed {target}; expires in {args.valid_days} days.", file=sys.stderr)


def reject_duplicates(pairs):
    keys = [key for key, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)


if __name__ == "__main__":
    main()
