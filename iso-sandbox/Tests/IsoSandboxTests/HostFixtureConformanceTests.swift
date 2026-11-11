import Foundation
import Testing

@testable import IsoSandboxCore

/// Ties this runtime's own types to the fixtures the host's runtime-boundary
/// tests decode (`tests/fixtures/iso-sandbox/` at the repository root), so a
/// change to what `inspect` or `version` prints fails here until the fixtures
/// (and the host parser they exercise) follow.
@Suite struct HostFixtureConformanceTests {
  static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../tests/fixtures/iso-sandbox").standardized

  /// `InspectOutput` is encode-only; this reads the same members with the
  /// same runtime types.
  struct InspectFixture: Decodable {
    var record: SandboxRecord
    var status: SandboxStatus
    var live: LiveState?
    var effective: EffectiveConfig?
    var runtime: DesktopStatus?
    var disk: DiskSummary

    var output: InspectOutput {
      InspectOutput(
        record: record, status: status, live: live, effective: effective, runtime: runtime,
        disk: disk)
    }
  }

  static func json(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  static func inspectFixtures() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("inspect-") && $0.hasSuffix(".json") }.sorted()
  }

  @Test func theVersionFixtureNamesThisRuntimesContract() throws {
    let version = try Self.json(
      try Data(contentsOf: Self.directory.appending(path: "version.json")))
    #expect(version["name"] as? String == "iso-sandbox")
    #expect(version["protocol"] as? Int == protocolVersion)
    #expect(version["containerization"] as? String == containerizationVersion)
    // `version` is a representative release number the host only displays,
    // so it is not compared with `runtimeVersion`.
    #expect(version["version"] is String)
  }

  /// Each fixture decodes with the runtime's record, live-state and
  /// effective-configuration types and encodes, through the encoder
  /// `inspect` prints with, to the same JSON value: no member the runtime
  /// does not write, and none it writes missing.
  @Test func inspectFixturesRoundTripThroughTheRuntimeTypes() throws {
    let names = try Self.inspectFixtures()
    #expect(
      names == ["inspect-brokered-running.json", "inspect-running.json", "inspect-stopped.json"])
    for name in names {
      let data = try Data(contentsOf: Self.directory.appending(path: name))
      let fixture: InspectFixture
      do { fixture = try JSONDecoder.iso.decode(InspectFixture.self, from: data) } catch {
        Issue.record("\(name): the runtime's types do not decode the fixture: \(error)")
        continue
      }
      let encoded = try JSONEncoder.pretty.encode(fixture.output)
      #expect(try Self.json(encoded) == Self.json(data), "\(name)")
      #expect(fixture.record.id.rawValue == "iso-0a1b2c3d-00112233445566ff", "\(name)")
      #expect((fixture.status == .running) == (fixture.live != nil), "\(name)")
      #expect((fixture.status == .running) == (fixture.effective != nil), "\(name)")
    }
  }

  @Test func theBrokeredFixtureCarriesThisRuntimesChannelPolicy() throws {
    let data = try Data(
      contentsOf: Self.directory.appending(path: "inspect-brokered-running.json"))
    let fixture = try JSONDecoder.iso.decode(InspectFixture.self, from: data)
    let effective = try #require(fixture.effective)
    #expect(fixture.record.network == .brokered)
    #expect(fixture.record.subnetIndex == nil)
    #expect(effective.transport == "brokered")
    #expect(effective.channelPolicy == ChannelPolicy.current)
    #expect(effective.channelPolicyDigest == ChannelPolicy.current.digest)
    #expect(effective.networkPolicy == fixture.record.networkPolicy)
  }
}
