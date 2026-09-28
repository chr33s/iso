/// Structural checks that must run before Foundation decodes a document.
///
/// Foundation's `JSONDecoder` accepts trailing commas and a byte-order mark,
/// silently keeps the first of two duplicate keys, and bounds nesting only at
/// its own internal depth. This pass rejects all of those and enforces the
/// resource limits before any value is materialized. It validates RFC 8259
/// grammar strictly but builds no values: decoding stays with Foundation.
public struct JSONLimits: Sendable, Equatable {
  /// Largest accepted document, in bytes (before comment stripping).
  public var maxBytes: Int
  /// Deepest accepted container nesting; the root container is depth 1.
  public var maxDepth: Int
  /// Most object members accepted across the whole document.
  public var maxKeys: Int
  /// Most elements accepted in any one array.
  public var maxArrayElements: Int
  /// Longest accepted number literal, in bytes.
  public var maxNumberLength: Int
  /// Longest accepted string literal (raw, escapes included), in bytes.
  public var maxStringBytes: Int

  public static let configuration = JSONLimits(
    maxBytes: 1 << 20, maxDepth: 32, maxKeys: 16_384, maxArrayElements: 4_096,
    maxNumberLength: 64, maxStringBytes: 64 << 10)

  public init(
    maxBytes: Int, maxDepth: Int, maxKeys: Int, maxArrayElements: Int, maxNumberLength: Int,
    maxStringBytes: Int
  ) {
    self.maxBytes = maxBytes
    self.maxDepth = maxDepth
    self.maxKeys = maxKeys
    self.maxArrayElements = maxArrayElements
    self.maxNumberLength = maxNumberLength
    self.maxStringBytes = maxStringBytes
  }
}

/// A position inside a JSON document: an object key or an array index.
public enum JSONPathComponent: Hashable, Sendable, CustomStringConvertible {
  case key(String)
  case index(Int)

  public var description: String {
    switch self {
    case .key(let key): key
    case .index(let index): "[\(index)]"
    }
  }
}

/// Human-readable path such as `claude.mcp_servers["a.b"].args[0]`. Keys that
/// are not plain identifiers are quoted so `"a.b"` stays distinct from `a.b`.
public func renderPath(_ path: [JSONPathComponent]) -> String {
  guard !path.isEmpty else { return "<root>" }
  var out = ""
  for component in path {
    switch component {
    case .index(let index): out += "[\(index)]"
    case .key(let key):
      let plain =
        !key.isEmpty
        && key.unicodeScalars.allSatisfy { $0.isASCIIIdentifier }
      if plain {
        out += out.isEmpty ? key : ".\(key)"
      } else {
        out += "[\(jsonQuoted(key))]"
      }
    }
  }
  return out
}

func jsonQuoted(_ key: String) -> String {
  var out = "\""
  for scalar in key.unicodeScalars {
    switch scalar {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case _ where scalar.value < 0x20 || scalar.value == 0x7F:
      out += "\\u" + String(scalar.value, radix: 16).leftPadded(to: 4)
    default: out.unicodeScalars.append(scalar)
    }
  }
  return out + "\""
}

extension String {
  func leftPadded(to width: Int) -> String {
    count >= width ? self : String(repeating: "0", count: width - count) + self
  }
}

extension Unicode.Scalar {
  var isASCIIIdentifier: Bool {
    ("a"..."z").contains(self) || ("A"..."Z").contains(self) || ("0"..."9").contains(self)
      || self == "_" || self == "-"
  }
}

public struct JSONPreflightError: Error, Equatable, Sendable, CustomStringConvertible {
  public enum Kind: Sendable, Equatable {
    case tooLarge(limit: Int)
    case byteOrderMark
    case syntax(String)
    case duplicateKey(path: String)
    case tooDeep(limit: Int)
    case tooManyKeys(limit: Int)
    case arrayTooLong(path: String, limit: Int)
    case numberTooLong(path: String, limit: Int)
    case stringTooLong(path: String, limit: Int)
  }
  public let kind: Kind
  public let location: SourceLocation?

  public var description: String {
    let message =
      switch kind {
      case .tooLarge(let limit): "document exceeds \(limit) bytes"
      case .byteOrderMark: "document must not begin with a byte-order mark"
      case .syntax(let detail): "invalid JSON: \(detail)"
      case .duplicateKey(let path): "duplicate key \(path)"
      case .tooDeep(let limit): "nesting exceeds \(limit) levels"
      case .tooManyKeys(let limit): "document has more than \(limit) keys"
      case .arrayTooLong(let path, let limit): "\(path) has more than \(limit) elements"
      case .numberTooLong(let path, let limit): "number at \(path) is longer than \(limit) bytes"
      case .stringTooLong(let path, let limit): "string at \(path) is longer than \(limit) bytes"
      }
    return location.map { "\(message) at \($0)" } ?? message
  }
}

