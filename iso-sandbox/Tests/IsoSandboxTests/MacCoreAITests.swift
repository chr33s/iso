import Foundation
import IsoMacProtocol
import Testing
import Virtualization

@testable import IsoSandboxCore

// Paravirtualized Core AI (docs/design/paravirtualized-coreai.md). These run against the
// default build, which has no Core AI support: nothing is attached, anything requested is
// refused.

private let authorized = "ssh-ed25519 " + Data(repeating: 7, count: 51).base64EncodedString()

private func tempRoot() throws -> SandboxRoot {
  try SandboxRoot(
    FileManager.default.temporaryDirectory.appendingPathComponent("coreai-\(UUID().uuidString)")
      .path)
}

private func template(_ root: SandboxRoot, _ name: String, flag: Bool?) throws -> SandboxID {
  try root.createMacDirectories()
  let id = try SandboxID(name)
  let t = root.macTemplate(id)
  try FileManager.default.createDirectory(at: t.dir, withIntermediateDirectories: true)
  for f in [t.disk, t.aux, t.hardwareModel] { try Data("x".utf8).write(to: f) }
  let meta = MacTemplate(
    name: id, productVersion: "27.3", build: "27D1", ipswSha256: "0", helperSha256: "0",
    diskBytes: 1, minimumCPUs: 2, minimumMemoryBytes: 4 << 30, createdAt: Date(),
    coreAIFeatureFlag: flag)
  try JSONEncoder.pretty.encode(meta).write(to: t.metadata)
  return id
}

/// One of each device Gate O expects, on a NAT attachment so the device
/// check's last step (vmnet only) is reached and named.
private func gateOConfiguration() throws -> VZVirtualMachineConfiguration {
  let disk = FileManager.default.temporaryDirectory.appendingPathComponent(
    "coreai-\(UUID().uuidString).img")
  try Data(count: 4096).write(to: disk)
  let c = VZVirtualMachineConfiguration()
  let gfx = VZMacGraphicsDeviceConfiguration()
  gfx.displays = [
    VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)
  ]
  c.graphicsDevices = [gfx]
  c.storageDevices = [
    VZVirtioBlockDeviceConfiguration(
      attachment: try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false))
  ]
  let net = VZVirtioNetworkDeviceConfiguration()
  net.attachment = VZNATNetworkDeviceAttachment()
  c.networkDevices = [net]
  c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
  c.keyboards = [VZMacKeyboardConfiguration()]
  c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
  return c
}

@Test func coreAIAcceleratorListsAreNonEmptyKnownAndUnique() throws {
  #expect(try MacCoreAI(parsing: "gpu,neural_engine").accelerators == [.gpu, .neuralEngine])
  #expect(try MacCoreAI(parsing: "neural_engine").accelerators == [.neuralEngine])
  for bad in ["", "gpu,", "gpu,gpu", "cpu", "GPU", "gpu neural_engine"] {
    #expect(throws: SandboxError.self, "\(bad)") { try MacCoreAI(parsing: bad) }
  }
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(MacCoreAI.self, from: Data(#"{"accelerators":[]}"#.utf8))
  }
}

@Test func recordsAndTemplatesWithoutCoreAIStillDecode() async throws {
  let root = try tempRoot()
  let plain = try template(root, "plain", flag: nil)
  #expect(try !root.macTemplate(plain).load().hasCoreAIFeatureFlag)
  let flagged = try template(root, "t-coreai", flag: true)
  #expect(try root.macTemplate(flagged).load().hasCoreAIFeatureFlag)
  let record = try await MacSandboxes.create(
    root: root, id: try SandboxID("m1"), owner: "o", template: plain, cpus: 4,
    memoryBytes: 8 << 30, network: .shared, authorizedKey: authorized)
  #expect(record.coreAI == nil)
  let json = String(decoding: try JSONEncoder.pretty.encode(record), as: UTF8.self)
  #expect(!json.contains("coreAI"))
}

@Test func coreAINeedsATemplateWithTheFeatureFlag() async throws {
  let root = try tempRoot()
  let plain = try template(root, "plain", flag: nil)
  let flagged = try template(root, "t-coreai", flag: true)
  let coreAI = try MacCoreAI(accelerators: [.gpu, .neuralEngine])
  let refused = await #expect(throws: SandboxError.self) {
    try await MacSandboxes.create(
      root: root, id: try SandboxID("m1"), owner: "o", template: plain, cpus: 4,
      memoryBytes: 8 << 30, network: .shared, authorizedKey: authorized, coreAI: coreAI)
  }
  #expect(refused?.description.contains("iso setup --guest macos --coreai") == true)
  #expect(!FileManager.default.fileExists(atPath: root.macSandbox(try SandboxID("m1")).dir.path))
  let record = try await MacSandboxes.create(
    root: root, id: try SandboxID("m2"), owner: "o", template: flagged, cpus: 4,
    memoryBytes: 8 << 30, network: .shared, authorizedKey: authorized, coreAI: coreAI)
  #expect(record.coreAI == coreAI)
  #expect(try root.macSandbox(record.id).loadRecord().coreAI == coreAI)
}

