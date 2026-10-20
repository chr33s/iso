import Foundation

/// A strict YAML 1.2 subset parser for administrator configuration and
/// workflow files. It is written in Swift deliberately (no C parser in the
/// credential-holding controller) and refuses, rather than approximates,
/// features outside the subset: anchors, aliases, tags, merge keys, complex
/// keys, directives, multiple documents, duplicate keys and tab indentation.
///
/// Supported: block mappings and sequences (including compact `- key: v`),
/// flow sequences and mappings, plain/single/double-quoted scalars with line
/// folding, literal and folded block scalars with chomping and indentation
/// indicators, and comments.
package indirect enum YAMLNode: Sendable, Equatable {
  case scalar(YAMLScalar)
  case sequence([YAMLNode], line: Int)
  case mapping([YAMLPair], line: Int)

  package var line: Int {
    switch self {
    case .scalar(let scalar): scalar.line
    case .sequence(_, let line), .mapping(_, let line): line
    }
  }

  package var scalar: YAMLScalar? {
    if case .scalar(let value) = self { return value }
    return nil
  }

  package var sequence: [YAMLNode]? {
    if case .sequence(let items, _) = self { return items }
    return nil
  }

  package var mapping: [YAMLPair]? {
    if case .mapping(let pairs, _) = self { return pairs }
    return nil
  }

  /// The value under `key` in a mapping (keys compare as written).
  package subscript(key: String) -> YAMLNode? {
    mapping?.first { $0.key.value == key }?.value
  }

  /// A plain empty / `null` / `~` scalar.
  package var isNull: Bool { scalar?.isNull ?? false }

  /// YAML 1.2 core-schema conversion: quoted scalars stay strings; plain
  /// scalars resolve to null, booleans, integers and floats.
  package var json: JSONValue {
    switch self {
    case .scalar(let scalar): scalar.resolved
    case .sequence(let items, _): .array(items.map(\.json))
    case .mapping(let pairs, _):
      .object(
        Dictionary(pairs.map { ($0.key.value, $0.value.json) }, uniquingKeysWith: { a, _ in a }))
    }
  }
}

package struct YAMLPair: Sendable, Equatable {
  package let key: YAMLScalar
  package let value: YAMLNode
}

