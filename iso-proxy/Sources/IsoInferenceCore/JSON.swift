/// A parsed JSON value. Objects keep their member order so a re-serialized
/// document differs from its source only where policy changed it. Numbers
/// keep their validated source text; nothing is rounded through a Double on
/// the way upstream.
package indirect enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(JSONNumber)
  case string(String)
  case array([JSON])
  case object(JSONObject)

  package var object: JSONObject? {
    if case .object(let object) = self { object } else { nil }
  }
  package var array: [JSON]? {
    if case .array(let array) = self { array } else { nil }
  }
  package var string: String? {
    if case .string(let string) = self { string } else { nil }
  }
  package var bool: Bool? {
    if case .bool(let bool) = self { bool } else { nil }
  }
  package var number: JSONNumber? {
    if case .number(let number) = self { number } else { nil }
  }

  package subscript(key: String) -> JSON? { object?[key] }

  package static func int(_ value: Int64) -> JSON { .number(JSONNumber(value)) }

  var typeName: String {
    switch self {
    case .null: "null"
    case .bool: "boolean"
    case .number: "number"
    case .string: "string"
    case .array: "array"
    case .object: "object"
    }
  }
}

package struct JSONNumber: Sendable, Equatable {
  /// RFC 8259 number text, validated by the parser or produced by `init`.
  package let text: String

  init(validated text: String) { self.text = text }
  package init(_ value: Int64) { text = String(value) }

  package var int64: Int64? {
    if let exact = Int64(text) { return exact }
    // `1.0` and `1e3` are integral in JSON even though Int64 rejects them.
    guard let double = Double(text), double.rounded() == double, abs(double) < 9.0e15 else {
      return nil
    }
    return Int64(double)
  }
  package var double: Double? { Double(text) }
}

package struct JSONObject: Sendable, Equatable {
  package struct Member: Sendable, Equatable {
    package let key: String
    package var value: JSON
    package init(_ key: String, _ value: JSON) {
      self.key = key
      self.value = value
    }
  }
  package private(set) var members: [Member]

  package init(_ members: [Member] = []) { self.members = members }

  package init(_ pairs: KeyValuePairs<String, JSON>) {
    members = pairs.map { Member($0.key, $0.value) }
  }

  package subscript(key: String) -> JSON? {
    get { members.first(where: { $0.key == key })?.value }
    set {
      if let index = members.firstIndex(where: { $0.key == key }) {
        if let newValue { members[index].value = newValue } else { members.remove(at: index) }
      } else if let newValue {
        members.append(Member(key, newValue))
      }
    }
  }

  package var keys: [String] { members.map(\.key) }
  package var isEmpty: Bool { members.isEmpty }
}

/// Parse failures carry no input bytes: request bodies are guest-controlled.
package enum JSONParseError: Error, Sendable, Equatable {
  case tooLarge, tooDeep, duplicateKey, invalidUTF8, syntax, trailingData
}

