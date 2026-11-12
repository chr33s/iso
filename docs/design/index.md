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
- [Credential proxy proposal](issue-411-injecting-proxy.md).
- [Sandboxy-inspired features](sandboxy-inspired-features-spec.md): draft
  proposal only; it records no implementation or qualification.

## Editors

- [Editor providers](editor-providers-spec.md): implemented commands and
  proposed native integrations.
- [Editor hardening](editor-hardening.md): implemented sandbox modes and
  proposed stricter isolation.

## Computer use and experiments

- [macOS runtime design](macos-guest-computer-use.md) and
  [qualification plan](macos-computer-use-qualification-plan.md).
- [Guest permission-dialog responder](permission-dialog-auto-response.md):
  `cu respond` for expected TCC folder-access prompts; Keychain and
  authentication prompts are reported, not answered.
- [Guest-driven computer use](guest-driven-computer-use.md): an agent in a
  macOS guest drives its own desktop through a host-brokered vsock channel
  and the VM's virtual HID devices.
- [Paravirtualized Core AI](paravirtualized-coreai.md): experimental GPU and
  Neural Engine Core AI for macOS guests through private API, at the cost of
  a host running with AMFI relaxed. Follow-up: VM save/restore of a Core AI
  instance needs the host flag `ParavirtualizedCoreAIHost/enable_save_restore`
  (§11) once iso has snapshots; until then Core AI instances only shut down.
- [Q0 spike results](macos-computer-use-q0-spike.md).
- [Process-context experiment](macos-vz-context-headless-experiment-spec.md)
  and [results](macos-vz-context-experiment.md).
- [Linux computer-use proposal](linux-computer-use-sketch.md): superseded by
  the implemented virtio-gpu display; kept as the record of the alternative.
- [Screen sync](computer-use-screen-sync.md): a damage sequence and a
  wait operation, so an agent can tell when the screen has settled after
  input. Implemented and qualified on one host.
- [Live view and browser takeover](computer-use-live-view.md): a loopback
  H.264 viewer with takeover under the host hold. Implemented and approved;
  qualified on one host.
- [Linux computer use through a virtio-gpu display](linux-desktop-virtio-gpu.md):
  implemented for Linux guests built with the `desktop` profile. A
  host-driven display device instead of an in-guest helper: a second,
  iso-built kernel with the drivers, capture from the view's framebuffer
  surface, and the macOS guests' input, wait, live-view and guest-access
  code. Qualified on one host; the release workflows' new steps have not
  run in CI (§13). It records why an in-guest `voxl` was rejected.
