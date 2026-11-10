import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

// docs/design/linux-desktop-virtio-gpu.md: the gate's display checks, the
// image adapter, the `iso-sandbox` arguments and the guest MCP server.

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../..").standardized
private let fixture = repositoryRoot.appending(path: "tests/fixtures/iso-sandbox")

private let sandbox = try! MachineName("iso-0a1b2c3d-00112233445566ff")
private let owner = try! OwnerID("0a1b2c3d00112233445566778899aabb")
private let root = "/Users/me/.iso/backends/apple-container-v1/runtime"

private func expected(_ display: IsolationGate.ExpectedDisplay) -> IsolationGate.Expected {
  .init(
    sandbox: sandbox, owner: owner, runtimeRoot: root,
    resources: Resources(cpus: 2, memoryBytes: 2048 * 1024 * 1024), egress: .open,
    display: display)
}

/// The running fixture, as a display sandbox reports it when `display` is set.
private func inspect(display: [String: Any]?, recorded: String? = nil) throws -> [UInt8] {
  let data = try Data(contentsOf: fixture.appending(path: "inspect-running.json"))
  var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  var effective = object["effective"] as! [String: Any]
  for (key, value) in display ?? [:] { effective[key] = value }
  object["effective"] = effective
  if let recorded {
    var record = object["record"] as! [String: Any]
    record["display"] = recorded
    object["record"] = record
  }
  return Array(try JSONSerialization.data(withJSONObject: object))
}

private var virtio: [String: Any] {
  [
    "display": "virtio_display", "graphicsDevices": [["1920x1200"]], "vsockPorts": [7802],
  ]
}

private func gate(_ bytes: [UInt8], _ display: IsolationGate.ExpectedDisplay) throws(RuntimeError)
  -> IsolationGate.Ready
{
  try IsolationGate.verifyEffective(
    RuntimeProtocol.parseInspect(bytes, expected: sandbox), expected(display))
}

@Test func aDisplaySandboxPassesTheGate() throws {
  _ = try gate(
    try inspect(display: virtio, recorded: "virtio_display"), .virtio(guestComputerUse: true))
  var noListener = virtio
  noListener["vsockPorts"] = [UInt32]()
  _ = try gate(
    try inspect(display: noListener, recorded: "virtio_display"), .virtio(guestComputerUse: false))
}

@Test func aHeadlessReportIsUnchanged() throws {
  _ = try gate(try inspect(display: nil), .headless)
}

@Test func theGateRefusesADisplayItDidNotExpect() throws {
  // A display on a headless instance, in its report or its record.
  #expect(throws: RuntimeError.self) {
    try gate(try inspect(display: virtio), .headless)
  }
  #expect(throws: RuntimeError.self) {
    try gate(try inspect(display: nil, recorded: "virtio_display"), .headless)
  }
  // No display, or a record without one, on a display instance.
  #expect(throws: RuntimeError.self) {
    try gate(try inspect(display: nil, recorded: "virtio_display"), .virtio(guestComputerUse: true))
  }
  #expect(throws: RuntimeError.self) {
    try gate(try inspect(display: virtio), .virtio(guestComputerUse: true))
  }
}

@Test func theGateRefusesAnyOtherDisplayShape() throws {
  let bad: [[String: Any]] = [
    ["graphicsDevices": [["1920x1080"]]],
    ["graphicsDevices": [["1920x1200"], ["1920x1200"]]],
    ["graphicsDevices": [["1920x1200", "1920x1200"]]],
    ["graphicsDevices": [["VZMacGraphicsDevice"]]],
    ["vsockPorts": [7802, 7801]],
    ["vsockPorts": [UInt32]()],
    ["display": "headless"],
  ]
  for change in bad {
    let mutated = virtio.merging(change) { _, new in new }
    #expect(throws: RuntimeError.self) {
      try gate(
        try inspect(display: mutated, recorded: "virtio_display"), .virtio(guestComputerUse: true))
    }
  }
  // Without guest computer use, 7802 is a listener the gate did not expect.
  #expect(throws: RuntimeError.self) {
    try gate(
      try inspect(display: virtio, recorded: "virtio_display"), .virtio(guestComputerUse: false))
  }
}

