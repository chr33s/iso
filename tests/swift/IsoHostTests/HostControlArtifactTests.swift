import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost
@testable import IsoHostControl

@Suite struct HostControlArtifactTests {
  let owner = try! OwnerID(String(repeating: "ab", count: 16))
  let stranger = try! OwnerID(String(repeating: "cd", count: 16))

  func store() throws -> (ArtifactStore, ManualClock, String) {
    let root = FileManager.default.temporaryDirectory.appending(path: "iso-art-\(UUID())").path
    let clock = ManualClock()
    return (try ArtifactStore(root: root, clock: clock), clock, root)
  }

  func upload(_ store: ArtifactStore, _ bytes: [UInt8], kind: ArtifactKind = .buildContext)
    throws -> ArtifactStore.Record
  {
    let record = try store.begin(
      owner: owner, kind: kind, size: UInt64(bytes.count), digest: HostWire.sha256(bytes))
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + 1_000, bytes.count)
      _ = try store.write(
        owner: owner, handle: record.handle, offset: UInt64(offset),
        bytes: Array(bytes[offset..<end]))
      offset = end
    }
    return try store.commit(owner: owner, handle: record.handle)
  }

  @Test func verifiedUploadIsReadableOnlyByItsOwner() throws {
    let (store, _, root) = try store()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let bytes = tarArchive([("a/b.txt", Array("hello".utf8))])
    let record = try upload(store, bytes)
    #expect(record.state == .committed)
    #expect(
      try store.read(owner: owner, handle: record.handle, offset: 0, length: 5)
        == Array(bytes.prefix(5)))
    #expect(throws: HostControlError.self) {
      try store.read(owner: stranger, handle: record.handle, offset: 0, length: 5)
    }
  }

  @Test func digestMismatchDiscardsTheUpload() throws {
    let (store, _, root) = try store()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let bytes = tarArchive([("a", [1])])
    let record = try store.begin(
      owner: owner, kind: .buildContext, size: UInt64(bytes.count), digest: HostWire.sha256([0]))
    _ = try store.write(owner: owner, handle: record.handle, offset: 0, bytes: bytes)
    #expect(throws: HostControlError.self) { try store.commit(owner: owner, handle: record.handle) }
    #expect(throws: HostControlError.self) { try store.record(owner: owner, handle: record.handle) }
  }

  @Test func writesAreSequentialAndBounded() throws {
    let (store, _, root) = try store()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let record = try store.begin(
      owner: owner, kind: .buildContext, size: 4, digest: HostWire.sha256([1, 2, 3, 4]))
    #expect(throws: HostControlError.self) {
      try store.write(owner: owner, handle: record.handle, offset: 2, bytes: [1])
    }
    #expect(throws: HostControlError.self) {
      try store.write(owner: owner, handle: record.handle, offset: 0, bytes: [1, 2, 3, 4, 5])
    }
    #expect(throws: HostControlError.self) {
      try store.begin(
        owner: owner, kind: .buildContext, size: ArtifactKind.buildContext.maxBytes + 1,
        digest: HostWire.sha256([]))
    }
    #expect(throws: HostControlError.self) {
      try store.begin(owner: owner, kind: .runResult, size: 1, digest: HostWire.sha256([]))
    }
  }

  @Test func hostileArchivesAreRefused() throws {
    let hostile: [(String, [UInt8])] = [
      ("absolute", tarArchive([("/etc/passwd", [1])])),
      ("traversal", tarArchive([("a/../../x", [1])])),
      ("duplicate", tarArchive([("a", [1]), ("a", [2])])),
      (
        "symlink escape",
        tarArchive([], extra: [tarHeader(name: "l", size: 0, type: "2", link: "../../etc")])
      ),
      (
        "absolute symlink",
        tarArchive([], extra: [tarHeader(name: "l", size: 0, type: "2", link: "/etc")])
      ),
      (
        "write through link",
        tarArchive([("l/x", [1])], extra: []).dropLast(1024)
          + tarHeader(name: "l", size: 0, type: "2", link: "d") + [UInt8](repeating: 0, count: 1024)
      ),
      (
        "file beneath a link",
        tarHeader(name: "l", size: 0, type: "2", link: "d")
          + tarArchive([("l/x", [1])])
      ),
      ("device", tarArchive([], extra: [tarHeader(name: "dev", size: 0, type: "3")])),
      (
        "hard link to nothing",
        tarArchive([], extra: [tarHeader(name: "h", size: 0, type: "1", link: "missing")])
      ),
      ("truncated", Array(tarArchive([("a", [1])]).dropLast(512))),
      // Only an empty directory may name the root.
      ("root file", tarArchive([("./", [1])])),
      ("root link", tarArchive([], extra: [tarHeader(name: "./", size: 0, type: "2", link: "x")])),
    ]
    for (label, bytes) in hostile {
      #expect(throws: HostControlError.self, "\(label)") {
        try ArchiveValidator.validate(bytes: Array(bytes))
      }
    }
    let ok = tarArchive(
      [("d/f", [1])], extra: [tarHeader(name: "d/l", size: 0, type: "2", link: "f")])
    #expect(try ArchiveValidator.validate(bytes: ok).members == 2)
    // `tar cf - -C dir .` (GNU and BSD) leads with a `./` directory member.
    let rooted = tarHeader(name: "./", size: 0, type: "5") + tarArchive([("./hello.txt", [1])])
    #expect(try ArchiveValidator.validate(bytes: rooted).members == 2)
  }

  /// Each member names ~2,000 levels under a fresh top-level directory; keying
  /// every implied ancestor by its full prefix retained gigabytes here.
  @Test(.timeLimit(.minutes(1))) func deepMemberNamesStayLinearInArchiveSize() throws {
    var archive: [UInt8] = []
    let members = 1_000
    for index in 0..<members {
      let top = String(index, radix: 36)
      let name = top + String(repeating: "/a", count: (4_000 - top.utf8.count) / 2)
      let record = "path=\(name)"
      var length = record.utf8.count + 3
      while "\(length) \(record)\n".utf8.count != length { length += 1 }
      let data = Array("\(length) \(record)\n".utf8)
      archive += tarHeader(name: "pax", size: data.count, type: "x") + data
      archive += [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
      archive += tarHeader(name: "placeholder", size: 0, type: "0")
    }
    archive += [UInt8](repeating: 0, count: 1024)
    #expect(try ArchiveValidator.validate(bytes: archive).members == members)
    // The tree still sees every implied ancestor.
    let conflict =
      tarArchive([("a/b/c/d", [1])], extra: [tarHeader(name: "a/b", size: 0, type: "0")])
    #expect(throws: HostControlError.self) { try ArchiveValidator.validate(bytes: conflict) }
    let beneath = tarArchive([("a/b", [1]), ("a/b/c", [1])])
    #expect(throws: HostControlError.self) { try ArchiveValidator.validate(bytes: beneath) }
    let throughLink = tarArchive(
      [("d/f", [1])],
      extra: [
        tarHeader(name: "d/l", size: 0, type: "2", link: "f"),
        tarHeader(name: "m", size: 0, type: "2", link: "D/L/x"),
      ])
    #expect(throws: HostControlError.self) { try ArchiveValidator.validate(bytes: throughLink) }
    let hardLink = tarArchive(
      [("d/f", [1])], extra: [tarHeader(name: "h", size: 0, type: "1", link: "D/F")])
    #expect(try ArchiveValidator.validate(bytes: hardLink).members == 2)
  }

  @Test func extractorDesyncAndChainedLinksAreRefused() throws {
    func pax(_ records: [String]) -> [UInt8] {
      let body = records.map { record -> String in
        var length = record.utf8.count + 3
        while "\(length) \(record)\n".utf8.count != length { length += 1 }
        return "\(length) \(record)\n"
      }.joined()
      let data = Array(body.utf8)
      return tarHeader(name: "pax", size: data.count, type: "x") + data
        + [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
    }
    /// `header` with bytes at `offset` replaced and the checksum redone.
    func patched(_ header: [UInt8], _ text: String, at offset: Int) -> [UInt8] {
      var out = header
      for (index, byte) in text.utf8.enumerated() { out[offset + index] = byte }
      for index in 148..<156 { out[index] = 32 }
      let sum = out.reduce(0) { $0 + Int($1) }
      for (index, byte) in (String(sum, radix: 8).leftPad(6) + "\0 ").utf8.enumerated() {
        out[148 + index] = byte
      }
      return out
    }
    func longName(_ type: Character, _ text: String) -> [UInt8] {
      let data = Array((text + "\0").utf8)
      return tarHeader(name: "././@LongLink", size: data.count, type: type) + data
        + [UInt8](repeating: 0, count: (512 - data.count % 512) % 512)
    }
    let cases: [(String, [UInt8])] = [
      (
        // libarchive reads a regular `foo/` as a directory, and its data
        // blocks as the headers of hidden members.
        "regular file with a directory name",
        tarArchive(
          [],
          extra: [
            tarHeader(name: "foo/", size: 1024, type: "0"),
            tarHeader(name: "esc", size: 0, type: "2", link: "/etc"),
            [UInt8](repeating: 0, count: 512),
          ])
      ),
      (
        // Old GNU keeps atime at 345, which must not read as a prefix.
        "old GNU absolute name",
        tarArchive(
          [],
          extra: [
            patched(
              patched(tarHeader(name: "/tmp/abs", size: 0, type: "0"), "ustar  \0", at: 257),
              "00000000001", at: 345)
          ])
      ),
      (
        "unknown ustar variant",
        tarArchive(
          [], extra: [patched(tarHeader(name: "a", size: 0, type: "0"), "ustar\0zz", at: 257)])
      ),
      ("pax then GNU name", pax(["path=a"]) + longName("L", "b") + tarArchive([("c", [1])])),
      ("GNU then pax name", longName("L", "b") + pax(["path=a"]) + tarArchive([("c", [1])])),
      (
        "pax then GNU link",
        pax(["linkpath=x"]) + longName("K", "y")
          + tarArchive([], extra: [tarHeader(name: "l", size: 0, type: "2", link: "z")])
      ),
      (
        "pax size",
        tarArchive([("a", [1])], extra: []).dropLast(1024) + pax(["size=1024"])
          + tarArchive([("b", [])])
      ),
      ("pax xattr", pax(["SCHILY.xattr.user.x=y"]) + tarArchive([("a", [1])])),
      (
        "pax overflowing length",
        pax(["path=a", "9223372036854775807 x=y"]) + tarArchive([("a", [1])])
      ),
      (
        "chained link",
        tarArchive(
          [],
          extra: [
            tarHeader(name: "a/b", size: 0, type: "2", link: "c"),
            tarHeader(name: "e", size: 0, type: "2", link: "a/b/x"),
          ])
      ),
      (
        "case-folded parent",
        tarArchive([("A/x", [1])], extra: [tarHeader(name: "a", size: 0, type: "2", link: "d")])
      ),
    ]
    for (label, bytes) in cases {
      #expect(throws: HostControlError.self, "\(label)") {
        try ArchiveValidator.validate(bytes: Array(bytes))
      }
    }
  }

  @Test func incompleteUploadsExpireUnlessRetained() throws {
    let (store, clock, root) = try store()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let loose = try store.begin(
      owner: owner, kind: .buildContext, size: 10, digest: HostWire.sha256([]))
    let kept = try upload(store, tarArchive([("a", [1])]))
    try store.retain(owner: owner, handle: kept.handle, by: "op-1")
    #expect(throws: HostControlError.self) {
      try store.retain(owner: owner, handle: kept.handle, by: "op-2")
    }
    #expect(throws: HostControlError.self) {
      try store.release(owner: owner, handle: kept.handle, by: "op-2")
    }
    clock.advance(.seconds(3_601))
    store.sweep()
    #expect(throws: HostControlError.self) { try store.record(owner: owner, handle: loose.handle) }
    #expect(try store.record(owner: owner, handle: kept.handle).retainedBy == "op-1")
    try store.release(owner: owner, handle: kept.handle, by: "op-1")
    #expect(throws: HostControlError.self) { try store.record(owner: owner, handle: kept.handle) }
  }
}

