# Releasing coop

How a `coop` release is cut, and what to check before cutting one.

**Supported host and release target: macOS 27+ on Apple Silicon
(`aarch64-apple-darwin`) only.** Linux guests remain supported; Linux hosts
are outside this fork's scope.

## Fork distribution status

The installer, updater, and repository provenance checks target `chr33s/coop`.
Release tags must point to commits reachable from the `swift` branch. A
release is one archive, `coop-vX.Y.Z-aarch64-apple-darwin.tar.gz`, holding
the Swift host `coop`, the Swift credential proxy `coop-proxy`, and the
signed `coop-sandbox` runtime, plus `LICENSE` and `BUILD.json`.

No hosted candidate or fork release of the Swift host has been published or
verified yet. Build from source until those gates pass. Hosted attestation and
remaining acceptance gates are tracked in the
[host acceptance ledger](docs/design/swift-host-acceptance.md) (H-09) and the
[proxy acceptance map](docs/design/swift-proxy-acceptance.md).

## Building a release archive

[`scripts/build-release.py`](scripts/build-release.py) is the one release
build entrypoint. Its stages are explicit and run in order:

1. **source** — copies the tracked (and untracked, unignored) files of this
   checkout into a private staging directory and stamps the revision into
   `Sources/CoopHost/BuildRevision.swift` there; the working tree is never
   modified. `--expected-revision SHA` requires a clean checkout of exactly
   that commit, before and after the build.
2. **build** — `coop` (release: optimized, `-D COOP_RELEASE_BUILD`, which makes
   `coop update` treat the binary as a release), `coop-proxy`, and
   `coop-sandbox` (ad-hoc signed with its virtualization entitlement by
   `scripts/build-coop-sandbox.sh`), all with `--force-resolved-versions`.
