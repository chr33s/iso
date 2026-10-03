#!/usr/bin/env python3
"""Run iso-egress under its production Seatbelt profile.

The self-test must deny file writes, child execution, and non-443 TCP, and
must still bind loopback. It does not open a public connection.
"""
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "Sources/IsoHost/Guest/Resources/seatbelt-egress.sb"


def main():
    binary = Path(subprocess.check_output(
        ["swift", "build", "--package-path", str(ROOT / "iso-egress"), "--show-bin-path"],
        text=True).strip()) / "iso-egress"
    command = [
        "/usr/bin/sandbox-exec", "-D", f"EGRESS_BIN={binary}", "-f", str(PROFILE),
        str(binary), "--jail-selftest",
    ]
    result = subprocess.run(command, capture_output=True, text=True, env={}, timeout=30)
    if result.returncode != 0 or "write/exec/non-443 denied" not in result.stderr:
        raise SystemExit(f"jail self-test failed:\n{result.stderr}")
    print("PASS egress profile denies write/exec/non-443 and allows loopback bind", flush=True)


if __name__ == "__main__":
    main()
