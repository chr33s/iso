// swift-tools-version: 6.4
// Destination-filtered CONNECT companion. This package does not link
// iso-proxy and has no provider-credential code.
import PackageDescription

// Unacknowledged unsafe operations are errors; see docs/code-style.md.
let strictMemorySafety: [SwiftSetting] = [
  .strictMemorySafety(), .treatWarning("StrictMemorySafety", as: .error),
]

let package = Package(
  name: "iso-egress",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "iso-egress", targets: ["IsoEgress"])
  ],
  targets: [
    .target(name: "IsoEgressCore", swiftSettings: strictMemorySafety),
    .executableTarget(
      name: "IsoEgress", dependencies: ["IsoEgressCore"], swiftSettings: strictMemorySafety),
    .testTarget(name: "IsoEgressCoreTests", dependencies: ["IsoEgressCore"]),
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
