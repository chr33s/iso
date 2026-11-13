import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

// docs/audit.md: a boot's computer-use counts are audited once, whether
// `iso stop` read them from the running owner or a later inspection found
// them in the owner's log of ended boots.

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../fixtures/iso-sandbox").standardized
private let sandbox = try! MachineName("iso-0a1b2c3d-00112233445566ff")

private let streamed = MacLiveViewCounts(streams: 1, viewers: 1, takeovers: 0, inputEvents: 0)
private let guestCounts = MacGuestCUCounts(
  frameRate: 4, sessions: 1, frames: 3, actions: 2, statusRequests: 0, preemptions: 0,
  refusals: [:])

private func bootID(_ digit: Character) -> String { String(repeating: digit, count: 32) }

private func stopped(endedBoots: Any?) throws -> SandboxInspection {
  let data = try Data(contentsOf: fixtures.appending(path: "inspect-display-stopped.json"))
  var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  object["endedBoots"] = endedBoots
  return try RuntimeProtocol.parseInspect(
    Array(try JSONSerialization.data(withJSONObject: object)), expected: sandbox)
}

private func events(_ instance: Instance, _ kind: String) throws -> [[String: Any]] {
  try BoundaryAudit.load(instance).filter { $0["event"] as? String == kind }
}

private func backend(_ root: String, _ sink: LogSink) throws -> AppleBackend {
  AppleBackend(
    config: try testConfig("", home: root), environment: [:], diagnostics: sink.diagnostics,
    runtime: { () throws(RuntimeError) in
      throw RuntimeError.unqualified("the audit opens no runtime")
    })
}

/// A stopped display sandbox as the runtime prints it once its boot has
/// ended (tests/fixtures/iso-sandbox/README.md): the boot and counts of the
/// running fixture.
@Test func aStoppedSandboxListsTheBootThatEndedWithItsCounts() throws {
  let running = try RuntimeProtocol.parseInspect(
    Array(try Data(contentsOf: fixtures.appending(path: "inspect-display-running.json"))),
    expected: sandbox)
  let observed = AppleBackend.Observed.linux(try stopped(endedBoots: nil))
  #expect(observed.endedBoots.isEmpty)
  let parsed = try RuntimeProtocol.parseInspect(
    Array(try Data(contentsOf: fixtures.appending(path: "inspect-display-stopped.json"))),
    expected: sandbox)
  let ended = AppleBackend.Observed.linux(parsed).endedBoots
  #expect(
    ended == [
      EndedBoot(
        bootID: try #require(running.live?.bootId),
        guestComputerUse: try #require(running.runtime?.guestComputerUse),
        liveView: try #require(running.runtime?.liveView))
    ])
  #expect(AppleBackend.Observed.linux(running).endedBoots.isEmpty)
  #expect(AppleBackend.Observed.linux(running).computerUse.bootID == running.live?.bootId)
}

/// `endedBoots` is read for the audit only: nothing in it fails the
/// inspection a lifecycle command depends on.
@Test func invalidEndedBootsLoseOnlyThoseBoots() throws {
  let liveView = ["streams": 1, "viewers": 1, "takeovers": 0, "inputEvents": 0]
  var negative = liveView
  negative["viewers"] = -1
  let list: [Any] = [
    ["bootId": bootID("a"), "liveView": liveView],
    ["bootId": "../../etc/passwd", "liveView": liveView],
    ["bootId": bootID("A"), "liveView": liveView],
    ["liveView": liveView],
    7, NSNull(), "boot", [1, 2],
    ["bootId": bootID("b"), "liveView": negative],
  ]
  let boots = try #require(try stopped(endedBoots: list).endedBoots).boots
  #expect(
    boots == [
      EndedBoot(bootID: bootID("a"), guestComputerUse: nil, liveView: streamed),
      EndedBoot(bootID: bootID("b"), guestComputerUse: nil, liveView: nil),
    ])
  for other: Any in ["none", 3, ["bootId": bootID("a")]] {
    #expect(try stopped(endedBoots: other).endedBoots?.boots == [])
  }
  let many = (0..<EndedBoots.limit + 4).map {
    ["bootId": String(format: "%032x", $0), "liveView": liveView] as [String: Any]
  }
  let kept = try #require(try stopped(endedBoots: many).endedBoots).boots
  #expect(kept.count == EndedBoots.limit)
  #expect(kept.last?.bootID == String(format: "%032x", EndedBoots.limit + 3))
}

