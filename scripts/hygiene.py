#!/usr/bin/env python3
"""Repository hygiene for staged files (the pre-commit `hygiene` task).

    python3 scripts/hygiene.py [--all] [PATH...]

Checks what the former pre-commit-hooks checked, without rewriting files:
trailing whitespace, a missing final newline, YAML that does not parse (via
`yq`), files over 500 KiB, and leftover merge-conflict markers. By default it
checks the files staged for commit; `--all` checks every tracked file, and
explicit paths check just those. Exit status 1 lists every problem.
"""

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 500 * 1024
CONFLICT_MARKERS = (b"<<<<<<< ", b"=======\n", b">>>>>>> ")
# Fuzz inputs, vendored LLVM sources and captured baseline CLI output keep
# their original bytes.
EXEMPT = ("fuzz/corpus/", "fuzz/libfuzzer/", "tests/fixtures/baseline-cli/")


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
    if data and not data.endswith(b"\n"):
        problems.append("no newline at end of file")
    if path.endswith((".yml", ".yaml")):
        result = subprocess.run(["yq", "--exit-status", ".", str(file)], capture_output=True)
        if result.returncode not in (0, 1):  # 1: valid YAML whose value is null/false
            problems.append("YAML does not parse: " + result.stderr.decode(errors="replace").strip())
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
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
