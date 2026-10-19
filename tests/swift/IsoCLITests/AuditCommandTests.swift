import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Testing

@testable import IsoCLI

private final class Sink {
  var lines: [[UInt8]] = []
  var failAfter: Int?

  func emit(_ bytes: [UInt8]) throws {
    if let failAfter, lines.count >= failAfter { throw HostError("Broken pipe") }
    lines.append(bytes)
  }

  var records: [[String: Any]] {
    lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
  }

  var types: [String] { records.compactMap { $0["type"] as? String } }
}

private func scratch() -> String {
  let path = FileManager.default.temporaryDirectory.appending(
    path: "iso-audit-cli-\(UUID().uuidString)"
  ).path
  try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

private let vm = try! HexID(String(repeating: "a", count: 32))
private let boot = try! HexID(String(repeating: "1", count: 32))

/// A store with one run, its environment and `context` VM events of its boot.
private func populated(context: Int = 3) throws -> (AuditStore, AuditRunID, String) {
  let root = scratch()
  let store = AuditStore(root: root + "/audit/v1")
  let run = AuditRunID.generate()
  try store.append(
    .requested(
      run,
      .init(
        command: .run, role: .managed, lifecycle: .persistent, requestedAgent: "claude",
        requestedInstance: nil, permissionMode: .bypass, isoVersion: "iso test")))
  try store.append(
    .environment(
      run,
      .init(
        action: .attached, instanceName: "my-project", vmID: vm, bootID: boot, image: "default",
        guestOS: "linux", workspace: .copy, egress: nil, policy: nil, proxiedProviders: [],
        requested: .init(egress: "open", proxyMode: "auto", sessionTTLSeconds: nil), agent: nil,
        disposableSessionID: nil)))
  for _ in 0..<context { try store.append(stop(vm, boot)) }
  return (store, run, root)
}

private func stop(_ vm: HexID, _ boot: HexID?) -> AuditRecord {
  .boundary(vmID: vm, bootID: boot, instanceName: try! InstanceName("my-project"), .stop)
}

private func view(_ arguments: [String]) throws -> Audit.View {
  try Audit.parse(arguments).view()
}

// MARK: - Selection

@Test func auditSelectsExactlyOneViewAndMode() throws {
  let id = AuditRunID.generate().rawValue
  #expect(try view([]) == .instance(nil, suggestConfig: false))
  #expect(
    try view(["dev", "--suggest-config"]) == .instance(try InstanceName("dev"), suggestConfig: true)
  )
  #expect(try view(["--runs"]) == .runs(nil))
  #expect(try view(["dev", "--runs", "--output", "jsonl"]) == .runs(try InstanceName("dev")))
  #expect(try view(["--run", id]) == .run(try AuditRunID(id), .page))
  #expect(
    try view(["--run", id, "--follow", "--output", "jsonl"]) == .run(try AuditRunID(id), .follow))
  #expect(try view(["--run", id, "--follow"]) == .run(try AuditRunID(id), .follow))
  #expect(
    try view(["--run", id, "--export", "out.json"]) == .run(try AuditRunID(id), .export("out.json"))
  )
  for invalid in [
    ["--runs", "--run", id], ["--suggest-config", "--runs"], ["--follow"], ["--export", "x"],
    ["--run", id, "--follow", "--output", "json"], ["--run", id, "--export", "x", "--follow"],
    ["--run", id, "--export", "x", "--output", "jsonl"],
    ["--run", id, "--export", "x", "--limit", "5"],
    ["--runs", "--limit", "0"], ["--runs", "--limit", "1001"], ["dev", "--run", id],
    ["--after", "c1.x"], ["--output", "json"], ["--output", "jsonl"], ["--run", "run_short"],
  ] {
    #expect(throws: IsoCore.ValidationError.self, "\(invalid)") { try view(invalid) }
  }
}

@Test func jsonlIsOnlyForStreamCommands() {
  #expect(Audit.self is any StreamCommand.Type)
  for command: any ParsableCommand.Type in [List.self, Status.self, RunCommand.self, Logs.self] {
    #expect(!(command is any StreamCommand.Type))
  }
}

// MARK: - JSONL

