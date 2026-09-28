#!/usr/bin/env python3
"""Lifecycle commands: the Swift `coop` against the recorded baseline.

    python3 tests/test-swift-host-lifecycle-parity.py --swift .build/debug/coop \
        [--golden tests/baseline/parity/lifecycle.json]

The host runs in a HOME with a pre-seeded owner and VM key and its own copy of
the stateful fake runtime (`tests/fixtures/fake-runtime`), fake `container`
builder and fake `ssh`. Each step's exit status, stdout, runtime call
sequence, resulting state files and the captured image build contexts (byte
for byte) are compared with the results recorded from the baseline (Rust) host
before its removal, after normalizing generated names, nonces, timestamps and
home paths.
"""

import argparse
import hashlib
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "baseline" / "parity" / "lifecycle.json"
FAKES = ROOT / "tests" / "fixtures" / "fake-runtime"
OWNER = "0a1b2c3d00112233445566778899aabb"
STATE = ".coop/backends/apple-container-v1"

FAKE_SSH = "#!/bin/sh\nexit 0\n"

CONFIG_JSONC = """{
  "updates": {"mode": "off"},
  "apple_container": {"binary": "__BIN__/coop-sandbox", "builder": "__BIN__/container", "kernel": "__HOME__/kernel"}
}
"""

# Steps whose runtime call sequences may differ, with the recorded reason.
# State, stdout and exit status are still compared for them.
EXPECTED_CALL_DIFFERENCES: dict[str, str] = {}

# (label, argv, hook run before the command)
STEPS = [
    ("setup", ["setup"], None),
    ("setup again (up to date)", ["setup"], None),
    ("setup rust image", ["setup", "--rebuild", "--profile", "rust,python", "--image", "rusty", "--guest-user", "dev"], None),
    ("setup unknown profile", ["setup", "--profile", "nope"], None),
    ("devcontainer fixtures", None, "devcontainer"),
    ("setup devcontainer dry run", ["setup", "--dry-run", "--workspace", "__HOME__/dc"], None),
    ("setup devcontainer feature", ["setup", "--image", "dc", "--devcontainer",
                                    "__HOME__/dc/.devcontainer/devcontainer.json"], None),
    ("images", ["images", "--json"], None),
    ("seed instance", None, "seed"),
    ("status stopped", ["status", "alpha", "--json"], None),
    ("resize disk", ["resize", "alpha", "--size", "+2"], None),
    ("resize shrink", ["resize", "alpha", "--size", "1"], None),
    ("resize resources", ["resize", "alpha", "--mem", "3072", "--vcpus", "3"], None),
    ("commit", ["commit", "alpha", "--image", "snap"], None),
    ("commit exists", ["commit", "alpha", "--image", "snap"], None),
    ("commit force", ["commit", "alpha", "--image", "snap", "--force"], None),
    ("restore", ["restore", "alpha", "--image", "snap"], None),
    ("restore missing", ["restore", "alpha", "--image", "missing"], None),
    ("interrupted resource change", None, "journal-set"),
    ("resize recovers journal", ["resize", "alpha", "--vcpus", "5"], None),
    ("interrupted restore", None, "journal-restore"),
    ("restore recovers journal", ["restore", "alpha", "--image", "default"], None),
    ("interrupted create", None, "journal-create"),
    ("status with create journal", ["status", "beta", "--json"], None),
    ("destroy takes over create", ["destroy", "beta"], None),
    ("stop stopped", ["stop", "alpha"], None),
    ("delete image", ["images", "--delete", "rusty"], None),
    ("delete missing image", ["images", "--delete", "rusty"], None),
    ("destroy", ["destroy", "alpha"], None),
    ("destroy --all", ["destroy", "--all"], None),
    ("images after", ["images", "--json"], None),
]


def make_home(base, name, key_dir, config_text, config_name):
    home = Path(os.path.realpath(base)) / name
    bin_dir = home / "bin"
    bin_dir.mkdir(parents=True)
    for tool in ["coop-sandbox", "container"]:
        shutil.copy(FAKES / tool, bin_dir / tool)
        (bin_dir / tool).chmod(0o755)
    (bin_dir / "ssh").write_text(FAKE_SSH)
    (bin_dir / "ssh").chmod(0o755)
    (home / "kernel").write_text("kernel")
    state = home / STATE
    state.mkdir(parents=True)
    state.chmod(0o700)
    (state / "owner.json").write_text(
        json.dumps({"schema_version": 1, "backend": "apple-container", "owner_id": OWNER}, indent=2) + "\n")
    for key in ["vm_key", "vm_key.pub"]:
        shutil.copy(key_dir / key, state / key)
    config = home / ".coop" / config_name
    config.write_text(config_text.replace("__BIN__", str(bin_dir)).replace("__HOME__", str(home)))
    return home, config


