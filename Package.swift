// swift-tools-version: 6.2
// coop host CLI (Swift port; see docs/design/swift-host-spec.md). The runtime
// (`coop-sandbox/`) and credential proxy (`coop-proxy/`) remain separate
// packages and separate processes; this package never links them.
import PackageDescription

let package = Package(
  name: "coop",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "coop", targets: ["CoopCLI"]),
    .library(name: "CoopConfiguration", targets: ["CoopConfiguration"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
    // scrypt only (CryptoExtras); every other primitive comes from CryptoKit.
    // See docs/design/embedded-secrets-spec.md section 7.
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0"),
  ],
  targets: [
    .target(name: "CoopCore"),
    .target(name: "CoopConfiguration", dependencies: ["CoopCore"]),
    // The local secret store; must not depend on CoopHost (VM/runtime code).
    .target(
      name: "CoopSecrets",
      dependencies: ["CoopCore", .product(name: "CryptoExtras", package: "swift-crypto")]),
    // seatbelt-proxy.sb is the canonical copy of the embedded profile
    // (SeatbeltProfile.swift); the proxy test scripts pass it to sandbox-exec.
    .target(
      name: "CoopHost", dependencies: ["CoopCore", "CoopConfiguration", "CoopSecrets"],
      exclude: ["seatbelt-proxy.sb"]),
    .executableTarget(
      name: "CoopCLI",
      dependencies: [
        "CoopCore", "CoopConfiguration", "CoopHost", "CoopSecrets",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]),
    // tests/ also holds the integration scripts; Swift tests live under
    // tests/swift (a separate Tests/ would alias it on case-insensitive disks).
    // Fuzz harness bodies (fuzz/Targets). `scripts/fuzz.sh` links them with
    // libFuzzer entrypoints; the replay test runs the corpus through them in
    // ordinary builds. Not part of any product.
    .target(
      name: "CoopFuzzHarnesses", dependencies: ["CoopCore", "CoopConfiguration"],
      path: "fuzz/Targets"),
    .testTarget(
      name: "CoopFuzzReplayTests", dependencies: ["CoopFuzzHarnesses"],
      path: "tests/swift/CoopFuzzReplayTests"),
    .testTarget(
      name: "CoopCoreTests", dependencies: ["CoopCore"], path: "tests/swift/CoopCoreTests"),
    .testTarget(
      name: "CoopConfigurationTests", dependencies: ["CoopConfiguration"],
      path: "tests/swift/CoopConfigurationTests", resources: [.copy("Fixtures")]),
    .testTarget(
      name: "CoopHostTests", dependencies: ["CoopHost"], path: "tests/swift/CoopHostTests"),
    .testTarget(
      name: "CoopSecretsTests", dependencies: ["CoopSecrets"], path: "tests/swift/CoopSecretsTests"),
    .testTarget(name: "CoopCLITests", dependencies: ["CoopCLI"], path: "tests/swift/CoopCLITests"),
  ],
  swiftLanguageModes: [.v6]
)
