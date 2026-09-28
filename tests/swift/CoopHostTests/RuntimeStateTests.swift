import CoopConfiguration
import CoopCore
import Foundation
import Testing

@testable import CoopHost

private let sandboxFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../fixtures/coop-sandbox").standardized

private func fixture(_ name: String) throws -> [UInt8] {
  Array(try Data(contentsOf: sandboxFixtures.appending(path: name)))
}

private let sandbox = try! MachineName("coop-0a1b2c3d-00112233445566ff")
private let ownerID = try! OwnerID("0a1b2c3d00112233445566778899aabb")

// MARK: - Runtime protocol (shared fixtures with the Rust host)

@Test func versionParses() throws {
  let version = try RuntimeProtocol.parseVersion(try fixture("version.json"))
  #expect(version.name == "coop-sandbox")
  #expect(version.protocol == 2)
  #expect(version.containerization == "0.45.0")
  #expect(throws: RuntimeError.self) {
    try RuntimeProtocol.parseVersion(Array(#"{"name":"x"}"#.utf8))
  }
}

@Test func runningInspectParsesLiveAndEffective() throws {
  let inspection = try RuntimeProtocol.parseInspect(
    try fixture("inspect-running.json"), expected: sandbox)
  #expect(inspection.status == .running)
  #expect(inspection.ipv4 == (try IPv4Address("10.231.2.2")))
  #expect(inspection.effective?.mounts.count == 7)
  #expect(inspection.effective?.interfaces.count == 1)
  #expect(inspection.record.diskGeneration == 0)
}

@Test func stoppedInspectHasNoLiveState() throws {
  let inspection = try RuntimeProtocol.parseInspect(
    try fixture("inspect-stopped.json"), expected: sandbox)
  #expect(inspection.status == .stopped)
  #expect(inspection.live == nil && inspection.effective == nil)
}

@Test func inspectRejectsOtherIdsAndUnknownEffectiveFields() throws {
  let running = try fixture("inspect-running.json")
  let other = try MachineName("coop-0a1b2c3d-ffffffffffffffff")
  #expect(throws: RuntimeError.self) { try RuntimeProtocol.parseInspect(running, expected: other) }
  do {
    _ = try RuntimeProtocol.parseInspect(running, expected: other)
  } catch {
    guard case .identityConflict = error else {
      Issue.record("expected identity conflict")
      return
    }
  }
  let text = String(decoding: running, as: UTF8.self)
  let widened = text.replacingOccurrences(
    of: "\"socketRelays\" : 0,", with: "\"socketRelays\" : 0,\n    \"hostShares\" : [\"/Users\"],")
  #expect(widened != text)
  do {
    _ = try RuntimeProtocol.parseInspect(Array(widened.utf8), expected: sandbox)
    Issue.record("widened effective config accepted")
  } catch {
    guard case .unqualified(let message) = error else {
      Issue.record("expected unqualified")
      return
    }
    #expect(message.contains("hostShares"))
  }
  #expect(throws: RuntimeError.self) {
    try RuntimeProtocol.parseInspect(Array("{}".utf8), expected: sandbox)
  }
  let badIP = text.replacingOccurrences(of: "10.231.2.2\"", with: "010.231.2.2\"")
  #expect(badIP != text)
  #expect(throws: RuntimeError.self) {
    try RuntimeProtocol.parseInspect(Array(badIP.utf8), expected: sandbox)
  }
}

