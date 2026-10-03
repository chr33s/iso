# iso-proxy

The Swift-only credential proxy for the [isolate fork](../README.md), requiring
macOS 27+ and Xcode 27. It holds provider credentials on the host, authenticates
guest requests with per-VM capabilities, and admits only fixed provider operations.
The isolate host CLI launches it as a separate process under Seatbelt confinement.

Run from the repository root:

```sh
swift build --package-path iso-proxy --force-resolved-versions
swift test --package-path iso-proxy --force-resolved-versions
```

SwiftPM produces `iso-proxy`. Install it beside `iso`;
see [source installation](../docs/getting-started.md#build-from-source).
The Apple runtime is the separate [`iso-sandbox/`](../iso-sandbox/) package.

See [proxy configuration and contract](../docs/credential-proxy.md),
[testing](../docs/testing.md), and [acceptance status](../docs/release-validation.md).
