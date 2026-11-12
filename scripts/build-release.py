#!/usr/bin/env python3
"""Build the iso release archive: the one release entrypoint (spec S-05).

    python3 scripts/build-release.py [--release] [--test] [--tag vX.Y.Z]
                                     [--expected-revision SHA] [--sign]
                                     [--desktop-kernel DIR] [--out DIR]

Stages, in order, each explicit:

1. source   copy the tracked (and untracked, unignored) files of this checkout
            into a private staging directory and stamp the revision into
            Sources/IsoHost/Update/BuildRevision.swift there. The working tree is
            never modified. `--expected-revision` requires a clean checkout
            of exactly that commit, before and after the build.
2. build    the Swift host (`iso`), the credential proxy (`iso-proxy`),
            the filtered-egress companion (`iso-egress`), and the Apple
            runtime (`iso-sandbox`, with the macOS guest agent
            `iso-macos-helper`), plus the Linux `desktop` images' guest
            files: `iso-cu-mcp` (Static Linux SDK) and `vmlinux-desktop`
            (scripts/build-desktop-kernel.sh, which fetches the pinned Linux
            source and needs Apple `container`). `--desktop-kernel DIR`
            takes that script's output from DIR instead of running it: the
            release workflows build the kernel on an arm64 Linux runner,
            because GitHub's hosted macOS runners cannot start the
            `container` build VM. Either way the kernel must be one
            KernelPin.desktopAllowed pins, and a prebuilt one must come
            with the pinned source tarball. Every macOS binary is signed ad hoc with the
            hardened runtime and the Enhanced Security entitlements
            (scripts/enhanced-security.entitlements; iso-sandbox's come from
            iso-sandbox/iso-sandbox.entitlements, signed by
            scripts/build-iso-sandbox.sh). `--release` builds
            with optimizations and `-D ISO_RELEASE_BUILD`, which makes
            `iso update` treat the binary as a release.
3. test     (`--test`) every package's tests in the staging copy.
4. sign     (`--sign`) Developer ID signing and notarization through
            scripts/macos-sign-notarize.sh. Only this stage sees the
            MACOS_*/NOTARY_* secrets (also checked before staging); every
            other subprocess has them removed.
5. archive  `iso-<name>-aarch64-apple-darwin.tar.gz` holding the directory
            `iso-<name>-aarch64-apple-darwin/` (iso, iso-proxy,
            iso-egress, iso-sandbox, iso-macos-helper, iso-cu-mcp,
            vmlinux-desktop, legal notices,
            the skills/iso agent skill, BUILD.json), the desktop kernel's
            corresponding source as `iso-<name>-vmlinux-desktop-source.tar.gz`,
            and a `SHA256SUMS` listing both, next to it in `--out`. `<name>` is `--tag`, else the
            revision. This is the layout `iso update` and install.sh expect.

Nothing is published or uploaded; publication and attestation belong to the
workflow that runs this.
"""

import argparse
import hashlib
import io
import json
import os
import platform
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRIPLE = "aarch64-apple-darwin"
BINARIES = ["iso", "iso-proxy", "iso-egress", "iso-sandbox", "iso-macos-helper"]
# Signed here; build-iso-sandbox.sh signs iso-sandbox and iso-macos-helper.
ADHOC_SIGNED = ["iso", "iso-proxy", "iso-egress"]
# Linux guest files (ELF, not codesigned): checked by content instead.
LINUX_GUEST_FILES = ["iso-cu-mcp", "vmlinux-desktop"]
ENTITLEMENTS = "scripts/enhanced-security.entitlements"
SKILL = Path("skills/iso")
# Private entitlements need AMFI relaxed on the host; the experimental
# iso-sandbox-coreai build that carries one is never released
# (docs/design/paravirtualized-coreai.md).
PRIVATE_ENTITLEMENT_PREFIX = "com.apple.private."
UNRELEASED = ["iso-sandbox-coreai", "iso-sandbox-coreai.entitlements"]
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
    source = (ROOT / "Sources/IsoHost/Update/UpdateVersion.swift").read_text()
    marker = 'package static let packageVersion = "'
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
    revision_file = staging / "Sources/IsoHost/Update/BuildRevision.swift"
    text = revision_file.read_text()
    stamped = text.replace("package let buildRevision: String? = nil",
                           f"package let buildRevision: String? = {json.dumps(stamp)}")
    if stamped == text:
        raise SystemExit("Sources/IsoHost/Update/BuildRevision.swift no longer has the stamp anchor")
    revision_file.write_text(stamped)