@Test func aPartialDisplayReportDoesNotDecode() throws {
  for key in ["display", "graphicsDevices", "vsockPorts"] {
    var partial = virtio
    partial.removeValue(forKey: key)
    #expect(throws: RuntimeError.self) {
      try RuntimeProtocol.parseInspect(try inspect(display: partial), expected: sandbox)
    }
  }
}

@Test func aDisplayReportCarriesItsLiveViewListener() throws {
  func listening(_ value: Any?) throws -> Bool? {
    var display = virtio
    display["liveViewListening"] = value
    return try RuntimeProtocol.parseInspect(
      try inspect(display: display, recorded: "virtio_display"), expected: sandbox
    ).effective?.display?.liveViewListening
  }
  // Absent from an owner that predates the report: none.
  #expect(try listening(nil) == false)
  #expect(try listening(false) == false)
  #expect(try listening(true) == true)
  #expect(throws: RuntimeError.self) { try listening("yes") }
  // An open listener is opt-in and token-gated: the gate accepts it.
  var streaming = virtio
  streaming["liveViewListening"] = true
  _ = try gate(
    try inspect(display: streaming, recorded: "virtio_display"), .virtio(guestComputerUse: true))
  // A headless sandbox has no listener to report.
  #expect(throws: RuntimeError.self) {
    try RuntimeProtocol.parseInspect(
      try inspect(display: ["liveViewListening": false]), expected: sandbox)
  }
}

/// The running display fixture with `runtime` as its owner's counts.
private func inspect(runtime: Any?) throws -> SandboxInspection {
  let bytes = try inspect(display: virtio, recorded: "virtio_display")
  var object = try JSONSerialization.jsonObject(with: Data(bytes)) as! [String: Any]
  object["runtime"] = runtime
  return try RuntimeProtocol.parseInspect(
    Array(try JSONSerialization.data(withJSONObject: object)), expected: sandbox)
}

@Test func aDisplaySandboxReportsItsComputerUseCounts() throws {
  let guest: [String: Any] = [
    "frameRate": 4, "sessions": 1, "frames": 30, "actions": 12, "statusRequests": 1,
    "preemptions": 2, "refusals": ["held_by_host": 3],
  ]
  let liveView = ["streams": 1, "viewers": 2, "takeovers": 1, "inputEvents": 40]
  // A headless or stopped sandbox reports none.
  #expect(try inspect(runtime: nil).runtime == nil)
  let both = try inspect(runtime: ["guestComputerUse": guest, "liveView": liveView]).runtime
  #expect(both?.guestComputerUse?.frames == 30 && both?.guestComputerUse?.preemptions == 2)
  #expect(
    both?.liveView == MacLiveViewCounts(streams: 1, viewers: 2, takeovers: 1, inputEvents: 40))
  // No guest computer use, no stream yet.
  let neither = try inspect(runtime: [String: Any]()).runtime
  #expect(neither != nil && neither?.guestComputerUse == nil && neither?.liveView == nil)
  // An invalid count drops that report only; the inspection still decodes.
  var negative = liveView
  negative["viewers"] = -1
  let dropped = try inspect(runtime: ["guestComputerUse": guest, "liveView": negative]).runtime
  #expect(dropped?.guestComputerUse?.frames == 30 && dropped?.liveView == nil)
}

@Test func computerUseCountsBecomeAuditEvents() {
  let guest = MacGuestCUCounts(
    frameRate: 4, sessions: 1, frames: 3, actions: 2, statusRequests: 0, preemptions: 0,
    refusals: [:])
  let streamed = MacLiveViewCounts(streams: 1, viewers: 1, takeovers: 0, inputEvents: 0)
  let unused = MacLiveViewCounts(streams: 0, viewers: 0, takeovers: 0, inputEvents: 0)
  func events(_ created: Bool, _ guest: MacGuestCUCounts?, _ liveView: MacLiveViewCounts?)
    -> [BoundaryAudit.Event]
  {
    AppleBackend.computerUseEvents(
      createdWithGuestComputerUse: created, guest: guest, liveView: liveView)
  }
  #expect(events(true, guest, streamed) == [.guestComputerUse(guest), .liveView(streamed)])
  // Guest counts only for an instance created with guest computer use.
  #expect(events(false, guest, nil).isEmpty)
  #expect(events(true, nil, nil).isEmpty)
  // The live view needs no guest computer use, only a stream this boot.
  #expect(events(false, nil, streamed) == [.liveView(streamed)])
  #expect(events(false, nil, unused).isEmpty)
}

