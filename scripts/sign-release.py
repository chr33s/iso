#!/usr/bin/env python3
"""Sign a draft release's SHA256SUMS with a maintainer SSH key and publish it.

    python3 scripts/sign-release.py vX.Y.Z [--key PUBKEY] [--no-publish]

release.yml publishes every release as a draft, because CI never holds the
release signing key. This script, run by a maintainer:

1. requires the release to still be a draft;
2. downloads its tarballs, SHA256SUMS and attestations.jsonl, and checks that
   SHA256SUMS lists exactly the published tarballs with matching digests and
   that each tarball's attestation verifies with the same signer pin
   `iso update` uses, bound to the commit the tag names both on GitHub and
   in this checkout (`--source-digest`) — so the key only ever signs what
   release.yml built from the commit the maintainer has locally;
3. signs SHA256SUMS with `ssh-keygen -Y sign` (the private key stays in the
   ssh-agent, e.g. 1Password or the Secure Enclave), then verifies the result
   against .github/release-signers;
4. uploads SHA256SUMS.sig and publishes the release (skipped by --no-publish),
   then checks that GitHub's recorded asset digests still match what was
   signed.

--key names the public key file of the signer to use; the default is the
first key in .github/release-signers, read from a matching ~/.ssh/*.pub when
there is one so that a key not loaded in an agent can sign from its file.
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


def default_key(work):
    """The first listed signer's public key file.

    A matching ~/.ssh/*.pub is preferred: ssh-keygen tries the agent first and
    then the private key beside it, so a passphrase-protected key that is not
    loaded in an agent still signs. Otherwise the key is written to `work`,
    which only an agent holding the private key can sign with.
    """
    wanted = signer_keys()[0]
    for pub in sorted((Path.home() / ".ssh").glob("*.pub")):
        try:
            fields = pub.read_text().split()
        except OSError:
            continue
        if " ".join(fields[:2]) == wanted:
            return pub
    key = work / "signer.pub"
    key.write_text(wanted + "\n")
    return key


SUMS_LINE = re.compile(r"([0-9a-f]{64})  ([^\s*][^\n]*)\n")


def check_checksums(directory, tarballs):
    """SHA256SUMS must be exactly `sha256sum`'s output for `tarballs`: one
    canonical line per tarball, nothing else. Parsers disagree on which of
    two entries for one name wins, so a duplicate, blank, comment or
    otherwise non-canonical line is refused rather than interpreted."""
    text = (directory / "SHA256SUMS").read_text()
    listed = {}
    lines = text.splitlines(keepends=True)
    for line in lines:
        match = SUMS_LINE.fullmatch(line)
        if not match:
            die(f"SHA256SUMS has a non-canonical line: {line!r}")
        digest, name = match.groups()
        if name in listed:
            die(f"SHA256SUMS lists {name} more than once")
        listed[name] = digest
    if set(listed) != set(tarballs):
        die(f"SHA256SUMS lists {sorted(listed)}, release has {sorted(tarballs)}")
    for name in tarballs:
        actual = hashlib.sha256((directory / name).read_bytes()).hexdigest()
        if actual != listed[name]:
            die(f"{name}: SHA256SUMS says {listed[name]}, downloaded {actual}")


def check_published(tag, expected):
    """The release's asset digests, as GitHub records them, match what was
    checked and signed. Releases are mutable, so an asset swapped after the
    check is reported rather than left behind a valid signature."""
    release = json.loads(run(
        "gh", "api", f"repos/{REPO}/releases/tags/{tag}", capture=True))
    published = {asset["name"]: asset.get("digest") for asset in release["assets"]}
    for name, digest in expected.items():
        if published.get(name) != f"sha256:{digest}":
            die(f"{tag}: published {name} has digest {published.get(name)}, "
                f"signed sha256:{digest}; investigate before announcing the release")


def tag_commit(tag):
    """The commit `tag` names on GitHub, which must equal the local tag's.

    A tag moved on GitHub after the maintainer reviewed it, or a local tag that
    was never fetched, stops signing: the attestation is then checked against
    the exact commit the maintainer holds.
    """
    remote = run("gh", "api", f"repos/{REPO}/commits/{tag}", "--jq", ".sha",
                 capture=True).strip()
    try:
        local = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--verify", "--quiet",
             f"refs/tags/{tag}^{{commit}}"],
            check=True, text=True, stdout=subprocess.PIPE).stdout.strip()
    except subprocess.CalledProcessError:
        die(f"{tag} is not a local tag; run `git fetch --tags` and review it first")
    if not re.fullmatch(r"[0-9a-f]{40}", remote) or remote != local:
        die(f"{tag} names {remote or 'nothing'} on GitHub but {local} locally")
    return remote


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

    commit = tag_commit(args.tag)
    print(f"{args.tag} -> {commit}")

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
                "--source-ref", f"refs/tags/{args.tag}", "--source-digest", commit,
                "--deny-self-hosted-runners",
                "--bundle", str(work / "attestations.jsonl"))

        signed = {name: hashlib.sha256((work / name).read_bytes()).hexdigest()
                  for name in tarballs + ["SHA256SUMS"]}
        key = args.key or default_key(work)
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
    check_published(args.tag, signed)
    print(f"Signed and published {args.tag}")


if __name__ == "__main__":
    main()