@Suite struct RemoteRunOwnershipTests {
  func create(_ f: SupervisorFixture, egress: EgressMode = .none) throws -> RunID {
    let run = RunID.generate()
    let receipt = try f.receipt(
      .runCreate(
        run: run, spec: try f.spec(name: "run", egress: egress), outputLimitBytes: 1 << 20,
        ttlSeconds: 600))
    #expect(receipt.disposition == .accepted)
    f.supervisor.runPending()
    return run
  }

  func inspect(_ f: SupervisorFixture, _ run: RunID) throws -> RunObservation {
    try RunObservation(wire: f.call(.runInspect(run)).get())
  }

  @Test func resultsArePublishedOnlyAfterAVerifiedStop() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    var state = try inspect(f, run)
    let instance = try #require(state.instanceID)
    let runtime = try #require(try f.supervisor.store.loadInstance(instance)?.runtimeID)
    // The stop fails and the VM keeps running: nothing may be published.
    f.native.set { $0.stopRefused = true }
    _ = try f.receipt(.runComplete(run: run, expectedGeneration: state.generation, exitStatus: 0))
    f.supervisor.runPending()
    state = try inspect(f, run)
    #expect(state.phase == .stopping)
    #expect(state.artifact != nil)
    #expect(f.native.vm(runtime) != .stopped)
    // Once the stop works, the next pass publishes with a retention deadline.
    f.native.set { $0.stopRefused = false }
    f.supervisor.runPending()
    state = try inspect(f, run)
    #expect(state.phase == .resultsPending)
    #expect(state.retentionDeadline != nil)
    #expect(f.native.vm(runtime) == .stopped)
  }

  @Test func aRunWhoseVMNeverStopsIsDestroyedWhenRetentionExpires() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    var state = try inspect(f, run)
    let instance = try #require(state.instanceID)
    let runtime = try #require(try f.supervisor.store.loadInstance(instance)?.runtimeID)
    // The VM crashed and refuses every stop: the run cannot leave .stopping.
    f.native.set {
      $0.unhealthy.insert(runtime)
      $0.stopRefused = true
    }
    _ = try f.receipt(.runComplete(run: run, expectedGeneration: state.generation, exitStatus: 0))
    f.supervisor.runPending()
    state = try inspect(f, run)
    #expect(state.phase == .stopping)
    // Retention still bounds it: the run and its VM are destroyed, freeing the slot.
    f.clock.advance(.seconds(Int64(RunStore.retentionSeconds) + 1))
    f.supervisor.runPending()
    state = try inspect(f, run)
    #expect(state.phase == .destroyed)
    #expect(f.native.vm(runtime) == nil)
  }

  func runCreate(_ f: SupervisorFixture, _ run: RunID) throws -> OperationReceipt {
    try f.receipt(
      .runCreate(
        run: run, spec: try f.spec(name: "run", egress: .none), outputLimitBytes: 1 << 20,
        ttlSeconds: 600))
  }

  @Test func aRunCreateWhoseRunCannotBeWrittenLeavesNothing() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let runsRoot = f.supervisor.runs.root
    #expect(chmod(runsRoot, 0o500) == 0)
    #expect(throws: HostControlError.self) { try runCreate(f, RunID.generate()) }
    #expect(chmod(runsRoot, 0o700) == 0)
    // The child create was undone with it, and no ledger slot is held.
    #expect(f.supervisor.store.operationIDs().isEmpty)
    #expect(f.supervisor.store.usedSlots() == 0)
    #expect(f.supervisor.store.instanceIDs().isEmpty)
    #expect(f.supervisor.runs.runIDs().isEmpty)
  }

  @Test func repairDiscardsARunWhoseParentWasNeverWritten() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = RunID.generate()
    let parent = try runCreate(f, run)
    // A crash before the parent operation reached disk.
    unlink(f.supervisor.store.operationPath(parent.operationID))
    f.supervisor.repairUnacceptedAdmissions()
    #expect(try f.supervisor.runs.load(run) == nil)
    #expect(f.supervisor.store.operationIDs().isEmpty)
    #expect(f.supervisor.store.instanceIDs().isEmpty)
    #expect(f.native.calls("create") == 0)
    // The run id is free again.
    #expect(try runCreate(f, run).disposition == .accepted)
  }

  @Test func repairDiscardsARunChildWithoutItsRun() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = RunID.generate()
    let parent = try runCreate(f, run)
    // A crash after the child create, before the run record.
    unlink(f.supervisor.store.operationPath(parent.operationID))
    try f.supervisor.runs.remove(run)
    #expect(f.supervisor.store.operationIDs().count == 1)
    f.supervisor.repairUnacceptedAdmissions()
    #expect(f.supervisor.store.operationIDs().isEmpty)
    #expect(f.supervisor.store.instanceIDs().isEmpty)
  }

  @Test func normalCompletionExportsBeforeStopAndAckDestroys() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    var state = try inspect(f, run)
    #expect(state.phase == .running)
    _ = try f.receipt(.runComplete(run: run, expectedGeneration: state.generation, exitStatus: 0))
    f.supervisor.runPending()
    state = try inspect(f, run)
    #expect(state.phase == .resultsPending)
    let digest = try #require(state.artifactDigest)
    let handle = try #require(state.artifact)
    let instance = try #require(state.instanceID)
    let runtime = try #require(try f.supervisor.store.loadInstance(instance)?.runtimeID)
    #expect(f.native.vm(runtime) == .stopped)
    // The client downloads without booting the VM.
    let chunk = try f.call(.artifactRead(handle: handle, offset: 0, length: 512)).get()
    #expect(chunk["data"] != nil)
    // A wrong digest cannot acknowledge.
    #expect(
      failure(
        f.call(
          .runResultsAck(
            run: run, expectedGeneration: state.generation, digest: HostWire.sha256([]),
            stage: .generate()), operation: .generate()))
        == .invalidRequest)
    let ack = try f.receipt(
      .runResultsAck(
        run: run, expectedGeneration: state.generation, digest: digest, stage: .generate()))
    f.supervisor.runPending()
    #expect(try f.operation(ack.operationID).state == .succeeded)
    state = try inspect(f, run)
    #expect(state.phase == .destroyed)
    #expect(state.disposition == "delivered")
    #expect(f.native.vm(runtime) == nil)
    #expect(f.supervisor.runs.slotsInUse() == 0)
  }

  @Test func cancellingRunCreateCancelsItsChildAndFreesItsSlot() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let before = f.supervisor.store.usedSlots()
    let receipt = try f.receipt(
      .runCreate(
        run: .generate(), spec: try f.spec(name: "run"), outputLimitBytes: 1 << 20, ttlSeconds: 600)
    )
    // The child create is never dispatched on its own.
    f.supervisor.reconcileAll()
    let cancelled = try OperationReceipt(
      wire: f.call(.operationCancel(target: receipt.operationID)).get())
    #expect(cancelled.state == .cancelled)
    f.supervisor.runPending()
    #expect(f.native.calls("create") == 0)
    #expect(f.supervisor.runs.slotsInUse() == 0)
    // Only the cancelled records and the tombstone remain.
    #expect(f.supervisor.store.usedSlots() <= before + 3)
  }

  @Test func fourRetentionSlotsBoundConcurrency() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    for _ in 0..<4 { _ = try create(f) }
    let fifth = f.call(
      .runCreate(
        run: .generate(), spec: try f.spec(name: "run"), outputLimitBytes: 1 << 20, ttlSeconds: 600),
      operation: .generate())
    #expect(failure(fifth) == .limitExceeded)
  }

  @Test func controllerLossStopsAndOneRecoveryIsAllowed() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    f.clock.advance(.seconds(61))
    f.supervisor.reconcileRun(run)
    var state = try inspect(f, run)
    #expect(state.phase == .stoppedDiskPendingExport)
    #expect(state.artifact == nil)
    // Only the run's transitions boot its disk: a plain start or maintenance
    // would bypass its recovery allowance and restrictions.
    let childID = try #require(state.instanceID)
    let child = try #require(try f.supervisor.store.loadInstance(childID))
    #expect(
      failure(
        f.call(
          .vmStart(
            child.qualified, expectedGeneration: child.generation, ttlSeconds: 60,
            policy: try f.spec(name: "run", egress: .none).policyHash), operation: .generate()))
        == .unsupportedCapability)
    #expect(
      failure(
        f.call(
          .maintenance(
            child.qualified, expectedGeneration: child.generation,
            .resize(cpus: 4, memoryMiB: nil, diskGiB: nil)), operation: .generate()))
        == .unsupportedCapability)
    let retention = try #require(state.retentionDeadline)
    // Time passes before recovery: a recomputed deadline would differ.
    f.clock.advance(.seconds(120))
    let recover = try f.receipt(.runResultsRecover(run: run, expectedGeneration: state.generation))
    // The allowance is durable at admission.
    #expect(try inspect(f, run).recoveryUsed)
    f.supervisor.runPending()
    #expect(try f.operation(recover.operationID).state == .succeeded)
    state = try inspect(f, run)
    #expect(state.phase == .resultsPending)
    #expect(state.retentionDeadline == retention)
    #expect(f.native.calls("start") == 2)
    // Retention expiry deletes exactly the owned resources.
    f.clock.advance(.seconds(3_480))
    f.supervisor.reconcileRun(run)
    state = try inspect(f, run)
    #expect(state.phase == .destroyed)
    #expect(state.disposition == "retention_expired")
  }

  @Test func recoveryIsRefusedForOpenEgressAndAfterUse() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let open = try create(f, egress: .open)
    f.clock.advance(.seconds(61))
    f.supervisor.reconcileRun(open)
    let state = try inspect(f, open)
    #expect(
      failure(
        f.call(
          .runResultsRecover(run: open, expectedGeneration: state.generation),
          operation: .generate()))
        == .unsupportedCapability)
    let discard = try f.receipt(.runResultsDiscard(run: open, expectedGeneration: state.generation))
    f.supervisor.runPending()
    #expect(try f.operation(discard.operationID).state == .succeeded)
    #expect(try inspect(f, open).disposition == "discarded")

    let hostOnly = try create(f)
    f.native.set { $0.results = Array("not a tar archive".utf8) }
    f.clock.advance(.seconds(61))
    f.supervisor.reconcileRun(hostOnly)
    var current = try inspect(f, hostOnly)
    _ = try f.receipt(.runResultsRecover(run: hostOnly, expectedGeneration: current.generation))
    f.supervisor.runPending()
    current = try inspect(f, hostOnly)
    #expect(current.phase == .stoppedDiskPendingExport)
    #expect(current.disposition == "export_failed")
    #expect(
      failure(
        f.call(
          .runResultsRecover(run: hostOnly, expectedGeneration: current.generation),
          operation: .generate()))
        == .resultsUnavailable)
  }
}