@Test func finiteJSONLPagesAreIndependentBoundedLines() throws {
  let (store, run, root) = try populated()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let reader = AuditReader(store: store)
  var cursor: AuditCursor?
  var seen: [String] = []
  repeat {
    let sink = Sink()
    try AuditStreamWriter(emit: sink.emit).page(reader, .run(run), after: cursor, limit: 2)
    for line in sink.lines {
      #expect(line.last == 0x0A && line.count <= AuditJSONL.lineBytes)
      #expect(line.dropLast().allSatisfy { $0 != 0x0A })
    }
    let records = sink.records
    #expect(records.count == sink.lines.count)
    #expect(records.allSatisfy { $0["schema"] as? String == "iso.audit.stream/v1" })
    #expect(sink.types.first == "state" && sink.types.last == "progress")
    // Control records do not count toward the item limit.
    #expect(sink.types.filter { $0 == "event" }.count == min(2, 5 - seen.count))
    seen += records.compactMap { ($0["event"] as? [String: Any])?["event_id"] as? String }
    let progress = try #require(records.last)
    let token = progress["cursor"] as? String
    #expect((progress["snapshot_exhausted"] as? Bool) == (token == nil))
    cursor = try token.map { try AuditCursor(token: $0) }
  } while cursor != nil
  #expect(seen.count == 5 && Set(seen).count == 5)
}

@Test func finiteJSONAndJSONLSelectTheSameRecords() throws {
  let (store, run, root) = try populated()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let reader = AuditReader(store: store)
  let page = try reader.page(.run(run), after: nil, limit: 3)
  let document = try #require(
    try JSONSerialization.jsonObject(
      with: Data(JSONOutput.render(MachineAuditPage(page), pretty: false).utf8))
      as? [String: Any])
  let fromJSON = (document["events"] as? [[String: Any]] ?? []).compactMap {
    ($0["event"] as? [String: Any])?["event_id"] as? String
  }
  let sink = Sink()
  try AuditStreamWriter(emit: sink.emit).page(reader, .run(run), after: nil, limit: 3)
  let fromJSONL = sink.records.compactMap {
    ($0["event"] as? [String: Any])?["event_id"] as? String
  }
  #expect(fromJSON == fromJSONL && fromJSON.count == 3)
  #expect(document["next_cursor"] as? String == (sink.records.last?["cursor"] as? String))
  // Nullable members are present as null.
  let asOf = try #require(document["as_of"] as? [String: Any])
  #expect(asOf.keys.contains("journal_id"))
  let environment = try #require(
    (document["run"] as? [String: Any])?["environment"] as? [String: Any])
  #expect((environment["fact"] as? [String: Any])?["egress"] is NSNull)
}

@Test func followDrainsThenEmitsOnlyForAdvancedSnapshots() throws {
  let (store, run, root) = try populated(context: 0)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let sink = Sink()
  var ticks = 0
  try AuditStreamWriter(emit: sink.emit).follow(
    AuditReader(store: store), run, after: nil, limit: 1, poll: .milliseconds(1),
    until: {
      ticks += 1
      if ticks == 3 { try? store.append(stop(try! HexID(String(repeating: "b", count: 32)), nil)) }
      if ticks == 6 { try? store.append(stop(vm, boot)) }
      return ticks > 10
    })
  #expect(
    sink.types == [
      "state", "event", "progress", "event", "progress",
      // An unrelated record still advances the snapshot.
      "state", "progress",
      "state", "event", "progress",
    ])
  let progress = sink.records.filter { $0["type"] as? String == "progress" }
  #expect(progress.map { $0["snapshot_exhausted"] as? Bool } == [false, true, true, true])
  let last = try AuditCursor(token: try #require(progress.last?["cursor"] as? String))
  #expect(last.kind == .rolling && last.head == 4)
  // Resuming from the rolling cursor replays nothing.
  let resumed = try AuditReader(store: store).page(.run(run), after: last, mode: .follow)
  #expect(resumed.items.isEmpty)
}

@Test func aFailedWriteEndsTheStreamWithoutAnErrorRecord() throws {
  let (store, run, root) = try populated()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let sink = Sink()
  sink.failAfter = 2
  let writer = AuditStreamWriter(emit: sink.emit)
  #expect(throws: HostError.self) {
    try writer.page(AuditReader(store: store), .run(run), after: nil, limit: 10)
  }
  writer.fail(HostError("Broken pipe"))
  #expect(sink.types == ["state", "event"])
}

