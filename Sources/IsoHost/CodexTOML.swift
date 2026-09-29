import Foundation

/// The TOML subset iso needs for Codex's own `~/.codex/config.toml`: the
/// host file (trusted, user-authored) is merged with iso-managed keys, and
/// the guest's copy (untrusted) is read only to carry its plugin and
/// project tables across a rewrite. Host configuration is JSONC; this type
/// exists only for that Codex file.
///
/// Values are kept as data: nothing parsed here is executed or used as a
/// host path. Tables print with sorted keys in the layout of the Rust
/// `toml` crate (`BTreeMap` tables): plain values first, then each table
/// or array of tables in key order, a header only where a table holds
/// plain values (or is empty).
indirect enum TOMLValue: Equatable, Sendable {
  case string(String)
  case integer(Int64)
  case float(Double)
  case boolean(Bool)
  /// Offset/local date-time, date or time, as written (normalized `T`/`Z`).
  case datetime(String)
  case array([TOMLValue])
  case table(TOMLTable)

  var stringValue: String? { if case .string(let value) = self { value } else { nil } }
  var tableValue: TOMLTable? { if case .table(let value) = self { value } else { nil } }

  /// Non-empty arrays whose every element is a table print as `[[...]]`.
  var arrayOfTables: [TOMLTable]? {
    guard case .array(let elements) = self, !elements.isEmpty else { return nil }
    let tables = elements.compactMap(\.tableValue)
    return tables.count == elements.count ? tables : nil
  }

  static func == (a: TOMLValue, b: TOMLValue) -> Bool {
    switch (a, b) {
    case (.string(let x), .string(let y)): x == y
    case (.integer(let x), .integer(let y)): x == y
    case (.float(let x), .float(let y)): x == y || (x.isNaN && y.isNaN)
    case (.boolean(let x), .boolean(let y)): x == y
    case (.datetime(let x), .datetime(let y)): x == y
    case (.array(let x), .array(let y)): x == y
    case (.table(let x), .table(let y)): x == y
    default: false
    }
  }
}

struct TOMLTable: Equatable, Sendable {
  private(set) var entries: [String: TOMLValue] = [:]

  init() {}

  init(_ pairs: [(String, TOMLValue)]) {
    for (key, value) in pairs { entries[key] = value }
  }

  subscript(key: String) -> TOMLValue? {
    get { entries[key] }
    set { entries[key] = newValue }
  }

  var isEmpty: Bool { entries.isEmpty }
  func contains(_ key: String) -> Bool { entries[key] != nil }

  @discardableResult
  mutating func remove(_ key: String) -> TOMLValue? { entries.removeValue(forKey: key) }

  /// Rust `String` order (bytes).
  var sortedKeys: [String] {
    entries.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
  }
}

// MARK: - Printing

extension TOMLTable {
  /// A whole document (`toml::to_string`).
  var document: String {
    var out = ""
    writeBody(&out, path: [])
    return out
  }

  private func isSection(_ value: TOMLValue) -> Bool {
    value.tableValue != nil || value.arrayOfTables != nil
  }

  private func writeBody(_ out: inout String, path: [String]) {
    let keys = sortedKeys
    for key in keys where !isSection(entries[key]!) {
      out += TOMLWriter.key(key) + " = " + TOMLWriter.inline(entries[key]!) + "\n"
    }
    for key in keys {
      let value = entries[key]!
      if let table = value.tableValue {
        table.writeSection(&out, path: path + [key])
      } else if let tables = value.arrayOfTables {
        for table in tables {
          if !out.isEmpty { out += "\n" }
          out += "[[" + (path + [key]).map(TOMLWriter.key).joined(separator: ".") + "]]\n"
          table.writeBody(&out, path: path + [key])
        }
      }
    }
  }

  private func writeSection(_ out: inout String, path: [String]) {
    let hasValues = entries.values.contains { !isSection($0) }
    if hasValues || entries.isEmpty {
      if !out.isEmpty { out += "\n" }
      out += "[" + path.map(TOMLWriter.key).joined(separator: ".") + "]\n"
    }
    writeBody(&out, path: path)
  }
}

