#!/usr/bin/env python3
"""Exercise every registered CLI help path and required public command families."""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INVENTORY = ROOT / "tests/fixtures/contracts/cli-inventory.json"
GLOBAL = {"--config", "-v", "--verbose", "--output", "--quiet", "--version", "-h", "--help"}

REQUIRED = {
    "setup", "up", "start", "shell", "exec", "stop", "destroy", "list", "status", "logs",
    "claude", "codex", "agent", "run", "run-cleanup", "images", "diff", "audit", "secrets",
    "github", "proxy", "profiles", "devcontainer", "update", "uninstall", "validate", "completions",
    "capabilities", "ssh-config", "editor", "code", "zed",
}


def commands(command, prefix=()):
    path = prefix + (command["commandName"],) if prefix or command["commandName"] != "iso" else ()
    yield path, command
    for child in command.get("subcommands", []):
        yield from commands(child, path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True)
    parser.add_argument("--update-inventory", action="store_true", help=f"rewrite {INVENTORY.relative_to(ROOT)}")
    options = parser.parse_args()
    binary = os.path.abspath(options.swift)
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
    failures += inventory(paths, options.update_inventory)
    failures += machine_listing(binary, paths)
    failures += completion_coverage(binary, paths)
    for removed in ["init", "quickstart"]:
        result = subprocess.run([binary, removed], capture_output=True, text=True, timeout=60)
        if result.returncode == 0:
            failures.append(f"removed command {removed} remains registered")
    for failure in failures:
        print("FAIL", failure)
    print(f"{len(paths)} command help paths checked; {len(failures)} failures")
    return bool(failures)


def public(paths):
    """Paths whose every component is displayed (hidden groups are internal)."""
    shown = {}
    for path, command in paths:
        shown[path] = command.get("shouldDisplay", True) and (len(path) < 2 or shown.get(path[:-1], True))
    return [path for path, _ in paths if path and shown[path]]


def spelling(name):
    return ("-" if name["kind"] == "short" else "--") + name["name"]


def inventory(paths, update):
    """Every public command path with its arguments and every accepted spelling.

    The reviewed fixture is the one maintained command inventory: adding,
    renaming or dropping a flag or alias shows up as a diff to it.
    """
    current = {}
    for path in public(paths):
        command = dict(paths)[path]
        entries = []
        for argument in command.get("arguments", []):
            names = [spelling(name) for name in argument.get("names", [])]
            if GLOBAL.intersection(names):
                continue
            label = " ".join(names) if names else "<" + argument.get("valueName", "") + ">"
            if not argument.get("shouldDisplay", True):
                label += " (hidden)"
            entries.append(label)
        current[" ".join(path)] = entries
    if update:
        INVENTORY.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
        return []
    recorded = json.loads(INVENTORY.read_text())
    failures = []
    for path in sorted(set(recorded) | set(current)):
        if recorded.get(path) != current.get(path):
            failures.append(f"inventory: iso {path}: recorded {recorded.get(path)} != current {current.get(path)} (review, then --update-inventory)")
    return failures


def machine_listing(binary, paths):
    """`capabilities` advertises exactly the documented machine commands, and each one dispatches."""
    failures = []
    document = json.loads(subprocess.check_output([binary, "capabilities", "--output", "json"], text=True, timeout=60))
    advertised = set(document["result"]["commands"])
    table = (ROOT / "docs/machine-interface.md").read_text().split("## Supported commands", 1)[1].split("\n\n", 2)[1]
    documented = {name for cell in re.findall(r"^\| (.+?) \|", table, re.M) for name in re.findall(r"`([a-z][a-z -]*?)(?: \[|`)", cell)}
    if advertised != documented:
        failures.append(f"machine commands {sorted(advertised)} differ from docs/machine-interface.md {sorted(documented)}")
    known = {" ".join(path) for path in public(paths)}
    for name in sorted(advertised - known):
        failures.append(f"advertised machine command '{name}' is not a public command path")
    return failures


def completion_coverage(binary, paths):
    """Every public command name appears in each generated completion script."""
    failures = []
    names = {path[-1] for path in public(paths)}
    for shell in ["bash", "zsh", "fish"]:
        script = subprocess.check_output([binary, "completions", shell], text=True, timeout=60)
        words = set(re.findall(r"[A-Za-z0-9_.\[\]-]+", script))
        missing = sorted(name for name in names if name not in words)
        if missing:
            failures.append(f"{shell} completions miss {missing}")
    return failures


if __name__ == "__main__":
    sys.exit(main())