@Test func onlyADesktopImageInstallsTheDiscoveredDesktopKernel() throws {
  func kernel(_ configured: String?, _ discovered: String?, _ desktopImage: Bool) throws -> String?
  {
    try AppleBackend.desktopKernel(
      configured: configured, discovered: discovered, desktopImage: desktopImage)
  }
  // A release's kernel beside iso-sandbox is not this runtime's to check
  // until an image needs it.
  #expect(try kernel(nil, "/opt/iso/bin/vmlinux-desktop", false) == nil)
  #expect(try kernel(nil, "/opt/iso/bin/vmlinux-desktop", true) == "/opt/iso/bin/vmlinux-desktop")
  #expect(try kernel(nil, nil, false) == nil)
  // A desktop image with no kernel is refused at setup, not at its first boot.
  #expect(throws: HostError.self) { try kernel(nil, nil, true) }
  // A configured kernel was asked for: always checked, and it wins.
  #expect(try kernel("/k/vmlinux", "/opt/iso/bin/vmlinux-desktop", false) == "/k/vmlinux")
  #expect(try kernel("/k/vmlinux", nil, true) == "/k/vmlinux")
}

@Test func theExpectedDisplayFollowsTheSidecar() {
  #expect(IsolationGate.ExpectedDisplay(nil, guestComputerUse: true) == .headless)
  #expect(
    IsolationGate.ExpectedDisplay(.virtio, guestComputerUse: true)
      == .virtio(guestComputerUse: true))
  #expect(
    IsolationGate.ExpectedDisplay(.virtio, guestComputerUse: false)
      == .virtio(guestComputerUse: false))
}

// MARK: images and the runtime

@Test func onlyTheBuiltInDesktopProfileAddsTheDisplayAdapter() {
  let python = Profiles.builtin.first { $0.name == "python" }!
  #expect(BuildContext.guestAdapters(profiles: [python]) == BuildContext.guestAdapters)
  #expect(
    BuildContext.guestAdapters(profiles: [python, Profiles.desktopDefinition])
      == BuildContext.guestAdapters + [ImageManifest.virtioDisplayAdapter])
  let shadow = ProfileDefinition(
    name: Profiles.desktop, aptPackages: [], preInstall: nil, postInstall: nil, marketplaces: [],
    plugins: [])
  #expect(BuildContext.guestAdapters(profiles: [shadow]) == BuildContext.guestAdapters)
}

@Test func theDesktopProfileShipsNoThirdPartyDisplayCode() {
  let profile = Profiles.desktopDefinition
  #expect(Profiles.builtin.contains(profile))
  for package in profile.aptPackages {
    #expect(!["xvfb", "xdotool", "x11vnc", "ffmpeg", "x264", "python3"].contains(package))
  }
  #expect(profile.aptPackages.contains("firefox"))
  // The only download is Mozilla's key, checked against its fingerprint.
  let pre = profile.preInstall ?? ""
  #expect(pre.contains("MOZILLA_KEY_FPRS='35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3'"))
  #expect(pre.contains("Pin: origin packages.mozilla.org"))
  let post = profile.postInstall ?? ""
  #expect(!post.contains("curl") && !post.contains("wget"))
  #expect(post.hasSuffix("install -m 0755 /opt/iso-build/iso-cu-mcp /usr/local/bin/iso-cu-mcp\n"))
}

