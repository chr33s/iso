#!/usr/bin/env python3
"""Build local macOS transition artifacts beside an apple-container coop binary.

Rust remains the default. Select Swift only in the host launch environment with
COOP_PROXY_IMPLEMENTATION=swift. This does not install or publish release files.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def source_state(expected_revision=None):
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT))
    if expected_revision is not None and (revision != expected_revision or dirty):
        raise RuntimeError("candidate build requires a clean checkout of the exact expected revision")
    return revision, dirty


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release", action="store_true")
    parser.add_argument("--archive", type=Path, help="write a local Apple-backend transition tarball")
    parser.add_argument("--include-runtime", action="store_true", help="include the signed coop-sandbox runtime")
    parser.add_argument("--expected-revision", help="require this exact clean Git revision before and after building")
    args = parser.parse_args()
    if args.expected_revision and not (args.release and args.archive and args.include_runtime):
        parser.error("--expected-revision requires --release, --archive, and --include-runtime")
    source_state(args.expected_revision)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("requires Apple Silicon macOS")
    if int(platform.mac_ver()[0].split(".")[0]) < 27:
        parser.error("requires macOS 27 or newer")
    configuration = "release" if args.release else "debug"
    cargo_flags = ["--release"] if args.release else []
    run("cargo", "build", "--locked", "-p", "coop", "--features", "apple-container", *cargo_flags)
    run("cargo", "build", "--locked", "-p", "coop-proxy", *cargo_flags)
    package = ROOT / "macos/coop-proxy"
    run("swift", "build", "--package-path", str(package), "-c", configuration,
        "--force-resolved-versions")
    swift_bin = Path(subprocess.check_output(
        ["swift", "build", "--package-path", str(package), "-c", configuration,
         "--force-resolved-versions", "--show-bin-path"],
        cwd=ROOT, text=True).strip())
    metadata = json.loads(subprocess.check_output(
        ["cargo", "metadata", "--no-deps", "--format-version", "1"], cwd=ROOT, text=True))
    destination = Path(metadata["target_directory"]) / configuration
    # Publish each complete artifact with a rename; never expose a partial copy.
    with tempfile.TemporaryDirectory(prefix="proxy-transition-", dir=destination) as staging:
        for source, name in [(destination / "coop-proxy", "coop-proxy-rs"),
                             (swift_bin / "coop-proxy-swift", "coop-proxy-swift")]:
            staged = Path(staging) / name
            shutil.copy2(source, staged)
            os.replace(staged, destination / name)
    print(f"Built {destination}/coop with coop-proxy-rs and coop-proxy-swift")
    if args.include_runtime:
        with tempfile.TemporaryDirectory(prefix="proxy-runtime-") as prefix:
            run(str(ROOT / "scripts/build-coop-sandbox.sh"), prefix)
            shutil.copy2(Path(prefix) / "bin/coop-sandbox", destination / "coop-sandbox")
    revision, dirty = source_state(args.expected_revision)
    if args.archive:
        archive = args.archive.resolve()
        archive.parent.mkdir(parents=True, exist_ok=True)
        names = ["coop", "coop-proxy-rs", "coop-proxy-swift"]
        if args.include_runtime:
            names.append("coop-sandbox")
        checksums = []
        for name in names:
            digest = hashlib.sha256()
            with (destination / name).open("rb") as binary:
                for chunk in iter(lambda: binary.read(1024 * 1024), b""):
                    digest.update(chunk)
            checksums.append(f"{digest.hexdigest()}  {name}\n")
        manifest = {
            "format": 1, "backend": "apple-container", "architecture": "arm64",
            "minimum_macos": "27.0", "default_proxy": "rust",
            "configuration": configuration,
            "source_revision": revision, "source_dirty": dirty,
            "local_build": args.expected_revision is None,
            "includes_runtime": args.include_runtime,
        }
        # A local bundle is not a signed release or update channel. Checksums
        # detect accidental corruption; they do not establish provenance.
        with tempfile.TemporaryDirectory(prefix="proxy-archive-", dir=archive.parent) as staging:
            staged = Path(staging) / "archive.tar.gz"
            with tarfile.open(staged, "w:gz") as bundle:
                for name in names:
                    bundle.add(destination / name, arcname=f"coop-proxy-transition/{name}", recursive=False)
                bundle.add(ROOT / "LICENSE", arcname="coop-proxy-transition/LICENSE", recursive=False)
                for name, content in [
                    ("SHA256SUMS", "".join(checksums).encode()),
                    ("BUILD.json", (json.dumps(manifest, indent=2) + "\n").encode()),
                ]:
                    entry = tarfile.TarInfo(f"coop-proxy-transition/{name}")
                    entry.size = len(content)
                    entry.mode = 0o644
                    bundle.addfile(entry, io.BytesIO(content))
            os.replace(staged, archive)
        print(f"Local transition archive: {archive}")


if __name__ == "__main__":
    main()
