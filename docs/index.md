<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Documentation index

System-of-record map for `iso`. The root [`AGENTS.md`](../AGENTS.md) is the
short navigational entrypoint; durable detail lives here.

This is the `chr33s/iso` fork of Trail of Bits’ isolate. Supported hosts are
**macOS 27+ on Apple Silicon only**; guests run Linux. The host CLI is Swift
(root [`Package.swift`](../Package.swift), [`Sources/`](../Sources/)) with one
Apple backend. The credential proxy is the Swift package
[`iso-proxy/`](../iso-proxy/); the Apple runtime is
[`iso-sandbox/`](../iso-sandbox/). See the [project motivation](../README.md),
[source installation](installation.md#build-from-source), and
[release validation](release-validation.md).

## CI companion

- [`ci.md`](ci.md) — `iso-ci`: GitHub-connected runner pools and local
  workflow preflight in brokered VMs (separately installed; [`iso-ci/`](../iso-ci/)).

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
- [`design/`](design/index.md) — decision records:
  - [`apple-sandbox-runtime.md`](design/apple-sandbox-runtime.md): why the
    Apple backend runs its own runtime;
  - [`apple-sandbox-transactions.md`](design/apple-sandbox-transactions.md):
    its mutation invariants, disk-update recovery, per-sandbox locking, and
    maintenance image.
  - [`local-and-remote-hosts-spec.md`](design/local-and-remote-hosts-spec.md):
    host control — the per-user service, durable operations, access grants,
    owned relays, remote execution hosts — and its implementation status;
  - [`brokered-network-isolation.md`](design/brokered-network-isolation.md):
    the NIC-less brokered transport (SSH over a runtime-owned vsock stream),
    its specification (ISO-NET-001), requirement mapping, native evidence
    and open qualification items;
  - [`iso-ci-specification.md`](design/iso-ci-specification.md): the
    separately installed GitHub Actions companion (connected runner pools and
    local preflight) and its implementation status;
  - [`iso-ci-qualification.md`](design/iso-ci-qualification.md): the
    companion's recorded live evidence and the defects it exposed;
  - [`embedded-secrets-spec.md`](design/embedded-secrets-spec.md): the
    Secure Enclave-bound local secret store, `--env-file` and `{vault:}`
    references;
  - [`selective-hardening-spec.md`](design/selective-hardening-spec.md):
    staged workspace return, `proxy.mode`, egress modes, budgets, and audit;
  - [`iso-security-hardening-spec.md`](design/iso-security-hardening-spec.md):
    host-boundary hardening and secure defaults — selected-content input,
    Git-free staged return, grant provenance and revocation;
  - [`iso-policy.md`](design/iso-policy.md): the IsoPolicy v1 contract —
    permit/forbid evaluation, admission quotas, single-use staged approvals,
    boot binding and proxy startup version 3;
  - [`sandboxy-inspired-features-spec.md`](design/sandboxy-inspired-features-spec.md):
    one-command sessions, declarative agents, image inspection, and
    destination-filtered egress. Filtered-egress qualification remains incomplete.
  - [`macos-computer-use-qualification-plan.md`](design/macos-computer-use-qualification-plan.md):
    the release gates (A–T) for macOS-guest computer use;
  - [`macos-vz-context-headless-experiment-spec.md`](design/macos-vz-context-headless-experiment-spec.md):
    the experiment spec for which host context a macOS VM owner needs;
  - [`macos-computer-use-q0-spike.md`](design/macos-computer-use-q0-spike.md):
    go/no-go spike results for macOS-guest computer use (display, input,
    boot identity) and the owner-topology constraints they set;
  - [`macos-guest-computer-use.md`](design/macos-guest-computer-use.md):
    macOS guests in `iso-sandbox` (templates, clones, helper channel,
    computer use) and their qualification status;
  - [`macos-vz-context-experiment.md`](design/macos-vz-context-experiment.md):
    which host process/session context a macOS VM owner and its view need
    (headless runtime in `user/$UID`; computer use needs a window, not a
    visible one);
  - [`linux-computer-use-sketch.md`](design/linux-computer-use-sketch.md):
    proposal for computer use in Ubuntu guests (Xvfb + XTEST, in-guest loop
    first, bounded host frame channel for qualification);
  - [`editor-providers-spec.md`](design/editor-providers-spec.md):
    `iso code` / `iso zed`, compiled-in editor providers, and the boundary
    between SSH connection targets and managed agent workloads.
  - [`editor-hardening.md`](design/editor-hardening.md): the sandboxed
    local editor (Seatbelt enclave, ephemeral SSH identity, supervision), its
    threat model, and where the implementation departs from the design.

## For users

- [`getting-started.md`](getting-started.md) — install and first VM.
- [`installation.md`](installation.md) — release verification and source builds.
- [`commands.md`](commands.md) — every `iso` subcommand.
- [`machine-interface.md`](machine-interface.md) — the versioned `--output json`
  contract (`iso.machine/v1`) for editors, CI and other integrations.
- [`audit.md`](audit.md) — `iso audit` run history: the `iso.audit/v1` event
  model, retention, cursors and the `iso.audit.stream/v1` JSONL protocol.
- [`configuration.md`](configuration.md) — `config.jsonc` reference.
- [`backends.md`](backends.md) — the Apple sandbox backend (`iso-sandbox` on `apple/containerization`) and its state layout.
- [`images-and-profiles.md`](images-and-profiles.md),
  [`workspaces.md`](workspaces.md), [`multi-instance.md`](multi-instance.md),
  [`devcontainer.md`](devcontainer.md), [`editor.md`](editor.md),
  [`shell-completion.md`](shell-completion.md).
- [`remote-hosts.md`](remote-hosts.md) — project VMs on trusted remote Macs.
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
