import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

private func temporaryStore(_ retention: AuditRetention = .standard) -> AuditStore {
  AuditStore(
    root: FileManager.default.temporaryDirectory.appending(
      path: "iso-audit-store-\(UUID().uuidString)"
    ).path + "/audit/v1", retention: retention)
}

private func remove(_ store: AuditStore) {
  try? FileManager.default.removeItem(
    atPath: ((store.root as NSString).deletingLastPathComponent as NSString)
      .deletingLastPathComponent)
}

private func request(
  _ command: AuditFacts.Command = .run, lifecycle: AuditFacts.Lifecycle = .disposable,
  instance: String? = nil
) -> AuditFacts.Request {
  AuditFacts.Request(
    command: command, role: command == .claudeAgents ? .administrative : .managed,
    lifecycle: lifecycle, requestedAgent: "claude", requestedInstance: instance,
    permissionMode: .bypass, isoVersion: "iso test")
}

private let vmA = try! HexID(String(repeating: "a", count: 32))
private let vmB = try! HexID(String(repeating: "b", count: 32))
private let bootA = try! HexID(String(repeating: "1", count: 32))
private let bootA2 = try! HexID(String(repeating: "2", count: 32))

private func environment(
  _ name: String = "my-project", vm: HexID? = vmA, boot: HexID? = bootA,
  session: RunSessionID? = nil
) -> AuditFacts.Environment {
  AuditFacts.Environment(
    action: .created, instanceName: name, vmID: vm, bootID: boot, image: "default",
    guestOS: "linux", workspace: .copy, egress: .init(mode: "none", transport: "vmnet"),
    policy: .init(mode: "off", digest: nil), proxiedProviders: ["anthropic"],
    requested: .init(egress: "none", proxyMode: "required", sessionTTLSeconds: 3600),
    agent: nil, disposableSessionID: session)
}

private func boundary(_ vm: HexID, _ boot: HexID?, _ event: BoundaryAudit.Event = .stop)
  -> AuditRecord
{
  .boundary(vmID: vm, bootID: boot, instanceName: try! InstanceName("my-project"), event)
}

private func events(_ page: AuditPage) -> [(AuditRelationship, AuditEvent)] {
  page.items.compactMap {
    if case .event(let relationship, let event) = $0 { return (relationship, event) }
    return nil
  }
}

private func drain(_ reader: AuditReader, _ selection: AuditSelection, limit: Int) throws
  -> [AuditItem]
{
  var items: [AuditItem] = []
  var cursor: AuditCursor?
  repeat {
    let page = try reader.page(selection, after: cursor, limit: limit)
    items += page.items
    cursor = page.nextCursor
  } while cursor != nil
  return items
}

// MARK: - Recording

@Test func appendAssignsOrderAndIdentityAndStaysOwnerOnly() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  let first = try store.append(.requested(run, request()))
  let second = try store.append(.preparationFailed(run, .init(stage: .start)))
  #expect(first.sequence == 1 && second.sequence == 2)
  #expect(first.eventID != second.eventID && first.journalID == second.journalID)
  #expect(first.evidence == .hostRequest && second.evidence == .hostObservation)
  #expect(first.subject == .invocation(run) && first.producer == .iso)
  let snapshot = try store.snapshot()
  #expect(snapshot.events == [first, second] && snapshot.head == 2)
  for path in [
    store.root, store.root + "/journal.json", store.root + "/" + AuditStore.segmentName(1),
  ] {
    var info = stat()
    #expect(stat(path, &info) == 0)
    #expect(info.st_mode & 0o077 == 0, "\(path) is not owner-only")
  }
}

@Test func recordTooLargeIsRefusedAndConsumesNoSequence() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  let huge = AuditFacts.Handoff(
    transport: "ssh", pty: false,
    forwardedVariables: (0..<2000).map { "VARIABLE_NAME_\($0)" })
  #expect(throws: (any Error).self) { try store.append(.handoff(run, huge)) }
  let next = try store.append(.preparationFailed(run, .init(stage: .connect)))
  // Only the refusal's capture-degraded note sits between them.
  let kinds = try store.snapshot().events.map(\.kind)
  #expect(kinds == [.invocationRequested, .storeRecordingGap, .invocationPreparationFailed])
  #expect(next.sequence == 3)
}

