import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore

/// Byte-level framing and value handling for `iso.host/v1`
/// (docs/design/local-and-remote-hosts-spec.md section 6.1). Frames are UTF-8 JSON
/// Lines; every frame is decoded through the configuration loader's strict
/// pipeline (UTF-8, duplicate keys, depth, sizes) before any field is read.
package enum HostWire {
  package static let maxRequestFrame = 64 << 10
  package static let maxResponseFrame = 1 << 20
  package static let maxDepth = 32

  package static let requestLimits = JSONLimits(
    maxBytes: maxRequestFrame, maxDepth: maxDepth, maxKeys: 1_024, maxArrayElements: 256,
    maxNumberLength: 32, maxStringBytes: maxRequestFrame)
  package static let responseLimits = JSONLimits(
    maxBytes: maxResponseFrame, maxDepth: maxDepth, maxKeys: 65_536, maxArrayElements: 4_096,
    maxNumberLength: 32, maxStringBytes: maxResponseFrame)

  /// Parses one frame (without its newline). Errors never quote frame bytes.
  package static func parse(_ frame: [UInt8], limits: JSONLimits) throws(HostControlError)
    -> JSONValue
  {
    do {
      return try ConfigLoader.parse(frame, format: .json, path: "frame", limits: limits)
    } catch {
      let reason =
        switch error {
        case .preflight(_, let failure):
          switch failure.kind {
          case .tooLarge: "frame too large"
          case .duplicateKey: "duplicate key"
          case .tooDeep: "nesting too deep"
          case .byteOrderMark: "byte-order mark"
          default: "malformed JSON"
          }
        case .scan: "invalid UTF-8"
        default: "malformed JSON"
        }
      throw .invalidRequest(reason)
    }
  }

  /// Canonical compact encoding: sorted keys, no whitespace, minimal string
  /// escapes, exact integers. Deterministic for equal values, so request
  /// digests hash typed content, never incidental formatting.
  package static func canonical(_ value: JSONValue) -> [UInt8] {
    var out: [UInt8] = []
    append(value, to: &out)
    return out
  }

  /// `canonical` plus the frame newline.
  package static func frame(_ value: JSONValue) -> [UInt8] {
    canonical(value) + [UInt8(ascii: "\n")]
  }

  package static func sha256(_ bytes: [UInt8]) -> SHA256Hex {
    SHA256Hex(digest: SHA256.hash(data: bytes))
  }

  private static func append(_ value: JSONValue, to out: inout [UInt8]) {
    switch value {
    case .null: out += Array("null".utf8)
    case .bool(let flag): out += Array((flag ? "true" : "false").utf8)
    case .number(let number): out += Array(number.description.utf8)
    case .string(let string): appendString(string, to: &out)
    case .array(let elements):
      out.append(UInt8(ascii: "["))
      for (index, element) in elements.enumerated() {
        if index > 0 { out.append(UInt8(ascii: ",")) }
        append(element, to: &out)
      }
      out.append(UInt8(ascii: "]"))
    case .object(let members):
      out.append(UInt8(ascii: "{"))
      // Byte order of UTF-8 keys, independent of locale and String ordering.
      let keys = members.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
      for (index, key) in keys.enumerated() {
        if index > 0 { out.append(UInt8(ascii: ",")) }
        appendString(key, to: &out)
        out.append(UInt8(ascii: ":"))
        // Keys come from `members`, so the lookup always succeeds.
        append(members[key] ?? .null, to: &out)
      }
      out.append(UInt8(ascii: "}"))
    }
  }

  private static func appendString(_ string: String, to out: inout [UInt8]) {
    out.append(UInt8(ascii: "\""))
    for byte in string.utf8 {
      switch byte {
      case UInt8(ascii: "\""): out += Array("\\\"".utf8)
      case UInt8(ascii: "\\"): out += Array("\\\\".utf8)
      case 0x0A: out += Array("\\n".utf8)
      case 0x0D: out += Array("\\r".utf8)
      case 0x09: out += Array("\\t".utf8)
      case 0..<0x20:
        let hex = String(byte, radix: 16)
        out += Array(("\\u00" + (hex.count == 1 ? "0" + hex : hex)).utf8)
      default: out.append(byte)
      }
    }
    out.append(UInt8(ascii: "\""))
  }
}

