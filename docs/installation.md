<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Installation

Install a release, verify its provenance, or build all five executables from source.

## Install

The release channel is `chr33s/iso`, built from tagged commits on `main`. Its
macOS archives install `iso`, `iso-proxy`, `iso-egress`, `iso-sandbox` and
`iso-macos-helper` together; see [Apple prerequisites](backends.md). Install the
latest release:

```sh
curl -fsSL https://raw.githubusercontent.com/chr33s/iso/main/install.sh | bash
```

`install.sh` verifies the maintainer signature on the release's `SHA256SUMS`
(`SHA256SUMS.sig`), the downloaded tarball's SHA-256 against it and, when the
[GitHub CLI](https://cli.github.com/) is installed, its Sigstore
build-provenance attestation. `iso update` runs the
same verification, except that it treats the checksum as mandatory and refuses
to install without it. To verify a tarball by hand, download
`attestations.jsonl` from the same release and pass `--bundle` (this needs no
GitHub credential):

```sh
gh attestation verify iso-<version>-<triple>.tar.gz --repo chr33s/iso \
  --bundle attestations.jsonl
```

Dropping `--bundle` makes `gh` fetch the attestation from the GitHub API
instead, which it will only do when `gh` is logged in. `install.sh` and `iso
update` use that API path themselves for releases published without a usable
bundle.

## Switching from upstream

Run the fork installer to install all matching components. An upstream updater
continues to target its own repository. Fork releases use the Apple backend
only; instances created by another backend are not managed by this build.

## Build from source

With Xcode 27 installed:

```sh
git clone https://github.com/chr33s/iso.git
cd iso
python3 scripts/build-release.py --release
```

This is the one release build entrypoint. It builds `iso` (this package),
`iso-proxy`, `iso-egress`, `iso-sandbox` (ad-hoc signed with its entitlement)
and `iso-macos-helper` from a staged copy of the checkout and writes
`iso-<revision>-aarch64-apple-darwin.tar.gz` plus `SHA256SUMS` under
`.build/release-archive/`. Add `--test` to run every package's tests first.
Extract the archive and install its executables in the same directory on
`PATH`. A missing `iso-egress` blocks only filtered boots.

For a development build of the host CLI alone:

```sh
swift build --force-resolved-versions   # .build/debug/iso
```

`iso-sandbox` must still be built and installed with
`./scripts/build-iso-sandbox.sh`; see
[Apple backend setup](backends.md#macos--apple-sandbox) for prerequisites.
A source build updates by pulling and rebuilding; an installed release
updates with [`iso update`](commands.md#update) from `chr33s/iso`.


Continue with [getting started](getting-started.md#first-run).
