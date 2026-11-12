<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Documentation index

System-of-record map for `iso`. The root [`AGENTS.md`](../AGENTS.md) is the
short navigational entrypoint; durable detail lives here.

This is the `chr33s/iso` fork of Trail of Bits’ coop. Supported hosts are
**macOS 27+ on Apple Silicon only**; guests run Linux, or macOS from an image
built with `iso setup --guest macos`
([macOS guests](images-and-profiles.md#macos-guests)). The host CLI is Swift
(root [`Package.swift`](../Package.swift), [`Sources/`](../Sources/)) with one
Apple backend. The credential proxy is the Swift package
[`iso-proxy/`](../iso-proxy/); the Apple runtime is
[`iso-sandbox/`](../iso-sandbox/). See the [project motivation](../README.md),
[source installation](installation.md#build-from-source), and
[release validation](release-validation.md).

## CI companion

- [`ci.md`](ci.md) — `iso-ci`: GitHub-connected runner pools and local
  workflow preflight in brokered VMs, including project Git hooks that run it
  before commits or pushes (separately installed; [`iso-ci/`](../iso-ci/)).

## Authorization policy

- [`policy.md`](policy.md) — the optional default-deny `policy`: governed
  actions, quotas on proxied requests, inline approvals for staged applies.

## For contributors (engineering)

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Swift module map, the Apple backend,
  host→guest data flow, architectural invariants.
- [`trust-model.md`](trust-model.md) — trust boundaries, taint sources, secret
  handling, `iso update` verification. The authoritative security spec the
  `review-security` agent reads. (Disclosure policy is [`SECURITY.md`](../SECURITY.md).)
- [`code-style.md`](code-style.md) — Swift authoring conventions and the
  review / authoring checklists.
- [`testing.md`](testing.md) — Swift package tests, sanitizers, behavior
  contracts, fault injection, libFuzzer fuzzing, integration suites.
- [`platform-notes.md`](platform-notes.md) — Docker networking, scp `~`
  caveat, diagnostics on stderr.
- [`xcode-security-settings.md`](xcode-security-settings.md) — Enhanced
  Security entitlements and other security build-setting decisions.
- [`design/`](design/index.md) — decision records, specifications and
  qualification evidence; its index lists every record with its status.

## For users

- [`getting-started.md`](getting-started.md) — install and first VM.
- [`installation.md`](installation.md) — release verification and source builds.
- [`commands.md`](commands.md) — every `iso` subcommand.
- [`machine-interface.md`](machine-interface.md) — the versioned `--output json`
  contract (`iso.machine/v1`) for editors, CI and other integrations.
- [`agent-skill.md`](agent-skill.md) — the [`skills/iso/`](../skills/iso/)
  Agent Skill that lets a host coding agent operate `iso`.
- [`audit.md`](audit.md) — `iso audit` run history: the `iso.audit/v1` event
  model, retention, cursors and the `iso.audit.stream/v1` JSONL protocol.
- [`configuration.md`](configuration.md) — `config.jsonc` reference.
- [`coreai.md`](coreai.md) — experimental paravirtualized Core AI for macOS
  guests (weakens the host).
- [`backends.md`](backends.md) — the Apple sandbox backend (`iso-sandbox` on `apple/containerization`) and its state layout.
- [`images-and-profiles.md`](images-and-profiles.md),
  [`workspaces.md`](workspaces.md), [`multi-instance.md`](multi-instance.md),
  [`devcontainer.md`](devcontainer.md), [`editor.md`](editor.md),
  [`shell-completion.md`](shell-completion.md).
- [`remote-hosts.md`](remote-hosts.md) — project VMs on trusted remote Macs.
- [`claude-integration.md`](claude-integration.md),
  [`codex-integration.md`](codex-integration.md) — agent integration.
- [`credential-proxy.md`](credential-proxy.md) — the `proxy`
  credential-injecting proxy (required by default) (issue #411): keeps the raw API key out of the
  guest.

## Agent tooling

- [`.agents/skills/`](../.agents/skills/) — shared review, closeout, fault-injection,
  integration, and PR-shepherding workflows, plus `iso` (a link to the
  shipped [`skills/iso/`](agent-skill.md) skill), discovered by Codex and, through
  the `.claude/skills` symlink, Claude Code.
- [`.github/workflows/review.yml`](../.github/workflows/review.yml)
  — trusted-user, on-demand `@claude` and `@codex` PR reviews (Codex in a
  read-only sandbox).
- [`.claude/`](../.claude/) — the `.claude/skills` symlink, the `/my-review`
  command, review subagents, and local hooks/settings.