/// A strict RFC 8259 parser for untrusted request and response bodies:
/// bounded input size and nesting depth, duplicate keys rejected at every
/// level, invalid UTF-8 and unpaired surrogates rejected, no trailing data.
package enum JSONParser {
  package struct Limits: Sendable {
    package let maxBytes: Int
    package let maxDepth: Int
    package init(maxBytes: Int, maxDepth: Int) {
      self.maxBytes = maxBytes
      self.maxDepth = maxDepth
    }
  }

  package static func parse(_ bytes: [UInt8], limits: Limits) throws(JSONParseError) -> JSON {
    guard bytes.count <= limits.maxBytes else { throw .tooLarge }
    let input = bytes.span
    var cursor = Cursor(maxDepth: limits.maxDepth)
    cursor.skipWhitespace(in: input)
    let value = try cursor.value(in: input, depth: 0)
    cursor.skipWhitespace(in: input)
    guard cursor.index == input.count else { throw .trailingData }
    return value
  }

  /// Keeps only the position; every call borrows the input from `parse`.
  private struct Cursor {
    let maxDepth: Int
    var index = 0

    init(maxDepth: Int) { self.maxDepth = maxDepth }

    mutating func skipWhitespace(in bytes: Span<UInt8>) {
      while index < bytes.count {
        switch bytes[index] {
        case 0x20, 0x09, 0x0A, 0x0D: index += 1
        default: return
        }
      }
    }

    func peek(in bytes: Span<UInt8>) throws(JSONParseError) -> UInt8 {
      guard index < bytes.count else { throw .syntax }
      return bytes[index]
    }

    mutating func expect(_ literal: String, in bytes: Span<UInt8>) throws(JSONParseError) {
      for byte in literal.utf8 {
        guard index < bytes.count, bytes[index] == byte else { throw .syntax }
        index += 1
      }
    }

    mutating func value(in bytes: Span<UInt8>, depth: Int) throws(JSONParseError) -> JSON {
      switch try peek(in: bytes) {
      case UInt8(ascii: "{"): return try object(in: bytes, depth: depth + 1)
      case UInt8(ascii: "["): return try array(in: bytes, depth: depth + 1)
      case UInt8(ascii: "\""): return .string(try string(in: bytes))
      case UInt8(ascii: "t"):
        try expect("true", in: bytes)
        return .bool(true)
      case UInt8(ascii: "f"):
        try expect("false", in: bytes)
        return .bool(false)
      case UInt8(ascii: "n"):
        try expect("null", in: bytes)
        return .null
      default: return .number(try number(in: bytes))
      }
    }

    mutating func object(in bytes: Span<UInt8>, depth: Int) throws(JSONParseError) -> JSON {
      guard depth <= maxDepth else { throw .tooDeep }
      index += 1
      var members: [JSONObject.Member] = []
      var seen = Set<String>()
      skipWhitespace(in: bytes)
      if try peek(in: bytes) == UInt8(ascii: "}") {
        index += 1
        return .object(JSONObject(members))
      }
      while true {
        skipWhitespace(in: bytes)
        guard try peek(in: bytes) == UInt8(ascii: "\"") else { throw .syntax }
        let key = try string(in: bytes)
        guard seen.insert(key).inserted else { throw .duplicateKey }
        skipWhitespace(in: bytes)
        guard try peek(in: bytes) == UInt8(ascii: ":") else { throw .syntax }
        index += 1
        skipWhitespace(in: bytes)
        members.append(JSONObject.Member(key, try value(in: bytes, depth: depth)))
        skipWhitespace(in: bytes)
        switch try peek(in: bytes) {
        case UInt8(ascii: ","): index += 1
        case UInt8(ascii: "}"):
          index += 1
          return .object(JSONObject(members))
        default: throw .syntax
        }
      }
    }

    mutating func array(in bytes: Span<UInt8>, depth: Int) throws(JSONParseError) -> JSON {
      guard depth <= maxDepth else { throw .tooDeep }
      index += 1
      var elements: [JSON] = []
      skipWhitespace(in: bytes)
      if try peek(in: bytes) == UInt8(ascii: "]") {
        index += 1
        return .array(elements)
      }
      while true {
        skipWhitespace(in: bytes)
        elements.append(try value(in: bytes, depth: depth))
        skipWhitespace(in: bytes)
        switch try peek(in: bytes) {
        case UInt8(ascii: ","): index += 1
        case UInt8(ascii: "]"):
          index += 1
          return .array(elements)
        default: throw .syntax
        }
      }
    }

    mutating func string(in bytes: Span<UInt8>) throws(JSONParseError) -> String {
      index += 1
      var out: [UInt8] = []
      while true {
        guard index < bytes.count else { throw .syntax }
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "\""):
          index += 1
          guard let text = String(validating: out, as: UTF8.self) else { throw .invalidUTF8 }
          return text
        case UInt8(ascii: "\\"):
          index += 1
          let escape = try peek(in: bytes)
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
            var scalar = try hex4(in: bytes)
            if (0xD800...0xDBFF).contains(scalar) {
              guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                bytes[index + 1] == UInt8(ascii: "u")
              else { throw .invalidUTF8 }
              index += 2
              let low = try hex4(in: bytes)
              guard (0xDC00...0xDFFF).contains(low) else { throw .invalidUTF8 }
              scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(scalar) {
              throw .invalidUTF8
            }
            guard let unicode = Unicode.Scalar(scalar) else { throw .invalidUTF8 }
            out.append(contentsOf: String(Character(unicode)).utf8)
          default: throw .syntax
          }
        default:
          guard byte >= 0x20 else { throw .syntax }
          out.append(byte)
          index += 1
        }
      }
    }

    mutating func hex4(in bytes: Span<UInt8>) throws(JSONParseError) -> UInt32 {
      guard index + 4 <= bytes.count else { throw .syntax }
      var value: UInt32 = 0
      for _ in 0..<4 {
        let byte = bytes[index]
        let digit: UInt32
        switch byte {
        case 0x30...0x39: digit = UInt32(byte - 0x30)
        case 0x41...0x46: digit = UInt32(byte - 0x37)
        case 0x61...0x66: digit = UInt32(byte - 0x57)
        default: throw .syntax
        }
        value = value * 16 + digit
        index += 1
      }
      return value
    }

    mutating func digits(in bytes: Span<UInt8>, into text: inout [UInt8]) -> Int {
      let start = index
      while index < bytes.count, (0x30...0x39).contains(bytes[index]) {
        text.append(bytes[index])
        index += 1
      }
      return index - start
    }

    mutating func number(in bytes: Span<UInt8>) throws(JSONParseError) -> JSONNumber {
      // Bounded: a number is at most the whole (size-limited) body.
      var text: [UInt8] = []
      if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
        text.append(bytes[index])
        index += 1
      }
      guard index < bytes.count else { throw .syntax }
      if bytes[index] == UInt8(ascii: "0") {
        text.append(bytes[index])
        index += 1
      } else if (0x31...0x39).contains(bytes[index]) {
        _ = digits(in: bytes, into: &text)
      } else {
        throw .syntax
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        text.append(bytes[index])
        index += 1
        guard digits(in: bytes, into: &text) > 0 else { throw .syntax }
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E")
      {
        text.append(bytes[index])
        index += 1
        if index < bytes.count,
          bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")
        {
          text.append(bytes[index])
          index += 1
        }
        guard digits(in: bytes, into: &text) > 0 else { throw .syntax }
      }
      return JSONNumber(validated: String(decoding: text, as: UTF8.self))
    }
  }
}

