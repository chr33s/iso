#!/usr/bin/env python3
"""Verify a downloaded hosted candidate before executing any of its binaries.

Usage: python3 scripts/verify-candidate.py DIRECTORY --revision FULL_SHA
The directory must contain the candidate tarball, SHA256SUMS and attestations.jsonl.
This checks distribution integrity; it does not qualify VM or live-provider behavior.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import tempfile

BINARIES = ("iso", "iso-proxy", "iso-egress", "iso-sandbox")
MAX_BYTES = 2 * 1024 ** 3
MAX_MEMBERS = 4096
REPO = "chr33s/iso"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def checksum(directory, name):
    lines = (directory / "SHA256SUMS").read_text().splitlines()
    require(len(lines) == 1, "candidate must have exactly one checksum entry")
    match = re.fullmatch(r"([0-9a-f]{64})  (.+)", lines[0])
    require(match is not None and match[2] == name, "unexpected checksum entry")
    archive = directory / name
    require(archive.is_file() and not archive.is_symlink(), "archive must be a regular file")
    require(archive.stat().st_size <= MAX_BYTES, "archive exceeds size budget")
    require(digest(archive) == match[1], "archive checksum mismatch")
    return archive


def unpack(archive, destination, name):
    """Extract only bounded regular files/directories under the expected root."""
    seen = set()
    total = 0
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            path = PurePosixPath(member.name)
            require(len(seen) < MAX_MEMBERS, "archive has too many members")
            require(not path.is_absolute() and path.parts and path.parts[0] == name
                    and ".." not in path.parts and "\\" not in member.name,
                    "archive member escapes expected bundle")
            require(path not in seen, "duplicate archive member")
            seen.add(path)
            require(member.isdir() or member.isfile(), "archive contains a link or special file")
            require(member.size >= 0, "invalid archive member size")
            total += member.size
            require(total <= MAX_BYTES, "unpacked archive exceeds size budget")
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
            else:
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                with source.extractfile(member) as incoming, target.open("xb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
                target.chmod(0o700 if member.mode & 0o111 else 0o600)
    return destination / name


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate BUILD.json field")
        result[key] = value
    return result


def manifest(bundle, revision):
    path = bundle / "BUILD.json"
    require(path.stat().st_size <= 65536, "BUILD.json exceeds size budget")
    data = json.loads(path.read_text(), object_pairs_hook=unique_object)
    require(isinstance(data, dict), "BUILD.json must be an object")
    expected = {"format": 1, "name": bundle.name, "source_revision": revision,
                "source_dirty": False, "release_build": True, "tested": True,
                "developer_id_signed": True, "configuration": "release",
                "architecture": "arm64", "minimum_macos": "27.0", "tag": None}
    for key, value in expected.items():
        require(key in data and type(data[key]) is type(value) and data[key] == value,
                f"unexpected BUILD.json {key}")
    require(isinstance(data.get("version"), str) and
            re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?",
                         data["version"]), "invalid candidate version")
    hashes = data.get("binaries")
    require(isinstance(hashes, dict) and set(hashes) == set(BINARIES),
            "BUILD.json must describe all four binaries")
    for binary in BINARIES:
        path = bundle / binary
        require(path.is_file() and not path.is_symlink() and path.stat().st_mode & 0o111,
                f"missing executable: {binary}")
        require(hashes[binary] == digest(path), f"binary checksum mismatch: {binary}")
    return data


def run(*args):
    subprocess.run(args, check=True, timeout=180)


def signing(path):
    run("/usr/bin/codesign", "--verify", "--strict", path)
    identity = subprocess.run(("/usr/bin/codesign", "-d", "--verbose=4", path),
                              check=True, timeout=30, capture_output=True, text=True)
    require("Authority=Developer ID Application:" in identity.stderr,
            "binary is not Developer ID signed")
    assessment = subprocess.run(("/usr/sbin/spctl", "--assess", "--type", "open", "--context",
                                 "context:primary-signature", "--verbose=2", path),
                                check=True, timeout=180, capture_output=True, text=True)
    require("source=Notarized Developer ID" in assessment.stderr,
            "binary lacks notarized Developer ID assessment")


def verify(directory, revision):
    require(re.fullmatch(r"[0-9a-f]{40}", revision) is not None,
            "revision must be the full lowercase commit SHA")
    name = f"iso-{revision[:12]}-aarch64-apple-darwin"
    # Work on a private snapshot: validation and extraction use identical bytes.
    with tempfile.TemporaryDirectory(prefix="iso-candidate-verify-") as temporary:
        work = Path(temporary)
        for filename in (name + ".tar.gz", "SHA256SUMS", "attestations.jsonl"):
            source = directory / filename
            require(source.is_file() and not source.is_symlink(), "missing regular candidate asset")
            require(0 < source.stat().st_size <= MAX_BYTES, "invalid candidate asset size")
            shutil.copyfile(source, work / filename)
        archive = checksum(work, name + ".tar.gz")
        run("gh", "attestation", "verify", str(archive), "--repo", REPO,
            "--bundle", str(work / "attestations.jsonl"),
            "--signer-workflow", REPO + "/.github/workflows/candidate.yml",
            "--source-ref", "refs/heads/main", "--source-digest", revision)
        bundle = unpack(archive, work / "extracted", name)
        data = manifest(bundle, revision)
        for binary in BINARIES:
            signing(str(bundle / binary))
        # Execution is allowed only after every binary passes verification.
        run(str(bundle / "iso"), "--version")
        run(str(bundle / "iso-sandbox"), "version")
        print(f"PASS hosted candidate {revision}, version {data['version']}, all four binaries")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    try:
        verify(args.directory.resolve(), args.revision)
    except (ValueError, OSError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, f"candidate verification failed: {error}\n")


if __name__ == "__main__":
    main()