@Test func readFailuresAreTerminalErrorRecordsWithBounds() throws {
  let sink = Sink()
  let bounds = AuditBounds(
    journalID: .generate(), checkpointThrough: 40, oldestSequence: 41, newestSequence: 90)
  AuditStreamWriter(emit: sink.emit).fail(AuditReadError.cursorExpired(bounds))
  let record = try #require(sink.records.first)
  #expect(record["type"] as? String == "error" && record["code"] as? String == "cursor_expired")
  #expect((record["bounds"] as? [String: Any])?["checkpoint_through"] as? Int == 40)
  let other = Sink()
  AuditStreamWriter(emit: other.emit).fail(
    AuditReadError.runNotFound(AuditRunID.generate()))
  #expect(other.records.first?["code"] as? String == "run_not_found")
  #expect(MachineFailure(AuditReadError.resetRequired).code == .auditResetRequired)
  #expect(MachineFailure(AuditReadError.invalidCursor("x")).code == .invalidArgument)
}

// MARK: - Export

@Test func exportDrainsEveryPageIntoANewPrivateFile() throws {
  let (store, run, root) = try populated(context: 7)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/run-audit.json"
  let exported = try AuditExport.write(AuditReader(store: store), run, to: path, limit: 2)
  #expect(exported.events == 9 && exported.head == 9)
  let document = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
      as? [String: Any])
  #expect(document["schema"] as? String == "iso.audit/v1")
  #expect(document["snapshot_exhausted"] as? Bool == true)
  let ids = (document["events"] as? [[String: Any]] ?? []).compactMap {
    ($0["event"] as? [String: Any])?["event_id"] as? String
  }
  #expect(ids.count == 9 && Set(ids).count == 9)
  var info = stat()
  #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
  // Never overwrites, and leaves the existing file alone.
  let before = try Data(contentsOf: URL(fileURLWithPath: path))
  #expect(throws: HostError.self) {
    try AuditExport.write(AuditReader(store: store), run, to: path)
  }
  #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
}

@Test func aFailedExportPublishesNothing() throws {
  let (store, _, root) = try populated()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let directory = root + "/out"
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  #expect(throws: AuditReadError.self) {
    try AuditExport.write(
      AuditReader(store: store), AuditRunID.generate(), to: directory + "/x.json")
  }
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty)
}

// MARK: - Text

@Test func textNeverClaimsMoreThanWasObserved() throws {
  let (store, run, root) = try populated(context: 1)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let page = try AuditReader(store: store).page(.run(run), after: nil)
  let lines = AuditText.detail(page)
  #expect(lines.contains("  Outcome:     no terminal outcome recorded"))
  #expect(lines.contains { $0.contains("VM context") && $0.contains("boundary.stop") })
  #expect(
    lines.contains { $0.hasPrefix("Coverage:") && $0.contains("not observed: agent reports") })
  try store.append(.transportEnded(run, .init(transport: "ssh", termination: .init(.exited(0)))))
  let ended = AuditText.detail(try AuditReader(store: store).page(.run(run), after: nil))
  #expect(ended.contains("  Outcome:     transport exited 0"))
  let listing = AuditText.listing(
    try AuditReader(store: store).page(.runs(instance: nil), after: nil), instance: nil)
  #expect(listing.contains { $0.hasPrefix(run.rawValue) && $0.contains("run claude") })
  #expect(AuditText.details(.object([("name", .string("a\u{1b}[31m\nb"))])) == "  name=a?[31m?b")
}

@Test func anExportThatFailsAfterItsFirstPagePublishesNothing() throws {
  let (store, run, root) = try populated(context: 4)
  defer { try? FileManager.default.removeItem(atPath: root) }
  let directory = root + "/out"
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let reader = AuditReader(store: store)
  var pages = 0
  #expect(throws: AuditReadError.self) {
    try AuditExport.write(to: directory + "/x.json") { emit in
      try reader.pages(.run(run), limit: 2) { page in
        pages += 1
        // Retention overtook the snapshot between pages.
        if pages == 2 { throw AuditReadError.cursorExpired(try store.snapshot().bounds) }
        try emit(page)
      }
    }
  }
  #expect(pages == 2)
  #expect(try FileManager.default.contentsOfDirectory(atPath: directory).isEmpty)
}

