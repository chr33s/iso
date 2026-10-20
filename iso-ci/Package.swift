// swift-tools-version: 6.4
// iso-ci: GitHub Actions companion (docs/design/iso-ci-specification.md).
// Base iso never links or requires this package.
import PackageDescription

let package = Package(
  name: "iso-ci",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "iso-ci", targets: ["IsoCI"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    // The guest-facing preflight data plane (HTTP/1.1 over a Unix socket).
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.100.0"),
  ],
  targets: [
    .target(
      name: "IsoCICore",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ],
      linkerSettings: [.linkedLibrary("sqlite3")]),
    .executableTarget(
      name: "IsoCI",
      dependencies: [
        "IsoCICore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    .testTarget(
      name: "IsoCICoreTests", dependencies: ["IsoCICore"], resources: [.copy("Fixtures")]),
  ],
  swiftLanguageModes: [.v6]
)
