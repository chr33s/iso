#!/usr/bin/env python3
"""Exercise every registered CLI help path and required public command families."""

import argparse
import json
import os
import subprocess
import sys

REQUIRED = {
    "setup", "up", "start", "shell", "exec", "stop", "destroy", "list", "status", "logs",
    "claude", "codex", "agent", "run", "run-cleanup", "images", "diff", "audit", "secrets",
    "github", "proxy", "profiles", "devcontainer", "update", "uninstall", "validate", "completions",
    "capabilities", "ssh-config",
}


def commands(command, prefix=()):
    path = prefix + (command["commandName"],) if prefix or command["commandName"] != "iso" else ()
    yield path, command
    for child in command.get("subcommands", []):
        yield from commands(child, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True)
    binary = os.path.abspath(parser.parse_args().swift)
    tree = json.loads(subprocess.check_output([binary, "--experimental-dump-help"], text=True, timeout=60))["command"]
    public = {child["commandName"] for child in tree["subcommands"] if child.get("shouldDisplay", True)}
    failures = []
    if REQUIRED - public:
        failures.append(f"missing required command families: {sorted(REQUIRED - public)}")
    paths = list(commands(tree))
    for path, command in paths:
        result = subprocess.run([binary, *path, "--help"], capture_output=True, text=True, timeout=60)
        label = " ".join(("iso", *path))
        if result.returncode or "USAGE:" not in result.stdout or result.stderr:
            failures.append(f"{label}: help failed: {result.returncode} {result.stderr}")
        names = {name["name"] for argument in command.get("arguments", []) for name in argument.get("names", [])}
        if "no-claude" in names:
            failures.append(f"{label}: deprecated agent flag remains")
    for removed in ["init", "quickstart"]:
        result = subprocess.run([binary, removed], capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            failures.append(f"removed command {removed} remains registered")
    for failure in failures:
        print("FAIL", failure)
    print(f"{len(paths)} command help paths checked; {len(failures)} failures")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
