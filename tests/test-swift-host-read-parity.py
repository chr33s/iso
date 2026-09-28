#!/usr/bin/env python3
"""Read-only commands: the Swift `coop` against the recorded baseline.

    python3 tests/test-swift-host-read-parity.py --swift .build/debug/coop \
        [--golden tests/baseline/parity/read.json]

Builds one synthetic state tree under a temporary HOME (instances without a
running runtime, images, per-VM proxy overrides, custom profiles) and a JSONC
configuration, runs each command, and compares stdout and exit status with the
results recorded from the baseline (Rust) host before its removal. Updates are
disabled so nothing contacts the network. Differences listed in EXPECTED are
recorded scope decisions; anything else fails.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

OWNER = "0a1b2c3d00112233445566778899aabb"
HASH = "a" * 64
ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "baseline" / "parity" / "read.json"
FIXTURES = ROOT / "tests" / "fixtures" / "coop-sandbox"
FIXTURE_ID = "coop-0a1b2c3d-00112233445566ff"
FIXTURE_ROOT = "/Users/me/.coop/backends/apple-container-v1/runtime"

# A stand-in `coop-sandbox`: answers `version` and `inspect` from the shared
# fixtures, rewriting the sandbox id and runtime root to the ones requested.
FAKE_RUNTIME = """#!/bin/sh
here=$(cd "$(dirname "$0")" && pwd)
case "$1" in
  version) cat "$here/fixtures/version.json" ;;
  inspect) sed -e "s#__ROOT__#$3#g" "$here/fixtures/inspect-$4.json" ;;
  list) echo '[]' ;;
  logs)
    if [ "$4" = "coop-0a1b2c3d-000000000000000b" ]; then echo "disk busy" >&2; exit 3; fi
    printf '  boot line one  \\n\\033[31mred\\033[0m and\\302\\255soft\\n'
    head -c 70000 /dev/zero | tr '\\0' x; printf '\\n'
    echo "stderr note" >&2
    printf 'last line without newline'
    [ "$5" = "--follow" ] && printf '\\nfollowed\\n'
    ;;
  *) echo "unexpected: $*" >&2; exit 64 ;;