def seed_instance(home):
    """An instance created earlier: records, pin, and a stopped sandbox."""
    state = home / STATE
    fake = json.loads((state / "runtime" / "fake-state.json").read_text())
    image = json.loads((state / "images" / "default" / "apple-image.json").read_text())
    machine = "coop-0a1b2c3d-00000000000000aa"
    fake["sandboxes"][machine] = {
        "id": machine, "owner": OWNER, "imageReference": image["image_ref"], "imageDigest": image["digest"],
        "cpus": 2, "memoryBytes": 4096 << 20, "diskBytes": 8 << 30, "diskGeneration": 0, "status": "stopped",
        "subnet": 7}
    (state / "runtime" / "fake-state.json").write_text(json.dumps(fake, indent=2))
    disk = state / "runtime" / "sandboxes" / machine / "rootfs.ext4"
    disk.parent.mkdir(parents=True)
    with open(disk, "a") as handle:
        handle.truncate(8 << 30)
    instance = state / "instances" / "alpha"
    instance.mkdir(parents=True)
    (instance / "instance.json").write_text(json.dumps({"name": "alpha", "index": 0, "image": "default"}))
    (instance / "known_hosts").write_text(
        f"{machine}.coop ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINiqkOnkRV06x+SuorkF+O3KdBTVFznIV0+b58cidW1N\n")
    (instance / "apple-machine.json").write_text(json.dumps({
        "schema_version": 2, "backend": "apple-container", "owner_id": OWNER, "machine_id": machine,
        "image_ref": image["image_ref"], "image_digest": image["digest"], "image_manifest_id": image["manifest_id"],
        "guest_user": "ubuntu", "requested_cpus": 2, "requested_memory_bytes": 4096 << 20,
        "host_key_fingerprint": "SHA256:x", "last_observed_owner_pid": None, "last_observed_ip": None,
        "reenroll_host_key": False, "created_at": "2026-09-28T00:00:00Z", "runtime_identity": "coop-sandbox 0.2.0"},
        indent=2))


DEVCONTAINER = """{
  // A registry Feature (served by the stub curl), a built-in profile, and a guest user.
  "features": {"ghcr.io/devcontainers/features/hello:1": {"greeting": "it's"}, "rust": {}},
  "remoteUser": "vscode",
  "hostRequirements": {"cpus": 3, "memory": "3GiB"},
}
"""

# Answers the GHCR token, manifest and blob requests; no network.
STUB_CURL = """#!/bin/sh
out=""; hdr=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a";; -D) hdr="$a";; esac
  prev="$a"
done
case "$*" in
  *token*) printf '{"token":"SYNTHETIC"}';;
  */manifests/*) printf 'docker-content-digest: __DIGEST__\\r\\n' > "$hdr"
    cp "__MANIFEST__" "$out";;
  */blobs/*) cp "__ARCHIVE__" "$out";;
  *) exit 22;;
esac
"""


def seed_devcontainer(home):
    """A devcontainer.json with a Feature, and a stub `curl` serving it."""
    archive = home.parent / "feature.tgz"
    if not archive.exists():
        # Byte-deterministic (fixed mtimes, owners, gzip header): its bytes
        # are embedded in provision.sh, so the recorded baseline depends on them.
        files = {"devcontainer-feature.json": b'{"id": "hello"}',
                 "install.sh": b'#!/bin/sh\necho "hello $GREETING"\n'}
        raw = io.BytesIO()
        with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for name, data in files.items():
                info = tarfile.TarInfo(name)
                info.size, info.mode, info.mtime = len(data), 0o644, 0
                tar.addfile(info, io.BytesIO(data))
        with open(archive, "wb") as out, gzip.GzipFile(fileobj=out, mode="wb", mtime=0, filename="") as gz:
            gz.write(raw.getvalue())
    (home / "dc" / ".devcontainer").mkdir(parents=True)
    (home / "dc" / ".devcontainer" / "devcontainer.json").write_text(DEVCONTAINER)
    # Real digests: the manifest names the layer by its hash and is served
    # with the digest of its own bytes (the Swift host verifies both).
    layer = "sha256:" + hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = home.parent / "manifest.json"
    manifest.write_text(json.dumps({"layers": [{"digest": layer}]}, separators=(",", ":")))
    digest = "sha256:" + hashlib.sha256(manifest.read_bytes()).hexdigest()
    curl = home / "bin" / "curl"
    curl.write_text(STUB_CURL.replace("__DIGEST__", digest).replace("__MANIFEST__", str(manifest))
                    .replace("__ARCHIVE__", str(archive)))
    curl.chmod(0o755)


