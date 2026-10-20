import Foundation

/// The declared GitHub Actions expression subset (spec section 9): literals,
/// context property/index access, object filters, the comparison and logical
/// operators, and a fixed function list. Parsing is bounded; error text
/// names the construct, never the evaluated data.
package indirect enum ExpressionNode: Sendable, Equatable, Hashable {
  case literal(JSONValue)
  /// A top-level named value (`github`, `matrix`, …), lowercased.
  case context(String)
  case property(ExpressionNode, String)
  case index(ExpressionNode, ExpressionNode)
  /// `a.*` / `a[*]`: an object filter producing an array.
  case wildcard(ExpressionNode)
  case not(ExpressionNode)
  case binary(ExpressionOperator, ExpressionNode, ExpressionNode)
  case and(ExpressionNode, ExpressionNode)
  case or(ExpressionNode, ExpressionNode)
  /// A function call; the name is lowercased.
  case call(String, [ExpressionNode])
}

package enum ExpressionOperator: String, Sendable, Equatable, Hashable {
  case equal = "=="
  case notEqual = "!="
  case less = "<"
  case lessOrEqual = "<="
  case greater = ">"
  case greaterOrEqual = ">="
}

/// Functions in the subset with their arity bounds.
package enum ExpressionFunction: String, Sendable, CaseIterable {
  case contains, startswith, endswith, format, join, tojson, fromjson, hashfiles
  case success, always, cancelled, failure

  package var arity: ClosedRange<Int> {
    switch self {
    case .contains, .startswith, .endswith: 2...2
    case .format: 1...64
    case .join: 1...2
    case .tojson, .fromjson: 1...1
    case .hashfiles: 1...32
    case .success, .always, .cancelled, .failure: 0...0
    }
  }

  package var isStatus: Bool {
    switch self {
    case .success, .always, .cancelled, .failure: true
    default: false
    }
  }
}

/// The named values (contexts) in the subset.
package enum ExpressionContextName: String, Sendable, CaseIterable, Hashable {
  case github, env, vars, job, jobs, steps, runner, secrets, strategy, matrix, needs, inputs
}

package enum Expression {
  package static let maxLength = 8_192
  package static let maxDepth = 50
  package static let maxTokens = 2_048

  /// Parses one expression (without `${{ }}`).
  package static func parse(_ text: String) throws(CIError) -> ExpressionNode {
    guard text.utf8.count <= maxLength else { throw fail("expression is too long") }
    var lexer = ExpressionLexer(Array(text.utf8))
    let tokens = try lexer.tokens()
    guard tokens.count <= maxTokens else { throw fail("expression has too many tokens") }
    var parser = ExpressionParser(tokens: tokens)
    let node = try parser.parseExpression(depth: 0)
    guard parser.atEnd else { throw fail("unexpected token after the expression") }
    return node
  }

  static func fail(_ message: String) -> CIError {
    CIError(.compatibilityRejected, "expression: \(message)")
  }
}

extension ExpressionNode {
  /// Every top-level context this expression reads.
  package var contexts: Set<String> {
    var out: Set<String> = []
    visit { node in
      if case .context(let name) = node { out.insert(name) }
    }
    return out
  }

  /// Every function this expression calls (lowercased).
  package var functions: Set<String> {
    var out: Set<String> = []
    visit { node in
      if case .call(let name, _) = node { out.insert(name) }
    }
    return out
  }

  package var callsStatusFunction: Bool {
    functions.contains { ExpressionFunction(rawValue: $0)?.isStatus ?? false }
  }

  package func visit(_ body: (ExpressionNode) -> Void) {
    body(self)
    switch self {
    case .literal, .context: break
    case .property(let base, _), .wildcard(let base), .not(let base): base.visit(body)
    case .index(let base, let index):
      base.visit(body)
      index.visit(body)
    case .binary(_, let a, let b), .and(let a, let b), .or(let a, let b):
      a.visit(body)
      b.visit(body)
    case .call(_, let arguments): for argument in arguments { argument.visit(body) }
    }
  }