/// Paths of number literals written with a fraction or exponent, so decoding
/// can keep `1.0` distinct from `1` (Foundation decodes both as `Int64`).
public struct JSONPreflightResult: Sendable {
  public let fractionalNumberPaths: Set<[JSONPathComponent]>
}

public enum JSONPreflight {
  private enum Container {
    case object
    case array(count: Int)
  }

  /// Validates `bytes` (comment-free JSON) and returns number-literal kinds.
  public static func check(_ bytes: [UInt8], limits: JSONLimits) throws(JSONPreflightError)
    -> JSONPreflightResult
  {
    var scanner = Scanner(bytes: bytes, limits: limits)
    return try scanner.run()
  }

  private struct Scanner {
    let bytes: [UInt8]
    let limits: JSONLimits
    var index = 0
    var keyCount = 0
    var stack: [Container] = []
    /// Keys seen so far in each open object, innermost last; kept apart from
    /// `stack` so inserts mutate in place instead of copying the set.
    var objectKeys: [Set<String>] = []
    var path: [JSONPathComponent] = []
    var fractional: Set<[JSONPathComponent]> = []

    init(bytes: [UInt8], limits: JSONLimits) {
      self.bytes = bytes
      self.limits = limits
    }

    func fail(_ kind: JSONPreflightError.Kind, at offset: Int? = nil) -> JSONPreflightError {
      JSONPreflightError(
        kind: kind, location: SourceLocation.of(offset: offset ?? index, in: bytes))
    }

    mutating func skipWhitespace() {
      while index < bytes.count, JSONCScanner.isJSONWhitespace(bytes[index]) { index += 1 }
    }

    var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func run() throws(JSONPreflightError) -> JSONPreflightResult {
      guard bytes.count <= limits.maxBytes else {
        throw JSONPreflightError(kind: .tooLarge(limit: limits.maxBytes), location: nil)
      }
      if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
        throw JSONPreflightError(kind: .byteOrderMark, location: nil)
      }
      skipWhitespace()
      try value()
      // Iterative: containers push state instead of recursing, so hostile
      // nesting is bounded by `maxDepth`, not by the thread's stack.
      while !stack.isEmpty {
        skipWhitespace()
        switch stack[stack.count - 1] {
        case .object:
          try afterObjectMember()
        case .array(let count):
          try afterArrayElement(count: count)
        }
      }
      skipWhitespace()
      guard index == bytes.count else {
        throw fail(.syntax("unexpected data after the root value"))
      }
      return JSONPreflightResult(fractionalNumberPaths: fractional)
    }

    /// Parses one value; containers are opened here and closed by `run`.
    mutating func value() throws(JSONPreflightError) {
      skipWhitespace()
      guard let byte = current else { throw fail(.syntax("unexpected end of input")) }
      switch byte {
      case UInt8(ascii: "{"):
        try push(.object)
        index += 1
        skipWhitespace()
        if current == UInt8(ascii: "}") {
          index += 1
          pop()
        } else {
          try member()
        }
      case UInt8(ascii: "["):
        try push(.array(count: 0))
        index += 1
        skipWhitespace()
        if current == UInt8(ascii: "]") {
          index += 1
          pop()
        } else {
          try element(0)
        }
      case UInt8(ascii: "\""):
        _ = try string(decode: false)
        finishScalar()
      case UInt8(ascii: "t"): try literal("true")
      case UInt8(ascii: "f"): try literal("false")
      case UInt8(ascii: "n"): try literal("null")
      case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number()
      default: throw fail(.syntax("unexpected character"))
      }
    }

    mutating func push(_ container: Container) throws(JSONPreflightError) {
      guard stack.count < limits.maxDepth else { throw fail(.tooDeep(limit: limits.maxDepth)) }
      stack.append(container)
      if case .object = container { objectKeys.append([]) }
    }

    /// Closes the innermost container and the path component naming it.
    mutating func pop() {
      if case .object = stack.removeLast() { objectKeys.removeLast() }
      finishScalar()
    }

    /// A value is complete: drop the path component that addressed it.
    mutating func finishScalar() {
      if !stack.isEmpty { path.removeLast() }
    }

    mutating func member() throws(JSONPreflightError) {
      skipWhitespace()
      guard current == UInt8(ascii: "\"") else { throw fail(.syntax("expected an object key")) }
      let keyOffset = index
      let key = try string(decode: true)!
      keyCount += 1
      guard keyCount <= limits.maxKeys else {
        throw fail(.tooManyKeys(limit: limits.maxKeys), at: keyOffset)
      }
      // Swift `String` equality is canonical equivalence, matching how
      // Foundation keys a dictionary, so NFC/NFD spellings collide here too.
      guard objectKeys[objectKeys.count - 1].insert(key).inserted else {
        throw fail(.duplicateKey(path: renderPath(path + [.key(key)])), at: keyOffset)
      }
      skipWhitespace()
      guard current == UInt8(ascii: ":") else { throw fail(.syntax("expected ':'")) }
      index += 1
      path.append(.key(key))
      try value()
    }

