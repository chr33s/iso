# Releasing coop

How a `coop` release is cut, and what to check before cutting one.

**Supported host and release target: macOS 27+ on Apple Silicon
(`aarch64-apple-darwin`) only.** Linux guests remain supported. Linux/Firecracker
host failures are outside acceptance scope.

## Fork distribution status

The installer, updater, and repository provenance checks target `chr33s/coop`.
Release tags must point to commits reachable from the `swift` branch. macOS
artifacts use `apple-container` and bundle the signed `coop-sandbox` runtime
and Swift `coop-proxy`. Linux artifacts are outside the intended release
channel. Source and release builds use the same Apple backend.

This configures the channel; no hosted candidate or fork release has been
published or verified as part of this change. Build from source until those
gates pass. Hosted attestation and remaining acceptance gates are tracked in
[the acceptance map](docs/design/swift-proxy-acceptance.md).

## Automation alignment still required

The checked-in release matrix and preflight still include Linux targets, and
CI retains Linux jobs. These are inherited implementation details, not the
fork’s supported-host policy. Align the release matrix, installer platform
selection, CI gates, and preflight with macOS 27+ before the next release.
A Linux runner may still be useful for platform-neutral checks; it does not
create a Linux host support obligation. Do not treat a failed required GitHub
job as passing: update the configured gates to match this policy.

## Current automation (includes inherited Linux jobs)

- **`ci.yml`** runs on pushes to the configured branches and on every PR: `fmt --check`, `clippy -D warnings`,
  `cargo test --workspace`, the preflight/probe regression tests, Linux bridge
  isolation, `integration-proxy-forward.sh`, `integration-install.sh`, `integration-update.sh`,
  `integration-uninstall.sh`, the macOS 27 Swift proxy package/process gates,
  `cargo deny --workspace check`, `taplo format --check`, and `zizmor`.
