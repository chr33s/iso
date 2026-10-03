// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import IsoConfiguration
import IsoCore

/// A `devcontainer.json` value as the baseline decoded it (`serde_json`
/// with `preserve_order`). Objects keep every member in document order;
/// consumers merge repeated keys per the target type (`mergedMembers`,
/// `sortedMembers`) or reject them for modeled fields. Numbers keep
/// serde_json's classes: unsigned and negative integers, otherwise `f64`.
/// Offsets locate the value in the scanned bytes for diagnostics.
package struct DevcontainerJSON: Sendable, Equatable {
  package indirect enum Value: Sendable, Equatable {
    case null
    case bool(Bool)
    case unsigned(UInt64)
    case negative(Int64)
    case float(Double)
    case string(String)
    case array([DevcontainerJSON])
    case object([Member])
  }

  package struct Member: Sendable, Equatable {
    package let key: String
    /// Offset just past the key's closing quote.
    let keyEnd: Int
    package var value: DevcontainerJSON
  }

  package var value: Value
  /// Offset of the first byte and just past the last byte of the value.
  let start: Int
  let end: Int

  package init(_ value: Value) {
    self.value = value
    start = 0
    end = 0
  }

  init(_ value: Value, start: Int, end: Int) {
    self.value = value
    self.start = start
    self.end = end
  }

  package static func == (a: Self, b: Self) -> Bool { a.value == b.value }

  /// `serde_json::Value` rendering: strings bare, everything else as
  /// compact JSON.
  package var rendered: String {
    if case .string(let text) = value { return text }
    return output.compactRendered()
  }

  package var output: OutputJSON {
    switch value {
    case .null: .null
    case .bool(let flag): .bool(flag)
    case .unsigned(let number): .uint(number)
    case .negative(let number): .int(number)
    case .float(let number): .double(number)
    case .string(let text): .string(text)
    case .array(let elements): .array(elements.map(\.output))
    case .object(let members): .object(mergedMembers(members).map { ($0.key, $0.value.output) })
    }
  }

  package var string: String? {
    if case .string(let text) = value { text } else { nil }
  }

  package var isNull: Bool { value == .null }

  /// serde's `Unexpected` text for this value in an `invalid type` error.
  var unexpected: String {
    switch value {
    case .null: "unit value"
    case .bool(let flag): "boolean `\(flag)`"
    case .unsigned(let number): "integer `\(number)`"
    case .negative(let number): "integer `\(number)`"
    case .float(let number): "floating point `\(OutputJSON.floatText(number))`"
    case .string(let text): "string \(debugQuoted(text))"
    case .array: "sequence"
    case .object: "map"
    }
  }
}

/// A decoding failure with serde_json's message and position suffix.
package struct DevcontainerJSONError: Error, Equatable, Sendable, CustomStringConvertible {
  package let message: String
  package let line: Int
  package let column: Int
  package var description: String { "\(message) at line \(line) column \(column)" }
}

/// Positions in the scanned document, reported as serde_json does:
/// `consumed` counts bytes read on the line, so a peeked byte is included.
struct DevcontainerSource {
  let bytes: [UInt8]

  func error(_ message: String, consumed offset: Int) -> DevcontainerJSONError {
    var line = 1
    var lineStart = 0
    for index in 0..<min(offset, bytes.count) where bytes[index] == UInt8(ascii: "\n") {
      line += 1
      lineStart = index + 1
    }
    return DevcontainerJSONError(message: message, line: line, column: offset - lineStart)
  }

  /// `invalid type`: scalars are reported after the value, containers
  /// before their opening bracket.
  func invalidType(_ node: DevcontainerJSON, expected: String) -> DevcontainerJSONError {
    let offset: Int
    switch node.value {
    case .array, .object: offset = node.start
    default: offset = node.end
    }
    return error("invalid type: \(node.unexpected), expected \(expected)", consumed: offset)
  }

  func invalidValue(_ node: DevcontainerJSON, expected: String) -> DevcontainerJSONError {
    error("invalid value: \(node.unexpected), expected \(expected)", consumed: node.end)
  }

  /// A custom error raised while deserializing `node` inside an object:
  /// reported after the object's closing brace when it follows directly,
  /// otherwise at the next token.
  func custom(_ message: String, after node: DevcontainerJSON) -> DevcontainerJSONError {
    var index = node.end
    while index < bytes.count, DevcontainerParser.isWhitespace(bytes[index]) { index += 1 }
    if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1 }
    return error(message, consumed: index)
  }
}

