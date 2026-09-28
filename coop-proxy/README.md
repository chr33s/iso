# coop-proxy

The Swift-only credential proxy for the [coop fork](../README.md), requiring
macOS 27+ and Xcode 27. It holds provider credentials on the host, authenticates
guest requests with per-VM capabilities, and admits only fixed provider operations.
The coop host CLI launches it as a separate process under Seatbelt confinement.

Run from the repository root:

```sh
swift build --package-path coop-proxy --force-resolved-versions
swift test --package-path coop-proxy --force-resolved-versions
```

SwiftPM produces `coop-proxy-swift`. Install it as `coop-proxy` beside `coop`;
see [source installation](../docs/getting-started.md#build-from-source).
The Apple runtime is the separate [`coop-sandbox/`](../coop-sandbox/) package.

See [proxy configuration and contract](../docs/credential-proxy.md),
[testing](../docs/testing.md), and [acceptance status](../docs/design/swift-proxy-acceptance.md).