@Test func tornTailIsNeverWrittenAfterAndItsSequenceIsSkipped() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  let segment = store.root + "/" + AuditStore.segmentName(1)
  let handle = try #require(FileHandle(forWritingAtPath: segment))
  handle.seekToEndOfFile()
  handle.write(Data(#"{"event_id":"evt_"#.utf8))
  handle.closeFile()
  let next = try store.append(.preparationFailed(run, .init(stage: .resolve)))
  #expect(next.sequence == 4)
  let snapshot = try store.snapshot()
  #expect(snapshot.events.map(\.sequence) == [1, 3, 4])
  #expect(snapshot.events[1].kind == .storeRecordingGap)
  #expect(snapshot.health.contains { $0.reason == .tornRecord && $0.afterSequence == 1 })
  // The torn segment is sealed: the new records went to a new one.
  #expect(FileManager.default.fileExists(atPath: store.root + "/" + AuditStore.segmentName(3)))
}

@Test func theTailOfALongSegmentIsFoundWithoutReadingAllOfIt() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let vm = try HexID(randomHex(16))
  var last: UInt64 = 0
  while true {
    last = try store.append(boundary(vm, nil)).sequence
    let size =
      try FileManager.default.attributesOfItem(
        atPath: store.root + "/" + AuditStore.segmentName(1))[.size] as? Int ?? 0
    if size > 2 * AuditStore.tailWindow { break }
  }
  #expect(try store.append(boundary(vm, nil)).sequence == last + 1)
  // Unparseable lines filling the whole window: the full read finds the tail.
  let segment = store.root + "/" + AuditStore.segmentName(1)
  let handle = try #require(FileHandle(forWritingAtPath: segment))
  handle.seekToEndOfFile()
  let filler = String(repeating: "x", count: 1000) + "\n"
  handle.write(Data(String(repeating: filler, count: AuditStore.tailWindow / 1000 + 2).utf8))
  handle.closeFile()
  let lost = UInt64(AuditStore.tailWindow / 1000 + 2)
  let next = try store.append(boundary(vm, nil))
  #expect(next.sequence == last + 1 + lost + 2)
}

@Test func degradedCaptureIsVisibleAndRecordedWhenCaptureResumes() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  store.noteRefused(Date(timeIntervalSince1970: 1_800_000_000))
  store.noteRefused(Date(timeIntervalSince1970: 1_800_000_100))
  let degraded = try #require(try store.snapshot().degraded)
  #expect(
    degraded.ongoing && degraded.refusedCount == 2 && degraded.since == "2027-01-15T08:00:00Z")
  let reader = AuditReader(store: store)
  let page = try reader.page(.run(run), after: nil)
  #expect(page.coverage.sources.first { $0.source == "launch" }?.status == .unavailable)
  try store.append(.preparationFailed(run, .init(stage: .connect)))
  let after = try store.snapshot()
  #expect(after.degraded == nil)
  let gap = try #require(after.events.first { $0.kind == .storeRecordingGap })
  #expect(gap.recordingGap?.refusedCount == 2)
}

@Test func unparseableAndOutOfOrderRecordsAreReportedNotBridged() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  let segment = store.root + "/" + AuditStore.segmentName(1)
  let original = try Data(contentsOf: URL(fileURLWithPath: segment))
  let handle = try #require(FileHandle(forWritingAtPath: segment))
  handle.seekToEndOfFile()
  handle.write(Data("not json\n".utf8))
  handle.closeFile()
  try store.append(.preparationFailed(run, .init(stage: .resolve)))
  let snapshot = try store.snapshot()
  #expect(snapshot.health.contains { $0.reason == .unparseableRecord })
  // A replayed lower sequence makes ordering untrustworthy: a terminal error.
  let replay = try Data(contentsOf: URL(fileURLWithPath: segment))
  try (replay + original).write(to: URL(fileURLWithPath: segment))
  #expect(throws: AuditReadError.self) { try store.snapshot() }
}

@Test func aPayloadThatDoesNotMatchItsKindIsUnparseable() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  let stored = try store.append(.requested(run, request()))
  // A well-formed event whose transport_ended data has no known termination.
  let forged = String(decoding: try stored.encoded(), as: UTF8.self)
    .replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":2")
    .replacingOccurrences(of: "invocation.requested", with: "launch.transport_ended")
  let handle = try #require(
    FileHandle(forWritingAtPath: store.root + "/" + AuditStore.segmentName(1)))
  handle.seekToEndOfFile()
  handle.write(Data((forged + "\n").utf8))
  handle.closeFile()
  let snapshot = try store.snapshot()
  #expect(snapshot.events.map(\.sequence) == [1])
  #expect(snapshot.health.contains { $0.reason == .unparseableRecord && $0.afterSequence == 1 })
  let summary = try #require(
    try AuditReader(store: store).page(.run(run), after: nil).run?.summary)
  #expect(summary.outcome == .noTerminalOutcome)
}

