import Foundation

/// The transactional controller database (spec section 5): allocations,
/// external-operation intents, pool/host state, approvals, GitHub App and
/// installation metadata, preflight runs/jobs and a bounded event log.
package final class ControllerStore: Sendable {
  package static let schemaVersion: Int64 = 1
  package static let maxEvents: Int64 = 50_000
  package static let maxEventMessageBytes = 512

  package let db: Database
  private let clock: any CIClock

  package init(database: Database, clock: any CIClock = SystemClock()) throws(CIError) {
    db = database
    self.clock = clock
    try migrate()
  }

  package static func open(root: DataRoot, clock: any CIClock = SystemClock()) throws(CIError)
    -> ControllerStore
  {
    try root.prepare()
    return try ControllerStore(database: try Database(path: root.database), clock: clock)
  }

  package static func inMemory(clock: any CIClock = SystemClock()) throws(CIError)
    -> ControllerStore
  {
    try ControllerStore(database: try Database(path: ":memory:"), clock: clock)
  }

  package var now: EpochSeconds { clock.now() }

  private func migrate() throws(CIError) {
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS allocations (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, pool TEXT, preflight_run TEXT, host TEXT NOT NULL,
        settled INTEGER NOT NULL, created_at INTEGER NOT NULL, record TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS allocations_pool ON allocations(pool, settled);
      CREATE INDEX IF NOT EXISTS allocations_host ON allocations(host, settled);
      CREATE TABLE IF NOT EXISTS intents (
        id TEXT PRIMARY KEY, allocation TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
        record TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS intents_allocation ON intents(allocation);
      CREATE TABLE IF NOT EXISTS pools (name TEXT PRIMARY KEY, record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS hosts (alias TEXT PRIMARY KEY, record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS approvals (
        kind TEXT NOT NULL, name TEXT NOT NULL, record TEXT NOT NULL, PRIMARY KEY (kind, name));
      CREATE TABLE IF NOT EXISTS github_apps (app_id INTEGER PRIMARY KEY, record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS installations (name TEXT PRIMARY KEY, record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS preflight_runs (
        id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS preflight_jobs (
        attempt TEXT PRIMARY KEY, run TEXT NOT NULL, job_key TEXT NOT NULL, record TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS preflight_jobs_run ON preflight_jobs(run);
      CREATE TABLE IF NOT EXISTS events (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, subject TEXT NOT NULL,
        kind TEXT NOT NULL, message TEXT NOT NULL, data TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS events_subject ON events(subject, seq);
      """)
    let rows = try db.query("SELECT value FROM meta WHERE key = 'schema'")
    if let raw = rows.first?.string("value") {
      guard Int64(raw) == Self.schemaVersion else {
        throw CIError.storage("controller database schema \(raw) is not supported by this build")
      }
    } else {
      try db.query(
        "INSERT INTO meta(key, value) VALUES ('schema', ?)", [.text(String(Self.schemaVersion))])
    }
  }

  // MARK: Coding

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  package static func encode<T: Encodable>(_ value: T) throws(CIError) -> String {
    do { return String(decoding: try encoder.encode(value), as: UTF8.self) } catch {
      throw CIError.storage("cannot encode a record")
    }
  }

  package static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws(CIError) -> T {
    do { return try JSONDecoder().decode(type, from: Data(text.utf8)) } catch {
      throw CIError.storage("a stored \(type) record is unreadable")
    }
  }

  // MARK: Controller identity

  package func controllerID() throws(CIError) -> ControllerID {
    try db.transaction { () throws(CIError) -> ControllerID in
      if let raw = try db.query("SELECT value FROM meta WHERE key = 'controller_id'").first?.string(
        "value")
      {
        return try ControllerID(raw)
      }
      let id = ControllerID.generate()
      try db.query("INSERT INTO meta(key, value) VALUES ('controller_id', ?)", [.text(id.rawValue)])
      return id
    }
  }

  package func meta(_ key: String) throws(CIError) -> String? {
    try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value")
  }

  package func setMeta(_ key: String, _ value: String?) throws(CIError) {
    if let value {
      try db.query(
        "INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        [.text(key), .text(value)])
    } else {
      try db.query("DELETE FROM meta WHERE key = ?", [.text(key)])
    }
  }

  // MARK: Allocations

  package func insert(_ record: AllocationRecord) throws(CIError) {
    try db.query(
      "INSERT INTO allocations(id, kind, pool, preflight_run, host, settled, created_at, record) VALUES (?,?,?,?,?,?,?,?)",
      [
        .text(record.id.rawValue), .text(record.kind.rawValue), .init(record.pool?.rawValue),
        .init(record.preflightRun?.rawValue), .text(record.host.rawValue),
        .init(record.isSettled), .init(record.createdAt), .text(try Self.encode(record)),
      ])
  }

  package func save(_ record: AllocationRecord) throws(CIError) {
    try db.query(
      "UPDATE allocations SET pool = ?, preflight_run = ?, host = ?, settled = ?, record = ? WHERE id = ?",
      [
        .init(record.pool?.rawValue), .init(record.preflightRun?.rawValue),
        .text(record.host.rawValue), .init(record.isSettled), .text(try Self.encode(record)),
        .text(record.id.rawValue),
      ])
    guard db.changes == 1 else { throw CIError(.notFound, "unknown allocation \(record.id)") }
  }

  package func allocation(_ id: AllocationID) throws(CIError) -> AllocationRecord? {
    guard
      let row = try db.query("SELECT record FROM allocations WHERE id = ?", [.text(id.rawValue)])
        .first
    else { return nil }
    return try Self.decode(AllocationRecord.self, try row.required("record"))
  }

  /// Unsettled allocations (optionally for one pool or host), oldest first.
  package func openAllocations(pool: Name? = nil, host: Name? = nil) throws(CIError)
    -> [AllocationRecord]
  {
    var sql = "SELECT record FROM allocations WHERE settled = 0"
    var bindings: [Database.Value] = []
    if let pool {
      sql += " AND pool = ?"
      bindings.append(.text(pool.rawValue))
    }
    if let host {
      sql += " AND host = ?"
      bindings.append(.text(host.rawValue))
    }
    sql += " ORDER BY created_at, id"
    return try decodeAll(try db.query(sql, bindings))
  }

  package func allocations(preflightRun: PreflightRunID) throws(CIError) -> [AllocationRecord] {
    try decodeAll(
      try db.query(
        "SELECT record FROM allocations WHERE preflight_run = ? ORDER BY created_at, id",
        [.text(preflightRun.rawValue)]))
  }

  /// Recent allocations (settled included), newest first.
  package func recentAllocations(limit: Int) throws(CIError) -> [AllocationRecord] {
    try decodeAll(
      try db.query(
        "SELECT record FROM allocations ORDER BY created_at DESC, id LIMIT ?", [.int(Int64(limit))])
    )
  }

  private func decodeAll(_ rows: [Database.Row]) throws(CIError) -> [AllocationRecord] {
    var out: [AllocationRecord] = []
    for row in rows {
      out.append(try Self.decode(AllocationRecord.self, try row.required("record")))
    }
    return out
  }

  /// Read-modify-write of one allocation inside a transaction.
  @discardableResult
  package func update(
    _ id: AllocationID, _ change: (inout AllocationRecord) throws(CIError) -> Void
  )
    throws(CIError) -> AllocationRecord
  {
    try db.transaction { () throws(CIError) -> AllocationRecord in
      guard var record = try allocation(id) else {
        throw CIError(.notFound, "unknown allocation \(id)")
      }
      try change(&record)
      try save(record)
      return record
    }
  }

  // MARK: Intents

  package func insert(_ intent: IntentRecord) throws(CIError) {
    try db.query(
      "INSERT INTO intents(id, allocation, kind, status, record) VALUES (?,?,?,?,?)",
      [
        .text(intent.id), .text(intent.allocation.rawValue), .text(intent.kind.rawValue),
        .text(intent.status.rawValue), .text(try Self.encode(intent)),
      ])
  }

  package func save(_ intent: IntentRecord) throws(CIError) {
    try db.query(
      "UPDATE intents SET status = ?, record = ? WHERE id = ?",
      [.text(intent.status.rawValue), .text(try Self.encode(intent)), .text(intent.id)])
  }

  package func intent(_ id: String) throws(CIError) -> IntentRecord? {
    guard let row = try db.query("SELECT record FROM intents WHERE id = ?", [.text(id)]).first
    else {
      return nil
    }
    return try Self.decode(IntentRecord.self, try row.required("record"))
  }

  package func intents(allocation: AllocationID) throws(CIError) -> [IntentRecord] {
    var out: [IntentRecord] = []
    for row in try db.query(
      "SELECT record FROM intents WHERE allocation = ? ORDER BY rowid", [.text(allocation.rawValue)]
    ) {
      out.append(try Self.decode(IntentRecord.self, try row.required("record")))
    }
    return out
  }

  // MARK: Pools, hosts, approvals

  package func poolStatus(_ name: Name) throws(CIError) -> PoolStatusRecord? {
    guard
      let row = try db.query("SELECT record FROM pools WHERE name = ?", [.text(name.rawValue)])
        .first
    else { return nil }
    return try Self.decode(PoolStatusRecord.self, try row.required("record"))
  }

  package func poolStatuses() throws(CIError) -> [PoolStatusRecord] {
    var out: [PoolStatusRecord] = []
    for row in try db.query("SELECT record FROM pools ORDER BY name") {
      out.append(try Self.decode(PoolStatusRecord.self, try row.required("record")))
    }
    return out
  }

  package func save(_ pool: PoolStatusRecord) throws(CIError) {
    try db.query(
      "INSERT INTO pools(name, record) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET record = excluded.record",
      [.text(pool.name.rawValue), .text(try Self.encode(pool))])
  }

  package func host(_ alias: Name) throws(CIError) -> HostRecord? {
    guard
      let row = try db.query("SELECT record FROM hosts WHERE alias = ?", [.text(alias.rawValue)])
        .first
    else { return nil }
    return try Self.decode(HostRecord.self, try row.required("record"))
  }

  package func hosts() throws(CIError) -> [HostRecord] {
    var out: [HostRecord] = []
    for row in try db.query("SELECT record FROM hosts ORDER BY alias") {
      out.append(try Self.decode(HostRecord.self, try row.required("record")))
    }
    return out
  }

  package func save(_ host: HostRecord) throws(CIError) {
    try db.query(
      "INSERT INTO hosts(alias, record) VALUES (?, ?) ON CONFLICT(alias) DO UPDATE SET record = excluded.record",
      [.text(host.alias.rawValue), .text(try Self.encode(host))])
  }

  package func approval(_ kind: ApprovalRecord.Kind, _ name: Name) throws(CIError)
    -> ApprovalRecord?
  {
    guard
      let row = try db.query(
        "SELECT record FROM approvals WHERE kind = ? AND name = ?",
        [.text(kind.rawValue), .text(name.rawValue)]
      ).first
    else { return nil }
    return try Self.decode(ApprovalRecord.self, try row.required("record"))
  }

  package func save(_ approval: ApprovalRecord) throws(CIError) {
    try db.query(
      "INSERT INTO approvals(kind, name, record) VALUES (?, ?, ?) ON CONFLICT(kind, name) DO UPDATE SET record = excluded.record",
      [
        .text(approval.kind.rawValue), .text(approval.name.rawValue),
        .text(try Self.encode(approval)),
      ])
  }

  // MARK: GitHub metadata (never secrets)

  package func save(_ app: GitHubAppRecord) throws(CIError) {
    try db.query(
      "INSERT INTO github_apps(app_id, record) VALUES (?, ?) ON CONFLICT(app_id) DO UPDATE SET record = excluded.record",
      [.int(app.appID), .text(try Self.encode(app))])
  }

  package func apps() throws(CIError) -> [GitHubAppRecord] {
    var out: [GitHubAppRecord] = []
    for row in try db.query("SELECT record FROM github_apps ORDER BY app_id") {
      out.append(try Self.decode(GitHubAppRecord.self, try row.required("record")))
    }
    return out
  }

  package func app(_ id: Int64) throws(CIError) -> GitHubAppRecord? {
    guard
      let row = try db.query("SELECT record FROM github_apps WHERE app_id = ?", [.int(id)]).first
    else { return nil }
    return try Self.decode(GitHubAppRecord.self, try row.required("record"))
  }

  package func removeApp(_ id: Int64) throws(CIError) {
    try db.query("DELETE FROM github_apps WHERE app_id = ?", [.int(id)])
  }

  package func save(_ installation: InstallationRecord) throws(CIError) {
    try db.query(
      "INSERT INTO installations(name, record) VALUES (?, ?) ON CONFLICT(name) DO UPDATE SET record = excluded.record",
      [.text(installation.name.rawValue), .text(try Self.encode(installation))])
  }

  package func installation(_ name: Name) throws(CIError) -> InstallationRecord? {
    guard
      let row = try db.query(
        "SELECT record FROM installations WHERE name = ?", [.text(name.rawValue)]
      )
      .first
    else { return nil }
    return try Self.decode(InstallationRecord.self, try row.required("record"))
  }

  package func installations() throws(CIError) -> [InstallationRecord] {
    var out: [InstallationRecord] = []
    for row in try db.query("SELECT record FROM installations ORDER BY name") {
      out.append(try Self.decode(InstallationRecord.self, try row.required("record")))
    }
    return out
  }

  package func removeInstallation(_ name: Name) throws(CIError) {
    try db.query("DELETE FROM installations WHERE name = ?", [.text(name.rawValue)])
  }

  // MARK: Preflight runs and jobs (opaque Codable records owned by Preflight)

  package func savePreflightRun<T: Encodable>(
    _ id: PreflightRunID, createdAt: EpochSeconds, _ record: T
  )
    throws(CIError)
  {
    try db.query(
      "INSERT INTO preflight_runs(id, created_at, record) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record",
      [.text(id.rawValue), .init(createdAt), .text(try Self.encode(record))])
  }

  package func preflightRun<T: Decodable>(_ id: PreflightRunID, as type: T.Type) throws(CIError)
    -> T?
  {
    guard
      let row = try db.query("SELECT record FROM preflight_runs WHERE id = ?", [.text(id.rawValue)])
        .first
    else { return nil }
    return try Self.decode(type, try row.required("record"))
  }

  package func preflightRunIDs(limit: Int) throws(CIError) -> [PreflightRunID] {
    var out: [PreflightRunID] = []
    for row in try db.query(
      "SELECT id FROM preflight_runs ORDER BY created_at DESC, id LIMIT ?", [.int(Int64(limit))])
    {
      out.append(try PreflightRunID(try row.required("id")))
    }
    return out
  }

  package func savePreflightJob<T: Encodable>(
    attempt: JobAttemptID, run: PreflightRunID, jobKey: String, _ record: T
  ) throws(CIError) {
    try db.query(
      "INSERT INTO preflight_jobs(attempt, run, job_key, record) VALUES (?, ?, ?, ?) ON CONFLICT(attempt) DO UPDATE SET record = excluded.record",
      [.text(attempt.rawValue), .text(run.rawValue), .text(jobKey), .text(try Self.encode(record))])
  }

  package func preflightJob<T: Decodable>(_ attempt: JobAttemptID, as type: T.Type) throws(CIError)
    -> T?
  {
    guard
      let row = try db.query(
        "SELECT record FROM preflight_jobs WHERE attempt = ?", [.text(attempt.rawValue)]
      ).first
    else { return nil }
    return try Self.decode(type, try row.required("record"))
  }

  package func preflightJobs<T: Decodable>(run: PreflightRunID, as type: T.Type) throws(CIError)
    -> [T]
  {
    var out: [T] = []
    for row in try db.query(
      "SELECT record FROM preflight_jobs WHERE run = ? ORDER BY rowid", [.text(run.rawValue)])
    {
      out.append(try Self.decode(type, try row.required("record")))
    }
    return out
  }

  // MARK: Events

  /// Appends one bounded event. Messages are bounded and control-free; data
  /// values are nonsecret identifiers.
  @discardableResult
  package func event(
    _ subject: String, _ kind: String, _ message: String, data: [String: String] = [:]
  ) throws(CIError) -> Int64 {
    let bounded = String(CIError.bounded(message).utf8.prefix(Self.maxEventMessageBytes)) ?? ""
    try db.query(
      "INSERT INTO events(at, subject, kind, message, data) VALUES (?, ?, ?, ?, ?)",
      [
        .init(now), .text(subject), .text(kind), .text(bounded),
        .text(try Self.encode(data.mapValues(CIError.bounded))),
      ])
    let sequence = db.lastInsertRowID
    if sequence % 1_000 == 0 {
      try db.query("DELETE FROM events WHERE seq <= ?", [.int(sequence - Self.maxEvents)])
    }
    return sequence
  }

  /// Events after `cursor` (exclusive), optionally for one subject.
  package func events(after cursor: Int64, subject: String? = nil, limit: Int = 200) throws(CIError)
    -> [EventRecord]
  {
    var sql = "SELECT seq, at, subject, kind, message, data FROM events WHERE seq > ?"
    var bindings: [Database.Value] = [.int(cursor)]
    if let subject {
      sql += " AND subject = ?"
      bindings.append(.text(subject))
    }
    sql += " ORDER BY seq LIMIT ?"
    bindings.append(.int(Int64(min(max(limit, 1), 1_000))))
    var out: [EventRecord] = []
    for row in try db.query(sql, bindings) {
      out.append(
        EventRecord(
          sequence: row.int("seq") ?? 0, at: row.uint("at") ?? 0,
          subject: try row.required("subject"), kind: try row.required("kind"),
          message: try row.required("message"),
          data: try Self.decode([String: String].self, try row.required("data"))))
    }
    return out
  }
}