/// Reads one closed wire object: every member must be consumed by a typed
/// accessor, and `finish()` rejects anything left over.
package struct WireObject {
  package let field: String
  private let members: [String: JSONValue]
  private var consumed: Set<String> = []

  package init(_ value: JSONValue, field: String) throws(HostControlError) {
    guard case .object(let members) = value else {
      throw .invalidRequest("\(field) must be an object")
    }
    self.field = field
    self.members = members
  }

  private func name(_ key: String) -> String { field.isEmpty ? key : "\(field).\(key)" }

  package mutating func raw(_ key: String) -> JSONValue? {
    consumed.insert(key)
    guard let value = members[key], value != .null else { return nil }
    return value
  }

  package mutating func required(_ key: String) throws(HostControlError) -> JSONValue {
    guard let value = raw(key) else { throw .invalidRequest("missing \(name(key))") }
    return value
  }

  package mutating func string(_ key: String) throws(HostControlError) -> String {
    try Self.string(try required(key), field: name(key))
  }

  package mutating func optionalString(_ key: String) throws(HostControlError) -> String? {
    guard let value = raw(key) else { return nil }
    return try Self.string(value, field: name(key))
  }

  package mutating func bool(_ key: String) throws(HostControlError) -> Bool {
    guard case .bool(let flag) = try required(key) else {
      throw .invalidRequest("\(name(key)) must be a boolean")
    }
    return flag
  }

  package mutating func unsigned<T: FixedWidthInteger & UnsignedInteger>(
    _ key: String, as _: T.Type = T.self
  ) throws(HostControlError) -> T {
    try Self.unsigned(try required(key), field: name(key))
  }

  package mutating func optionalUnsigned<T: FixedWidthInteger & UnsignedInteger>(
    _ key: String, as _: T.Type = T.self
  ) throws(HostControlError) -> T? {
    guard let value = raw(key) else { return nil }
    return try Self.unsigned(value, field: name(key))
  }

  package mutating func parsed<T>(
    _ key: String, _ parse: (String) throws(ValidationError) -> T
  ) throws(HostControlError) -> T {
    let text = try string(key)
    do { return try parse(text) } catch { throw .invalidRequest("invalid \(name(key))") }
  }

  package mutating func optionalParsed<T>(
    _ key: String, _ parse: (String) throws(ValidationError) -> T
  ) throws(HostControlError) -> T? {
    guard let text = try optionalString(key) else { return nil }
    do { return try parse(text) } catch { throw .invalidRequest("invalid \(name(key))") }
  }

  package mutating func object(_ key: String) throws(HostControlError) -> WireObject {
    try WireObject(try required(key), field: name(key))
  }

  package mutating func optionalObject(_ key: String) throws(HostControlError) -> WireObject? {
    guard let value = raw(key) else { return nil }
    return try WireObject(value, field: name(key))
  }

  package mutating func array(_ key: String) throws(HostControlError) -> [JSONValue] {
    guard case .array(let elements) = try required(key) else {
      throw .invalidRequest("\(name(key)) must be an array")
    }
    return elements
  }

  /// Rejects members no accessor read (closed v1 structures).
  package func finish() throws(HostControlError) {
    if let extra = members.keys.filter({ !consumed.contains($0) }).sorted().first {
      throw .invalidRequest("unknown field \(name(extra))")
    }
  }

  package static func string(_ value: JSONValue, field: String) throws(HostControlError) -> String {
    guard case .string(let text) = value else {
      throw .invalidRequest("\(field) must be a string")
    }
    return text
  }

  package static func unsigned<T: FixedWidthInteger & UnsignedInteger>(
    _ value: JSONValue, field: String, as _: T.Type = T.self
  ) throws(HostControlError) -> T {
    let result: T? =
      switch value {
      case .number(.integer(let n)): n >= 0 ? T(exactly: n) : nil
      case .number(.unsigned(let n)): T(exactly: n)
      default: nil
      }
    guard let result else { throw .invalidRequest("\(field) must be an unsigned integer in range") }
    return result
  }
}

/// Builds wire objects from typed values.
package struct WireBuilder {
  package private(set) var members: [String: JSONValue] = [:]

  package init() {}

  package mutating func set(_ key: String, _ value: String) { members[key] = .string(value) }
  package mutating func set(_ key: String, _ value: Bool) { members[key] = .bool(value) }
  package mutating func set(_ key: String, _ value: UInt64) {
    members[key] = .number(.unsigned(value))
  }
  package mutating func set(_ key: String, _ value: JSONValue) { members[key] = value }
  package mutating func set(_ key: String, _ value: some CustomStringConvertible) {
    members[key] = .string(value.description)
  }
  package mutating func setIfPresent(_ key: String, _ value: (some CustomStringConvertible)?) {
    if let value { members[key] = .string(value.description) }
  }
  package mutating func setIfPresent(_ key: String, _ value: UInt64?) {
    if let value { members[key] = .number(.unsigned(value)) }
  }

  package var value: JSONValue { .object(members) }
}

/// Wall-clock instants on the wire: whole UNIX seconds.
package struct WireTime: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
  package let seconds: UInt64

  package init(seconds: UInt64) { self.seconds = seconds }
  package init(_ date: Date) { seconds = UInt64(max(0, date.timeIntervalSince1970.rounded(.down))) }

  package var date: Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
  package var description: String { String(seconds) }
  package static func < (a: Self, b: Self) -> Bool { a.seconds < b.seconds }

  package func adding(seconds delta: UInt64) -> WireTime {
    let (sum, overflow) = seconds.addingReportingOverflow(delta)
    return WireTime(seconds: overflow ? .max : sum)
  }
}