enum TOMLWriter {
  static func key(_ key: String) -> String {
    let bare =
      !key.isEmpty
      && key.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
          || $0 == "_" || $0 == "-"
      }
    return bare ? key : string(key)
  }

  /// A basic string; every control character is escaped.
  static func string(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\t": out += "\\t"
      case "\n": out += "\\n"
      case "\u{0C}": out += "\\f"
      case "\r": out += "\\r"
      case _ where scalar.value < 0x20 || scalar.value == 0x7F:
        out += String(format: "\\u%04X", scalar.value)
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  static func float(_ value: Double) -> String {
    if value.isNaN { return "nan" }
    if value.isInfinite { return value < 0 ? "-inf" : "inf" }
    if value == value.rounded(), value.magnitude < 1e16 {
      let sign = value.sign == .minus ? "-" : ""
      return sign + String(Int64(value.magnitude)) + ".0"
    }
    return value.description
  }

  static func inline(_ value: TOMLValue) -> String {
    switch value {
    case .string(let text): string(text)
    case .integer(let number): String(number)
    case .float(let number): float(number)
    case .boolean(let flag): flag ? "true" : "false"
    case .datetime(let text): text
    case .array(let elements): "[" + elements.map(inline).joined(separator: ", ") + "]"
    case .table(let table):
      table.isEmpty
        ? "{}"
        : "{ "
          + table.sortedKeys.map { key($0) + " = " + inline(table[$0]!) }.joined(separator: ", ")
          + " }"
    }
  }
}

// MARK: - Parsing

struct TOMLParseError: Error, CustomStringConvertible, Equatable {
  let message: String
  let line: Int
  var description: String { "TOML parse error at line \(line): \(message)" }
}

extension TOMLTable {
  /// Parse a TOML 1.1 document. Nesting of arrays and inline tables is
  /// limited to `TOMLParser.maxDepth`.
  static func parse(_ text: String) throws(TOMLParseError) -> TOMLTable {
    try withParserStack { () throws(TOMLParseError) in
      var parser = TOMLParser(bytes: Array(text.utf8))
      return try parser.document()
    }
  }
}

struct TOMLParser {
  static let maxDepth = 128

  let bytes: [UInt8]
  var index = 0
  var line = 1

  /// How a table came to exist, which decides whether it may be extended.
  enum Origin {
    case implicit, header, dotted, inline, arrayElement
  }

  /// Mutable build tree: tables remember their origin and arrays created by
  /// `[[...]]` stay appendable.
  final class Node {
    var origin: Origin
    var children: [String: Entry] = [:]
    init(_ origin: Origin) { self.origin = origin }
  }

  enum Entry {
    case value(TOMLValue)
    case table(Node)
    case tableArray([Node])
  }

  init(bytes: [UInt8]) { self.bytes = bytes }

  func fail(_ message: String) -> TOMLParseError { TOMLParseError(message: message, line: line) }

  var atEnd: Bool { index >= bytes.count }
  var current: UInt8? { index < bytes.count ? bytes[index] : nil }

  func peek(_ text: String) -> Bool {
    let expected = Array(text.utf8)
    return bytes.count - index >= expected.count
      && bytes[index..<index + expected.count].elementsEqual(expected)
  }

  mutating func document() throws(TOMLParseError) -> TOMLTable {
    let root = Node(.header)
    var table = root
    while true {
      skipBlank()
      guard let byte = current else { break }
      if byte == UInt8(ascii: "\n") || peek("\r\n") {
        try newline()
        continue
      }
      if byte == UInt8(ascii: "#") {
        try comment()
        continue
      }
      if byte == UInt8(ascii: "[") {
        if peek("[[") {
          index += 2
          skipBlank()
          let path = try key()
          skipBlank()
          guard peek("]]") else { throw fail("expected `]]`") }
          index += 2
          table = try appendArrayTable(root, path)
        } else {
          index += 1
          skipBlank()
          let path = try key()
          skipBlank()
          guard current == UInt8(ascii: "]") else { throw fail("expected `]`") }
          index += 1
          table = try defineTable(root, path)
        }
      } else {
        try keyValue(into: table, depth: 0)
      }
      try endOfLine()
    }
    return Self.build(root)
  }