@Test func listRejectsDuplicatesAndUnknownStatus() throws {
  #expect(
    try RuntimeProtocol.parseList(Array(#"[{"id":"a","status":"running","owner":"o"}]"#.utf8)).count
      == 1)
  #expect(throws: RuntimeError.self) {
    try RuntimeProtocol.parseList(
      Array(#"[{"id":"a","status":"running"},{"id":"a","status":"stopped"}]"#.utf8))
  }
  #expect(throws: RuntimeError.self) {
    try RuntimeProtocol.parseList(Array(#"[{"id":"a","status":"paused"}]"#.utf8))
  }
}

@Test func imageDigestsAreStrict() throws {
  let good = #"[{"reference":"r","digest":"sha256:\#(String(repeating: "a", count: 64))"}]"#
  #expect(try RuntimeProtocol.parseImages(Array(good.utf8)).count == 1)
  for bad in [
    #"[{"reference":"r","digest":"sha256:abc"}]"#, #"[{"reference":"r","digest":"md5:00"}]"#,
  ] {
    #expect(throws: RuntimeError.self) { try RuntimeProtocol.parseImages(Array(bad.utf8)) }
  }
}

@Test func maintenanceArtifactParsesOrIsAbsent() throws {
  #expect(try RuntimeProtocol.parseMaintenance(Array("null".utf8)) == nil)
  let installed = try RuntimeProtocol.parseMaintenance(
    Array(
      #"{"version":"1","reference":"local/m:1","digest":"sha256:ab","capacityBytes":1,"installedAt":"2026-09-26T00:00:00Z","disk":"tools-ab-1.ext4"}"#
        .utf8))
  #expect(installed?.version == "1")
  #expect(throws: RuntimeError.self) { try RuntimeProtocol.parseMaintenance(Array("{}".utf8)) }
}

// MARK: - Names

@Test func runtimeNamesFollowTheRustRules() throws {
  #expect(throws: Never.self) { try MachineName("coop-0a1b2c3d-00112233445566ff") }
  for bad in [
    "", "-lead", "trail-", "Upper", "has_underscore", "semi;colon", "a b", "../x",
    String(repeating: "a", count: 49),
  ] {
    #expect(throws: ValidationError.self) { try MachineName(bad) }
  }
  #expect(throws: Never.self) { try MachineName(String(repeating: "a", count: 48)) }
  let generated = try MachineName.generate(for: ownerID, randomHex: "00112233445566ff")
  #expect(generated.belongs(to: ownerID))
  #expect(!(try MachineName("coop-0a1b2c3dx-1")).belongs(to: ownerID))
  #expect(!(try MachineName("users-machine")).belongs(to: ownerID))
  #expect(throws: ValidationError.self) { try OwnerID("short") }
  #expect(throws: ValidationError.self) { try OwnerID("0A1B2C3D00112233445566778899AABB") }
  #expect(throws: ValidationError.self) { try OperationID("") }
  #expect(throws: ValidationError.self) { try OperationID("Coop-1") }
  for bad in ["", "root", "1abc", "Ab", "a b", String(repeating: "a", count: 33)] {
    #expect(throws: ValidationError.self) { try GuestUser(bad) }
  }
  #expect(try GuestUser("_dev-1").home == "/home/_dev-1")
}

@Test func ipv4ParsingIsStrict() throws {
  #expect(try IPv4Address("172.16.0.2").description == "172.16.0.2")
  for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "01.2.3.4", "1.2.3.4 ", "a.b.c.d", "1..2.3"] {
    #expect(throws: ValidationError.self) { try IPv4Address(bad) }
  }
}

@Test func displaySanitizationNeutralizesTerminalControl() {
  #expect(sanitizeForDisplay("  ok\tline\nnext  ") == "ok\tline\nnext")
  #expect(sanitizeForDisplay("a\u{1B}[31mred") == "a?[31mred")
  #expect(sanitizeForDisplay("safe\u{202E}txt.exe") == "safe?txt.exe")
  #expect(sanitizeForDisplay("zero\u{200B}width\u{FEFF}") == "zero?width?")
}

// MARK: - State records

private func stateConfig(_ root: String) throws -> CoopConfig {
  let value = try ConfigLoader.parse(
    Array("{\"data_dir\": \"\(root)\"}".utf8), format: .json, path: "c", limits: .configuration)
  return try ConfigLoader.decode(value, path: "c", environment: .empty)
}

private func temporaryRoot() throws -> String {
  let path = FileManager.default.temporaryDirectory.appending(
    path: "coop-state-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

private func write(_ text: String, _ path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private let sidecarJSON = """
  {
    "schema_version": 2, "backend": "apple-container",
    "owner_id": "0a1b2c3d00112233445566778899aabb",
    "machine_id": "coop-0a1b2c3d-00112233445566ff",
    "image_ref": "coop-image/default:1", "image_digest": "sha256:\(String(repeating: "b", count: 64))",
    "image_manifest_id": "m1", "guest_user": "ubuntu", "requested_cpus": 2,
    "requested_memory_bytes": 4294967296, "host_key_fingerprint": "SHA256:abc",
    "last_observed_owner_pid": null, "last_observed_ip": "10.231.2.2", "reenroll_host_key": false,
    "created_at": "2026-09-27T00:00:00Z", "runtime_identity": "coop-sandbox 1"
  }
  """

@Test func stateRecordsWrittenByRustAreReadable() throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let config = try stateConfig(root)
  let state = config.stateRoot.path
  try write(
    #"{"schema_version":1,"backend":"apple-container","owner_id":"0a1b2c3d00112233445566778899aabb"}"#,
    state + "/owner.json")
  let owner = try Owner.load(config)
  #expect(owner.id == ownerID)
  let instanceDirectory = state + "/instances/proj"
  try write(#"{"name":"proj","index":3}"#, instanceDirectory + "/instance.json")
  try write(sidecarJSON, instanceDirectory + "/apple-machine.json")
  try write(
    #"{"schema_version":2,"backend":"apple-container","owner_id":"0a1b2c3d00112233445566778899aabb","machine_id":"coop-0a1b2c3d-00112233445566ff","op":{"kind":"set-resources","operation":"coop-00ff","prior":{"cpus":2,"memory_bytes":1024}}}"#,
    instanceDirectory + "/operation.json")
  let instance = try InstanceStore.resolve(config, name: nil)
  #expect(instance.name.rawValue == "proj")
  #expect(instance.image == .default)
  let sidecar = try #require(try MachineSidecar.loadIfPresent(instance))
  #expect(sidecar.resources.description == "2 vCPUs / 4096 MiB")
  try sidecar.checkOwner(owner)
  let journal = try #require(try Journal.loadIfPresent(instance))
  #expect(
    journal.op
      == .setResources(
        operation: try OperationID("coop-00ff"), prior: Resources(cpus: 2, memoryBytes: 1024)))
  #expect(journal.op.recoveryHint(instance.name) == "run `coop start proj` to finish it")
}

@Test func journalRoundTripsInTheRustTaggedForm() throws {
  let ops: [JournalOp] = [
    .create(stage: .creatingMachine), .destroy(stage: .machineDeleted),
    .restoreDisk(operation: try OperationID("coop-1"), priorGeneration: 4),
    .setResources(operation: try OperationID("coop-2"), prior: Resources(cpus: 4, memoryBytes: 8)),
  ]
  for op in ops {
    let bytes = try StateStore.encode(op, path: "op")
    #expect(try JSONDecoder().decode(JournalOp.self, from: Data(bytes)) == op)
  }
  let text = String(
    decoding: try StateStore.encode(JournalOp.create(stage: .creatingMachine), path: "op"),
    as: UTF8.self)
  #expect(text.contains(#""kind" : "create""#))
  #expect(text.contains(#""stage" : "creating-machine""#))
  #expect(CreateStage.reserved < .creatingMachine && CreateStage.creatingMachine < .machineCreated)
}

@Test func foreignAndRetiredSchemasAreRefused() throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let config = try stateConfig(root)
  let ownerPath = config.stateRoot.path + "/owner.json"
  try write(
    #"{"schema_version":1,"backend":"lima","owner_id":"0a1b2c3d00112233445566778899aabb"}"#,
    ownerPath)
  #expect(throws: RuntimeError.self) { try Owner.load(config) }
  let directory = config.instancesDirectory.path + "/p"
  try write(#"{"name":"p","index":0}"#, directory + "/instance.json")
  let instance = try InstanceStore.resolve(config, name: try InstanceName("p"))
  try write(
    sidecarJSON.replacingOccurrences(of: "\"schema_version\": 2", with: "\"schema_version\": 1"),
    MachineSidecar.path(instance))
  do {
    _ = try MachineSidecar.loadIfPresent(instance)
    Issue.record("schema 1 accepted")
  } catch let error as RuntimeError {
    #expect(error.description.contains("retired `container machine` backend"))
  }
  try write(
    sidecarJSON.replacingOccurrences(of: "\"schema_version\": 2", with: "\"schema_version\": 3"),
    MachineSidecar.path(instance))
  #expect(throws: RuntimeError.self) { try MachineSidecar.loadIfPresent(instance) }
  // A record owned by another installation is refused.
  try write(sidecarJSON, MachineSidecar.path(instance))
  let sidecar = try #require(try MachineSidecar.loadIfPresent(instance))
  let otherOwner = Owner(
    schemaVersion: 1, backend: "apple-container",
    ownerID: try OwnerID("ffffffff00112233445566778899aabb"))
  #expect(throws: RuntimeError.self) { try sidecar.checkOwner(otherOwner) }
}

@Test func controlFilesDoNotFollowSymlinks() throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write("{}", root + "/elsewhere.json")
  symlink(root + "/elsewhere.json", root + "/owner.json")
  #expect(throws: HostError.self) { try StateStore.readControlFile(root + "/owner.json") }
  #expect(try StateStore.readControlFile(root + "/missing.json") == nil)
}

@Test func controlFileWritesAreOwnerOnly() throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try StateStore.ensurePrivateDirectory(root + "/state")
  try StateStore.writeControlFile(Resources(cpus: 1, memoryBytes: 2), to: root + "/state/r.json")
  var status = stat()
  lstat(root + "/state/r.json", &status)
  #expect(status.st_mode & 0o777 == 0o600)
  lstat(root + "/state", &status)
  #expect(status.st_mode & 0o777 == 0o700)
}

@Test func instanceListingSkipsCorruptEntriesAndResolvesByName() throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let config = try stateConfig(root)
  let instances = config.instancesDirectory.path
  try write(#"{"name":"b","index":2,"image":"custom"}"#, instances + "/b/instance.json")
  try write(#"{"name":"a","index":5}"#, instances + "/a/instance.json")
  try write("not json", instances + "/broken/instance.json")
  try FileManager.default.createDirectory(
    atPath: instances + "/empty", withIntermediateDirectories: true)
  try write("", instances + "/stray-file")
  var skipped: [String] = []
  let listed = try InstanceStore.list(config) { path, _ in
    skipped.append((path as NSString).lastPathComponent)
  }
  #expect(listed.map(\.name.rawValue) == ["b", "a"])
  #expect(listed[0].image.rawValue == "custom")
  #expect(skipped.sorted() == ["broken", "empty"])
  #expect(try InstanceStore.resolve(config, name: try InstanceName("a")).index.value == 5)
  do {
    _ = try InstanceStore.resolve(config, name: nil)
    Issue.record("ambiguous resolve succeeded")
  } catch {
    #expect("\(error)" == "Multiple instances exist. Specify one: b, a")
  }
  do {
    _ = try InstanceStore.resolve(config, name: try InstanceName("zz"))
    Issue.record("missing resolve succeeded")
  } catch {
    #expect(
      "\(error)" == "No instance named 'zz'. Available: b, a\nCreate one with: coop up . --name zz")
  }
  #expect(try InstanceStore.list(try stateConfig(root + "/none")).isEmpty)
}

@Test func recordsWrittenBySwiftKeepTheRustFieldNames() throws {
  let sidecar = try JSONDecoder().decode(MachineSidecar.self, from: Data(sidecarJSON.utf8))
  let written =
    try JSONSerialization.jsonObject(with: Data(try StateStore.encode(sidecar, path: "s")))
    as! [String: Any]
  let original = try JSONSerialization.jsonObject(with: Data(sidecarJSON.utf8)) as! [String: Any]
  #expect(Set(written.keys) == Set(original.keys))
  let journal = Journal(
    schemaVersion: 2, backend: "apple-container", ownerID: ownerID, machineID: sandbox,
    op: .restoreDisk(operation: try OperationID("coop-1"), priorGeneration: 3))
  let text = String(decoding: try StateStore.encode(journal, path: "j"), as: UTF8.self)
  for key in ["schema_version", "owner_id", "machine_id", "prior_generation"] {
    #expect(text.contains("\"\(key)\""))
  }
  let owner = Owner(schemaVersion: 1, backend: "apple-container", ownerID: ownerID)
  #expect(
    String(decoding: try StateStore.encode(owner, path: "o"), as: UTF8.self).contains(
      "\"owner_id\""))
}

@Test func defaultDataRootRefusesUpstreamState() throws {
  let home = try TemporaryDirectory(prefix: "coop-data-root-")
  defer { home.remove() }
  let root = home.path + "/.coop"
  #expect(throws: Never.self) {
    try DataRoot.check(home: home.path, usesDefaultConfiguration: true)
  }
  try FileManager.default.createDirectory(
    atPath: root + "/backends/apple-container-v1", withIntermediateDirectories: true)
  #expect(throws: Never.self) {
    try DataRoot.check(home: home.path, usesDefaultConfiguration: true)
  }
  FileManager.default.createFile(atPath: root + "/vm_key", contents: Data())
  #expect(throws: (any Error).self) {
    try DataRoot.check(home: home.path, usesDefaultConfiguration: true)
  }
  #expect(throws: Never.self) {
    try DataRoot.check(home: home.path, usesDefaultConfiguration: false)
  }
  try FileManager.default.removeItem(atPath: root)
  try FileManager.default.createSymbolicLink(atPath: root, withDestinationPath: home.path)
  #expect(throws: (any Error).self) {
    try DataRoot.check(home: home.path, usesDefaultConfiguration: true)
  }
}
