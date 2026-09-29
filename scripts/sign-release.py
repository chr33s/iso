#!/usr/bin/env python3
"""Sign a draft release's SHA256SUMS with a maintainer SSH key and publish it.

    python3 scripts/sign-release.py vX.Y.Z [--key PUBKEY] [--no-publish]

release.yml publishes every release as a draft, because CI never holds the
release signing key. This script, run by a maintainer:

1. requires the release to still be a draft;
2. downloads its tarballs, SHA256SUMS and attestations.jsonl, and checks that
   SHA256SUMS lists exactly the published tarballs with matching digests and
   that each tarball's attestation verifies with the same signer pin
   `iso update` uses — so the key only ever signs what release.yml built;
3. signs SHA256SUMS with `ssh-keygen -Y sign` (the private key stays in the
   ssh-agent, e.g. 1Password or the Secure Enclave), then verifies the result
   against .github/release-signers;
4. uploads SHA256SUMS.sig and publishes the release (skipped by --no-publish).

--key names the public key file of the signer to use; the default is the
first key in .github/release-signers.
"""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "chr33s/iso"
NAMESPACE = "release-sums@chr33s"
SIGNERS = ROOT / ".github" / "release-signers"
TAG = re.compile(r"^v\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")


def run(*args, stdin=None, capture=False):
    result = subprocess.run(
        list(args), stdin=stdin, check=True, text=capture,
        stdout=subprocess.PIPE if capture else None)
    return result.stdout if capture else None


def die(message):
    print(f"sign-release: {message}", file=sys.stderr)
    sys.exit(1)


def signer_keys():
    keys = []
    for line in SIGNERS.read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            keys.append(" ".join(line.split()[-2:]))
    return keys


def check_checksums(directory, tarballs):
    listed = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        listed[name.lstrip("*")] = digest.lower()
    if set(listed) != set(tarballs):
        die(f"SHA256SUMS lists {sorted(listed)}, release has {sorted(tarballs)}")
    for name in tarballs:
        actual = hashlib.sha256((directory / name).read_bytes()).hexdigest()
        if actual != listed[name]:
            die(f"{name}: SHA256SUMS says {listed[name]}, downloaded {actual}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tag")
    parser.add_argument("--key", type=Path, help="public key file of the signer")
    parser.add_argument("--no-publish", action="store_true")
    args = parser.parse_args()
    if not TAG.match(args.tag):
        die(f"{args.tag!r} is not a v-prefixed semver tag")

    view = json.loads(run(
        "gh", "release", "view", args.tag, "--repo", REPO, "--json", "isDraft,assets",
        capture=True))
    if not view["isDraft"]:
        die(f"{args.tag} is already published; signing happens before publication")
    names = [asset["name"] for asset in view["assets"]]
    if "SHA256SUMS.sig" in names:
        die(f"{args.tag} already has SHA256SUMS.sig")
    tarballs = [name for name in names if name.endswith(".tar.gz")]
    if not tarballs:
        die(f"{args.tag} has no tarballs")

    with tempfile.TemporaryDirectory() as scratch:
        work = Path(scratch)
        for name in tarballs + ["SHA256SUMS", "attestations.jsonl"]:
            run("gh", "release", "download", args.tag, "--repo", REPO, "--pattern", name,
                "--dir", str(work))
        check_checksums(work, tarballs)
        for name in tarballs:
            run("gh", "attestation", "verify", str(work / name), "--repo", REPO,
                "--cert-identity",
                f"https://github.com/{REPO}/.github/workflows/release.yml@refs/tags/{args.tag}",
                "--source-ref", f"refs/tags/{args.tag}", "--deny-self-hosted-runners",
                "--bundle", str(work / "attestations.jsonl"))

        key = args.key
        if key is None:
            key = work / "signer.pub"
            key.write_text(signer_keys()[0] + "\n")
        sums = work / "SHA256SUMS"
        run("ssh-keygen", "-Y", "sign", "-f", str(key), "-n", NAMESPACE, str(sums))
        signature = work / "SHA256SUMS.sig"
        with sums.open("rb") as message:
            run("ssh-keygen", "-Y", "verify", "-f", str(SIGNERS), "-I", "release",
                "-n", NAMESPACE, "-s", str(signature), stdin=message)

        run("gh", "release", "upload", args.tag, "--repo", REPO, str(signature))
    if args.no_publish:
        print(f"Signed {args.tag}; publish with: gh release edit {args.tag} --draft=false --latest")
        return
    run("gh", "release", "edit", args.tag, "--repo", REPO, "--draft=false", "--latest")
    print(f"Signed and published {args.tag}")


if __name__ == "__main__":
    main()