@Test func boundaryEventsReachTheStoreForInstancesInTheStateLayout() throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "iso-audit-layout-\(UUID().uuidString)"
  ).path
  defer { try? FileManager.default.removeItem(atPath: root) }
  let directory = root + "/instances/my-project"
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("my-project"), index: InstanceIndex(1)!, directory: directory,
    image: try ImageName("default"))
  // No VM identity yet: nothing can be attributed.
  BoundaryAudit.record(instance, .stop)
  let store = try #require(AuditStore.forInstance(instance))
  #expect(store.root == root + "/audit/v1")
  #expect(try store.snapshot().events.isEmpty)
  let binding = try PolicyBoot.begin(
    instance, configured: nil, diagnostics: Diagnostics(verbosity: 0))
  BoundaryAudit.record(instance, .pullStage(changes: 2, bytes: 9, applicable: true))
  let recorded = try store.snapshot().events
  #expect(recorded.map(\.kind) == [.boundaryPolicyBoot, .boundaryPullStage])
  let vm = try HexID(try #require(try PolicyInstanceIdentity.load(instance)))
  #expect(recorded.allSatisfy { $0.subject == .vm(vmID: vm, bootID: try? HexID(binding.bootID)) })
  guard case .boundary(let data) = recorded[1].data else {
    Issue.record("not a boundary payload")
    return
  }
  #expect(data["changes"] == .uint(2))
  #expect(data["instance_name"] == .string("my-project"))
  #expect(data["time"] == nil)
  // The legacy per-instance log is unchanged.
  #expect(try BoundaryAudit.lines(instance).count == 3)
  // Outside the layout (tests, foreign paths) nothing is attributed.
  let elsewhere = Instance(
    name: instance.name, index: instance.index, directory: root + "/other", image: instance.image)
  #expect(AuditStore.forInstance(elsewhere) == nil)
}

// MARK: - Reading

@Test func runSummaryDerivesOnlyWhatWasObserved() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  #expect(try reader.page(.run(run), after: nil).run?.summary.outcome == .noTerminalOutcome)
  try store.append(.environment(run, environment()))
  try store.append(.handoff(run, .init(transport: "ssh", pty: true, forwardedVariables: ["A"])))
  #expect(try reader.page(.run(run), after: nil).run?.summary.outcome == .noTerminalOutcome)
  try store.append(.transportEnded(run, .init(transport: "ssh", termination: .init(.signaled(9)))))
  let summary = try #require(try reader.page(.run(run), after: nil).run?.summary)
  #expect(summary.outcome == .transportEnded(.init(.signaled(9))))
  #expect(summary.outcome.text == "transport signaled 9")
  let other = AuditRunID.generate()
  try store.append(.requested(other, request()))
  try store.append(
    .transportEnded(other, .init(transport: "ssh", termination: .init(.exited(255)))))
  #expect(
    try reader.page(.run(other), after: nil).run?.summary.outcome.text == "transport exited 255")
  let failed = AuditRunID.generate()
  try store.append(.requested(failed, request()))
  try store.append(.preparationFailed(failed, .init(stage: .prepare)))
  #expect(
    try reader.page(.run(failed), after: nil).run?.summary.outcome == .preparationFailed(.prepare))
  #expect(
    throws: AuditReadError.runNotFound(
      AuditRunID(unchecked: "run_" + String(repeating: "0", count: 32)))
  ) {
    try reader.page(
      .run(AuditRunID(unchecked: "run_" + String(repeating: "0", count: 32))), after: nil)
  }
}

@Test func runsSharingAVMNeverAcquireEachOthersEvents() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let first = AuditRunID.generate()
  let second = AuditRunID.generate()
  try store.append(boundary(vmA, bootA, .pullDirect))
  try store.append(.requested(first, request(.claude, lifecycle: .existing)))
  try store.append(.environment(first, environment()))
  try store.append(.requested(second, request(.codex, lifecycle: .existing)))
  try store.append(.environment(second, environment()))
  try store.append(boundary(vmA, bootA))
  // Another boot of the same VM, another VM, and an unknown boot: none join.
  try store.append(boundary(vmA, bootA2))
  try store.append(boundary(vmB, bootA))
  try store.append(boundary(vmA, nil))
  let page = try reader.page(.run(first), after: nil)
  let selected = events(page)
  #expect(
    selected.allSatisfy { relationship, event in
      relationship == .invocation ? event.subject == .invocation(first) : true
    })
  #expect(selected.filter { $0.0 == .invocation }.count == 2)
  // The whole boot's context, before and after the invocation.
  #expect(
    selected.filter { $0.0 == .vmContext }.map(\.1.kind) == [.boundaryPullDirect, .boundaryStop])
  #expect(page.coverage.vmContext == .joined)
}

@Test func withoutAKnownBootTheVMContextIsOmittedAndSaidSo() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(boundary(vmA, bootA))
  try store.append(.requested(run, request()))
  try store.append(.environment(run, environment(boot: nil)))
  let page = try AuditReader(store: store).page(.run(run), after: nil)
  #expect(events(page).allSatisfy { $0.0 == .invocation })
  #expect(page.coverage.vmContext == .unavailable)
}

