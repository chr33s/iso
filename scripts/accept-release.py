#!/usr/bin/env python3
"""Exercise published install/update/uninstall in a private HOME and install dir.

No VMs or provider requests are made. Run on a clean supported Mac for clean-machine
distribution evidence. A same-version forced update exercises first-release
replacement; pass --from-version for a later cross-version upgrade acceptance.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARIES = ("iso", "iso-proxy", "iso-egress", "iso-sandbox", "iso-macos-helper")


def version(value):
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", value):
        raise argparse.ArgumentTypeError("expected an explicit v-prefixed release version")
    return value


def environment(work, tag):
    # Do not inherit provider keys, GitHub auth, proxy variables, or update-origin
    # overrides. Retain the trusted tool search path, not any installed iso path.
    env = {key: value for key, value in os.environ.items()
           if key in {"PATH", "USER", "LOGNAME", "LANG", "TMPDIR"}}
    env.update(HOME=str(work / "home"), GH_CONFIG_DIR=str(work / "gh"),
               XDG_CONFIG_HOME=str(work / "home/.config"),
               XDG_STATE_HOME=str(work / "home/.local/state"),
               XDG_DATA_HOME=str(work / "home/.local/share"),
               VERSION=tag, INSTALL_DIR=str(work / "bin"))
    return env


def command(args, env, timeout=300):
    result = subprocess.run([str(arg) for arg in args], env=env, stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, timeout=timeout, check=True)
    return result.stdout + result.stderr


def check_bundle(work, tag, env):
    for binary in BINARIES:
        path = work / "bin" / binary
        if not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError(f"installed bundle missing {binary}")
        command(["/usr/bin/codesign", "--verify", "--strict", path], env)
        assessment = command(["/usr/sbin/spctl", "--assess", "--type", "open", "--context",
                              "context:primary-signature", "--verbose=2", path], env)
        if "source=Notarized Developer ID" not in assessment:
            raise ValueError(f"installed binary is not notarized: {binary}")
    output = command([work / "bin/iso", "--version"], env)
    if not output.startswith("iso " + tag[1:] + " ("):
        raise ValueError("installed iso version differs from requested release")
    command([work / "bin/iso-sandbox", "version"], env)
    command([work / "bin/iso", "--help"], env)


def accept(work, initial, target):
    for name in ("home", "gh", "bin"):
        (work / name).mkdir(mode=0o700)
    env = environment(work, initial)
    installed = command(["/bin/bash", ROOT / "install.sh"], env)
    for marker in ("SHA256SUMS signature verified.", "Attestation verified against attestations.jsonl"):
        if marker not in installed:
            raise ValueError("installer did not confirm credential-free bundled verification")
    check_bundle(work, initial, env)
    executable = work / "bin/iso"
    before = {name: (work / "bin" / name).stat().st_ino for name in BINARIES}
    command([executable, "update", "--version", target, "--force", "--yes"], env)
    check_bundle(work, target, env)
    if any((work / "bin" / name).stat().st_ino == inode for name, inode in before.items()):
        raise ValueError("update did not replace every installed binary")
    # The existing uninstall contract removes the CLI and optionally its data;
    # it does not promise removal of companion executables from the directory.
    command([executable, "uninstall", "--yes", "--keep-data"], env)
    if executable.exists():
        raise ValueError("uninstall retained the CLI executable")
    return {"installed": initial, "updated": target,
            "update_kind": "same-version replacement" if initial == target else "cross-version upgrade",
            "credential_free_install": True, "all_binaries_replaced": True,
            "uninstall": "CLI removed", "vm_and_provider_acceptance": "not exercised"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", type=version, required=True, help="published target release")
    parser.add_argument("--from-version", type=version, help="published starting release; defaults to target")
    args = parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="iso-release-acceptance-") as temporary:
            report = accept(Path(temporary), args.from_version or args.version, args.version)
        print(json.dumps(report, indent=2))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"release acceptance failed: {error}\n")


if __name__ == "__main__":
    main()
