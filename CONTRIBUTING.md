<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Contributing to isolate

Thanks for your interest in contributing to isolate. This document covers how to
build the project, run its tests, and submit changes.

isolate is a Swift CLI that orchestrates disposable VMs for running agent CLIs —
Linux guests through the Swift `iso-sandbox` runtime on macOS 27+ Apple
Silicon hosts only. The host is the root Swift package (`Package.swift`,
`Sources/`, `tests/swift/`); the credential proxy lives in `iso-proxy/` and
the runtime in `iso-sandbox/`, each a separate Swift package and a separate
executable. Because isolate drives real virtualization, some tests only run on a
host with the Apple runtime available. The sections below note where that
applies.

## Prerequisites

- **Xcode 27** on macOS 27+ Apple Silicon (macOS SDK, code signing).
- **[mise](https://mise.jdx.dev)**, which installs the pinned toolchain from
  [`mise.toml`](mise.toml) — Swift 6.4.0 (with `swift format`), Python, jq,
  yq, shellcheck, actionlint, zizmor and Apple's `container` CLI — and the git
  hook: run `./scripts/install-dev-tools.sh` once.
- To run the integration suite: the stock Apple `container` service and guest
  kernel; see [backend setup](docs/backends.md#macos--apple-sandbox) and
  [docs/getting-started.md](docs/getting-started.md#prerequisites).
  Linux hosts are outside this fork's support and acceptance scope.

## Building

Clone the repository and build:

```bash
git clone https://github.com/chr33s/iso
cd iso
swift build --force-resolved-versions
```

The host CLI lands at `.build/debug/iso` (`-c release` for
`.build/release/iso`). A usable installation also needs `iso-proxy` and
`iso-sandbox` beside it; `python3 scripts/build-release.py` builds all three
and assembles the same archive layout the installer and `iso update` use (see
[RELEASING.md](RELEASING.md)).

## Pre-commit hook

`./scripts/install-dev-tools.sh` installs the hook (`mise generate
git-pre-commit --write`); it runs `mise run pre-commit` on every commit. Run
the same gates by hand at any time:

```bash
mise run check                    # hygiene, lint, build, test
python3 scripts/hygiene.py --all  # hygiene over every tracked file
```

The tasks are defined in `mise.toml`. Whatever they cover, run these gates
before submitting a host change:

```bash
swift format lint --strict -r Package.swift Sources tests/swift fuzz/Targets fuzz/Entrypoints iso-sandbox/Package.swift iso-sandbox/Sources iso-sandbox/Tests
swift build --force-resolved-versions
swift test --force-resolved-versions
```

On macOS 27+, also run `swift test --package-path iso-proxy
--force-resolved-versions` when touching the proxy and `swift test
--package-path iso-sandbox --no-parallel` when touching the runtime.

Fix every warning before committing, and keep `swift format lint --strict`
clean; CI enforces both.

## Testing

### Unit tests

```bash
swift test --force-resolved-versions
```

The package tests (`tests/swift/`) cover the host targets: JSONC scanning and
configuration decoding, validated names and units, remote-command quoting,
state records and locks, subprocess ownership, lifecycle against a scripted
runtime, and the CLI surface. They also replay the fuzz corpus. Test behavior,
not implementation — a test that breaks under a refactor but not a behavior
change is testing the wrong thing.

The Python host checks (configuration migration, compatibility inventory,
golden parity with the former Rust host, CLI surface) are listed in
[docs/testing.md](docs/testing.md#swift-host-checks).

### Integration tests

The integration suite exercises the full VM lifecycle on real Apple
Containerization VMs. It is too slow for the pre-commit hooks, so run it
before submitting a guest-visible or lifecycle change:

```bash
./tests/run-integration.sh                  # Apple runtime suite (all phases)
./tests/run-integration.sh --only iso      # iso end to end only

# Credential proxy VM gates
python3 tests/integration-proxy-transition.py
python3 tests/integration-proxy-transition.py --controlled-upstream
# Live agent tool use (dedicated credentials, approved models; billed)
python3 tests/integration-proxy-transition.py --live-agents \
  --claude-model APPROVED_MODEL --codex-model APPROVED_MODEL
```

When you add a command or a guest-visible change, consider whether it needs a
new integration test phase.

### Deeper checks

- **Fault injection** — `python3 scripts/swift-host-fault-injection.py` shows
  that critical tests fail when their protected behavior is removed. A new
  security-relevant host behavior needs a fault entry there.
- **Sanitizers** — `swift test --sanitize=address --scratch-path .build-asan`
  (also `thread`, `undefined`).
- **Fuzzing** — `scripts/fuzz.sh smoke` for all parser targets; longer
  campaigns with `scripts/fuzz.sh run`.

See [docs/testing.md](docs/testing.md) for when and how to run them.

## Code style

- Keep `swift format lint --strict` clean and the build warning-free.
- Lean on the type system to make illegal states unrepresentable rather than
  validating at runtime: parse untrusted input into strong types at the
  boundary, use smart-constructor value types over bare strings and integers
  that carry an invariant, and use enums for state rather than boolean flags.
- Build subprocess argv without shell interpolation (`RemoteCommand` for guest
  commands) and spawn through `ProcessRunner`.
- Write diagnostics to stderr through `Diagnostics`, never `print` for logs;
  stdout carries command output and `--json`.

[docs/code-style.md](docs/code-style.md) documents the project's conventions in
detail, including what reviewers look for.

## Commits

- Write commit subjects in the imperative mood, no more than 72 characters
  ("Add license field to Package.swift", not "Added..." or "Adds...").
- Keep each commit to one logical change.
- Work on a feature branch and open a pull request. Never push directly to
  `main`.

## Pull requests

1. Branch from the latest `main`.
2. Make your change, keeping commits focused.
3. Run the pre-commit hooks and the applicable macOS integration suites.
4. Open a pull request describing what the change does. Describe the code as it
   stands — not discarded approaches or prior iterations — and use plain,
   factual language.
5. A maintainer will review. Address feedback with follow-up commits.

CI must pass before a pull request can merge. The
[CI workflow](.github/workflows/ci.yml) runs, on macOS 27 runners, the Swift
host format/build/test gates and Python host checks, the fuzz corpus replay
and bounded smoke, the `iso-proxy` and `iso-sandbox` package tests, the
host-only install/update/uninstall suites and regression scripts, and a
GitHub Actions security audit ([zizmor](https://github.com/zizmorcore/zizmor)).

The VM lifecycle suite is not run in CI — run it locally, as described above.

## Reporting issues

Open an issue on the [issue tracker](https://github.com/chr33s/iso/issues).
For bug reports, include the platform and backend, the command you ran, and the
output (isolate's diagnostics go to stderr — `-v` adds debug detail, `-vv` trace).

If you believe you have found a security vulnerability, do not open a public
issue. Follow the private reporting process in [SECURITY.md](SECURITY.md).

## License

isolate is licensed under the [Apache License 2.0](LICENSE). By contributing, you
agree that your contributions will be licensed under the same terms.