  /// The static names read from one context (`secrets.X`, `secrets['X']`),
  /// and whether any read of it used a computed index.
  package func names(in context: String) -> (names: Set<String>, dynamic: Bool) {
    var names: Set<String> = []
    var dynamic = false
    func walk(_ node: ExpressionNode) {
      switch node {
      case .property(.context(let name), let key) where name == context:
        names.insert(key)
      case .index(.context(let name), let index) where name == context:
        if case .literal(.string(let key)) = index { names.insert(key) } else { dynamic = true }
        walk(index)
      case .wildcard(.context(let name)) where name == context:
        dynamic = true
      case .context(let name) where name == context:
        dynamic = true
      case .literal, .context: break
      case .property(let base, _), .wildcard(let base), .not(let base): walk(base)
      case .index(let base, let index):
        walk(base)
        walk(index)
      case .binary(_, let a, let b), .and(let a, let b), .or(let a, let b):
        walk(a)
        walk(b)
      case .call(_, let arguments): arguments.forEach(walk)
      }
    }
    walk(self)
    return (names, dynamic)
  }
}

// MARK: - Lexer

enum ExpressionToken: Equatable {
  case number(Double)
  case string(String)
  case identifier(String)
  case dot, star, leftBracket, rightBracket, leftParen, rightParen, comma
  case not
  case op(ExpressionOperator)
  case and, or
}

struct ExpressionLexer {
  let bytes: [UInt8]
  var index = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  func peek(_ offset: Int = 0) -> UInt8? {
    index + offset < bytes.count ? bytes[index + offset] : nil
  }

  static func isIdentifierStart(_ b: UInt8) -> Bool {
    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(b)
      || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(b) || b == UInt8(ascii: "_")
  }

  static func isIdentifierPart(_ b: UInt8) -> Bool {
    isIdentifierStart(b) || isDigit(b) || b == UInt8(ascii: "-")
  }

