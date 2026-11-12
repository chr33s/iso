import Foundation
import Testing

@testable import IsoSandboxCore

/// A boot's computer-use counts outlive it (`boot-counts.json`), so the
/// host can audit a boot it did not stop.
@MainActor
@Suite struct BootCountsTests {
  /// The counts a test's "owner" reports now.
  final class Counts {
    var now = DesktopStatus(guestComputerUse: nil, liveView: nil)
  }

  let dir: URL
  var log: URL { dir.appendingPathComponent("boot-counts.json") }

  init() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "boots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  func ended(live: String?) -> [BootCounts]? {
    BootCountsLog.ended(BootCountsLog.load(log), live: live)
  }

  func recorder(_ boot: String, _ counts: Counts) -> BootCountsRecorder {
    BootCountsRecorder(url: log, bootId: boot, log: { _ in }, counts: { counts.now })
  }

  static func streamed(viewers: Int) -> DesktopStatus {
    var liveView = MacLiveViewCounters()
    liveView.streams = 1
    liveView.viewers = viewers
    return DesktopStatus(guestComputerUse: nil, liveView: liveView)
  }

  func modified() throws -> Date {
    try #require(
      try FileManager.default.attributesOfItem(atPath: log.path)[.modificationDate] as? Date)
  }

  @Test func aBootWithoutCountsWritesNothing() {
    defer { try? FileManager.default.removeItem(at: dir) }
    let counts = Counts()
    let boot = recorder("a", counts)
    boot.record()
    #expect(!FileManager.default.fileExists(atPath: log.path))
    #expect(ended(live: nil) == nil)
    // Nor one whose display does not exist yet.
    BootCountsRecorder(url: log, bootId: "b", log: { _ in }).record()
    #expect(!FileManager.default.fileExists(atPath: log.path))
  }

  @Test func aBootsCountsAreRewrittenOnlyWhenTheyChange() throws {
    defer { try? FileManager.default.removeItem(at: dir) }
    let counts = Counts()
    let boot = recorder("a", counts)
    counts.now = Self.streamed(viewers: 1)
    boot.record()
    #expect(ended(live: nil) == [BootCounts(bootId: "a", counts.now)])
    // Unchanged: the file is left alone.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: log.path)
    boot.record()
    #expect(try modified() == Date(timeIntervalSince1970: 1))
    // Changed: the boot's one entry is replaced, not added to.
    counts.now = Self.streamed(viewers: 2)
    boot.record()
    #expect(ended(live: nil) == [BootCounts(bootId: "a", counts.now)])
  }

  /// launchd restarts a crashed owner; the new boot's counts go beside the
  /// crashed boot's, and only the boot now running is left out.
  @Test func aRestartedOwnerKeepsTheEarlierBootsCounts() {
    defer { try? FileManager.default.removeItem(at: dir) }
    let crashed = Counts()
    crashed.now = Self.streamed(viewers: 3)
    recorder("crashed", crashed).record()
    let running = Counts()
    running.now = DesktopStatus(guestComputerUse: MacGuestCUCounters(frameRate: 4), liveView: nil)
    recorder("running", running).record()

    let earlier = BootCounts(bootId: "crashed", crashed.now)
    #expect(ended(live: "running") == [earlier])
    // Once it has ended too (its owner gone, whatever live.json says), both.
    #expect(
      ended(live: nil) == [earlier, BootCounts(bootId: "running", running.now)])
    #expect(ended(live: "crashed")?.map(\.bootId) == ["running"])
  }

  @Test func theLogKeepsOnlyItsMostRecentBoots() {
    defer { try? FileManager.default.removeItem(at: dir) }
    let counts = Counts()
    counts.now = Self.streamed(viewers: 1)
    let boots = (0..<BootCountsLog.limit + 3).map { "boot-\($0)" }
    for boot in boots { recorder(boot, counts).record() }
    #expect(BootCountsLog.load(log).count == BootCountsLog.limit)
    #expect(
      ended(live: nil)?.map(\.bootId)
        == Array(boots.suffix(BootCountsLog.limit)))
  }

  @Test func anUnreadableLogHoldsNoBootsAndIsReplaced() throws {
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data("not json".utf8).write(to: log)
    #expect(ended(live: nil) == nil)
    let counts = Counts()
    counts.now = Self.streamed(viewers: 1)
    recorder("a", counts).record()
    #expect(ended(live: nil)?.map(\.bootId) == ["a"])
  }

  /// What `inspect` prints for a stopped sandbox whose last boot had counts.
  @Test func inspectReportsAStoppedSandboxesEndedBoots() throws {
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try SandboxRoot(dir.appendingPathComponent("runtime").path)
    try root.createDirectories()
    let stopped = try Data(
      contentsOf: HostFixtureConformanceTests.directory.appending(path: "inspect-stopped.json"))
    let record = try JSONDecoder.iso.decode(
      HostFixtureConformanceTests.InspectFixture.self, from: stopped
    ).record
    let paths = root.sandbox(record.id)
    try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
    try paths.save(record)
    #expect(try Sandboxes.inspect(root: root, id: record.id).endedBoots == nil)

    let counts = Counts()
    counts.now = Self.streamed(viewers: 1)
    BootCountsRecorder(
      url: paths.bootCounts, bootId: "ended", log: { _ in }, counts: { counts.now }
    ).record()
    let inspected = try Sandboxes.inspect(root: root, id: record.id)
    #expect(inspected.status == .stopped && inspected.runtime == nil)
    #expect(inspected.endedBoots == [BootCounts(bootId: "ended", counts.now)])
  }

  /// An owner alive: its lock held, as for the owner's whole life.
  func holdLock(_ url: URL) -> Int32 {
    let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    #expect(fd >= 0 && flock(fd, LOCK_EX) == 0)
    return fd
  }

  /// The boot live.json names has ended once its owner is gone (a crash
  /// leaves the file behind), and is not listed while its owner lives.
  @Test func aCrashedOwnersBootIsListedAsEnded() throws {
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try SandboxRoot(dir.appendingPathComponent("runtime").path)
    try root.createDirectories()
    let record = try JSONDecoder.iso.decode(
      HostFixtureConformanceTests.InspectFixture.self,
      from: try Data(
        contentsOf: HostFixtureConformanceTests.directory.appending(path: "inspect-stopped.json"))
    ).record
    let paths = root.sandbox(record.id)
    try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
    try paths.save(record)
    let counts = Counts()
    counts.now = Self.streamed(viewers: 1)
    for boot in ["earlier", "latest"] {
      BootCountsRecorder(
        url: paths.bootCounts, bootId: boot, log: { _ in }, counts: { counts.now }
      ).record()
    }
    try JSONEncoder.pretty.encode(
      LiveState(pid: 999_999, startedAt: Date(), ipv4: nil, ipv6: nil, bootId: "latest")
    ).write(to: paths.live)

    let fd = holdLock(paths.lock)
    let alive = try Sandboxes.inspect(root: root, id: record.id)
    #expect(alive.status == .booting && alive.endedBoots?.map(\.bootId) == ["earlier"])
    close(fd)
    let crashed = try Sandboxes.inspect(root: root, id: record.id)
    #expect(crashed.status == .crashed)
    #expect(crashed.endedBoots?.map(\.bootId) == ["earlier", "latest"])
  }

  @Test func aMacSandboxListsItsEndedBootsTheSameWay() throws {
    defer { try? FileManager.default.removeItem(at: dir) }
    let root = try SandboxRoot(dir.appendingPathComponent("runtime").path)
    try root.createDirectories()
    try root.createMacDirectories()
    let record = MacSandboxRecord(
      id: try SandboxID("m1"), owner: "o", template: try SandboxID("t"), templateBuild: "b",
      cpus: 4, memoryBytes: 8 << 30, macAddress: "02:00:00:00:00:01", subnetIndex: 3,
      network: .shared, enrollment: .pending, authorizedKey: "ssh-ed25519 AAAA test",
      createdAt: Date(), expiresAt: nil, coreAI: nil)
    let paths = root.macSandbox(record.id)
    try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
    try paths.save(record)
    #expect(try MacSandboxes.inspect(root: root, id: record.id).endedBoots == nil)

    let counts = Counts()
    counts.now = Self.streamed(viewers: 1)
    for boot in ["earlier", "latest"] {
      BootCountsRecorder(
        url: paths.bootCounts, bootId: boot, log: { _ in }, counts: { counts.now }
      ).record()
    }
    let stopped = try MacSandboxes.inspect(root: root, id: record.id)
    #expect(stopped.status == .stopped)
    #expect(stopped.endedBoots?.map(\.bootId) == ["earlier", "latest"])

    try JSONEncoder.pretty.encode(
      MacLiveState(pid: 999_999, startedAt: Date(), bootId: "latest", ipv4: "10.231.3.2")
    ).write(to: paths.live)
    let fd = holdLock(paths.lock)
    let alive = try MacSandboxes.inspect(root: root, id: record.id)
    #expect(alive.status == .booting && alive.endedBoots?.map(\.bootId) == ["earlier"])
    close(fd)
    let crashed = try MacSandboxes.inspect(root: root, id: record.id)
    #expect(crashed.status == .crashed)
    #expect(crashed.endedBoots?.map(\.bootId) == ["earlier", "latest"])
  }
}
