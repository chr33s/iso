# Vendored apple/containerization

This directory is [apple/containerization](https://github.com/apple/containerization)
at tag `0.45.0` (`9eacc197d7c3663eb29cbab6d51244ede6d1cd7d`), plus two host-side
fixes to `UnixSocketRelay`. iso-sandbox needs them to relay the inference
gateway socket into a guest (secure-local-inference spec §22). The guest
agent stays the pinned `vminit:0.45.0` image. Both fixes are host-only.

| Patch | Change | Upstream |
|---|---|---|
| `../patches/0001-Backport-host-relay-fix-from-8b8cd7e-933.patch` | `UnixSocketRelay.swift` and its tests from `8b8cd7e` ("Fix socket forwarding hangs and shared I/O stalls", #933): a failed per-connection setup closes that connection only, so the listener keeps accepting. | Merged on `main` after 0.45.0; not yet released. |
| `../patches/0002-Limit-concurrent-connections-in-UnixSocketRelay.patch` | `UnixSocketConfiguration.maxConnections`: a connection that arrives at the limit is closed before the other side is dialed, so a guest cannot exhaust the owner process's file descriptors. | Not yet proposed upstream. |

Trimmed from the upstream tree:

- repository tooling, examples and documentation;
- every test target except `ContainerizationUnitTests`, which holds only `UnixSocketRelayTests.swift`;
- that target's image resources.

Run the relay tests with:

```bash
swift test --package-path iso-sandbox/Vendor/containerization --filter UnixSocketRelayTests
```

**Remove this directory** once a containerization release contains both
changes. Point `iso-sandbox/Package.swift` back at that release with an
`exact:` pin, bump the `vminit` image pin in `IsoSandbox/CLI.swift` to the
same version, and re-run the Apple VM integration suite.
