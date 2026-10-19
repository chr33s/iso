import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore

// One reader for every audit rendering (docs/audit.md#reading): a typed
// selection, one bounded page at a fixed snapshot `H`, and summaries derived
// from the checkpoint plus the retained events through `H`.

// MARK: - Run summary

/// A reference to the stored event an observation came from.
package struct AuditEventRef: Codable, Sendable, Equatable {
  package let eventID: AuditEventID
  package let sequence: UInt64
  package let recordedAt: String

  init(_ event: AuditEvent) {
    eventID = event.eventID
    sequence = event.sequence
    recordedAt = event.recordedAt
  }

  enum CodingKeys: String, CodingKey {
    case sequence
    case eventID = "event_id"
    case recordedAt = "recorded_at"
  }
}

package enum AuditRelationship: String, Codable, Sendable {
  case invocation
  case linkedOperation = "linked_operation"
  case vmContext = "vm_context"
}

/// What the recorded evidence says about one invocation. Derived, never
/// written per event; retained in the checkpoint when its detail expires.
package struct AuditRunSummary: Codable, Sendable, Equatable {
  package struct Observed<Fact: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    package let fact: Fact
    package let event: AuditEventRef
  }

  package struct Cleanup: Codable, Sendable, Equatable {
    package let sessionID: RunSessionID
    package let outcome: AuditFacts.CleanupOutcome
    package let relationship: AuditRelationship
    package let event: AuditEventRef

    enum CodingKeys: String, CodingKey {
      case outcome, relationship, event
      case sessionID = "session_id"
    }
  }

  package let auditRunID: AuditRunID
  package let startedAt: String
  package let request: Observed<AuditFacts.Request>
  @EncodedNull package var environment: Observed<AuditFacts.Environment>? = nil
  @EncodedNull package var preparationFailure: Observed<AuditFacts.PreparationFailure>? = nil
  @EncodedNull package var handoff: Observed<AuditFacts.Handoff>? = nil
  @EncodedNull package var transportEnded: Observed<AuditFacts.TransportEnded>? = nil
  @EncodedNull package var transportFailed: Observed<AuditFacts.TransportFailed>? = nil
  package var cleanup: [Cleanup] = []
  package var lastSequence: UInt64
  package var lastRecordedAt: String

  enum CodingKeys: String, CodingKey {
    case request, environment, handoff, cleanup
    case auditRunID = "audit_run_id"
    case startedAt = "started_at"
    case preparationFailure = "preparation_failure"
    case transportEnded = "transport_ended"
    case transportFailed = "transport_failed"
    case lastSequence = "last_sequence"
    case lastRecordedAt = "last_recorded_at"
  }

  /// Listing order: newest start first, by the immutable
  /// `(started_at, audit_run_id)` key.
  package static func newestFirst(_ a: Self, _ b: Self) -> Bool {
    a.startedAt != b.startedAt ? a.startedAt > b.startedAt : a.auditRunID > b.auditRunID
  }

  package var instanceName: String? {
    environment?.fact.instanceName ?? request.fact.requestedInstance
  }

  /// The exact boot this run's VM context joins; nil without one.
  package var boot: (vm: HexID, boot: HexID)? {
    guard let fact = environment?.fact, let vm = fact.vmID, let boot = fact.bootID else {
      return nil
    }
    return (vm, boot)
  }

  package var sessions: Set<RunSessionID> {
    var ids = Set(cleanup.map(\.sessionID))
    if let session = environment?.fact.disposableSessionID { ids.insert(session) }
    return ids
  }

  /// Folds in one more event of this run.
  mutating func observed(_ event: AuditEvent) {
    lastSequence = event.sequence
    lastRecordedAt = event.recordedAt
  }

  /// What was observed last, never more: a missing terminal record is
  /// reported as such, not as an interruption.
  package var outcome: Outcome {
    if let ended = transportEnded { return .transportEnded(ended.fact.termination) }
    if let failed = transportFailed { return .transportFailed(failed.fact.reason) }
    if let failure = preparationFailure { return .preparationFailed(failure.fact.stage) }
    return .noTerminalOutcome
  }

  package enum Outcome: Equatable, Sendable, Encodable {
    case transportEnded(AuditFacts.Termination)
    case transportFailed(AuditFacts.TransportFailure)
    case preparationFailed(AuditFacts.Stage)
    case noTerminalOutcome

    enum CodingKeys: String, CodingKey { case kind, termination, reason, stage }

    package func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .transportEnded(let termination):
        try values.encode("transport_ended", forKey: .kind)
        try values.encode(termination, forKey: .termination)
      case .transportFailed(let reason):
        try values.encode("transport_failed", forKey: .kind)
        try values.encode(reason, forKey: .reason)
      case .preparationFailed(let stage):
        try values.encode("preparation_failed", forKey: .kind)
        try values.encode(stage, forKey: .stage)
      case .noTerminalOutcome:
        try values.encode("no_terminal_outcome", forKey: .kind)
      }
    }

    package var text: String {
      switch self {
      case .transportEnded(let termination): "transport \(termination.text)"
      case .transportFailed(let reason): "transport failed (\(reason.rawValue))"
      case .preparationFailed(let stage): "preparation failed (\(stage.rawValue))"
      case .noTerminalOutcome: "no terminal outcome recorded"
      }
    }
  }
}

