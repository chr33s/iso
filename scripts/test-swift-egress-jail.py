#!/usr/bin/env python3
"""Run iso-egress under its production Seatbelt profile, and once without it.

The confined self-test must deny file writes, child execution, non-443 TCP,
loopback ports 443 and 53 and reads under the user's home, and must still bind
loopback. Unconfined, the companion must refuse to start before it reads the
startup secret from stdin. It does not open a public connection.
"""
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILE = ROOT / "Sources/IsoHost/Guest/Resources/seatbelt-egress.sb"
STARTUP = b'{"listen":"127.0.0.1:1","capability":"unconfined-fixture","allowedHosts":[]}'


def confined(binary):
    command = [
        "/usr/bin/sandbox-exec", "-D", f"EGRESS_BIN={binary}", "-f", str(PROFILE),
        str(binary), "--jail-selftest",
    ]
    result = subprocess.run(command, capture_output=True, text=True, env={}, timeout=30)
    expected = "write/exec/non-443/loopback-443/loopback-53/home-read denied; loopback bind allowed"
    if result.returncode != 0 or expected not in result.stderr:
        raise SystemExit(f"jail self-test failed:\n{result.stderr}")
    print("PASS egress profile denies write/exec/non-443/loopback-443/loopback-53/home-read "
          "and allows loopback bind", flush=True)


def unconfined(binary):
    """The startup bytes stay in the pipe: the companion exits without reading them."""
    read, write = os.pipe()
    try:
        os.write(write, STARTUP)
        result = subprocess.run([str(binary)], stdin=read, capture_output=True, text=True,
                                env={}, timeout=30)
        os.set_blocking(read, False)
        left = os.read(read, len(STARTUP) + 1)
    finally:
        os.close(read)
        os.close(write)
    if result.returncode == 0 or "confinement failure" not in result.stderr:
        raise SystemExit(f"unconfined companion did not refuse startup:\n{result.stderr}")
    if left != STARTUP:
        raise SystemExit("unconfined companion read stdin before refusing")
    if "unconfined-fixture" in result.stderr:
        raise SystemExit("unconfined companion echoed its startup input")
    print("PASS unconfined egress refuses before reading stdin", flush=True)


def main():
    binary = Path(subprocess.check_output(
        ["swift", "build", "--package-path", str(ROOT / "iso-egress"), "--show-bin-path"],
        text=True).strip()) / "iso-egress"
    confined(binary)
    unconfined(binary)


if __name__ == "__main__":
    main()
