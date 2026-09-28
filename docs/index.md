<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Documentation index

System-of-record map for `coop`. The root [`AGENTS.md`](../AGENTS.md) is the
short navigational entrypoint; durable detail lives here.

This is the `chr33s/coop` fork of Trail of Bits’ coop. Supported hosts are
**macOS 27+ on Apple Silicon only**; guests run Linux. The host CLI is Swift
(root [`Package.swift`](../Package.swift), [`Sources/`](../Sources/)) with one
Apple backend. The credential proxy is the Swift package
[`coop-proxy/`](../coop-proxy/); the Apple runtime is
[`coop-sandbox/`](../coop-sandbox/). Historical design records may describe the
former Rust host and Firecracker/Lima backends; they do not imply support.
See the [fork motivation](../README.md#why-this-fork)
and [source installation](getting-started.md#build-from-source). Design records
preserve historical experiments; the acceptance map identifies outstanding gates.

## For contributors (engineering)

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Swift module map, the Apple backend,
  host→guest data flow, architectural invariants.
- [`trust-model.md`](trust-model.md) — trust boundaries, taint sources, secret
  handling, `coop update` verification. The authoritative security spec the
  `review-security` agent reads. (Disclosure policy is [`SECURITY.md`](../SECURITY.md).)
- [`code-style.md`](code-style.md) — Swift authoring conventions and the
  review / authoring checklists.
- [`testing.md`](testing.md) — Swift package tests, sanitizers, parity and
  migration checks, fault injection, libFuzzer fuzzing, integration suites.
- [`platform-notes.md`](platform-notes.md) — Docker networking, scp `~`
  caveat, diagnostics on stderr.
- [`design/`](design/) — decision records:
  - [`swift-host-spec.md`](design/swift-host-spec.md): the port from the Rust
    host to Swift, JSONC configuration, compatibility and cutover gates;
    [`swift-host-acceptance.md`](design/swift-host-acceptance.md) is its
    gate/evidence ledger and [`swift-host-inventory.json`](design/swift-host-inventory.json)
    the machine-readable compatibility inventory;
  - [`apple-sandbox-runtime.md`](design/apple-sandbox-runtime.md): why the
    Apple backend runs its own runtime;
  - [`apple-sandbox-transactions.md`](design/apple-sandbox-transactions.md):
    its mutation invariants, disk-update recovery, per-sandbox locking, and
    maintenance image.
  - [`swift-proxy-spec.md`](design/swift-proxy-spec.md): approved Swift proxy
    contract and acceptance requirements;
  - [`swift-proxy-acceptance.md`](design/swift-proxy-acceptance.md): Swift proxy
    requirement/evidence map, remaining decisions, and cutover gates;
    [`swift-proxy-progress.md`](design/swift-proxy-progress.md) records the
    implementation and validation history.

## For users

- [`getting-started.md`](getting-started.md) — install and first VM.
- [`commands.md`](commands.md) — every `coop` subcommand.
- [`configuration.md`](configuration.md) — `config.jsonc` reference and
  TOML migration.
- [`backends.md`](backends.md) — the Apple sandbox backend (`coop-sandbox` on `apple/containerization`) and its state layout.
- [`images-and-profiles.md`](images-and-profiles.md),
  [`workspaces.md`](workspaces.md), [`multi-instance.md`](multi-instance.md),
  [`devcontainer.md`](devcontainer.md), [`editor.md`](editor.md),
  [`shell-completion.md`](shell-completion.md).
- [`claude-integration.md`](claude-integration.md),
  [`codex-integration.md`](codex-integration.md) — agent integration.
- [`credential-proxy.md`](credential-proxy.md) — the opt-in `proxy`
  credential-injecting proxy (issue #411): keeps the raw API key out of the
  guest.

## Agent tooling

- [`.agents/skills/`](../.agents/skills/) — shared review, closeout, fault-injection,
  integration, and PR-shepherding workflows discovered by Codex.
- [`.github/workflows/review.yml`](../.github/workflows/review.yml)
  — trusted-user, on-demand `@claude` and `@codex` PR reviews (Codex in a
  read-only sandbox).
- [`.claude/`](../.claude/) — compatibility commands, skill entrypoints, and
  local hooks/settings.