@Test func theDefaultBuildAttachesNothingAndRefusesAnyRequestedAccelerator() throws {
  #expect(!MacAccelerators.compiledIn)
  #expect(!MacAccelerators.isAvailable())
  let c = try gateOConfiguration()
  #expect(MacAccelerators.attached(c).isEmpty)
  let off = #expect(throws: SandboxError.self) {
    try MacConfig.requireOnlyExpectedDevices(c, expectedAccelerators: [])
  }
  #expect(off?.description.contains("non-vmnet") == true)
  let on = #expect(throws: SandboxError.self) {
    try MacConfig.requireOnlyExpectedDevices(c, expectedAccelerators: [.gpu])
  }
  #expect(on?.description.contains("no Core AI support") == true)
  #expect(throws: SandboxError.self) { try MacAccelerators.apply([.neuralEngine], to: c) }
  try MacAccelerators.apply([], to: c)
}

@Test func effectiveConfigReadsAcceleratorsBackFromTheConfiguration() throws {
  let c = try gateOConfiguration()
  let record = MacSandboxRecord(
    id: try SandboxID("m1"), owner: "o", template: try SandboxID("t"), templateBuild: "b",
    cpus: 4, memoryBytes: 8 << 30, macAddress: "02:00:00:00:00:01", subnetIndex: 3,
    network: .shared, enrollment: .enrolled, authorizedKey: authorized, createdAt: Date(),
    expiresAt: nil, coreAI: try MacCoreAI(accelerators: [.gpu]))
  let effective = MacEffectiveConfig.from(c, record: record, vsockPorts: [7801], topology: "t")
  #expect(effective.accelerators == [])
  #expect(effective.hostSecurityReduced == nil)
  let reduced = MacEffectiveConfig.from(
    c, record: record, vsockPorts: [7801], topology: "t",
    hostSecurity: .init(reduced: true, detail: "x"))
  #expect(reduced.hostSecurityReduced == true)
}

@Test func hostSecurityIsReducedOnlyWithAnAMFIBootArg() {
  let secured = MacHostSecurity.evaluate(
    bootArgs: "", csrStatus: "System Integrity Protection status: enabled.\n")
  #expect(!secured.reduced)
  #expect(secured.detail.contains("fully secured"))
  let sipOnly = MacHostSecurity.evaluate(
    bootArgs: "-v", csrStatus: "System Integrity Protection status: disabled.\n")
  #expect(!sipOnly.reduced)
  #expect(sipOnly.detail.contains("AMFI is enforcing"))
  let relaxed = MacHostSecurity.evaluate(
    bootArgs: "-v amfi_get_out_of_my_way=1",
    csrStatus: "System Integrity Protection status: disabled.\n")
  #expect(relaxed.reduced)
  #expect(relaxed.detail == "boot-args amfi_get_out_of_my_way=1, SIP disabled")
  #expect(!MacHostSecurity.evaluate(bootArgs: "xamfi_get_out_of_my_way=1", csrStatus: "").reduced)
}