def copy_desktop_kernel(directory, source, destination):
    """The output of scripts/build-desktop-kernel.sh, built elsewhere: the
    pinned kernel and the pinned Linux tarball, with both configurations."""
    pins = desktop_kernel_source_pins(source)
    tarball = f"linux-{pins['KVER']}.tar.xz"
    names = ["vmlinux-desktop", "vmlinux-desktop.config", "vmlinux-desktop.input.config", tarball]
    for name in names:
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise SystemExit(f"--desktop-kernel has no {name}")
    kernel = sha256(directory / "vmlinux-desktop")
    if kernel not in desktop_kernel_pins(source):
        raise SystemExit(f"vmlinux-desktop (sha256 {kernel}) is not a pinned desktop kernel")
    if sha256(directory / tarball) != pins["SOURCE_SHA256"]:
        raise SystemExit(f"{tarball} is not the pinned Linux source")
    destination.mkdir(parents=True, exist_ok=True)
    for name in names:
        shutil.copy2(directory / name, destination / name)


def build(staging, configuration, release, prefix, desktop_kernel=None):
    if desktop_kernel is not None:
        # Before the Swift builds: a wrong kernel fails in seconds.
        phase("Check the prebuilt desktop kernel")
        copy_desktop_kernel(desktop_kernel, staging, prefix / "kernel")
    phase("Build iso (Swift host)")
    flags = ["-Xswiftc", "-DISO_RELEASE_BUILD"] if release else []
    common = ["-c", configuration, "--force-resolved-versions"]
    run(["swift", "build", *common, "--product", "iso", *flags], staging)
    host = Path(run(["swift", "build", *common, "--show-bin-path"], staging, capture=True).strip())
    phase("Build iso-proxy")
    proxy_package = staging / "iso-proxy"
    run(["swift", "build", "--package-path", proxy_package, *common], staging)
    proxy = Path(run(["swift", "build", "--package-path", proxy_package, *common, "--show-bin-path"],
                     staging, capture=True).strip())
    phase("Build iso-egress")
    egress_package = staging / "iso-egress"
    run(["swift", "build", "--package-path", egress_package, *common], staging)
    egress = Path(run(["swift", "build", "--package-path", egress_package, *common, "--show-bin-path"],
                      staging, capture=True).strip())
    phase("Build and ad-hoc sign iso-sandbox and iso-macos-helper; build iso-cu-mcp")
    run([staging / "scripts/build-iso-sandbox.sh", "--require-cu-mcp", prefix], staging)
    if desktop_kernel is None:
        phase("Build the desktop kernel")
        run([staging / "scripts/build-desktop-kernel.sh", prefix / "kernel"], staging)
    return {
        "iso-cu-mcp": prefix / "bin/iso-cu-mcp",
        "vmlinux-desktop": prefix / "kernel/vmlinux-desktop",
        "iso": host / "iso",
        "iso-proxy": proxy / "iso-proxy",
        "iso-egress": egress / "iso-egress",
        "iso-sandbox": prefix / "bin/iso-sandbox",
        "iso-macos-helper": prefix / "bin/iso-macos-helper",
    }


def test(staging):
    phase("Test iso (Swift host)")
    run(["swift", "test", "--force-resolved-versions"], staging)
    phase("Test iso-policy")
    run(["swift", "test", "--package-path", staging / "iso-policy", "--force-resolved-versions"], staging)
    phase("Test iso-proxy")
    run(["swift", "test", "--package-path", staging / "iso-proxy", "--force-resolved-versions"], staging)
    phase("Test iso-egress")
    run(["swift", "test", "--package-path", staging / "iso-egress", "--force-resolved-versions"], staging)
    phase("Test iso-sandbox")
    run(["swift", "test", "--package-path", staging / "iso-sandbox", "--no-parallel"], staging)