@Test func theTextFollowerShowsEachEventOnceAndLateContext() throws {
  let root = scratch()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let store = AuditStore(root: root + "/audit/v1")
  let reader = AuditReader(store: store)
  let run = AuditRunID.generate()
  try store.append(
    .requested(
      run,
      .init(
        command: .claude, role: .managed, lifecycle: .existing, requestedAgent: "claude",
        requestedInstance: nil, permissionMode: .bypass, isoVersion: "iso test")))
  // Recorded before the run's boot is known.
  try store.append(stop(vm, boot))
  var out: [String] = []
  var ticks = 0
  try AuditText.follow(
    reader, run, after: nil, limit: 1, out: { out.append($0) }, poll: .milliseconds(1),
    until: {
      ticks += 1
      if ticks == 3 {
        try? store.append(
          .environment(
            run,
            .init(
              action: .attached, instanceName: "my-project", vmID: vm, bootID: boot,
              image: "default", guestOS: "linux", workspace: .copy, egress: nil, policy: nil,
              proxiedProviders: [],
              requested: .init(egress: "open", proxyMode: "auto", sessionTTLSeconds: nil),
              agent: nil, disposableSessionID: nil)))
      }
      return ticks > 6
    })
  let timeline = out.filter { $0.hasPrefix("  #") }
  #expect(timeline.count == 3)
  #expect(Set(timeline).count == timeline.count)
  // The earlier VM record joins once the boot is known.
  #expect(timeline.contains { $0.hasPrefix("  #2 ") && $0.contains("VM context") })
  // A resumed text view starts after its cursor.
  let resumeFrom = try #require(try reader.page(.run(run), after: nil, limit: 1).nextCursor)
  var resumed: [String] = []
  var stopAfter = 0
  try AuditText.follow(
    reader, run, after: resumeFrom, limit: 10, out: { resumed.append($0) }, poll: .milliseconds(1),
    until: {
      stopAfter += 1
      return stopAfter > 1
    })
  let resumedLines = resumed.filter { $0.hasPrefix("  #") }.map { String($0.prefix(5)) }
  #expect(resumedLines == ["  #2 ", "  #3 "])
}

@Test func exportNeverReplacesAFileCreatedDuringTheDrain() throws {
  let (store, run, root) = try populated()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/raced.json"
  let reader = AuditReader(store: store)
  #expect(throws: HostError.self) {
    try AuditExport.write(to: path) { emit in
      try reader.pages(.run(run)) { page in
        if !FileManager.default.fileExists(atPath: path) {
          try "theirs".write(toFile: path, atomically: false, encoding: .utf8)
        }
        try emit(page)
      }
    }
  }
  #expect(try String(contentsOfFile: path, encoding: .utf8) == "theirs")
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root).filter { $0.hasSuffix(".tmp") }
      .isEmpty)
}

@Test func aLiveFollowerCatchesUpWhenItsRunsBootBecomesKnown() throws {
  let root = scratch()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let store = AuditStore(root: root + "/audit/v1")
  let run = AuditRunID.generate()
  try store.append(
    .requested(
      run,
      .init(
        command: .run, role: .managed, lifecycle: .disposable, requestedAgent: "claude",
        requestedInstance: nil, permissionMode: .bypass, isoVersion: "iso test")))
  // The VM starts and records its boot before the run's environment.
  try store.append(stop(vm, boot))
  let sink = Sink()
  var ticks = 0
  try AuditStreamWriter(emit: sink.emit).follow(
    AuditReader(store: store), run, after: nil, limit: 10, poll: .milliseconds(1),
    until: {
      ticks += 1
      if ticks == 3 {
        try? store.append(
          .environment(
            run,
            .init(
              action: .created, instanceName: "my-project", vmID: vm, bootID: boot,
              image: "default", guestOS: "linux", workspace: .copy, egress: nil, policy: nil,
              proxiedProviders: [],
              requested: .init(egress: "open", proxyMode: "auto", sessionTTLSeconds: nil),
              agent: nil, disposableSessionID: nil)))
      }
      return ticks > 6
    })
  #expect(!sink.types.contains("error"))
  #expect(sink.types == ["state", "event", "progress", "state", "event", "event", "progress"])
  let events = sink.records.compactMap { $0["event"] as? [String: Any] }
  let ids = events.compactMap { $0["event_id"] as? String }
  #expect(ids.count == 3 && Set(ids).count == 3)
  // The boot's earlier record arrives with its relationship once known.
  #expect(
    sink.records.contains {
      $0["relationship"] as? String == "vm_context"
        && ($0["event"] as? [String: Any])?["sequence"] as? Int == 2
    })
}

@Test func jsonlIsRecognizedForGroupCommandsToo() {
  #expect(GlobalOptions.requests(.jsonl, ["iso", "secrets", "--output", "jsonl"]))
  #expect(GlobalOptions.requests(.jsonl, ["iso", "--output=jsonl", "github"]))
  #expect(!GlobalOptions.requests(.jsonl, ["iso", "exec", "--", "x", "--output", "jsonl"]))
  #expect(!GlobalOptions.requests(.jsonl, ["iso", "secrets", "--output", "json"]))
}