  static func build(_ node: Node) -> TOMLTable {
    var table = TOMLTable()
    for (key, entry) in node.children {
      switch entry {
      case .value(let value): table[key] = value
      case .table(let child): table[key] = .table(build(child))
      case .tableArray(let nodes): table[key] = .array(nodes.map { .table(build($0)) })
      }
    }
    return table
  }

  // MARK: Tables

  /// Walk `path` (all but the last key) from `root`, creating implicit
  /// tables and descending into the last element of a table array.
  func descend(_ root: Node, _ path: ArraySlice<String>) throws(TOMLParseError) -> Node {
    var node = root
    for key in path {
      switch node.children[key] {
      case nil:
        let child = Node(.implicit)
        node.children[key] = .table(child)
        node = child
      case .table(let child)?:
        guard child.origin != .inline else { throw fail("cannot extend inline table `\(key)`") }
        node = child
      case .tableArray(let nodes)?:
        node = nodes[nodes.count - 1]
      case .value?:
        throw fail("key `\(key)` is not a table")
      }
    }
    return node
  }

  func defineTable(_ root: Node, _ path: [String]) throws(TOMLParseError) -> Node {
    let parent = try descend(root, path.dropLast())
    let last = path[path.count - 1]
    switch parent.children[last] {
    case nil:
      let node = Node(.header)
      parent.children[last] = .table(node)
      return node
    case .table(let node)?:
      guard node.origin == .implicit else { throw fail("duplicate table `\(last)`") }
      node.origin = .header
      return node
    default:
      throw fail("duplicate key `\(last)`")
    }
  }

  func appendArrayTable(_ root: Node, _ path: [String]) throws(TOMLParseError) -> Node {
    let parent = try descend(root, path.dropLast())
    let last = path[path.count - 1]
    let node = Node(.arrayElement)
    switch parent.children[last] {
    case nil: parent.children[last] = .tableArray([node])
    case .tableArray(let nodes)?: parent.children[last] = .tableArray(nodes + [node])
    default: throw fail("duplicate key `\(last)`")
    }
    return node
  }

  mutating func keyValue(into table: Node, depth: Int) throws(TOMLParseError) {
    let path = try key()
    skipBlank()
    guard current == UInt8(ascii: "=") else { throw fail("expected `=`") }
    index += 1
    skipBlank()
    let parsed = try value(depth: depth)
    var node = table
    for key in path.dropLast() {
      switch node.children[key] {
      case nil:
        let child = Node(.dotted)
        node.children[key] = .table(child)
        node = child
      case .table(let child)? where child.origin == .dotted || child.origin == .implicit:
        node = child
      default:
        throw fail("cannot extend `\(key)` with a dotted key")
      }
    }
    let last = path[path.count - 1]
    guard node.children[last] == nil else { throw fail("duplicate key `\(last)`") }
    if case .table(let inline) = parsed {
      node.children[last] = .table(Self.frozen(inline))
    } else {
      node.children[last] = .value(parsed)
    }
  }

  /// An inline table as a node that can no longer be extended.
  static func frozen(_ table: TOMLTable) -> Node {
    let node = Node(.inline)
    for key in table.sortedKeys {
      node.children[key] = .value(table[key]!)
    }
    return node
  }

  // MARK: Keys

