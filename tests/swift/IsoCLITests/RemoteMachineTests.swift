import Foundation
import IsoCore
import IsoHost
import Testing

@testable import IsoCLI

@Suite struct RemoteMachineTests {
  private func object(_ value: some Encodable) throws -> [String: Any] {
    let text = try JSONOutput.render(value, pretty: false)
    return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }

  @Test func unreachableRowsAreUnknownAndKeepV1Fields() throws {
    let binding = ClientBinding(
      host: try HostAlias("build-mac"), hostID: .generate(),
      ownerID: try OwnerID(String(repeating: "ab", count: 16)), instanceID: .generate(),
      runtimeID: try MachineName("iso-abababab-0011223344556677"), guestOS: .linux,
      name: try InstanceName("proj"), policyHash: HostWire.sha256([]), createdBy: .generate(),
      lastState: .running, lastObservedAt: 1_800_000_000)
    let row = try object(MachineInstance(.unreachable(binding)))
    #expect(row["name"] as? String == "proj")
    #expect(row["state"] as? String == "unknown")
    #expect(row["backend"] as? String == AppleBackend.name)
    #expect(row["host"] as? String == "build-mac")
    #expect(row["reachability"] as? String == "unreachable")
    #expect(row["last_observed_at"] as? Int == 1_800_000_000)
  }

  @Test func localRowsWithoutAllHostsAreUnchanged() throws {
    let result = MachineListResult(instances: [])
    #expect(try object(result).keys.sorted() == ["instances"])
  }

  @Test func capabilitiesAdvertiseHostControlWithoutSideEffects() throws {
    let host = try #require(
      try object(MachineCapabilitiesResult())["host_control"] as? [String: Any])
    #expect(host["protocols"] as? [String] == ["iso.host/v1"])
    #expect(host["remote_guest_os"] as? [String] == ["linux"])
  }
}
