// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "coop-proxy",
  platforms: [.macOS("27.0")],
  products: [
    .library(name: "CoopProxyCore", targets: ["CoopProxyCore"]),
    .executable(name: "coop-proxy-swift", targets: ["CoopProxy"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.100.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.36.1"),
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.2"),
  ],
  targets: [
    .target(name: "CoopProxyCore"),
    .executableTarget(
      name: "CoopProxy",
      dependencies: [
        "CoopProxyCore", "CoopProxyTransport",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]),
    .target(
      name: "CoopProxyTransport",
      dependencies: [
        "CoopProxyCore",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "NIOTLS", package: "swift-nio"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
      ]),
    .testTarget(
      name: "CoopProxyTransportTests",
      dependencies: [
        "CoopProxyTransport",
        .product(name: "NIOEmbedded", package: "swift-nio"),
      ], resources: [.copy("Fixtures")]),
    .testTarget(name: "CoopProxyCoreTests", dependencies: ["CoopProxyCore"]),
  ]
)
