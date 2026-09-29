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

- The isolate version (`iso --version`), your macOS version, and the
  `iso-sandbox version` output.
- A description of the issue and the impact you expect it to have.
- Steps to reproduce, a proof of concept, or the affected code path.
- Any suggested remediation.

## Upstream response

We coordinate disclosure with the reporter. Once a fix is ready we publish it in
a release and credit you unless you ask us not to.

## Upstream supported versions

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
