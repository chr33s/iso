// swift-tools-version: 6.4
// Q0 go/no-go spike for macOS-guest computer use; see
// docs/design/macos-computer-use-q0-spike.md. Not part of the shipped product.
import PackageDescription

let package = Package(
  name: "macos-computer-use-q0",
  platforms: [.macOS("27.0")],
  products: [
    .executable(name: "q0-owner", targets: ["Q0Owner"]),
    .executable(name: "q0-fixture", targets: ["Q0Fixture"]),
    .executable(name: "q0-helper", targets: ["Q0Helper"]),
  ],
  targets: [
    // Host: VM owner, frame capture, input injection, control socket.
    .executableTarget(name: "Q0Owner"),
    // Guest: AppKit oracle app (render / grid / keys).
    .executableTarget(name: "Q0Fixture"),
    // Guest: vsock boot-identity helper.
    .executableTarget(name: "Q0Helper"),
  ]
)