@Test func thePreflightRefusesBeforeAnyVMIsBuilt() {
  let refused = #expect(throws: SandboxError.self) {
    try MacHostSecurity.preflight(
      hostVersion: OperatingSystemVersion(majorVersion: 27, minorVersion: 3, patchVersion: 0),
      report: { .init(reduced: true, detail: "") })
  }
  #expect(refused?.description.contains("iso-sandbox-coreai") == true)
}

@Test func theCoreAIFloorIsMacOS27Point3() throws {
  #expect(
    !MacAccelerators.atLeastMinimum(.init(majorVersion: 27, minorVersion: 2, patchVersion: 9)))
  #expect(MacAccelerators.atLeastMinimum(.init(majorVersion: 27, minorVersion: 3, patchVersion: 0)))
  #expect(MacAccelerators.atLeastMinimum(.init(majorVersion: 28, minorVersion: 0, patchVersion: 0)))
  #expect(throws: SandboxError.self) {
    try MacTemplates.requireCoreAIGuest(.init(majorVersion: 27, minorVersion: 2, patchVersion: 0))
  }
  try MacTemplates.requireCoreAIGuest(try GuestText.operatingSystemVersion("27.3"))
  let v = try GuestText.operatingSystemVersion("27.3.1")
  #expect((v.majorVersion, v.minorVersion, v.patchVersion) == (27, 3, 1))
  for bad in ["27", "27.x", "27..1", "27.3.1.2", "-1.3"] {
    #expect(throws: SandboxError.self, "\(bad)") { try GuestText.operatingSystemVersion(bad) }
  }
}

@Test func onlyACoreAITemplateNameEndsInTheSuffix() throws {
  try MacTemplates.requireName(try SandboxID("iso-a-b-coreai"), coreAI: true)
  try MacTemplates.requireName(try SandboxID("iso-a-b"), coreAI: false)
  #expect(throws: SandboxError.self) {
    try MacTemplates.requireName(try SandboxID("iso-a-b"), coreAI: true)
  }
  #expect(throws: SandboxError.self) {
    try MacTemplates.requireName(try SandboxID("iso-a-b-coreai"), coreAI: false)
  }
}

@Test func theFeatureFlagIsWrittenOnlyForACoreAITemplateAndBeforeTheShutdown() throws {
  let plain = MacTemplates.guestSetupScript(provision: true)
  #expect(!plain.contains("ParavirtualizedCoreAI"))
  let script = MacTemplates.guestSetupScript(provision: true, coreAI: true)
  let flag = try #require(
    script.range(
      of:
        "defaults write /Library/Preferences/FeatureFlags/Domain/ParavirtualizedCoreAI \\\n  enable_pv_delegate -dict Enabled -bool true\n"
    ))
  let mkdir = try #require(
    script.range(of: "\nmkdir -p /Library/Preferences/FeatureFlags/Domain\n"))
  let provision = try #require(script.range(of: "/bin/bash /Users/iso/iso-provision.sh"))
  let shutdown = try #require(script.range(of: "/sbin/shutdown -h now"))
  #expect(mkdir.lowerBound < flag.lowerBound)
  #expect(flag.lowerBound < provision.lowerBound && provision.lowerBound < shutdown.lowerBound)
}

@Test func coreAIStatusRepliesAreBounded() {
  func reply(_ kinds: [String]) -> Result<HelperMessage, HelperError> {
    var m = HelperMessage(type: .coreAIStatusReply)
    m.availableKinds = kinds
    m.delegateEnabled = true
    return HelperMessage.parse(Array(m.encodedLine().dropLast()))
  }
  guard case .success(let ok) = reply(["cpu", "gpu", "neuralEngine"]) else {
    Issue.record("a well-formed reply must parse")
    return
  }
  #expect(ok.availableKinds == ["cpu", "gpu", "neuralEngine"] && ok.delegateEnabled == true)
  for bad in [
    ["gpu", "gpu"], ["neural_engine"], ["\u{1b}[31m"], [""], [String(repeating: "a", count: 33)],
    (0..<9).map { "k" + String(repeating: "a", count: $0 + 1) },
  ] {
    #expect(reply(bad) == .failure(.malformed), "\(bad)")
  }
  let request = HelperMessage(type: .coreAIStatus).encodedLine()
  #expect(String(decoding: request, as: UTF8.self).contains(#""type":"coreai_status""#))
}