  mutating func key() throws(TOMLParseError) -> [String] {
    var parts: [String] = []
    while true {
      skipBlank()
      guard let byte = current else { throw fail("expected a key") }
      if byte == UInt8(ascii: "\"") {
        guard !peek("\"\"\"") else { throw fail("multi-line strings are not keys") }
        parts.append(try basicString())
      } else if byte == UInt8(ascii: "'") {
        guard !peek("'''") else { throw fail("multi-line strings are not keys") }
        parts.append(try literalString())
      } else {
        let start = index
        while let byte = current, Self.isBareKey(byte) { index += 1 }
        guard index > start else { throw fail("expected a key") }
        parts.append(String(decoding: bytes[start..<index], as: UTF8.self))
      }
      skipBlank()
      guard current == UInt8(ascii: ".") else { return parts }
      // Each segment is a table level: dotted keys and headers count
      // against the same nesting limit as arrays and inline tables.
      guard parts.count < Self.maxDepth else { throw fail("recursion limit exceeded") }
      index += 1
    }
  }

  static func isBareKey(_ byte: UInt8) -> Bool {
    (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x41 && byte <= 0x5A)
      || (byte >= 0x30 && byte <= 0x39) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
  }

  // MARK: Whitespace, comments, line ends

  mutating func skipBlank() {
    while let byte = current, byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") {
      index += 1
    }
  }

  mutating func newline() throws(TOMLParseError) {
    if current == UInt8(ascii: "\r") {
      guard peek("\r\n") else { throw fail("bare carriage return") }
      index += 1
    }
    index += 1
    line += 1
  }

  mutating func comment() throws(TOMLParseError) {
    index += 1
    while let byte = current, byte != UInt8(ascii: "\n") {
      if byte == UInt8(ascii: "\r") && peek("\r\n") { break }
      if (byte < 0x20 && byte != UInt8(ascii: "\t")) || byte == 0x7F {
        throw fail("control character in comment")
      }
      index += 1
    }
  }

  mutating func endOfLine() throws(TOMLParseError) {
    skipBlank()
    if current == UInt8(ascii: "#") { try comment() }
    guard !atEnd else { return }
    guard current == UInt8(ascii: "\n") || peek("\r\n") else {
      throw fail("expected a newline after the value")
    }
    try newline()
  }

  /// Whitespace, newlines and comments inside arrays and inline tables.
  mutating func skipTrivia() throws(TOMLParseError) {
    while let byte = current {
      if byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t") {
        index += 1
      } else if byte == UInt8(ascii: "\n") || peek("\r\n") {
        try newline()
      } else if byte == UInt8(ascii: "#") {
        try comment()
      } else {
        return
      }
    }
  }

  // MARK: Values

  mutating func value(depth: Int) throws(TOMLParseError) -> TOMLValue {
    guard let byte = current else { throw fail("expected a value") }
    switch byte {
    case UInt8(ascii: "\""):
      return .string(peek("\"\"\"") ? try multilineBasicString() : try basicString())
    case UInt8(ascii: "'"):
      return .string(peek("'''") ? try multilineLiteralString() : try literalString())
    case UInt8(ascii: "["):
      guard depth < Self.maxDepth else { throw fail("nesting is too deep") }
      index += 1
      var elements: [TOMLValue] = []
      while true {
        try skipTrivia()
        if current == UInt8(ascii: "]") {
          index += 1
          return .array(elements)
        }
        elements.append(try value(depth: depth + 1))
        try skipTrivia()
        if current == UInt8(ascii: ",") {
          index += 1
        } else if current != UInt8(ascii: "]") {
          throw fail("expected `,` or `]` in array")
        }
      }
    case UInt8(ascii: "{"):
      guard depth < Self.maxDepth else { throw fail("nesting is too deep") }
      index += 1
      let node = Node(.inline)
      while true {
        try skipTrivia()
        if current == UInt8(ascii: "}") {
          index += 1
          return .table(Self.build(node))
        }
        try keyValue(into: node, depth: depth + 1)
        try skipTrivia()
        if current == UInt8(ascii: ",") {
          index += 1
        } else if current != UInt8(ascii: "}") {
          throw fail("expected `,` or `}` in inline table")
        }
      }
    case UInt8(ascii: "t"):
      guard peek("true") else { throw fail("invalid value") }
      index += 4
      return .boolean(true)
    case UInt8(ascii: "f"):
      guard peek("false") else { throw fail("invalid value") }
      index += 5
      return .boolean(false)
    default:
      return try scalar()
    }
  }

  /// Numbers, `inf`/`nan`, and dates/times.
  mutating func scalar() throws(TOMLParseError) -> TOMLValue {
    let start = index
    func isTokenByte(_ byte: UInt8) -> Bool {
      Self.isBareKey(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
        || byte == UInt8(ascii: ":")
    }
    while let byte = current, isTokenByte(byte) { index += 1 }
    // A date and time may be separated by one space.
    if index - start == 10, current == UInt8(ascii: " "), index + 1 < bytes.count,
      bytes[index + 1] >= 0x30 && bytes[index + 1] <= 0x39,
      Self.isDate(Array(bytes[start..<index]))
    {
      index += 1
      while let byte = current, isTokenByte(byte) { index += 1 }
    }
    let token = String(decoding: bytes[start..<index], as: UTF8.self)
    guard !token.isEmpty else { throw fail("invalid value") }
    if let value = Self.number(token) { return value }
    if let value = Self.datetime(token) { return .datetime(value) }
    throw fail("invalid value `\(token)`")
  }

  static func isDigits(_ bytes: ArraySlice<UInt8>) -> Bool {
    !bytes.isEmpty && bytes.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
  }

  static func isDate(_ bytes: [UInt8]) -> Bool {
    bytes.count == 10 && isDigits(bytes[0..<4]) && bytes[4] == UInt8(ascii: "-")
      && isDigits(bytes[5..<7]) && bytes[7] == UInt8(ascii: "-") && isDigits(bytes[8..<10])
  }

  /// `HH:MM[:SS[.frac]]` (seconds optional in TOML 1.1).
  static func isTime(_ bytes: ArraySlice<UInt8>) -> Bool {
    let bytes = Array(bytes)
    guard bytes.count >= 5, isDigits(bytes[0..<2]), bytes[2] == UInt8(ascii: ":"),
      isDigits(bytes[3..<5])
    else { return false }
    var rest = bytes[5...]
    guard !rest.isEmpty else { return true }
    guard rest.first == UInt8(ascii: ":"), rest.count >= 3, isDigits(rest.dropFirst().prefix(2))
    else { return false }
    rest = rest.dropFirst(3)
    guard !rest.isEmpty else { return true }
    return rest.first == UInt8(ascii: ".") && isDigits(rest.dropFirst())
  }

  static func datetime(_ token: String) -> String? {
    var bytes = Array(token.utf8)
    if bytes.count >= 11, isDate(Array(bytes[0..<10])),
      bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: "t")
        || bytes[10] == UInt8(ascii: " ")
    {
      bytes[10] = UInt8(ascii: "T")
      var time = bytes[11...]
      if time.last == UInt8(ascii: "Z") || time.last == UInt8(ascii: "z") {
        bytes[bytes.count - 1] = UInt8(ascii: "Z")
        time = time.dropLast()
      } else if time.count > 6,
        time[time.endIndex - 6] == UInt8(ascii: "+")
          || time[time.endIndex - 6] == UInt8(ascii: "-"),
        isDigits(time.suffix(5).prefix(2)), time[time.endIndex - 3] == UInt8(ascii: ":"),
        isDigits(time.suffix(2))
      {
        time = time.dropLast(6)
      }
      return isTime(time) ? String(decoding: bytes, as: UTF8.self) : nil
    }
    if isDate(bytes) { return token }
    if isTime(bytes[...]) { return token }
    return nil
  }

  /// Integer or float literal.
  static func number(_ token: String) -> TOMLValue? {
    switch token {
    case "inf", "+inf": return .float(.infinity)
    case "-inf": return .float(-.infinity)
    case "nan", "+nan", "-nan": return .float(.nan)
    default: break
    }
    let bytes = Array(token.utf8)
    for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where token.hasPrefix(prefix) {
      let digits = bytes.dropFirst(2)
      guard underscoresBetweenDigits(digits, radix: radix) else { return nil }
      let clean = String(decoding: digits.filter { $0 != UInt8(ascii: "_") }, as: UTF8.self)
      return Int64(clean, radix: radix).map(TOMLValue.integer)
    }
    var body = bytes[...]
    if body.first == UInt8(ascii: "+") || body.first == UInt8(ascii: "-") {
      body = body.dropFirst()
    }
    // Split into integer part, fraction and exponent.
    let fractionStart = body.firstIndex(of: UInt8(ascii: "."))
    let exponentStart = body.firstIndex { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }
    let integerEnd = fractionStart ?? exponentStart ?? body.endIndex
    let integerPart = body[body.startIndex..<integerEnd]
    guard underscoresBetweenDigits(integerPart, radix: 10) else { return nil }
    if integerPart.count > 1 && integerPart.first == UInt8(ascii: "0") { return nil }
    let clean = String(decoding: bytes.filter { $0 != UInt8(ascii: "_") }, as: UTF8.self)
    if fractionStart == nil && exponentStart == nil {
      return Int64(clean.hasPrefix("+") ? String(clean.dropFirst()) : clean).map(TOMLValue.integer)
    }
    if let fractionStart {
      let end = exponentStart ?? body.endIndex
      guard fractionStart < end,
        underscoresBetweenDigits(body[(fractionStart + 1)..<end], radix: 10)
      else { return nil }
    }
    if let exponentStart {
      var exponent = body[(exponentStart + 1)...]
      if exponent.first == UInt8(ascii: "+") || exponent.first == UInt8(ascii: "-") {
        exponent = exponent.dropFirst()
      }
      guard underscoresBetweenDigits(exponent, radix: 10) else { return nil }
    }
    guard let value = Double(clean), value.isFinite else { return nil }
    return .float(value)
  }

  static func underscoresBetweenDigits(_ bytes: ArraySlice<UInt8>, radix: Int) -> Bool {
    guard let first = bytes.first, let last = bytes.last, first != UInt8(ascii: "_"),
      last != UInt8(ascii: "_")
    else { return false }
    var previousUnderscore = false
    for byte in bytes {
      if byte == UInt8(ascii: "_") {
        if previousUnderscore { return false }
        previousUnderscore = true
        continue
      }
      previousUnderscore = false
      guard let digit = Int(String(Unicode.Scalar(byte)), radix: radix), digit >= 0 else {
        return false
      }
    }
    return true
  }

  // MARK: Strings

  mutating func basicString() throws(TOMLParseError) -> String {
    index += 1
    var out = String.UnicodeScalarView()
    while let byte = current {
      if byte == UInt8(ascii: "\"") {
        index += 1
        return String(out)
      }
      if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
        throw fail("newline in a basic string")
      }
      if byte == UInt8(ascii: "\\") {
        try escape(into: &out)
        continue
      }
      try plainScalar(into: &out)
    }
    throw fail("unterminated string")
  }

  mutating func multilineBasicString() throws(TOMLParseError) -> String {
    index += 3
    if current == UInt8(ascii: "\n") || peek("\r\n") { try newline() }
    var out = String.UnicodeScalarView()
    while let byte = current {
      if peek("\"\"\"") {
        // Up to two quotes may end the content before the delimiter.
        var quotes = 3
        while quotes < 5, index + quotes < bytes.count, bytes[index + quotes] == UInt8(ascii: "\"")
        {
          quotes += 1
        }
        for _ in 0..<(quotes - 3) { out.append("\"") }
        index += quotes
        return String(out)
      }
      if byte == UInt8(ascii: "\n") || peek("\r\n") {
        try newline()
        out.append("\n")
        continue
      }
      if byte == UInt8(ascii: "\\") {
        // Line-ending backslash: trim whitespace and newlines that follow.
        var probe = index + 1
        while probe < bytes.count,
          bytes[probe] == UInt8(ascii: " ") || bytes[probe] == UInt8(ascii: "\t")
        {
          probe += 1
        }
        if probe < bytes.count,
          bytes[probe] == UInt8(ascii: "\n")
            || (bytes[probe] == UInt8(ascii: "\r") && probe + 1 < bytes.count
              && bytes[probe + 1] == UInt8(ascii: "\n"))
        {
          index = probe
          while let next = current {
            if next == UInt8(ascii: " ") || next == UInt8(ascii: "\t") {
              index += 1
            } else if next == UInt8(ascii: "\n") || peek("\r\n") {
              try newline()
            } else {
              break
            }
          }
          continue
        }
        try escape(into: &out)
        continue
      }
      try plainScalar(into: &out)
    }
    throw fail("unterminated string")
  }

  mutating func literalString() throws(TOMLParseError) -> String {
    index += 1
    var out = String.UnicodeScalarView()
    while let byte = current {
      if byte == UInt8(ascii: "'") {
        index += 1
        return String(out)
      }
      if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
        throw fail("newline in a literal string")
      }
      try plainScalar(into: &out)
    }
    throw fail("unterminated string")
  }

  mutating func multilineLiteralString() throws(TOMLParseError) -> String {
    index += 3
    if current == UInt8(ascii: "\n") || peek("\r\n") { try newline() }
    var out = String.UnicodeScalarView()
    while let byte = current {
      if peek("'''") {
        var quotes = 3
        while quotes < 5, index + quotes < bytes.count, bytes[index + quotes] == UInt8(ascii: "'") {
          quotes += 1
        }
        for _ in 0..<(quotes - 3) { out.append("'") }
        index += quotes
        return String(out)
      }
      if byte == UInt8(ascii: "\n") || peek("\r\n") {
        try newline()
        out.append("\n")
        continue
      }
      try plainScalar(into: &out)
    }
    throw fail("unterminated string")
  }

  /// One UTF-8 scalar of string content; control characters other than tab
  /// are rejected.
  mutating func plainScalar(into out: inout String.UnicodeScalarView) throws(TOMLParseError) {
    let byte = bytes[index]
    if (byte < 0x20 && byte != UInt8(ascii: "\t")) || byte == 0x7F {
      throw fail("control character in string")
    }
    let length =
      byte < 0x80 ? 1 : byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
    let end = min(index + length, bytes.count)
    out.append(contentsOf: String(decoding: bytes[index..<end], as: UTF8.self).unicodeScalars)
    index = end
  }

  mutating func escape(into out: inout String.UnicodeScalarView) throws(TOMLParseError) {
    index += 1
    guard let byte = current else { throw fail("unterminated escape") }
    index += 1
    switch byte {
    case UInt8(ascii: "b"): out.append("\u{08}")
    case UInt8(ascii: "t"): out.append("\t")
    case UInt8(ascii: "n"): out.append("\n")
    case UInt8(ascii: "f"): out.append("\u{0C}")
    case UInt8(ascii: "r"): out.append("\r")
    case UInt8(ascii: "e"): out.append("\u{1B}")
    case UInt8(ascii: "\""): out.append("\"")
    case UInt8(ascii: "\\"): out.append("\\")
    case UInt8(ascii: "x"): out.append(try hexScalar(2))
    case UInt8(ascii: "u"): out.append(try hexScalar(4))
    case UInt8(ascii: "U"): out.append(try hexScalar(8))
    default: throw fail("invalid escape")
    }
  }

  mutating func hexScalar(_ count: Int) throws(TOMLParseError) -> Unicode.Scalar {
    guard bytes.count - index >= count,
      bytes[index..<index + count].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }),
      let code = UInt32(String(decoding: bytes[index..<index + count], as: UTF8.self), radix: 16),
      let scalar = Unicode.Scalar(code)
    else { throw fail("invalid unicode escape") }
    index += count
    return scalar
  }
}