- **`release.yml`** runs when a `v*` tag is pushed. It **re-runs all of CI as a
  gate**, then builds the Rust host CLI on native runners for three
  targets
  (`aarch64-apple-darwin`, `x86_64-unknown-linux-musl`,
  `aarch64-unknown-linux-musl`), checks the built CLI reports the tagged release
  version, builds and packages Swift `coop-proxy` and signed `coop-sandbox` for macOS only,
  re-signs the macOS binaries with Developer ID and notarizes them (the
  `sign-macos` job, see [macOS signing](#macos-signing)), generates `SHA256SUMS`, attests
  build provenance, extracts the `## vX.Y.Z` section from `CHANGELOG.md` as the
  release notes, and publishes the GitHub release. **It fails if there is no
  matching CHANGELOG section.**

So pushing the tag is the release. Everything below is about making sure that
push succeeds and ships something correct.

## Candidate download and verification

Run the **Release candidate** workflow (`.github/workflows/candidate.yml`)
against `swift`. Its downloadable artifact is
`coop-candidate-<commit>-aarch64-apple-darwin`, containing:

- `coop-<commit>-aarch64-apple-darwin.tar.gz`
- `SHA256SUMS`
- `attestations.jsonl`

After unzipping the GitHub artifact, enter its directory. Set `REVISION` to the
full commit SHA from the workflow run, then verify before extracting:

```bash
REVISION="FULL_COMMIT_SHA_FROM_WORKFLOW_RUN"
ARCHIVE="coop-${REVISION}-aarch64-apple-darwin.tar.gz"
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
cd candidate/coop
shasum -a 256 -c SHA256SUMS
for binary in coop coop-proxy coop-sandbox; do
  codesign --verify --strict "$binary"
done
cat BUILD.json
./coop --version
./coop-sandbox version
)
```

The manifest must match the expected commit, with `source_dirty: false`,
`local_build: false`, and `includes_runtime: true`. All three binaries stay
together. Earlier downloads retain their original archive layout and signer
workflow identity; use those original identities when verifying old artifacts.

## macOS signing

The `sign-macos` job in `release.yml` runs
[`scripts/macos-sign-notarize.sh`](scripts/macos-sign-notarize.sh) on the
unsigned macOS archive. It signs `coop`, `coop-proxy`, and `coop-sandbox`
with a Developer ID Application certificate (hardened runtime, secure
timestamp; `coop-sandbox` keeps its virtualization entitlement), submits them
to Apple's notary service, and fails the release unless notarization is
`Accepted`. A browser-downloaded archive then runs without
`xattr -d com.apple.quarantine`. Bare binaries cannot carry a stapled ticket,
so Gatekeeper checks notarization online on first launch.

`candidate.yml` signs the same way through
`scripts/build-proxy-transition.py --sign`, which signs before writing the
archive's `SHA256SUMS`. The builder strips the signing secrets from every
cargo and swift subprocess, so only the signing script sees them.

Both jobs use the `release` GitHub environment, which must define these
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

| Check | CI (on PR + on tag) | `preflight-release.sh` | Manual judgement |
|-------|:---:|:---:|:---:|
| fmt / clippy / unit tests | ✓ | ✓ | |
| `cargo deny --workspace`, `zizmor`, `taplo` | ✓ | ✓ (if installed) | |
| Host-only integration and preflight/probe regression suites | ✓ | ✓ | |
| Version ↔ lock ↔ CHANGELOG ↔ tag agreement | | ✓ | |
| Release builds (3 targets) | native only | ✓ (per installed toolchain) | |
| Formal verification (`cargo kani`) | | ✓ (if installed) | |
| Supported macOS VM integration | | inherited runner needs alignment | Apple runtime/proxy and shared host behavior |
| Mutation testing (`--mutants`) | | opt-in | when logic changed |
| Fuzzing (`--fuzz`) | | opt-in | when a parser changed |

CI can't run the full VM integration suite or the extra-toolchain checks
(kani/mutants/fuzz); those are the preflight's job.

## Release checklist

1. **Land all release content on `swift`.** Open PRs merged, `swift` green in CI.

2. **Pick the version** (`X.Y.Z`, semver). Breaking changes → major; new
   features → minor; fixes only → patch. Look at the `## Unreleased` section of
   `CHANGELOG.md` to judge.

3. **Bump the version.**
   - Edit `[workspace.package].version` in `Cargo.toml`; the host package inherits it.
   - Run `cargo build --workspace` so `Cargo.lock` picks up the host package version.

4. **Promote the changelog.** Rename `## Unreleased` to `## vX.Y.Z` in
   `CHANGELOG.md`. The text under it becomes the GitHub release notes verbatim,
   so read it as release notes. Start a fresh empty `## Unreleased` above it.

5. **Run the preflight.** It refuses to pass until the version sources agree and
   the tag is free, then runs the full gate:

   ```bash
   ./scripts/preflight-release.sh
   ```

   A successful exit with warnings is incomplete validation: resolve skipped
   tools and supported macOS gates before tagging. Linux-only requirements
   in this inherited script need removal as described above.

   Run the Apple runtime and proxy VM gates on macOS 27+ Apple Silicon:

   ```bash
   ./tests/integration-apple-sandbox.sh
   python3 tests/integration-proxy-transition.py --controlled-upstream
   ```

   `./tests/run-integration.sh` invokes the Apple runtime suite. Live-provider and guest-agent
   tests remain required for proxy acceptance; see [testing](docs/testing.md).
   No Linux/Firecracker VM gate or remote Linux host is required.

6. **Run the deep checks when the diff warrants it** (these are slow and not CI
   gates — see `AGENTS.md`):
   - `--mutants` when this release changed logic-dense modules (config,
     workspace, devcontainer, parsing, secret routing).
   - `--fuzz` when it changed a parser of user-editable input
     (`parse_repo_slug`, `jsonc_to_json`, `config_load`).

   ```bash
   ./scripts/preflight-release.sh --mutants --fuzz
   ```

7. **Open the bump PR** (`Cargo.toml`, `Cargo.lock`, `CHANGELOG.md`), get it
   reviewed, and merge to `swift`. Never push the bump straight to `swift`.

8. **Tag the merge commit and push.**

   ```bash
   git checkout swift && git pull
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

   This triggers `release.yml`.

9. **Verify the published release.** On the GitHub release page confirm:
   - three `coop-vX.Y.Z-<target>.tar.gz` artifacts, each containing `coop`; the macOS
     archive also contains Swift `coop-proxy` and signed `coop-sandbox`, plus release-level `SHA256SUMS`
     and `attestations.jsonl`,
   - the build-provenance attestation is attached,
   - the macOS binaries are notarized: after extracting the macOS archive,
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
macOS ARM64 bundle with Xcode 27. Align the inherited three-target preflight
and workflow first; Linux cross-compilation is not a release requirement for
this fork. Then verify the hosted artifact’s checksum, source revision,
provenance, signatures, and execution on a supported macOS host.

Do **not** attempt `git push origin :refs/tags/vX.Y.Z` to delete and reuse a
tag — immutable releases reject it, and reusing a spent version is not allowed.
