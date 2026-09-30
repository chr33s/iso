/// A parsed JSON value. Objects keep their member order so a re-serialized
/// document differs from its source only where policy changed it. Numbers
/// keep their validated source text; nothing is rounded through a Double on
/// the way upstream.
public indirect enum JSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(JSONNumber)
  case string(String)
  case array([JSON])
  case object(JSONObject)

  public var object: JSONObject? {
    if case .object(let object) = self { object } else { nil }
  }
  public var array: [JSON]? {
    if case .array(let array) = self { array } else { nil }
  }
  public var string: String? {
    if case .string(let string) = self { string } else { nil }
  }
  public var bool: Bool? {
    if case .bool(let bool) = self { bool } else { nil }
  }
  public var number: JSONNumber? {
    if case .number(let number) = self { number } else { nil }
  }

  public subscript(key: String) -> JSON? { object?[key] }

  public static func int(_ value: Int64) -> JSON { .number(JSONNumber(value)) }

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

public struct JSONNumber: Sendable, Equatable {
  /// RFC 8259 number text, validated by the parser or produced by `init`.
  public let text: String

  init(validated text: String) { self.text = text }
  public init(_ value: Int64) { text = String(value) }

  public var int64: Int64? {
    if let exact = Int64(text) { return exact }
    // `1.0` and `1e3` are integral in JSON even though Int64 rejects them.
    guard let double = Double(text), double.rounded() == double, abs(double) < 9.0e15 else {
      return nil
    }
    return Int64(double)
  }
  public var double: Double? { Double(text) }
}

public struct JSONObject: Sendable, Equatable {
  public struct Member: Sendable, Equatable {
    public let key: String
    public var value: JSON
    public init(_ key: String, _ value: JSON) {
      self.key = key
      self.value = value
    }
  }
  public private(set) var members: [Member]

  public init(_ members: [Member] = []) { self.members = members }

  public init(_ pairs: KeyValuePairs<String, JSON>) {
    members = pairs.map { Member($0.key, $0.value) }
  }

  public subscript(key: String) -> JSON? {
    get { members.first(where: { $0.key == key })?.value }
    set {
      if let index = members.firstIndex(where: { $0.key == key }) {
        if let newValue { members[index].value = newValue } else { members.remove(at: index) }
      } else if let newValue {
        members.append(Member(key, newValue))
      }
    }
  }

  public var keys: [String] { members.map(\.key) }
  public var isEmpty: Bool { members.isEmpty }
}

/// Parse failures carry no input bytes: request bodies are guest-controlled.
public enum JSONParseError: Error, Sendable, Equatable {
  case tooLarge, tooDeep, duplicateKey, invalidUTF8, syntax, trailingData
}

/// A strict RFC 8259 parser for untrusted request and response bodies:
/// bounded input size and nesting depth, duplicate keys rejected at every
/// level, invalid UTF-8 and unpaired surrogates rejected, no trailing data.
public struct JSONParser {
  public struct Limits: Sendable {
    public let maxBytes: Int
    public let maxDepth: Int
    public init(maxBytes: Int, maxDepth: Int) {
      self.maxBytes = maxBytes
      self.maxDepth = maxDepth
    }
  }

  public static func parse(_ bytes: [UInt8], limits: Limits) throws(JSONParseError) -> JSON {
    guard bytes.count <= limits.maxBytes else { throw .tooLarge }
    var result: Result<JSON, JSONParseError> = .failure(.syntax)
    bytes.withUnsafeBufferPointer { buffer in
      var parser = Cursor(bytes: buffer, maxDepth: limits.maxDepth)
      do {
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == buffer.count else { throw JSONParseError.trailingData }
        result = .success(value)
      } catch let error as JSONParseError {
        result = .failure(error)
      } catch {
        result = .failure(.syntax)
      }
    }
    return try result.get()
  }

  private struct Cursor {
    let bytes: UnsafeBufferPointer<UInt8>
    let maxDepth: Int
    var index = 0

    init(bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int) {
      self.bytes = bytes
      self.maxDepth = maxDepth
    }

    mutating func skipWhitespace() {
      while index < bytes.count {
        switch bytes[index] {
        case 0x20, 0x09, 0x0A, 0x0D: index += 1
        default: return
        }
      }
    }

    func peek() throws(JSONParseError) -> UInt8 {
      guard index < bytes.count else { throw .syntax }
      return bytes[index]
    }

    mutating func expect(_ literal: StaticString) throws(JSONParseError) {
      let count = literal.utf8CodeUnitCount
      guard index + count <= bytes.count else { throw .syntax }
      let start = literal.utf8Start
      for offset in 0..<count where bytes[index + offset] != start[offset] { throw .syntax }
      index += count
    }