  static func isDigit(_ b: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) }

  mutating func tokens() throws(CIError) -> [ExpressionToken] {
    var out: [ExpressionToken] = []
    while let b = peek() {
      switch b {
      case 0x20, 0x09, 0x0A, 0x0D:
        index += 1
      case UInt8(ascii: "."):
        if let next = peek(1), Self.isDigit(next), !Self.endsValue(out.last) {
          out.append(.number(try number()))
        } else {
          index += 1
          out.append(.dot)
        }
      case UInt8(ascii: "*"):
        index += 1
        out.append(.star)
      case UInt8(ascii: "["):
        index += 1
        out.append(.leftBracket)
      case UInt8(ascii: "]"):
        index += 1
        out.append(.rightBracket)
      case UInt8(ascii: "("):
        index += 1
        out.append(.leftParen)
      case UInt8(ascii: ")"):
        index += 1
        out.append(.rightParen)
      case UInt8(ascii: ","):
        index += 1
        out.append(.comma)
      case UInt8(ascii: "!"):
        if peek(1) == UInt8(ascii: "=") {
          index += 2
          out.append(.op(.notEqual))
        } else {
          index += 1
          out.append(.not)
        }
      case UInt8(ascii: "="):
        guard peek(1) == UInt8(ascii: "=") else { throw Expression.fail("unexpected '='") }
        index += 2
        out.append(.op(.equal))
      case UInt8(ascii: "<"):
        if peek(1) == UInt8(ascii: "=") {
          index += 2
          out.append(.op(.lessOrEqual))
        } else {
          index += 1
          out.append(.op(.less))
        }
      case UInt8(ascii: ">"):
        if peek(1) == UInt8(ascii: "=") {
          index += 2
          out.append(.op(.greaterOrEqual))
        } else {
          index += 1
          out.append(.op(.greater))
        }
      case UInt8(ascii: "&"):
        guard peek(1) == UInt8(ascii: "&") else { throw Expression.fail("unexpected '&'") }
        index += 2
        out.append(.and)
      case UInt8(ascii: "|"):
        guard peek(1) == UInt8(ascii: "|") else { throw Expression.fail("unexpected '|'") }
        index += 2
        out.append(.or)
      case UInt8(ascii: "'"):
        out.append(.string(try string()))
      case UInt8(ascii: "-"), UInt8(ascii: "+"):
        guard let next = peek(1), Self.isDigit(next) || next == UInt8(ascii: "."),
          !Self.endsValue(out.last)
        else { throw Expression.fail("unexpected '\(Character(UnicodeScalar(b)))'") }
        out.append(.number(try number()))
      default:
        if Self.isDigit(b) {
          out.append(.number(try number()))
        } else if Self.isIdentifierStart(b) {
          let start = index
          while let c = peek(), Self.isIdentifierPart(c) { index += 1 }
          out.append(.identifier(String(decoding: bytes[start..<index], as: UTF8.self)))
        } else {
          throw Expression.fail("unexpected character")
        }
      }
    }
    return out
  }

  static func endsValue(_ token: ExpressionToken?) -> Bool {
    switch token {
    case .number?, .string?, .identifier?, .rightBracket?, .rightParen?, .star?: true
    default: false
    }
  }

  mutating func string() throws(CIError) -> String {
    index += 1
    var out: [UInt8] = []
    while true {
      guard let b = peek() else { throw Expression.fail("unterminated string literal") }
      index += 1
      if b == UInt8(ascii: "'") {
        if peek() == UInt8(ascii: "'") {
          out.append(b)
          index += 1
          continue
        }
        return String(decoding: out, as: UTF8.self)
      }
      out.append(b)
    }
  }

  mutating func number() throws(CIError) -> Double {
    let start = index
    if peek() == UInt8(ascii: "-") || peek() == UInt8(ascii: "+") { index += 1 }
    if peek() == UInt8(ascii: "0"), peek(1) == UInt8(ascii: "x") || peek(1) == UInt8(ascii: "X") {
      index += 2
      let digitsStart = index
      while let c = peek(), c < 0x80, Character(UnicodeScalar(c)).isHexDigit { index += 1 }
      let digits = String(decoding: bytes[digitsStart..<index], as: UTF8.self)
      guard !digits.isEmpty, digits.count <= 16, let value = UInt64(digits, radix: 16) else {
        throw Expression.fail("invalid hexadecimal literal")
      }
      if let next = peek(), Self.isIdentifierPart(next) {
        throw Expression.fail("invalid number literal")
      }
      return bytes[start] == UInt8(ascii: "-") ? -Double(value) : Double(value)
    }
    while let c = peek(),
      Self.isDigit(c) || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
        || ((c == UInt8(ascii: "-") || c == UInt8(ascii: "+"))
          && (bytes[index - 1] == UInt8(ascii: "e") || bytes[index - 1] == UInt8(ascii: "E")))
    {
      index += 1
    }
    if let next = peek(), Self.isIdentifierStart(next) {
      throw Expression.fail("invalid number literal")
    }
    let text = String(decoding: bytes[start..<index], as: UTF8.self)
    guard text.utf8.count <= 64, let value = Double(text), value.isFinite else {
      throw Expression.fail("invalid number literal")
    }
    return value
  }
}

// MARK: - Parser

struct ExpressionParser {
  let tokens: [ExpressionToken]
  var position = 0

  var atEnd: Bool { position >= tokens.count }

  func peek() -> ExpressionToken? { position < tokens.count ? tokens[position] : nil }

  mutating func advance() -> ExpressionToken? {
    defer { position += 1 }
    return peek()
  }

  mutating func expect(_ token: ExpressionToken, _ what: String) throws(CIError) {
    guard peek() == token else { throw Expression.fail("expected \(what)") }
    position += 1
  }

  static func guardDepth(_ depth: Int) throws(CIError) {
    guard depth <= Expression.maxDepth else { throw Expression.fail("expression nesting too deep") }
  }

  mutating func parseExpression(depth: Int) throws(CIError) -> ExpressionNode {
    try parseOr(depth: depth)
  }