def adhoc_sign(directory, entitlements):
    for name in ADHOC_SIGNED:
        run(["codesign", "--force", "--sign", "-", "--options", "runtime",
             "--entitlements", entitlements, directory / name], directory)


def signed_entitlements(path, directory):
    signed = run(["codesign", "--display", "--entitlements", "-", "--xml", path], directory,
                 capture=True)
    return plistlib.loads(signed.encode()) if signed.strip() else {}


def check_entitlements(name, granted, required):
    """Every required entitlement, and no private one."""
    missing = sorted(key for key, value in required.items() if granted.get(key) != value)
    if missing:
        raise SystemExit(f"{name} is not signed with {', '.join(missing)}")
    private = sorted(key for key in granted if key.startswith(PRIVATE_ENTITLEMENT_PREFIX))
    if private:
        raise SystemExit(f"{name} carries private entitlement(s) {', '.join(private)}")


def verify(directory, expected_version, source):
    """Check the bundle against `source`, the tree it was built from."""
    required = plistlib.loads((source / ENTITLEMENTS).read_bytes())
    for name in UNRELEASED:
        if (directory / name).exists():
            raise SystemExit(f"{name} must never be in a release")
    for name in BINARIES:
        path = directory / name
        if not (path.is_file() and os.access(path, os.X_OK)):
            raise SystemExit(f"{name} is missing or not executable")
        run(["codesign", "--verify", "--strict", path], directory)
        check_entitlements(name, signed_entitlements(path, directory), required)
    verify_linux_guest_files(directory, source)
    version = run([directory / "iso", "--version"], directory, capture=True).strip()
    if version != expected_version:
        raise SystemExit(f"expected `iso --version` to print {expected_version!r}, got {version!r}")
    run([directory / "iso-sandbox", "version"], directory, capture=True)


def desktop_kernel_pins(source):
    """The SHA-256s in KernelPin.desktopAllowed (iso-sandbox Layout.swift)."""
    layout = (source / "iso-sandbox/Sources/IsoSandboxCore/Layout.swift").read_text()
    block = layout[layout.index("package static let desktopAllowed"):]
    block = block[:block.index("]")]
    return {line.strip().strip('",') for line in block.splitlines()
            if line.strip().startswith('"') and len(line.strip().strip('",')) == 64}


def desktop_kernel_source_pins(source):
    """The Linux version, tarball URL and hashes scripts/build-desktop-kernel.sh pins."""
    script = (source / "scripts/build-desktop-kernel.sh").read_text()
    pins = {key: script.split(f"{key}=", 1)[1].split("\n", 1)[0].strip('"')
            for key in ("KVER", "SOURCE_URL", "SOURCE_SHA256", "BASE_CONFIG_SHA256")}
    pins["SOURCE_URL"] = pins["SOURCE_URL"].replace("${KVER}", pins["KVER"])
    return pins


def verify_linux_guest_files(directory, source):
    """An arm64 Linux executable, and the pinned desktop kernel."""
    mcp = (directory / "iso-cu-mcp").read_bytes()
    if not (mcp[:6] == b"\x7fELF\x02\x01" and mcp[18:20] == b"\xb7\x00"):
        raise SystemExit("iso-cu-mcp is not an arm64 Linux executable")
    kernel = sha256(directory / "vmlinux-desktop")
    if kernel not in desktop_kernel_pins(source):
        raise SystemExit(f"vmlinux-desktop (sha256 {kernel}) is not a pinned desktop kernel")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_legal_files(staging, bundle):
    """Ship project attribution and the licenses of the pinned build inputs."""
    for relative in ("LICENSE", "NOTICE", "PROVENANCE.md", "THIRD_PARTY_LICENSES.md",
                     "fuzz/libfuzzer/LICENSE.TXT"):
        destination = bundle / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(staging / relative, destination)
    # iso-egress has no external dependencies and no Package.resolved.
    for package in (Path("."), Path("iso-proxy"), Path("iso-sandbox")):
        resolved = json.loads((staging / package / "Package.resolved").read_text())
        for pin in resolved["pins"]:
            checkout = staging / package / ".build/checkouts" / pin["identity"]
            legal = sorted(p for p in checkout.rglob("*") if p.is_file()
                           and p.name.upper().startswith(("LICENSE", "LICENCE", "NOTICE", "COPYING")))
            if not any(p.parent == checkout and p.name.upper().startswith(("LICENSE", "LICENCE", "COPYING"))
                       for p in legal):
                raise SystemExit(f"missing dependency license: {package}/{pin['identity']}")
            destination = bundle / "third-party" / (package.name or "host") / pin["identity"]
            destination.mkdir(parents=True, exist_ok=True)
            (destination / "SOURCE.json").write_text(json.dumps(pin, indent=2) + "\n")
            for source in legal:
                target = destination / source.relative_to(checkout)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)


