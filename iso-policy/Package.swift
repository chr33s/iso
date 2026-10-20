// swift-tools-version: 6.4
// IsoPolicy: the default-deny permit/forbid evaluator, sliding-window
// admissions and single-use approvals shared by the host CLI and the
// credential proxy (docs/design/iso-policy.md); IsoGitIndex: the inert Git
// index reader shared by the host and iso-ci. Libraries only: no runtime
// process, no networking, no subprocesses, no third-party dependencies.
import PackageDescription

let package = Package(
  name: "iso-policy",
  platforms: [.macOS("27.0")],
  products: [
    .library(name: "IsoPolicy", targets: ["IsoPolicy"]),
    .library(name: "IsoGitIndex", targets: ["IsoGitIndex"]),
  ],
  targets: [
    .target(name: "IsoPolicy"),
    .target(name: "IsoGitIndex"),
    .testTarget(name: "IsoGitIndexTests", dependencies: ["IsoGitIndex"]),
    .testTarget(
      name: "IsoPolicyTests", dependencies: ["IsoPolicy"], resources: [.copy("Fixtures")]),
    // `swift run -c release --package-path iso-policy IsoPolicyBench`; not a product.
    .executableTarget(
      name: "IsoPolicyBench", dependencies: ["IsoPolicy"], path: "Benchmarks/IsoPolicyBench"),
  ],
  swiftLanguageModes: [.v6]
)