  mutating func parseOr(depth: Int) throws(CIError) -> ExpressionNode {
    try Self.guardDepth(depth)
    var left = try parseAnd(depth: depth + 1)
    while peek() == .or {
      position += 1
      left = .or(left, try parseAnd(depth: depth + 1))
    }
    return left
  }

  mutating func parseAnd(depth: Int) throws(CIError) -> ExpressionNode {
    try Self.guardDepth(depth)
    var left = try parseEquality(depth: depth + 1)
    while peek() == .and {
      position += 1
      left = .and(left, try parseEquality(depth: depth + 1))
    }
    return left
  }

  mutating func parseEquality(depth: Int) throws(CIError) -> ExpressionNode {
    try Self.guardDepth(depth)
    var left = try parseComparison(depth: depth + 1)
    while case .op(let op)? = peek(), op == .equal || op == .notEqual {
      position += 1
      left = .binary(op, left, try parseComparison(depth: depth + 1))
    }
    return left
  }

  mutating func parseComparison(depth: Int) throws(CIError) -> ExpressionNode {
    try Self.guardDepth(depth)
    var left = try parseUnary(depth: depth + 1)
    while case .op(let op)? = peek(), op != .equal && op != .notEqual {
      position += 1
      left = .binary(op, left, try parseUnary(depth: depth + 1))
    }
    return left
  }

  mutating func parseUnary(depth: Int) throws(CIError) -> ExpressionNode {
    try Self.guardDepth(depth)
    if peek() == .not {
      position += 1
      return .not(try parseUnary(depth: depth + 1))
    }
    return try parsePostfix(depth: depth + 1)
  }

  mutating func parsePostfix(depth: Int) throws(CIError) -> ExpressionNode {
    try Self.guardDepth(depth)
    var node = try parsePrimary(depth: depth + 1)
    while true {
      switch peek() {
      case .dot?:
        position += 1
        switch advance() {
        case .identifier(let name)?: node = .property(node, name)
        case .star?: node = .wildcard(node)
        default: throw Expression.fail("expected a property name after '.'")
        }
      case .leftBracket?:
        position += 1
        if peek() == .star {
          position += 1
          node = .wildcard(node)
        } else {
          node = .index(node, try parseExpression(depth: depth + 1))
        }
        try expect(.rightBracket, "']'")
      default:
        return node
      }
    }
  }

  mutating func parsePrimary(depth: Int) throws(CIError) -> ExpressionNode {
    try Self.guardDepth(depth)
    switch advance() {
    case .number(let value)?: return .literal(numberValue(value))
    case .string(let value)?: return .literal(.string(value))
    case .leftParen?:
      let inner = try parseExpression(depth: depth + 1)
      try expect(.rightParen, "')'")
      return inner
    case .identifier(let name)?:
      switch name {
      case "true": return .literal(.bool(true))
      case "false": return .literal(.bool(false))
      case "null": return .literal(.null)
      default: break
      }
      let lowered = name.lowercased()
      if peek() == .leftParen {
        position += 1
        guard let function = ExpressionFunction(rawValue: lowered) else {
          throw Expression.fail("unknown function \(String(name.prefix(64)))")
        }
        var arguments: [ExpressionNode] = []
        if peek() != .rightParen {
          while true {
            arguments.append(try parseExpression(depth: depth + 1))
            if peek() == .comma {
              position += 1
              continue
            }
            break
          }
        }
        try expect(.rightParen, "')'")
        guard function.arity.contains(arguments.count) else {
          throw Expression.fail("wrong number of arguments to \(function.rawValue)()")
        }
        return .call(lowered, arguments)
      }
      guard ExpressionContextName(rawValue: lowered) != nil else {
        throw Expression.fail("unrecognized named-value \(String(name.prefix(64)))")
      }
      return .context(lowered)
    default:
      throw Expression.fail("expected a value")
    }
  }
}

/// Integral doubles become exact integers so equality and output match.
func numberValue(_ value: Double) -> JSONValue {
  if value.rounded() == value, abs(value) < 9e15 { return .integer(Int64(value)) }
  return .double(value)
}