def copy_linux_guest_legal(prefix, staging, bundle):
    """The Linux guest files' notices: the Static Linux SDK's SBOM for
    iso-cu-mcp, and the desktop kernel's configuration and source pins
    (GPL-2.0; PROVENANCE.md)."""
    mcp = bundle / "third-party" / "iso-cu-mcp"
    mcp.mkdir(parents=True, exist_ok=True)
    shutil.copy2(prefix / "bin/iso-cu-mcp.sbom.spdx.json", mcp / "sbom.spdx.json")
    kernel = bundle / "third-party" / "vmlinux-desktop"
    kernel.mkdir(parents=True, exist_ok=True)
    shutil.copy2(prefix / "kernel/vmlinux-desktop.config", kernel / "config")
    pins = desktop_kernel_source_pins(staging)
    pins["license"] = "GPL-2.0-only WITH Linux-syscall-note"
    pins["source_asset"] = source_asset_name(bundle.name)
    (kernel / "SOURCE.json").write_text(json.dumps(pins, indent=2) + "\n")


def source_asset_name(bundle_name):
    """The release asset with the desktop kernel's corresponding source."""
    return bundle_name.removesuffix(f"-{TRIPLE}") + "-vmlinux-desktop-source.tar.gz"


def write_kernel_source(prefix, staging, destination):
    """The desktop kernel's corresponding source (GPL-2.0 §3): the exact Linux
    tarball, the configuration it was built with, and the scripts and build
    image that build it, as one archive published beside the release."""
    root = destination.name.removesuffix(".tar.gz")
    version = desktop_kernel_source_pins(staging)["KVER"]
    tarball = f"linux-{version}.tar.xz"
    members = {
        tarball: prefix / "kernel" / tarball,
        "vmlinux-desktop.input.config": prefix / "kernel/vmlinux-desktop.input.config",
        "vmlinux-desktop.config": prefix / "kernel/vmlinux-desktop.config",
        "scripts/build-desktop-kernel.sh": staging / "scripts/build-desktop-kernel.sh",
        "iso-sandbox/kernel/desktop.config": staging / "iso-sandbox/kernel/desktop.config",
        "iso-sandbox/kernel/build.sh": staging / "iso-sandbox/kernel/build.sh",
        "iso-sandbox/kernel/Dockerfile": staging / "iso-sandbox/kernel/Dockerfile",
    }
    readme = (f"The corresponding source of vmlinux-desktop (Linux {version}, GPL-2.0-only\n"
              f"WITH Linux-syscall-note) in this iso release. {tarball} is the\n"
              "unmodified upstream tarball; vmlinux-desktop.input.config is the\n"
              "configuration given to `make olddefconfig`, vmlinux-desktop.config the result.\n"
              "From an iso checkout, scripts/build-desktop-kernel.sh --source\n"
              f"{tarball} OUT rebuilds it.\n")
    with tarfile.open(destination, "w:gz") as tar:
        info = tarfile.TarInfo(f"{root}/README")
        info.size = len(readme.encode())
        tar.addfile(info, io.BytesIO(readme.encode()))
        for name, source in members.items():
            info = tar.gettarinfo(source, arcname=f"{root}/{name}")
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            with source.open("rb") as handle:
                tar.addfile(info, handle)


def copy_skill(staging, bundle):
    """Ship the host agent skill (docs/agent-skill.md) inside the verified archive."""
    source = staging / SKILL
    if source.is_symlink() or not (source / "SKILL.md").is_file():
        raise SystemExit(f"missing agent skill: {SKILL}/SKILL.md")
    links = sorted(str(p.relative_to(staging)) for p in source.rglob("*") if p.is_symlink())
    if links:
        raise SystemExit(f"agent skill must not contain symlinks: {', '.join(links)}")
    shutil.copytree(source, bundle / SKILL)


