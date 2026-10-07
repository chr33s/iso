#!/usr/bin/env python3
"""`iso` end to end on macOS guests (real hardware: macOS 27+, Apple Silicon).

    tests/macos-iso-e2e.py --ipsw FILE [--work DIR] [--keep]

Builds the iso host, iso-egress and the runtime from this checkout into
DIR (default ~/.iso-macos-e2e), runs `iso setup --guest macos` there (a
no-op once the image is current; about 25 minutes otherwise), then checks
up, exec, status, list, stop, start and destroy with open egress, and the
filtered-egress boundary. It uses its own data directory and never your
~/.iso. At most two macOS guests can run per host, so keep others stopped.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok)))
    print(f"{'PASS' if ok else 'FAIL'}  {name}{'  ' + detail if detail and not ok else ''}", flush=True)
    return ok


def build(work):
    bin_dir = work / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(ROOT / "scripts/build-iso-sandbox.sh"), str(work)], check=True)
    for package, product in [(ROOT, "iso"), (ROOT / "iso-egress", "iso-egress")]:
        subprocess.run(["swift", "build", "--package-path", str(package), "-c", "release", "--product", product],
                       check=True)
        out = subprocess.run(["swift", "build", "--package-path", str(package), "-c", "release",
                              "--show-bin-path"], check=True, capture_output=True, text=True).stdout.strip()
        shutil.copy2(Path(out) / product, bin_dir / product)
    return bin_dir


def config(work, name, extra):
    path = work / name
    path.write_text(json.dumps({
        "data_dir": str(work / "data"),
        "vm": {"vcpu_count": 4, "mem_size_mib": 8192, "template_size_gib": 64},
        "apple_container": {"binary": str(work / "bin/iso-sandbox")},
        **extra,
    }, indent=2))
    return path


class Iso:
    def __init__(self, binary, config_path, cwd):
        self.binary, self.config, self.cwd = str(binary), str(config_path), str(cwd)

    def __call__(self, *args, timeout=1800):
        r = subprocess.run([self.binary, "--config", self.config, *args], cwd=self.cwd, capture_output=True,
                           text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout, r.stderr


def open_egress(iso):
    code, _, err = iso("up", "--image", "mac", "--name", "e2e-open")
    if not check("up (open egress)", code == 0, err[-500:]):
        return
    code, out, _ = iso("exec", "e2e-open", "--", "cat", "/workspace/README.txt")
    check("workspace copied to /workspace", code == 0 and out.strip() == "hello from host", out)
    for tool in [["claude", "--version"], ["codex", "--version"], ["gh", "--version"], ["git", "--version"]]:
        code, out, _ = iso("exec", "e2e-open", "--", *tool)
        check(f"{tool[0]} present", code == 0, out[-200:])
    code, out, _ = iso("exec", "e2e-open", "--", "whoami")
    check("guest user is iso", out.strip() == "iso")
    code, out, _ = iso("status", "e2e-open")
    check("status names a macOS guest", code == 0 and "macOS guest" in out, out[-300:])
    code, out, _ = iso("list")
    check("list shows it running", code == 0 and "e2e-open" in out and "running" in out)
    code, _, err = iso("logs", "e2e-open")
    check("logs refused for macOS guests", code != 0 and "macOS guests" in err, err[-200:])
    code, _, err = iso("stop", "e2e-open")
    check("stop", code == 0, err[-300:])
    code, _, err = iso("start", "e2e-open")
    check("start (agent bootstrap)", code == 0, err[-300:])
    code, out, _ = iso("exec", "e2e-open", "--", "cat", "/workspace/README.txt")
    check("workspace survives restart", out.strip() == "hello from host")
    code, _, err = iso("destroy", "e2e-open")
    check("destroy", code == 0, err[-300:])


def filtered_egress(iso):
    code, _, err = iso("up", "--image", "mac", "--name", "e2e-filtered", "--no-agents")
    if not check("up (filtered egress)", code == 0, err[-500:]):
        return
    code, out, err = iso("exec", "e2e-filtered", "--", "curl", "-sS", "-m", "15", "https://api.github.com/zen")
    check("allowed host through the proxy", code == 0 and out.strip(), err[-300:])
    code, out, err = iso("exec", "e2e-filtered", "--", "curl", "-sS", "-m", "15", "https://example.com")
    check("other host refused by the companion", code != 0 and "403" in err, err[-300:])
    code, out, err = iso("exec", "e2e-filtered", "--", "curl", "-sS", "-m", "8", "--noproxy", "*",
                         "https://1.1.1.1")
    check("no direct route", code != 0, out[-200:])
    code, out, _ = iso("exec", "e2e-filtered", "--", "/usr/bin/dscacheutil", "-q", "host", "-a", "name",
                       "example.com")
    check("no guest DNS", "ip_address" not in out, out[-200:])
    code, _, err = iso("stop", "e2e-filtered")
    check("filtered stop", code == 0, err[-300:])
    code, _, err = iso("start", "e2e-filtered", "--no-agents")
    check("filtered start re-proves readiness", code == 0, err[-300:])
    code, out, err = iso("exec", "e2e-filtered", "--", "curl", "-sS", "-m", "15", "https://api.github.com/zen")
    check("allowed host after restart", code == 0 and out.strip(), err[-300:])
    code, _, err = iso("destroy", "e2e-filtered")
    check("filtered destroy", code == 0, err[-300:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipsw", required=True)
    ap.add_argument("--work", default=str(Path.home() / ".iso-macos-e2e"))
    ap.add_argument("--skip-build", action="store_true")
    args = ap.parse_args()
    work = Path(args.work)
    work.mkdir(mode=0o700, parents=True, exist_ok=True)
    binaries = work / "bin" if args.skip_build else build(work)
    project = Path(tempfile.mkdtemp(prefix="iso-macos-e2e-"))
    (project / "README.txt").write_text("hello from host\n")
    open_config = config(work, "config-open.jsonc", {})
    filtered_config = config(work, "config-filtered.jsonc",
                             {"egress": "filtered", "egress_filter": {"allowed_hosts": ["api.github.com"]}})
    iso = Iso(binaries / "iso", open_config, project)
    code, _, err = iso("setup", "--guest", "macos", "--ipsw", args.ipsw, "--image", "mac", timeout=4 * 3600)
    if check("setup --guest macos", code == 0, err[-800:]):
        open_egress(iso)
        filtered_egress(Iso(binaries / "iso", filtered_config, project))
        code, out, _ = iso("list")
        check("no instances left", "e2e-" not in out, out)
    shutil.rmtree(project, ignore_errors=True)
    failed = [name for name, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} passed")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    os.umask(0o077)
    main()
