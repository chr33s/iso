#!/usr/bin/env python3
"""Default data-root safety and explicit configuration selection contracts."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def run(binary, home, *args):
    return subprocess.run(
        [binary, *args, "list"], capture_output=True, text=True, timeout=60,
        env={"HOME": str(home), "PATH": "/usr/bin:/bin", "ISO_NO_UPDATE_CHECK": "1"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", required=True)
    binary = os.path.abspath(parser.parse_args().swift)
    failures = []
    with tempfile.TemporaryDirectory(prefix="iso-data-root-") as directory:
        base = Path(directory).resolve()
        for kind in ["absent", "directory", "file", "symlink", "missing-config", "custom-config"]:
            home = base / kind
            home.mkdir()
            root = home / ".iso"
            args = []
            if kind == "directory":
                root.mkdir()
                (root / "unrelated").write_text("preserve me")
            elif kind == "file":
                root.write_text("preserve me")
            elif kind == "symlink":
                target = home / "target"
                target.mkdir()
                root.symlink_to(target)
            elif kind in ["missing-config", "custom-config"]:
                config = home / "custom.jsonc"
                args = ["--config", str(config)]
                if kind == "custom-config":
                    config.write_text(json.dumps({"data_dir": str(home / "custom-data"), "updates": {"mode": "off"}}))
            result = run(binary, home, *args)
            should_succeed = kind in ["absent", "directory", "custom-config"]
            if (result.returncode == 0) != should_succeed:
                failures.append(f"{kind}: exit {result.returncode}: {result.stderr}")
            if kind == "missing-config" and "Configuration file does not exist" not in result.stderr:
                failures.append("missing selected config did not report the missing file")
            if kind == "file" and root.read_text() != "preserve me":
                failures.append("file root changed")
            if kind == "directory" and (root / "unrelated").read_text() != "preserve me":
                failures.append("unrelated data changed")
            if kind == "symlink" and (not root.is_symlink() or list(target.iterdir())):
                failures.append("symlink target changed")
    for failure in failures:
        print("FAIL", failure)
    print(f"6 data-root scenarios checked; {len(failures)} failures")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
