# Design records

Engineering decisions, implementation specifications, and experiments behind
isolate. These records retain the status and assumptions of their original
work; a proposal or passing experiment is not a release qualification.
Use the [user guides](../getting-started.md), [current architecture](../ARCHITECTURE.md),
and [trust model](../trust-model.md) for supported behavior.

## Runtime and host control

- [Apple runtime decision](apple-sandbox-runtime.md) and
  [selection experiment](apple-sandbox-experiment.md).
- [Runtime transactions](apple-sandbox-transactions.md): disk changes,
  locking, and recovery.
- [Local and remote execution hosts](local-and-remote-hosts-spec.md):
  implementation status and qualification evidence.
- [Brokered network isolation](brokered-network-isolation.md) (ISO-NET-001):
  the specification for the NIC-less `network.transport: "brokered"`, its
  implementation, native evidence and open qualification items.
- [iso-ci](iso-ci-specification.md) (ISO-CI): the GitHub Actions companion's
  implementation contract and implementation status, with its
  [qualification record](iso-ci-qualification.md) (evidence and defects
  found). Operator guide: [`docs/ci.md`](../ci.md).

## Security and credentials

- [Embedded secrets](embedded-secrets-spec.md): encrypted local storage.
- [Selective hardening](selective-hardening-spec.md): workspace return,
  egress, resource budgets, and audit.
- [Security hardening](iso-security-hardening-spec.md): host-boundary
  hardening and secure defaults — selected-content input, Git-free staged
  return, grant provenance and revocation.
- [Authorization policy](iso-policy.md): evaluation and approval contracts.
- [`iso audit` run history](iso-audit.md): the design review behind the
  `iso.audit/v1` store, reader and JSONL stream, implementation notes, and the
  evidence for each essential check.
- [Credential proxy proposal](issue-411-injecting-proxy.md) and
  [proxy jail compatibility](proxy-jail-graceful-degradation.md).
- [Sandboxy-inspired features](sandboxy-inspired-features-spec.md): proposal
  with implementation and qualification notes.

## Editors

- [Editor providers](editor-providers-spec.md): implemented commands and
  proposed native integrations.
- [Editor hardening](editor-hardening.md): implemented sandbox modes and
  proposed stricter isolation.

## Computer use and experiments

- [macOS runtime design](macos-guest-computer-use.md) and
  [qualification plan](macos-computer-use-qualification-plan.md).
- [Q0 spike results](macos-computer-use-q0-spike.md).
- [Process-context experiment](macos-vz-context-headless-experiment-spec.md)
  and [results](macos-vz-context-experiment.md).
- [Linux computer-use proposal](linux-computer-use-sketch.md).