@Test func runCleanupIsALinkedOperationOfTheDisposableRun() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  let session = try RunSessionID(randomHex(16))
  let unrelated = try RunSessionID(randomHex(16))
  try store.append(.requested(run, request()))
  try store.append(.environment(run, environment(session: session)))
  try store.append(.cleanup(run, .init(sessionID: session, outcome: .deferred)))
  try store.append(.cleanupReconciled(.init(sessionID: unrelated, outcome: .destroyed)))
  try store.append(.cleanupReconciled(.init(sessionID: session, outcome: .destroyed)))
  let page = try AuditReader(store: store).page(.run(run), after: nil)
  #expect(events(page).map(\.0) == [.invocation, .invocation, .invocation, .linkedOperation])
  let cleanup = try #require(page.run?.summary.cleanup)
  #expect(cleanup.map(\.outcome) == [.deferred, .destroyed])
  #expect(cleanup.map(\.relationship) == [.invocation, .linkedOperation])
}

@Test func runListingIsNewestFirstFiltersByRecordedInstanceAndPages() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let reader = AuditReader(store: store)
  var ids: [AuditRunID] = []
  for index in 0..<5 {
    let run = AuditRunID.generate()
    ids.append(run)
    try store.append(
      .requested(run, request(instance: index % 2 == 0 ? "even" : "odd")),
      now: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
  }
  let all = try drain(reader, .runs(instance: nil), limit: 2)
  let listed = all.compactMap { item -> AuditRunID? in
    if case .run(let view) = item { return view.summary.auditRunID }
    return nil
  }
  #expect(listed == ids.reversed())
  let even = try reader.page(.runs(instance: try InstanceName("even")), after: nil)
  #expect(even.items.count == 3 && even.exhausted)
}

@Test func pagesStayAtOneSnapshotWhileRecordsArrive() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  for _ in 0..<4 { try store.append(boundary(vmA, bootA)) }
  try store.append(.environment(run, environment()))
  let first = try reader.page(.run(run), after: nil, limit: 2)
  #expect(first.items.count == 2 && !first.exhausted)
  let cursor = try #require(first.nextCursor)
  try store.append(boundary(vmA, bootA))
  try store.append(.preparationFailed(run, .init(stage: .connect)))
  var seen = events(first).map(\.1.sequence)
  var next: AuditCursor? = cursor
  while let current = next {
    let page = try reader.page(.run(run), after: try AuditCursor(token: current.token), limit: 2)
    #expect(page.asOf.sequence == first.asOf.sequence)
    seen += events(page).map(\.1.sequence)
    next = page.nextCursor
  }
  #expect(seen == [1, 2, 3, 4, 5, 6])
  // A fresh read sees the newer records.
  #expect(try drain(reader, .run(run), limit: 100).count == 8)
}

@Test func cursorsAreBoundToTheirSelectionAndMode() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  let other = AuditRunID.generate()
  try store.append(.requested(run, request()))
  try store.append(.requested(other, request()))
  try store.append(.environment(run, environment()))
  let page = try reader.page(.run(run), after: nil, limit: 1)
  let fixed = try #require(page.nextCursor)
  #expect(throws: AuditReadError.invalidCursor("it belongs to a different selection")) {
    try reader.page(.run(other), after: fixed)
  }
  let rolling = try #require(try reader.page(.run(run), after: nil).rollingCursor)
  #expect(throws: AuditReadError.invalidCursor("a follow cursor resumes only with --follow")) {
    try reader.page(.run(run), after: rolling)
  }
  #expect(throws: AuditReadError.self) { try AuditCursor(token: "c1.!!!") }
  #expect(throws: AuditReadError.self) { try AuditCursor(token: "garbage") }
  // A rolling cursor resumes after its snapshot, even when nothing matched.
  try store.append(boundary(vmB, bootA))
  let resumed = try reader.page(.run(run), after: rolling, mode: .follow)
  #expect(resumed.items.isEmpty && resumed.asOf.sequence == 4 && resumed.exhausted)
  #expect(resumed.rollingCursor?.head == 4)
}

@Test func aBootBecomingKnownRequiresAResetOfAResumedFollower() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  try store.append(boundary(vmA, bootA, .pullDirect))
  let rolling = try #require(try reader.page(.run(run), after: nil).rollingCursor)
  try store.append(.environment(run, environment()))
  #expect(throws: AuditReadError.resetRequired) {
    try reader.page(.run(run), after: rolling, mode: .follow)
  }
  // Without earlier context records, a new association needs no reset.
  let quiet = AuditRunID.generate()
  try store.append(.requested(quiet, request()))
  let before = try #require(try reader.page(.run(quiet), after: nil).rollingCursor)
  try store.append(.environment(quiet, environment(vm: vmB, boot: bootA2)))
  #expect(try reader.page(.run(quiet), after: before, mode: .follow).items.count == 1)
}

