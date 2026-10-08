<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Releasing isolate

How a `iso` release is cut, and what to check before cutting one.

**Supported host and release target: macOS 27+ on Apple Silicon
(`aarch64-apple-darwin`) only.** Linux guests remain supported; Linux hosts
are outside this fork's scope.

## Fork distribution status

The installer, updater, and repository provenance checks target `chr33s/iso`.
Release tags must point to commits reachable from the `main` branch. A
release is one archive, `iso-vX.Y.Z-aarch64-apple-darwin.tar.gz`, holding
the Swift host `iso`, the credential proxy `iso-proxy`, the egress companion
`iso-egress`, and the
signed `iso-sandbox` runtime, plus `BUILD.json`, `LICENSE`, `NOTICE`,
`PROVENANCE.md`, `THIRD_PARTY_LICENSES.md`, `fuzz/libfuzzer/LICENSE.TXT`
and the pinned dependency licenses and notices under `third-party/`.

Qualify a hosted candidate from the exact revision being published. Historical
local or hosted results do not qualify a changed archive. Attestation and
candidate validation requirements are tracked in
[release validation](docs/release-validation.md).

## Building a release archive

[`scripts/build-release.py`](scripts/build-release.py) is the one release
build entrypoint. Its stages are explicit and run in order:

1. **source** — copies the tracked (and untracked, unignored) files of this
   checkout into a private staging directory and stamps the revision into
   `Sources/IsoHost/Update/BuildRevision.swift` there; the working tree is never
   modified. `--expected-revision SHA` requires a clean checkout of exactly
   that commit, before and after the build.
2. **build** — `iso` (release: optimized, `-D ISO_RELEASE_BUILD`, which makes
   `iso update` treat the binary as a release), `iso-proxy`, `iso-egress`, and
   `iso-sandbox` (ad-hoc signed with its virtualization entitlement by
   `scripts/build-iso-sandbox.sh`), all with `--force-resolved-versions`.