    mutating func value(depth: Int) throws(JSONParseError) -> JSON {
      switch try peek() {
      case UInt8(ascii: "{"): return try object(depth: depth + 1)
      case UInt8(ascii: "["): return try array(depth: depth + 1)
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
      default: return .number(try number())
      }
    }

    mutating func object(depth: Int) throws(JSONParseError) -> JSON {
      guard depth <= maxDepth else { throw .tooDeep }
      index += 1
      var members: [JSONObject.Member] = []
      var seen = Set<String>()
      skipWhitespace()
      if try peek() == UInt8(ascii: "}") {
        index += 1
        return .object(JSONObject(members))
      }
      while true {
        skipWhitespace()
        guard try peek() == UInt8(ascii: "\"") else { throw .syntax }
        let key = try string()
        guard seen.insert(key).inserted else { throw .duplicateKey }
        skipWhitespace()
        guard try peek() == UInt8(ascii: ":") else { throw .syntax }
        index += 1
        skipWhitespace()
        members.append(JSONObject.Member(key, try value(depth: depth)))
        skipWhitespace()
        switch try peek() {
        case UInt8(ascii: ","): index += 1
        case UInt8(ascii: "}"):
          index += 1
          return .object(JSONObject(members))
        default: throw .syntax
        }
      }
    }

    mutating func array(depth: Int) throws(JSONParseError) -> JSON {
      guard depth <= maxDepth else { throw .tooDeep }
      index += 1
      var elements: [JSON] = []
      skipWhitespace()
      if try peek() == UInt8(ascii: "]") {
        index += 1
        return .array(elements)
      }
      while true {
        skipWhitespace()
        elements.append(try value(depth: depth))
        skipWhitespace()
        switch try peek() {
        case UInt8(ascii: ","): index += 1
        case UInt8(ascii: "]"):
          index += 1
          return .array(elements)
        default: throw .syntax
        }
      }
    }

    mutating func string() throws(JSONParseError) -> String {
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
          let escape = try peek()
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
            if (0xD800...0xDBFF).contains(scalar) {
              guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"),
                bytes[index + 1] == UInt8(ascii: "u")
              else { throw .invalidUTF8 }
              index += 2
              let low = try hex4()
              guard (0xDC00...0xDFFF).contains(low) else { throw .invalidUTF8 }
              scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00...0xDFFF).contains(scalar) {
              throw .invalidUTF8
            }
            guard let unicode = Unicode.Scalar(scalar) else { throw .invalidUTF8 }
            out.append(contentsOf: Array(String(Character(unicode)).utf8))
          default: throw .syntax
          }
        default:
          guard byte >= 0x20 else { throw .syntax }
          out.append(byte)
          index += 1
        }
      }
    }

    mutating func hex4() throws(JSONParseError) -> UInt32 {
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

    mutating func number() throws(JSONParseError) -> JSONNumber {
      let start = index
      if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
      guard index < bytes.count else { throw .syntax }
      if bytes[index] == UInt8(ascii: "0") {
        index += 1
      } else if (0x31...0x39).contains(bytes[index]) {
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
      } else {
        throw .syntax
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        index += 1
        let digits = index
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        guard index > digits else { throw .syntax }
      }
      if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E")
      {
        index += 1
        if index < bytes.count,
          bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-")
        {
          index += 1
        }
        let digits = index
        while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        guard index > digits else { throw .syntax }
      }
      // Bounded: a number is at most the whole (size-limited) body.
      return JSONNumber(validated: String(decoding: bytes[start..<index], as: UTF8.self))
    }
  }
}

extension JSON {
  /// Compact serialization. Strings are escaped per RFC 8259; non-ASCII
  /// text is emitted as UTF-8.
  public var serialized: [UInt8] {
    var out: [UInt8] = []
    write(into: &out)
    return out
  }

  public var serializedString: String { String(decoding: serialized, as: UTF8.self) }

  func write(into out: inout [UInt8]) {
    switch self {
    case .null: out.append(contentsOf: Array("null".utf8))
    case .bool(let flag): out.append(contentsOf: Array((flag ? "true" : "false").utf8))
    case .number(let number): out.append(contentsOf: Array(number.text.utf8))
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
        out.append(contentsOf: Array("\\u00".utf8))
        out.append(hex[Int(byte >> 4)])
        out.append(hex[Int(byte & 0x0F)])
      default: out.append(byte)
      }
    }
    out.append(UInt8(ascii: "\""))
  }
}
