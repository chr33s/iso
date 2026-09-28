#!/usr/bin/env python3
"""H-02 flag surface: every baseline command path and option exists in the Swift CLI.

    python3 tests/test-swift-host-cli-surface.py --swift .build/debug/coop

Reads tests/fixtures/baseline-cli/commands.json (captured from the Rust
host) and, for each command path, parses `coop <path> --help` from the
Swift host. Differences must be listed in ALLOWED with the decision that
permits them; anything else fails.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (command path, option) -> reason. "*" as the path applies everywhere.
ALLOWED_MISSING = {
    ("*", "-V --version"): "Argument Parser offers --version on the root only",
}
ALLOWED_EXTRA = {
    ("*", "--version"): "Argument Parser adds --version to every subcommand",
    ("*", "--config"): "global option accepted after the subcommand (baseline: global=true)",
    ("*", "-v --verbose"): "global option accepted after the subcommand (baseline: global=true)",
    ("setup", "--config-only"): "C-03: config creation moved from `init` into setup",
    ("pull", "--review"): "selective-hardening spec §5: staged workspace return",
    ("pull", "--apply"): "selective-hardening spec §5: staged workspace return",
    ("pull", "--discard"): "selective-hardening spec §5: staged workspace return",
    ("pull", "--stage-id"): "selective-hardening spec §5: staged workspace return",
    ("pull", "--stat"): "selective-hardening spec §5: staged workspace return",
}
ALLOWED_MISSING_COMMANDS = {
    "quickstart": "C-03: hidden; fails with the setup/up/claude-or-codex replacement",
}


def swift_options(binary, path):
    argv = [binary] + (path.split() if path != "coop" else []) + ["--help"]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        return None
    options = set()
    in_options = False
    for line in result.stdout.splitlines():
        if line.startswith("OPTIONS:"):
            in_options = True
            continue
        if in_options and line and not line.startswith(" "):
            in_options = False
        if not in_options:
            continue
        match = re.match(r"^  (-\w)?(?:, )?(--[\w-]+)?", line)
        if not match or not (match.group(1) or match.group(2)):
            continue
        options.add(" ".join(x for x in match.groups() if x))
    return options


def allowed(table, path, option):
    return (path, option) in table or ("*", option) in table


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--swift", required=True)
    args = parser.parse_args()
    baseline = json.loads((ROOT / "tests/fixtures/baseline-cli/commands.json").read_text())["commands"]
    failures = 0
    for path, spec in baseline.items():
        if path in ALLOWED_MISSING_COMMANDS:
            continue
        got = swift_options(args.swift, path)
        if got is None:
            print(f"FAIL  {path}: missing in the Swift CLI")
            failures += 1
            continue
        want = set(spec["options"])
        missing = sorted(o for o in want - got if not allowed(ALLOWED_MISSING, path, o))
        extra = sorted(o for o in got - want if not allowed(ALLOWED_EXTRA, path, o))
        if missing or extra:
            failures += 1
            print(f"FAIL  {path}: missing {missing} extra {extra}")
        else:
            print(f"ok    {path}")
    total = len(baseline) - len(ALLOWED_MISSING_COMMANDS)
    print(f"\n{total - failures}/{total} command paths match")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