/// A run summary as returned: the summary plus what the snapshot says about
/// it (derived outcome, whether its opening detail is still retained).
package struct AuditRunView: Encodable, Sendable, Equatable {
  package let summary: AuditRunSummary
  package let openerRetained: Bool

  enum CodingKeys: String, CodingKey {
    case outcome
    case openerRetained = "opener_retained"
  }

  package func encode(to encoder: any Encoder) throws {
    try summary.encode(to: encoder)
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(summary.outcome, forKey: .outcome)
    try values.encode(openerRetained, forKey: .openerRetained)
  }
}

// MARK: - Reducer

/// Folds events into run summaries. Checkpoint creation and every read use
/// this one fold, so a summary is the same whichever prefix it came from.
struct AuditReducer {
  var runs: [AuditRunID: AuditRunSummary] = [:]
  var sessions: [RunSessionID: AuditRunID] = [:]
  var recordedGaps: [AuditGap] = []

  init(checkpoint: AuditCheckpoint?) {
    for run in checkpoint?.runs ?? [] {
      runs[run.auditRunID] = run
      for session in run.sessions { sessions[session] = run.auditRunID }
    }
  }

  mutating func apply(_ event: AuditEvent) {
    let ref = AuditEventRef(event)
    switch (event.subject, event.data) {
    case (.invocation(let id), .requested(let request)):
      guard runs[id] == nil else { return }
      runs[id] = AuditRunSummary(
        auditRunID: id, startedAt: event.recordedAt, request: .init(fact: request, event: ref),
        lastSequence: event.sequence, lastRecordedAt: event.recordedAt)
    case (.invocation(let id), let data):
      guard var run = runs[id] else { return }
      switch data {
      case .environment(let fact):
        run.environment = .init(fact: fact, event: ref)
        if let session = fact.disposableSessionID { sessions[session] = id }
      case .preparationFailed(let fact): run.preparationFailure = .init(fact: fact, event: ref)
      case .handoff(let fact): run.handoff = .init(fact: fact, event: ref)
      case .transportEnded(let fact): run.transportEnded = .init(fact: fact, event: ref)
      case .transportFailed(let fact): run.transportFailed = .init(fact: fact, event: ref)
      case .cleanup(let fact):
        run.cleanup.append(
          .init(
            sessionID: fact.sessionID, outcome: fact.outcome, relationship: .invocation, event: ref)
        )
        sessions[fact.sessionID] = id
      case .requested, .recordingGap, .boundary: break
      }
      run.observed(event)
      runs[id] = run
    case (.runCleanup(let session), .cleanup(let fact)):
      guard let id = sessions[session], var run = runs[id] else { return }
      run.cleanup.append(
        .init(
          sessionID: fact.sessionID, outcome: fact.outcome, relationship: .linkedOperation,
          event: ref))
      run.observed(event)
      runs[id] = run
    case (.journal, .recordingGap(let gap)):
      recordedGaps.append(
        AuditGap(
          reason: gap.reason, afterSequence: gap.afterSequence, beforeSequence: event.sequence,
          since: gap.refusedSince, refusedCount: gap.refusedCount))
    default: break
    }
  }