3. **test** (`--test`) — every package's tests in the staging copy.
4. **sign** (`--sign`, requires `--release --expected-revision`) — Developer ID
   signing and notarization; see [macOS signing](#macos-signing).
5. **archive** — verifies `coop --version` and `coop-sandbox version`, writes
   `BUILD.json` (version, tag, revision, dirty flag, per-binary SHA-256,
   `tested`, `developer_id_signed`), then `coop-<tag|revision>-aarch64-apple-darwin.tar.gz`
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
  bounded smoke, the `coop-proxy` and `coop-sandbox` package tests, the
  host-only install/update/uninstall suites and regression scripts, and
  `zizmor`.
- **`candidate.yml`** builds a signed same-revision candidate with
  `scripts/build-release.py --release --test --sign` in the `release`
  environment and attests it.
- **`release.yml`** runs when a `v*` tag is pushed. It gates on CI, builds
  the macOS ARM64 archive, signs and notarizes it, generates `SHA256SUMS`,
  attests build provenance, extracts the `## vX.Y.Z` section from
  `CHANGELOG.md` as the release notes, and publishes the GitHub release.
  **A missing CHANGELOG section fails it.**

So pushing the tag is the release. Everything below is about making sure that
push succeeds and ships something correct.

## Candidate download and verification

Run the **Release candidate** workflow (`.github/workflows/candidate.yml`)
against `swift`. Its downloadable artifact is
`coop-candidate-<commit>-aarch64-apple-darwin`, containing:

- `coop-<first 12 hex digits of the commit>-aarch64-apple-darwin.tar.gz`
- `SHA256SUMS`
- `attestations.jsonl`

After unzipping the GitHub artifact, enter its directory. Set `REVISION` to the
full commit SHA from the workflow run, then verify before extracting:

```bash
REVISION="FULL_COMMIT_SHA_FROM_WORKFLOW_RUN"
ARCHIVE="coop-${REVISION:0:12}-aarch64-apple-darwin.tar.gz"
shasum -a 256 -c SHA256SUMS
gh attestation verify "$ARCHIVE" \
  --repo chr33s/coop \
  --bundle attestations.jsonl \
  --signer-workflow chr33s/coop/.github/workflows/candidate.yml \
  --source-ref refs/heads/swift \
  --source-digest "$REVISION"
```

After both checks succeed, extract into a fresh directory and check the bundle:

```bash
(
set -e
mkdir candidate
tar -xzf "$ARCHIVE" -C candidate
cd "candidate/coop-${REVISION:0:12}-aarch64-apple-darwin"
for binary in coop coop-proxy coop-sandbox; do
  codesign --verify --strict "$binary"
done
cat BUILD.json
./coop --version
./coop-sandbox version
)
```

`BUILD.json` must name the expected commit in `source_revision`, with
`source_dirty: false`, `release_build: true`, `tested: true`, and
`developer_id_signed: true`, and its `binaries` digests must match the
extracted files. All three binaries stay
together. Earlier downloads retain their original archive layout and signer
workflow identity; use those original identities when verifying old artifacts.

## macOS signing

`scripts/build-release.py --sign` runs
[`scripts/macos-sign-notarize.sh`](scripts/macos-sign-notarize.sh) on the
staged bundle before `BUILD.json` and `SHA256SUMS` are written. It signs
`coop`, `coop-proxy`, and `coop-sandbox` with a Developer ID Application
certificate (hardened runtime, secure timestamp; `coop-sandbox` keeps its
virtualization entitlement), submits them to Apple's notary service, and fails
unless notarization is `Accepted`. A browser-downloaded archive then runs
without `xattr -d com.apple.quarantine`. Bare binaries cannot carry a stapled
ticket, so Gatekeeper checks notarization online on first launch.

Only the sign stage sees the signing secrets; the builder removes them from
every other `swift` and helper subprocess.

The signing workflows use the `release` GitHub environment, which must define these
secrets:

| Secret | Value |
|--------|-------|
| `MACOS_CERTIFICATE_P12` | base64 of the Developer ID Application `.p12` (certificate + private key) |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `MACOS_SIGNING_IDENTITY` | e.g. `Developer ID Application: Name (TEAMID)` |
| `NOTARY_API_KEY_P8` | base64 of an App Store Connect API key (`.p8`, Developer role) |
| `NOTARY_API_KEY_ID` | that key's ID |
| `NOTARY_API_ISSUER_ID` | the App Store Connect issuer ID |

A missing secret fails the release, which burns the version, so configure the
environment before tagging.

## What runs where

| Check | CI (on PR + on tag) | Local before tagging | Manual judgement |
|-------|:---:|:---:|:---:|
| `swift format lint --strict`, build, package tests | ✓ | ✓ | |
| Python host checks (migration, inventory, parity, CLI surface) | ✓ | ✓ | |
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

1. **Land all release content on `swift`.** Open PRs merged, `swift` green in CI.

2. **Pick the version** (`X.Y.Z`, semver). Breaking changes → major; new
   features → minor; fixes only → patch. Look at the `## Unreleased` section of
   `CHANGELOG.md` to judge.

3. **Bump the version.** Edit `packageVersion` in
   `Sources/CoopHost/UpdateVersion.swift`.

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
   ```

   Live-provider and guest-agent tests remain required for proxy acceptance:
   `scripts/test-proxy-live.py` per approved model, then
   `python3 tests/integration-proxy-transition.py --live-agents` with
   `--claude-model`/`--codex-model` for each approved model. Both use the
   dedicated `coop-live-*` Keychain credentials; see [testing](docs/testing.md).

6. **Run the deep checks when the diff warrants it** (slow, not CI gates):
   - `python3 scripts/swift-host-fault-injection.py` when this release changed
     security-relevant host behavior (config, credentials, workspace,
     devcontainer, subprocess/SSH, state, update).
   - `swift test --sanitize=address --scratch-path .build-asan` (and
     `thread`, `undefined`) when host code changed.
   - `scripts/fuzz.sh run <target> 600` when it changed a parser of
     user-editable input (`ParseRepoSlug`, `JSONCToJSON`, `ConfigLoad`).

7. **Open the bump PR** (`Sources/CoopHost/UpdateVersion.swift`, `CHANGELOG.md`), get it
   reviewed, and merge to `swift`. Never push the bump straight to `swift`.

8. **Tag the merge commit and push.**

   ```bash
   git checkout swift && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

   This triggers `release.yml`.

9. **Verify the published release.** On the GitHub release page confirm:
   - `coop-vX.Y.Z-aarch64-apple-darwin.tar.gz` containing `coop`, `coop-proxy`,
     `coop-sandbox`, `LICENSE` and `BUILD.json`, plus release-level
     `SHA256SUMS` and `attestations.jsonl`,
   - the build-provenance attestation is attached,
   - the binaries are notarized: after extracting the archive,
     `spctl --assess --type open --context context:primary-signature -v coop`
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

   The run must print `Attestation verified against attestations.jsonl`. A
   "Could not use `attestations.jsonl`" line instead means the bundle could not
   be downloaded — the installer cannot tell a missing asset from a failed
   download, so confirm the asset on the release page (step 9's first bullet)
   before concluding it is missing.

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
