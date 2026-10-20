import Foundation
import SQLite3

/// A thin, typed wrapper over one SQLite connection. The controller owns one
/// database per data root (spec section 5); every multi-row change goes
/// through `transaction`, so a crash leaves either the old or the new state.
package final class Database: @unchecked Sendable {
  private var handle: OpaquePointer?
  private let lock = NSRecursiveLock()
  package let path: String

  /// Opens (creating if needed) the database at `path` with WAL journaling,
  /// foreign keys and a bounded busy timeout. `:memory:` is allowed in tests.
  package init(path: String) throws(CIError) {
    self.path = path
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
      let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
      sqlite3_close(db)
      throw CIError.storage("cannot open the controller database: \(message)")
    }
    handle = db
    sqlite3_busy_timeout(db, 5_000)
    if path != ":memory:" {
      chmod(path, 0o600)
      try execute("PRAGMA journal_mode=WAL")
    }
    try execute("PRAGMA foreign_keys=ON")
    try execute("PRAGMA synchronous=FULL")
  }

  deinit { sqlite3_close(handle) }

  private var db: OpaquePointer {
    // `handle` is set by the initializer and only cleared by deinit.
    handle!
  }

  private func failure(_ context: String) -> CIError {
    CIError.storage("\(context): \(String(cString: sqlite3_errmsg(db)))")
  }

  /// Runs one or more statements without bindings or results.
  package func execute(_ sql: String) throws(CIError) {
    lock.lock()
    defer { lock.unlock() }
    var error: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
      let message = error.map { String(cString: $0) } ?? "unknown error"
      sqlite3_free(error)
      throw CIError.storage("statement failed: \(message)")
    }
  }

  /// A bound value. Text and blobs are copied by SQLite (SQLITE_TRANSIENT).
  package enum Value: Sendable, Equatable {
    case null
    case int(Int64)
    case text(String)
    case blob([UInt8])

    package init(_ value: String?) { self = value.map(Value.text) ?? .null }
    package init(_ value: Int64?) { self = value.map(Value.int) ?? .null }
    package init(_ value: UInt64?) { self = value.map { .int(Int64(bitPattern: $0)) } ?? .null }
    package init(_ value: Bool) { self = .int(value ? 1 : 0) }
  }

  /// One result row, read by column name.
  package struct Row: Sendable {
    package let values: [String: Value]

    package func string(_ column: String) -> String? {
      if case .text(let value)? = values[column] { return value }
      return nil
    }

    package func int(_ column: String) -> Int64? {
      if case .int(let value)? = values[column] { return value }
      return nil
    }

    package func uint(_ column: String) -> UInt64? { int(column).map { UInt64(bitPattern: $0) } }

    package func bool(_ column: String) -> Bool { int(column).map { $0 != 0 } ?? false }

    package func blob(_ column: String) -> [UInt8]? {
      switch values[column] {
      case .blob(let bytes)?: bytes
      case .text(let text)?: Array(text.utf8)
      default: nil
      }
    }

    package func required(_ column: String) throws(CIError) -> String {
      guard let value = string(column) else {
        throw CIError.storage("database row is missing \(column)")
      }
      return value
    }
  }

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  /// Runs one statement with positional bindings; returns all rows.
  @discardableResult
  package func query(_ sql: String, _ bindings: [Value] = []) throws(CIError) -> [Row] {
    lock.lock()
    defer { lock.unlock() }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw failure("prepare failed")
    }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let code: Int32
      switch value {
      case .null: code = sqlite3_bind_null(statement, index)
      case .int(let number): code = sqlite3_bind_int64(statement, index, number)
      case .text(let text): code = sqlite3_bind_text(statement, index, text, -1, Self.transient)
      case .blob(let bytes):
        code = bytes.withUnsafeBytes {
          sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
        }
      }
      guard code == SQLITE_OK else { throw failure("bind failed") }
    }
    var rows: [Row] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw failure("step failed") }
      var values: [String: Value] = [:]
      for column in 0..<sqlite3_column_count(statement) {
        let name = String(cString: sqlite3_column_name(statement, column))
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: values[name] = .int(sqlite3_column_int64(statement, column))
        case SQLITE_TEXT:
          values[name] = .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, column))
          if let pointer = sqlite3_column_blob(statement, column), count > 0 {
            values[name] = .blob(Array(UnsafeRawBufferPointer(start: pointer, count: count)))
          } else {
            values[name] = .blob([])
          }
        case SQLITE_FLOAT:
          values[name] = .int(Int64(sqlite3_column_double(statement, column)))
        default: values[name] = .null
        }
      }
      rows.append(Row(values: values))
    }
    return rows
  }

  package var changes: Int {
    lock.lock()
    defer { lock.unlock() }
    return Int(sqlite3_changes(db))
  }

  package var lastInsertRowID: Int64 {
    lock.lock()
    defer { lock.unlock() }
    return sqlite3_last_insert_rowid(db)
  }

  /// Runs `body` inside BEGIN IMMEDIATE / COMMIT; rolls back on any error.
  /// Nested calls join the outer transaction.
  package func transaction<T>(_ body: () throws(CIError) -> T) throws(CIError) -> T {
    lock.lock()
    defer { lock.unlock() }
    if depth > 0 {
      depth += 1
      defer { depth -= 1 }
      return try body()
    }
    try execute("BEGIN IMMEDIATE")
    depth = 1
    do {
      let result = try body()
      depth = 0
      try execute("COMMIT")
      return result
    } catch {
      depth = 0
      try? execute("ROLLBACK")
      throw error
    }
  }

  private var depth = 0
}
