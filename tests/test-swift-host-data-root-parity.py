#!/usr/bin/env python3
"""The default data-directory guard: the Swift `iso` against the recorded baseline.

    python3 tests/test-swift-host-data-root-parity.py --swift .build/debug/iso \
        [--golden tests/baseline/parity/data-root.json]

Each scenario builds a HOME, runs `iso list`, and compares exit status and the
resulting directory layout with the results recorded from the baseline (Rust)
host before its removal. The default
`~/.iso` is refused when it holds upstream coop state or is not a real
directory; an explicit `--config` is never checked; a leftover
`~/.coop-apple` is neither read nor moved.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "baseline" / "parity" / "data-root.json"
OWNER = {"schema_version": 1, "backend": "apple-container", "owner_id": "0a1b2c3d00112233445566778899aabb"}


def state(root):
    base = root / "backends" / "apple-container-v1"
    base.mkdir(parents=True)
    (base / "owner.json").write_text(json.dumps(OWNER))
    (base / "instances").mkdir()


def owned(home):
    state(home / ".iso")


def upstream_key(home):
    (home / ".iso").mkdir()
    (home / ".iso" / "vm_key").write_text("x")


def upstream_instances(home):
    (home / ".iso" / "instances").mkdir(parents=True)


def linked_root(home):
    state(home / "elsewhere")
    (home / ".iso").symlink_to(home / "elsewhere")


def leftover(home):
    state(home / ".coop-apple")


SCENARIOS = [
    ("absent root", lambda home: None, []),
    ("owned state", owned, []),
    ("refuses upstream key", upstream_key, []),
    ("refuses upstream instances", upstream_instances, []),
    ("refuses a symlinked root", linked_root, []),
    ("ignores a leftover coop-apple directory", leftover, []),
    ("explicit --config is not checked", upstream_key, ["--config", "{home}/custom.jsonc"]),
]


def layout(home):
    entries = {}
    for path in sorted(home.rglob("*")):
        relative = str(path.relative_to(home))
        if relative.startswith("bin") or path.name.startswith(".lock"):
            continue
        if "runtime" in relative and path.name.endswith(".lock"):
            continue
        if path.is_symlink():
            entries[relative] = "-> " + os.readlink(path).replace(str(home), "<HOME>")
        elif path.is_dir():
            entries[relative] = "dir"
        else:
            entries[relative] = "file"
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--golden", type=Path, default=GOLDEN, help=f"recorded baseline results (default {GOLDEN.relative_to(ROOT)})")
    parser.add_argument("--swift", required=True)
    args = parser.parse_args()
    golden = json.loads(args.golden.read_text())
    failures = 0
    with tempfile.TemporaryDirectory(prefix="iso-data-root-") as base:
        base = Path(os.path.realpath(base))
        for label, build, extra in SCENARIOS:
            home = base / f"swift-{label.replace(' ', '-')}"
            home.mkdir()
            build(home)
            argv = [a.format(home=home) for a in extra] + ["list"]
            env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "ISO_NO_UPDATE_CHECK": "1", "RUST_LOG": "off"}
            result = subprocess.run([os.path.abspath(args.swift), *argv], capture_output=True, text=True, env=env,
                                    timeout=120)
            swift = (result.returncode, layout(home), result.stderr.strip()[-300:])
            expected = golden[label]
            baseline = (expected["exit"], expected["layout"])
            if (baseline[0] == 0) == (swift[0] == 0) and baseline[1] == swift[1]:
                print(f"ok    {label} (exit {baseline[0]})")
                continue
            failures += 1
            print(f"FAIL  {label}: baseline exit {baseline[0]}, swift exit {swift[0]}")
            for key in sorted(set(baseline[1]) | set(swift[1])):
                if baseline[1].get(key) != swift[1].get(key):
                    print(f"  {key}: baseline {baseline[1].get(key)} / swift {swift[1].get(key)}")
            print("  swift stderr: " + swift[2])
    print(f"\n{len(SCENARIOS) - failures}/{len(SCENARIOS)} scenarios match")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