@Test func aBootsComputerUseIsAuditedOnce() throws {
  let root = try scratchDirectory("ended-boots")
  defer { removeScratch(root) }
  let instance = try testInstance(root + "/instance")
  let first = bootID("1")
  ComputerUseAudit.record(instance, boot: first, [.liveView(streamed)])
  #expect(try events(instance, "live_view").count == 1)
  ComputerUseAudit.record(instance, boot: first, [.liveView(streamed)])
  ComputerUseAudit.record(instance, boot: first, [.guestComputerUse(guestCounts)])
  #expect(try events(instance, "live_view").count == 1)
  #expect(try events(instance, "guest_computer_use").isEmpty)
  ComputerUseAudit.record(
    instance, boot: bootID("2"), [.guestComputerUse(guestCounts), .liveView(streamed)])
  #expect(try events(instance, "live_view").count == 2)
  #expect(try events(instance, "guest_computer_use").count == 1)
}

@Test func aBootWithNothingToAuditIsNotRemembered() throws {
  let root = try scratchDirectory("ended-boots")
  defer { removeScratch(root) }
  let instance = try testInstance(root + "/instance")
  let boot = bootID("3")
  ComputerUseAudit.record(instance, boot: boot, [])
  #expect(!FileManager.default.fileExists(atPath: ComputerUseAudit.path(instance)))
  ComputerUseAudit.record(instance, boot: boot, [.liveView(streamed)])
  #expect(try events(instance, "live_view").count == 1)
}

@Test func theRecordOfAuditedBootsIsBoundedAndSurvivesDamage() throws {
  let root = try scratchDirectory("ended-boots")
  defer { removeScratch(root) }
  let instance = try testInstance(root + "/instance")
  let path = ComputerUseAudit.path(instance)
  let boots = (0..<ComputerUseAudit.limit + 2).map { String(format: "%032x", $0) }
  for boot in boots { ComputerUseAudit.record(instance, boot: boot, [.liveView(streamed)]) }
  let kept = try StateStore.decode(
    ComputerUseAudit.Record.self, try #require(try StateStore.readControlFile(path)), path: path)
  #expect(kept.boots == Array(boots.suffix(ComputerUseAudit.limit)))
  #expect(ComputerUseAudit.limit > EndedBoots.limit)
  let before = try events(instance, "live_view").count
  for boot in boots.suffix(EndedBoots.limit) {
    ComputerUseAudit.record(instance, boot: boot, [.liveView(streamed)])
  }
  #expect(try events(instance, "live_view").count == before)

  try Data("{".utf8).write(to: URL(fileURLWithPath: path))
  ComputerUseAudit.record(instance, boot: boots[0], [.liveView(streamed)])
  #expect(try events(instance, "live_view").count == before + 1)
  ComputerUseAudit.record(instance, boot: boots[0], [.liveView(streamed)])
  #expect(try events(instance, "live_view").count == before + 1)

  try FileManager.default.removeItem(atPath: path)
  try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/dev/null")
  let sink = LogSink()
  ComputerUseAudit.record(
    instance, boot: bootID("4"), [.liveView(streamed)], diagnostics: sink.diagnostics)
  #expect(try events(instance, "live_view").count == before + 1)
  #expect(sink.text.contains("not recorded"))
}

/// A boot that ended without `iso stop` (session expiry, guest poweroff,
/// an owner crash) is audited from what its owner last wrote, by whichever
/// command inspects the instance next; `iso stop` of a running boot audits
/// it from the running owner, and the ended-boot list that follows adds
/// nothing.
@Test func endedBootsAreAuditedAtTheNextInspectionAndAStoppedBootIsNotAuditedAgain() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let sink = LogSink()
  let backend = try backend(guest.root, sink)
  let base = try workloadRunning(guest, identity: nil)
  let instance = base.instance
  let expired = EndedBoot(bootID: bootID("e"), guestComputerUse: guestCounts, liveView: streamed)

  backend.auditEndedBoots(instance, createdWithGuestComputerUse: false, [expired])
  #expect(try events(instance, "live_view").count == 1)
  #expect(try events(instance, "guest_computer_use").isEmpty)
  backend.auditEndedBoots(instance, createdWithGuestComputerUse: false, [expired])
  #expect(try events(instance, "live_view").count == 1)

  let stoppedBoot = bootID("f")
  let running = AppleBackend.Running(
    instance: instance, sidecar: base.sidecar, ready: base.ready, target: base.target,
    handoffIdentity: nil,
    computerUse: .init(bootID: stoppedBoot, guest: nil, liveView: streamed))
  backend.auditComputerUse(running)
  #expect(try events(instance, "live_view").count == 2)
  backend.auditEndedBoots(
    instance, createdWithGuestComputerUse: false,
    [expired, EndedBoot(bootID: stoppedBoot, guestComputerUse: nil, liveView: streamed)])
  #expect(try events(instance, "live_view").count == 2)
}
