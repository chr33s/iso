import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private let macSandbox = try! MachineName("iso-0a1b2c3d-00112233445566ff")
private let macTemplate = try! MachineName("iso-0a1b2c3d-aabbccddeeff0011")
private let macOwner = try! OwnerID("0a1b2c3d00112233445566778899aabb")
private let macRoot = "/Users/me/.iso/backends/apple-container-v1/runtime"
private let hostKey =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINiqkOnkRV06x+SuorkF+O3KdBTVFznIV0+b58cidW1N"

private func expected(_ egress: EgressMode = .open) -> IsolationGate.Expected {
  .init(
    sandbox: macSandbox, owner: macOwner, runtimeRoot: macRoot,
    resources: Resources(cpus: 4, memoryBytes: 8192 << 20), egress: egress)
}

private func runningMac() -> [String: Any] {
  [
    "record": [
      "id": macSandbox.rawValue, "owner": macOwner.rawValue, "template": macTemplate.rawValue,
      "templateBuild": "26A434", "cpus": 4, "memoryBytes": 8192 << 20,
      "macAddress": "1e:00:00:00:00:01", "subnetIndex": 7, "network": "shared",
      "enrollment": "enrolled", "authorizedKey": hostKey, "createdAt": "2026-10-06T00:00:00Z",
    ] as [String: Any],
    "status": "running",
    "live": [
      "pid": 4343, "startedAt": "2026-10-06T00:00:00Z", "bootId": "boot-1", "ipv4": "10.231.7.2",
    ] as [String: Any],
    "effective": [
      "id": macSandbox.rawValue, "template": macTemplate.rawValue, "cpus": 4,
      "memoryBytes": 8192 << 20, "displays": ["1920x1200@80ppi"],
      "pointingDevices": ["VZMacTrackpadConfiguration"],
      "keyboards": ["VZMacKeyboardConfiguration"],
      "storage": ["\(macRoot)/macos/sandboxes/\(macSandbox)/disk.img"],
      "network": "vmnet-shared:10.231.7.0/24", "macAddress": "1e:00:00:00:00:01",
      "vsockPorts": [7801], "directoryShares": 0, "audioDevices": 0, "serialPorts": 0,
      "usbControllers": 0, "clipboard": false, "ownerTopology": "user/501 Background",
    ] as [String: Any],
    "runtime": [
      "vmState": "running", "vmInstance": "vm", "bootId": "boot-1", "enrollment": "enrolled",
      "helperConnected": true, "helperGeneration": 1, "sshHostKey": hostKey,
      "sshHostKeyConfirmed": true, "ipv4": "10.231.7.2", "topology": "user/501 Background",
    ] as [String: Any],
    "sshHostKey": hostKey,
  ]
}

private func inspection(_ object: [String: Any]) throws -> MacInspection {
  try RuntimeProtocol.parseMacInspect(
    Array(try JSONSerialization.data(withJSONObject: object)), expected: macSandbox)
}

private func gate(_ object: [String: Any], _ egress: EgressMode = .open) throws
  -> IsolationGate
  .Ready
{
  try IsolationGate.verifyMacEffective(
    inspection(object), expected(egress), template: macTemplate, helper: .confirmedThisBoot)
}

private func with(_ section: String, _ key: String, _ value: Any) -> [String: Any] {
  var object = runningMac()
  var inner = object[section] as! [String: Any]
  inner[key] = value
  object[section] = inner
  return object
}

@Test func aConformingMacGuestPassesTheGate() throws {
  let ready = try gate(runningMac())
  #expect(ready.ownerPID == 4343)
  #expect(ready.ipv4 == (try IPv4Address("10.231.7.2")))
}

@Test func hostExposureFailsTheMacGate() throws {
  let exposures: [(String, Any)] = [
    ("directoryShares", 1), ("audioDevices", 1), ("serialPorts", 1), ("usbControllers", 1),
    ("clipboard", true), ("displays", ["a", "b"]), ("vsockPorts", [7801, 22]),
    ("storage", ["/Users/me/other.img"]),
  ]
  for (key, value) in exposures {
    #expect {
      try gate(with("effective", key, value))
    } throws: { error in
      if case .hostExposure = error as? RuntimeError { return true }
      return false
    }
  }
}

