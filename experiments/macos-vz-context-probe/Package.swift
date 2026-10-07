// swift-tools-version: 6.4
// Architecture-selection experiment: which host process/session/UI context a
// macOS VZVirtualMachine and its VZVirtualMachineView need. See
// docs/design/macos-vz-context-headless-experiment-spec.md and README.md.
// Not part of the shipped product.
import PackageDescription

let package = Package(
  name: "macos-vz-context-probe",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "vz-context-probe", targets: ["VZContextProbe"]),
    .executable(name: "iso-vz-probe-fixture", targets: ["ProbeFixture"]),
    .executable(name: "iso-vz-probe-helper", targets: ["ProbeHelper"]),
  ],
  targets: [
    // Host: context report, headless VM owner, view owner, frame analysis.
    .executableTarget(name: "VZContextProbe"),
    // Guest: AppKit fixture (token, frame counter, grid, text, keys, drag, scroll).
    .executableTarget(name: "ProbeFixture"),
    // Guest: vsock boot-identity helper, runs as a guest LaunchDaemon.
    .executableTarget(name: "ProbeHelper"),
  ]
)
