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
    .executable(name: "iso-proxy", targets: ["IsoProxy"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.100.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.1"),
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
  ],
  swiftLanguageModes: [.v6]
)
