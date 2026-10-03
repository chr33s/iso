// swift-tools-version: 6.4
// Destination-filtered CONNECT companion. This package does not link
// iso-proxy and has no provider-credential code.
import PackageDescription

let package = Package(
  name: "iso-egress",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "iso-egress", targets: ["IsoEgress"])
  ],
  targets: [
    .target(name: "IsoEgressCore"),
    .executableTarget(name: "IsoEgress", dependencies: ["IsoEgressCore"]),
    .testTarget(name: "IsoEgressCoreTests", dependencies: ["IsoEgressCore"]),
  ],
  swiftLanguageModes: [.v6]
)