@Test func networkAndAddressMustMatchTheDedicatedSubnet() throws {
  for object in [
    with("effective", "network", "vmnet-shared:10.231.8.0/24"),
    with("effective", "macAddress", "1e:00:00:00:00:99"),
    with("live", "ipv4", "10.231.7.3"),
    with("runtime", "ipv4", "10.231.7.9"),
  ] {
    #expect(throws: RuntimeError.self) { try gate(object) }
  }
  // Egress none requires the host-only network, and the record must agree.
  #expect(throws: RuntimeError.self) { try gate(runningMac(), .none) }
  var hostOnly = with("record", "network", "host_only")
  var effective = hostOnly["effective"] as! [String: Any]
  effective["network"] = "vmnet-host:10.231.7.0/24"
  hostOnly["effective"] = effective
  _ = try gate(hostOnly, .none)
}

@Test func anUnconfirmedOrMismatchedEnrollmentIsNotReady() throws {
  for object in [
    with("runtime", "helperConnected", false), with("runtime", "sshHostKeyConfirmed", false),
    with("runtime", "enrollment", "pending"), with("runtime", "bootId", "boot-2"),
  ] {
    #expect(throws: RuntimeError.self) { try gate(object) }
  }
  #expect(
    IsolationGate.macPending(try inspection(with("runtime", "helperConnected", false))) != nil)
  #expect(IsolationGate.macPending(try inspection(runningMac())) == nil)
  #expect {
    try gate(with("record", "enrollment", "identity_mismatch"))
  } throws: { error in
    if case .hostKeyChanged = error as? RuntimeError { return true }
    return false
  }
}

@Test func identityAndResourcesMustMatchTheRecord() throws {
  for object in [
    with("record", "owner", "someone-else"), with("record", "template", "iso-0a1b2c3d-ffff"),
    with("effective", "cpus", 8), with("record", "cpus", 2),
  ] {
    #expect(throws: RuntimeError.self) { try gate(object) }
  }
}

@Test func macInspectRefusesAnotherSandboxAndUnknownEffectiveFields() throws {
  #expect(throws: RuntimeError.self) { try inspection(with("record", "id", "iso-other")) }
  #expect(throws: RuntimeError.self) { try inspection(with("effective", "id", "iso-other")) }
  #expect(throws: RuntimeError.self) { try inspection(with("effective", "sharedFolder", "/")) }
}

@Test func linuxSidecarsKeepTheirShapeAndMacOnesRecordTheirKind() throws {
  let sidecar = MachineSidecar(
    schemaVersion: StateSchema.version, backend: StateSchema.backend, ownerID: macOwner,
    machineID: macSandbox, imageRef: "r", imageDigest: "d", imageManifestID: "m",
    guestUser: .default, requestedCPUs: 2, requestedMemoryBytes: 1 << 30, hostKeyFingerprint: "",
    lastObservedOwnerPID: nil, lastObservedIP: nil, reenrollHostKey: false, createdAt: "t",
    runtimeIdentity: "i")
  let linux = String(decoding: try JSONEncoder().encode(sidecar), as: UTF8.self)
  #expect(!linux.contains("guest_os"))
  #expect(try JSONDecoder().decode(MachineSidecar.self, from: Data(linux.utf8)).kind == .linux)
  var mac = sidecar
  mac.guestOS = .macos
  let encoded = try JSONEncoder().encode(mac)
  #expect(String(decoding: encoded, as: UTF8.self).contains(#""guest_os":"macos""#))
  #expect(try JSONDecoder().decode(MachineSidecar.self, from: encoded).kind == .macos)
}

private func refusal(_ object: [String: Any], _ egress: EgressMode = .open) -> RuntimeError? {
  do {
    _ = try gate(object, egress)
    return nil
  } catch let error as RuntimeError {
    return error
  } catch {
    return .failed("\(error)")
  }
}

