<!--
Derived from trailofbits/coop.
Modified by chr33s: ported/adapted for the Swift implementation.
SPDX-License-Identifier: Apache-2.0
-->

# Security Policy

This is the `chr33s/iso` fork of Trail of Bits' coop. It adds the Swift host,
credential proxy and Apple runtime described in
[the trust model](docs/trust-model.md). Trail of Bits does not maintain this
fork.

## Reporting a Vulnerability

Do not report security vulnerabilities through public GitHub issues, pull
requests, or discussions.

Report them privately through **GitHub private vulnerability reporting**: open
a report at <https://github.com/chr33s/iso/security/advisories/new>. It stays
visible only to the maintainer until a fix is published.

If the issue also affects upstream coop, report it there as well, through
<https://github.com/trailofbits/coop/security/advisories/new>.

Include as much of the following as you can:

- The isolate version (`iso --version`), your macOS version, and the
  `iso-sandbox version` output.
- A description of the issue and the impact you expect it to have.
- Steps to reproduce, a proof of concept, or the affected code path.
- Any suggested remediation.

## Response

We coordinate disclosure with the reporter. Once a fix is ready we publish it in
a release and credit you unless you ask us not to.

## Supported versions

isolate ships as a rolling release. Only the latest release receives security
fixes. Fixes land on `main` and go out in the next tagged release; there are no
long-term support branches. `iso update` installs the latest release, verifying
its SHA-256 checksum and — when `gh` is present — the GitHub build-provenance
attestation.

## Scope

isolate provisions isolated Linux virtual machines on macOS 27+ Apple Silicon,
through the `iso-sandbox` runtime built on Apple's Containerization framework,
to run coding agents such as Claude Code and Codex. **The
security boundary is the VM.** isolate's job is to stand that boundary up and hand
work to it without weakening it.

This policy is the disclosure process. The engineering-facing trust boundaries,
taint sources, and invariants that define what "weakening the boundary" means
live in [`docs/trust-model.md`](docs/trust-model.md).

In scope:

- Flaws in isolate that weaken or escape the VM isolation boundary.
- Mishandling of the secrets and credentials isolate injects into a guest — for
  example GitHub tokens, SSH configuration, and stored secrets.
- Guest configuration or workspace-sync handling that lets untrusted guest
  input reach the host.
- Verification gaps in `iso update` (release download, checksum, or provenance
  checks).

Out of scope:

- Vulnerabilities in the software isolate runs or orchestrates rather than ships —
  the guest agents (Claude Code, Codex), Docker, the guest OS, Apple's
  `container` CLI, and the Containerization and Virtualization frameworks.
  Report those to their respective projects.
- Behavior that requires an attacker who already controls the host isolate runs on.
