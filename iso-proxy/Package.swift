// swift-tools-version: 6.4
import PackageDescription

// Unacknowledged unsafe operations are errors; see docs/code-style.md.
let strictMemorySafety: [SwiftSetting] = [
  .strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error),
]

let package = Package(
  name: "iso-proxy",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "iso-proxy", targets: ["IsoProxy"]),
    // The per-user inference gateway (docs/design/secure-local-inference-spec.md).
    .executable(name: "iso-inference", targets: ["IsoInference"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.2"),
    // The policy evaluator shared with the host CLI; a library, not a process.
    .package(path: "../iso-policy"),
  ],
  targets: [
    .target(
      name: "IsoProxyCore", dependencies: [.product(name: "IsoPolicy", package: "iso-policy")],
      swiftSettings: strictMemorySafety),
    .executableTarget(
      name: "IsoProxy",
      dependencies: [
        "IsoProxyCore", "IsoProxyTransport",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ], swiftSettings: strictMemorySafety),
    .target(
      name: "IsoProxyTransport",
      dependencies: [
        "IsoProxyCore",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "NIOTLS", package: "swift-nio"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "IsoPolicy", package: "iso-policy"),
      ], swiftSettings: strictMemorySafety),
    .testTarget(
      name: "IsoProxyTransportTests",
      dependencies: [
        "IsoProxyTransport", "IsoProxyTestSupport",
        .product(name: "NIOEmbedded", package: "swift-nio"),
        .product(name: "IsoPolicy", package: "iso-policy"),
      ], resources: [.copy("Fixtures")]),
    .target(name: "IsoProxyTestSupport", path: "Tests/IsoProxyTestSupport"),
    .testTarget(name: "IsoProxyE2ETests", dependencies: ["IsoProxyTestSupport"]),
    .testTarget(
      name: "IsoProxyCoreTests",
      dependencies: ["IsoProxyCore", .product(name: "IsoPolicy", package: "iso-policy")]),
    // Fuzz harness bodies. `scripts/fuzz.sh` links them with libFuzzer
    // entrypoints in ../fuzz/Entrypoints; the replay test runs the committed
    // corpus (../fuzz/corpus) through them. Not part of any product.
    .target(
      name: "IsoProxyFuzzHarnesses", dependencies: ["IsoProxyCore", "IsoInferenceCore"],
      path: "Fuzz", swiftSettings: strictMemorySafety),
    .testTarget(name: "IsoProxyFuzzReplayTests", dependencies: ["IsoProxyFuzzHarnesses"]),
    // iso-inference: request policy, scheduling and the control protocol
    // (no I/O), the NIO gateway, and the executable.
    .target(
      name: "IsoInferenceCore", dependencies: ["IsoProxyCore"], swiftSettings: strictMemorySafety),
    .target(
      name: "IsoInferenceGateway",
      dependencies: [
        "IsoInferenceCore", "IsoProxyCore", "IsoProxyTransport",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
      ], swiftSettings: strictMemorySafety),
    .executableTarget(
      name: "IsoInference",
      dependencies: [
        "IsoInferenceCore", "IsoInferenceGateway", "IsoProxyCore",
        .product(name: "NIOPosix", package: "swift-nio"),
      ], swiftSettings: strictMemorySafety),
    .testTarget(
      name: "IsoInferenceCoreTests", dependencies: ["IsoInferenceCore", "IsoProxyCore"],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "IsoInferenceGatewayTests",
      dependencies: [
        "IsoInferenceGateway", "IsoInferenceCore", "IsoProxyCore",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ]),
  ],
  swiftLanguageModes: [.v6]
)

// Warnings in this package's own targets fail the build; SwiftPM does not
// apply this to remote dependencies. See docs/code-style.md.
// The mutation scripts' scratch builds set ISO_MUTATION_BUILD: a deliberate
// fault may leave a value unused, and that warning must not hide the test.
if Context.environment["ISO_MUTATION_BUILD"] == nil {
  for target in package.targets {
    target.swiftSettings = [.treatAllWarnings(as: .error)] + (target.swiftSettings ?? [])
  }
}
