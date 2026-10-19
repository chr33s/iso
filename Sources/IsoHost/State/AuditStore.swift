import Foundation
import IsoConfiguration
import IsoCore

/// The bounds `<stateRoot>/audit/v1` keeps (docs/audit.md#retention).
package struct AuditRetention: Sendable, Equatable {
  package var maxAge: TimeInterval = 7 * 24 * 3600
  /// Segments plus checkpoint.
  package var maxBytes = 128 << 20
  package var segmentBytes = 4 << 20
  /// Reserved inside `maxBytes` for replacing the checkpoint.
  package var checkpointHeadroom = 8 << 20
  package var maxRetainedRuns = 4096
  package var maxRetainedGaps = 64

  package static let standard = Self()
  package init() {}
}

/// Why a read could not answer. Never converted into successful exhaustion.
package enum AuditReadError: Error, Equatable, Sendable, CustomStringConvertible {
  case runNotFound(AuditRunID)
  case invalidCursor(String)
  /// Retention or a new journal overtook the cursor.
  case cursorExpired(AuditBounds)
  /// Older records became relevant to the selection (a boot became known).
  case resetRequired
  case recordTooLarge
  /// Unreadable or untrustworthy store state.
  case unavailable(String)

  package var description: String {
    switch self {
    case .runNotFound(let id): "No audit run \(id) is retained"
    case .invalidCursor(let why): "Invalid audit cursor: \(why)"
    case .cursorExpired:
      "The audit cursor expired (retention or a new journal overtook it); read again without --after"
    case .resetRequired:
      "Earlier audit records became relevant to this run; read again without --after"
    case .recordTooLarge: "An audit record exceeds the 64 KiB line bound"
    case .unavailable(let why): "Audit history is unavailable: \(why)"
    }
  }

  /// The `iso.audit.stream/v1` error code.
  package var code: String {
    switch self {
    case .runNotFound: "run_not_found"
    case .invalidCursor: "invalid_cursor"
    case .cursorExpired: "cursor_expired"
    case .resetRequired: "reset_required"
    case .recordTooLarge: "record_too_large"
    case .unavailable: "unavailable"
    }
  }

  package var bounds: AuditBounds? {
    if case .cursorExpired(let bounds) = self { bounds } else { nil }
  }
}

/// What is retained when a cursor expires or a read fails.
package struct AuditBounds: Codable, Sendable, Equatable {
  @EncodedNull package private(set) var journalID: AuditJournalID?
  package let checkpointThrough: UInt64
  @EncodedNull package private(set) var oldestSequence: UInt64?
  package let newestSequence: UInt64

  package init(
    journalID: AuditJournalID?, checkpointThrough: UInt64, oldestSequence: UInt64?,
    newestSequence: UInt64
  ) {
    self.journalID = journalID
    self.checkpointThrough = checkpointThrough
    self.oldestSequence = oldestSequence
    self.newestSequence = newestSequence
  }

  enum CodingKeys: String, CodingKey {
    case journalID = "journal_id"
    case checkpointThrough = "checkpoint_through"
    case oldestSequence = "oldest_sequence"
    case newestSequence = "newest_sequence"
  }
}

/// A visible limitation of the recorded history.
package struct AuditGap: Codable, Sendable, Equatable {
  package enum Reason: String, Codable, Sendable {
    /// A partially written record; its sequence number is never reused.
    case tornRecord = "torn_record"
    case unparseableRecord = "unparseable_record"
    case sequenceDiscontinuity = "sequence_discontinuity"
    /// Records were refused while the store could not accept them.
    case captureDegraded = "capture_degraded"
  }

  package let reason: Reason
  @EncodedNull package private(set) var afterSequence: UInt64?
  @EncodedNull package private(set) var beforeSequence: UInt64?
  @EncodedNull package private(set) var since: String?
  @EncodedNull package private(set) var refusedCount: UInt64?
  /// Still happening (capture is refused right now).
  package let ongoing: Bool

  package init(
    reason: Reason, afterSequence: UInt64? = nil, beforeSequence: UInt64? = nil,
    since: String? = nil, refusedCount: UInt64? = nil, ongoing: Bool = false
  ) {
    self.reason = reason
    self.afterSequence = afterSequence
    self.beforeSequence = beforeSequence
    self.since = since
    self.refusedCount = refusedCount
    self.ongoing = ongoing
  }

  enum CodingKeys: String, CodingKey {
    case reason, since, ongoing
    case afterSequence = "after_sequence"
    case beforeSequence = "before_sequence"
    case refusedCount = "refused_count"
  }
}

