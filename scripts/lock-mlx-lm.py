#!/usr/bin/env python3
"""Regenerate the hash-locked requirements that `managed.install` provisions.

`iso inference provision` installs mlx-lm into a managed backend's venv with
`pip install --require-hashes --no-deps --only-binary :all: -r <lock>`. The
lock is Sources/IsoHost/Inference/Resources/mlx-lm-<version>.lock, which
scripts/generate-embedded-resources.py embeds in iso. This script resolves it
with uv (pinned in mise.toml) from PyPI for the standalone CPython 3.12 that
provisioning installs (macOS arm64), binary wheels only. uv records a hash for
every file of each pinned version, so pip finds one for whichever wheel it
picks. Run scripts/generate-embedded-resources.py afterwards.

    python3 scripts/lock-mlx-lm.py [--check]
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources" / "IsoHost" / "Inference" / "Resources"

MLX_LM = "0.31.3"
# The mlx release the launcher and backend profile were qualified with
# (docs/design/secure-local-inference-spec.md §19).
MLX = "0.32.3"
# The minor version of `StandalonePython` in ManagedBackend.swift.
PYTHON = "3.12"
# iso hosts run macOS 27 or later.
MACOS = "27.0"
# The newest PyPI upload the lock may use, so a rerun resolves the same
# versions. Move it forward deliberately when re-locking.
EXCLUDE_NEWER = "2026-11-09T00:00:00Z"


def compile_lock(uv, output):
    with tempfile.TemporaryDirectory() as scratch:
        requirements = Path(scratch) / "requirements.in"
        requirements.write_text(f"mlx-lm=={MLX_LM}\nmlx=={MLX}\n", encoding="utf-8")
        environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": os.environ.get("HOME", scratch),
            "MACOSX_DEPLOYMENT_TARGET": MACOS,
        }
        subprocess.run(
            [
                uv, "pip", "compile", "--quiet", "--no-config", "--no-cache",
                "--python-version", PYTHON, "--python-platform", "aarch64-apple-darwin",
                "--only-binary", ":all:", "--generate-hashes",
                "--index-url", "https://pypi.org/simple",
                "--exclude-newer", EXCLUDE_NEWER,
                "--annotation-style", "line",
                "--custom-compile-command", "python3 scripts/lock-mlx-lm.py",
                "--output-file", str(output), requirements.name,
            ],
            check=True, env=environment, cwd=scratch, stdout=subprocess.DEVNULL,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", action="store_true", help="fail if the committed lock differs")
    args = parser.parse_args()
    uv = shutil.which("uv")
    if uv is None:
        raise SystemExit("uv not found; install the pinned tools with scripts/install-dev-tools.sh")
    lock = RESOURCES / f"mlx-lm-{MLX_LM}.lock"
    with tempfile.TemporaryDirectory() as scratch:
        fresh = Path(scratch) / lock.name
        compile_lock(uv, fresh)
        if args.check:
            if not lock.exists() or lock.read_text(encoding="utf-8") != fresh.read_text(encoding="utf-8"):
                raise SystemExit(f"{lock.relative_to(ROOT)} differs from a fresh resolution")
            print(f"verified {lock.relative_to(ROOT)}")
        else:
            shutil.copyfile(fresh, lock)
            print(f"wrote {lock.relative_to(ROOT)}")


if __name__ == "__main__":
    sys.exit(main())