// MARK: - Retention

private let small: AuditRetention = {
  var retention = AuditRetention()
  retention.segmentBytes = 2048
  retention.maxBytes = 12_000
  retention.checkpointHeadroom = 4000
  return retention
}()

@Test func retentionRetiresSegmentsBehindACheckpointAndKeepsRunIdentity() throws {
  let store = temporaryStore(small)
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  try store.append(.requested(run, request(instance: "kept")))
  try store.append(.environment(run, environment("kept")))
  let early = try reader.page(.run(run), after: nil, limit: 1)
  let expiring = try #require(early.nextCursor)
  for _ in 0..<60 { try store.append(boundary(vmB, nil)) }
  let snapshot = try store.snapshot()
  #expect(snapshot.through > 2)
  #expect(snapshot.events.first.map { $0.sequence > snapshot.through } ?? true)
  var total = 0
  for segment in try store.listSegments() { total += segment.size }
  #expect(total <= small.maxBytes)
  // The opener is retired, its identity and exposure are not.
  let page = try reader.page(.run(run), after: nil)
  let view = try #require(page.run)
  #expect(!view.openerRetained)
  #expect(view.summary.environment?.fact.instanceName == "kept")
  #expect(view.summary.request.event.sequence == 1)
  #expect(page.coverage.retained.checkpointThrough == snapshot.through)
  // A cursor from before the checkpoint expires explicitly.
  #expect(throws: AuditReadError.self) { try reader.page(.run(run), after: expiring) }
  do {
    _ = try reader.page(.run(run), after: expiring)
  } catch .cursorExpired(let bounds) {
    #expect(bounds.checkpointThrough == snapshot.through)
  }
  let listed = try reader.page(.runs(instance: try InstanceName("kept")), after: nil)
  #expect(listed.items.count == 1)
}

@Test func aCrashBetweenCheckpointAndDeletionReplaysNothingTwice() throws {
  let store = temporaryStore(small)
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  try store.append(.environment(run, environment()))
  for _ in 0..<60 { try store.append(boundary(vmA, bootA)) }
  let snapshot = try store.snapshot()
  let checkpoint = try #require(snapshot.checkpoint)
  // Put a retired segment back, as if deletion never happened.
  let retired = store.root + "/" + AuditStore.segmentName(1)
  #expect(!FileManager.default.fileExists(atPath: retired))
  let line =
    String(
      decoding: try JSONOutput.render(
        AuditEvent(
          eventID: .generate(), journalID: checkpoint.journalID, sequence: 1,
          recordedAt: "2027-01-15T08:00:00Z", record: boundary(vmA, bootA)), pretty: false
      ).utf8, as: UTF8.self) + "\n"
  try line.write(toFile: retired, atomically: false, encoding: .utf8)
  let reread = try store.snapshot()
  #expect(reread.events.map(\.sequence) == snapshot.events.map(\.sequence))
  let page = try AuditReader(store: store).page(.run(run), after: nil)
  let ids = events(page).map(\.1.eventID)
  #expect(Set(ids).count == ids.count)
  #expect(page.run?.summary.environment != nil)
  // The next writer removes the redundant segment.
  try store.append(boundary(vmA, bootA))
  #expect(!FileManager.default.fileExists(atPath: retired))
}

@Test func oldRunsExpireWholeAndAreCounted() throws {
  var retention = small
  retention.maxAge = 24 * 3600
  let store = temporaryStore(retention)
  defer { remove(store) }
  let old = Date().addingTimeInterval(-2 * 24 * 3600)
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()), now: old)
  for _ in 0..<20 { try store.append(boundary(vmB, nil), now: old) }
  // Age the sealed segments, then append now.
  for segment in try store.listSegments() {
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: segment.path)
  }
  try store.append(boundary(vmB, nil))
  let checkpoint = try #require(try store.snapshot().checkpoint)
  #expect(checkpoint.runs.isEmpty && checkpoint.expiredRuns == 1)
  #expect(throws: AuditReadError.runNotFound(run)) {
    try AuditReader(store: store).page(.run(run), after: nil)
  }
}

// MARK: - Recorder

