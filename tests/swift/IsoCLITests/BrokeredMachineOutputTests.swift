import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Testing

@testable import IsoCLI

/// The additive `network` object of `status --output json`: present for a
/// brokered instance only, `effective` null unless the boot was gate-approved.
private func object(_ value: some Encodable) throws -> [String: Any] {
  let text = try JSONOutput.render(value, pretty: false)
  return try #require(
    try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func instance() throws -> Instance {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "iso-brokered-machine-\(UUID().uuidString)"
  ).path
  defer { try? FileManager.default.removeItem(atPath: root) }
  let config = try ConfigLoader.decode(
    ConfigLoader.parse(
      Array(#"{"data_dir": "\#(root)"}"#.utf8), format: .jsonc, path: "c", limits: .configuration),
    path: "c", environment: .empty)
  return try Instance.allocate(
    config, name: try InstanceName("b"), image: .default, workspacePath: nil)
}

@Test func machineStatusAddsNetworkOnlyForBrokeredInstances() throws {
  let one = try instance()
  let vmnet = try object(MachineStatusEntry(Status.Row(instance: one, state: .running, usage: nil)))
  #expect(vmnet["network"] == nil)
  #expect(Set(vmnet.keys) == ["instance", "usage", "reason"])

  let digest = try SHA256Hex(String(repeating: "a", count: 64))
  let policy = BrokeredNetworkPolicy(
    publicEgress: .init(profile: "filtered", allowedHosts: ["api.example.com"], policyHash: "h"),
    providerGrants: ["anthropic"],
    localServices: [
      .init(name: "claude-local-model", guestPort: 1234, hostAddress: "127.0.0.1", hostPort: 1234)
    ])
  let view = BrokeredView(
    bootID: try BootID("b7ad1194a3cc79a7720b4f169833bb62"), externalNICCount: 0,
    networkPolicy: digest, channelPolicy: BrokeredChannel.digest, policy: policy)
  let running = try object(
    MachineStatusEntry(
      Status.Row(
        instance: one, state: .running, usage: nil,
        brokered: .init(requestedTransport: .brokered, effective: view))))
  let network = try #require(running["network"] as? [String: Any])
  #expect(network["transport"] as? String == "brokered")
  #expect(network["requested_transport"] as? String == "brokered")
  let effective = try #require(network["effective"] as? [String: Any])
  #expect(effective["external_nic_count"] as? Int == 0)
  #expect(effective["network_policy_digest"] as? String == digest.rawValue)
  #expect(effective["channel_policy_digest"] as? String == BrokeredChannel.digest.rawValue)
  #expect(effective["fallback"] as? String == "forbidden")
  #expect(effective["provider_grants"] as? [String] == ["anthropic"])
  let egress = try #require(effective["public_egress"] as? [String: Any])
  #expect(egress["allowed_hosts"] as? [String] == ["api.example.com"])
  #expect(egress["policy_hash"] == nil)
  let services = try #require(effective["local_services"] as? [[String: Any]])
  #expect(services.first?["guest_port"] as? Int == 1234)

  // Stopped, or a configuration now requesting vmnet: the observation is
  // null and the mismatch stays visible.
  let stopped = try object(
    MachineStatusEntry(
      Status.Row(
        instance: one, state: .stopped, usage: nil,
        brokered: .init(requestedTransport: .vmnet, effective: nil))))
  let stoppedNetwork = try #require(stopped["network"] as? [String: Any])
  #expect(stoppedNetwork["requested_transport"] as? String == "vmnet")
  #expect(stoppedNetwork["effective"] is NSNull)
}

@Test func capabilitiesListTheCompiledInTransports() throws {
  let capabilities = try object(MachineCapabilitiesResult())
  let transports = try #require(capabilities["network_transports"] as? [String: Any])
  #expect(transports["transports"] as? [String] == ["vmnet", "brokered"])
  #expect(transports["brokered_runtime_feature"] as? String == RuntimeProtocol.brokeredFeature)
}
