import Foundation
import Testing

@testable import IsoSandboxCore

@Suite struct SubnetTests {
  func tempRoot() throws -> SandboxRoot {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "csb-\(UUID().uuidString)")
    let root = try SandboxRoot(dir.path)
    try root.createDirectories()
    return root
  }

  func commitRecord(_ root: SandboxRoot, _ name: String, _ index: Int) throws {
    let id = try SandboxID(name)
    let paths = root.sandbox(id)
    try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
    try paths.save(
      SandboxRecord(
        id: id, owner: "o", imageReference: "i", imageDigest: "d", baseDisk: nil, environment: [],
        cpus: 1,
        memoryBytes: 1, diskBytes: 1, subnetIndex: index, createdAt: Date()))
  }

  func commitMacRecord(_ root: SandboxRoot, _ name: String, _ index: Int) throws {
    let id = try SandboxID(name)
    let paths = root.macSandbox(id)
    try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true)
    try paths.save(
      MacSandboxRecord(
        id: id, owner: "o", template: try SandboxID("t"), templateBuild: "b", cpus: 4,
        memoryBytes: 1, macAddress: "1e:00:00:00:00:01", subnetIndex: index, network: .shared,
        enrollment: .pending, authorizedKey: "k", createdAt: Date(), expiresAt: nil))
  }

  @Test func linuxAndMacOSSandboxesNeverShareASubnet() throws {
    let root = try tempRoot()
    try commitMacRecord(root, "m", 1)
    try commitRecord(root, "a", 2)
    var got = 0
    try SubnetAllocator(root: root).allocate(for: try SandboxID("b")) { got = $0 }
    #expect(got == 3)
    // An unreadable macOS record fails closed rather than freeing its subnet.
    try Data("{".utf8).write(to: root.macSandbox(try SandboxID("m")).record)
    #expect(throws: (any Error).self) {
      try SubnetAllocator(root: root).allocate(for: try SandboxID("c")) { _ in }
    }
  }

  @Test func allocatesLowestFreeIndex() throws {
    let root = try tempRoot()
    try commitRecord(root, "a", 1)
    try commitRecord(root, "b", 3)
    var got = 0
    try SubnetAllocator(root: root).allocate(for: try SandboxID("c")) { got = $0 }
    #expect(got == 2)
  }

  @Test func ownIndexIsNotConsideredUsed() throws {
    let root = try tempRoot()
    try commitRecord(root, "a", 1)
    var got = 0
    try SubnetAllocator(root: root).allocate(for: try SandboxID("a")) { got = $0 }
    #expect(got == 1)
  }

  @Test func quarantinedIndexIsSkippedUntilExpiry() throws {
    let root = try tempRoot()
    let alloc = SubnetAllocator(root: root)
    let id = try SandboxID("a")
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var got = 0
    try alloc.quarantineAndReallocate(1, for: id, now: t0) { got = $0 }
    #expect(got == 2)
    try alloc.allocate(for: id, now: t0.addingTimeInterval(60)) { got = $0 }
    #expect(got == 2)
    try alloc.allocate(for: id, now: t0.addingTimeInterval(SubnetAllocator.quarantineTTL + 1)) {
      got = $0
    }
    #expect(got == 1)
  }

  @Test func quarantineIsBounded() {
    var state = SubnetAllocator.State()
    let now = Date()
    for i in 1...(SubnetAllocator.maxQuarantined + 20) {
      state.quarantined[i] = now.addingTimeInterval(TimeInterval(i))
    }
    SubnetAllocator.prune(&state, now: now)
    #expect(state.quarantined.count == SubnetAllocator.maxQuarantined)
    // The oldest entries are the ones dropped.
    #expect(state.quarantined[1] == nil)
  }

  @Test func openTriesPastMoreRefusalsThanTheQuarantineHolds() throws {
    let root = try tempRoot()
    try commitRecord(root, "other", 2)
    struct Refused: Error {}
    let held = 1...(SubnetAllocator.maxQuarantined + 40)
    var opened: [Int] = []
    var committed: [Int] = []
    var moves = 0
    let got = try SubnetAllocator(root: root).open(
      from: 1, for: try SandboxID("a"),
      attempt: { index in
        opened.append(index)
        if held.contains(index) { throw Refused() }
        return index
      },
      commit: { committed.append($0) }, refused: { _, _, _ in moves += 1 })
    #expect(got == held.upperBound + 1)
    #expect(Set(opened).count == opened.count, "no subnet is tried twice")
    #expect(!opened.contains(2), "another sandbox's subnet is never tried")
    #expect(committed.last == got)
    #expect(moves == held.count - 1)
  }

  @Test func openFailsOnceEverySubnetIsRefused() throws {
    let root = try tempRoot()
    struct Refused: Error {}
    var attempts = 0
    #expect(throws: SandboxError.self) {
      try SubnetAllocator(root: root).open(
        from: 1, for: try SandboxID("a"),
        attempt: { (_: Int) -> Int in
          attempts += 1
          throw Refused()
        },
        commit: { _ in }, refused: { _, _, _ in })
    }
    #expect(attempts == SubnetAllocator.range.count)
  }

  @Test func failedCommitAllocatesNothing() throws {
    let root = try tempRoot()
    struct Boom: Error {}
    #expect(throws: Boom.self) {
      try SubnetAllocator(root: root).allocate(for: try SandboxID("a")) { _ in throw Boom() }
    }
    #expect(try root.allRecords().isEmpty)
  }
}