@Test func invocationRecorderNamesOnlyAndNeverFailsTheWorkload() throws {
  let store = temporaryStore()
  defer { remove(store) }
  var notices: [String] = []
  let invocation = AuditInvocation.begin(
    store: store, request: request(), diagnostics: Diagnostics(verbosity: 0),
    notice: { notices.append($0) })
  #expect(
    notices == ["Audit run \(invocation.runID); inspect with `iso audit --run \(invocation.runID)`"]
  )
  invocation.exclude(variables: ["DEFAULT_FLAG"])
  #expect(!invocation.launchObserved)
  var forward = EnvForward()
  forward.set("ANTHROPIC_API_KEY", Secret("sk-canary-secret-value"))
  forward.set("DEFAULT_FLAG", Secret("1"))
  invocation.handoff(pty: false, forwarded: forward.names)
  invocation.transportEnded(.exited(0))
  #expect(invocation.launchObserved)
  #expect(throws: HostError.self) {
    try invocation.during(.connect) { throw HostError("after handoff") }
  }
  let recorded = try store.snapshot().events
  #expect(
    recorded.map(\.kind) == [.invocationRequested, .launchHandoff, .launchTransportEnded])
  guard case .handoff(let handoff) = recorded[1].data else {
    Issue.record("not a handoff payload")
    return
  }
  #expect(handoff.forwardedVariables == ["ANTHROPIC_API_KEY"])
  for segment in try store.listSegments() {
    let text = String(decoding: try store.readSegment(segment.path), as: UTF8.self)
    #expect(!text.contains("sk-canary-secret-value"))
  }
  // An unwritable store warns once; the caller is not failed.
  let broken = AuditStore(root: "/dev/null/audit/v1")
  let messages = Mutex<[String]>([])
  let quiet = AuditInvocation.begin(
    store: broken, request: request(),
    diagnostics: Diagnostics(verbosity: 0, sink: { line in messages.withLock { $0.append(line) } }),
    notice: { notices.append($0) })
  quiet.preparationFailed(.resolve)
  #expect(notices.count == 1)
  #expect(messages.withLock { $0 }.count == 1)
}

@Test func failuresBeforeTheHandoffAreRecordedAtTheirStage() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let invocation = AuditInvocation.begin(
    store: store, request: request(), diagnostics: Diagnostics(verbosity: 0), notice: { _ in })
  #expect(throws: HostError.self) {
    try invocation.during(.connect) { throw HostError("no running instance") }
  }
  let summary = try #require(
    try AuditReader(store: store).page(.run(invocation.runID), after: nil).run?.summary)
  #expect(summary.outcome == .preparationFailed(.connect))
}

// MARK: - Essential checks (docs/audit.md)

@Test func aCheckpointThatCannotBePublishedKeepsHistoryAndDegradesCapture() throws {
  var retention = small
  retention.maxBytes = 6000
  // No checkpoint can ever fit: retirement must not delete anything.
  retention.checkpointHeadroom = 64
  let store = temporaryStore(retention)
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  try store.append(.environment(run, environment()))
  var appended: UInt64 = 2
  var refused = false
  for _ in 0..<100 {
    do {
      try store.append(boundary(vmA, bootA))
      appended += 1
    } catch {
      refused = true
      break
    }
  }
  #expect(refused)
  #expect(!FileManager.default.fileExists(atPath: store.checkpointPath))
  let snapshot = try store.snapshot()
  #expect(snapshot.through == 0 && snapshot.events.count == Int(appended))
  #expect(snapshot.events.first?.sequence == 1 && snapshot.head == appended)
  #expect(snapshot.degraded?.ongoing == true)
  let page = try AuditReader(store: store).page(.run(run), after: nil)
  #expect(page.run?.summary.environment != nil && page.run?.openerRetained == true)
  #expect(page.coverage.sources.allSatisfy { $0.status != .enabled })
}

@Test func partialCleanupFailedTransportsAndSignalsNeverBecomeSuccess() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  let session = try RunSessionID(randomHex(16))
  try store.append(.requested(run, request()))
  try store.append(.environment(run, environment(session: session)))
  try store.append(.handoff(run, .init(transport: "ssh", pty: false, forwardedVariables: [])))
  try store.append(.transportFailed(run, .init(transport: "ssh", reason: .sessionError)))
  try store.append(.cleanup(run, .init(sessionID: session, outcome: .deferred)))
  try store.append(.cleanupReconciled(.init(sessionID: session, outcome: .destroyFailed)))
  let summary = try #require(try reader.page(.run(run), after: nil).run?.summary)
  #expect(summary.outcome == .transportFailed(.sessionError))
  #expect(summary.outcome.text == "transport failed (session_error)")
  #expect(summary.cleanup.map(\.outcome) == [.deferred, .destroyFailed])
  #expect(!summary.cleanup.contains { $0.outcome == .destroyed })
  // An interrupt is the transport's signal, not a confirmed guest stop.
  let interrupted = AuditRunID.generate()
  try store.append(.requested(interrupted, request()))
  try store.append(
    .transportEnded(interrupted, .init(transport: "ssh", termination: .init(.signaled(SIGINT)))))
  let view = try #require(try reader.page(.run(interrupted), after: nil).run)
  #expect(view.summary.outcome.text == "transport signaled \(SIGINT)")
  #expect(
    try auditJSON(view.summary.outcome)
      == .object([
        ("kind", .string("transport_ended")),
        (
          "termination",
          .object([
            ("kind", .string("signaled")), ("signal", .int(Int64(SIGINT))), ("status", .null),
          ])
        ),
      ]))
}