/// RFC 8259 parser with serde_json's grammar and messages. Input is the
/// output of the shared JSONC scanner under the `.devcontainer` policy.
struct DevcontainerParser {
  static let recursionLimit = 127

  let source: DevcontainerSource
  var bytes: [UInt8] { source.bytes }
  var index = 0
  var depth = 0

  static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
  }

  static func parse(_ scanned: [UInt8]) throws(DevcontainerJSONError) -> DevcontainerJSON {
    var parser = DevcontainerParser(source: DevcontainerSource(bytes: scanned))
    let value = try parser.value()
    parser.skipWhitespace()
    if parser.index < scanned.count {
      throw parser.source.error("trailing characters", consumed: parser.index + 1)
    }
    return value
  }

  mutating func skipWhitespace() {
    while index < bytes.count, Self.isWhitespace(bytes[index]) { index += 1 }
  }

  func peekError(_ message: String) -> DevcontainerJSONError {
    source.error(message, consumed: min(index + 1, bytes.count))
  }

  func eofError(_ what: String) -> DevcontainerJSONError {
    source.error("EOF while parsing \(what)", consumed: bytes.count)
  }

  mutating func value() throws(DevcontainerJSONError) -> DevcontainerJSON {
    skipWhitespace()
    guard index < bytes.count else { throw eofError("a value") }
    let start = index
    switch bytes[index] {
    case UInt8(ascii: "n"):
      try literal("null")
      return DevcontainerJSON(.null, start: start, end: index)
    case UInt8(ascii: "t"):
      try literal("true")
      return DevcontainerJSON(.bool(true), start: start, end: index)
    case UInt8(ascii: "f"):
      try literal("false")
      return DevcontainerJSON(.bool(false), start: start, end: index)
    case UInt8(ascii: "\""):
      let text = try string()
      return DevcontainerJSON(.string(text), start: start, end: index)
    case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
      let number = try number()
      return DevcontainerJSON(number, start: start, end: index)
    case UInt8(ascii: "["):
      return try array(start)
    case UInt8(ascii: "{"):
      return try object(start)
    default:
      throw peekError("expected value")
    }
  }

  mutating func literal(_ word: String) throws(DevcontainerJSONError) {
    for expected in word.utf8 {
      guard index < bytes.count else { throw eofError("a value") }
      guard bytes[index] == expected else { throw peekError("expected ident") }
      index += 1
    }
  }

  mutating func enter() throws(DevcontainerJSONError) {
    depth += 1
    if depth > Self.recursionLimit { throw peekError("recursion limit exceeded") }
  }

  mutating func array(_ start: Int) throws(DevcontainerJSONError) -> DevcontainerJSON {
    try enter()
    index += 1
    var elements: [DevcontainerJSON] = []
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
      index += 1
      depth -= 1
      return DevcontainerJSON(.array([]), start: start, end: index)
    }
    while true {
      guard index < bytes.count else { throw eofError("a list") }
      elements.append(try value())
      skipWhitespace()
      guard index < bytes.count else { throw eofError("a list") }
      switch bytes[index] {
      case UInt8(ascii: ","):
        index += 1
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
          throw peekError("trailing comma")
        }
      case UInt8(ascii: "]"):
        index += 1
        depth -= 1
        return DevcontainerJSON(.array(elements), start: start, end: index)
      default:
        throw peekError("expected `,` or `]`")
      }
    }
  }

  mutating func object(_ start: Int) throws(DevcontainerJSONError) -> DevcontainerJSON {
    try enter()
    index += 1
    var members: [DevcontainerJSON.Member] = []
    skipWhitespace()
    if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
      index += 1
      depth -= 1
      return DevcontainerJSON(.object([]), start: start, end: index)
    }
    while true {
      skipWhitespace()
      guard index < bytes.count else { throw eofError("an object") }
      guard bytes[index] == UInt8(ascii: "\"") else { throw peekError("key must be a string") }
      let key = try string()
      let keyEnd = index
      skipWhitespace()
      guard index < bytes.count else { throw eofError("an object") }
      guard bytes[index] == UInt8(ascii: ":") else { throw peekError("expected `:`") }
      index += 1
      members.append(DevcontainerJSON.Member(key: key, keyEnd: keyEnd, value: try value()))
      skipWhitespace()
      guard index < bytes.count else { throw eofError("an object") }
      switch bytes[index] {
      case UInt8(ascii: ","):
        index += 1
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
          throw peekError("trailing comma")
        }
      case UInt8(ascii: "}"):
        index += 1
        depth -= 1
        return DevcontainerJSON(.object(members), start: start, end: index)
      default:
        throw peekError("expected `,` or `}`")
      }
    }
  }

  mutating func string() throws(DevcontainerJSONError) -> String {
    index += 1
    var scalars = String.UnicodeScalarView()
    var runStart = index
    func flush(_ end: Int) {
      scalars.append(
        contentsOf: String(decoding: bytes[runStart..<end], as: UTF8.self).unicodeScalars)
    }
    while true {
      guard index < bytes.count else { throw eofError("a string") }
      let byte = bytes[index]
      if byte == UInt8(ascii: "\"") {
        flush(index)
        index += 1
        return String(scalars)
      }
      if byte < 0x20 {
        throw peekError("control character (\\u0000-\\u001F) found while parsing a string")
      }
      guard byte == UInt8(ascii: "\\") else {
        index += 1
        continue
      }
      flush(index)
      index += 1
      guard index < bytes.count else { throw eofError("a string") }
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
        let unit = try hex4()
        if (0xDC00...0xDFFF).contains(unit) {
          throw peekError("lone leading surrogate in hex escape")
        }
        if (0xD800...0xDBFF).contains(unit) {
          guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
            bytes[index + 1] == UInt8(ascii: "u")
          else {
            throw peekError("unexpected end of hex escape")
          }
          index += 2
          let low = try hex4()
          guard (0xDC00...0xDFFF).contains(low) else {
            throw peekError("lone leading surrogate in hex escape")
          }
          let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
          scalars.append(Unicode.Scalar(combined)!)
        } else {
          scalars.append(Unicode.Scalar(unit)!)
        }
      default:
        throw source.error("invalid escape", consumed: index)
      }
      runStart = index
    }
  }

  mutating func hex4() throws(DevcontainerJSONError) -> UInt32 {
    var result: UInt32 = 0
    for _ in 0..<4 {
      guard index < bytes.count else { throw eofError("a string") }
      let byte = bytes[index]
      let digit: UInt32
      switch byte {
      case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
      case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
      case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
      default: throw peekError("invalid escape")
      }
      result = result << 4 | digit
      index += 1
    }
    return result
  }

  func isDigit(_ offset: Int) -> Bool {
    offset < bytes.count && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[offset])
  }

  mutating func number() throws(DevcontainerJSONError) -> DevcontainerJSON.Value {
    let start = index
    let negative = bytes[index] == UInt8(ascii: "-")
    if negative { index += 1 }
    guard index < bytes.count else { throw eofError("a value") }
    guard isDigit(index) else { throw peekError("invalid number") }
    if bytes[index] == UInt8(ascii: "0") {
      index += 1
      if isDigit(index) { throw peekError("invalid number") }
    } else {
      while isDigit(index) { index += 1 }
    }
    var fractional = false
    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
      fractional = true
      index += 1
      guard isDigit(index) else {
        if index >= bytes.count { throw eofError("a value") }
        throw peekError("invalid number")
      }
      while isDigit(index) { index += 1 }
    }
    if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
      fractional = true
      index += 1
      if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")
      {
        index += 1
      }
      guard isDigit(index) else {
        if index >= bytes.count { throw eofError("a value") }
        throw peekError("invalid number")
      }
      while isDigit(index) { index += 1 }
    }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    if !fractional {
      let digits = negative ? String(text.dropFirst()) : text
      if negative {
        if digits.allSatisfy({ $0 == "0" }) { return .float(-0.0) }
        if let magnitude = UInt64(digits), magnitude <= UInt64(Int64.max) + 1 {
          return .negative(magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude))
        }
      } else if let value = UInt64(digits) {
        return .unsigned(value)
      }
    }
    guard let value = Double(text), value.isFinite else {
      throw source.error("number out of range", consumed: index)
    }
    return .float(value)
  }
}

extension DevcontainerJSON {
  /// Strip comments and trailing commas with the shared scanner, then parse.
  package static func parse(_ text: String) throws -> DevcontainerJSON {
    let scanned = try JSONCScanner.strip(Array(text.utf8), policy: .devcontainer)
    return try DevcontainerParser.parse(scanned)
  }
}
