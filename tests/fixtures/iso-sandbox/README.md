# iso-sandbox fixtures

Representative protocol-5 output from `iso-sandbox` 0.5.0 with
containerization 0.45.0, used by host runtime-boundary tests.

- `version.json` — runtime version and qualified protocol/dependency.
- `inspect-stopped.json` — a created, stopped sandbox.
- `inspect-running.json` — a running sandbox, live owner and effective VM configuration.

The record has an explicit `network` mode, and running live state has a
nonempty `bootId`. Missing required fields must fail decoding. Optional operation
and expiration values reflect whether that operation or TTL exists.

The sandbox ID is `iso-0a1b2c3d-00112233445566ff`, the owner is
`0a1b2c3d00112233445566778899aabb`, and the runtime root is
`/Users/me/.iso/backends/apple-container-v1/runtime`. Tests substitute their
own values. Update these fixtures with runtime contract changes and bump the
protocol for incompatible changes.
