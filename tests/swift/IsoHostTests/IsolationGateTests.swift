import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private let gateFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../fixtures/iso-sandbox").standardized

private let gateSandbox = try! MachineName("coop-0a1b2c3d-00112233445566ff")
private let gateOwner = try! OwnerID("0a1b2c3d00112233445566778899aabb")
private let gateRoot = "/Users/me/.iso/backends/apple-container-v1/runtime"

private func expected() -> IsolationGate.Expected {
  .init(
    sandbox: gateSandbox, owner: gateOwner, runtimeRoot: gateRoot,
    resources: Resources(cpus: 2, memoryBytes: 2048 * 1024 * 1024), egress: .open)
}

private func gate(_ bytes: [UInt8]) throws(RuntimeError) -> IsolationGate.Ready {
  try IsolationGate.verifyEffective(
    RuntimeProtocol.parseInspect(bytes, expected: gateSandbox), expected())
}

private func running() throws -> [String: Any] {
  let data = try Data(contentsOf: gateFixture.appending(path: "inspect-running.json"))
  return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func bytes(_ object: [String: Any]) throws -> [UInt8] {
  Array(try JSONSerialization.data(withJSONObject: object))
}

enum ErrorClass: Sendable { case hostExposure, network, identity, unqualified, uncertain }

private func classify(_ error: RuntimeError) -> ErrorClass? {
  switch error {
  case .hostExposure: .hostExposure
  case .networkIsolation: .network
  case .identityConflict: .identity
  case .unqualified: .unqualified
  case .operationUncertain: .uncertain
  default: nil
  }
}

private func setPath(_ object: inout [String: Any], _ path: [Any], _ value: Any) {
  guard let head = path.first else { return }
  if path.count == 1 {
    object[head as! String] = value
    return
  }
  let key = head as! String
  if let index = path[1] as? Int {
    var array = object[key] as! [Any]
    var element = array[index] as! [String: Any]
    if path.count == 2 {
      array[index] = value
    } else {
      setPath(&element, Array(path.dropFirst(2)), value)
      array[index] = element
    }
    object[key] = array
  } else {
    var child = object[key] as! [String: Any]
    setPath(&child, Array(path.dropFirst()), value)
    object[key] = child
  }
}

@Test func gateAcceptsTheRealRunningShape() throws {
  let ready = try gate(try bytes(try running()))
  #expect(ready.ipv4 == (try IPv4Address("10.231.2.2")))
  #expect(ready.sandbox == gateSandbox)
}

@Test func gateRejectsAStoppedSandbox() throws {
  let stopped = Array(try Data(contentsOf: gateFixture.appending(path: "inspect-stopped.json")))
  #expect(throws: RuntimeError.self) { try gate(stopped) }
  do { _ = try gate(stopped) } catch { #expect(classify(error) == .uncertain) }
}

typealias Mutation = @Sendable (inout [String: Any]) -> Void

private let cases: [(String, Mutation, ErrorClass)] = [
  ("agent", { setPath(&$0, ["effective", "sshAgentForwarding"], true) }, .hostExposure),
  ("relay", { setPath(&$0, ["effective", "socketRelays"], 1) }, .hostExposure),
  ("port", { setPath(&$0, ["effective", "publishedPorts"], 1) }, .hostExposure),
  (
    "virtiofs",
    { j in
      var effective = j["effective"] as! [String: Any]
      var mounts = effective["mounts"] as! [Any]
      mounts.append([
        "type": "virtiofs", "source": "/Users/me", "destination": "/proc", "options": [],
      ])
      effective["mounts"] = mounts
      j["effective"] = effective
    }, .hostExposure
  ),
  (
    "host path at allowed destination",
    { setPath(&$0, ["effective", "mounts", 0, "source"], "/Users/me") }, .hostExposure
  ),
  (
    "foreign rootfs", { setPath(&$0, ["effective", "rootfs", "source"], "/Users/me/disk.img") },
    .hostExposure
  ),
  ("init", { setPath(&$0, ["effective", "initArgv"], ["/bin/sh"]) }, .hostExposure),
  ("nested virt", { setPath(&$0, ["effective", "virtualization"], true) }, .hostExposure),
  (
    "second interface",
    { j in
      var effective = j["effective"] as! [String: Any]
      var interfaces = effective["interfaces"] as! [Any]
      interfaces.append(interfaces[0])
      effective["interfaces"] = interfaces
      j["effective"] = effective
    }, .network
  ),
  (
    "shared network",
    { setPath(&$0, ["effective", "interfaces", 0, "network"], "vmnet-shared:192.168.64.0/24") },
    .network
  ),
  ("rootfs kind", { setPath(&$0, ["effective", "rootfs", "type"], "none") }, .hostExposure),
  (
    "address outside subnet",
    { j in
      setPath(&j, ["live", "ipv4"], "10.231.9.2")
      setPath(&j, ["effective", "interfaces", 0, "ipv4"], "10.231.9.2/24")
    }, .network
  ),
  ("no live state", { $0["live"] = NSNull() }, .unqualified),
  ("record memory", { setPath(&$0, ["record", "memoryBytes"], 1) }, .identity),
  ("address mismatch", { setPath(&$0, ["live", "ipv4"], "10.231.2.9") }, .network),
  ("owner", { setPath(&$0, ["record", "owner"], String(repeating: "f", count: 32)) }, .identity),
  ("cpus", { setPath(&$0, ["effective", "cpus"], 8) }, .identity),
  (
    "image",
    { setPath(&$0, ["effective", "imageDigest"], "sha256:" + String(repeating: "f", count: 64)) },
    .identity
  ),
  (
    "subnet suffix spoof",
    { setPath(&$0, ["effective", "interfaces", 0, "network"], "vmnet-shared:10.231.2.0/24x") },
    .network
  ),
]

@Test(arguments: cases.map(\.0))
func gateRejectsEachExposureNetworkAndIdentityChange(_ label: String) throws {
  let (_, mutate, expectedClass) = cases.first { $0.0 == label }!
  var object = try running()
  mutate(&object)
  do {
    _ = try gate(try bytes(object))
    Issue.record("\(label) accepted")
  } catch let error as RuntimeError {
    #expect(classify(error) == expectedClass, "\(label): \(error)")
  }
}

@Test func runtimePinsMatchTheRuntimeSources() throws {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../..")
    .standardized
  let layout = try String(
    contentsOf: root.appending(path: "iso-sandbox/Sources/IsoSandboxCore/Layout.swift"),
    encoding: .utf8)
  let package = try String(
    contentsOf: root.appending(path: "iso-sandbox/Package.swift"), encoding: .utf8)
  #expect(layout.contains("public let protocolVersion = \(RuntimeProtocol.version)\n"))
  #expect(
    layout.contains("public let containerizationVersion = \"\(SandboxRuntime.containerization)\"\n")
  )
  #expect(
    package.contains(
      "\"https://github.com/apple/containerization.git\", exact: \"\(SandboxRuntime.containerization)\")"
    ))
}

