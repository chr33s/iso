import Foundation

/// The status a job-level or step-level `if:` is evaluated against.
package struct ExpressionStatus: Sendable, Equatable {
  /// No dependency (or previous step) failed or was cancelled.
  package var success: Bool
  /// A dependency (or previous step) failed.
  package var failure: Bool
  /// The run was cancelled.
  package var cancelled: Bool

  package init(success: Bool, failure: Bool, cancelled: Bool) {
    self.success = success
    self.failure = failure
    self.cancelled = cancelled
  }
}

/// The named values available to one evaluation. Missing contexts read as
/// null. `status` is set only where status functions are allowed.
package struct ExpressionContexts: Sendable, Equatable {
  package var values: [String: JSONValue]
  package var status: ExpressionStatus?

  package init(
    github: JSONValue? = nil, env: JSONValue? = nil, vars: JSONValue? = nil,
    job: JSONValue? = nil, jobs: JSONValue? = nil, steps: JSONValue? = nil,
    runner: JSONValue? = nil, secrets: JSONValue? = nil, strategy: JSONValue? = nil,
    matrix: JSONValue? = nil, needs: JSONValue? = nil, inputs: JSONValue? = nil,
    status: ExpressionStatus? = nil
  ) {
    var values: [String: JSONValue] = [:]
    let pairs: [(ExpressionContextName, JSONValue?)] = [
      (.github, github), (.env, env), (.vars, vars), (.job, job), (.jobs, jobs), (.steps, steps),
      (.runner, runner), (.secrets, secrets), (.strategy, strategy), (.matrix, matrix),
      (.needs, needs), (.inputs, inputs),
    ]
    for (name, value) in pairs { if let value { values[name.rawValue] = value } }
    self.values = values
    self.status = status
  }

  package subscript(name: ExpressionContextName) -> JSONValue? {
    get { values[name.rawValue] }
    set { values[name.rawValue] = newValue }
  }
}

