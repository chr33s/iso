import Foundation
import IsoCore

/// A JSON value with object members in document order, parsed and printed
/// as `serde_json` (with `preserve_order`) does. Guest settings files are
/// read and rewritten through this, so a merge leaves the guest's own key
/// order alone. Parsing is bounded: input arrives size-limited from the
/// capture, and nesting deeper than `maxDepth` is rejected like
/// serde_json's recursion limit.
indirect enum OrderedJSON: Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case string(String)
  case array([OrderedJSON])
  case object(Members)

  static let maxDepth = 128

  /// Insertion-ordered members with `IndexMap` semantics: replacing a key
  /// keeps its position, a new key is appended, and removal swaps the last
  /// member into the hole (serde_json's `Map::remove` under
  /// `preserve_order`).
  struct Members: Equatable, Sendable {
    private(set) var keys: [String] = []
    private var values: [String: OrderedJSON] = [:]

    init() {}

    init(_ pairs: [(String, OrderedJSON)]) {
      for (key, value) in pairs { self[key] = value }
    }

    var isEmpty: Bool { keys.isEmpty }
    var count: Int { keys.count }

    subscript(key: String) -> OrderedJSON? {
      get { values[key] }
      set {
        guard let newValue else {
          remove(key)
          return
        }
        if values[key] == nil { keys.append(key) }
        values[key] = newValue
      }
    }

    /// Returns the previous value, if any.
    @discardableResult
    mutating func insert(_ key: String, _ value: OrderedJSON) -> OrderedJSON? {
      let previous = values[key]
      self[key] = value
      return previous
    }

    @discardableResult
    mutating func remove(_ key: String) -> OrderedJSON? {
      guard let previous = values.removeValue(forKey: key),
        let index = keys.firstIndex(of: key)
      else { return nil }
      if index == keys.count - 1 {
        keys.removeLast()
      } else {
        keys[index] = keys.removeLast()
      }
      return previous
    }

    var pairs: [(String, OrderedJSON)] { keys.map { ($0, values[$0]!) } }

    static func == (a: Members, b: Members) -> Bool {
      // serde_json map equality ignores order.
      a.values == b.values
    }
  }

  var objectMembers: Members? {
    if case .object(let members) = self { members } else { nil }
  }

  subscript(key: String) -> OrderedJSON? {
    objectMembers?[key]
  }

  var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
  var stringValue: String? { if case .string(let value) = self { value } else { nil } }

  // MARK: - Printing

  /// `serde_json::to_string`.
  var compact: String {
    var out = ""
    writeCompact(&out)
    return out
  }

  /// `serde_json::to_string_pretty` (no trailing newline).
  var pretty: String { String(outputJSON.rendered().dropLast()) }

  private func writeCompact(_ out: inout String) {
    switch self {
    case .array(let elements):
      out += "["
      for (index, element) in elements.enumerated() {
        if index > 0 { out += "," }
        element.writeCompact(&out)
      }
      out += "]"
    case .object(let members):
      out += "{"
      for (index, (key, value)) in members.pairs.enumerated() {
        if index > 0 { out += "," }
        out += Self.quote(key) + ":"
        value.writeCompact(&out)
      }
      out += "}"
    default:
      out += String(outputJSON.rendered().dropLast())
    }
  }

  var outputJSON: OutputJSON {
    switch self {
    case .null: .null
    case .bool(let value): .bool(value)
    case .int(let value): .int(value)
    case .uint(let value): .uint(value)
    case .double(let value): .double(value)
    case .string(let value): .string(value)
    case .array(let elements): .array(elements.map(\.outputJSON))
    case .object(let members): .object(members.pairs.map { ($0, $1.outputJSON) })
    }
  }

  static func quote(_ text: String) -> String {
    String(OutputJSON.string(text).rendered().dropLast())
  }

  // MARK: - Parsing

  struct ParseError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  static func parse(_ text: String) throws(ParseError) -> OrderedJSON {
    try withParserStack { () throws(ParseError) in try parseOnCurrentStack(text) }
  }

  private static func parseOnCurrentStack(_ text: String) throws(ParseError) -> OrderedJSON {
    var contiguous = text
    contiguous.makeContiguousUTF8()
    let bytes = contiguous.utf8Span.span
    var parser = Parser()
    parser.skipWhitespace(in: bytes)
    let value = try parser.value(in: bytes, depth: 0)
    parser.skipWhitespace(in: bytes)
    guard parser.index == bytes.count else {
      throw parser.error("trailing characters")
    }
    return value
  }

  private struct Parser {
    // Keep only the cursor here; each call borrows input from the parse scope.
    var index = 0

    func error(_ message: String) -> ParseError {
      ParseError(message: "\(message) at byte \(index)")
    }

    func text(in range: Range<Int>, bytes: Span<UInt8>) -> String {
      bytes.extracting(range).withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
    }

    mutating func skipWhitespace(in bytes: Span<UInt8>) {
      while index < bytes.count,
        [UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r")].contains(
          bytes[index])
      {
        index += 1
      }
    }

    mutating func value(in bytes: Span<UInt8>, depth: Int) throws(ParseError) -> OrderedJSON {
      guard index < bytes.count else { throw error("EOF while parsing a value") }
      switch bytes[index] {
      case UInt8(ascii: "{"):
        guard depth < OrderedJSON.maxDepth else { throw error("recursion limit exceeded") }
        index += 1
        var members = Members()
        skipWhitespace(in: bytes)
        if peek(UInt8(ascii: "}"), in: bytes) {
          index += 1
          return .object(members)
        }
        while true {
          skipWhitespace(in: bytes)
          guard peek(UInt8(ascii: "\""), in: bytes) else { throw error("key must be a string") }
          let key = try string(in: bytes)
          skipWhitespace(in: bytes)
          guard peek(UInt8(ascii: ":"), in: bytes) else { throw error("expected `:`") }
          index += 1
          skipWhitespace(in: bytes)
          members[key] = try value(in: bytes, depth: depth + 1)
          skipWhitespace(in: bytes)
          if peek(UInt8(ascii: ","), in: bytes) {
            index += 1
            continue
          }
          guard peek(UInt8(ascii: "}"), in: bytes) else { throw error("expected `,` or `}`") }
          index += 1
          return .object(members)
        }
      case UInt8(ascii: "["):
        guard depth < OrderedJSON.maxDepth else { throw error("recursion limit exceeded") }
        index += 1
        var elements: [OrderedJSON] = []
        skipWhitespace(in: bytes)
        if peek(UInt8(ascii: "]"), in: bytes) {
          index += 1
          return .array(elements)
        }
        while true {
          skipWhitespace(in: bytes)
          elements.append(try value(in: bytes, depth: depth + 1))
          skipWhitespace(in: bytes)
          if peek(UInt8(ascii: ","), in: bytes) {
            index += 1
            continue
          }
          guard peek(UInt8(ascii: "]"), in: bytes) else { throw error("expected `,` or `]`") }
          index += 1
          return .array(elements)
        }
      case UInt8(ascii: "\""): return .string(try string(in: bytes))
      case UInt8(ascii: "t"): return try literal("true", .bool(true), in: bytes)
      case UInt8(ascii: "f"): return try literal("false", .bool(false), in: bytes)
      case UInt8(ascii: "n"): return try literal("null", .null, in: bytes)
      default: return try number(in: bytes)
      }
    }

    func peek(_ byte: UInt8, in bytes: Span<UInt8>) -> Bool {
      index < bytes.count && bytes[index] == byte
    }

    mutating func literal(_ word: String, _ result: OrderedJSON, in bytes: Span<UInt8>)
      throws(ParseError) -> OrderedJSON
    {
      let expected = word.utf8
      guard bytes.count - index >= expected.count,
        bytes.extracting(index..<index + expected.count).withUnsafeBufferPointer({
          $0.elementsEqual(expected)
        })
      else { throw error("expected value") }
      index += expected.count
      return result
    }

    mutating func number(in bytes: Span<UInt8>) throws(ParseError) -> OrderedJSON {
      let start = index
      func isDigit(_ byte: UInt8) -> Bool { byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") }
      if peek(UInt8(ascii: "-"), in: bytes) { index += 1 }
      guard index < bytes.count, isDigit(bytes[index]) else { throw error("expected value") }
      if bytes[index] == UInt8(ascii: "0") {
        index += 1
      } else {
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
      }
      var integral = true
      if peek(UInt8(ascii: "."), in: bytes) {
        integral = false
        index += 1
        guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid number") }
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
      }
      if peek(UInt8(ascii: "e"), in: bytes) || peek(UInt8(ascii: "E"), in: bytes) {
        integral = false
        index += 1
        if peek(UInt8(ascii: "+"), in: bytes) || peek(UInt8(ascii: "-"), in: bytes) { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { throw error("invalid number") }
        while index < bytes.count, isDigit(bytes[index]) { index += 1 }
      }
      let text = text(in: start..<index, bytes: bytes)
      if integral {
        if text.hasPrefix("-") {
          // serde_json reads `-0` as a float.
          if text != "-0", let value = Int64(text) { return .int(value) }
        } else if let value = UInt64(text) {
          return .uint(value)
        }
      }
      guard let value = Double(text), value.isFinite else {
        throw error("number out of range")
      }
      return .double(value)
    }

    mutating func string(in bytes: Span<UInt8>) throws(ParseError) -> String {
      index += 1  // opening quote
      var scalars = String.UnicodeScalarView()
      var run = index
      func flush(_ end: Int) {
        scalars.append(contentsOf: text(in: run..<end, bytes: bytes).unicodeScalars)
      }
      while index < bytes.count {
        let byte = bytes[index]
        if byte == UInt8(ascii: "\"") {
          flush(index)
          index += 1
          return String(scalars)
        }
        if byte < 0x20 { throw error("control character in string") }
        if byte != UInt8(ascii: "\\") {
          index += 1
          continue
        }
        flush(index)
        index += 1
        guard index < bytes.count else { break }
        let escape = bytes[index]
        index += 1
        switch escape {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append("\u{08}")
        case UInt8(ascii: "f"): scalars.append("\u{0C}")
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"):
          var code = try hex4(in: bytes)
          if (0xD800...0xDBFF).contains(code) {
            guard peek(UInt8(ascii: "\\"), in: bytes), index + 1 < bytes.count,
              bytes[index + 1] == UInt8(ascii: "u")
            else { throw error("lone leading surrogate in hex escape") }
            index += 2
            let low = try hex4(in: bytes)
            guard (0xDC00...0xDFFF).contains(low) else {
              throw error("lone leading surrogate in hex escape")
            }
            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
          } else if (0xDC00...0xDFFF).contains(code) {
            throw error("lone trailing surrogate in hex escape")
          }
          guard let scalar = Unicode.Scalar(code) else { throw error("invalid escape") }
          scalars.append(scalar)
        default: throw error("invalid escape")
        }
        run = index
      }
      throw error("EOF while parsing a string")
    }

    mutating func hex4(in bytes: Span<UInt8>) throws(ParseError) -> UInt32 {
      guard bytes.count - index >= 4,
        bytes.extracting(index..<index + 4).withUnsafeBufferPointer({
          $0.allSatisfy { Character(Unicode.Scalar($0)).isHexDigit }
        }),
        let value = UInt32(text(in: index..<index + 4, bytes: bytes), radix: 16)
      else { throw error("invalid escape") }
      index += 4
      return value
    }
  }
}