// MARK: - egress

private func hostOnly(_ object: [String: Any]) -> [String: Any] {
  var copy = object
  setPath(&copy, ["record", "network"], "host_only")
  setPath(&copy, ["effective", "interfaces", 0, "network"], "vmnet-host:10.231.2.0/24")
  return copy
}

private func gate(_ bytes: [UInt8], egress: EgressMode) throws(RuntimeError) -> IsolationGate.Ready
{
  let base = expected()
  return try IsolationGate.verifyEffective(
    RuntimeProtocol.parseInspect(bytes, expected: gateSandbox),
    .init(
      sandbox: base.sandbox, owner: base.owner, runtimeRoot: base.runtimeRoot,
      resources: base.resources, egress: egress))
}

private func egressClass(_ object: [String: Any], _ egress: EgressMode) throws -> ErrorClass? {
  let data = try bytes(object)
  do {
    _ = try gate(data, egress: egress)
    return nil
  } catch {
    return classify(error)
  }
}

@Test func egressNoneRequiresAHostOnlySandbox() throws {
  let shared = try running()
  // A host-only record and interface pass only when egress is none.
  #expect(try gate(try bytes(hostOnly(shared)), egress: .none).sandbox == gateSandbox)
  #expect(try egressClass(hostOnly(shared), .open) == .network)
  // A shared (NAT) sandbox never satisfies egress none.
  #expect(try egressClass(shared, .none) == .network)
  // A host-only record whose VM reports a shared interface is refused.
  var mixed = hostOnly(shared)
  setPath(&mixed, ["effective", "interfaces", 0, "network"], "vmnet-shared:10.231.2.0/24")
  #expect(try egressClass(mixed, .none) == .network)
  // An unknown record mode is not guessed at.
  var unknown = shared
  setPath(&unknown, ["record", "network"], "bridged")
  #expect(try egressClass(unknown, .open) == .unqualified)
}

@Test func egressIsCheckedOnTheRecordBeforeBoot() throws {
  let data = try Data(contentsOf: gateFixture.appending(path: "inspect-stopped.json"))
  var stopped = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  setPath(&stopped, ["record", "network"], "host_only")
  let inspection = try RuntimeProtocol.parseInspect(try bytes(stopped), expected: gateSandbox)
  let base = expected()
  func expect(_ egress: EgressMode) -> IsolationGate.Expected {
    .init(
      sandbox: base.sandbox, owner: base.owner, runtimeRoot: base.runtimeRoot,
      resources: base.resources, egress: egress)
  }
  try IsolationGate.verifyRecord(inspection, expect(.none))
  #expect(throws: RuntimeError.self) { try IsolationGate.verifyRecord(inspection, expect(.open)) }
}

@Test func anExpiredSessionIsNotHandedOut() throws {
  var object = try running()
  setPath(&object, ["record", "expiresAt"], "2000-01-01T00:00:00Z")
  do {
    _ = try gate(try bytes(object))
    Issue.record("an expired session was handed out")
  } catch {
    #expect("\(error)".hasPrefix("APPLE_SESSION_EXPIRED"))
  }
  setPath(&object, ["record", "expiresAt"], "2999-01-01T00:00:00Z")
  #expect(try gate(try bytes(object)).sandbox == gateSandbox)
}

@Test func anUnreadableSessionDeadlineIsNotTreatedAsNoLimit() throws {
  var object = try running()
  setPath(&object, ["record", "expiresAt"], "soon")
  #expect(throws: RuntimeError.self) { try gate(try bytes(object)) }
}
