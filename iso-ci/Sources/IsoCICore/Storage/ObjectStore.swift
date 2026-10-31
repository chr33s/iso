import CryptoKit
import Foundation

/// One immutable, content-addressed object store for snapshots, cache
/// payloads, artifacts, action archives and log segments, with separate
/// metadata and authorization per kind (spec section 10). Digest knowledge
/// alone never authorizes a read: every read names a subject that holds a
/// grant. Writes land in a private staging file and are published atomically
/// only after the digest and size are verified.
package final class ObjectStore: Sendable {
  package enum Kind: String, Sendable, Codable, CaseIterable {
    case snapshot
    case cache
    case artifact
    case actionArchive = "action_archive"
    case log
    case result
  }

  package enum Mode: String, Sendable, Codable {
    case read
  }

  /// A writable private staging file for one upload.
  package struct Upload: Sendable, Equatable {
    package let id: String
    package let kind: Kind
    package let subject: String
    package let path: String
    package let limit: UInt64
  }

  package struct CacheEntry: Sendable, Equatable, Codable {
    package let scope: String
    package let key: String
    package let version: String
    package let digest: Digest
    package let size: UInt64
    package let createdAt: EpochSeconds
  }

  package struct ArtifactEntry: Sendable, Equatable, Codable {
    package let id: Int64
    package let run: String
    package let attempt: String
    package let name: String
    package let digest: Digest?
    package let size: UInt64
    package let authority: String
    package let finalized: Bool
    package let createdAt: EpochSeconds
  }

  package static let maxObjectBytes: UInt64 = 10 << 30
  package static let maxCacheKeyBytes = 512
  package static let maxRestoreKeys = 10

  private let db: Database
  package let root: String
  package let staging: String
  private let clock: any CIClock

  package init(
    database: Database, objects: String, staging: String, clock: any CIClock = SystemClock()
  )
    throws(CIError)
  {
    db = database
    root = objects
    self.staging = staging
    self.clock = clock
    try PrivateFiles.ensureDirectory(objects)
    try PrivateFiles.ensureDirectory(staging)
    try db.execute(
      """
      CREATE TABLE IF NOT EXISTS objects (
        kind TEXT NOT NULL, digest TEXT NOT NULL, size INTEGER NOT NULL, created_at INTEGER NOT NULL,
        PRIMARY KEY (kind, digest));
      CREATE TABLE IF NOT EXISTS object_grants (
        subject TEXT NOT NULL, kind TEXT NOT NULL, digest TEXT NOT NULL, mode TEXT NOT NULL,
        PRIMARY KEY (subject, kind, digest, mode));
      CREATE TABLE IF NOT EXISTS uploads (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, subject TEXT NOT NULL, path TEXT NOT NULL,
        size_limit INTEGER NOT NULL, created_at INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS cache_entries (
        scope TEXT NOT NULL, key TEXT NOT NULL, version TEXT NOT NULL, digest TEXT NOT NULL,
        size INTEGER NOT NULL, created_at INTEGER NOT NULL, publisher TEXT NOT NULL,
        PRIMARY KEY (scope, key, version));
      CREATE TABLE IF NOT EXISTS cache_reservations (
        id TEXT PRIMARY KEY, scope TEXT NOT NULL, key TEXT NOT NULL, version TEXT NOT NULL,
        subject TEXT NOT NULL, upload TEXT, created_at INTEGER NOT NULL,
        UNIQUE (scope, key, version));
      CREATE TABLE IF NOT EXISTS artifacts (
        id INTEGER PRIMARY KEY AUTOINCREMENT, run TEXT NOT NULL, attempt TEXT NOT NULL,
        name TEXT NOT NULL, digest TEXT, size INTEGER NOT NULL, authority TEXT NOT NULL,
        finalized INTEGER NOT NULL, created_at INTEGER NOT NULL, upload TEXT,
        UNIQUE (run, name));
      """)
  }

  package convenience init(root: DataRoot, database: Database, clock: any CIClock = SystemClock())
    throws(CIError)
  {
    try self.init(database: database, objects: root.objects, staging: root.staging, clock: clock)
  }

  // MARK: Paths

  package func path(_ digest: Digest) -> String {
    root + "/" + String(digest.rawValue.prefix(2)) + "/" + digest.rawValue
  }

  // MARK: Uploads

  /// Starts a private upload for `subject`, bounded by `limit` bytes.
  package func beginUpload(kind: Kind, subject: String, limit: UInt64) throws(CIError) -> Upload {
    guard limit > 0, limit <= Self.maxObjectBytes else {
      throw CIError.invalid("upload limit out of range")
    }
    let id = randomHex(bytes: 16)
    let directory = staging + "/uploads"
    try PrivateFiles.ensureDirectory(directory)
    let path = directory + "/" + id
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CIError.storage("cannot create an upload") }
    close(fd)
    try db.query(
      "INSERT INTO uploads(id, kind, subject, path, size_limit, created_at) VALUES (?,?,?,?,?,?)",
      [
        .text(id), .text(kind.rawValue), .text(subject), .text(path), .init(limit),
        .init(clock.now()),
      ])
    return Upload(id: id, kind: kind, subject: subject, path: path, limit: limit)
  }

  package func upload(_ id: String) throws(CIError) -> Upload? {
    guard id.utf8.count == 32, Array(id.utf8).allSatisfy(isLowerHex),
      let row = try db.query("SELECT * FROM uploads WHERE id = ?", [.text(id)]).first,
      let kind = Kind(rawValue: try row.required("kind"))
    else { return nil }
    return Upload(
      id: id, kind: kind, subject: try row.required("subject"), path: try row.required("path"),
      limit: row.uint("size_limit") ?? 0)
  }

  /// Appends bytes at `offset` (sequential or rewrite), enforcing the limit.
  package func write(_ upload: Upload, offset: UInt64, bytes: [UInt8]) throws(CIError) {
    guard offset + UInt64(bytes.count) <= upload.limit else {
      throw CIError(.budgetExceeded, "upload exceeds its size limit")
    }
    let fd = open(upload.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw CIError.storage("upload is gone") }
    defer { close(fd) }
    var written = 0
    while written < bytes.count {
      let count = bytes.withUnsafeBytes {
        pwrite(fd, $0.baseAddress! + written, $0.count - written, off_t(offset) + off_t(written))
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw CIError.storage("cannot write an upload")
      }
      written += count
    }
  }

  /// Hashes the staged file, verifies the expectation, and publishes it.
  /// The upload is consumed either way.
  @discardableResult
  package func commit(_ upload: Upload, expectedDigest: Digest? = nil, expectedSize: UInt64? = nil)
    throws(CIError) -> (digest: Digest, size: UInt64)
  {
    defer {
      PrivateFiles.remove(upload.path)
      _ = try? db.query("DELETE FROM uploads WHERE id = ?", [.text(upload.id)])
    }
    let (digest, size) = try hashFile(upload.path, limit: upload.limit)
    if let expectedDigest, expectedDigest != digest {
      throw CIError.invalid("uploaded content does not match its digest")
    }
    if let expectedSize, expectedSize != size {
      throw CIError.invalid("uploaded content does not match its size")
    }
    try publish(file: upload.path, kind: upload.kind, digest: digest, size: size)
    return (digest, size)
  }

  package func abort(_ upload: Upload) {
    PrivateFiles.remove(upload.path)
    _ = try? db.query("DELETE FROM uploads WHERE id = ?", [.text(upload.id)])
  }

  /// Imports a controller-produced file (for example a snapshot archive).
  package func importFile(_ path: String, kind: Kind, limit: UInt64 = maxObjectBytes)
    throws(CIError) -> (digest: Digest, size: UInt64)
  {
    let (digest, size) = try hashFile(path, limit: limit)
    let copy = staging + "/import-" + randomHex(bytes: 8)
    do { try FileManager.default.copyItem(atPath: path, toPath: copy) } catch {
      throw CIError.storage("cannot stage an import")
    }
    defer { PrivateFiles.remove(copy) }
    try publish(file: copy, kind: kind, digest: digest, size: size)
    return (digest, size)
  }

  package func importBytes(_ bytes: [UInt8], kind: Kind) throws(CIError) -> Digest {
    let digest = Digest(hashing: bytes)
    let copy = staging + "/import-" + randomHex(bytes: 8)
    try PrivateFiles.write(bytes, to: copy)
    defer { PrivateFiles.remove(copy) }
    try publish(file: copy, kind: kind, digest: digest, size: UInt64(bytes.count))
    return digest
  }

  private func publish(file: String, kind: Kind, digest: Digest, size: UInt64) throws(CIError) {
    let target = path(digest)
    try PrivateFiles.ensureDirectory((target as NSString).deletingLastPathComponent)
    if access(target, F_OK) != 0 {
      // Same filesystem: rename is the atomic publication point.
      if link(file, target) != 0 && errno != EEXIST {
        guard rename(file, target) == 0 || errno == EEXIST else {
          throw CIError.storage("cannot publish an object")
        }
      }
      chmod(target, 0o400)
    }
    try db.query(
      "INSERT OR IGNORE INTO objects(kind, digest, size, created_at) VALUES (?,?,?,?)",
      [.text(kind.rawValue), .text(digest.rawValue), .init(size), .init(clock.now())])
  }

  package func hashFile(_ path: String, limit: UInt64) throws(CIError) -> (Digest, UInt64) {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw CIError.storage("cannot read a staged object") }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw CIError.storage("a staged object is not a regular file")
    }
    guard UInt64(status.st_size) <= limit else {
      throw CIError(.budgetExceeded, "object exceeds its size limit")
    }
    var hasher = StreamingSHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    var total: UInt64 = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw CIError.storage("cannot read a staged object")
      }
      if count == 0 { break }
      total += UInt64(count)
      guard total <= limit else { throw CIError(.budgetExceeded, "object exceeds its size limit") }
      hasher.update(buffer[0..<count])
    }
    return (hasher.finalize(), total)
  }

  // MARK: Metadata and grants

  package func exists(kind: Kind, digest: Digest) throws(CIError) -> Bool {
    !(try db.query(
      "SELECT 1 FROM objects WHERE kind = ? AND digest = ?",
      [.text(kind.rawValue), .text(digest.rawValue)]
    ).isEmpty)
  }

  package func size(kind: Kind, digest: Digest) throws(CIError) -> UInt64? {
    try db.query(
      "SELECT size FROM objects WHERE kind = ? AND digest = ?",
      [.text(kind.rawValue), .text(digest.rawValue)]
    ).first?.uint("size")
  }

  /// Grants `subject` read access to one existing object of `kind`.
  package func grant(subject: String, kind: Kind, digest: Digest) throws(CIError) {
    guard try exists(kind: kind, digest: digest) else {
      throw CIError(.notFound, "no such \(kind.rawValue) object")
    }
    try db.query(
      "INSERT OR IGNORE INTO object_grants(subject, kind, digest, mode) VALUES (?,?,?,'read')",
      [.text(subject), .text(kind.rawValue), .text(digest.rawValue)])
  }

  package func isGranted(subject: String, kind: Kind, digest: Digest) throws(CIError) -> Bool {
    !(try db.query(
      "SELECT 1 FROM object_grants WHERE subject = ? AND kind = ? AND digest = ? AND mode = 'read'",
      [.text(subject), .text(kind.rawValue), .text(digest.rawValue)]
    ).isEmpty)
  }

  package func revokeAll(subject: String) throws(CIError) {
    try db.query("DELETE FROM object_grants WHERE subject = ?", [.text(subject)])
  }

  /// The object's path for an authorized subject; refuses without a grant.
  package func authorizedPath(subject: String, kind: Kind, digest: Digest) throws(CIError) -> String
  {
    guard try isGranted(subject: subject, kind: kind, digest: digest) else {
      throw CIError(.unauthorized, "not authorized for this object")
    }
    return path(digest)
  }

  /// Copies (APFS clone) an authorized object into `directory` under a
  /// random name. Never a hard link: a same-user process holding the copy
  /// must not be able to change the stored object's mode or bytes.
  package func exportCopy(subject: String, kind: Kind, digest: Digest, into directory: String)
    throws(CIError) -> String
  {
    let source = try authorizedPath(subject: subject, kind: kind, digest: digest)
    try PrivateFiles.ensureDirectory(directory)
    let target = directory + "/" + randomHex(bytes: 16)
    if clonefile(source, target, 0) != 0 {
      guard copyfile(source, target, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
        unlink(target)
        throw CIError.storage("cannot expose an object")
      }
    }
    chmod(target, 0o600)
    return target
  }

  // MARK: Caches

  /// A cache scope partitions entries by repository/owner, authority class,
  /// OS/architecture, approved image/toolchain and dependency lock digest
  /// (spec section 10); Actions key/version/restore-key matching applies
  /// only within one scope.
  package struct CacheScope: Sendable, Equatable, Codable {
    package let repository: String
    package let authority: String
    package let platform: String
    package let imageDigest: String
    package let toolchain: String
    package let inputDigest: String
    /// Set when the publishing run received secrets or captured a dirty or
    /// patched tree (`PreflightService.cacheConfinement`): such entries are
    /// confined to their own run and never shared or promoted.
    package let confinedToRun: String?

    package init(
      repository: String, authority: String, platform: String, imageDigest: String,
      toolchain: String, inputDigest: String, confinedToRun: String?
    ) {
      self.repository = repository
      self.authority = authority
      self.platform = platform
      self.imageDigest = imageDigest
      self.toolchain = toolchain
      self.inputDigest = inputDigest
      self.confinedToRun = confinedToRun
    }

    package var fingerprint: String {
      let value: JSONValue = [
        "repository": .string(repository), "authority": .string(authority),
        "platform": .string(platform), "image": .string(imageDigest),
        "toolchain": .string(toolchain), "input": .string(inputDigest),
        "run": confinedToRun.map(JSONValue.string) ?? .null,
      ]
      return Digest(hashing: value.canonical).rawValue
    }
  }

  package static func validCacheKey(_ key: String) -> Bool {
    (1...maxCacheKeyBytes).contains(key.utf8.count) && !key.contains(",")
      && key.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
  }

  /// Actions restore semantics within one scope: the primary key matches
  /// exactly; each restore key then matches exactly or as a prefix, newest
  /// entry first. The version must match exactly.
  package func cacheLookup(scope: CacheScope, keys: [String], version: String) throws(CIError)
    -> CacheEntry?
  {
    guard !keys.isEmpty, keys.count <= Self.maxRestoreKeys + 1, keys.allSatisfy(Self.validCacheKey)
    else { throw CIError.invalid("invalid cache keys") }
    let fingerprint = scope.fingerprint
    for (index, key) in keys.enumerated() {
      if let row = try db.query(
        "SELECT * FROM cache_entries WHERE scope = ? AND key = ? AND version = ?",
        [.text(fingerprint), .text(key), .text(version)]
      ).first {
        return try cacheEntry(row)
      }
      guard index > 0 else { continue }
      // Case-sensitive prefix match (SQLite LIKE folds ASCII case).
      if let row = try db.query(
        "SELECT * FROM cache_entries WHERE scope = ? AND version = ? AND substr(key, 1, length(?)) = ? ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [.text(fingerprint), .text(version), .text(key), .text(key)]
      ).first {
        return try cacheEntry(row)
      }
    }
    return nil
  }

  private func cacheEntry(_ row: Database.Row) throws(CIError) -> CacheEntry {
    CacheEntry(
      scope: try row.required("scope"), key: try row.required("key"),
      version: try row.required("version"), digest: try Digest(try row.required("digest")),
      size: row.uint("size") ?? 0, createdAt: row.uint("created_at") ?? 0)
  }

  /// Reserves (scope, key, version) for one publisher; nil when an entry or
  /// another reservation already exists (first writer wins, no overwrite).
  package func cacheReserve(
    scope: CacheScope, key: String, version: String, subject: String, limit: UInt64
  )
    throws(CIError) -> (reservation: String, upload: Upload)?
  {
    guard Self.validCacheKey(key), (1...512).contains(version.utf8.count) else {
      throw CIError.invalid("invalid cache key or version")
    }
    return try db.transaction { () throws(CIError) -> (String, Upload)? in
      let fingerprint = scope.fingerprint
      if !(try db.query(
        "SELECT 1 FROM cache_entries WHERE scope = ? AND key = ? AND version = ?",
        [.text(fingerprint), .text(key), .text(version)]
      ).isEmpty) {
        return nil
      }
      if !(try db.query(
        "SELECT 1 FROM cache_reservations WHERE scope = ? AND key = ? AND version = ?",
        [.text(fingerprint), .text(key), .text(version)]
      ).isEmpty) {
        return nil
      }
      let upload = try beginUpload(kind: .cache, subject: subject, limit: limit)
      let id = randomHex(bytes: 16)
      try db.query(
        "INSERT INTO cache_reservations(id, scope, key, version, subject, upload, created_at) VALUES (?,?,?,?,?,?,?)",
        [
          .text(id), .text(fingerprint), .text(key), .text(version), .text(subject),
          .text(upload.id),
          .init(clock.now()),
        ])
      return (id, upload)
    }
  }

  package func cacheReservation(_ id: String) throws(CIError) -> (subject: String, upload: Upload)?
  {
    guard
      let row = try db.query("SELECT * FROM cache_reservations WHERE id = ?", [.text(id)]).first,
      let uploadID = row.string("upload"), let upload = try upload(uploadID)
    else { return nil }
    return (try row.required("subject"), upload)
  }

  /// Verifies and publishes a reserved cache entry atomically. An
  /// incomplete or mismatched upload never becomes visible.
  package func cacheCommit(reservation id: String, subject: String, expectedSize: UInt64?)
    throws(CIError) -> CacheEntry
  {
    guard let row = try db.query("SELECT * FROM cache_reservations WHERE id = ?", [.text(id)]).first
    else { throw CIError(.notFound, "unknown cache reservation") }
    guard try row.required("subject") == subject else {
      throw CIError(.unauthorized, "cache reservation belongs to another attempt")
    }
    guard let uploadID = row.string("upload"), let upload = try upload(uploadID) else {
      throw CIError(.notFound, "cache upload is gone")
    }
    let published: (digest: Digest, size: UInt64)
    do {
      published = try commit(upload, expectedSize: expectedSize)
    } catch {
      _ = try? db.query("DELETE FROM cache_reservations WHERE id = ?", [.text(id)])
      throw error
    }
    let entry = CacheEntry(
      scope: try row.required("scope"), key: try row.required("key"),
      version: try row.required("version"), digest: published.digest, size: published.size,
      createdAt: clock.now())
    try db.transaction { () throws(CIError) in
      try db.query("DELETE FROM cache_reservations WHERE id = ?", [.text(id)])
      try db.query(
        "INSERT OR IGNORE INTO cache_entries(scope, key, version, digest, size, created_at, publisher) VALUES (?,?,?,?,?,?,?)",
        [
          .text(entry.scope), .text(entry.key), .text(entry.version), .text(entry.digest.rawValue),
          .init(entry.size), .init(entry.createdAt), .text(subject),
        ])
    }
    return entry
  }

  /// Drops reservations older than `before` (an uploader that vanished)
  /// together with their staged uploads.
  package func cacheExpireReservations(before: EpochSeconds) throws(CIError) {
    for row in try db.query(
      "SELECT id FROM cache_reservations WHERE created_at < ?", [.init(before)])
    {
      if let id = row.string("id") { try cacheAbort(reservation: id) }
    }
  }

  package func cacheAbort(reservation id: String) throws(CIError) {
    if let reserved = try cacheReservation(id) { abort(reserved.upload) }
    try db.query("DELETE FROM cache_reservations WHERE id = ?", [.text(id)])
  }

  // MARK: Artifacts

  package func artifactCreate(
    run: String, attempt: String, name: String, authority: String, limit: UInt64
  )
    throws(CIError) -> (entry: ArtifactEntry, upload: Upload)
  {
    guard Self.validArtifactName(name) else { throw CIError.invalid("invalid artifact name") }
    return try db.transaction { () throws(CIError) -> (ArtifactEntry, Upload) in
      if let existing = try db.query(
        "SELECT * FROM artifacts WHERE run = ? AND name = ?", [.text(run), .text(name)]
      ).first {
        guard existing.int("finalized") == 0, existing.string("attempt") == attempt else {
          throw CIError(.conflict, "an artifact with this name already exists in the run")
        }
        try db.query("DELETE FROM artifacts WHERE id = ?", [.int(existing.int("id") ?? -1)])
      }
      let upload = try beginUpload(kind: .artifact, subject: attempt, limit: limit)
      try db.query(
        "INSERT INTO artifacts(run, attempt, name, digest, size, authority, finalized, created_at, upload) VALUES (?,?,?,NULL,0,?,0,?,?)",
        [
          .text(run), .text(attempt), .text(name), .text(authority), .init(clock.now()),
          .text(upload.id),
        ])
      let entry = ArtifactEntry(
        id: db.lastInsertRowID, run: run, attempt: attempt, name: name, digest: nil, size: 0,
        authority: authority, finalized: false, createdAt: clock.now())
      return (entry, upload)
    }
  }

  package func artifactUpload(id: Int64, attempt: String) throws(CIError) -> Upload {
    guard let row = try db.query("SELECT * FROM artifacts WHERE id = ?", [.int(id)]).first else {
      throw CIError(.notFound, "unknown artifact")
    }
    guard row.string("attempt") == attempt, row.int("finalized") == 0,
      let uploadID = row.string("upload"), let upload = try upload(uploadID)
    else { throw CIError(.unauthorized, "artifact is not writable by this attempt") }
    return upload
  }

  package func artifactFinalize(
    id: Int64, attempt: String, expectedSize: UInt64?, expectedDigest: Digest?
  )
    throws(CIError) -> ArtifactEntry
  {
    let upload = try artifactUpload(id: id, attempt: attempt)
    let published = try commit(upload, expectedDigest: expectedDigest, expectedSize: expectedSize)
    try db.query(
      "UPDATE artifacts SET digest = ?, size = ?, finalized = 1, upload = NULL WHERE id = ?",
      [.text(published.digest.rawValue), .init(published.size), .int(id)])
    try grant(subject: attempt, kind: .artifact, digest: published.digest)
    guard let entry = try artifact(id: id) else { throw CIError(.notFound, "unknown artifact") }
    return entry
  }

  package func artifact(id: Int64) throws(CIError) -> ArtifactEntry? {
    guard let row = try db.query("SELECT * FROM artifacts WHERE id = ?", [.int(id)]).first else {
      return nil
    }
    return try artifactEntry(row)
  }

  /// Finalized artifacts of `run`, optionally filtered by name.
  package func artifacts(run: String, name: String? = nil) throws(CIError) -> [ArtifactEntry] {
    var sql = "SELECT * FROM artifacts WHERE run = ? AND finalized = 1"
    var bindings: [Database.Value] = [.text(run)]
    if let name {
      sql += " AND name = ?"
      bindings.append(.text(name))
    }
    var out: [ArtifactEntry] = []
    for row in try db.query(sql + " ORDER BY id", bindings) { out.append(try artifactEntry(row)) }
    return out
  }

  private func artifactEntry(_ row: Database.Row) throws(CIError) -> ArtifactEntry {
    ArtifactEntry(
      id: row.int("id") ?? 0, run: try row.required("run"), attempt: try row.required("attempt"),
      name: try row.required("name"),
      digest: try row.string("digest").map { (raw) throws(CIError) in try Digest(raw) },
      size: row.uint("size") ?? 0, authority: try row.required("authority"),
      finalized: row.int("finalized") == 1, createdAt: row.uint("created_at") ?? 0)
  }

  package static func validArtifactName(_ name: String) -> Bool {
    guard (1...256).contains(name.utf8.count), name != ".", name != ".." else { return false }
    let forbidden: Set<Unicode.Scalar> = ["\"", ":", "<", ">", "|", "*", "?", "\\", "/"]
    return name.unicodeScalars.allSatisfy {
      $0.value >= 0x20 && $0.value != 0x7F && !forbidden.contains($0)
    }
  }
}

/// Incremental SHA-256 over chunks (CryptoKit wrapper).
package struct StreamingSHA256 {
  private var hasher = SHA256Box()

  package init() {}

  package mutating func update(_ bytes: some Collection<UInt8>) { hasher.update(Array(bytes)) }

  package func finalize() -> Digest { hasher.finalize() }
}

private struct SHA256Box {
  var state = SHA256()

  mutating func update(_ bytes: [UInt8]) { state.update(data: bytes) }

  func finalize() -> Digest {
    // A freshly formatted hex digest always validates.
    Digest(unchecked: state.finalize().map { String(format: "%02x", $0) }.joined())
  }
}

extension Digest {
  fileprivate init(unchecked rawValue: String) {
    do { try self.init(rawValue) } catch { fatalError("SHA-256 produced an invalid digest") }
  }
}
