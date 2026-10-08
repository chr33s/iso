#!/usr/bin/env python3
"""Check that every published release carries a valid SHA256SUMS.sig.

    python3 scripts/check-release-signatures.py

release.yml stops at a draft, and sign-release.py signs it before publishing.
A draft published any other way ships without the signature install.sh and
`iso update` require, and nothing else notices. This lists the published
releases, downloads each one's SHA256SUMS and SHA256SUMS.sig, and verifies the
signature against .github/release-signers. It exits 1 if any release fails.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "chr33s/iso"
NAMESPACE = "release-sums@chr33s"
SIGNERS = ROOT / ".github" / "release-signers"


def published_tags():
    out = subprocess.run(
        ["gh", "release", "list", "--repo", REPO, "--exclude-drafts",
         "--limit", "1000", "--json", "tagName"],
        check=True, capture_output=True, text=True).stdout
    return [release["tagName"] for release in json.loads(out)]


def download(tag, name, directory):
    result = subprocess.run(
        ["gh", "release", "download", tag, "--repo", REPO, "--pattern", name,
         "--dir", str(directory)],
        capture_output=True)
    return result.returncode == 0 and (directory / name).is_file()


def check_release(tag, directory, signers=SIGNERS):
    """Return why `tag`'s signature is unacceptable, or None."""
    for name in ("SHA256SUMS", "SHA256SUMS.sig"):
        if not download(tag, name, directory):
            return f"could not download {name}"
    with (directory / "SHA256SUMS").open("rb") as message:
        result = subprocess.run(
            ["ssh-keygen", "-Y", "verify", "-f", str(signers), "-I", "release",
             "-n", NAMESPACE, "-s", str(directory / "SHA256SUMS.sig")],
            stdin=message, capture_output=True)
    if result.returncode != 0:
        return "SHA256SUMS.sig is not a valid signature by a release signer"
    return None


def main():
    failures = 0
    tags = published_tags()
    for tag in tags:
        with tempfile.TemporaryDirectory() as scratch:
            problem = check_release(tag, Path(scratch))
        if problem:
            failures += 1
            print(f"FAIL {tag}: {problem}", file=sys.stderr)
        else:
            print(f"ok   {tag}")
    if failures:
        print(f"{failures} of {len(tags)} published releases are not signed; "
              "see RELEASING.md#release-signing", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
