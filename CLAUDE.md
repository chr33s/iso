<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# isolate agent guide

Follow the shared repository instructions in [`AGENTS.md`](AGENTS.md). Agent
workflows are in [`.agents/skills/`](.agents/skills/); compatibility commands
under [`.claude/commands/`](.claude/commands/) invoke those workflows.

<!-- The remainder is retained as a standalone fallback for clients that do
not follow the shared entrypoint link. Keep normative changes in AGENTS.md. -->

This is the `chr33s/iso` fork, supporting **macOS 27+ on Apple Silicon hosts
only**. Linux guests remain supported; Linux hosts are outside this fork's
scope. The host CLI is Swift (root `Package.swift`); the credential proxy
(`iso-proxy/`) and Apple VM runtime (`iso-sandbox/`) remain separate Swift
packages and separate processes. See [README.md](README.md) for motivation and
fork installation guidance.

## Agent entrypoint

Shared entrypoint for Claude, Codex, and humans. Keep this short and
navigational; durable detail lives in [`docs/`](docs/).

- [`docs/index.md`](docs/index.md) — system-of-record map.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Swift module map, the Apple
  backend, host→guest data flow, architectural invariants.
- [`docs/trust-model.md`](docs/trust-model.md) — trust boundaries and taint
  sources (the security spec; read before touching secrets, subprocess,
  network, or the guest boundary).
- [`docs/code-style.md`](docs/code-style.md) — Swift authoring conventions +
  review / authoring checklists.
- [`docs/testing.md`](docs/testing.md) — package tests, sanitizers, parity,
  fault injection, fuzzing, integration.
- [`docs/platform-notes.md`](docs/platform-notes.md) — Docker networking, scp
  `~` caveat, diagnostics on stderr.
- Agent workflows: `.agents/skills/`.

## Architecture (one paragraph)

A Swift CLI (`IsoCLI` on Swift Argument Parser, over `IsoHost`,
`IsoSecrets`, `IsoConfiguration` and `IsoCore`) that orchestrates VM lifecycle (setup →
up/start → shell → stop → destroy → status/logs) on one concrete Apple backend:
`iso-sandbox` VMs on `apple/containerization`, driven over the runtime's JSON
CLI. Each command loads one validated JSONC configuration snapshot
(`~/.iso/config.jsonc`). SSH, workspace, config/secret injection, and agent
bootstrap run from the host over pinned-host-key SSH. Full detail:
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Trust model

**The VM is the isolation boundary.** The guest is deliberately permissive
(passwordless sudo, agents run in bypass mode) because the whole VM is the blast
radius — so the guest is **untrusted from the host's view**, and guest-authored
data must never escalate into host code execution, filesystem escape, or
credential exposure. Authoritative boundaries and the stop-and-confirm checklist:
[`docs/trust-model.md`](docs/trust-model.md). This is the engineering spec;
[`SECURITY.md`](SECURITY.md) remains the vulnerability-disclosure policy.

Stop and confirm before merging code that adds an outbound URL / network
listener / egress rule, forwards a new secret into the guest, runs a subprocess
on tainted bytes, writes a host path from tainted data, logs/traces tainted or
secret content, or softens the `iso update` verification chain.

## Development commands

Toolchain: Xcode 27 (Swift 6.4, Swift 6 language mode), macOS 27+ on Apple
Silicon. Python 3.11+ for the migration, parity and integration scripts.

```bash
swift build                                                   # debug build → .build/debug/iso
swift test --force-resolved-versions                          # host package tests
swift format lint --strict -r Package.swift Sources tests/swift fuzz/Targets fuzz/Entrypoints
swift test --sanitize=address --scratch-path .build-address   # also thread, undefined
swift test --package-path iso-proxy --force-resolved-versions   # credential proxy
swift test --package-path iso-sandbox --no-parallel             # Apple runtime
python3 tests/test-migrate-config.py                          # TOML → JSONC converter
python3 tests/test-swift-host-inventory.py                    # compatibility inventory
python3 tests/test-swift-host-cli-surface.py --swift .build/debug/iso
python3 tests/test-swift-host-read-parity.py --swift .build/debug/iso   # also lifecycle, data-root
python3 scripts/swift-host-fault-injection.py                 # tests catch injected faults
scripts/fuzz.sh smoke                                         # bounded libFuzzer run, all targets
python3 scripts/build-release.py [--release --test --tag vX.Y.Z]  # release archive
mise run check                                                # pre-commit gates (mise.toml)
```

The parity scripts replay recorded baselines from `tests/baseline/parity/`.
When changing the proxy also run
`python3 scripts/test-swift-proxy-process.py --skip-tls`. Details and the
remaining checks are in [`docs/testing.md`](docs/testing.md).

## Before committing

The pre-commit hook runs `mise run pre-commit` ([`mise.toml`](mise.toml);
install the pinned tools and the hook with `./scripts/install-dev-tools.sh`):
`scripts/hygiene.py` (whitespace, final newline, YAML, large-file and
merge-conflict checks on staged files), `swift format lint --strict`,
`swift build --force-resolved-versions` and `swift test --force-resolved-versions`. CI installs the same `mise.toml` tools with `jdx/mise-action` (pin its
`version` to a mise release that satisfies `min_version`) and runs the
same tasks over every tracked file. For guest-visible and
lifecycle changes, also run the integration suite on macOS 27+ Apple Silicon:

```bash
./tests/run-integration.sh [--only PHASE[,PHASE...]] [--keep]   # Apple sandbox VM suite
python3 tests/integration-proxy-transition.py [--controlled-upstream]
```

Live-provider acceptance uses dedicated credentials and approved models only
(`scripts/test-proxy-live.py`; `tests/integration-proxy-transition.py
--live-agents`); see [`docs/testing.md`](docs/testing.md).

The `/integration` command wraps the
[`integration`](.agents/skills/integration/SKILL.md) skill to run and interpret
it. [`docs/testing.md`](docs/testing.md) has the full testing reference,
including fault injection and the
[`mutation-check`](.agents/skills/mutation-check/SKILL.md) skill.

## Code style

Follow [`docs/code-style.md`](docs/code-style.md): Swift 6 language mode,
`swift format lint --strict` clean, value types and enums over booleans,
smart-constructor types in `IsoCore`, parse-don't-validate at boundaries,
typed throws where callers switch on a closed error type, every subprocess
through `ProcessRunner` with no shell interpolation (`RemoteCommand` for guest
commands), state writes through `StateStore`/`AtomicFile`, and diagnostics on
**stderr**. Prefer changing a type to make a bug unrepresentable over adding a
runtime check.

## Pull requests

- **One PR = one logical change.** Put refactors/renames before behavior, never
  in the same change. Split if the description needs unrelated bullets.
- Run the gates before opening: `swift format lint --strict`, a warning-free
  `swift build`, `swift test --force-resolved-versions` (plus the companion
  packages you touched), and the macOS integration suites for guest-visible or
  lifecycle changes.
- Keep cross-file representations in sync: CLI flags/config fields ↔
  `config.example.jsonc`, `ConfigTemplate` and `docs/`; tool pins in `mise.toml` (CI reads them through `jdx/mise-action`); a new
  security-relevant host behavior ↔ a fault in
  `scripts/swift-host-fault-injection.py` that a test detects.
- Before opening, use the
  [`closeout-review`](.agents/skills/closeout-review/SKILL.md) skill on the
  working diff (a `PreToolUse` hook gates `gh pr create` on it). Describe what
  the code does now in plain, factual language; a bug fix is a bug fix.