/// Evaluates the expression subset with GitHub's coercion and truthiness
/// rules. Bounded: string results are capped, `fromJSON` uses strict limits.
package enum ExpressionEvaluator {
  package static let maxStringBytes = 1 << 20

  package static func evaluate(_ text: String, _ contexts: ExpressionContexts) throws(CIError)
    -> JSONValue
  {
    try evaluate(try Expression.parse(text), contexts)
  }

  package static func evaluate(_ node: ExpressionNode, _ contexts: ExpressionContexts)
    throws(CIError) -> JSONValue
  {
    try eval(node, contexts, depth: 0).json
  }

  /// Evaluates an `if:` condition to a boolean (GitHub truthiness).
  package static func condition(_ text: String, _ contexts: ExpressionContexts) throws(CIError)
    -> Bool
  {
    truthy(try evaluate(text, contexts))
  }

  // MARK: Values

  /// An intermediate value; `filtered` marks the result of an object filter
  /// so further property access maps over its elements.
  enum Value {
    case json(JSONValue)
    case filtered([JSONValue])

    var json: JSONValue {
      switch self {
      case .json(let value): value
      case .filtered(let items): .array(items)
      }
    }
  }

  static func fail(_ message: String) -> CIError {
    CIError(.invalidRequest, "expression: \(message)")
  }

  static func eval(_ node: ExpressionNode, _ contexts: ExpressionContexts, depth: Int)
    throws(CIError) -> Value
  {
    guard depth <= Expression.maxDepth * 2 else { throw fail("evaluation nesting too deep") }
    switch node {
    case .literal(let value):
      return .json(value)
    case .context(let name):
      return .json(contexts.values[name] ?? .null)
    case .property(let base, let name):
      switch try eval(base, contexts, depth: depth + 1) {
      case .json(let value): return .json(member(value, name))
      case .filtered(let items):
        return .filtered(
          items.compactMap { item in
            let value = member(item, name)
            return value == .null ? nil : value
          })
      }
    case .index(let base, let indexNode):
      let index = try eval(indexNode, contexts, depth: depth + 1).json
      switch try eval(base, contexts, depth: depth + 1) {
      case .json(let value): return .json(subscripted(value, index))
      case .filtered(let items):
        return .filtered(
          items.compactMap { item in
            let value = subscripted(item, index)
            return value == .null ? nil : value
          })
      }
    case .wildcard(let base):
      switch try eval(base, contexts, depth: depth + 1) {
      case .json(let value):
        switch value {
        case .array(let items): return .filtered(items)
        case .object(let members):
          return .filtered(members.keys.sorted().compactMap { members[$0] })
        default: return .filtered([])
        }
      case .filtered(let items):
        var out: [JSONValue] = []
        for item in items {
          switch item {
          case .array(let nested): out += nested
          case .object(let members): out += members.keys.sorted().compactMap { members[$0] }
          default: break
          }
        }
        return .filtered(out)
      }
    case .not(let inner):
      return .json(.bool(!truthy(try eval(inner, contexts, depth: depth + 1).json)))
    case .and(let a, let b):
      let left = try eval(a, contexts, depth: depth + 1).json
      guard truthy(left) else { return .json(left) }
      return .json(try eval(b, contexts, depth: depth + 1).json)
    case .or(let a, let b):
      let left = try eval(a, contexts, depth: depth + 1).json
      if truthy(left) { return .json(left) }
      return .json(try eval(b, contexts, depth: depth + 1).json)
    case .binary(let op, let a, let b):
      let left = try eval(a, contexts, depth: depth + 1).json
      let right = try eval(b, contexts, depth: depth + 1).json
      return .json(.bool(compare(op, left, right)))
    case .call(let name, let arguments):
      return .json(try call(name, arguments, contexts, depth: depth))
    }
  }

  /// Case-insensitive member lookup (exact match preferred).
  static func member(_ value: JSONValue, _ name: String) -> JSONValue {
    guard case .object(let members) = value else { return .null }
    if let exact = members[name] { return exact }
    let lowered = name.lowercased()
    for key in members.keys.sorted() where key.lowercased() == lowered {
      return members[key] ?? .null
    }
    return .null
  }

  static func subscripted(_ value: JSONValue, _ index: JSONValue) -> JSONValue {
    switch value {
    case .array(let items):
      let number = toNumber(index)
      guard number.isFinite, number >= 0, number < Double(items.count) else { return .null }
      let position = Int(number.rounded(.towardZero))
      return items[position]
    case .object:
      return member(value, toText(index))
    default:
      return .null
    }
  }

  // MARK: Coercion

  package static func truthy(_ value: JSONValue) -> Bool {
    switch value {
    case .null: false
    case .bool(let flag): flag
    case .integer(let number): number != 0
    case .double(let number): number != 0 && !number.isNaN
    case .string(let text): !text.isEmpty
    case .array, .object: true
    }
  }

  static func toNumber(_ value: JSONValue) -> Double {
    switch value {
    case .null: return 0
    case .bool(let flag): return flag ? 1 : 0
    case .integer(let number): return Double(number)
    case .double(let number): return number
    case .string(let text):
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return 0 }
      let negative = trimmed.hasPrefix("-")
      let body = negative || trimmed.hasPrefix("+") ? String(trimmed.dropFirst()) : trimmed
      if body.lowercased().hasPrefix("0x") {
        guard let parsed = UInt64(body.dropFirst(2), radix: 16) else { return .nan }
        return negative ? -Double(parsed) : Double(parsed)
      }
      if body.lowercased().hasPrefix("0o") {
        guard let parsed = UInt64(body.dropFirst(2), radix: 8) else { return .nan }
        return negative ? -Double(parsed) : Double(parsed)
      }
      let allowed = Set("0123456789.eE+-")
      guard body.allSatisfy({ allowed.contains($0) }), let parsed = Double(trimmed) else {
        if trimmed == "Infinity" { return .infinity }
        if trimmed == "-Infinity" { return -.infinity }
        return .nan
      }
      return parsed
    case .array, .object: return .nan
    }
  }

  /// GitHub's string conversion (used by format, join, contains, …).
  package static func toText(_ value: JSONValue) -> String {
    switch value {
    case .null: ""
    case .bool(let flag): flag ? "true" : "false"
    case .integer(let number): String(number)
    case .double(let number): numberText(number)
    case .string(let text): text
    case .array: "Array"
    case .object: "Object"
    }
  }

  static func numberText(_ number: Double) -> String {
    if number.isNaN { return "NaN" }
    if number.isInfinite { return number > 0 ? "Infinity" : "-Infinity" }
    if number.rounded() == number, abs(number) < 1e15 { return String(Int64(number)) }
    return "\(number)"
  }

  static func compare(_ op: ExpressionOperator, _ a: JSONValue, _ b: JSONValue) -> Bool {
    switch op {
    case .equal: return looseEqual(a, b)
    case .notEqual: return !looseEqual(a, b)
    default: break
    }
    let ordering: Int?
    if case .string(let x) = a, case .string(let y) = b {
      let left = x.uppercased()
      let right = y.uppercased()
      ordering =
        left == right ? 0 : (Array(left.utf8).lexicographicallyPrecedes(Array(right.utf8)) ? -1 : 1)
    } else {
      let x = toNumber(a)
      let y = toNumber(b)
      ordering = x.isNaN || y.isNaN ? nil : (x == y ? 0 : (x < y ? -1 : 1))
    }
    guard let ordering else { return false }
    switch op {
    case .less: return ordering < 0
    case .lessOrEqual: return ordering <= 0
    case .greater: return ordering > 0
    case .greaterOrEqual: return ordering >= 0
    case .equal, .notEqual: return false
    }
  }

  package static func looseEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
    switch (a, b) {
    case (.null, .null): return true
    case (.bool(let x), .bool(let y)): return x == y
    case (.string(let x), .string(let y)): return x.uppercased() == y.uppercased()
    case (.array, .array), (.object, .object):
      // Equal only when they are the same instance; values have no identity here.
      return false
    default:
      let x = toNumber(a)
      let y = toNumber(b)
      return !x.isNaN && !y.isNaN && x == y
    }
  }

  // MARK: Functions

  static func call(
    _ name: String, _ arguments: [ExpressionNode], _ contexts: ExpressionContexts, depth: Int
  )
    throws(CIError) -> JSONValue
  {
    guard let function = ExpressionFunction(rawValue: name) else { throw fail("unknown function") }
    if function.isStatus {
      guard let status = contexts.status else {
        throw fail("\(function.rawValue)() is not available here")
      }
      switch function {
      case .success: return .bool(status.success && !status.cancelled)
      case .always: return .bool(true)
      case .cancelled: return .bool(status.cancelled)
      case .failure: return .bool(status.failure && !status.cancelled)
      default: break
      }
    }
    if function == .hashfiles {
      throw CIError(.unsupported, "hashFiles() is evaluated by the runner, not the controller")
    }
    var values: [JSONValue] = []
    for argument in arguments { values.append(try eval(argument, contexts, depth: depth + 1).json) }
    switch function {
    case .contains:
      if case .array(let items) = values[0] {
        return .bool(items.contains { looseEqual($0, values[1]) })
      }
      return .bool(toText(values[0]).uppercased().contains(toText(values[1]).uppercased()))
    case .startswith:
      return .bool(toText(values[0]).uppercased().hasPrefix(toText(values[1]).uppercased()))
    case .endswith:
      return .bool(toText(values[0]).uppercased().hasSuffix(toText(values[1]).uppercased()))
    case .format:
      return .string(try format(toText(values[0]), values.dropFirst().map(toText)))
    case .join:
      let separator = values.count > 1 ? toText(values[1]) : ","
      switch values[0] {
      case .array(let items):
        let joined = items.map(toText).joined(separator: separator)
        guard joined.utf8.count <= maxStringBytes else { throw fail("join() result is too large") }
        return .string(joined)
      case .string(let text): return .string(text)
      default: return .string(toText(values[0]))
      }
    case .tojson:
      let text = prettyJSON(values[0])
      guard text.utf8.count <= maxStringBytes else { throw fail("toJSON() result is too large") }
      return .string(text)
    case .fromjson:
      let text = toText(values[0])
      do {
        return try StrictJSON.parse(text, limits: JSONLimits(maxBytes: maxStringBytes))
      } catch {
        throw fail("fromJSON() input is not valid JSON")
      }
    default:
      throw fail("unknown function")
    }
  }

  /// `format('{0} {{literal}}', x)`.
  package static func format(_ template: String, _ arguments: [String]) throws(CIError) -> String {
    var out = ""
    let characters = Array(template)
    var index = 0
    while index < characters.count {
      let c = characters[index]
      if c == "{" {
        if index + 1 < characters.count, characters[index + 1] == "{" {
          out.append("{")
          index += 2
          continue
        }
        var end = index + 1
        var digits = ""
        while end < characters.count, characters[end].isNumber, digits.count < 4 {
          digits.append(characters[end])
          end += 1
        }
        guard !digits.isEmpty, end < characters.count, characters[end] == "}",
          let position = Int(digits)
        else { throw fail("format() has an invalid placeholder") }
        guard position < arguments.count else {
          throw fail("format() placeholder index out of range")
        }
        out += arguments[position]
        index = end + 1
      } else if c == "}" {
        guard index + 1 < characters.count, characters[index + 1] == "}" else {
          throw fail("format() has an unescaped '}'")
        }
        out.append("}")
        index += 2
      } else {
        out.append(c)
        index += 1
      }
      guard out.utf8.count <= maxStringBytes else { throw fail("format() result is too large") }
    }
    return out
  }

  /// `toJSON` output: two-space indentation, sorted keys.
  package static func prettyJSON(_ value: JSONValue, indent: Int = 0) -> String {
    let pad = String(repeating: "  ", count: indent)
    let inner = String(repeating: "  ", count: indent + 1)
    switch value {
    case .array(let items):
      if items.isEmpty { return "[]" }
      return "[\n"
        + items.map { inner + prettyJSON($0, indent: indent + 1) }.joined(separator: ",\n")
        + "\n" + pad + "]"
    case .object(let members):
      if members.isEmpty { return "{}" }
      let keys = members.keys.sorted()
      return "{\n"
        + keys.map {
          inner + JSONValue.string($0).canonicalString + ": "
            + prettyJSON(members[$0] ?? .null, indent: indent + 1)
        }.joined(separator: ",\n") + "\n" + pad + "}"
    case .double(let number): return numberText(number)
    default: return value.canonicalString
    }
  }
}
