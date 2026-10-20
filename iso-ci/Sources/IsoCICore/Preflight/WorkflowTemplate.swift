import Foundation

/// One static compatibility problem, reported before any allocation.
package struct CompatibilityDiagnostic: Sendable, Equatable, Hashable, Codable,
  CustomStringConvertible
{
  package let line: Int
  package let path: String
  package let reason: String

  package init(line: Int, path: String, reason: String) {
    self.line = line
    self.path = path
    self.reason = CIError.bounded(reason)
  }

  package var description: String { "line \(line): \(path): \(reason)" }
}

/// Which contexts and functions an expression in one workflow field may use
/// (GitHub's context-availability table, restricted to the subset's keys).
package struct ExpressionField: Sendable, Equatable {
  package let contexts: Set<ExpressionContextName>
  package let statusFunctions: Bool
  package let hashFiles: Bool

  init(_ contexts: [ExpressionContextName], status: Bool = false, hashFiles: Bool = false) {
    self.contexts = Set(contexts)
    statusFunctions = status
    self.hashFiles = hashFiles
  }

  private static let stepContexts: [ExpressionContextName] = [
    .github, .needs, .strategy, .matrix, .job, .runner, .env, .vars, .secrets, .steps, .inputs,
  ]

  package static let runName = ExpressionField([.github, .inputs, .vars])
  package static let workflowEnv = ExpressionField([.github, .secrets, .inputs, .vars])
  package static let jobIf = ExpressionField([.github, .needs, .vars, .inputs], status: true)
  package static let jobName = ExpressionField([
    .github, .needs, .strategy, .matrix, .vars, .inputs,
  ])
  package static let jobRunsOn = ExpressionField([
    .github, .needs, .strategy, .matrix, .vars, .inputs,
  ])
  package static let jobEnv = ExpressionField([
    .github, .needs, .strategy, .matrix, .vars, .secrets, .inputs,
  ])
  package static let jobContainer = ExpressionField([
    .github, .needs, .strategy, .matrix, .vars, .inputs,
  ])
  package static let jobContainerEnv = ExpressionField([
    .github, .needs, .strategy, .matrix, .job, .runner, .env, .vars, .secrets, .inputs,
  ])
  package static let jobOutputs = ExpressionField(stepContexts)
  package static let jobTimeout = ExpressionField([
    .github, .needs, .strategy, .matrix, .vars, .inputs,
  ])
  package static let jobContinueOnError = ExpressionField([
    .github, .needs, .strategy, .vars, .matrix, .inputs,
  ])
  package static let jobDefaultsRun = ExpressionField([
    .github, .needs, .strategy, .matrix, .env, .vars, .inputs,
  ])
  package static let stepIf = ExpressionField(
    [.github, .needs, .strategy, .matrix, .job, .runner, .env, .vars, .steps, .inputs],
    status: true, hashFiles: true)
  package static let stepField = ExpressionField(stepContexts, hashFiles: true)
}

/// A `${{ }}` segmentation of one string.
package enum TemplateSegment: Sendable, Equatable {
  case literal(String)
  case expression(String)
}