@Test func theDesktopResourcesAreTheCheckedInFiles() throws {
  let guest = repositoryRoot.appending(path: "Sources/IsoHost/Guest/Resources")
  #expect(
    DesktopResources.preInstall
      == (try String(contentsOf: guest.appending(path: "desktop-pre.sh"), encoding: .utf8)))
  #expect(
    DesktopResources.postInstall
      == (try String(contentsOf: guest.appending(path: "desktop-post.sh"), encoding: .utf8)))
}

/// The smallest header `computerUseMCPPayload` accepts: a 64-bit
/// little-endian ELF for arm64 (`e_machine` 183).
private var arm64ELF: [UInt8] {
  var elf = [UInt8](repeating: 0, count: 64)
  elf[0..<4] = [0x7F, 0x45, 0x4C, 0x46]
  elf[4] = 2
  elf[5] = 1
  elf[18] = 183
  return elf
}

@Test func onlyAnArm64LinuxExecutableIsAPayload() throws {
  let elf = arm64ELF
  let payload = try BuildContext.computerUseMCPPayload(elf)
  #expect(payload.name == "iso-cu-mcp" && payload.mode == 0o755)
  var x86 = elf
  x86[18] = 62
  var macho = elf
  macho[0..<4] = [0xCF, 0xFA, 0xED, 0xFE]
  for bad in [x86, macho, [UInt8](elf.prefix(8))] {
    #expect(throws: HostError.self) { try BuildContext.computerUseMCPPayload(bad) }
  }
}

@Test func thePayloadIsPartOfTheImageIdentity() throws {
  var elf = arm64ELF
  let base = BuildContext.render(
    publicKey: "k", profiles: [Profiles.desktopDefinition], guestUser: .default)
  var a = base
  a.payloads = [try BuildContext.computerUseMCPPayload(elf)]
  elf[63] = 1
  var b = base
  b.payloads = [try BuildContext.computerUseMCPPayload(elf)]
  func id(_ c: BuildContext) -> String {
    c.manifestID(guestUser: .default, publicKeyFingerprint: "f")
  }
  #expect(id(a) != id(base))
  #expect(id(a) != id(b))
  #expect(a != b)
}

/// A Linux instance's sidecar with no display and no guest computer use.
private var headlessSidecar: MachineSidecar {
  MachineSidecar(
    schemaVersion: StateSchema.version, backend: StateSchema.backend, ownerID: owner,
    machineID: sandbox, imageRef: "r", imageDigest: "d", imageManifestID: "m",
    guestUser: .default, requestedCPUs: 2, requestedMemoryBytes: 1 << 30,
    hostKeyFingerprint: "", lastObservedOwnerPID: nil, lastObservedIP: nil,
    reenrollHostKey: false, createdAt: "t", runtimeIdentity: "i")
}

@Test func theBootstrapServerFollowsTheSidecar() throws {
  func sidecar(_ kind: GuestOS?, display: LinuxGuestDisplay?, guestCU: Bool) -> MachineSidecar {
    var s = headlessSidecar
    s.guestOS = kind
    s.display = display
    s.guestComputerUse = guestCU ? MacGuestComputerUse(frameRate: 4) : nil
    return s
  }
  #expect(
    AgentBootstrap.computerUseServer(sidecar(nil, display: .virtio, guestCU: true))?.command
      == "/usr/local/bin/iso-cu-mcp")
  #expect(AgentBootstrap.computerUseServer(sidecar(nil, display: nil, guestCU: true)) == nil)
  #expect(AgentBootstrap.computerUseServer(sidecar(nil, display: .virtio, guestCU: false)) == nil)
  let mac = try #require(
    AgentBootstrap.computerUseServer(sidecar(.macos, display: nil, guestCU: true)))
  #expect(mac.command == AgentBootstrap.computerUseCommand && mac.args == ["cu-mcp"])
}

@Test func aHeadlessSidecarIsUnchangedOnDisk() throws {
  let s = headlessSidecar
  let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
  #expect(!json.contains("display"))
}

@Test func aDisplaySidecarKeepsItsDisplayAcrossASave() throws {
  var s = headlessSidecar
  s.display = .virtio
  s.guestComputerUse = MacGuestComputerUse(frameRate: 4)
  let back = try JSONDecoder().decode(MachineSidecar.self, from: try JSONEncoder().encode(s))
  #expect(back.display == .virtio)
  #expect(back.guestComputerUse == MacGuestComputerUse(frameRate: 4))
}

