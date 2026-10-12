import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

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
    ]
    for (label, bytes) in hostile {
      #expect(throws: HostControlError.self, "\(label)") {
        try ArchiveValidator.validate(bytes: Array(bytes))
      }
    }
    let ok = tarArchive(
      [("d/f", [1])], extra: [tarHeader(name: "d/l", size: 0, type: "2", link: "f")])
    #expect(try ArchiveValidator.validate(bytes: ok).members == 2)
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
    let cases: [(String, [UInt8])] = [
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
