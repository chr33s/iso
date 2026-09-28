<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Security Policy

This fork adds the Swift credential proxy and Apple runtime described in
[the trust model](docs/trust-model.md). The upstream reporting channels below
belong to Trail of Bits and cover upstream code; they are not a promise that
Trail of Bits maintains this fork. For fork-specific changes, arrange a private
report with the fork maintainer through their
[GitHub profile](https://github.com/chr33s); do not publish exploit details.

## Reporting a Vulnerability

Do not report security vulnerabilities through public GitHub issues, pull
requests, or discussions.

Report them privately through either channel:

- **GitHub private vulnerability reporting** — open a report at
  <https://github.com/trailofbits/coop/security/advisories/new>. It stays
  visible only to the maintainers until a fix is published.
- **Trail of Bits security contact** — follow the process in
  <https://www.trailofbits.com/.well-known/security.txt> (encrypted upload via
  SendSafely, or email dan@trailofbits.com).

Include as much of the following as you can:

- The coop version (`coop --version`) and host platform (Linux/Firecracker or
  macOS/Lima).
- A description of the issue and the impact you expect it to have.
- Steps to reproduce, a proof of concept, or the affected code path.
- Any suggested remediation.

## Upstream response

We coordinate disclosure with the reporter. Once a fix is ready we publish it in
a release and credit you unless you ask us not to.

## Upstream supported versions

coop ships as a rolling release. Only the latest release receives security
fixes. Fixes land on `main` and go out in the next tagged release; there are no
long-term support branches. `coop update` installs the latest release, verifying
its SHA-256 checksum and — when `gh` is present — the GitHub build-provenance
attestation.

## Scope

coop provisions isolated virtual machines — Firecracker microVMs on Linux, Lima
VMs or the opt-in Apple Containerization runtime on macOS — to run coding agents such as Claude Code and Codex. **The
security boundary is the VM.** coop's job is to stand that boundary up and hand
work to it without weakening it.

This policy is the disclosure process. The engineering-facing trust boundaries,
taint sources, and invariants that define what "weakening the boundary" means
live in [`docs/trust-model.md`](docs/trust-model.md).

In scope:

- Flaws in coop that weaken or escape the VM isolation boundary.
- Mishandling of the secrets and credentials coop injects into a guest — for
  example GitHub tokens, SSH configuration, and stored secrets.
- Guest configuration or workspace-sync handling that lets untrusted guest
  input reach the host.
- Verification gaps in `coop update` (release download, checksum, or provenance
  checks).

Out of scope:

- The relaxed in-guest Docker networking (`DOCKER_INSECURE_NO_IPTABLES_RAW=1`).
  This is a documented, intentional trade-off for the minimal CI kernel: without
  the raw iptables table, another host on the guest's network could reach a
  published container port, even one bound to loopback. The guest's only network
  neighbor is its own Firecracker host, and the VM is the isolation boundary, so
  this crosses no trust boundary. See
  [`docs/platform-notes.md`](docs/platform-notes.md) and
  [`docs/trust-model.md`](docs/trust-model.md) for details.
- Vulnerabilities in the software coop runs or orchestrates rather than ships —
  the guest agents (Claude Code, Codex), Docker, the guest OS, Firecracker, and
  Lima. Report those to their respective projects.
- Behavior that requires an attacker who already controls the host coop runs on.