3. **test** (`--test`) — every package's tests in the staging copy.
4. **sign** (`--sign`, requires `--release --expected-revision`) — Developer ID
   signing and notarization; see [macOS signing](#macos-signing).
5. **archive** — verifies `iso --version` and `iso-sandbox version`, writes
   `BUILD.json` (version, tag, revision, dirty flag, per-binary SHA-256,
   `tested`, `developer_id_signed`), then `iso-<tag|revision>-aarch64-apple-darwin.tar.gz`
   and `SHA256SUMS` in `--out` (default `.build/release-archive`).

```bash
python3 scripts/build-release.py                             # unsigned dev archive
python3 scripts/build-release.py --release --test --tag vX.Y.Z
```

`--tag` must equal `v` plus the package version. Nothing is published or
uploaded by the script; publication and attestation belong to the workflow
that runs it. It requires Apple Silicon macOS 27+.

## Automation

- **`ci.yml`** runs on pushes and pull requests: the Swift host
  format/build/test gates and Python host checks, fuzz corpus replay and a
  bounded smoke, the `iso-proxy` and `iso-sandbox` package tests, the
  host-only install/update/uninstall suites and regression scripts, and
  `zizmor`.
- **`candidate.yml`** builds a signed same-revision candidate with
  `scripts/build-release.py --release --test --sign` in the `release`
  environment and attests it.
- **`release.yml`** runs when a `v*` tag is pushed. It gates on CI, builds
  the macOS ARM64 archive, signs and notarizes it, generates `SHA256SUMS`,
  attests build provenance, extracts the `## vX.Y.Z` section from
  `CHANGELOG.md` as the release notes, and creates a **draft** GitHub
  release. **A missing CHANGELOG section fails it.**
- **`release-signatures.yml`** runs when a release is published, daily and on
  demand: [`scripts/check-release-signatures.py`](scripts/check-release-signatures.py)
  fails if any published release lacks a `SHA256SUMS.sig` that verifies
  against [`.github/release-signers`](.github/release-signers).

Pushing the tag builds the release; a maintainer's signature over its
`SHA256SUMS` publishes it (see [Release signing](#release-signing)). Everything
below is about making sure both succeed and ship something correct.

## Candidate download and verification

Run the **Release candidate** workflow (`.github/workflows/candidate.yml`)
against `main`. Its downloadable artifact is
`iso-candidate-<commit>-aarch64-apple-darwin`, containing:

- `iso-<first 12 hex digits of the commit>-aarch64-apple-darwin.tar.gz`
- `SHA256SUMS`
- `attestations.jsonl`

After unzipping the GitHub artifact, enter its directory. Set `REVISION` to the
full commit SHA from the workflow run, then verify before extracting:

The automated equivalent, run from the repository checkout, verifies the pinned
attestation before extraction, rejects unsafe archive members, checks clean build
metadata and all five executable hashes, and requires Developer ID signatures and
notarized Gatekeeper assessments before running either version command:

```bash
python3 scripts/verify-candidate.py /path/to/unzipped-artifact --revision FULL_COMMIT_SHA
```

It requires `gh` and macOS signing tools. It does not install the candidate or
qualify clean-machine lifecycle, VM isolation, or live-provider behavior. For
manual verification, use:

```bash
REVISION="FULL_COMMIT_SHA_FROM_WORKFLOW_RUN"
ARCHIVE="iso-${REVISION:0:12}-aarch64-apple-darwin.tar.gz"
shasum -a 256 -c SHA256SUMS
gh attestation verify "$ARCHIVE" \
  --repo chr33s/iso \
  --bundle attestations.jsonl \
  --signer-workflow chr33s/iso/.github/workflows/candidate.yml \
  --source-ref refs/heads/main \
  --source-digest "$REVISION"
```

After both checks succeed, extract into a fresh directory and check the bundle:

```bash
(
set -e
mkdir candidate
tar -xzf "$ARCHIVE" -C candidate
cd "candidate/iso-${REVISION:0:12}-aarch64-apple-darwin"
for binary in iso iso-proxy iso-egress iso-sandbox; do
  codesign --verify --strict "$binary"
done
cat BUILD.json
./iso --version
./iso-sandbox version
)
```

`BUILD.json` must name the expected commit in `source_revision`, with
`source_dirty: false`, `release_build: true`, `tested: true`, and
`developer_id_signed: true`, and its `binaries` digests must match the
extracted files. All five binaries stay
together. Earlier downloads retain their original archive layout and signer
workflow identity; use those original identities when verifying old artifacts.

## macOS signing

`scripts/build-release.py --sign` runs
[`scripts/macos-sign-notarize.sh`](scripts/macos-sign-notarize.sh) on the
staged bundle before `BUILD.json` and `SHA256SUMS` are written. It signs
`iso`, `iso-proxy`, `iso-egress`, and `iso-sandbox` with a Developer ID Application
certificate (hardened runtime, secure timestamp; `iso-sandbox` keeps its
virtualization entitlement), submits them to Apple's notary service, and fails
unless notarization is `Accepted`. A browser-downloaded archive then runs
without `xattr -d com.apple.quarantine`. Bare binaries cannot carry a stapled
ticket, so Gatekeeper checks notarization online on first launch.

Only the signing script sees the signing secrets; the builder removes them from
every other `main` and helper subprocess. With `--sign`, it first calls the
script's `--check-env` mode before staging or building. This checks that every
required variable is nonempty and the base64 certificate decodes to a readable
PKCS#12 file with the supplied password. Certificate trust, the signing identity,
and API key validity are checked during signing and notarization.

The signing workflows use the `release` GitHub environment, which must define these
secrets:

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_P12` | base64 of the Developer ID Application `.p12` (certificate + private key) |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `MACOS_SIGNING_IDENTITY` | exact `Developer ID Application: Name (TEAMID)` name or certificate SHA-1 |
| `NOTARY_API_KEY_P8` | base64 of an App Store Connect API key (`.p8`, Developer role) |
| `NOTARY_API_KEY_ID` | that key's ID |
| `NOTARY_API_ISSUER_ID` | the App Store Connect issuer ID |

A missing secret fails the release, which burns the version, so configure the
environment before tagging.

`MACOS_CERTIFICATE_P12` must not be populated from Apple's downloaded `.cer`
file: that contains no private key. In Keychain Access, open **My Certificates**,
select the Developer ID Application identity with its private key, and export
it as a password-protected `.p12`. Populate the certificate secret from that
export and set `MACOS_CERTIFICATE_PASSWORD` to its export password:

```bash
base64 -i /path/to/DeveloperID.p12 | gh secret set MACOS_CERTIFICATE_P12 --env release --repo chr33s/iso
gh secret set MACOS_CERTIFICATE_PASSWORD --env release --repo chr33s/iso
```

The second command prompts for the password. If the identity has no private
key in Keychain Access, export it from the Mac that created the certificate
request, or create a new Developer ID Application identity. Renaming `.cer`
to `.p12` does not supply the missing key. An `Unknown format in import` error
requires checking the export and password, then rerunning the candidate after
updating the secrets.

If a candidate reports `NOTARY_API_KEY_ID is not set`, set that secret in the
repository's `release` environment to the ID of the key supplied by
`NOTARY_API_KEY_P8`, then rerun the candidate. The key ID and issuer ID are
separate values; both must be configured.

If signing reports `no identity found` or an identity mismatch, ensure
`MACOS_SIGNING_IDENTITY` exactly matches the Developer ID Application certificate
in the `.p12`, or use its SHA-1 from `security find-identity -v -p codesigning`.
The export must include its private key and a valid, trusted certificate. The
script adds its temporary keychain to the user search list for certificate-chain
lookup, resolves the configured identity to a certificate hash, and restores the
original search list on exit. It rejects missing, invalid, or ambiguous identities
before signing any binary, without logging identity names or secret values.

## Release signing

`iso update` and `install.sh` refuse a release unless `SHA256SUMS.sig` is an
`ssh-keygen -Y sign` signature over its `SHA256SUMS`, in namespace
`release-sums@chr33s`, by a key compiled into the running binary
(`ReleaseSigners.keys` in `Sources/IsoHost/Update/ReleaseSignature.swift`). The
private key is a maintainer's SSH key in their ssh-agent; it never reaches CI,
which is why `release.yml` stops at a draft.

[`scripts/sign-release.py`](scripts/sign-release.py) does the signing:

```bash
python3 scripts/sign-release.py vX.Y.Z      # --key PUB to pick a signer, --no-publish to stop before publishing
```

It requires the release to still be a draft, downloads its tarballs,
`SHA256SUMS` and `attestations.jsonl`, checks that `SHA256SUMS` lists exactly
those tarballs with matching digests and that each attestation verifies with
the same signer pin `iso update` uses, signs with the agent, verifies the
signature against [`.github/release-signers`](.github/release-signers), uploads
`SHA256SUMS.sig` and publishes the release.

The signer list is kept in three places that a test holds equal:
`ReleaseSigners.keys`, `.github/release-signers` and `ALLOWED_SIGNERS` in
`install.sh`. It is compiled in, never fetched from `github.com/<user>.keys`,
so rotating the key on GitHub changes nothing for clients.

- **Rotating a key.** Add the new key to all three places, and cut a release
  signed with a key already listed; its binary then trusts both. Sign later
  releases with the new key and drop the old one in a later release.
- **Backup key.** If every listed private key is lost, installed binaries can
  never verify another release and users must reinstall with `install.sh`.
  Keep a second, offline key (hardware token or separate Secure Enclave key)
  listed.
- **Compromised key.** Remove it and release immediately with the remaining
  key; binaries older than that release still trust it until updated.

## Withdrawing a published release

Neither signatures nor Sigstore bundles can be revoked once published. To
withdraw a bad release, add its archive digest (from its `SHA256SUMS`) to
`ReleaseRevocations.digests` in `Sources/IsoHost/Update/ReleaseSignature.swift` and
cut the next release. Updated binaries refuse the revoked archive, and
anti-rollback refuses any older release unless `--allow-downgrade` is passed.

## What runs where

| Check | CI (on PR + on tag) | Local before tagging | Manual judgement |
|-------|:---:|:---:|:---:|
| `swift format lint --strict`, build, package tests | ✓ | ✓ | |
| Python host behavior and CLI contract checks | ✓ | ✓ | |
| Fuzz corpus replay + bounded smoke | ✓ | ✓ | |
| Host-only install/update/uninstall and regression suites | ✓ | ✓ | |
| Version ↔ CHANGELOG ↔ tag agreement | | ✓ (`build-release.py --tag`, preflight) | |
| Release archive (`build-release.py --release --test`) | | ✓ | |
| Sanitizer runs (`--sanitize=address/thread/undefined`) | | ✓ | when host code changed |
| Fault injection (`scripts/swift-host-fault-injection.py`) | | ✓ | when security-relevant behavior changed |
| Fuzz campaigns (`scripts/fuzz.sh run`) | | opt-in | when a parser changed |
| Apple VM integration and proxy VM gates | | ✓ | Apple runtime/proxy and lifecycle behavior |

CI cannot boot VMs; the VM suites and longer campaigns run on a macOS 27+
Apple Silicon machine.

## Release checklist

1. **Land all release content on `main`.** Open PRs merged, `main` green in CI.

2. **Pick the version** (`X.Y.Z`, semver). Breaking changes → major; new
   features → minor; fixes only → patch. Look at the `## Unreleased` section of
   `CHANGELOG.md` to judge.

3. **Bump the version.** Edit `packageVersion` in
   `Sources/IsoHost/Update/UpdateVersion.swift`.

4. **Promote the changelog.** Rename `## Unreleased` to `## vX.Y.Z` in
   `CHANGELOG.md`. The text under it becomes the GitHub release notes verbatim,
   so read it as release notes. Start a fresh empty `## Unreleased` above it.

5. **Run the preflight and release build.** The preflight refuses to pass
   until the version sources agree and the tag is free:

   ```bash
   ./scripts/preflight-release.sh
   python3 scripts/build-release.py --release --test --tag vX.Y.Z
   ```

   A successful exit with warnings is incomplete validation: resolve skipped
   tools and gates before tagging.

   Run the Apple runtime and proxy VM gates on macOS 27+ Apple Silicon:

   ```bash
   ./tests/run-integration.sh
   python3 tests/integration-proxy-transition.py --controlled-upstream
   python3 tests/integration-filtered-broker-readiness.py
   ```

   The full preflight also runs the filtered VM gate; `--quick` skips it.
   This gate uses synthetic provider credentials and explicit public HTTPS
   controls, not billed provider operations.
   For failure diagnosis, use `--only brokers|egress|revocation|network` (choose
   one); a focused run does not replace the full gate. An unreachable positive
   control is a qualification failure, not evidence of isolation.

   Live-provider and guest-agent tests remain required for proxy acceptance:
   `scripts/test-proxy-live.py` per approved model, then
   `python3 tests/integration-proxy-transition.py --live-agents` with
   `--claude-model`/`--codex-model` for each approved model. Both use the
   dedicated `iso-live-*` Keychain credentials; see [testing](docs/testing.md).

6. **Run the deep checks when the diff warrants it** (slow, not CI gates):
   - `python3 scripts/swift-host-fault-injection.py` when this release changed
     security-relevant host behavior (config, credentials, workspace,
     devcontainer, subprocess/SSH, state, update).
   - `swift test --sanitize=address --scratch-path .build-asan` (and
     `thread`, `undefined`) when host code changed.
   - `scripts/fuzz.sh run <target> 600` when it changed a parser of
     user-editable input (`ParseRepoSlug`, `JSONCToJSON`, `ConfigLoad`).

7. **Open the bump PR** (`Sources/IsoHost/Update/UpdateVersion.swift`, `CHANGELOG.md`), get it
   reviewed, and merge to `main`. Never push the bump straight to `main`.

8. **Tag the merge commit and push.**

   ```bash
   git checkout main && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

   This triggers `release.yml`, which ends with a draft release.

9. **Sign and publish.** Once `release.yml` is green, with the release
   signing key in your ssh-agent:

   ```bash
   python3 scripts/sign-release.py vX.Y.Z
   ```

   Clients do not see the draft, and would refuse it unsigned, until this runs.

10. **Verify the published release.** On the GitHub release page confirm:
   - `iso-vX.Y.Z-aarch64-apple-darwin.tar.gz` containing `iso`, `iso-proxy`,
     `iso-egress`, `iso-sandbox`, the legal files listed above and `BUILD.json`, plus release-level
     `SHA256SUMS`, `SHA256SUMS.sig` and `attestations.jsonl`,
   - the build-provenance attestation is attached,
   - the binaries are notarized: after extracting the archive,
     `spctl --assess --type open --context context:primary-signature -v iso`
     reports `source=Notarized Developer ID`,
   - the notes match the `## vX.Y.Z` CHANGELOG section.

   Then smoke-test the install path with credentials stripped, so the
   credential-free bundle verification is exercised as an external user sees
   it. Pin `VERSION` to the tag you just pushed rather than relying on
   "latest":

   ```bash
   env -u GH_TOKEN -u GITHUB_TOKEN GH_CONFIG_DIR="$(mktemp -d)" \
     VERSION=vX.Y.Z INSTALL_DIR="$(mktemp -d)" bash install.sh
   ```

   The run must print `SHA256SUMS signature verified.` and
   `Attestation verified against attestations.jsonl`. A
   "Could not use `attestations.jsonl`" line instead means the bundle could not
   be downloaded — the installer cannot tell a missing asset from a failed
   download, so confirm the asset on the release page (step 10's first bullet)
   before concluding it is missing.

   For a repeatable isolated install, five-binary replacement, version/signing
   check, and CLI uninstall, run:

   ```bash
   python3 scripts/accept-release.py --version vX.Y.Z
   ```

   This uses a private HOME, GitHub config, and install directory, with provider
   credentials, GitHub tokens, proxy variables, and update-origin overrides
   stripped. The first-release path forces a same-version replacement; later
   releases can use `--from-version vA.B.C` for cross-version upgrade acceptance.
   It creates no VM and performs no provider calls. Run it on a clean supported
   Mac for clean-machine evidence; a private HOME on a development Mac alone
   does not establish that evidence. Uninstall checks the current CLI-removal
   contract; the harness then removes its private directory and companions.

## If the tag run fails

**The upstream process assumes immutable releases. Do not reuse a published version.**
Once `vX.Y.Z` is pushed, that version is spent: you cannot move or re-tag it and
re-run the release. A red `release.yml` run means you **bump to the next patch
version and cut a fresh release** — go back to step 2 with `vX.Y.(Z+1)`.

The release must pass the configured checks and build/sign/notarize the
macOS ARM64 bundle with Xcode 27. Then verify the hosted artifact's checksum,
source revision, provenance, signatures, and execution on a supported macOS
host.

Do **not** attempt `git push origin :refs/tags/vX.Y.Z` to delete and reuse a
tag — immutable releases reject it, and reusing a spent version is not allowed.
