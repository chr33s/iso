# Release validation

A release is qualified against its exact source revision and the five binaries
in its archive: `iso`, `iso-sandbox`, `iso-proxy`, `iso-egress`, and
`iso-macos-helper`. Results
from earlier revisions do not qualify a changed candidate. This document lists
required evidence; it does not claim that any unexecuted gate has passed.

Before publication, record the revision, toolchain, commands and results for:

- Package format, build and test checks for all four Swift packages, the host
  behavior/CLI contracts, and the host-only install/update/uninstall suites.
- Relevant fault-injection tests, parser corpus replay, fuzz smoke, and
  sanitizer checks. A mutation must fail a running test; compile failures are
  inconclusive.
- Apple VM lifecycle and isolation integration on supported macOS hardware,
  including interrupted-operation recovery, host-key continuity, workspace
  transfers, port forwarding and devcontainer Features where changed.
- Credential-proxy forwarding through real guest SSH tunnels to controlled TLS
  upstreams, secret-leak scans, disconnects, startup failure and cleanup. Test
  certificate or loopback fixtures do not qualify live provider behavior.
- Approved live provider models with dedicated test credentials: Anthropic
  streaming and token counting, OpenAI Responses, disconnect/recovery, and
  successful Claude/Codex guest tool use. Model and credential approval is
  separate from ordinary local regression testing.
- Filtered-egress qualification, including NET-20/F1 and the adversarial cases
  in [testing](testing.md). Partial local observations do not qualify this
  mode for a release claim.
- A same-revision hosted candidate: archive checksum, all five binary digests,
  clean source metadata, Developer ID signatures, notarization, and pinned
  workflow attestation. Validate clean-machine install, run, update and
  uninstall. Local ad-hoc signing is not hosted distribution evidence.
- Final scope-controlled review after all changes and test repairs.

The commands, fixture limitations and platform requirements are documented in
[testing](testing.md). Packaging, signing and publication are described in
[RELEASING.md](../RELEASING.md). Keep the source and dependency attribution in
[NOTICE](../NOTICE), [PROVENANCE.md](../PROVENANCE.md), and
[THIRD_PARTY_LICENSES.md](../THIRD_PARTY_LICENSES.md).
