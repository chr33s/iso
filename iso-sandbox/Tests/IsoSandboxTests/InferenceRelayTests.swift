import Containerization
import ContainerizationExtras
import Foundation
import Testing

@testable import IsoSandboxCore

/// The one socket relay a record can request (secure-local-inference §22).
@Suite struct InferenceRelayTests {
  func record(relay: Bool? = nil) throws -> SandboxRecord {
    var r = SandboxRecord(
      id: try SandboxID("a"), owner: "o", imageReference: "i", imageDigest: "d", baseDisk: nil,
      environment: [], cpus: 1, memoryBytes: 1 << 30, diskBytes: 1 << 30, subnetIndex: 1,
      createdAt: Date(timeIntervalSince1970: 0))
    r.inferenceRelay = relay
    return r
  }

  func paths() throws -> SandboxPaths {
    try SandboxRoot(FileManager.default.temporaryDirectory.path + "/csb-relay").sandbox(
      try SandboxID("a"))
  }

  func interface() throws -> NATInterface {
    NATInterface(
      ipv4Address: try CIDRv4("10.231.1.2/24"), ipv4Gateway: try IPv4Address("10.231.1.1"))
  }

  @Test func absentByDefaultAndCarriesNoPath() throws {
    let off = try record()
    #expect(!off.relaysInference)
    let plain =
      try JSONSerialization.jsonObject(with: JSONEncoder.pretty.encode(off)) as? [String: Any]
      ?? [:]
    #expect(plain["inferenceRelay"] == nil)
    let on = try record(relay: true)
    let text = String(decoding: try JSONEncoder.pretty.encode(on), as: UTF8.self)
    #expect(text.contains("\"inferenceRelay\" : true"))
    #expect(try JSONDecoder.iso.decode(SandboxRecord.self, from: Data(text.utf8)).relaysInference)
    // The record can only switch the relay on; no host or guest path.
    #expect(!text.contains(".sock"))
  }

  @Test func hostSocketIsDerivedInsideThePrivateDirectory() throws {
    let socket = try paths().inferenceSocket
    #expect(socket.deletingLastPathComponent().path == InferenceRelay.hostDirectory.path)
    #expect(socket.lastPathComponent.hasSuffix(".sock"))
    let name = socket.lastPathComponent.dropLast(5)
    #expect(!name.isEmpty && name.allSatisfy { $0.isHexDigit })
    // It must fit sun_path.
    #expect(socket.path.utf8.count < 104)
  }

  @Test func ownerConfiguresExactlyTheInferenceRelay() throws {
    let p = try paths()
    let off = Owner.machineConfiguration(
      record: try record(), paths: p, interface: try interface(), bootLog: .fileHandle(.nullDevice))
    #expect(off.sockets.isEmpty)
    let on = Owner.machineConfiguration(
      record: try record(relay: true), paths: p, interface: try interface(),
      bootLog: .fileHandle(.nullDevice))
    let relay = try #require(on.sockets.first)
    #expect(on.sockets.count == 1)
    #expect(relay.source == p.inferenceSocket)
    #expect(relay.destination.path == "/var/lib/iso-inference/gateway.sock")
    #expect(relay.maxConnections == 32)
    #expect(relay.direction == .into)
    let effective = Owner.effectiveConfig(
      record: try record(relay: true), config: on,
      rootfs: .block(format: "ext4", source: "/r", destination: "/", options: []),
      interface: try interface())
    #expect(effective.socketRelays == 1)
    #expect(
      effective.inferenceRelay
        == .init(host: p.inferenceSocket.path, guest: InferenceRelay.guestPath, maxConnections: 32))
  }
}