@Test func secretCanariesNeverReachTheStore() throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "iso-audit-canary-\(UUID().uuidString)"
  ).path
  defer { try? FileManager.default.removeItem(atPath: root) }
  let directory = root + "/instances/my-project"
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("my-project"), index: InstanceIndex(1)!, directory: directory,
    image: try ImageName("default"))
  let canary = "sk-ant-canary-\(UUID().uuidString)"
  setenv("ANTHROPIC_API_KEY", canary, 1)
  defer { unsetenv("ANTHROPIC_API_KEY") }
  try PolicyBoot.begin(instance, configured: nil, diagnostics: Diagnostics(verbosity: 0))
  BoundaryAudit.record(
    instance,
    .boot(
      egress: .open, proxyMode: .auto, proxied: [.anthropic],
      providerSecrets: ["ANTHROPIC_API_KEY"], guestReferences: 1, sessionTTL: nil))
  BoundaryAudit.record(instance, .rawProviderForward(["ANTHROPIC_API_KEY"]))
  let store = try #require(AuditStore.forInstance(instance))
  let invocation = AuditInvocation.begin(
    store: store, request: request(), diagnostics: Diagnostics(verbosity: 0), notice: { _ in })
  var forward = EnvForward()
  forward.set("ANTHROPIC_API_KEY", Secret(canary))
  forward.set("GITHUB_TOKEN", Secret(canary + "-gh"))
  invocation.handoff(pty: true, forwarded: forward.names)
  invocation.transportEnded(.exited(0))
  #expect(try store.snapshot().events.count == 6)
  for name in try FileManager.default.contentsOfDirectory(atPath: store.root) {
    let path = store.root + "/" + name
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { continue }
    let text = String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    #expect(!text.contains(canary), "\(name) holds a secret value")
  }
}

@Test func cursorsExpireWhenTheJournalIsReplacedOrRetentionPassesAFollower() throws {
  let store = temporaryStore(small)
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  try store.append(.environment(run, environment()))
  let rolling = try #require(try reader.page(.run(run), after: nil).rollingCursor)
  for _ in 0..<60 { try store.append(boundary(vmB, nil)) }
  #expect(try store.snapshot().through > rolling.head)
  #expect(throws: AuditReadError.self) {
    try reader.page(.run(run), after: rolling, mode: .follow)
  }
  // A replaced journal expires every cursor of the old one.
  let fresh = temporaryStore()
  defer { remove(fresh) }
  try fresh.append(.requested(run, request()))
  let old = try #require(try AuditReader(store: fresh).page(.run(run), after: nil).rollingCursor)
  try FileManager.default.removeItem(atPath: fresh.root)
  try fresh.append(.requested(run, request()))
  do {
    _ = try AuditReader(store: fresh).page(.run(run), after: old, mode: .follow)
    Issue.record("a cursor of a replaced journal was accepted")
  } catch .cursorExpired {
  } catch {
    Issue.record("unexpected \(error)")
  }
}

@Test func missingJournalsSymlinksAndForeignCheckpointsAreRefused() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  // History without its journal record is never silently restarted.
  try FileManager.default.removeItem(atPath: store.journalPath)
  #expect(throws: (any Error).self) { try store.append(.requested(run, request())) }
  #expect(throws: AuditReadError.self) { try store.snapshot() }
  // A checkpoint of another journal is not trusted.
  let other = temporaryStore()
  defer { remove(other) }
  try other.append(.requested(run, request()))
  try StateStore.writeControlFile(
    AuditCheckpoint(
      schema: AuditCheckpoint.schema, journalID: .generate(), throughSequence: 0,
      throughRecordedAt: nil, createdAt: "2026-10-18T09:00:00Z", runs: [], gaps: [],
      expiredRuns: 0, expiredThrough: nil), to: other.checkpointPath)
  #expect(throws: AuditReadError.self) { try other.snapshot() }
  // A symlinked store directory is neither written nor read.
  let target = temporaryStore()
  defer { remove(target) }
  try target.append(.requested(run, request()))
  let linked = temporaryStore()
  defer { remove(linked) }
  try FileManager.default.createDirectory(
    atPath: (linked.root as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(atPath: linked.root, withDestinationPath: target.root)
  #expect(throws: (any Error).self) { try linked.append(.requested(run, request())) }
  #expect(throws: AuditReadError.self) { try linked.snapshot() }
  #expect(try target.snapshot().events.count == 1)
}

@Test func pagesEndEarlyAtTheByteBudgetAndListingsStayAtOneSnapshot() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  for _ in 0..<5 { try store.append(boundary(vmA, bootA)) }
  try store.append(.environment(run, environment()))
  let tight = try reader.page(.run(run), after: nil, limit: 100, byteBudget: 900)
  #expect(tight.items.count >= 1 && tight.items.count < 7 && tight.nextCursor != nil)
  for index in 0..<4 {
    try store.append(
      .requested(.generate(), request()),
      now: Date(timeIntervalSince1970: 1_900_000_000 + Double(index)))
  }
  let first = try reader.page(.runs(instance: nil), after: nil, limit: 2)
  // Newer runs recorded between pages do not shift the snapshot.
  try store.append(
    .requested(.generate(), request()), now: Date(timeIntervalSince1970: 2_000_000_000))
  var listed = first.items
  var cursor = first.nextCursor
  while let current = cursor {
    let page = try reader.page(.runs(instance: nil), after: current, limit: 2)
    #expect(page.asOf == first.asOf)
    listed += page.items
    cursor = page.nextCursor
  }
  #expect(listed.count == 5)
}

