import Foundation

/// A JSON value with exact integers. Every byte sequence iso-ci accepts from
/// another process (host replies, GitHub responses, guest data-plane
/// requests) is parsed by `StrictJSON` into this type before any field is read.
package enum JSONValue: Sendable, Equatable, Hashable {
  case null
  case bool(Bool)
  case integer(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  package subscript(key: String) -> JSONValue? {
    if case .object(let members) = self { return members[key] }
    return nil
  }

  package var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  package var intValue: Int64? {
    switch self {
    case .integer(let value): value
    case .double(let value) where value.rounded() == value && abs(value) < 9e15: Int64(value)
    default: nil
    }
  }

  package var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  package var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  package var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  /// Canonical compact encoding: byte-sorted keys, no whitespace, minimal
  /// escapes. Equal values encode identically, so digests hash content.
  package var canonical: [UInt8] {
    var out: [UInt8] = []
    JSONValue.append(self, to: &out)
    return out
  }

  package var canonicalString: String { String(decoding: canonical, as: UTF8.self) }

  /// One JSON Lines frame (canonical encoding plus a newline).
  package var frame: [UInt8] { canonical + [0x0A] }

  private static func append(_ value: JSONValue, to out: inout [UInt8]) {
    switch value {
    case .null: out += Array("null".utf8)
    case .bool(let flag): out += Array((flag ? "true" : "false").utf8)
    case .integer(let number): out += Array(String(number).utf8)
    case .double(let number):
      if number.isFinite, number.rounded() == number, abs(number) < 9e15 {
        out += Array(String(Int64(number)).utf8)
      } else if number.isFinite {
        out += Array("\(number)".utf8)
      } else {
        out += Array("null".utf8)
      }
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
      let keys = members.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
      for (index, key) in keys.enumerated() {
        if index > 0 { out.append(UInt8(ascii: ",")) }
        appendString(key, to: &out)
        out.append(UInt8(ascii: ":"))
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

  /// Bridges to Foundation objects (for `Codable` interop and output).
  package var foundation: Any {
    switch self {
    case .null: NSNull()
    case .bool(let value): value
    case .integer(let value): value
    case .double(let value): value
    case .string(let value): value
    case .array(let values): values.map(\.foundation)
    case .object(let members): members.mapValues(\.foundation)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByNilLiteral
{
  package init(stringLiteral value: String) { self = .string(value) }
  package init(integerLiteral value: Int64) { self = .integer(value) }
  package init(booleanLiteral value: Bool) { self = .bool(value) }
  package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  package init(dictionaryLiteral elements: (String, JSONValue)...) {
    var members: [String: JSONValue] = [:]
    for (key, value) in elements { members[key] = value }
    self = .object(members)
  }
  package init(nilLiteral: ()) { self = .null }
}

/// Resource limits for one parse. Every parse names its limits explicitly.
package struct JSONLimits: Sendable, Equatable {
  package var maxBytes: Int
  package var maxDepth: Int
  package var maxKeys: Int
  package var maxArrayElements: Int
  package var maxStringBytes: Int

  package init(
    maxBytes: Int, maxDepth: Int = 32, maxKeys: Int = 4_096, maxArrayElements: Int = 4_096,
    maxStringBytes: Int? = nil
  ) {
    self.maxBytes = maxBytes
    self.maxDepth = maxDepth
    self.maxKeys = maxKeys
    self.maxArrayElements = maxArrayElements
    self.maxStringBytes = maxStringBytes ?? maxBytes
  }

  /// Host-control replies (`iso.host/v1` caps a response frame at 1 MiB).
  package static let hostReply = JSONLimits(maxBytes: 1 << 20, maxKeys: 65_536)
  /// Guest-originated data-plane request bodies.
  package static let guestRequest = JSONLimits(
    maxBytes: 1 << 20, maxDepth: 24, maxKeys: 8_192, maxArrayElements: 8_192)
  /// GitHub REST responses.
  package static let github = JSONLimits(
    maxBytes: 8 << 20, maxDepth: 32, maxKeys: 262_144, maxArrayElements: 65_536)
  /// Operator control-channel frames.
  package static let control = JSONLimits(maxBytes: 256 << 10)
}

/// A strict RFC 8259 parser: UTF-8 only, no BOM, duplicate keys refused,
/// depth/size/count limits enforced while parsing. Error text never quotes
/// input bytes.
package struct StrictJSON {
  private let bytes: [UInt8]
  private let limits: JSONLimits
  private var index = 0
  private var keys = 0

  package static func parse(_ bytes: [UInt8], limits: JSONLimits) throws(CIError) -> JSONValue {
    guard bytes.count <= limits.maxBytes else { throw CIError.invalid("JSON document too large") }
    guard String(validating: bytes, as: UTF8.self) != nil else {
      throw CIError.invalid("JSON is not valid UTF-8")
    }
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
      throw CIError.invalid("JSON has a byte-order mark")
    }
    var parser = StrictJSON(bytes: bytes, limits: limits)
    parser.skipWhitespace()
    let value = try parser.value(depth: 0)
    parser.skipWhitespace()
    guard parser.index == bytes.count else { throw CIError.invalid("trailing bytes after JSON") }
    return value
  }

  package static func parse(_ data: Data, limits: JSONLimits) throws(CIError) -> JSONValue {
    try parse(Array(data), limits: limits)
  }

  package static func parse(_ text: String, limits: JSONLimits) throws(CIError) -> JSONValue {
    try parse(Array(text.utf8), limits: limits)
  }

  private init(bytes: [UInt8], limits: JSONLimits) {
    self.bytes = bytes
    self.limits = limits
  }

  private mutating func skipWhitespace() {
    while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
  }

  private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

  private mutating func expect(_ literal: String) throws(CIError) {
    let expected = Array(literal.utf8)
    guard index + expected.count <= bytes.count,
      Array(bytes[index..<(index + expected.count)]) == expected
    else { throw CIError.invalid("malformed JSON") }
    index += expected.count
  }

  private mutating func value(depth: Int) throws(CIError) -> JSONValue {
    guard depth <= limits.maxDepth else { throw CIError.invalid("JSON nesting too deep") }
    guard let byte = peek() else { throw CIError.invalid("unexpected end of JSON") }
    switch byte {
    case UInt8(ascii: "{"): return try object(depth: depth)
    case UInt8(ascii: "["): return try array(depth: depth)
    case UInt8(ascii: "\""): return .string(try string())
    case UInt8(ascii: "t"):
      try expect("true")
      return .bool(true)
    case UInt8(ascii: "f"):
      try expect("false")
      return .bool(false)
    case UInt8(ascii: "n"):
      try expect("null")
      return .null
    default: return try number()
    }
  }

  private mutating func object(depth: Int) throws(CIError) -> JSONValue {
    index += 1
    var members: [String: JSONValue] = [:]
    skipWhitespace()
    if peek() == UInt8(ascii: "}") {
      index += 1
      return .object(members)
    }
    while true {
      skipWhitespace()
      guard peek() == UInt8(ascii: "\"") else { throw CIError.invalid("malformed JSON object") }
      let key = try string()
      keys += 1
      guard keys <= limits.maxKeys else { throw CIError.invalid("too many JSON keys") }
      guard members[key] == nil else { throw CIError.invalid("duplicate JSON key") }
      skipWhitespace()
      guard peek() == UInt8(ascii: ":") else { throw CIError.invalid("malformed JSON object") }
      index += 1
      skipWhitespace()
      members[key] = try value(depth: depth + 1)
      skipWhitespace()
      switch peek() {
      case UInt8(ascii: ","): index += 1
      case UInt8(ascii: "}"):
        index += 1
        return .object(members)
      default: throw CIError.invalid("malformed JSON object")
      }
    }
  }

  private mutating func array(depth: Int) throws(CIError) -> JSONValue {
    index += 1
    var elements: [JSONValue] = []
    skipWhitespace()
    if peek() == UInt8(ascii: "]") {
      index += 1
      return .array(elements)
    }
    while true {
      skipWhitespace()
      elements.append(try value(depth: depth + 1))
      guard elements.count <= limits.maxArrayElements else {
        throw CIError.invalid("JSON array too long")
      }
      skipWhitespace()
      switch peek() {
      case UInt8(ascii: ","): index += 1
      case UInt8(ascii: "]"):
        index += 1
        return .array(elements)
      default: throw CIError.invalid("malformed JSON array")
      }
    }
  }

  private mutating func string() throws(CIError) -> String {
    index += 1
    var out: [UInt8] = []
    while true {
      guard let byte = peek() else { throw CIError.invalid("unterminated JSON string") }
      index += 1
      switch byte {
      case UInt8(ascii: "\""):
        guard out.count <= limits.maxStringBytes else {
          throw CIError.invalid("JSON string too long")
        }
        return String(decoding: out, as: UTF8.self)
      case UInt8(ascii: "\\"):
        guard let escape = peek() else { throw CIError.invalid("unterminated JSON string") }
        index += 1
        switch escape {
        case UInt8(ascii: "\""): out.append(0x22)
        case UInt8(ascii: "\\"): out.append(0x5C)
        case UInt8(ascii: "/"): out.append(0x2F)
        case UInt8(ascii: "b"): out.append(0x08)
        case UInt8(ascii: "f"): out.append(0x0C)
        case UInt8(ascii: "n"): out.append(0x0A)
        case UInt8(ascii: "r"): out.append(0x0D)
        case UInt8(ascii: "t"): out.append(0x09)
        case UInt8(ascii: "u"):
          var scalar = try hex4()
          if (0xD800..<0xDC00).contains(scalar) {
            try expect("\\u")
            let low = try hex4()
            guard (0xDC00..<0xE000).contains(low) else {
              throw CIError.invalid("invalid JSON surrogate pair")
            }
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
          } else if (0xDC00..<0xE000).contains(scalar) {
            throw CIError.invalid("invalid JSON surrogate pair")
          }
          guard let unicode = Unicode.Scalar(scalar) else {
            throw CIError.invalid("invalid JSON escape")
          }
          out += Array(String(unicode).utf8)
        default: throw CIError.invalid("invalid JSON escape")
        }
      case 0..<0x20: throw CIError.invalid("control character in JSON string")
      default: out.append(byte)
      }
      guard out.count <= limits.maxStringBytes else {
        throw CIError.invalid("JSON string too long")
      }
    }
  }

  private mutating func hex4() throws(CIError) -> UInt32 {
    guard index + 4 <= bytes.count else { throw CIError.invalid("invalid JSON escape") }
    var value: UInt32 = 0
    for _ in 0..<4 {
      let byte = bytes[index]
      index += 1
      let digit: UInt32
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
      default: throw CIError.invalid("invalid JSON escape")
      }
      value = value * 16 + digit
    }
    return value
  }

  private mutating func number() throws(CIError) -> JSONValue {
    let start = index
    if peek() == UInt8(ascii: "-") { index += 1 }
    guard let first = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
      throw CIError.invalid("malformed JSON")
    }
    if first == UInt8(ascii: "0") {
      index += 1
    } else {
      while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
    }
    var integral = true
    if peek() == UInt8(ascii: ".") {
      integral = false
      index += 1
      guard let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else {
        throw CIError.invalid("malformed JSON number")
      }
      while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
    }
    if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
      integral = false
      index += 1
      if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
      guard let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else {
        throw CIError.invalid("malformed JSON number")
      }
      while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
    }
    guard index - start <= 64 else { throw CIError.invalid("JSON number too long") }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    if integral, let exact = Int64(text) { return .integer(exact) }
    guard let double = Double(text), double.isFinite else {
      throw CIError.invalid("JSON number out of range")
    }
    return .double(double)
  }
}

/// Reads one closed object: every member must be consumed by a typed
/// accessor, and `finish()` refuses anything left over (strict decoding).
package struct ObjectReader {
  package let field: String
  package let members: [String: JSONValue]
  private var consumed: Set<String> = []

  package init(_ value: JSONValue, field: String) throws(CIError) {
    guard case .object(let members) = value else {
      throw CIError.invalid("\(field.isEmpty ? "value" : field) must be an object")
    }
    self.field = field
    self.members = members
  }

  private func name(_ key: String) -> String { field.isEmpty ? key : "\(field).\(key)" }

  package mutating func optional(_ key: String) -> JSONValue? {
    consumed.insert(key)
    guard let value = members[key], value != .null else { return nil }
    return value
  }

  package mutating func required(_ key: String) throws(CIError) -> JSONValue {
    guard let value = optional(key) else { throw CIError.invalid("missing \(name(key))") }
    return value
  }

  package mutating func string(_ key: String) throws(CIError) -> String {
    guard case .string(let value) = try required(key) else {
      throw CIError.invalid("\(name(key)) must be a string")
    }
    return value
  }

  package mutating func optionalString(_ key: String) throws(CIError) -> String? {
    guard let raw = optional(key) else { return nil }
    guard case .string(let value) = raw else {
      throw CIError.invalid("\(name(key)) must be a string")
    }
    return value
  }

  package mutating func int(_ key: String) throws(CIError) -> Int64 {
    guard let value = try required(key).intValue else {
      throw CIError.invalid("\(name(key)) must be an integer")
    }
    return value
  }

  /// A string member that must be one of an enumeration's raw values.
  package mutating func enumeration<T: RawRepresentable>(_ key: String, as type: T.Type)
    throws(CIError) -> T where T.RawValue == String
  {
    guard let value = T(rawValue: try string(key)) else {
      throw CIError.invalid("invalid \(name(key))")
    }
    return value
  }

  package mutating func optionalInt(_ key: String) throws(CIError) -> Int64? {
    guard let raw = optional(key) else { return nil }
    guard let value = raw.intValue else { throw CIError.invalid("\(name(key)) must be an integer") }
    return value
  }

  package mutating func unsigned(_ key: String) throws(CIError) -> UInt64 {
    let value = try int(key)
    guard value >= 0 else { throw CIError.invalid("\(name(key)) must not be negative") }
    return UInt64(value)
  }

  package mutating func optionalUnsigned(_ key: String) throws(CIError) -> UInt64? {
    guard let value = try optionalInt(key) else { return nil }
    guard value >= 0 else { throw CIError.invalid("\(name(key)) must not be negative") }
    return UInt64(value)
  }

  package mutating func bool(_ key: String) throws(CIError) -> Bool {
    guard case .bool(let value) = try required(key) else {
      throw CIError.invalid("\(name(key)) must be a boolean")
    }
    return value
  }

  package mutating func optionalBool(_ key: String) throws(CIError) -> Bool? {
    guard let raw = optional(key) else { return nil }
    guard case .bool(let value) = raw else {
      throw CIError.invalid("\(name(key)) must be a boolean")
    }
    return value
  }

  package mutating func array(_ key: String) throws(CIError) -> [JSONValue] {
    guard case .array(let value) = try required(key) else {
      throw CIError.invalid("\(name(key)) must be an array")
    }
    return value
  }

  package mutating func optionalArray(_ key: String) throws(CIError) -> [JSONValue]? {
    guard let raw = optional(key) else { return nil }
    guard case .array(let value) = raw else {
      throw CIError.invalid("\(name(key)) must be an array")
    }
    return value
  }

  package mutating func object(_ key: String) throws(CIError) -> ObjectReader {
    try ObjectReader(try required(key), field: name(key))
  }

  package mutating func strings(_ key: String) throws(CIError) -> [String] {
    var out: [String] = []
    for item in try array(key) {
      guard case .string(let value) = item else {
        throw CIError.invalid("\(name(key)) must contain strings")
      }
      out.append(value)
    }
    return out
  }

  /// Parses a string member as a validated identifier type. Prefer this to
  /// the closure form: an unapplied `T.init` can resolve to a non-validating
  /// initializer.
  package mutating func parsed<T: WireParsable>(_ key: String, as type: T.Type) throws(CIError) -> T
  {
    let raw = try string(key)
    do { return try T(parsing: raw) } catch { throw CIError.invalid("invalid \(name(key))") }
  }

  package mutating func optionalParsed<T: WireParsable>(_ key: String, as type: T.Type)
    throws(CIError) -> T?
  {
    guard let raw = try optionalString(key) else { return nil }
    do { return try T(parsing: raw) } catch { throw CIError.invalid("invalid \(name(key))") }
  }

  /// Parses a string member with a validating initializer.
  package mutating func parsed<T>(_ key: String, _ make: (String) throws -> T) throws(CIError) -> T
  {
    let raw = try string(key)
    do { return try make(raw) } catch { throw CIError.invalid("invalid \(name(key))") }
  }

  package mutating func optionalParsed<T>(_ key: String, _ make: (String) throws -> T)
    throws(CIError) -> T?
  {
    guard let raw = try optionalString(key) else { return nil }
    do { return try make(raw) } catch { throw CIError.invalid("invalid \(name(key))") }
  }

  /// Marks members as intentionally ignored (forward-compatible readers).
  package mutating func ignore(_ keys: String...) { for key in keys { consumed.insert(key) } }

  /// Refuses unknown members.
  package func finish() throws(CIError) {
    let unknown = Set(members.keys).subtracting(consumed)
    guard unknown.isEmpty else {
      throw CIError.invalid("unknown field in \(field.isEmpty ? "object" : field)")
    }
  }
}