extension JSON {
  /// Compact serialization. Strings are escaped per RFC 8259; non-ASCII
  /// text is emitted as UTF-8.
  package var serialized: [UInt8] {
    var out: [UInt8] = []
    write(into: &out)
    return out
  }

  package var serializedString: String { String(decoding: serialized, as: UTF8.self) }

  func write(into out: inout [UInt8]) {
    switch self {
    case .null: out.append(contentsOf: "null".utf8)
    case .bool(let flag): out.append(contentsOf: (flag ? "true" : "false").utf8)
    case .number(let number): out.append(contentsOf: number.text.utf8)
    case .string(let text): Self.writeString(text, into: &out)
    case .array(let elements):
      out.append(UInt8(ascii: "["))
      for (offset, element) in elements.enumerated() {
        if offset > 0 { out.append(UInt8(ascii: ",")) }
        element.write(into: &out)
      }
      out.append(UInt8(ascii: "]"))
    case .object(let object):
      out.append(UInt8(ascii: "{"))
      for (offset, member) in object.members.enumerated() {
        if offset > 0 { out.append(UInt8(ascii: ",")) }
        Self.writeString(member.key, into: &out)
        out.append(UInt8(ascii: ":"))
        member.value.write(into: &out)
      }
      out.append(UInt8(ascii: "}"))
    }
  }

  static func writeString(_ text: String, into out: inout [UInt8]) {
    let hex = Array("0123456789abcdef".utf8)
    out.append(UInt8(ascii: "\""))
    for byte in text.utf8 {
      switch byte {
      case 0x22: out.append(contentsOf: [0x5C, 0x22])
      case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
      case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
      case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
      case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
      case 0x00..<0x20:
        out.append(contentsOf: "\\u00".utf8)
        out.append(hex[Int(byte >> 4)])
        out.append(hex[Int(byte & 0x0F)])
      default: out.append(byte)
      }
    }
    out.append(UInt8(ascii: "\""))
  }
}
