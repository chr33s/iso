# iso-sandbox fixtures

Representative protocol-5 output from `iso-sandbox` 0.1.0 with
containerization 0.54.0, used by host runtime-boundary tests.

- `version.json` — what `iso-sandbox version` prints from a default build:
  runtime version, qualified protocol/dependency and features.
- `inspect-stopped.json` — a created, stopped sandbox.
- `inspect-running.json` — a running sandbox, live owner and effective VM configuration.
- `inspect-brokered-running.json` — a running `--network brokered` sandbox, captured
  from a real boot (identifiers and paths rewritten to the values below): no
  interface or address, the owner's live device counts, and the runtime's
  channel policy and digest, which the host recomputes and must match.

- `inspect-display-running.json` — a running `--display virtio
  --guest-computer-use` sandbox mid-stream, captured from the `display`
  phase of `tests/integration-apple-sandbox.sh` (kept as
  `display-inspect.json` with `--keep`; identifiers, paths and the image
  reference rewritten as below): the display, its one scanout, vsock 7802,
  an open live-view listener, and this boot's computer-use counts under
  `runtime`.

The record has an explicit `network` mode, and running live state has a
nonempty `bootId`. Missing required fields must fail decoding. Optional operation
and expiration values reflect whether that operation or TTL exists.

The sandbox ID is `iso-0a1b2c3d-00112233445566ff`, the owner is
`0a1b2c3d00112233445566778899aabb`, and the runtime root is
`/Users/me/.iso/backends/apple-container-v1/runtime`. Tests substitute their
own values. Update these fixtures with runtime contract changes and bump the
protocol for incompatible changes.

Both sides test against these files. The host decodes them through
`RuntimeProtocol` (`tests/swift/IsoHostTests`). The runtime's
`HostFixtureConformanceTests` (`iso-sandbox/Tests/IsoSandboxTests`) checks that
`version.json` equals what its `version` command encodes, that
each `inspect-*.json` decodes with its record, live-state and
effective-configuration types and re-encodes to the same JSON value, and that
the brokered fixture carries its current channel policy and digest. A new
`inspect-*.json` must be added to that suite's list.
