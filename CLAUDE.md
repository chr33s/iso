# coop agent guide

Follow the shared repository instructions in [`AGENTS.md`](AGENTS.md). Agent
workflows are in [`.agents/skills/`](.agents/skills/); compatibility commands
under [`.claude/commands/`](.claude/commands/) invoke those workflows.

<!-- The remainder is retained as a standalone fallback for clients that do
not follow the shared entrypoint link. Keep normative changes in AGENTS.md. -->

This is the `chr33s/coop` fork, supporting **macOS 27+ on Apple Silicon hosts
only**. Linux guests remain supported; Linux/Firecracker host testing is outside
this fork’s acceptance scope. The host CLI remains Rust; the Swift-only
credential proxy (`coop-proxy/`, macOS 27+) and optional Apple VM runtime
(`coop-sandbox/`) are root-level Swift packages. Cargo does not build them.
See [README.md](README.md) for motivation and fork installation guidance.

## Agent entrypoint

Shared entrypoint for Claude, Codex, and humans. Keep this short and
navigational; durable detail lives in [`docs/`](docs/).

- [`docs/index.md`](docs/index.md) — system-of-record map.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — module map, the backend
  design, host→guest data flow, architectural invariants.
- [`docs/trust-model.md`](docs/trust-model.md) — trust boundaries and taint
  sources (the security spec; read before touching secrets, subprocess,
  network, or the guest boundary).
- [`docs/code-style.md`](docs/code-style.md) — Rust authoring idioms + review /
  authoring checklists.
- [`docs/testing.md`](docs/testing.md) — integration, mutation, fuzzing, kani.
- [`docs/platform-notes.md`](docs/platform-notes.md) — CI-kernel workarounds,
  Docker networking, scp `~` caveat, tracing-to-stderr.
- Agent workflows: `.agents/skills/`.

## Architecture (one paragraph)

A Rust CLI that orchestrates VM lifecycle (setup → up/start → shell → stop →
destroy → status/logs). Backends are selected at **compile time** by `#[cfg]`
behind the `backend::VmBackend` trait / `PlatformBackend` alias. The release
uses the Apple sandbox backend (`apple-container` Cargo feature); Lima remains
a source-build option. Both run Linux guests on macOS 27+ Apple Silicon hosts.
Retained Firecracker code is inherited and outside supported-host scope.
Shared SSH, workspace, config/secret injection, and agent bootstrap contracts
must hold for the supported macOS backends. Full detail: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

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
secret content, or softens the `coop update` verification chain.

## Development commands

Runtime: Rust `1.94.0` (see `rust-toolchain.toml`), edition 2024.

```bash
cargo build                                                    # debug build
cargo fmt -- --check                                           # format check
cargo clippy --all-targets -- -D warnings                      # lints (zero-warnings)
cargo clippy --all-targets --features apple-container -- -D warnings  # macOS: Apple backend
cargo test                                                     # unit tests (lib)
swift test --package-path coop-proxy --force-resolved-versions   # macOS 27+: proxy
swift test --package-path coop-sandbox --no-parallel             # macOS: runtime
cargo deny check                                               # advisories/licenses/bans
taplo format --check                                           # TOML formatting
prek run                                                       # all pre-commit hooks
```

Install pinned local dev tools (prek, taplo, cargo-deny, cargo-mutants,
cargo-fuzz, kani) with `./scripts/install-dev-tools.sh --all`, then `prek
install`. CI pins its own taplo/cargo-deny versions in
`.github/workflows/ci.yml`; keep those in sync with the installer.

## Before committing

Pre-commit hooks (prek) run automatically: `cargo fmt`, `cargo clippy`, `cargo
test`, `taplo format --check`, plus trailing-whitespace / EOF / large-file /
merge-conflict checks. After hooks pass, run the integration suite on the applicable **macOS
backends** — too slow for hooks:

```bash
./tests/run-integration.sh                       # local (macOS/Lima)
./tests/integration-apple-sandbox.sh             # macOS/Apple runtime
python3 tests/integration-proxy-transition.py --controlled-upstream
```

The `/integration` command wraps this; [`docs/testing.md`](docs/testing.md) has
the full testing reference (including the `.cargo/mutants.toml` mutation scoping
and the [`mutation-check`](.agents/skills/mutation-check/SKILL.md) skill).

## Code style

Follow the global Rust guidance (clippy lint policy, `thiserror`/`anyhow`,
`tracing`, newtypes, enums over bools) plus coop's own conventions in
[`docs/code-style.md`](docs/code-style.md): parse-don't-validate at boundaries,
smart-constructor newtypes, type-state for lifecycles, absolute imports only,
tracing to **stderr**. Prefer changing a type to make a bug unrepresentable over
adding a runtime check.

## Pull requests

- **One PR = one logical change.** Refactors/renames first, then behavior —
  never mixed. Split if the description needs "and" / unrelated bullets.
- Run the gates before opening: `cargo fmt -- --check`, `cargo clippy … -D
  warnings`, `cargo test`, and the integration suite on the applicable macOS backends for
  guest-visible or lifecycle changes.
- Keep cross-file infra in sync in the same PR — a new CLI flag/config field ↔
  `config.example.toml` + `docs/`; tool-version pins ↔ CI; a new shell-out/IO
  function in a scoped module ↔ `.cargo/mutants.toml`.
- Before opening, run the [`closeout-review`](.agents/skills/closeout-review/SKILL.md)
  skill on the working diff (a `PreToolUse` hook gates `gh pr create` on it).
  Describe what the code does now — plain, factual language; a bug fix is a bug
  fix.