private func manifest(_ adapters: [String]) -> ImageManifest {
  ImageManifest(
    schemaVersion: StateSchema.version, backend: StateSchema.backend, imageRef: "r", digest: "d",
    disk: nil, manifestID: "m", baseImage: "b", platform: "p", guestUser: .default, created: "c",
    guestAdapters: adapters)
}

private let headlessManifest = manifest(BuildContext.guestAdapters)
private let desktopManifest = manifest(
  BuildContext.guestAdapters(profiles: [Profiles.desktopDefinition]))

@Test func createPassesTheDisplayToTheRuntimeOnlyForDesktopImages() throws {
  let version =
    #"{"name":"iso-sandbox","version":"0.5.0","protocol":5,"containerization":"0.54.0","features":["linux-display"]}"#
  func createArguments(_ image: ImageManifest, guestComputerUse: MacGuestComputerUse?) throws
    -> [String]
  {
    let executor = ScriptedRuntime { args in
      ScriptedRuntime.ok(args == ["version"] ? version : "{}")
    }
    let runtime = SandboxRuntime(executor: executor, root: "/r", settings: .defaults)
    try runtime.create(
      sandbox, source: .image("r"), cpus: 2, memoryMiB: 2048, diskGiB: 8, owner: owner,
      egress: .open, display: image.hasVirtioDisplay ? .virtio : nil,
      guestComputerUse: guestComputerUse)
    return try #require(executor.calls.withLock { $0.last { $0.first == "create" } })
  }
  let headless = try createArguments(headlessManifest, guestComputerUse: nil)
  #expect(!headless.contains("--display") && !headless.contains("--guest-computer-use"))
  let desktop = try createArguments(desktopManifest, guestComputerUse: nil)
  #expect(desktop.suffix(2) == ["--display", "virtio"])
  let driven = try createArguments(
    desktopManifest, guestComputerUse: MacGuestComputerUse(frameRate: 4))
  #expect(
    driven.suffix(5) == ["--display", "virtio", "--guest-computer-use", "--guest-frame-rate", "4"])
}

@Test func aRestoredDiskMustMatchTheInstanceDisplay() throws {
  let headless = headlessManifest
  let desktop = desktopManifest
  let image = try ImageName("snap")
  let instance = try InstanceName("box")
  try headless.requireDisplay(nil, image: image, instance: instance)
  try desktop.requireDisplay(.virtio, image: image, instance: instance)
  #expect(throws: HostError.self) {
    try headless.requireDisplay(.virtio, image: image, instance: instance)
  }
  #expect(throws: HostError.self) {
    try desktop.requireDisplay(nil, image: image, instance: instance)
  }
}

@Test func anUpdateInstallsTheLinuxGuestFilesItCarries() throws {
  let base = FileManager.default.temporaryDirectory.appending(path: "iso-guest-\(UUID())")
  defer { try? FileManager.default.removeItem(at: base) }
  let extract = base.appending(path: "extract")
  let install = base.appending(path: "bin")
  try FileManager.default.createDirectory(at: extract, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: install, withIntermediateDirectories: true)
  let current = install.appending(path: "iso").path
  // A release without them leaves the install alone.
  try SelfReplace.replaceSiblingLinuxGuestFiles(extract.path, currentExecutable: current)
  #expect(!FileManager.default.fileExists(atPath: install.appending(path: "iso-cu-mcp").path))
  for name in SelfReplace.linuxGuestNames {
    try Data("new \(name)".utf8).write(to: extract.appending(path: name))
  }
  try SelfReplace.replaceSiblingLinuxGuestFiles(extract.path, currentExecutable: current)
  for name in SelfReplace.linuxGuestNames {
    #expect(
      (try String(contentsOf: install.appending(path: name), encoding: .utf8)) == "new \(name)")
  }
  #expect(SelfReplace.companionNames.contains("vmlinux-desktop"))
}