/// Converts YAML workflow values into `TemplateValue`s, validating every
/// embedded expression against its field and collecting diagnostics and the
/// static secret names referenced.
package struct TemplateConverter {
  package var diagnostics: [CompatibilityDiagnostic] = []
  package var secretNames: Set<String> = []

  package init() {}

  package mutating func report(_ node: YAMLNode, _ path: String, _ reason: String) {
    diagnostics.append(CompatibilityDiagnostic(line: node.line, path: path, reason: reason))
  }

  package mutating func report(line: Int, _ path: String, _ reason: String) {
    diagnostics.append(CompatibilityDiagnostic(line: line, path: path, reason: reason))
  }

  /// Splits `text` into literal and `${{ }}` segments. `}}` inside a quoted
  /// string literal does not close an expression.
  package static func segments(_ text: String) throws(CIError) -> [TemplateSegment] {
    let bytes = Array(text.utf8)
    var out: [TemplateSegment] = []
    var literal: [UInt8] = []
    var index = 0
    while index < bytes.count {
      if bytes[index] == UInt8(ascii: "$"), index + 2 < bytes.count,
        bytes[index + 1] == UInt8(ascii: "{"), bytes[index + 2] == UInt8(ascii: "{")
      {
        var cursor = index + 3
        var inString = false
        var closed = false
        while cursor < bytes.count {
          let b = bytes[cursor]
          if inString {
            if b == UInt8(ascii: "'") {
              if cursor + 1 < bytes.count, bytes[cursor + 1] == UInt8(ascii: "'") {
                cursor += 2
                continue
              }
              inString = false
            }
          } else if b == UInt8(ascii: "'") {
            inString = true
          } else if b == UInt8(ascii: "}"), cursor + 1 < bytes.count,
            bytes[cursor + 1] == UInt8(ascii: "}")
          {
            closed = true
            break
          }
          cursor += 1
        }
        guard closed else {
          throw CIError(.compatibilityRejected, "unterminated ${{ expression")
        }
        if !literal.isEmpty {
          out.append(.literal(String(decoding: literal, as: UTF8.self)))
          literal = []
        }
        let inner = String(decoding: bytes[(index + 3)..<cursor], as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else {
          throw CIError(.compatibilityRejected, "empty ${{ }} expression")
        }
        out.append(.expression(inner))
        index = cursor + 2
      } else {
        literal.append(bytes[index])
        index += 1
      }
    }
    if !literal.isEmpty { out.append(.literal(String(decoding: literal, as: UTF8.self))) }
    return out
  }

  /// The single expression equivalent to `segments` (GitHub's format()
  /// composition for mixed text).
  package static func composed(_ segments: [TemplateSegment]) -> String? {
    let expressions = segments.compactMap { segment -> String? in
      if case .expression(let text) = segment { return text }
      return nil
    }
    guard !expressions.isEmpty else { return nil }
    if segments.count == 1 { return expressions[0] }
    var template = ""
    var placeholder = 0
    for segment in segments {
      switch segment {
      case .literal(let text):
        template += text.replacingOccurrences(of: "{", with: "{{")
          .replacingOccurrences(of: "}", with: "}}").replacingOccurrences(of: "'", with: "''")
      case .expression:
        template += "{\(placeholder)}"
        placeholder += 1
      }
    }
    return "format('\(template)', \(expressions.joined(separator: ", ")))"
  }

  /// Parses and validates one expression for `field`.
  @discardableResult
  package mutating func validate(_ text: String, field: ExpressionField, line: Int, path: String)
    -> ExpressionNode?
  {
    let node: ExpressionNode
    do { node = try Expression.parse(text) } catch {
      report(line: line, path, error.message)
      return nil
    }
    for context in node.contexts.sorted()
    where !field.contexts.contains(ExpressionContextName(rawValue: context) ?? .github)
      || ExpressionContextName(rawValue: context) == nil
    {
      report(line: line, path, "the '\(context)' context is not available in this field")
    }
    for function in node.functions.sorted() {
      guard let parsed = ExpressionFunction(rawValue: function) else { continue }
      if parsed.isStatus && !field.statusFunctions {
        report(line: line, path, "\(function)() is only available in if: conditions")
      }
      if parsed == .hashfiles && !field.hashFiles {
        report(line: line, path, "hashFiles() is only available in step fields")
      }
    }
    let secrets = node.names(in: ExpressionContextName.secrets.rawValue)
    if secrets.dynamic {
      report(line: line, path, "secret names must be static (secrets.NAME)")
    }
    for name in secrets.names {
      if name.contains("ACTIONS_ID_TOKEN") {
        report(line: line, path, "OIDC token requests are not available in local preflight")
      }
      secretNames.insert(name)
    }
    return node
  }

  /// A scalar or nested value; mapping keys must be literal.
  package mutating func value(_ node: YAMLNode, field: ExpressionField, path: String)
    -> TemplateValue
  {
    switch node {
    case .scalar(let scalar):
      return self.scalar(scalar, field: field, path: path)
    case .sequence(let items, _):
      return .sequence(
        items.enumerated().map { value($0.element, field: field, path: "\(path)[\($0.offset)]") })
    case .mapping:
      return .mapping(entries(node, field: field, path: path))
    }
  }

  package mutating func scalar(_ scalar: YAMLScalar, field: ExpressionField, path: String)
    -> TemplateValue
  {
    if scalar.style == .plain {
      if scalar.isNull { return .null }
      if let flag = scalar.bool { return .bool(flag) }
      if let number = scalar.int { return .number(Double(number)) }
      if let number = scalar.double, number.isFinite { return .number(number) }
    }
    return string(scalar.value, field: field, line: scalar.line, path: path)
  }

  package mutating func string(_ text: String, field: ExpressionField, line: Int, path: String)
    -> TemplateValue
  {
    if text.contains("ACTIONS_ID_TOKEN_REQUEST") {
      report(line: line, path, "OIDC token requests are not available in local preflight")
    }
    let parts: [TemplateSegment]
    do { parts = try Self.segments(text) } catch {
      report(line: line, path, error.message)
      return .string(text)
    }
    guard let expression = Self.composed(parts) else { return .string(text) }
    if field.contexts.isEmpty {
      report(line: line, path, "expressions are not allowed in this field")
      return .string(text)
    }
    for part in parts {
      if case .expression(let inner) = part {
        validate(inner, field: field, line: line, path: path)
      }
    }
    return .expression(expression)
  }

  /// A mapping of literal keys to values (env, with, outputs).
  package mutating func entries(_ node: YAMLNode, field: ExpressionField, path: String)
    -> [TemplateEntry]
  {
    if node.isNull { return [] }
    guard let pairs = node.mapping else {
      report(node, path, "must be a mapping")
      return []
    }
    var out: [TemplateEntry] = []
    for pair in pairs {
      if pair.key.value.contains("${{") {
        report(line: pair.key.line, "\(path).\(pair.key.value)", "keys cannot contain expressions")
        continue
      }
      if pair.key.value.contains("ACTIONS_ID_TOKEN_REQUEST") {
        report(
          line: pair.key.line, "\(path).\(pair.key.value)",
          "OIDC token requests are not available in local preflight")
      }
      out.append(
        TemplateEntry(
          key: pair.key.value,
          value: value(pair.value, field: field, path: "\(path).\(pair.key.value)")))
    }
    return out
  }

  /// An `if:` condition as expression text, wrapped as
  /// `success() && (…)` when it calls no status function (GitHub's rule).
  package mutating func condition(_ node: YAMLNode?, field: ExpressionField, path: String) -> String
  {
    guard let node, !node.isNull else { return "success()" }
    guard let scalar = node.scalar else {
      report(node, path, "must be a scalar expression")
      return "success()"
    }
    var text: String
    if scalar.style == .plain, let flag = scalar.bool {
      text = flag ? "true" : "false"
    } else {
      let parts: [TemplateSegment]
      do { parts = try Self.segments(scalar.value) } catch {
        report(node, path, error.message)
        return "success()"
      }
      if let composed = Self.composed(parts) {
        text = composed
      } else {
        text = scalar.value.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    }
    if text.isEmpty { return "success()" }
    guard let parsed = validate(text, field: field, line: scalar.line, path: path) else {
      return "success()"
    }
    if !parsed.callsStatusFunction { text = "success() && (\(text))" }
    return text
  }
}
