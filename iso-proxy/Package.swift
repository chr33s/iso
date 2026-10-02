// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "iso-proxy",
  platforms: [.macOS("27.0")],
  products: [
    .library(name: "IsoProxyCore", targets: ["IsoProxyCore"]),
    .executable(name: "iso-proxy-swift", targets: ["IsoProxy"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.100.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.1"),
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.2"),
  ],
  targets: [
    .target(name: "IsoProxyCore"),
    .executableTarget(
      name: "IsoProxy",
      dependencies: [
        "IsoProxyCore", "IsoProxyTransport",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]),
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
      ]),
    .testTarget(
      name: "IsoProxyTransportTests",
      dependencies: [
        "IsoProxyTransport", "IsoProxyTestSupport",
        .product(name: "NIOEmbedded", package: "swift-nio"),
      ], resources: [.copy("Fixtures")]),
    .target(name: "IsoProxyTestSupport", path: "Tests/IsoProxyTestSupport"),
    .testTarget(name: "IsoProxyE2ETests", dependencies: ["IsoProxyTestSupport"]),
    .testTarget(name: "IsoProxyCoreTests", dependencies: ["IsoProxyCore"]),
  ]
)