@Test func retentionCapsRetainedRunSummaries() throws {
  var retention = small
  retention.maxRetainedRuns = 2
  let store = temporaryStore(retention)
  defer { remove(store) }
  for index in 0..<4 {
    try store.append(
      .requested(.generate(), request()),
      now: Date(timeIntervalSince1970: 1_900_000_000 + Double(index)))
  }
  for _ in 0..<60 { try store.append(boundary(vmB, nil)) }
  let checkpoint = try #require(try store.snapshot().checkpoint)
  #expect(checkpoint.runs.count == 2 && checkpoint.expiredRuns == 2)
  #expect(checkpoint.runs.map(\.startedAt) == ["2030-03-17T17:46:43Z", "2030-03-17T17:46:42Z"])
}

@Test func aLongRunningRunKeepsItsSummaryWhileItHasRetainedEvents() throws {
  var retention = small
  retention.maxAge = 24 * 3600
  let store = temporaryStore(retention)
  defer { remove(store) }
  let old = Date().addingTimeInterval(-3 * 24 * 3600)
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()), now: old)
  try store.append(.environment(run, environment()), now: old)
  for _ in 0..<20 { try store.append(boundary(vmB, nil), now: old) }
  for segment in try store.listSegments() {
    try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: segment.path)
  }
  // Its transport ends today, after its opening detail aged out.
  try store.append(.transportEnded(run, .init(transport: "ssh", termination: .init(.exited(0)))))
  for _ in 0..<5 { try store.append(boundary(vmB, nil)) }
  let snapshot = try store.snapshot()
  #expect(snapshot.through > 2)
  let view = try #require(try AuditReader(store: store).page(.run(run), after: nil).run)
  #expect(!view.openerRetained)
  #expect(view.summary.outcome == .transportEnded(.init(.exited(0))))
  #expect(view.summary.environment?.fact.instanceName == "my-project")
}

@Test func aBusyStoreRefusesWithinItsBoundAndCountsTheRefusal() throws {
  let store = temporaryStore()
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  let holder = try #require(try FileLock.bounded(path: store.lockPath, timeout: .seconds(1)))
  let started = ContinuousClock.now
  #expect(throws: HostError.self) {
    try store.append(.preparationFailed(run, .init(stage: .start)))
  }
  #expect(ContinuousClock.now - started < .seconds(5))
  #expect(try store.snapshot().degraded?.refusedCount == 1)
  holder.release()
  try store.append(.preparationFailed(run, .init(stage: .start)))
  let gap = try #require(try store.snapshot().events.first { $0.kind == .storeRecordingGap })
  #expect(gap.recordingGap?.refusedCount == 1)
  #expect(try store.snapshot().degraded == nil)
}

@Test func aRefusalIsCountedOnceWhenTheAppendAfterItsGapFails() throws {
  var retention = AuditRetention()
  // Every record gets its own segment.
  retention.segmentBytes = 200
  let store = temporaryStore(retention)
  defer { remove(store) }
  let run = AuditRunID.generate()
  try store.append(.requested(run, request()))
  store.noteRefused(Date())
  // The gap (2) is written; the record after it (3) cannot be.
  let blocked = store.root + "/" + AuditStore.segmentName(3)
  try FileManager.default.createDirectory(atPath: blocked, withIntermediateDirectories: false)
  #expect(throws: (any Error).self) {
    try store.append(.preparationFailed(run, .init(stage: .connect)))
  }
  try FileManager.default.removeItem(atPath: blocked)
  try store.append(.preparationFailed(run, .init(stage: .connect)))
  let counts = try store.snapshot().events.compactMap {
    $0.recordingGap?.refusedCount
  }
  // One refusal before the failed append, one for it: never three.
  #expect(counts == [1, 1])
}

extension AuditEvent {
  fileprivate var recordingGap: AuditFacts.RecordingGap? {
    if case .recordingGap(let gap) = data { gap } else { nil }
  }
}