def archive_bundle(bundle, destination):
    with tarfile.open(destination, "w:gz") as tar:
        for entry in sorted(bundle.rglob("*")):
            info = tar.gettarinfo(entry, arcname=f"{bundle.name}/{entry.relative_to(bundle)}")
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            if info.isfile():
                with entry.open("rb") as handle:
                    tar.addfile(info, handle)
            else:
                tar.addfile(info)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--release", action="store_true", help="optimized release build (-D ISO_RELEASE_BUILD)")
    parser.add_argument("--test", action="store_true", help="run every package's tests before archiving")
    parser.add_argument("--tag", help="release tag vX.Y.Z; must match the package version")
    parser.add_argument("--expected-revision", help="require this exact clean revision before and after")
    parser.add_argument("--sign", action="store_true", help="Developer ID sign and notarize (needs MACOS_*/NOTARY_* secrets)")
    parser.add_argument("--desktop-kernel", type=Path, metavar="DIR",
                        help="a scripts/build-desktop-kernel.sh output directory to use instead of building the kernel")
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
    if args.sign:
        phase("Check signing and notarization environment")
        run([ROOT / "scripts/macos-sign-notarize.sh", "--check-env"], ROOT, signing=True)
    stamp = revision[:7] + ("+dirty" if dirty else "")
    expected_version = f"iso {version} ({stamp})" if args.release else f"iso {version}-dev ({stamp})"
    configuration = "release" if args.release else "debug"
    name = f"iso-{args.tag or revision[:12]}-{TRIPLE}"
    args.out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="iso-release-") as work:
        work = Path(work)
        staging = work / "src"
        phase(f"Stage source at {revision[:12]}{' (dirty)' if dirty else ''}")
        stage_source(staging, stamp)
        binaries = build(staging, configuration, args.release, work / "runtime",
                         args.desktop_kernel and args.desktop_kernel.resolve())
        if args.test:
            test(staging)
        bundle = work / "bundle" / name
        bundle.mkdir(parents=True)
        for binary, source in binaries.items():
            shutil.copy2(source, bundle / binary)
        copy_legal_files(staging, bundle)
        copy_linux_guest_legal(work / "runtime", staging, bundle)
        copy_skill(staging, bundle)
        phase("Ad-hoc sign iso, iso-proxy and iso-egress")
        adhoc_sign(bundle, staging / ENTITLEMENTS)
        if args.sign:
            phase("Sign and notarize (Developer ID)")
            run([ROOT / "scripts/macos-sign-notarize.sh", bundle], work, signing=True)
        phase("Verify binaries")
        verify(bundle, expected_version, staging)
        manifest = {
            "format": 1, "name": name, "version": version, "tag": args.tag,
            "configuration": configuration, "release_build": args.release,
            "source_revision": revision, "source_dirty": dirty,
            "architecture": "arm64", "minimum_macos": "27.0",
            "binaries": {binary: sha256(bundle / binary) for binary in BINARIES},
            "linux_guest_files": {name: sha256(bundle / name) for name in LINUX_GUEST_FILES},
            "tested": args.test, "developer_id_signed": args.sign,
        }
        (bundle / "BUILD.json").write_text(json.dumps(manifest, indent=2) + "\n")
        source_state(args.expected_revision)  # unchanged during the build

        phase("Archive")
        archive = args.out / f"{name}.tar.gz"
        staged = args.out / f".{name}.tar.gz.partial"
        archive_bundle(bundle, staged)
        os.replace(staged, archive)
        phase("Archive the desktop kernel's source")
        source_asset = args.out / source_asset_name(name)
        write_kernel_source(work / "runtime", staging, source_asset)
        (args.out / "SHA256SUMS").write_text(
            f"{sha256(archive)}  {archive.name}\n{sha256(source_asset)}  {source_asset.name}\n")
        print(f"{archive}\n{source_asset}\n{args.out / 'SHA256SUMS'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