@Test func theMacGateRefusesAnExpiredOrUnreadableSession() {
  guard case .sessionExpired = refusal(with("record", "expiresAt", "2000-01-01T00:00:00Z")) else {
    Issue.record("an expired session must not be handed out")
    return
  }
  guard case .unqualified = refusal(with("record", "expiresAt", "tomorrow")) else {
    Issue.record("an unreadable deadline is not 'no limit'")
    return
  }
  #expect(refusal(with("record", "expiresAt", "2999-01-01T00:00:00Z")) == nil)
}

@Test func theMacGateNamesWhatItRefuses() {
  guard case .networkIsolation = refusal(with("effective", "network", "vmnet-shared:10.231.8.0/24"))
  else {
    Issue.record("another subnet is a network-isolation refusal")
    return
  }
  guard case .networkIsolation = refusal(runningMac(), .none) else {
    Issue.record("a shared network for egress none is a network-isolation refusal")
    return
  }
  guard case .unqualified = refusal(with("record", "network", "bridged")) else {
    Issue.record("an unknown network mode is unqualified")
    return
  }
  guard case .unqualified = refusal(with("record", "enrollment", "maybe")) else {
    Issue.record("an unknown enrollment is unqualified")
    return
  }
  guard case .identityConflict = refusal(with("effective", "template", "iso-0a1b2c3d-ffff")) else {
    Issue.record("booting another template is an identity conflict")
    return
  }
  guard case .networkIsolation = refusal(with("record", "subnetIndex", 251)) else {
    Issue.record("a subnet outside the allocator's range is refused")
    return
  }
  // A clone of another template, consistently reported, is still refused.
  var other = with("record", "template", "iso-0a1b2c3d-ffff")
  var effective = other["effective"] as! [String: Any]
  effective["template"] = "iso-0a1b2c3d-ffff"
  other["effective"] = effective
  guard case .identityConflict = refusal(other) else {
    Issue.record("a sandbox cloned from another template is an identity conflict")
    return
  }
  var stopped = runningMac()
  stopped["status"] = "stopped"
  guard case .operationUncertain = refusal(stopped) else {
    Issue.record("a stopped sandbox is not handed out")
    return
  }
}

@Test func macConstantsMatchTheRuntimeSources() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..")
    .standardized
  let layout = try String(
    contentsOf: root.appending(path: "iso-sandbox/Sources/IsoSandboxCore/Layout.swift"),
    encoding: .utf8)
  let helper = try String(
    contentsOf: root.appending(path: "iso-sandbox/Sources/IsoMacProtocol/HelperProtocol.swift"),
    encoding: .utf8)
  let templates = try String(
    contentsOf: root.appending(path: "iso-sandbox/Sources/IsoSandboxCore/MacOS/MacTemplates.swift"),
    encoding: .utf8)
  #expect(layout.contains("package let macGuestsFeature = \"\(RuntimeProtocol.macFeature)\"\n"))
  #expect(helper.contains("package static let port: UInt32 = \(IsolationGate.macVsockPorts[0])\n"))
  #expect(templates.contains("static let guestUser = \"\(MacProvision.guestUser)\""))
}

/// A loopback listener for one connection: echoes what it reads, or holds
/// the connection open without answering.
private func listener(echo: Bool) throws -> UInt16 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  var address = sockaddr_in()
  address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bound == 0, listen(fd, 1) == 0 else { throw HostError("listener") }
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
  }
  Thread.detachNewThread {
    let peer = accept(fd, nil, nil)
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = read(peer, &buffer, buffer.count)
    if echo, n > 0 { _ = write(peer, buffer, n) }
    if echo { close(peer) } else { Thread.sleep(forTimeInterval: 8) }
    close(fd)
  }
  return UInt16(bigEndian: address.sin_port)
}