/// The reducer state through a retired segment boundary `B`.
package struct AuditCheckpoint: Codable, Sendable, Equatable {
  static let schema = "iso.audit.checkpoint/v1"

  let schema: String
  package let journalID: AuditJournalID
  package let throughSequence: UInt64
  package let throughRecordedAt: String?
  let createdAt: String
  package let runs: [AuditRunSummary]
  package let gaps: [AuditGap]
  /// Whole run summaries dropped by retention, and the newest one's start.
  package let expiredRuns: UInt64
  package let expiredThrough: String?

  enum CodingKeys: String, CodingKey {
    case schema, runs, gaps
    case journalID = "journal_id"
    case throughSequence = "through_sequence"
    case throughRecordedAt = "through_recorded_at"
    case createdAt = "created_at"
    case expiredRuns = "expired_runs"
    case expiredThrough = "expired_through"
  }
}

/// One consistent view: the checkpoint through `B`, then the retained
/// events with `B < sequence <= head`.
package struct AuditSnapshot: Sendable {
  package let journalID: AuditJournalID?
  package let checkpoint: AuditCheckpoint?
  package let head: UInt64
  package let events: [AuditEvent]
  /// Read-health findings in the retained range.
  package let health: [AuditGap]
  /// Capture is being refused right now.
  package let degraded: AuditGap?

  package var through: UInt64 { checkpoint?.throughSequence ?? 0 }

  package var bounds: AuditBounds {
    AuditBounds(
      journalID: journalID, checkpointThrough: through,
      oldestSequence: events.first?.sequence, newestSequence: head)
  }
}

