import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private func withPolicyFixture(_ body: (Instance, IsoConfig) throws -> Void) throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "iso-policy-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let config = try ConfigLoader.decode(
    ConfigLoader.parse(
      Array(
        #"{"egress":"filtered","egress_filter":{"allowed_hosts":["example.com","api.example.com"]}}"#
          .utf8),
      format: .json, path: "c", limits: .configuration), path: "c", environment: .empty)
  let instance = Instance(
    name: try InstanceName("t"), index: try #require(InstanceIndex(0)), directory: directory,
    image: .default)
  try body(instance, config)
}

@Test func networkPolicyVerifiesItsCanonicalHash() throws {
  try withPolicyFixture { instance, config in
    try NetworkPolicy.save(config, instance)
    let original = try #require(try NetworkPolicy.load(instance))
    #expect(original == NetworkPolicy.make(config))
    try NetworkPolicy.enforce(instance, config: config)
    var changed = original
    changed.policyHash = "sha256:forged"
    try StateStore.writeControlFile(changed, to: NetworkPolicy.path(instance))
    #expect(throws: HostError.self) { try NetworkPolicy.load(instance) }
    #expect(throws: HostError.self) { try NetworkPolicy.enforce(instance, config: config) }
    changed = original
    changed.allowedHosts = ["other.example.com"]
    try StateStore.writeControlFile(changed, to: NetworkPolicy.path(instance))
    #expect(throws: HostError.self) { try NetworkPolicy.load(instance) }
  }
}

@Test func networkPolicyRejectsNoncanonicalOrInvalidHostsAndModes() throws {
  try withPolicyFixture { instance, config in
    let original = NetworkPolicy.make(config)
    for hosts in [
      ["example.com", "api.example.com"], ["example.com", "example.com"],
      ["EXAMPLE.COM"], ["127.0.0.1"], ["*.example.com"],
    ] {
      var changed = original
      changed.allowedHosts = hosts
      // Even a self-consistent hash must not legitimize invalid metadata.
      let canonical = "mode=filtered\nhosts=\(hosts.joined(separator: ","))\nport=443\n"
      changed.policyHash = "sha256:" + sha256Hex(Array(canonical.utf8))
      try StateStore.writeControlFile(changed, to: NetworkPolicy.path(instance))
      #expect(throws: HostError.self) { try NetworkPolicy.load(instance) }
    }
    for mode in ["open", "none", "unknown"] {
      var changed = original
      changed.mode = mode
      let canonical =
        "mode=\(mode)\nhosts=\(changed.allowedHosts.joined(separator: ","))\nport=443\n"
      changed.policyHash = "sha256:" + sha256Hex(Array(canonical.utf8))
      try StateStore.writeControlFile(changed, to: NetworkPolicy.path(instance))
      #expect(throws: HostError.self) { try NetworkPolicy.load(instance) }
    }
  }
}

@Test func filteredBootPolicyIsAtomicBoundedAndDoesNotAdoptLegacyBootFiles() throws {
  try withPolicyFixture { instance, config in
    #expect(try FilteredHandoff.recordedPolicy(instance) == nil)
    try AtomicFile.write(
      Array("old-boot".utf8), to: instance.directory + "/egress-boot-id", mode: .atMost(0o600))
    #expect(try FilteredHandoff.recordedPolicy(instance) == nil)
    let policy = FilteredHandoff.BootPolicy(
      bootID: "boot", policyHash: NetworkPolicy.make(config).policyHash)
    let path = FilteredHandoff.policyPath(instance)
    try StateStore.writeControlFile(policy, to: path)
    #expect(try FilteredHandoff.recordedPolicy(instance) == policy)
    var status = stat()
    try #require(lstat(path, &status) == 0)
    #expect(status.st_mode & 0o777 == 0o600)
    let good = try Data(contentsOf: URL(fileURLWithPath: path))
    var json = try #require(JSONSerialization.jsonObject(with: good) as? [String: Any])
    for (key, value) in [
      ("schemaVersion", 99 as Any), ("backend", "foreign" as Any),
      ("bootID", "" as Any), ("policyHash", "" as Any),
    ] {
      var modified = json
      modified[key] = value
      try JSONSerialization.data(withJSONObject: modified).write(to: URL(fileURLWithPath: path))
      #expect(throws: HostError.self) { try FilteredHandoff.recordedPolicy(instance) }
    }
    json["bootID"] = 1
    try JSONSerialization.data(withJSONObject: json).write(to: URL(fileURLWithPath: path))
    #expect(throws: HostError.self) { try FilteredHandoff.recordedPolicy(instance) }
    try Data(repeating: 32, count: StateStore.maxControlFile + 1).write(
      to: URL(fileURLWithPath: path))
    #expect(throws: HostError.self) { try FilteredHandoff.recordedPolicy(instance) }
    try FileManager.default.removeItem(atPath: path)
    let target = instance.directory + "/target.json"
    try good.write(to: URL(fileURLWithPath: target))
    try #require(symlink(target, path) == 0)
    #expect(throws: HostError.self) { try FilteredHandoff.recordedPolicy(instance) }
  }
}

@Test(arguments: [EgressMode.open, .none, .filtered])
func networkPolicyRequiresCreationRecordInEveryMode(_ mode: EgressMode) throws {
  try withPolicyFixture { instance, _ in
    let config = try testConfig("\"egress\": \"\(mode.rawValue)\"")
    #expect(try NetworkPolicy.load(instance) == nil)
    let error = try #require(throws: HostError.self) {
      try NetworkPolicy.enforce(instance, config: config)
    }
    #expect(error.message.contains("no recorded network policy"))
    try NetworkPolicy.save(config, instance)
    try NetworkPolicy.enforce(instance, config: config)
    #expect(try NetworkPolicy.load(instance)?.mode == mode.rawValue)
  }
}