def fake_state(home):
    path = home / STATE / "runtime" / "fake-state.json"
    return path, json.loads(path.read_text())


def write_journal(instance, machine, op):
    (instance / "operation.json").write_text(json.dumps({
        "schema_version": 2, "backend": "apple-container", "owner_id": OWNER, "machine_id": machine, "op": op},
        indent=2))


def seed_set_journal(home):
    """The runtime applied a resource change the host never recorded."""
    machine = "coop-0a1b2c3d-00000000000000aa"
    path, fake = fake_state(home)
    sandbox = fake["sandboxes"][machine]
    prior = {"cpus": sandbox["cpus"], "memory_bytes": sandbox["memoryBytes"]}
    sandbox["cpus"] = 4
    sandbox["lastOperation"] = "coop-00000000000000f1"
    path.write_text(json.dumps(fake, indent=2))
    write_journal(home / STATE / "instances" / "alpha", machine,
                  {"kind": "set-resources", "operation": "coop-00000000000000f1", "prior": prior})


def seed_restore_journal(home):
    """A restore that never reached the runtime."""
    machine = "coop-0a1b2c3d-00000000000000aa"
    _, fake = fake_state(home)
    write_journal(home / STATE / "instances" / "alpha", machine,
                  {"kind": "restore-disk", "operation": "coop-00000000000000f2",
                   "prior_generation": fake["sandboxes"][machine]["diskGeneration"]})


def seed_create_journal(home):
    """A create interrupted after the runtime made the sandbox."""
    machine = "coop-0a1b2c3d-00000000000000bb"
    path, fake = fake_state(home)
    alpha = fake["sandboxes"]["coop-0a1b2c3d-00000000000000aa"]
    fake["sandboxes"][machine] = dict(alpha, id=machine, status="running", lastOperation=None)
    path.write_text(json.dumps(fake, indent=2))
    instance = home / STATE / "instances" / "beta"
    instance.mkdir(parents=True)
    (instance / "instance.json").write_text(json.dumps({"name": "beta", "index": 1}))
    write_journal(instance, machine, {"kind": "create", "stage": "creating-machine"})