    mutating func element(_ position: Int) throws(JSONPreflightError) {
      guard position < limits.maxArrayElements else {
        throw fail(.arrayTooLong(path: renderPath(path), limit: limits.maxArrayElements))
      }
      stack[stack.count - 1] = .array(count: position + 1)
      path.append(.index(position))
      try value()
    }

    mutating func afterObjectMember() throws(JSONPreflightError) {
      switch current {
      case UInt8(ascii: ","):
        index += 1
        try member()
      case UInt8(ascii: "}"):
        index += 1
        pop()
      default:
        throw fail(.syntax(current == nil ? "unexpected end of input" : "expected ',' or '}'"))
      }
    }

    mutating func afterArrayElement(count: Int) throws(JSONPreflightError) {
      switch current {
      case UInt8(ascii: ","):
        index += 1
        skipWhitespace()
        try element(count)
      case UInt8(ascii: "]"):
        index += 1
        pop()
      default:
        throw fail(.syntax(current == nil ? "unexpected end of input" : "expected ',' or ']'"))
      }
    }

    mutating func literal(_ word: String) throws(JSONPreflightError) {
      let expected = Array(word.utf8)
      guard index + expected.count <= bytes.count,
        bytes[index..<index + expected.count].elementsEqual(expected)
      else { throw fail(.syntax("unexpected character")) }
      index += expected.count
      finishScalar()
    }

    mutating func number() throws(JSONPreflightError) {
      let start = index
      var isFractional = false
      if current == UInt8(ascii: "-") { index += 1 }
      guard let first = current, isDigit(first) else { throw fail(.syntax("invalid number")) }
      if first == UInt8(ascii: "0") {
        index += 1
      } else {
        while let byte = current, isDigit(byte) { index += 1 }
      }
      if current == UInt8(ascii: ".") {
        isFractional = true
        index += 1
        guard let byte = current, isDigit(byte) else { throw fail(.syntax("invalid number")) }
        while let byte = current, isDigit(byte) { index += 1 }
      }
      if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
        isFractional = true
        index += 1
        if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
        guard let byte = current, isDigit(byte) else { throw fail(.syntax("invalid number")) }
        while let byte = current, isDigit(byte) { index += 1 }
      }
      guard index - start <= limits.maxNumberLength else {
        throw fail(.numberTooLong(path: renderPath(path), limit: limits.maxNumberLength), at: start)
      }
      if isFractional { fractional.insert(path) }
      finishScalar()
    }

    func isDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }

    /// Validates a string literal at `index`; returns its decoded value when
    /// `decode` is set (object keys), otherwise nil.
    mutating func string(decode: Bool) throws(JSONPreflightError) -> String? {
      let start = index
      index += 1
      var scalars = String.UnicodeScalarView()
      var rawStart = index
      func flushRaw(_ end: Int) {
        if decode, rawStart < end {
          scalars.append(
            contentsOf: String(decoding: bytes[rawStart..<end], as: UTF8.self).unicodeScalars)
        }
      }
      while true {
        guard let byte = current else { throw fail(.syntax("unterminated string"), at: start) }
        guard index - start <= limits.maxStringBytes else {
          throw fail(
            .stringTooLong(path: renderPath(path), limit: limits.maxStringBytes), at: start)
        }
        switch byte {
        case UInt8(ascii: "\""):
          flushRaw(index)
          index += 1
          return decode ? String(scalars) : nil
        case UInt8(ascii: "\\"):
          flushRaw(index)
          index += 1
          guard let escape = current else { throw fail(.syntax("unterminated string"), at: start) }
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
            let high = try hex4()
            if (0xD800...0xDBFF).contains(high) {
              guard current == UInt8(ascii: "\\"), index + 1 < bytes.count,
                bytes[index + 1] == UInt8(ascii: "u")
              else { throw fail(.syntax("unpaired surrogate escape")) }
              index += 2
              let low = try hex4()
              guard (0xDC00...0xDFFF).contains(low) else {
                throw fail(.syntax("unpaired surrogate escape"))
              }
              scalars.append(Unicode.Scalar(0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00))!)
            } else {
              guard let scalar = Unicode.Scalar(high) else {
                throw fail(.syntax("unpaired surrogate escape"))
              }
              scalars.append(scalar)
            }
          default: throw fail(.syntax("invalid escape sequence"))
          }
          rawStart = index
        case 0x00..<0x20:
          throw fail(.syntax("control character in string"))
        default:
          index += 1
        }
      }
    }

    mutating func hex4() throws(JSONPreflightError) -> UInt32 {
      guard index + 4 <= bytes.count else { throw fail(.syntax("invalid unicode escape")) }
      var value: UInt32 = 0
      for _ in 0..<4 {
        let byte = bytes[index]
        let digit: UInt8
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
        default: throw fail(.syntax("invalid unicode escape"))
        }
        value = value << 4 | UInt32(digit)
        index += 1
      }
      return value
    }
  }
}
