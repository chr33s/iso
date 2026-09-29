// swift-tools-version: 6.2
// iso host CLI (Swift port; see docs/design/swift-host-spec.md). The runtime
// (`iso-sandbox/`) and credential proxy (`iso-proxy/`) remain separate
// packages and separate processes; this package never links them.
import PackageDescription

let package = Package(
  name: "iso",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "iso", targets: ["IsoCLI"]),
    .library(name: "IsoConfiguration", targets: ["IsoConfiguration"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    // scrypt only (CryptoExtras); every other primitive comes from CryptoKit.
    // See docs/design/embedded-secrets-spec.md section 7.
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0"),
  ],
  targets: [
    .target(name: "IsoCore"),
    .target(name: "IsoConfiguration", dependencies: ["IsoCore"]),
    // The local secret store; must not depend on IsoHost (VM/runtime code).
    .target(
      name: "IsoSecrets",
      dependencies: ["IsoCore", .product(name: "CryptoExtras", package: "swift-crypto")]),
    // seatbelt-proxy.sb is the canonical copy of the embedded profile
    // (SeatbeltProfile.swift); the proxy test scripts pass it to sandbox-exec.
    .target(
      name: "IsoHost", dependencies: ["IsoCore", "IsoConfiguration", "IsoSecrets"],
      exclude: ["seatbelt-proxy.sb"]),
    .executableTarget(
      name: "IsoCLI",
      dependencies: [
        "IsoCore", "IsoConfiguration", "IsoHost", "IsoSecrets",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    // tests/ also holds the integration scripts; Swift tests live under
    // tests/swift (a separate Tests/ would alias it on case-insensitive disks).
    // Fuzz harness bodies (fuzz/Targets). `scripts/fuzz.sh` links them with
    // libFuzzer entrypoints; the replay test runs the corpus through them in
    // ordinary builds. Not part of any product.
    .target(
      name: "IsoFuzzHarnesses", dependencies: ["IsoCore", "IsoConfiguration"],
      path: "fuzz/Targets"),
    .testTarget(
      name: "IsoFuzzReplayTests", dependencies: ["IsoFuzzHarnesses"],
      path: "tests/swift/IsoFuzzReplayTests"),
    .testTarget(
      name: "IsoCoreTests", dependencies: ["IsoCore"], path: "tests/swift/IsoCoreTests"),
    .testTarget(
      name: "IsoConfigurationTests", dependencies: ["IsoConfiguration"],
      path: "tests/swift/IsoConfigurationTests", resources: [.copy("Fixtures")]),
    .testTarget(
      name: "IsoHostTests", dependencies: ["IsoHost"], path: "tests/swift/IsoHostTests"),
    .testTarget(
      name: "IsoSecretsTests", dependencies: ["IsoSecrets"], path: "tests/swift/IsoSecretsTests"),
    .testTarget(name: "IsoCLITests", dependencies: ["IsoCLI"], path: "tests/swift/IsoCLITests"),
  ],
  swiftLanguageModes: [.v6]
)
