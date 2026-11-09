import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../..").standardized

@Test func coreAISelectsTheExperimentalRuntimeByName() {
  #expect(
    BinaryResolver.defaultRuntimes(
      home: "/h", executable: "/opt/iso/bin/iso", name: "iso-sandbox-coreai")
      == [
        "/opt/iso/bin/iso-sandbox-coreai", "/h/.local/opt/iso-sandbox/bin/iso-sandbox-coreai",
        "/usr/local/bin/iso-sandbox-coreai", "/opt/homebrew/bin/iso-sandbox-coreai",
      ])
  #expect(
    BinaryResolver.defaultRuntimes(home: "/h", executable: nil)
      == [
        "/h/.local/opt/iso-sandbox/bin/iso-sandbox", "/usr/local/bin/iso-sandbox",
        "/opt/homebrew/bin/iso-sandbox",
      ])
}

@Test func aConfigWithCoreAIRefusesAMissingExperimentalRuntime() throws {
  let config = try testConfig(
    #""coreai": {"accelerators": ["gpu"], "acknowledge_reduced_host_security": true}"#)
  let home = FileManager.default.temporaryDirectory.appending(path: "coreai-\(UUID().uuidString)")
    .path
  let error = try #require(throws: RuntimeError.self) {
    try SandboxRuntime.open(config, environment: ["HOME": home], executable: home + "/iso")
  }
  #expect("\(error)".contains("iso-sandbox-coreai"))
  #expect("\(error)".contains("--experimental-coreai"))
}

@Test func theCoreAIBuildMustAdvertiseItAndCarryThePrivateEntitlement() throws {
  let feature: Set<String> = ["macos-guests", "macos-coreai"]
  try CoreAIRuntime.check(features: feature, entitlements: nil)
  try CoreAIRuntime.check(
    features: feature, entitlements: ["com.apple.private.virtualization": true])
  #expect(throws: HostError.self) {
    try CoreAIRuntime.check(features: ["macos-guests"], entitlements: nil)
  }
  for entitlements: [String: Any] in [
    [:], ["com.apple.private.virtualization": false],
    ["com.apple.security.virtualization": true],
  ] {
    let error = try #require(throws: HostError.self) {
      try CoreAIRuntime.check(features: feature, entitlements: entitlements)
    }
    #expect(error.message.hasPrefix(CoreAIRuntime.missing))
  }
}

@Test func entitlementsAreReadFromTheSignature() throws {
  let dir = FileManager.default.temporaryDirectory.appending(path: "coreai-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  func signed(_ entitlements: String) throws -> String {
    let path = dir.appending(path: (entitlements as NSString).lastPathComponent + ".bin").path
    try Data(contentsOf: URL(fileURLWithPath: "/usr/bin/true")).write(
      to: URL(fileURLWithPath: path))
    chmod(path, 0o755)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = [
      "--force", "--sign", "-", "--entitlements", root.appending(path: entitlements).path, path,
    ]
    sign.standardOutput = FileHandle.nullDevice
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    #expect(sign.terminationStatus == 0)
    return path
  }
  let coreAI = try CoreAIRuntime.entitlements(
    try signed("iso-sandbox/iso-sandbox-coreai.entitlements"))
  #expect(coreAI["com.apple.private.virtualization"] as? Bool == true)
  try CoreAIRuntime.check(features: ["macos-coreai"], entitlements: coreAI)
  let plain = try CoreAIRuntime.entitlements(try signed("iso-sandbox/iso-sandbox.entitlements"))
  #expect(plain["com.apple.security.virtualization"] as? Bool == true)
  #expect(throws: HostError.self) {
    try CoreAIRuntime.check(features: ["macos-coreai"], entitlements: plain)
  }
}