package struct YAMLScalar: Sendable, Equatable, Hashable {
  package enum Style: String, Sendable {
    case plain, singleQuoted, doubleQuoted, literal, folded
  }

  package let value: String
  package let style: Style
  package let line: Int

  package var isNull: Bool {
    style == .plain && ["", "~", "null", "Null", "NULL"].contains(value)
  }

  package var bool: Bool? {
    guard style == .plain else { return nil }
    switch value {
    case "true", "True", "TRUE": return true
    case "false", "False", "FALSE": return false
    default: return nil
    }
  }

  package var int: Int64? {
    guard style == .plain else { return nil }
    if value.hasPrefix("0x"), let parsed = Int64(value.dropFirst(2), radix: 16) { return parsed }
    if value.hasPrefix("0o"), let parsed = Int64(value.dropFirst(2), radix: 8) { return parsed }
    let body = value.hasPrefix("-") || value.hasPrefix("+") ? value.dropFirst() : Substring(value)
    guard !body.isEmpty, body.allSatisfy(\.isASCIIDigit) else { return nil }
    return Int64(value.hasPrefix("+") ? String(value.dropFirst()) : value)
  }

  package var double: Double? {
    guard style == .plain else { return nil }
    switch value {
    case ".inf", ".Inf", ".INF", "+.inf": return .infinity
    case "-.inf", "-.Inf", "-.INF": return -.infinity
    case ".nan", ".NaN", ".NAN": return .nan
    default: break
    }
    let allowed = Set("0123456789+-.eE")
    guard value.contains(where: \.isASCIIDigit), value.allSatisfy({ allowed.contains($0) }) else {
      return nil
    }
    return Double(value)
  }

  package var resolved: JSONValue {
    if isNull { return .null }
    if let bool { return .bool(bool) }
    if let int { return .integer(int) }
    if let double, double.isFinite { return .double(double) }
    return .string(value)
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

package struct YAMLLimits: Sendable {
  package var maxBytes = 1 << 20
  package var maxDepth = 64
  package var maxNodes = 200_000
  package init() {}
}

package enum YAML {
  package static func parse(_ text: String, limits: YAMLLimits = YAMLLimits()) throws(CIError)
    -> YAMLNode
  {
    guard text.utf8.count <= limits.maxBytes else {
      throw CIError.invalid("YAML document too large")
    }
    var parser = YAMLParser(text: text, limits: limits)
    return try parser.document()
  }

  package static func parse(_ data: Data, limits: YAMLLimits = YAMLLimits()) throws(CIError)
    -> YAMLNode
  {
    guard let text = String(data: data, encoding: .utf8) else {
      throw CIError.invalid("YAML is not valid UTF-8")
    }
    return try parse(text, limits: limits)
  }
}

private struct YAMLParser {
  let lines: [[UInt8]]
  let limits: YAMLLimits
  var line = 0
  var col = 0
  var nodes = 0
  var depth = 0

  init(text: String, limits: YAMLLimits) {
    var lines: [[UInt8]] = []
    var current: [UInt8] = []
    for byte in text.utf8 {
      if byte == 0x0A {
        if current.last == 0x0D { current.removeLast() }
        lines.append(current)
        current = []
      } else {
        current.append(byte)
      }
    }
    if !current.isEmpty { lines.append(current) }
    if let first = lines.first, first.starts(with: [0xEF, 0xBB, 0xBF]) {
      lines[0] = Array(first.dropFirst(3))
    }
    self.lines = lines
    self.limits = limits
  }

  // MARK: Errors

  func fail(_ message: String) -> CIError {
    CIError.invalid("YAML line \(line + 1): \(message)")
  }

  // MARK: Cursor helpers

  var atEOF: Bool { line >= lines.count }

  func byte(_ l: Int, _ c: Int) -> UInt8? {
    guard l < lines.count, c < lines[l].count else { return nil }
    return lines[l][c]
  }

  var current: UInt8? { byte(line, col) }

  func peek(_ offset: Int) -> UInt8? { byte(line, col + offset) }

  static func isSpace(_ byte: UInt8?) -> Bool { byte == 0x20 }
  static func isBlank(_ byte: UInt8?) -> Bool { byte == nil || byte == 0x20 || byte == 0x09 }

  /// Whether the rest of the current line from `col` is blank or a comment.
  func restIsEmpty() -> Bool {
    var c = col
    while let b = byte(line, c), b == 0x20 || b == 0x09 { c += 1 }
    guard let b = byte(line, c) else { return true }
    return b == UInt8(ascii: "#")
  }

  mutating func skipInlineSpaces() {
    while let b = current, b == 0x20 || b == 0x09 { col += 1 }
  }

  func indentation(of l: Int) throws(CIError) -> Int? {
    var c = 0
    while let b = byte(l, c), b == 0x20 { c += 1 }
    guard let b = byte(l, c) else { return nil }
    if b == 0x09 {
      // A tab after the indentation is content-level whitespace; a tab as
      // indentation is refused.
      var probe = c
      while let t = byte(l, probe), t == 0x09 || t == 0x20 { probe += 1 }
      if byte(l, probe) == nil || byte(l, probe) == UInt8(ascii: "#") { return nil }
      throw CIError.invalid("YAML line \(l + 1): tabs are not allowed for indentation")
    }
    if b == UInt8(ascii: "#") { return nil }
    return c
  }

  /// Moves to the first content character of the next non-blank,
  /// non-comment line at or after `line`. Returns false at end of input.
  mutating func nextContentLine(from start: Int) throws(CIError) -> Bool {
    var l = start
    while l < lines.count {
      if let indent = try indentation(of: l) {
        if lines[l].starts(with: Array("---".utf8)) && indent == 0 && l > 0
          && (lines[l].count == 3 || lines[l][3] == 0x20)
        {
          throw CIError.invalid("YAML line \(l + 1): multiple documents are not supported")
        }
        if lines[l] == Array("...".utf8) {
          throw CIError.invalid("YAML line \(l + 1): document end markers are not supported")
        }
        line = l
        col = indent
        return true
      }
      l += 1
    }
    line = lines.count
    col = 0
    return false
  }

  mutating func finishLine() throws(CIError) {
    guard restIsEmpty() else { throw fail("unexpected content after value") }
    line += 1
    col = 0
  }

  mutating func count() throws(CIError) {
    nodes += 1
    guard nodes <= limits.maxNodes else { throw fail("document has too many nodes") }
  }

  // MARK: Document

  mutating func document() throws(CIError) -> YAMLNode {
    guard try nextContentLine(from: 0) else {
      return .scalar(YAMLScalar(value: "", style: .plain, line: 1))
    }
    if lines[line].first == UInt8(ascii: "%") { throw fail("directives are not supported") }
    if col == 0, lines[line].starts(with: Array("---".utf8)),
      lines[line].count == 3 || lines[line][3] == 0x20
    {
      col = 3
      if restIsEmpty() {
        guard try nextContentLine(from: line + 1) else {
          return .scalar(YAMLScalar(value: "", style: .plain, line: line + 1))
        }
      } else {
        skipInlineSpaces()
      }
    }
    let node = try blockNode(parentIndent: -1)
    if try nextContentLine(from: line) {
      throw fail("unexpected content at the top level")
    }
    return node
  }

  // MARK: Block nodes

  /// Parses the node whose first content character is at (line, col).
  /// `parentIndent` is the indentation of the enclosing collection.
  mutating func blockNode(parentIndent: Int) throws(CIError) -> YAMLNode {
    depth += 1
    defer { depth -= 1 }
    guard depth <= limits.maxDepth else { throw fail("nesting too deep") }
    try count()
    let indent = col
    guard let b = current else {
      return .scalar(YAMLScalar(value: "", style: .plain, line: line + 1))
    }
    switch b {
    case UInt8(ascii: "-") where Self.isBlank(peek(1)):
      return try blockSequence(indent: indent)
    case UInt8(ascii: "|"), UInt8(ascii: ">"):
      return .scalar(try blockScalar(parentIndent: parentIndent))
    case UInt8(ascii: "["), UInt8(ascii: "{"):
      let startLine = line
      let node = try flowNode(depth: 0)
      if line == startLine, try mappingIndicatorFollows() {
        throw fail("flow collections as mapping keys are not supported")
      }
      try finishLine()
      return node
    default:
      try refuseUnsupportedIndicator(b)
      if try lineHasMappingKey() { return try blockMapping(indent: indent) }
      return .scalar(try inlineScalar(parentIndent: parentIndent))
    }
  }

  func refuseUnsupportedIndicator(_ b: UInt8) throws(CIError) {
    switch b {
    case UInt8(ascii: "&"): throw fail("anchors are not supported")
    case UInt8(ascii: "*"): throw fail("aliases are not supported")
    case UInt8(ascii: "!"): throw fail("tags are not supported")
    case UInt8(ascii: "?") where Self.isBlank(peek(1)): throw fail("complex keys are not supported")
    case UInt8(ascii: "%"), UInt8(ascii: "@"), UInt8(ascii: "`"):
      throw fail("reserved indicator at the start of a scalar")
    default: break
    }
  }

  mutating func mappingIndicatorFollows() throws(CIError) -> Bool {
    var c = col
    while let b = byte(line, c), b == 0x20 { c += 1 }
    return byte(line, c) == UInt8(ascii: ":") && Self.isBlank(byte(line, c + 1))
  }

  /// Whether the current line, from `col`, is `key: ...` (a mapping entry).
  func lineHasMappingKey() throws(CIError) -> Bool {
    var probe = self
    guard (try? probe.mappingKey()) != nil else { return false }
    return true
  }

  /// Scans a mapping key at (line, col) through its `:` indicator.
  mutating func mappingKey() throws(CIError) -> YAMLScalar {
    let keyLine = line
    guard let b = current else { throw fail("expected a mapping key") }
    var key: YAMLScalar
    if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
      key = try quotedScalar(parentIndent: -1, singleLine: true)
    } else {
      try refuseUnsupportedIndicator(b)
      if b == UInt8(ascii: "[") || b == UInt8(ascii: "{") {
        throw fail("flow collections as mapping keys are not supported")
      }
      var c = col
      var out: [UInt8] = []
      while let ch = byte(line, c) {
        if ch == UInt8(ascii: ":") && Self.isBlank(byte(line, c + 1)) { break }
        if ch == UInt8(ascii: "#") && c > col && Self.isBlank(byte(line, c - 1)) {
          throw fail("expected a mapping key")
        }
        out.append(ch)
        c += 1
      }
      guard byte(line, c) == UInt8(ascii: ":") else { throw fail("expected a mapping key") }
      while out.last == 0x20 || out.last == 0x09 { out.removeLast() }
      guard !out.isEmpty else { throw fail("empty mapping key") }
      col = c
      key = YAMLScalar(
        value: String(decoding: out, as: UTF8.self), style: .plain, line: keyLine + 1)
    }
    skipInlineSpaces()
    guard current == UInt8(ascii: ":"), Self.isBlank(peek(1)) else {
      throw fail("expected ':' after mapping key")
    }
    col += 1
    if key.style == .plain && key.value == "<<" { throw fail("merge keys are not supported") }
    return key
  }

  mutating func blockMapping(indent: Int) throws(CIError) -> YAMLNode {
    let startLine = line + 1
    var pairs: [YAMLPair] = []
    var seen: Set<String> = []
    while true {
      let key = try mappingKey()
      guard seen.insert(key.value).inserted else {
        throw fail("duplicate mapping key \"\(CIError.bounded(String(key.value.prefix(64))))\"")
      }
      let value = try mappingValue(indent: indent)
      try count()
      pairs.append(YAMLPair(key: key, value: value))
      guard try nextContentLine(from: line) else { break }
      if col < indent { break }
      guard col == indent else { throw fail("bad indentation of a mapping entry") }
      if current == UInt8(ascii: "-") && Self.isBlank(peek(1)) {
        throw fail("a sequence item cannot follow a mapping entry at the same indentation")
      }
    }
    return .mapping(pairs, line: startLine)
  }

  /// The value after `key:`; (line, col) is just past the colon.
  mutating func mappingValue(indent: Int) throws(CIError) -> YAMLNode {
    skipInlineSpaces()
    if restIsEmpty() {
      let valueLine = line + 1
      guard try nextContentLine(from: line + 1) else {
        return .scalar(YAMLScalar(value: "", style: .plain, line: valueLine))
      }
      if col > indent { return try blockNode(parentIndent: indent) }
      // A block sequence may sit at the same indentation as its key.
      if col == indent, current == UInt8(ascii: "-"), Self.isBlank(peek(1)) {
        return try blockSequence(indent: indent)
      }
      // Empty value: leave the cursor on the next entry.
      return .scalar(YAMLScalar(value: "", style: .plain, line: valueLine))
    }
    guard let b = current else { throw fail("expected a value") }
    switch b {
    case UInt8(ascii: "|"), UInt8(ascii: ">"):
      return .scalar(try blockScalar(parentIndent: indent))
    case UInt8(ascii: "["), UInt8(ascii: "{"):
      let node = try flowNode(depth: 0)
      try finishLine()
      return node
    case UInt8(ascii: "-") where Self.isBlank(peek(1)):
      throw fail("a block sequence cannot start on the same line as its key")
    default:
      try refuseUnsupportedIndicator(b)
      if try lineHasMappingKey() { throw fail("nested mappings must start on a new line") }
      return .scalar(try inlineScalar(parentIndent: indent))
    }
  }

  mutating func blockSequence(indent: Int) throws(CIError) -> YAMLNode {
    let startLine = line + 1
    var items: [YAMLNode] = []
    while true {
      guard current == UInt8(ascii: "-"), Self.isBlank(peek(1)) else {
        throw fail("expected a sequence item")
      }
      col += 1
      skipInlineSpaces()
      if restIsEmpty() {
        let itemLine = line + 1
        if try nextContentLine(from: line + 1), col > indent {
          items.append(try blockNode(parentIndent: indent))
        } else {
          items.append(.scalar(YAMLScalar(value: "", style: .plain, line: itemLine)))
        }
      } else {
        // Compact nested node: its indentation is the column it starts at.
        items.append(try blockNode(parentIndent: indent))
      }
      guard try nextContentLine(from: line) else { break }
      if col < indent { break }
      if col == indent {
        if current == UInt8(ascii: "-") && Self.isBlank(peek(1)) { continue }
        break
      }
      throw fail("bad indentation of a sequence item")
    }
    return .sequence(items, line: startLine)
  }

  // MARK: Scalars

  /// A plain or quoted scalar starting at (line, col); leaves the cursor at
  /// the start of the line after it.
  mutating func inlineScalar(parentIndent: Int) throws(CIError) -> YAMLScalar {
    guard let b = current else { throw fail("expected a scalar") }
    if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
      let scalar = try quotedScalar(parentIndent: parentIndent, singleLine: false)
      try finishLine()
      return scalar
    }
    return try plainScalar(parentIndent: parentIndent)
  }

  mutating func plainScalar(parentIndent: Int) throws(CIError) -> YAMLScalar {
    let startLine = line + 1
    var text = try plainLineSegment()
    line += 1
    col = 0
    // Continuation lines: more indented than the parent, folded with spaces.
    var pendingBreaks = 0
    while line < lines.count {
      guard let indent = try indentation(of: line) else {
        if lines[line].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
          pendingBreaks += 1
          line += 1
          continue
        }
        break  // a comment line ends a plain scalar
      }
      guard indent > parentIndent else { break }
      col = indent
      if current == UInt8(ascii: "-") && Self.isBlank(peek(1)) && indent <= parentIndent + 1 {
        break
      }
      if try lineHasMappingKey() { throw fail("unexpected mapping entry inside a plain scalar") }
      let segment = try plainLineSegment()
      text += pendingBreaks > 0 ? String(repeating: "\n", count: pendingBreaks) : " "
      text += segment
      pendingBreaks = 0
      line += 1
      col = 0
    }
    col = 0
    return YAMLScalar(value: text, style: .plain, line: startLine)
  }

  /// One line of a plain scalar from `col`, up to a comment or end of line.
  mutating func plainLineSegment() throws(CIError) -> String {
    var out: [UInt8] = []
    while let b = current {
      if b == UInt8(ascii: "#") && (out.isEmpty || out.last == 0x20 || out.last == 0x09) { break }
      if b == UInt8(ascii: ":") && Self.isBlank(peek(1)) {
        throw fail("unexpected ': ' in a plain scalar; quote the value")
      }
      out.append(b)
      col += 1
    }
    while out.last == 0x20 || out.last == 0x09 { out.removeLast() }
    return String(decoding: out, as: UTF8.self)
  }

  /// Single- or double-quoted scalar; may fold across lines unless `singleLine`.
  mutating func quotedScalar(parentIndent: Int, singleLine: Bool) throws(CIError) -> YAMLScalar {
    let startLine = line + 1
    guard let quote = current else { throw fail("expected a quoted scalar") }
    let double = quote == UInt8(ascii: "\"")
    col += 1
    var out: [UInt8] = []
    while true {
      guard let b = current else {
        // End of line inside quotes: fold.
        guard !singleLine else { throw fail("unterminated quoted key") }
        while out.last == 0x20 || out.last == 0x09 { out.removeLast() }
        line += 1
        col = 0
        guard line < lines.count else { throw fail("unterminated quoted scalar") }
        var breaks = 0
        while line < lines.count, lines[line].allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
          breaks += 1
          line += 1
        }
        guard line < lines.count else { throw fail("unterminated quoted scalar") }
        if breaks == 0 {
          out.append(0x20)
        } else {
          out += [UInt8](repeating: 0x0A, count: breaks)
        }
        skipInlineSpaces()
        continue
      }
      if double {
        if b == UInt8(ascii: "\"") {
          col += 1
          break
        }
        if b == UInt8(ascii: "\\") {
          guard let e = peek(1) else {
            // An escaped line break joins the lines without a space.
            guard !singleLine else { throw fail("unterminated quoted key") }
            while out.last == 0x20 || out.last == 0x09 { out.removeLast() }
            line += 1
            col = 0
            guard line < lines.count else { throw fail("unterminated quoted scalar") }
            skipInlineSpaces()
            continue
          }
          col += 2
          switch e {
          case UInt8(ascii: "0"): out.append(0)
          case UInt8(ascii: "a"): out.append(0x07)
          case UInt8(ascii: "b"): out.append(0x08)
          case UInt8(ascii: "t"), 0x09: out.append(0x09)
          case UInt8(ascii: "n"): out.append(0x0A)
          case UInt8(ascii: "v"): out.append(0x0B)
          case UInt8(ascii: "f"): out.append(0x0C)
          case UInt8(ascii: "r"): out.append(0x0D)
          case UInt8(ascii: "e"): out.append(0x1B)
          case 0x20: out.append(0x20)
          case UInt8(ascii: "\""): out.append(0x22)
          case UInt8(ascii: "/"): out.append(0x2F)
          case UInt8(ascii: "\\"): out.append(0x5C)
          case UInt8(ascii: "N"): out += Array("\u{85}".utf8)
          case UInt8(ascii: "_"): out += Array("\u{A0}".utf8)
          case UInt8(ascii: "L"): out += Array("\u{2028}".utf8)
          case UInt8(ascii: "P"): out += Array("\u{2029}".utf8)
          case UInt8(ascii: "x"): out += try hexEscape(2)
          case UInt8(ascii: "u"): out += try hexEscape(4)
          case UInt8(ascii: "U"): out += try hexEscape(8)
          default: throw fail("invalid escape in a double-quoted scalar")
          }
          continue
        }
      } else if b == UInt8(ascii: "'") {
        if peek(1) == UInt8(ascii: "'") {
          out.append(b)
          col += 2
          continue
        }
        col += 1
        break
      }
      out.append(b)
      col += 1
    }
    return YAMLScalar(
      value: String(decoding: out, as: UTF8.self), style: double ? .doubleQuoted : .singleQuoted,
      line: startLine)
  }

  mutating func hexEscape(_ digits: Int) throws(CIError) -> [UInt8] {
    var value: UInt32 = 0
    for _ in 0..<digits {
      guard let b = current, let digit = UInt8(ascii: b) else {
        throw fail("invalid hex escape")
      }
      value = value * 16 + UInt32(digit)
      col += 1
    }
    guard let scalar = Unicode.Scalar(value) else { throw fail("invalid unicode escape") }
    return Array(String(scalar).utf8)
  }

  /// `|` / `>` block scalar with optional chomping and indentation indicators.
  mutating func blockScalar(parentIndent: Int) throws(CIError) -> YAMLScalar {
    let startLine = line + 1
    let folded = current == UInt8(ascii: ">")
    col += 1
    var chomp: UInt8? = nil
    var explicitIndent: Int? = nil
    for _ in 0..<2 {
      guard let b = current else { break }
      if b == UInt8(ascii: "-") || b == UInt8(ascii: "+") {
        guard chomp == nil else { throw fail("repeated chomping indicator") }
        chomp = b
        col += 1
      } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(b) {
        guard explicitIndent == nil else { throw fail("repeated indentation indicator") }
        explicitIndent = Int(b - UInt8(ascii: "0"))
        col += 1
      }
    }
    guard restIsEmpty() else { throw fail("unexpected content after a block scalar header") }
    line += 1
    col = 0
    let base = max(parentIndent, 0)
    var contentIndent: Int? = explicitIndent.map { (parentIndent < 0 ? 0 : parentIndent) + $0 }
    var bodyLines: [(text: [UInt8], blank: Bool)] = []
    while line < lines.count {
      let raw = lines[line]
      var spaces = 0
      while spaces < raw.count, raw[spaces] == 0x20 { spaces += 1 }
      let blank = spaces == raw.count || raw[spaces...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
      if blank {
        bodyLines.append((contentIndent.map { spaces > $0 ? Array(raw[$0...]) : [] } ?? [], true))
        line += 1
        continue
      }
      if contentIndent == nil {
        guard spaces > parentIndent || (parentIndent < 0 && spaces >= 0) else { break }
        if spaces <= base && parentIndent >= 0 { break }
        contentIndent = spaces
      }
      guard let indent = contentIndent, spaces >= indent else { break }
      if raw[spaces] == 0x09 && spaces == indent {
        // Tabs inside content are allowed after the indentation.
      }
      bodyLines.append((Array(raw[indent...]), false))
      line += 1
    }
    col = 0
    // Trailing blank lines belong to chomping.
    var trailing = 0
    while let last = bodyLines.last, last.blank {
      trailing += 1
      bodyLines.removeLast()
    }
    var text: [UInt8] = []
    if folded {
      var previousMoreIndented = false
      var pendingBlank = 0
      for (index, entry) in bodyLines.enumerated() {
        if entry.blank {
          pendingBlank += 1
          continue
        }
        let moreIndented = entry.text.first == 0x20 || entry.text.first == 0x09
        if index > 0 {
          if pendingBlank > 0 {
            text += [UInt8](
              repeating: 0x0A, count: pendingBlank + (moreIndented || previousMoreIndented ? 1 : 0))
          } else if moreIndented || previousMoreIndented {
            text.append(0x0A)
          } else {
            text.append(0x20)
          }
        } else if pendingBlank > 0 {
          text += [UInt8](repeating: 0x0A, count: pendingBlank)
        }
        pendingBlank = 0
        text += entry.text
        previousMoreIndented = moreIndented
      }
    } else {
      for (index, entry) in bodyLines.enumerated() {
        if index > 0 { text.append(0x0A) }
        text += entry.text
      }
    }
    if !bodyLines.isEmpty {
      switch chomp {
      case UInt8(ascii: "-"): break
      case UInt8(ascii: "+"): text += [UInt8](repeating: 0x0A, count: 1 + trailing)
      default: text.append(0x0A)
      }
    } else if chomp == UInt8(ascii: "+") {
      text += [UInt8](repeating: 0x0A, count: trailing)
    }
    return YAMLScalar(
      value: String(decoding: text, as: UTF8.self), style: folded ? .folded : .literal,
      line: startLine)
  }

  // MARK: Flow collections

  mutating func skipFlowWhitespace() throws(CIError) {
    while true {
      while let b = current, b == 0x20 || b == 0x09 { col += 1 }
      if let b = current, b == UInt8(ascii: "#"), col == 0 || Self.isBlank(byte(line, col - 1)) {
        col = lines[line].count
      }
      if current == nil {
        line += 1
        col = 0
        guard line < lines.count else { throw fail("unterminated flow collection") }
        continue
      }
      return
    }
  }

  mutating func flowNode(depth level: Int) throws(CIError) -> YAMLNode {
    guard depth + level <= limits.maxDepth else { throw fail("nesting too deep") }
    try count()
    let startLine = line + 1
    guard let open = current else { throw fail("expected a flow collection") }
    col += 1
    let isMapping = open == UInt8(ascii: "{")
    let close = isMapping ? UInt8(ascii: "}") : UInt8(ascii: "]")
    var items: [YAMLNode] = []
    var pairs: [YAMLPair] = []
    var seen: Set<String> = []
    while true {
      try skipFlowWhitespace()
      if current == close {
        col += 1
        break
      }
      if isMapping {
        let key = try flowScalar()
        guard key.style != .plain || !key.value.isEmpty else {
          throw fail("empty flow mapping key")
        }
        try skipFlowWhitespace()
        var value: YAMLNode = .scalar(YAMLScalar(value: "", style: .plain, line: line + 1))
        if current == UInt8(ascii: ":") {
          col += 1
          try skipFlowWhitespace()
          if current != UInt8(ascii: ","), current != close { value = try flowItem(level) }
        }
        guard seen.insert(key.value).inserted else { throw fail("duplicate mapping key") }
        pairs.append(YAMLPair(key: key, value: value))
      } else {
        let item = try flowItem(level)
        try skipFlowWhitespace()
        if current == UInt8(ascii: ":") {
          throw fail("single-pair mappings in flow sequences are not supported")
        }
        items.append(item)
      }
      try skipFlowWhitespace()
      if current == UInt8(ascii: ",") {
        col += 1
        continue
      }
      guard current == close else { throw fail("expected ',' or a closing bracket") }
      col += 1
      break
    }
    return isMapping ? .mapping(pairs, line: startLine) : .sequence(items, line: startLine)
  }

  mutating func flowItem(_ level: Int) throws(CIError) -> YAMLNode {
    guard let b = current else { throw fail("expected a flow item") }
    if b == UInt8(ascii: "[") || b == UInt8(ascii: "{") { return try flowNode(depth: level + 1) }
    try count()
    return .scalar(try flowScalar())
  }

  mutating func flowScalar() throws(CIError) -> YAMLScalar {
    guard let b = current else { throw fail("expected a scalar") }
    if b == UInt8(ascii: "\"") || b == UInt8(ascii: "'") {
      return try quotedScalar(parentIndent: -1, singleLine: false)
    }
    try refuseUnsupportedIndicator(b)
    let startLine = line + 1
    var out: [UInt8] = []
    while let c = current {
      if c == UInt8(ascii: ",") || c == UInt8(ascii: "[") || c == UInt8(ascii: "]")
        || c == UInt8(ascii: "{") || c == UInt8(ascii: "}")
      {
        break
      }
      if c == UInt8(ascii: ":") {
        let next = peek(1)
        if Self.isBlank(next) || next == UInt8(ascii: ",") || next == UInt8(ascii: "]")
          || next == UInt8(ascii: "}")
        {
          break
        }
      }
      if c == UInt8(ascii: "#") && (out.isEmpty || out.last == 0x20) { break }
      out.append(c)
      col += 1
    }
    while out.last == 0x20 || out.last == 0x09 { out.removeLast() }
    return YAMLScalar(value: String(decoding: out, as: UTF8.self), style: .plain, line: startLine)
  }
}

extension UInt8 {
  /// Hex digit value of an ASCII byte.
  fileprivate init?(ascii byte: UInt8) {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): self = byte - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): self = byte - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): self = byte - UInt8(ascii: "A") + 10
    default: return nil
    }
  }
}
