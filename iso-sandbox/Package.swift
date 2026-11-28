// swift-tools-version: 6.4
// iso-sandbox: iso's macOS VM runtime, built directly on apple/containerization.
// Pinned exactly: the package's API changes between minor releases.
import PackageDescription

let package = Package(
  name: "iso-sandbox",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "iso-sandbox", targets: ["IsoSandbox"]),
    // Installed into macOS guest templates; see docs/design/macos-guest-computer-use.md.
    .executable(name: "iso-macos-helper", targets: ["IsoMacHelper"]),
    .executable(name: "iso-cu-mcp", targets: ["IsoCUMCP"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/containerization.git", exact: "0.57.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    .package(url: "https://github.com/apple/swift-system.git", exact: "1.9.0"),
  ],
  targets: [
    // Guest-driven computer use, shared by the runtime and both guest
    // servers; Foundation only, so it also builds for Linux.
    .target(name: "IsoGuestCU"),
    .target(name: "IsoMacProtocol", dependencies: ["IsoGuestCU"]),
    .executableTarget(name: "IsoCUMCP", dependencies: ["IsoGuestCU"]),
    .executableTarget(name: "IsoMacHelper", dependencies: ["IsoMacProtocol"]),
    .target(
      name: "IsoSandboxCore",
      dependencies: [
        "IsoMacProtocol",
        .product(name: "Containerization", package: "containerization"),
        .product(name: "ContainerizationExtras", package: "containerization"),
        .product(name: "ContainerizationOCI", package: "containerization"),
        .product(name: "ContainerizationEXT4", package: "containerization"),
        .product(name: "ContainerizationOS", package: "containerization"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
    .executableTarget(
      name: "IsoSandbox",
      dependencies: [
        "IsoSandboxCore",
        "IsoMacProtocol",
        .product(name: "Containerization", package: "containerization"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .testTarget(
      name: "IsoSandboxTests",
      dependencies: [
        "IsoSandboxCore",
        "IsoMacProtocol",
        .product(name: "ContainerizationEXT4", package: "containerization"),
        .product(name: "SystemPackage", package: "swift-system"),
      ]
    ),
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
