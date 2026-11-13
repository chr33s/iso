import Foundation
import IsoMacProtocol
import Testing

@testable import IsoSandboxCore

/// Ties this runtime's own types to the fixtures the host's runtime-boundary tests decode
/// (`tests/fixtures/iso-sandbox/` at the repository root), so a change to what `inspect` or
/// `version` prints fails here until the fixtures (and the host parser they exercise) follow.
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
    var endedBoots: [BootCounts]?
    var disk: DiskSummary

    var output: InspectOutput {
      InspectOutput(
        record: record, status: status, live: live, effective: effective, runtime: runtime,
        endedBoots: endedBoots, disk: disk)
    }
  }

  static func json(_ data: Data) throws -> NSDictionary {
    try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
  }

  static func inspectFixtures() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix("inspect-") && $0.hasSuffix(".json") }.sorted()
  }

  /// `version.json` is what `iso-sandbox version` prints from a default
  /// build; the experimental Core AI build adds one feature to it.
  @Test func theVersionFixtureIsWhatVersionPrints() throws {
    let fixture = try Self.json(
      try Data(contentsOf: Self.directory.appending(path: "version.json")))
    let printed = try #require(
      try Self.json(JSONEncoder.pretty.encode(VersionInfo())).mutableCopy() as? NSMutableDictionary)
    let features = try #require(printed["features"] as? [String])
    printed["features"] = features.filter { $0 != macCoreAIFeature }
    #expect(printed == fixture)
    #expect(fixture["protocol"] as? Int == protocolVersion)
  }

  /// Each fixture decodes with the runtime's record, live-state and effective-configuration
  /// types and encodes, through the encoder `inspect` prints with, to the same JSON value: no
  /// member the runtime does not write, and none it writes missing.
  @Test func inspectFixturesRoundTripThroughTheRuntimeTypes() throws {
    let names = try Self.inspectFixtures()
    #expect(
      names == [
        "inspect-brokered-running.json", "inspect-display-running.json",
        "inspect-display-stopped.json", "inspect-running.json", "inspect-stopped.json",
      ])
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

  /// The display fixture is what a display owner with guest computer use reports mid-stream:
  /// this runtime's display mode, geometry and port, and the counts the host audits.
  @Test func theDisplayFixtureCarriesThisRuntimesDisplayAndCounts() throws {
    let data = try Data(
      contentsOf: Self.directory.appending(path: "inspect-display-running.json"))
    let fixture = try JSONDecoder.iso.decode(InspectFixture.self, from: data)
    let effective = try #require(fixture.effective)
    #expect(fixture.record.displayMode == .virtioDisplay)
    #expect(effective.display == DisplayMode.virtioDisplay.rawValue)
    #expect(effective.graphicsDevices == [["\(LinuxDisplay.width)x\(LinuxDisplay.height)"]])
    #expect(effective.vsockPorts == [GuestCUProtocol.port])
    #expect(effective.liveViewListening == true)
    let runtime = try #require(fixture.runtime)
    let guest = try #require(runtime.guestComputerUse)
    #expect(guest.frameRate == fixture.record.guestComputerUse?.frameRate)
    #expect(guest.frames >= 1 && guest.sessions >= 1)
    #expect(try #require(runtime.liveView).streams == 1)
  }

  /// The stopped display fixture lists the boot that ended, with the counts
  /// its owner last wrote: the same boot and counts as the running fixture.
  @Test func theStoppedDisplayFixtureListsTheBootThatEnded() throws {
    func fixture(_ name: String) throws -> InspectFixture {
      try JSONDecoder.iso.decode(
        InspectFixture.self, from: try Data(contentsOf: Self.directory.appending(path: name)))
    }
    let running = try fixture("inspect-display-running.json")
    let stopped = try fixture("inspect-display-stopped.json")
    #expect(
      try Self.json(JSONEncoder.pretty.encode(stopped.record))
        == Self.json(JSONEncoder.pretty.encode(running.record)))
    #expect(running.endedBoots == nil && stopped.runtime == nil)
    let live = try #require(running.live)
    #expect(stopped.endedBoots == [BootCounts(bootId: live.bootId, try #require(running.runtime))])
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