  /// Which selected run an event belongs to, and how; nil when unrelated.
  /// Shared VM activity joins only through an exact known boot.
  static func relationship(_ event: AuditEvent, to run: AuditRunSummary) -> AuditRelationship? {
    switch event.subject {
    case .invocation(let id): id == run.auditRunID ? .invocation : nil
    case .runCleanup(let session): run.sessions.contains(session) ? .linkedOperation : nil
    case .vm(let vm, let boot?):
      run.boot.map { $0.vm == vm && $0.boot == boot } == true ? .vmContext : nil
    case .vm(_, nil), .journal: nil
    }
  }
}

// MARK: - Selection and cursors

/// What a read selects. The legacy instance view stays on `BoundaryAudit`.
package enum AuditSelection: Sendable, Equatable {
  /// Run listing, optionally filtered by the recorded instance name;
  /// includes runs of deleted instances.
  case runs(instance: InstanceName?)
  case run(AuditRunID)

  package var json: OutputJSON {
    switch self {
    case .runs(let instance):
      .object([("type", .string("runs")), ("instance", .optional(instance?.rawValue))])
    case .run(let id): .object([("type", .string("run")), ("audit_run_id", .string(id.rawValue))])
    }
  }

  /// Binds a cursor to this selection and the query/event schemas.
  var digest: String {
    let text =
      "\(AuditStore.schema)|iso.audit.query/v1|" + json.compactRendered()
    return String(Self.hex(text).prefix(32))
  }

  static func hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// An opaque continuation token. A fixed cursor resumes one snapshot `H`;
/// a rolling cursor (follow only) continues after `H` with fresh snapshots.
package struct AuditCursor: Sendable, Equatable {
  package enum Kind: String, Codable, Sendable {
    case fixed = "f"
    case rolling = "r"
  }

  package enum Position: Sendable, Equatable {
    case sequence(UInt64)
    case run(startedAt: String, id: AuditRunID)
  }

  package let kind: Kind
  let selection: String
  let journalID: AuditJournalID
  let checkpointThrough: UInt64
  package let head: UInt64
  let position: Position
  /// The run's VM/session association at `H` (run detail only).
  let context: String?

  /// The last sequence a consumer of this cursor has seen.
  package var resumeSequence: UInt64 {
    if kind == .fixed, case .sequence(let sequence) = position { return sequence }
    return head
  }

  private struct Wire: Codable {
    let v: Int
    let k: Kind
    let s: String
    let j: AuditJournalID
    let b: UInt64
    let h: UInt64
    let p: UInt64?
    let t: String?
    let r: AuditRunID?
    let c: String?
  }

  package var token: String {
    var p: UInt64?
    var t: String?
    var r: AuditRunID?
    switch position {
    case .sequence(let sequence): p = sequence
    case .run(let startedAt, let id):
      t = startedAt
      r = id
    }
    let wire = Wire(
      v: 1, k: kind, s: selection, j: journalID, b: checkpointThrough, h: head, p: p, t: t, r: r,
      c: context)
    // Safe because `Wire` holds only strings, integers and validated ids,
    // which a synthesized encoder cannot fail to encode.
    let json = try! JSONOutput.render(wire, pretty: false)
    return "c1."
      + Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  package init(token: String) throws(AuditReadError) {
    guard token.utf8.count <= 4096, token.hasPrefix("c1.") else {
      throw .invalidCursor("not an iso audit cursor")
    }
    var base64 = token.dropFirst(3).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    guard let data = Data(base64Encoded: base64),
      let wire = try? JSONDecoder().decode(Wire.self, from: data), wire.v == 1
    else { throw .invalidCursor("not an iso audit cursor") }
    let position: Position
    switch (wire.p, wire.t, wire.r) {
    case (let p?, nil, nil): position = .sequence(p)
    case (nil, let t?, let r?): position = .run(startedAt: t, id: r)
    default: throw .invalidCursor("not an iso audit cursor")
    }
    self.init(
      kind: wire.k, selection: wire.s, journalID: wire.j, checkpointThrough: wire.b, head: wire.h,
      position: position, context: wire.c)
  }

  init(
    kind: Kind, selection: String, journalID: AuditJournalID, checkpointThrough: UInt64,
    head: UInt64, position: Position, context: String?
  ) {
    self.kind = kind
    self.selection = selection
    self.journalID = journalID
    self.checkpointThrough = checkpointThrough
    self.head = head
    self.position = position
    self.context = context
  }
}

// MARK: - Coverage

/// What the history can and cannot say; outcomes are reported separately.
package struct AuditCoverage: Encodable, Sendable, Equatable {
  package struct Source: Encodable, Sendable, Equatable {
    package enum Status: String, Encodable, Sendable {
      case enabled, unavailable, unsupported
    }

    package let source: String
    package let status: Status
  }

  /// Whether a run's VM context could be joined: only through a known boot.
  package enum VMContext: String, Encodable, Sendable {
    case joined, unavailable
  }

  package struct Retained: Encodable, Sendable, Equatable {
    @EncodedNull package var journalID: AuditJournalID?
    package var checkpointThrough: UInt64
    @EncodedNull package var checkpointThroughRecordedAt: String?
    @EncodedNull package var oldestSequence: UInt64?
    @EncodedNull package var oldestRecordedAt: String?
    package var newestSequence: UInt64
    package var expiredRuns: UInt64
    @EncodedNull package var expiredThrough: String?
    package var maxAgeSeconds: UInt64
    package var maxBytes: UInt64

    enum CodingKeys: String, CodingKey {
      case journalID = "journal_id"
      case checkpointThrough = "checkpoint_through"
      case checkpointThroughRecordedAt = "checkpoint_through_recorded_at"
      case oldestSequence = "oldest_sequence"
      case oldestRecordedAt = "oldest_recorded_at"
      case newestSequence = "newest_sequence"
      case expiredRuns = "expired_runs"
      case expiredThrough = "expired_through"
      case maxAgeSeconds = "max_age_seconds"
      case maxBytes = "max_bytes"
    }
  }

  package let sources: [Source]
  package let gaps: [AuditGap]
  package let retained: Retained
  /// Run detail only.
  @EncodedNull package private(set) var vmContext: VMContext?

  enum CodingKeys: String, CodingKey {
    case sources, gaps, retained
    case vmContext = "vm_context"
  }

  init(
    _ snapshot: AuditSnapshot, recorded: [AuditGap], retention: AuditRetention,
    run: AuditRunSummary?
  ) {
    let capture: Source.Status = snapshot.degraded == nil ? .enabled : .unavailable
    sources = [
      .init(source: "launch", status: capture), .init(source: "boundary", status: capture),
      .init(source: "agent_reports", status: .unsupported),
      .init(source: "network", status: .unsupported),
      .init(source: "remote", status: .unsupported),
    ]
    gaps = Array(
      ((snapshot.checkpoint?.gaps ?? []) + recorded + snapshot.health
        + (snapshot.degraded.map { [$0] } ?? [])).suffix(retention.maxRetainedGaps))
    retained = Retained(
      journalID: snapshot.journalID, checkpointThrough: snapshot.through,
      checkpointThroughRecordedAt: snapshot.checkpoint?.throughRecordedAt,
      oldestSequence: snapshot.events.first?.sequence,
      oldestRecordedAt: snapshot.events.first?.recordedAt, newestSequence: snapshot.head,
      expiredRuns: snapshot.checkpoint?.expiredRuns ?? 0,
      expiredThrough: snapshot.checkpoint?.expiredThrough,
      maxAgeSeconds: UInt64(retention.maxAge), maxBytes: UInt64(retention.maxBytes))
    vmContext = run.map { $0.boot == nil ? .unavailable : .joined }
  }
}

// MARK: - Pages

package struct AuditAsOf: Encodable, Sendable, Equatable {
  @EncodedNull package var journalID: AuditJournalID?
  package var sequence: UInt64

  enum CodingKeys: String, CodingKey {
    case sequence
    case journalID = "journal_id"
  }
}

package enum AuditItem: Sendable, Equatable, Encodable {
  case event(AuditRelationship, AuditEvent)
  case run(AuditRunView)

  enum CodingKeys: String, CodingKey { case relationship, event }

  package func encode(to encoder: any Encoder) throws {
    switch self {
    case .event(let relationship, let event):
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(relationship, forKey: .relationship)
      try values.encode(event, forKey: .event)
    case .run(let view): try view.encode(to: encoder)
    }
  }
}

/// One bounded page at one snapshot. `nextCursor` is nil exactly when the
/// selected snapshot is exhausted.
package struct AuditPage: Sendable {
  package let selection: AuditSelection
  package let asOf: AuditAsOf
  package let coverage: AuditCoverage
  /// Run detail only.
  package let run: AuditRunView?
  package let items: [AuditItem]
  package let nextCursor: AuditCursor?
  /// Where a follower continues once this snapshot is exhausted.
  package let rollingCursor: AuditCursor?

  package var exhausted: Bool { nextCursor == nil }
}

package struct AuditReader: Sendable {
  package static let defaultLimit = 100
  package static let maxLimit = 1000
  /// Serialized bytes of the items (and, for JSONL, control records) one
  /// page may carry; fewer items are returned to stay within it.
  package static let pageBytes = 1 << 20

  package let store: AuditStore

  package init(store: AuditStore) { self.store = store }

  package enum Mode: Sendable { case finite, follow }

  /// A snapshot folded once; every page of it is cut from memory.
  struct Folded {
    let snapshot: AuditSnapshot
    let reducer: AuditReducer
  }

  /// One bounded page. With no cursor it reads a fresh snapshot from the
  /// start; a fixed cursor continues its snapshot; a rolling cursor (follow)
  /// reads a fresh snapshot after its `H`.
  package func page(
    _ selection: AuditSelection, after cursor: AuditCursor?, limit: Int = defaultLimit,
    mode: Mode = .finite, byteBudget: Int = pageBytes
  ) throws(AuditReadError) -> AuditPage {
    try page(
      selection, after: cursor, limit: limit, byteBudget: byteBudget,
      in: try read(selection, after: cursor, mode: mode))
  }

  /// Every page of one snapshot, read and folded once; the first page
  /// continues `cursor`.
  package func pages(
    _ selection: AuditSelection, after cursor: AuditCursor? = nil, limit: Int = defaultLimit,
    mode: Mode = .finite, byteBudget: Int = pageBytes, _ body: (AuditPage) throws -> Void
  ) throws {
    let folded = try read(selection, after: cursor, mode: mode)
    var next = cursor
    repeat {
      let current = try page(
        selection, after: next, limit: limit, byteBudget: byteBudget, in: folded)
      try body(current)
      next = current.nextCursor
    } while next != nil
  }

  /// The live reader behind `--follow`, text and JSONL alike: drains each
  /// snapshot whose `H` advanced, then waits for the store to change.
  /// `snapshot` receives the first page of each such snapshot; `page` every
  /// page, the events in it not yet delivered, and where to continue. A
  /// passed-in cursor that predates a new association fails with
  /// `resetRequired`; once this follower has delivered records it re-reads
  /// from the start instead.
  package func follow(
    _ id: AuditRunID, after: AuditCursor?, limit: Int, byteBudget: Int = pageBytes,
    poll: Duration = .milliseconds(500), until stop: () -> Bool = { false },
    snapshot: (AuditPage) throws -> Void,
    page: (AuditPage, [(AuditRelationship, AuditEvent)], AuditCursor?) throws -> Void
  ) throws {
    let selection = AuditSelection.run(id)
    var cursor = after
    var lastHead: UInt64?
    var external = after != nil
    var delivered = Set<AuditEventID>()
    while !stop() {
      let fingerprint = store.fingerprint()
      do {
        let folded = try read(selection, after: cursor, mode: .follow)
        var first = true
        var exhausted = false
        while !exhausted {
          let current = try self.page(
            selection, after: cursor, limit: limit, byteBudget: byteBudget, in: folded)
          external = false
          if first {
            // An unchanged snapshot is an idle poll.
            if current.asOf.sequence == lastHead && cursor?.kind == .rolling { break }
            try snapshot(current)
            first = false
          }
          var fresh: [(AuditRelationship, AuditEvent)] = []
          for case .event(let relationship, let event) in current.items
          where delivered.insert(event.eventID).inserted {
            fresh.append((relationship, event))
          }
          exhausted = current.exhausted
          cursor = exhausted ? current.rollingCursor : current.nextCursor
          try page(current, fresh, cursor)
          if exhausted { lastHead = current.asOf.sequence }
        }
      } catch AuditReadError.resetRequired where !external {
        // Earlier records became relevant (the run's boot became known):
        // re-read from the start, delivering only what is new.
        cursor = nil
        continue
      }
      while !stop() && store.fingerprint() == fingerprint {
        Thread.sleep(forTimeInterval: poll / .seconds(1))
      }
    }
  }

  /// The snapshot `cursor` continues (a fresh one unless it is fixed),
  /// folded once, after checking that the cursor still applies to it.
  func read(_ selection: AuditSelection, after cursor: AuditCursor?, mode: Mode)
    throws(AuditReadError) -> Folded
  {
    if let cursor {
      guard cursor.selection == selection.digest else {
        throw .invalidCursor("it belongs to a different selection")
      }
      if cursor.kind == .rolling && mode == .finite {
        throw .invalidCursor("a follow cursor resumes only with --follow")
      }
    }
    let snapshot = try store.snapshot(through: cursor?.kind == .fixed ? cursor?.head : nil)
    if let cursor {
      let expired = AuditReadError.cursorExpired(snapshot.bounds)
      guard snapshot.journalID == cursor.journalID else { throw expired }
      switch cursor.kind {
      case .fixed:
        // A newer checkpoint cannot answer an older snapshot.
        guard snapshot.through == cursor.checkpointThrough, snapshot.head == cursor.head else {
          throw expired
        }
      case .rolling:
        guard snapshot.through <= cursor.head else { throw expired }
      }
    }
    var reducer = AuditReducer(checkpoint: snapshot.checkpoint)
    for event in snapshot.events { reducer.apply(event) }
    return Folded(snapshot: snapshot, reducer: reducer)
  }

  /// The page after `cursor` of a snapshot it was checked against.
  func page(
    _ selection: AuditSelection, after cursor: AuditCursor?, limit: Int, byteBudget: Int,
    in folded: Folded
  ) throws(AuditReadError) -> AuditPage {
    let snapshot = folded.snapshot
    let reducer = folded.reducer
    let asOf = AuditAsOf(journalID: snapshot.journalID, sequence: snapshot.head)
    func next(_ kind: AuditCursor.Kind, _ position: AuditCursor.Position, context: String?)
      -> AuditCursor?
    {
      snapshot.journalID.map {
        AuditCursor(
          kind: kind, selection: selection.digest, journalID: $0,
          checkpointThrough: snapshot.through, head: snapshot.head, position: position,
          context: context)
      }
    }
    func view(_ run: AuditRunSummary) -> AuditRunView {
      AuditRunView(summary: run, openerRetained: run.request.event.sequence > snapshot.through)
    }
    switch selection {
    case .runs(let instance):
      let candidates = reducer.runs.values.filter {
        instance == nil || $0.instanceName == instance?.rawValue
      }.sorted(by: AuditRunSummary.newestFirst)
      var start = candidates.startIndex
      if let cursor {
        guard case .run(let startedAt, let id) = cursor.position else {
          throw .invalidCursor("not a run-listing position")
        }
        start =
          candidates.firstIndex {
            $0.startedAt != startedAt ? $0.startedAt < startedAt : $0.auditRunID < id
          } ?? candidates.endIndex
      }
      let (taken, more) = try bounded(
        candidates[start...].map { AuditItem.run(view($0)) }, limit: limit,
        byteBudget: byteBudget)
      var nextCursor: AuditCursor?
      if more, case .run(let last)? = taken.last {
        nextCursor = next(
          .fixed, .run(startedAt: last.summary.startedAt, id: last.summary.auditRunID),
          context: nil)
      }
      return AuditPage(
        selection: selection, asOf: asOf,
        coverage: AuditCoverage(
          snapshot, recorded: reducer.recordedGaps, retention: store.retention, run: nil),
        run: nil, items: taken, nextCursor: nextCursor, rollingCursor: nil)
    case .run(let id):
      guard let run = reducer.runs[id] else { throw .runNotFound(id) }
      let context = Self.context(run)
      var after: UInt64 = 0
      if let cursor {
        guard case .sequence(let position) = cursor.position else {
          throw .invalidCursor("not a run-detail position")
        }
        after = cursor.kind == .fixed ? position : cursor.head
        // A new boot or session association can make records before `H`
        // relevant; skipping them silently would hide that context.
        if cursor.kind == .rolling, cursor.context != context,
          snapshot.events.contains(where: {
            $0.sequence <= cursor.head
              && AuditReducer.relationship($0, to: run).map { $0 != .invocation } == true
          })
        {
          throw .resetRequired
        }
      }
      let selected = snapshot.events.lazy.filter { $0.sequence > after }.compactMap {
        event in AuditReducer.relationship(event, to: run).map { AuditItem.event($0, event) }
      }
      let (taken, more) = try bounded(Array(selected), limit: limit, byteBudget: byteBudget)
      var nextCursor: AuditCursor?
      if more, case .event(_, let last)? = taken.last {
        nextCursor = next(.fixed, .sequence(last.sequence), context: context)
      }
      return AuditPage(
        selection: selection, asOf: asOf,
        coverage: AuditCoverage(
          snapshot, recorded: reducer.recordedGaps, retention: store.retention, run: run),
        run: view(run), items: taken, nextCursor: nextCursor,
        rollingCursor: next(.rolling, .sequence(snapshot.head), context: context))
    }
  }

  /// The run's VM and session association, bound into its cursors.
  package static func context(_ run: AuditRunSummary) -> String {
    let boot = run.boot.map { "\($0.vm.rawValue):\($0.boot.rawValue)" } ?? ""
    let sessions = run.sessions.map(\.rawValue).sorted()
    return String(
      AuditSelection.hex(boot + "|" + sessions.joined(separator: ",")).prefix(16))
  }

  /// At most `limit` items within `byteBudget`, and whether more remain.
  func bounded(_ items: [AuditItem], limit: Int, byteBudget: Int) throws(AuditReadError)
    -> ([AuditItem], Bool)
  {
    var taken: [AuditItem] = []
    var bytes = 0
    for item in items {
      guard taken.count < limit else { return (taken, true) }
      let size: Int
      do { size = try JSONOutput.render(item, pretty: false).utf8.count } catch {
        throw .unavailable(neutralizeControls("\(error)"))
      }
      guard size <= AuditJSONL.lineBytes else { throw .recordTooLarge }
      if !taken.isEmpty && bytes + size > byteBudget { return (taken, true) }
      bytes += size
      taken.append(item)
    }
    return (taken, false)
  }
}

/// The `iso.audit.stream/v1` line bound, shared with the page bound.
package enum AuditJSONL {
  package static let schema = "iso.audit.stream/v1"
  /// Every encoded line, including its newline and envelope.
  package static let lineBytes = 64 << 10
}