@Test func theGuestReadinessProbeRunsAsRenderedOnAMacOSGuest() throws {
  // This host is macOS, like a macOS guest: no timeout(1), no /usr/bin/cat.
  let command = FilteredReadiness.guestProbeCommand.rendered
  #expect(!command.contains("/usr/bin/timeout") && !command.contains("/usr/bin/cat"))
  func run(_ port: UInt16) throws -> ProcessRunner.Output {
    try ProcessRunner().capture(
      .init(
        executable: "/bin/zsh", arguments: ["-c", command], environment: [:],
        deadline: .seconds(10), input: Array("\(port)\nPING\n".utf8)))
  }
  let echoed = try run(try listener(echo: true))
  #expect(echoed.termination == .exited(0))
  #expect(echoed.stdout == Array("PING\n".utf8))
  // A companion that accepts but never answers is cut off by the alarm.
  let start = ContinuousClock.now
  let silent = try run(try listener(echo: false))
  #expect(silent.termination != .exited(0) && silent.termination != .exited(127))
  #expect(ContinuousClock.now - start < .seconds(5))
}

@Test func resourceUsageRunsHereAsOnAMacOSGuest() throws {
  let output = try ProcessRunner().capture(
    .init(
      executable: "/bin/zsh", arguments: ["-c", ResourceUsage.command], environment: [:],
      deadline: .seconds(20)))
  let usage = ResourceUsage.parse(String(decoding: output.stdout, as: UTF8.self))
  #expect(usage.memTotalMiB > 0 && usage.memUsedMiB <= usage.memTotalMiB)
  #expect(usage.diskTotalMiB > 0 && usage.load1m > 0)
}

@Test func resourceUsageWithoutProcReportsMemoryAsUnavailable() {
  let usage = ResourceUsage.parse(
    "Filesystem 1M-blocks Used Available Capacity Mounted\n/dev/disk3s1 60000 13000 47000 22% /\n")
  #expect(usage.display.contains("Mem: unavailable"))
  #expect(usage.display.contains("Disk: 13000/60000 MiB"))
}

@Test func aHandoffToleratesASlowHelperButNotADifferentBoot() throws {
  func handoff(_ object: [String: Any]) throws -> IsolationGate.Ready {
    try IsolationGate.verifyMacEffective(
      inspection(object), expected(), template: macTemplate, helper: .pinned)
  }
  // Reconnecting or slow: no confirmation this time, or no status at all.
  _ = try handoff(with("runtime", "helperConnected", false))
  _ = try handoff(with("runtime", "sshHostKeyConfirmed", false))
  var noStatus = runningMac()
  noStatus["runtime"] = nil
  _ = try handoff(noStatus)
  // What the helper does report must still agree; enrollment is required.
  #expect(throws: RuntimeError.self) { try handoff(with("runtime", "bootId", "boot-2")) }
  do {
    _ = try handoff(with("runtime", "enrollment", "identity_mismatch"))
    Issue.record("handed off a guest that reported a different host key")
  } catch RuntimeError.hostKeyChanged {
  } catch {
    Issue.record("unexpected error: \(error)")
  }
  var unenrolled = with("record", "enrollment", "pending")
  unenrolled["sshHostKey"] = nil
  #expect(throws: RuntimeError.self) { try handoff(unenrolled) }
  #expect(throws: RuntimeError.self) {
    try handoff(with("record", "enrollment", "identity_mismatch"))
  }
  // A boot still needs the helper's confirmation.
  #expect(throws: RuntimeError.self) { try gate(with("runtime", "sshHostKeyConfirmed", false)) }
}

@Test func resourceUsageReadsAMacOSGuestsSysctlAndDataVolume() {
  let output = """
     2.09 2.06 2.10
    MemTotal: 8388608 kB
    MemAvailable: 2097152 kB
    Filesystem   1M-blocks    Used Available Capacity iused      ifree %iused  Mounted on
    /dev/disk3s5     60000   13000     47000    22% 8225392 4414236960    0%   /System/Volumes/Data
    """
  let usage = ResourceUsage.parse(output)
  #expect(usage.load1m == 2.09)
  #expect(usage.memTotalMiB == 8192 && usage.memUsedMiB == 6144)
  #expect(usage.diskTotalMiB == 60000 && usage.diskUsedMiB == 13000)
  #expect(ResourceUsage.command.hasPrefix("if [ -r /proc/loadavg ]; then cat /proc/loadavg;"))
}