/// `<stateRoot>/audit/v1`: one journal of bounded JSONL segments
/// (`seg-<first sequence>.jsonl`) and one checkpoint, outside instance
/// directories so history outlives the VM. Writers append under the store
/// lock; readers never take it. Owner-only, no-follow, bounded parsing.
package struct AuditStore: Sendable {
  package static let schema = "iso.audit/v1"

  package let root: String
  package let retention: AuditRetention

  package init(root: String, retention: AuditRetention = .standard) {
    self.root = root
    self.retention = retention
  }

  package init(config: IsoConfig) {
    self.init(root: config.stateRoot.appending("audit").appending("v1").path)
  }

  /// The store an instance's boundary events belong to, when the instance
  /// lives in the usual `<stateRoot>/instances/` layout.
  package static func forInstance(_ instance: Instance) -> AuditStore? {
    let parent = (instance.directory as NSString).deletingLastPathComponent
    guard (parent as NSString).lastPathComponent == "instances" else { return nil }
    return AuditStore(root: (parent as NSString).deletingLastPathComponent + "/audit/v1")
  }

  var journalPath: String { root + "/journal.json" }
  var checkpointPath: String { root + "/checkpoint.json" }
  var degradedPath: String { root + "/capture-degraded.json" }
  var lockPath: String { root + "/.lock" }
  var markerLockPath: String { root + "/.capture-degraded.lock" }

  static func segmentName(_ first: UInt64) -> String {
    "seg-" + String(repeating: "0", count: max(0, 20 - String(first).count)) + String(first)
      + ".jsonl"
  }

  struct JournalRecord: Codable {
    let schema: String
    let journalID: AuditJournalID
    let createdAt: String

    enum CodingKeys: String, CodingKey {
      case schema
      case journalID = "journal_id"
      case createdAt = "created_at"
    }
  }

  struct DegradedMarker: Codable {
    let since: String
    let refused: UInt64
  }

  struct Segment {
    let first: UInt64
    let path: String
    let size: Int
    let modified: Date
  }

  // MARK: - Writing

  /// Appends one record and returns the stored event. Callers treat a
  /// failure as non-fatal: audit never blocks the operation it describes.
  @discardableResult
  package func append(_ record: AuditRecord, now: Date = Date()) throws -> AuditEvent {
    // Neither the store nor its parent may be a symlink, even to chmod it.
    for path in [(root as NSString).deletingLastPathComponent, root] {
      _ = try Self.realDirectoryExists(path)
      try StateStore.ensurePrivateDirectory(path)
    }
    guard let lock = try FileLock.bounded(path: lockPath, timeout: Self.lockWait) else {
      noteRefused(now)
      throw HostError("audit store at \(root) is busy; this record was not kept")
    }
    defer { lock.release() }
    do {
      return try appendLocked(record, now: now)
    } catch {
      noteRefused(now)
      throw error
    }
  }

  func appendLocked(_ record: AuditRecord, now: Date) throws -> AuditEvent {
    let journal = try loadOrCreateJournal(now: now)
    var segments = try listSegments()
    if segmentBytes(segments) >= retention.maxBytes {
      try? maintain(journal: journal, now: now)
      segments = try listSegments()
      if segmentBytes(segments) >= retention.maxBytes {
        throw HostError("audit store at \(root) is full and could not retire history")
      }
    }
    let tail = try tailState(segments, journal: journal)
    var records: [AuditRecord] = []
    if tail.lost > 0 {
      records.append(.recordingGap(.init(reason: .tornRecord, afterSequence: tail.lastIntact)))
    }
    // The refusal marker is consumed under its own lock, which a writer
    // refused the store lock still takes to count its refusal.
    let markerLock = try FileLock.bounded(path: markerLockPath, timeout: Self.lockWait)
    defer { markerLock?.release() }
    var refused: (since: String?, count: UInt64?)?
    if markerLock != nil {
      // An unreadable marker still records a gap, of unknown extent.
      do { refused = try readDegraded().map { ($0.since, $0.refused) } } catch {
        refused = (nil, nil)
      }
    }
    var markerIndex: Int?
    if let refused {
      markerIndex = records.count
      records.append(
        .recordingGap(
          .init(
            reason: .captureDegraded, afterSequence: tail.next - 1, refusedSince: refused.since,
            refusedCount: refused.count)))
    }
    records.append(record)
    let recordedAt = utcTimestamp(now)
    let events = records.enumerated().map { offset, item in
      AuditEvent(
        eventID: .generate(), journalID: journal, sequence: tail.next + UInt64(offset),
        recordedAt: recordedAt, record: item)
    }
    let lines = try events.map { event in
      let bytes = try event.encoded() + [0x0A]
      guard bytes.count <= AuditEvent.maxEncodedBytes else {
        throw HostError("audit event \(event.kind.rawValue) exceeds 16 KiB; not recorded")
      }
      return bytes
    }
    // A torn tail seals its segment: the next record starts a new one.
    var target = tail.lost > 0 ? nil : segments.last.map { (path: $0.path, size: $0.size) }
    for (index, (event, line)) in zip(events, lines).enumerated() {
      var current = target ?? (path: root + "/" + Self.segmentName(event.sequence), size: 0)
      if current.size > 0 && current.size + line.count > retention.segmentBytes {
        current = (path: root + "/" + Self.segmentName(event.sequence), size: 0)
      }
      try appendLine(line, to: current.path)
      target = (current.path, current.size + line.count)
      // Once its gap is written the marker's count is recorded; a later
      // failure in this append starts a new count instead of repeating it.
      if index == markerIndex { try? StateStore.removeIfPresent(degradedPath) }
    }
    markerLock?.release()
    try? maintain(journal: journal, now: now)
    guard let stored = events.last else { throw HostError("audit append produced no event") }
    return stored
  }

  func appendLine(_ bytes: [UInt8], to path: String) throws {
    guard let fd = try openRegularFile(path, O_WRONLY | O_CREAT | O_APPEND) else {
      throw HostError.posix("Failed to open", path, ENOENT)
    }
    defer { close(fd) }
    // One write per record, so a reader sees whole lines or a torn tail.
    try AtomicFile.writeAll(fd, bytes, path)
  }

  /// How long a writer waits for another; recording never stalls the
  /// operation it describes for longer.
  static let lockWait = Duration.seconds(2)

  /// False when `path` is absent; throws unless it is a real directory.
  static func realDirectoryExists(_ path: String) throws -> Bool {
    var status = stat()
    if lstat(path, &status) != 0 {
      guard errno == ENOENT else { throw HostError.posix("Failed to inspect", path) }
      return false
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
      throw HostError("\(path) must be a real directory")
    }
    return true
  }

  func loadOrCreateJournal(now: Date) throws -> AuditJournalID {
    if let bytes = try StateStore.readControlFile(journalPath) {
      let record = try StateStore.decode(JournalRecord.self, bytes, path: journalPath)
      guard record.schema == Self.schema else {
        throw HostError("\(journalPath) is not an \(Self.schema) journal")
      }
      return record.journalID
    }
    // Existing history without its journal record is not silently restarted.
    guard try listSegments().isEmpty,
      try StateStore.readControlFile(checkpointPath) == nil
    else { throw HostError("\(journalPath) is missing but audit history exists") }
    let journal = AuditJournalID.generate()
    try StateStore.writeControlFile(
      JournalRecord(schema: Self.schema, journalID: journal, createdAt: utcTimestamp(now)),
      to: journalPath)
    return journal
  }

  /// Where the next record goes. A torn or unreadable tail of the active
  /// segment is never written after, and its sequence numbers are skipped.
  struct Tail {
    let next: UInt64
    let lastIntact: UInt64?
    let lost: UInt64
  }

  /// Bytes from the end of the active segment that usually hold its last
  /// intact record; the whole segment is read only when they do not.
  static let tailWindow = 4 * AuditEvent.maxEncodedBytes

  func tailState(_ segments: [Segment], journal: AuditJournalID) throws -> Tail {
    guard let last = segments.last else {
      let through = try readCheckpoint(expecting: journal)?.throughSequence ?? 0
      return Tail(next: through + 1, lastIntact: nil, lost: 0)
    }
    if last.size > Self.tailWindow,
      let tail = try lastIntact(last, journal: journal, from: last.size - Self.tailWindow)
    {
      return tail
    }
    return try lastIntact(last, journal: journal, from: 0)
      ?? Tail(next: last.first, lastIntact: nil, lost: 0)
  }

  /// The tail after the last intact record of `journal` at or after byte
  /// `offset`; nil when that range holds none (and `offset` is not 0).
  func lastIntact(_ segment: Segment, journal: AuditJournalID, from offset: Int) throws -> Tail? {
    var bytes = try readSegment(segment.path, from: offset)[...]
    if offset > 0 {
      // The window starts inside a record; that one is not the tail.
      guard let newline = bytes.firstIndex(of: 0x0A) else { return nil }
      bytes = bytes[(newline + 1)...]
    }
    guard !bytes.isEmpty else {
      return offset > 0 ? nil : Tail(next: segment.first, lastIntact: nil, lost: 0)
    }
    var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
    // `split` leaves an empty final piece after a trailing newline.
    var lost: UInt64 = lines.removeLast().isEmpty ? 0 : 1
    let decoder = JSONDecoder()
    for line in lines.reversed() {
      if let header = try? decoder.decode(Header.self, from: Data(line)),
        header.journalID == journal
      {
        return Tail(next: header.sequence + 1 + lost, lastIntact: header.sequence, lost: lost)
      }
      lost += 1
    }
    return offset > 0 ? nil : Tail(next: segment.first + lost, lastIntact: nil, lost: lost)
  }

  struct Header: Decodable {
    let sequence: UInt64
    let journalID: AuditJournalID
    enum CodingKeys: String, CodingKey {
      case sequence
      case journalID = "journal_id"
    }
  }

  /// Best effort: counts one refused record under the marker lock.
  func noteRefused(_ now: Date) {
    guard let lock = try? FileLock.bounded(path: markerLockPath, timeout: Self.lockWait) else {
      return
    }
    defer { lock.release() }
    let previous = try? readDegraded()
    let marker = DegradedMarker(
      since: previous?.since ?? utcTimestamp(now), refused: (previous?.refused ?? 0) + 1)
    try? StateStore.writeControlFile(marker, to: degradedPath)
  }

  func readDegraded() throws -> DegradedMarker? {
    guard let bytes = try StateStore.readControlFile(degradedPath) else { return nil }
    return try StateStore.decode(DegradedMarker.self, bytes, path: degradedPath)
  }

  func segmentBytes(_ segments: [Segment]) -> Int { segments.reduce(0) { $0 + $1.size } }

  // MARK: - Retention

  /// Retires the oldest sealed segments past the age or byte budget: build
  /// the checkpoint through their boundary, publish it atomically, and only
  /// then delete them. A crash in between leaves redundant segments that
  /// readers skip through `B`. Caller holds the store lock.
  func maintain(journal: AuditJournalID, now: Date) throws {
    let current = try readCheckpoint(expecting: journal)
    var segments = try listSegments()
    // Leftovers of an interrupted retirement: wholly covered by `B`.
    let through = current?.throughSequence ?? 0
    while segments.count > 1, segments[1].first <= through + 1 {
      try StateStore.removeIfPresent(segments[0].path)
      segments.removeFirst()
    }
    let checkpointSize = fileSize(checkpointPath)
    var total = segmentBytes(segments) + checkpointSize
    var retire = 0
    let cutoff = now.addingTimeInterval(-retention.maxAge)
    while retire < segments.count - 1,
      total > retention.maxBytes - retention.checkpointHeadroom
        || segments[retire].modified < cutoff
    {
      total -= segments[retire].size
      retire += 1
    }
    guard retire > 0 else { return }
    let boundary = segments[retire].first - 1
    // One read: the prefix through the boundary feeds the checkpoint, the
    // rest says which runs still have retained events.
    let retained = try snapshot(through: nil, journalCheck: journal, requireHead: false)
    let covered = retained.events.prefix { $0.sequence <= boundary }
    var reducer = AuditReducer(checkpoint: retained.checkpoint)
    for event in covered { reducer.apply(event) }
    // A run with events after the boundary keeps its summary whatever its
    // age: it expires only as a whole.
    var later = Set<AuditRunID>()
    for event in retained.events[covered.endIndex...] {
      switch event.subject {
      case .invocation(let id): later.insert(id)
      case .runCleanup(let session): if let id = reducer.sessions[session] { later.insert(id) }
      case .vm, .journal: break
      }
    }
    var expired: UInt64 = current?.expiredRuns ?? 0
    var expiredThrough = current?.expiredThrough
    var kept: [AuditRunSummary] = []
    let ordered = reducer.runs.values.sorted(by: AuditRunSummary.newestFirst)
    for run in ordered {
      let old = ((try? Date(run.lastRecordedAt, strategy: .iso8601)) ?? .distantPast) < cutoff
      if (old && !later.contains(run.auditRunID)) || kept.count >= retention.maxRetainedRuns {
        expired += 1
        expiredThrough = max(expiredThrough ?? run.startedAt, run.startedAt)
      } else {
        kept.append(run)
      }
    }
    let gaps = Array(
      ((current?.gaps ?? []) + retained.health.filter { ($0.afterSequence ?? 0) < boundary }
        + reducer.recordedGaps).suffix(
          retention.maxRetainedGaps))
    let checkpoint = AuditCheckpoint(
      schema: AuditCheckpoint.schema, journalID: journal, throughSequence: boundary,
      throughRecordedAt: covered.last?.recordedAt ?? current?.throughRecordedAt,
      createdAt: utcTimestamp(now), runs: kept, gaps: gaps, expiredRuns: expired,
      expiredThrough: expiredThrough)
    let bytes = try StateStore.encode(checkpoint, path: checkpointPath)
    guard bytes.count <= retention.checkpointHeadroom else {
      throw HostError("audit checkpoint would exceed its headroom; history kept")
    }
    try AtomicFile.write(bytes, to: checkpointPath, mode: .atMost(0o600))
    for segment in segments[..<retire] { try StateStore.removeIfPresent(segment.path) }
  }

  func fileSize(_ path: String) -> Int {
    var status = stat()
    return lstat(path, &status) == 0 ? Int(status.st_size) : 0
  }

  // MARK: - Reading

  func listSegments() throws -> [Segment] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: root)
    } catch {
      if !FileManager.default.fileExists(atPath: root) { return [] }
      throw HostError("Failed to list \(root)")
    }
    return names.compactMap { name -> Segment? in
      guard name.hasPrefix("seg-"), name.hasSuffix(".jsonl"),
        let first = UInt64(name.dropFirst(4).dropLast(6)), first > 0
      else { return nil }
      let path = root + "/" + name
      var status = stat()
      guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
      return Segment(
        first: first, path: path, size: Int(status.st_size),
        modified: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)))
    }.sorted { $0.first < $1.first }
  }

  /// The segment from byte `offset` to its end.
  func readSegment(_ path: String, from offset: Int = 0) throws -> [UInt8] {
    // Absent: retired by a concurrent writer after it was listed.
    guard let fd = try openRegularFile(path, O_RDONLY) else { throw SegmentVanished() }
    defer { close(fd) }
    guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else {
      throw HostError.posix("Failed to seek", path)
    }
    return try StateStore.readBounded(
      fd, path: path, limit: retention.segmentBytes + 2 * AuditEvent.maxEncodedBytes,
      tooLarge: "\(path) is larger than an audit segment")
  }

  func readCheckpoint(expecting journal: AuditJournalID?) throws -> AuditCheckpoint? {
    guard let fd = try openRegularFile(checkpointPath, O_RDONLY) else { return nil }
    defer { close(fd) }
    let bytes = try StateStore.readBounded(
      fd, path: checkpointPath, limit: retention.checkpointHeadroom,
      tooLarge: "\(checkpointPath) is too large")
    let checkpoint = try StateStore.decode(AuditCheckpoint.self, bytes, path: checkpointPath)
    guard checkpoint.schema == AuditCheckpoint.schema,
      journal == nil || checkpoint.journalID == journal
    else { throw HostError("\(checkpointPath) does not belong to this journal") }
    return checkpoint
  }

  /// The checkpoint and retained events through `limit` (the newest when
  /// nil). Lock-free: a segment retired mid-read is retried once from the
  /// newer checkpoint.
  package func snapshot(through limit: UInt64? = nil) throws(AuditReadError) -> AuditSnapshot {
    var retried = false
    while true {
      do {
        return try snapshot(through: limit, journalCheck: nil, requireHead: true)
      } catch let error as AuditReadError {
        throw error
      } catch is SegmentVanished where !retried {
        retried = true
      } catch {
        throw .unavailable(neutralizeControls("\(error)"))
      }
    }
  }

  struct SegmentVanished: Error, CustomStringConvertible {
    var description: String { "audit history changed during the read" }
  }

  /// `requireHead`: a `limit` past the retained records (a cursor from a
  /// replaced journal) is an expired cursor, not a shorter snapshot.
  func snapshot(through limit: UInt64?, journalCheck: AuditJournalID?, requireHead: Bool) throws
    -> AuditSnapshot
  {
    guard try Self.realDirectoryExists(root) else {
      return AuditSnapshot(
        journalID: nil, checkpoint: nil, head: 0, events: [], health: [], degraded: nil)
    }
    // Segments are listed before the journal and checkpoint are read: a
    // writer creates the journal first and publishes a checkpoint before
    // deleting what it covers, so a listed segment is either still readable,
    // covered by the checkpoint read after it, or vanishes (and is retried).
    let segments = try listSegments()
    var journal: AuditJournalID?
    if let bytes = try StateStore.readControlFile(journalPath) {
      journal = try StateStore.decode(JournalRecord.self, bytes, path: journalPath).journalID
    }
    if let journalCheck, journal != journalCheck {
      throw HostError("audit journal changed under its writer")
    }
    let checkpoint = try readCheckpoint(expecting: journal)
    guard let journal else {
      guard segments.isEmpty, checkpoint == nil else {
        throw AuditReadError.unavailable("\(journalPath) is missing but audit history exists")
      }
      return AuditSnapshot(
        journalID: nil, checkpoint: nil, head: 0, events: [], health: [],
        degraded: degradedGap())
    }
    let through = checkpoint?.throughSequence ?? 0
    let decoder = JSONDecoder()
    var events: [AuditEvent] = []
    var health: [AuditGap] = []
    var previous = through
    var reachedLimit = false
    for (index, segment) in segments.enumerated() {
      if index + 1 < segments.count, segments[index + 1].first <= through + 1 { continue }
      if let limit, segment.first > limit { break }
      let bytes = try readSegment(segment.path)
      var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
      let terminated = lines.last?.isEmpty ?? true
      lines.removeLast()
      for line in lines {
        guard line.count <= AuditEvent.maxEncodedBytes,
          let event = try? decoder.decode(AuditEvent.self, from: Data(line)),
          event.journalID == journal
        else {
          health.append(.init(reason: .unparseableRecord, afterSequence: previous))
          continue
        }
        if event.sequence <= through { continue }
        if let limit, event.sequence > limit {
          reachedLimit = true
          break
        }
        guard event.sequence > previous else {
          throw AuditReadError.unavailable(
            "audit sequence \(event.sequence) follows \(previous) out of order")
        }
        if event.sequence > previous + 1, health.last?.afterSequence != previous {
          health.append(
            .init(
              reason: .sequenceDiscontinuity, afterSequence: previous,
              beforeSequence: event.sequence))
        }
        events.append(event)
        previous = event.sequence
      }
      if reachedLimit { break }
      // The newest segment's unterminated tail is a write in progress.
      if !terminated && index + 1 < segments.count {
        health.append(.init(reason: .tornRecord, afterSequence: previous))
      }
    }
    if requireHead, let limit, previous < limit {
      throw AuditReadError.cursorExpired(
        AuditBounds(
          journalID: journal, checkpointThrough: through, oldestSequence: events.first?.sequence,
          newestSequence: previous))
    }
    return AuditSnapshot(
      journalID: journal, checkpoint: checkpoint, head: previous, events: events,
      health: health, degraded: degradedGap())
  }

  /// An unreadable marker still means capture was refused.
  func degradedGap() -> AuditGap? {
    let marker: DegradedMarker?
    do { marker = try readDegraded() } catch {
      return AuditGap(reason: .captureDegraded, ongoing: true)
    }
    guard let marker else { return nil }
    return AuditGap(
      reason: .captureDegraded, since: marker.since, refusedCount: marker.refused, ongoing: true)
  }

  /// Changes whenever an append or retirement does; cheap enough to poll.
  package func fingerprint() -> String {
    let segments = (try? listSegments()) ?? []
    let last = segments.last.map { "\($0.first):\($0.size)" } ?? "-"
    return "\(segments.count)/\(segments.first?.first ?? 0)/\(last)/\(fileSize(checkpointPath))"
  }
}
