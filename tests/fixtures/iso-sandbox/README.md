# iso-sandbox fixtures

Output of `iso-sandbox` (containerization 0.45.0), captured from one
sandbox on macOS 27 and used by the `apple_container` unit tests. The inspect
records were captured from 0.1.0 (protocol 1); in inspect output, protocol 2
only adds the optional `record.lastOperation`, absent until a sandbox's first `set`, `grow`,
or `restore`, and protocol 3 only adds the optional `record.network` (absent
for shared-mode sandboxes) and the `vmnet-host:` interface label for
host-only ones, and protocol 4 only adds the optional `record.expiresAt`
(absent without a session TTL), so they are unchanged, and `version.json` was
updated to 0.4.0:

- `version.json` — `iso-sandbox version`
- `inspect-stopped.json` — `iso-sandbox inspect` of a created, stopped sandbox
- `inspect-running.json` — the same sandbox running (live state and effective
  VM configuration)

The sandbox id is `coop-0a1b2c3d-00112233445566ff`, the owner
`0a1b2c3d00112233445566778899aabb`, and the runtime root was rewritten to
`/Users/me/.iso/backends/apple-container-v1/runtime`; the tests
substitute their own values for all three. Regenerate after any change to the
runtime's JSON output, and bump the protocol version for an incompatible one.