esac
"""

# A stand-in `ssh` (both hosts take it from PATH) returning guest usage.
FAKE_SSH = """#!/bin/sh
printf '0.12 0.08 0.03 1/42 1234\\nMemTotal:        2048000 kB\\nMemAvailable:    1024000 kB\\n'
printf 'Filesystem     1M-blocks  Used Available Use%% Mounted on\\n/dev/vda1          20480  3200     16000  17%% /\\n'
"""

CONFIG_JSONC = """{
  // The settings the baseline was recorded with.
  "apple_container": {"binary": "__BIN__/coop-sandbox"},
  "updates": {"mode": "off"},
  "profiles": {
    "zz-tools": {"apt_packages": ["jq", "ripgrep"], "post_install": "echo one\\necho two"},
    "python": {"apt_packages": ["python3-full"]}
  },
  "proxy": {"anthropic": {"credential": "cmd:security find-generic-password -s coop-anthropic -w", "auth": "bearer"}}
}
"""

COMMANDS = [
    ["list"],
    ["list", "--json"],
    ["ls"],
    ["images"],
    ["images", "--json"],
    ["profiles"],
    ["profiles", "list"],
    ["profiles", "list", "--json"],
    ["profiles", "show", "rust"],
    ["profiles", "show", "node"],
    ["profiles", "show", "python"],
    ["profiles", "show", "zz-tools"],
    ["profiles", "show", "nope"],
    ["proxy", "status"],
    ["proxy", "status", "--vm", "beta"],
    ["proxy", "status", "--vm", "alpha"],
    ["proxy", "status", "--vm", "missing"],
    ["proxy", "status", "--vm", "bad/name"],
    ["status", "--json"],
    ["status"],
    ["status", "alpha", "--json"],
    ["status", "bad/name"],
    ["status", "alpha"],
    ["status", "beta"],
    ["status", "beta", "--json"],
    ["status", "delta"],
    ["status", "epsilon", "--json"],
    ["status", "gamma"],
    ["logs", "alpha"],
    ["logs", "alpha", "--follow"],
    ["logs", "alpha", "-f"],
    ["logs", "beta"],
    ["logs", "gamma"],
    ["logs", "nobody"],
    ["logs"],
]

# (command, reason): stdout differences that are recorded scope decisions.
EXPECTED = {
    ("proxy", "status"): "header names the JSONC configuration instead of `[proxy] in config.toml`",
}


def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def sidecar(machine):
    return {
        "schema_version": 2, "backend": "apple-container", "owner_id": OWNER, "machine_id": machine,
        "image_ref": "local/coop-exp:fx", "image_digest": "sha256:" + HASH, "image_manifest_id": "m",
        "guest_user": "ubuntu", "requested_cpus": 2, "requested_memory_bytes": 2147483648,
        "host_key_fingerprint": "SHA256:SYNTHETIC", "last_observed_owner_pid": None,
        "last_observed_ip": None, "reenroll_host_key": False, "created_at": "2026-09-27T00:00:00Z",
        "runtime_identity": "coop-sandbox 0.2.0",
    }


def build_runtime(home):
    bin_dir = home / "bin"
    (bin_dir / "fixtures").mkdir(parents=True)
    (bin_dir / "fixtures" / "version.json").write_text((FIXTURES / "version.json").read_text())
    running = (FIXTURES / "inspect-running.json").read_text().replace(FIXTURE_ROOT, "__ROOT__")
    stopped = (FIXTURES / "inspect-stopped.json").read_text().replace(FIXTURE_ROOT, "__ROOT__")
    for machine, text in [
        ("coop-0a1b2c3d-000000000000000a", running),
        ("coop-0a1b2c3d-000000000000000b", stopped),
        ("coop-0a1b2c3d-000000000000000d", running.replace('"running"', '"booting"', 1)),
    ]:
        (bin_dir / "fixtures" / f"inspect-{machine}.json").write_text(text.replace(FIXTURE_ID, machine))
    for name, text in [("coop-sandbox", FAKE_RUNTIME), ("ssh", FAKE_SSH)]:
        (bin_dir / name).write_text(text)
        (bin_dir / name).chmod(0o755)
    bin_dir.chmod(0o755)
    return bin_dir


def build_state(home):
    bin_dir = build_runtime(home)
    state = home / ".coop" / "backends" / "apple-container-v1"
    write(state / "owner.json", json.dumps({"schema_version": 1, "backend": "apple-container", "owner_id": OWNER}))
    write(state / "vm_key", "SYNTHETIC")
    for name, suffix in [("alpha", "a"), ("beta", "b"), ("delta", "d")]:
        machine = "coop-0a1b2c3d-" + "0" * 15 + suffix
        write(state / "instances" / name / "apple-machine.json", json.dumps(sidecar(machine)))
        write(state / "instances" / name / "known_hosts", f"{machine}.coop ssh-ed25519 AAAA\n")
    write(state / "instances" / "epsilon" / "instance.json", json.dumps({"name": "epsilon", "index": 7}))
    write(state / "instances" / "epsilon" / "operation.json", json.dumps({
        "schema_version": 2, "backend": "apple-container", "owner_id": OWNER,
        "machine_id": "coop-0a1b2c3d-000000000000000e", "op": {"kind": "destroy", "stage": "reserved"}}))
    for name, index, image in [
        ("beta", 1, "default"), ("alpha", 4, "custom-img"), ("gamma", 2, None), ("delta", 3, None),
    ]:
        meta = {"name": name, "index": index}
        if image:
            meta["image"] = image
        write(state / "instances" / name / "instance.json", json.dumps(meta))
    write(state / "instances" / "corrupt" / "instance.json", "{not json")
    write(
        state / "instances" / "beta" / "proxy.json",
        json.dumps({"openai": {"credential": "cmd:pass show openai", "auth": "bearer"},
                    "anthropic": {"credential": "sk-literal-SYNTHETIC"}}),
    )
    write(state / "instances" / "gamma" / "proxy.json", json.dumps({}))
    template = {
        "version": 1, "created": "2026-09-27T00:00:00Z", "install_script_hash": HASH,
        "profiles": ["rust", "python"], "extra_packages": [], "post_install_hash": None,
    }
    write(state / "images" / "default" / "template-config.json", json.dumps(template))
    write(state / "images" / "bare" / "template-config.json", json.dumps({**template, "profiles": []}))
    write(state / "images" / "broken" / "template-config.json", json.dumps({**template, "install_script_hash": "x"}))
    (state / "images" / ".hidden").mkdir(parents=True)
    write(home / "swift" / "config.jsonc", CONFIG_JSONC.replace("__BIN__", str(bin_dir)))


def run(binary, args, home, config):
    env = {"HOME": str(home), "PATH": f"{home}/bin:/usr/bin:/bin", "NO_COLOR": "1", "RUST_LOG": "off"}
    command = [binary, "--config", str(config), *args]
    result = subprocess.run(command, capture_output=True, text=True, env=env, timeout=60)
    return result.returncode, result.stdout, result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--golden", type=Path, default=GOLDEN, help=f"recorded baseline results (default {GOLDEN.relative_to(ROOT)})")
    parser.add_argument("--swift", required=True)
    args = parser.parse_args()
    golden = json.loads(args.golden.read_text())
    failures = []
    with tempfile.TemporaryDirectory(prefix="coop-parity-") as directory:
        # Canonical path: the runtime root is compared after realpath.
        home = Path(os.path.realpath(directory))
        build_state(home)
        swift_config = home / "swift" / "config.jsonc"
        # Recorded results name the temporary HOME symbolically.
        def portable(result):
            return (result[0], result[1].replace(str(home), "<HOME>"), result[2])

        for command in COMMANDS:
            label = " ".join(command)
            expected = golden[label]
            baseline = (expected["exit"], expected["stdout"], "(recorded baseline)")
            swift = portable(run(os.path.abspath(args.swift), command, home, swift_config))
            same_status = (baseline[0] == 0) == (swift[0] == 0) and (baseline[0] != 2 or swift[0] == 2)
            same_stdout = baseline[1] == swift[1]
            reason = EXPECTED.get(tuple(command))
            if same_status and (same_stdout or reason):
                note = f"  (expected difference: {reason})" if not same_stdout else ""
                print(f"ok    {label}{note}")
                continue
            failures.append(label)
            print(f"FAIL  {label}: baseline exit {baseline[0]}, swift exit {swift[0]}")
            if not same_stdout:
                print("  --- baseline stdout\n" + baseline[1] + "  --- swift stdout\n" + swift[1])
            print("  --- swift stderr\n" + swift[2][-800:])
    print(f"\n{len(COMMANDS) - len(failures)}/{len(COMMANDS)} commands match")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
