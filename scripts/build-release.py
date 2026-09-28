#!/usr/bin/env python3
"""Build the coop release archive: the one release entrypoint (spec S-05).

    python3 scripts/build-release.py [--release] [--test] [--tag vX.Y.Z]
                                     [--expected-revision SHA] [--sign]
                                     [--out DIR]

Stages, in order, each explicit:

1. source   copy the tracked (and untracked, unignored) files of this checkout
            into a private staging directory and stamp the revision into
            Sources/CoopHost/BuildRevision.swift there. The working tree is
            never modified. `--expected-revision` requires a clean checkout
            of exactly that commit, before and after the build.
2. build    the Swift host (`coop`), the credential proxy (`coop-proxy`) and
            the Apple runtime (`coop-sandbox`, ad-hoc signed with its
            entitlement by scripts/build-coop-sandbox.sh). `--release` builds
            with optimizations and `-D COOP_RELEASE_BUILD`, which makes
            `coop update` treat the binary as a release.
3. test     (`--test`) every package's tests in the staging copy.
4. sign     (`--sign`) Developer ID signing and notarization through
            scripts/macos-sign-notarize.sh. Only this stage sees the
            MACOS_*/NOTARY_* secrets; every other subprocess has them removed.
5. archive  `coop-<name>-aarch64-apple-darwin.tar.gz` holding the directory
            `coop-<name>-aarch64-apple-darwin/` (coop, coop-proxy,
            coop-sandbox, LICENSE, BUILD.json), plus a `SHA256SUMS` listing
            the archive, next to it in `--out`. `<name>` is `--tag`, else the
            revision. This is the layout `coop update` and install.sh expect.

Nothing is published or uploaded; publication and attestation belong to the
workflow that runs this.
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIPLE = "aarch64-apple-darwin"
BINARIES = ["coop", "coop-proxy", "coop-sandbox"]
SIGNING_ENV = frozenset({
    "MACOS_CERTIFICATE_P12", "MACOS_CERTIFICATE_PASSWORD", "MACOS_SIGNING_IDENTITY",
    "NOTARY_API_KEY_P8", "NOTARY_API_KEY_ID", "NOTARY_API_ISSUER_ID",
})


def phase(message):
    print(f"==> {message}", flush=True)


def run(argv, cwd, signing=False, capture=False):
    env = None if signing else {k: v for k, v in os.environ.items() if k not in SIGNING_ENV}
    result = subprocess.run([str(a) for a in argv], cwd=cwd, env=env, check=True,
                            text=True, capture_output=capture)
    return result.stdout if capture else None


def git(*argv):
    return subprocess.check_output(["git", *argv], cwd=ROOT, text=True)


def source_state(expected_revision):
    revision = git("rev-parse", "HEAD").strip()
    dirty = bool(git("status", "--porcelain").strip())
    if expected_revision is not None and (revision != expected_revision or dirty):
        raise SystemExit("a candidate build requires a clean checkout of the exact expected revision")
    return revision, dirty


def package_version():
    source = (ROOT / "Sources/CoopHost/UpdateVersion.swift").read_text()
    marker = 'public static let packageVersion = "'
    start = source.index(marker) + len(marker)
    return source[start:source.index('"', start)]


def stage_source(staging, stamp):
    """Tracked plus untracked-unignored files; nothing from build outputs."""
    listing = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    for relative in filter(None, listing.split("\0")):
        source = ROOT / relative
        if not source.is_file() or source.is_symlink() and not source.exists():
            continue  # deleted in the working tree
        destination = staging / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination, follow_symlinks=False)
    revision_file = staging / "Sources/CoopHost/BuildRevision.swift"
    text = revision_file.read_text()
    stamped = text.replace("public let buildRevision: String? = nil",
                           f"public let buildRevision: String? = {json.dumps(stamp)}")
    if stamped == text:
        raise SystemExit("Sources/CoopHost/BuildRevision.swift no longer has the stamp anchor")
    revision_file.write_text(stamped)


def build(staging, configuration, release, prefix):
    phase("Build coop (Swift host)")
    flags = ["-Xswiftc", "-DCOOP_RELEASE_BUILD"] if release else []
    common = ["-c", configuration, "--force-resolved-versions"]
    run(["swift", "build", *common, "--product", "coop", *flags], staging)
    host = Path(run(["swift", "build", *common, "--show-bin-path"], staging, capture=True).strip())
    phase("Build coop-proxy")
    proxy_package = staging / "coop-proxy"
    run(["swift", "build", "--package-path", proxy_package, *common], staging)
    proxy = Path(run(["swift", "build", "--package-path", proxy_package, *common, "--show-bin-path"],
                     staging, capture=True).strip())
    phase("Build and ad-hoc sign coop-sandbox")
    run([staging / "scripts/build-coop-sandbox.sh", prefix], staging)
    return {
        "coop": host / "coop",
        "coop-proxy": proxy / "coop-proxy-swift",
        "coop-sandbox": prefix / "bin/coop-sandbox",
    }


def test(staging):
    phase("Test coop (Swift host)")
    run(["swift", "test", "--force-resolved-versions"], staging)
    phase("Test coop-proxy")
    run(["swift", "test", "--package-path", staging / "coop-proxy", "--force-resolved-versions"], staging)
    phase("Test coop-sandbox")
    run(["swift", "test", "--package-path", staging / "coop-sandbox", "--no-parallel"], staging)


def verify(directory, expected_version):
    for name in BINARIES:
        path = directory / name
        if not (path.is_file() and os.access(path, os.X_OK)):
            raise SystemExit(f"{name} is missing or not executable")
        run(["codesign", "--verify", "--strict", path], directory)
    version = run([directory / "coop", "--version"], directory, capture=True).strip()
    if version != expected_version:
        raise SystemExit(f"expected `coop --version` to print {expected_version!r}, got {version!r}")
    run([directory / "coop-sandbox", "version"], directory, capture=True)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--release", action="store_true", help="optimized release build (-D COOP_RELEASE_BUILD)")
    parser.add_argument("--test", action="store_true", help="run every package's tests before archiving")
    parser.add_argument("--tag", help="release tag vX.Y.Z; must match the package version")
    parser.add_argument("--expected-revision", help="require this exact clean revision before and after")
    parser.add_argument("--sign", action="store_true", help="Developer ID sign and notarize (needs MACOS_*/NOTARY_* secrets)")
    parser.add_argument("--out", type=Path, default=ROOT / ".build/release-archive")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("requires Apple Silicon macOS")
    if int(platform.mac_ver()[0].split(".")[0]) < 27:
        parser.error("requires macOS 27 or newer")
    if args.sign and not (args.release and args.expected_revision):
        parser.error("--sign requires --release and --expected-revision")
    version = package_version()
    if args.tag is not None and args.tag != f"v{version}":
        parser.error(f"--tag {args.tag} does not match the package version {version}")

    revision, dirty = source_state(args.expected_revision)
    stamp = revision[:7] + ("+dirty" if dirty else "")
    expected_version = f"coop {version} ({stamp})" if args.release else f"coop {version}-dev ({stamp})"
    configuration = "release" if args.release else "debug"
    name = f"coop-{args.tag or revision[:12]}-{TRIPLE}"
    args.out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="coop-release-") as work:
        work = Path(work)
        staging = work / "src"
        phase(f"Stage source at {revision[:12]}{' (dirty)' if dirty else ''}")
        stage_source(staging, stamp)
        binaries = build(staging, configuration, args.release, work / "runtime")
        if args.test:
            test(staging)
        bundle = work / "bundle" / name
        bundle.mkdir(parents=True)
        for binary, source in binaries.items():
            shutil.copy2(source, bundle / binary)
        shutil.copy2(ROOT / "LICENSE", bundle / "LICENSE")
        if args.sign:
            phase("Sign and notarize (Developer ID)")
            run([ROOT / "scripts/macos-sign-notarize.sh", bundle], work, signing=True)
        phase("Verify binaries")
        verify(bundle, expected_version)
        manifest = {
            "format": 1, "name": name, "version": version, "tag": args.tag,
            "configuration": configuration, "release_build": args.release,
            "source_revision": revision, "source_dirty": dirty,
            "architecture": "arm64", "minimum_macos": "27.0",
            "binaries": {binary: sha256(bundle / binary) for binary in BINARIES},
            "tested": args.test, "developer_id_signed": args.sign,
        }
        (bundle / "BUILD.json").write_text(json.dumps(manifest, indent=2) + "\n")
        source_state(args.expected_revision)  # unchanged during the build

        phase("Archive")
        archive = args.out / f"{name}.tar.gz"
        staged = args.out / f".{name}.tar.gz.partial"
        with tarfile.open(staged, "w:gz") as tar:
            for entry in sorted(bundle.iterdir()):
                info = tar.gettarinfo(entry, arcname=f"{name}/{entry.name}")
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                with entry.open("rb") as handle:
                    tar.addfile(info, handle)
        os.replace(staged, archive)
        (args.out / "SHA256SUMS").write_text(f"{sha256(archive)}  {archive.name}\n")
        print(f"{archive}\n{args.out / 'SHA256SUMS'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
