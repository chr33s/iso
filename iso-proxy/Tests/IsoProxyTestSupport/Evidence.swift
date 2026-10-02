import CoreFoundation
import Foundation

public let proxyRepository: URL = {
  var path = URL(fileURLWithPath: #filePath)
  for _ in 0..<4 { path.deleteLastPathComponent() }
  return path
}()

/// Each run owns a private directory. Keep observations and child diagnostics on failure.
public final class Evidence {
  public let directory: URL
  public init(_ name: String) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "iso-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    print("Proxy test evidence: \(directory.path)")
  }
  public func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
}

public enum ObservationFailure: Error { case invalid(String) }

public func check(_ condition: Bool, _ message: String) throws {
  guard condition else { throw ObservationFailure.invalid(message) }
}

/// Check JSON types explicitly: NSNumber's boolean/integer bridging must not widen the schema.
public struct Record {
  public let fields: [String: Any]
  public init(_ fields: [String: Any]) { self.fields = fields }
  public func keys(_ expected: Set<String>) throws {
    try check(Set(fields.keys) == expected, "observation fields differ: \(Set(fields.keys))")
  }
  public func integer(_ key: String) throws -> Int {
    guard let value = fields[key] as? NSNumber,
      CFGetTypeID(value) != CFBooleanGetTypeID(),
      !String(cString: value.objCType).contains("f"),
      !String(cString: value.objCType).contains("d"), value.int64Value >= 0,
      value.uint64Value <= UInt64(Int.max)
    else { throw ObservationFailure.invalid("expected nonnegative integer: \(key)") }
    return value.intValue
  }
  public func boolean(_ key: String) throws -> Bool {
    guard let value = fields[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID()
    else { throw ObservationFailure.invalid("expected boolean: \(key)") }
    return value.boolValue
  }
  public func string(_ key: String) throws -> String {
    guard let value = fields[key] as? String else {
      throw ObservationFailure.invalid("expected string: \(key)")
    }
    return value
  }
  public func integers(_ key: String) throws -> [Int] {
    guard let values = fields[key] as? [Any] else {
      throw ObservationFailure.invalid("expected integer array: \(key)")
    }
    return try values.map { try Record([key: $0]).integer(key) }
  }
  public func records(_ key: String) throws -> [Record] {
    try decodeRecords(fields[key] as Any)
  }
}

public func decodeRecords(_ object: Any) throws -> [Record] {
  guard let values = object as? [[String: Any]] else {
    throw ObservationFailure.invalid("expected observation array")
  }
  return values.map(Record.init)
}
