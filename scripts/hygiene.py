#!/usr/bin/env python3
"""Repository hygiene for staged files (the pre-commit `hygiene` task).

    python3 scripts/hygiene.py [--all] [PATH...]

Checks what the former pre-commit-hooks checked, without rewriting files:
trailing whitespace, a missing final newline, YAML that does not parse (via
`yq`), files over 500 KiB, leftover merge-conflict markers, and Swift that
escapes a quote with `replacingOccurrences` (it matches whole `Character`s,
so a quote followed by a combining mark escapes unchanged; escape per scalar
with `shellEscape` or iso-ci's `replacingScalars`). By default it
checks the files staged for commit; `--all` checks every tracked file, and
explicit paths check just those. Whenever a `Package.swift` is among the
checked files, it also requires every manifest to pin a shared dependency at
the same version. Exit status 1 lists every problem.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 500 * 1024
CONFLICT_MARKERS = (b"<<<<<<< ", b">>>>>>> ")
# Fuzz inputs and vendored LLVM sources keep
# their original bytes.
EXEMPT = ("fuzz/corpus/", "fuzz/libfuzzer/")
QUOTE_REPLACE = re.compile(rb'replacingOccurrences\(of: "(\'|\\"|\\\\|\{|\})"')


def git(*args):
    return subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True).stdout


def staged():
    output = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
    return [name.decode() for name in output.split(b"\0") if name]


def tracked():
    return [name.decode() for name in git("ls-files", "-z").split(b"\0") if name]


def is_binary(data):
    return b"\0" in data[:8192]


def check(path):
    problems = []
    file = ROOT / path
    if not file.is_file() or file.is_symlink():
        return problems
    data = file.read_bytes()
    if len(data) > MAX_BYTES:
        problems.append(f"larger than {MAX_BYTES // 1024} KiB ({len(data)} bytes)")
    if is_binary(data) or path.startswith(EXEMPT):
        return problems
    lines = data.split(b"\n")
    for number, line in enumerate(lines, 1):
        stripped = line.rstrip(b"\r")
        trailing = stripped[len(stripped.rstrip(b" \t")):]
        # Two trailing spaces are a Markdown hard line break.
        if trailing and not (path.endswith(".md") and trailing == b"  "):
            problems.append(f"line {number}: trailing whitespace")
        if line.startswith(CONFLICT_MARKERS) or line == b"=======":
            problems.append(f"line {number}: merge-conflict marker")
    if path.endswith(".swift"):
        for number, line in enumerate(lines, 1):
            if QUOTE_REPLACE.search(line):
                problems.append(
                    f"line {number}: quote escaped with replacingOccurrences; escape per Unicode scalar")
    if data and not data.endswith(b"\n"):
        problems.append("no newline at end of file")
    if path.endswith((".yml", ".yaml")):
        # Without --exit-status, yq exits 0 for any document (including null or
        # false) and 1 for a parse error.
        result = subprocess.run(["yq", ".", str(file)], capture_output=True)
        if result.returncode != 0:
            problems.append("YAML does not parse: " + result.stderr.decode(errors="replace").strip())
    return problems


PIN = re.compile(r'\.package\(\s*url:\s*"([^"]+)",\s*exact:\s*"([^"]+)"')


def pin_problems():
    """A dependency pinned by several manifests must have one version."""
    versions = {}
    for manifest in tracked():
        if Path(manifest).name != "Package.swift":
            continue
        for url, version in PIN.findall((ROOT / manifest).read_text()):
            versions.setdefault(url, {}).setdefault(version, []).append(manifest)
    problems = []
    for url, pins in sorted(versions.items()):
        if len(pins) > 1:
            detail = "; ".join(f"{v} in {', '.join(m)}" for v, m in sorted(pins.items()))
            problems.append(f"{url}: pinned at different versions ({detail})")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--all", action="store_true", help="check every tracked file")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    paths = args.paths or (tracked() if args.all else staged())
    failed = False
    for path in paths:
        for problem in check(path):
            print(f"{path}: {problem}")
            failed = True
    if any(Path(path).name == "Package.swift" for path in paths):
        for problem in pin_problems():
            print(problem)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