/// A transport straight into an in-process supervisor (no sockets).
struct InProcessTransport: HostTransport {
  let supervisor: HostSupervisor
  let transport: HostTransportKind

  func exchange(_ frame: [UInt8]) throws(HostControlError) -> [UInt8] {
    let request: HostRequest
    do { request = try HostRequest.decode(frame: Array(frame.dropLast())) } catch {
      throw .invalidRequest("undecodable")
    }
    return Array(supervisor.handle(request, transport: transport).frame.dropLast())
  }
}

@Suite struct RemoteRunClientTests {
  @Test func resultsAreVerifiedStagedThenAcknowledged() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let client = HostControlClient(
      transport: InProcessTransport(supervisor: f.supervisor, transport: .ssh),
      expected: (f.hostID, f.owner))
    let run = RunID.generate()
    _ = try client.call(
      .runCreate(
        run: run, spec: try f.spec(name: "run", egress: .none), outputLimitBytes: 1 << 20,
        ttlSeconds: 600),
      operation: .generate())
    f.supervisor.runPending()
    var observation = try RunObservation(wire: client.call(.runInspect(run)))
    #expect(observation.runtimeID != nil)
    _ = try client.call(
      .runComplete(run: run, expectedGeneration: observation.generation, exitStatus: 0),
      operation: .generate())
    f.supervisor.runPending()
    observation = try RunObservation(wire: client.call(.runInspect(run)))
    let config = try testConfig(#""data_dir": "\#(f.root)/client""#)
    let stage = try RemoteRunResults.download(
      client, run: observation, config: config, host: f.hostID, limit: 1 << 20)
    let bytes = try Data(contentsOf: URL(fileURLWithPath: stage.path))
    #expect(HostWire.sha256(Array(bytes)) == observation.artifactDigest)
    var status = stat()
    #expect(lstat(stage.path, &status) == 0 && status.st_mode & 0o077 == 0)
    let ack = try client.call(
      .runResultsAck(
        run: run, expectedGeneration: observation.generation,
        digest: try #require(observation.artifactDigest), stage: stage.id),
      operation: .generate())
    _ = ack
    f.supervisor.runPending()
    #expect(try RunObservation(wire: client.call(.runInspect(run))).phase == .destroyed)
    // The client stage survives the worker's deletion.
    #expect(FileManager.default.fileExists(atPath: stage.path))
  }

  @Test func aTooLargeDownloadIsRefused() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let client = HostControlClient(
      transport: InProcessTransport(supervisor: f.supervisor, transport: .ssh),
      expected: (f.hostID, f.owner))
    let run = RunID.generate()
    _ = try client.call(
      .runCreate(
        run: run, spec: try f.spec(name: "run"), outputLimitBytes: 1 << 20, ttlSeconds: 600),
      operation: .generate())
    f.supervisor.runPending()
    var observation = try RunObservation(wire: client.call(.runInspect(run)))
    _ = try client.call(
      .runComplete(run: run, expectedGeneration: observation.generation, exitStatus: 0),
      operation: .generate())
    f.supervisor.runPending()
    observation = try RunObservation(wire: client.call(.runInspect(run)))
    let config = try testConfig(#""data_dir": "\#(f.root)/client""#)
    #expect(throws: HostControlError.self) {
      try RemoteRunResults.download(
        client, run: observation, config: config, host: f.hostID, limit: 16)
    }
  }
}