class Normalizer:
    """Maps generated names to stable placeholders in order of appearance."""

    def __init__(self, home):
        self.home = str(home)
        self.names = {}

    def placeholder(self, kind, value):
        key = (kind, value)
        if key not in self.names:
            self.names[key] = f"<{kind}{sum(1 for k in self.names if k[0] == kind) + 1}>"
        return self.names[key]

    def text(self, value):
        value = value.replace(self.home, "<HOME>")
        value = re.sub(r"/(?:private/)?var/folders/[^\s\"']*/T/coop-apple-(build|image|maintenance)-[A-Za-z0-9_]+",
                       lambda m: f"<TMP-{m.group(1)}>", value)
        value = re.sub(r"local/coop-0a1b2c3d:([0-9a-f]{16})-([0-9a-f]{8})",
                       lambda m: f"local/coop-0a1b2c3d:{m.group(1)}-" + self.placeholder("build", m.group(2)), value)
        value = re.sub(r"maintenance:2-([0-9a-f]{8})", lambda m: "maintenance:2-" + self.placeholder("mbuild", m.group(1)),
                       value)
        value = re.sub(r"coop-0a1b2c3d-(?!00000000000000(?:aa|bb))[0-9a-f]{16}",
                       lambda m: self.placeholder("machine", m.group(0)), value)
        value = re.sub(r"(?<![0-9a-f-])coop-[0-9a-f]{16}(?![0-9a-f])", lambda m: self.placeholder("op", m.group(0)), value)
        value = re.sub(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", "<TIME>", value)
        value = re.sub(r"sha256:[0-9a-f]{64}", lambda m: self.placeholder("digest", m.group(0)), value)
        return value


def snapshot(home, normalizer):
    """Normalized JSON state files and the set of state paths."""
    state = home / STATE
    files = {}
    for path in sorted(state.rglob("*")):
        relative = normalizer.text(str(path.relative_to(state)))
        if path.is_dir() or path.name.endswith(".log") or path.name.startswith("."):
            continue
        # The boundary audit log (selective-hardening spec §9) is a Swift-only
        # append-only record with timestamps; it has no baseline counterpart.
        if path.name == "audit.jsonl":
            continue
        if path.suffix == ".json":
            text = path.read_text()
            if path.name == "fake-state.json":
                data = json.loads(text)
                for sandbox in data["sandboxes"].values():
                    sandbox.pop("subnet", None)
                data.pop("subnet", None)
                text = json.dumps(data, sort_keys=True)
            else:
                text = json.dumps(json.loads(text), sort_keys=True)
            files[relative] = normalizer.text(text)
        elif path.suffix == ".ext4":
            files[relative] = f"<{path.stat().st_size} bytes>"
        else:
            files[relative] = "<file>"
    return files


def run(binary, home, config, argv):
    env = {"HOME": str(home), "PATH": f"{home}/bin:/usr/bin:/bin", "NO_COLOR": "1", "RUST_LOG": "off",
           "TMPDIR": os.environ.get("TMPDIR", "/tmp")}
    argv = [arg.replace("__HOME__", str(home)) for arg in argv]
    result = subprocess.run([binary, "--config", str(config), *argv], capture_output=True, text=True, env=env,
                            timeout=300)
    return result.returncode, result.stdout, result.stderr


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--golden", type=Path, default=GOLDEN, help=f"recorded baseline results (default {GOLDEN.relative_to(ROOT)})")
    parser.add_argument("--swift", required=True)
    args = parser.parse_args()
    golden = json.loads(args.golden.read_text())
    failures = []
    with tempfile.TemporaryDirectory(prefix="coop-lifecycle-") as base:
        # A fixed synthetic key: it feeds manifest ids and build contexts, so
        # the results stay comparable with the recorded baseline.
        key_dir = Path(base) / "key"
        key_dir.mkdir()
        for name in ["vm_key", "vm_key.pub"]:
            shutil.copy2(ROOT / "tests/fixtures/lifecycle-key" / name, key_dir / name)
        (key_dir / "vm_key").chmod(0o600)
        home, config = make_home(base, "swift", key_dir, CONFIG_JSONC, "config.jsonc")
        binary = os.path.abspath(args.swift)
        normalizer = Normalizer(home)
        for label, argv, hook in STEPS:
            if hook:
                {"seed": seed_instance, "journal-set": seed_set_journal, "journal-restore": seed_restore_journal,
                 "journal-create": seed_create_journal, "devcontainer": seed_devcontainer}[hook](home)
                print(f"--    {label}")
                continue
            swift = run(binary, home, config, argv)
            log = home / "bin" / "calls.log"
            calls = [normalizer.text(line) for line in log.read_text().splitlines()] if log.exists() else []
            log.unlink(missing_ok=True)
            state = snapshot(home, normalizer)
            expected = golden["steps"][label]
            problems = []
            if (expected["exit"] == 0) != (swift[0] == 0):
                problems.append(f"exit baseline={expected['exit']} swift={swift[0]}")
            if expected["stdout"] != normalizer.text(swift[1]):
                problems.append("stdout differs")
            if expected["calls"] != calls and label not in EXPECTED_CALL_DIFFERENCES:
                problems.append("runtime calls differ")
            if expected["state"] != state:
                problems.append("state differs")
            if problems:
                failures.append(label)
                print(f"FAIL  {label}: {', '.join(problems)}")
                print("  swift stderr: " + swift[2].strip()[-600:])
                if "runtime calls differ" in problems:
                    for index in range(max(len(expected["calls"]), len(calls))):
                        b = expected["calls"][index] if index < len(expected["calls"]) else "-"
                        s = calls[index] if index < len(calls) else "-"
                        if b != s:
                            print(f"  call {index}:\n    baseline {b}\n    swift    {s}")
                            break
                if "state differs" in problems:
                    for key in sorted(set(expected["state"]) | set(state)):
                        if expected["state"].get(key) != state.get(key):
                            print(f"  {key}:\n    baseline {expected['state'].get(key)}\n    swift    {state.get(key)}")
                if "stdout differs" in problems:
                    print("  baseline stdout: " + expected["stdout"][-400:] + "\n  swift stdout: " + swift[1][-400:])
            else:
                note = f"; expected call difference: {EXPECTED_CALL_DIFFERENCES[label]}" if (
                    expected["calls"] != calls) else ""
                print(f"ok    {label} (exit {expected['exit']}{note})", flush=True)
        directory = home / "bin" / "contexts"
        contexts = {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sorted(directory.rglob("*")) if p.is_file()} if directory.exists() else {}
        baseline_contexts = golden["contexts"]
        if baseline_contexts != contexts or not baseline_contexts:
            failures.append("build contexts")
            print("FAIL  build contexts differ:", sorted(set(baseline_contexts) ^ set(contexts)) or
                  [k for k in baseline_contexts if baseline_contexts[k] != contexts.get(k)])
        else:
            print(f"ok    build contexts identical ({len(contexts)} files)")
    print(f"\n{len(STEPS) - 1 - len([f for f in failures if f != 'build contexts'])}/{len(STEPS) - 1} steps match")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
