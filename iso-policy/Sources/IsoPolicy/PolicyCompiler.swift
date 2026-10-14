import CryptoKit
import Foundation

/// A location inside the `policy` object, for bounded diagnostics.
public enum PolicyPathComponent: Sendable, Equatable {
  case key(String)
  case index(Int)
}

/// A rejected policy. Messages name the field and, where known, the rule or
/// guard ID; they never echo arbitrary input text.
public struct PolicyError: Error, Sendable, Equatable, CustomStringConvertible {
  public let path: [PolicyPathComponent]
  public let reason: String

  public init(_ path: [PolicyPathComponent], _ reason: String) {
    self.path = path
    self.reason = reason
  }

  public var description: String {
    var text = "policy"
    for component in path {
      switch component {
      case .key(let key): text += "." + key
      case .index(let index): text += "[\(index)]"
      }
    }
    return "\(text): \(reason)"
  }
}

/// A neutral JSON tree that each adapter builds from its own parser. The
/// adapter has already rejected duplicate keys; `number(nil)` is any number
/// that is not an exact integer literal (fractions, exponents, overflow).
public indirect enum PolicyJSON: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Int64?)
  case string(String)
  case array([PolicyJSON])
  case object([String: PolicyJSON])

  /// From a Foundation `JSONSerialization` tree. Booleans stay booleans;
  /// a number that is not an exact integer becomes `number(nil)`.
  public init(foundation value: Any) throws(PolicyError) {
    self = try PolicyCanonical.tree(value, [])
  }

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

extension PolicyDocument {
  /// Strict structural parse: unknown keys, wrong types, `null`, and
  /// non-integer numbers are errors. Semantics are `PolicyCompiler`'s job.
  public static func parse(_ value: PolicyJSON) throws(PolicyError) -> PolicyDocument {
    let root = try Reader(value, at: [])
    try root.rejectUnknown(PolicySchema.policyKeys)
    let version = try root.required("version") { v, p throws(PolicyError) in try int(v, p) }
    let mode = try root.required("mode") { v, p throws(PolicyError) in
      try enumeration(v, p, PolicyMode.self)
    }
    let actions = try root.required("actions") { v, p throws(PolicyError) in
      try array(v, p) { v, p throws(PolicyError) in try enumeration(v, p, PolicyAction.self) }
    }
    let rules = try root.required("rules") { v, p throws(PolicyError) in
      try array(v, p, rule)
    }
    let guards = try root.required("guards") { v, p throws(PolicyError) in
      try array(v, p, policyGuard)
    }
    return PolicyDocument(
      version: version, mode: mode, actions: actions, rules: rules, guards: guards)
  }

  private static func rule(_ value: PolicyJSON, _ path: [PolicyPathComponent]) throws(PolicyError)
    -> PolicyRule
  {
    let r = try Reader(value, at: path)
    try r.rejectUnknown(PolicySchema.ruleKeys)
    return PolicyRule(
      id: try r.required("id", string),
      effect: try r.required("effect") { v, p throws(PolicyError) in
        try enumeration(v, p, PolicyEffect.self)
      },
      action: try r.required("action") { v, p throws(PolicyError) in
        try enumeration(v, p, PolicyAction.self)
      },
      resources: try r.required("resources", resources),
      instances: try r.optional("instances", instances))
  }

  private static func policyGuard(_ value: PolicyJSON, _ path: [PolicyPathComponent])
    throws(PolicyError) -> PolicyGuard
  {
    let g = try Reader(value, at: path)
    try g.rejectUnknown(PolicySchema.guardKeys)
    return PolicyGuard(
      id: try g.required("id", string),
      action: try g.required("action") { v, p throws(PolicyError) in
        try enumeration(v, p, PolicyAction.self)
      },
      resources: try g.required("resources", resources),
      instances: try g.optional("instances", instances),
      requirement: try g.required("require", requirement))
  }

  private static func requirement(_ value: PolicyJSON, _ path: [PolicyPathComponent])
    throws(PolicyError) -> GuardRequirement
  {
    let r = try Reader(value, at: path)
    try r.rejectUnknown(PolicySchema.requireKeys)
    guard r.members.count == 1 else {
      throw PolicyError(path, "must contain exactly one of 'rate_limit' or 'approval_within'")
    }
    if let limit = try r.optional(
      "rate_limit",
      { v, p throws(PolicyError) in
        let l = try Reader(v, at: p)
        try l.rejectUnknown(PolicySchema.rateLimitKeys)
        return GuardRequirement.rateLimit(
          maxRequests: try l.required("max_requests", int),
          withinSeconds: try l.required("within_seconds", int))
      })
    {
      return limit
    }
    return try r.required("approval_within") { v, p throws(PolicyError) in
      let a = try Reader(v, at: p)
      try a.rejectUnknown(PolicySchema.approvalKeys)
      return GuardRequirement.approvalWithin(seconds: try a.required("seconds", int))
    }
  }

  private static func resources(_ value: PolicyJSON, _ path: [PolicyPathComponent])
    throws(PolicyError) -> [PolicyResource]
  {
    try array(value, path) { v, p throws(PolicyError) in
      try enumeration(v, p, PolicyResource.self)
    }
  }

  private static func instances(_ value: PolicyJSON, _ path: [PolicyPathComponent])
    throws(PolicyError) -> [String]
  {
    try array(value, path, string)
  }

  private static func string(_ value: PolicyJSON, _ path: [PolicyPathComponent])
    throws(PolicyError) -> String
  {
    guard case .string(let text) = value else {
      throw PolicyError(path, "expected a string, found \(value.typeName)")
    }
    return text
  }

  private static func int(_ value: PolicyJSON, _ path: [PolicyPathComponent])
    throws(PolicyError) -> Int
  {
    guard case .number(let number) = value else {
      throw PolicyError(path, "expected an integer, found \(value.typeName)")
    }
    guard let number, let result = Int(exactly: number) else {
      throw PolicyError(path, "expected an integer literal without fraction or exponent")
    }
    return result
  }

  private static func enumeration<T: RawRepresentable<String> & CaseIterable>(
    _ value: PolicyJSON, _ path: [PolicyPathComponent], _: T.Type
  ) throws(PolicyError) -> T {
    let raw = try string(value, path)
    guard let result = T(rawValue: raw) else {
      let names = T.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
      throw PolicyError(path, "unsupported value, expected one of \(names)")
    }
    return result
  }

  private static func array<T>(
    _ value: PolicyJSON, _ path: [PolicyPathComponent],
    _ element: (PolicyJSON, [PolicyPathComponent]) throws(PolicyError) -> T
  ) throws(PolicyError) -> [T] {
    guard case .array(let items) = value else {
      throw PolicyError(path, "expected an array, found \(value.typeName)")
    }
    var out: [T] = []
    for (index, item) in items.enumerated() {
      out.append(try element(item, path + [.index(index)]))
    }
    return out
  }

  private struct Reader {
    let path: [PolicyPathComponent]
    let members: [String: PolicyJSON]

    init(_ value: PolicyJSON, at path: [PolicyPathComponent]) throws(PolicyError) {
      guard case .object(let members) = value else {
        throw PolicyError(path, "expected an object, found \(value.typeName)")
      }
      self.path = path
      self.members = members
    }

    func rejectUnknown(_ allowed: Set<String>) throws(PolicyError) {
      if let unknown = members.keys.filter({ !allowed.contains($0) }).sorted().first {
        // An unknown key is user input; report only that one exists when it
        // is not a plain identifier.
        let shown = PolicySchema.isValidID(unknown) ? unknown : "<unrecognized>"
        throw PolicyError(path + [.key(shown)], "unknown field")
      }
    }

    func required<T>(
      _ key: String, _ parse: (PolicyJSON, [PolicyPathComponent]) throws(PolicyError) -> T
    ) throws(PolicyError) -> T {
      guard let value = members[key] else {
        throw PolicyError(path + [.key(key)], "missing required field")
      }
      if value == .null { throw PolicyError(path + [.key(key)], "must not be null") }
      return try parse(value, path + [.key(key)])
    }

    /// Absent → nil; `null` is not absence.
    func optional<T>(
      _ key: String, _ parse: (PolicyJSON, [PolicyPathComponent]) throws(PolicyError) -> T
    ) throws(PolicyError) -> T? {
      guard let value = members[key] else { return nil }
      if value == .null { throw PolicyError(path + [.key(key)], "must not be null") }
      return try parse(value, path + [.key(key)])
    }
  }
}

/// A validated, normalized, immutable policy and its identity.
public struct CompiledPolicy: Sendable, Equatable {
  /// Normalized: entries sorted by ID, set-valued arrays sorted.
  public let document: PolicyDocument
  /// `canonicalizationVersion = 1` bytes; never includes credentials.
  public let canonicalBytes: [UInt8]
  /// `sha256:<hex>` over `canonicalBytes`.
  public let digest: String

  public var mode: PolicyMode { document.mode }
  /// Actions this policy decides; empty when the mode is `off`.
  public var governedActions: Set<PolicyAction> {
    document.mode == .off ? [] : Set(document.actions)
  }
  public var canonicalJSON: String { String(decoding: canonicalBytes, as: UTF8.self) }

  /// Whether this policy hard-enforces `action` (mode `enforce` and selected).
  public func enforces(_ action: PolicyAction) -> Bool {
    mode == .enforce && document.actions.contains(action)
  }

  /// Whether either provider action is enforced.
  public var enforcesProviderActions: Bool {
    enforces(.credentialUse) || enforces(.proxyRequest)
  }

  /// Whether either provider action is governed in `shadow` or `enforce`.
  public var governsProviderActions: Bool {
    !governedActions.isDisjoint(with: [.credentialUse, .proxyRequest])
  }
}

public enum PolicyCompiler {
  /// Validates semantics and bounds, normalizes, and computes the digest.
  public static func compile(_ document: PolicyDocument) throws(PolicyError) -> CompiledPolicy {
    guard document.version == PolicySchema.version else {
      throw PolicyError([.key("version")], "unsupported version (expected 1)")
    }
    guard Set(document.actions).count == document.actions.count else {
      throw PolicyError([.key("actions")], "duplicate action")
    }
    if document.actions.isEmpty && document.mode != .off {
      throw PolicyError([.key("actions")], "must not be empty unless mode is \"off\"")
    }
    guard document.rules.count <= PolicySchema.maxRules else {
      throw PolicyError([.key("rules")], "more than \(PolicySchema.maxRules) rules")
    }
    guard document.guards.count <= PolicySchema.maxGuards else {
      throw PolicyError([.key("guards")], "more than \(PolicySchema.maxGuards) guards")
    }
    let declared = Set(document.actions)
    var ids = Set<String>()
    for (index, rule) in document.rules.enumerated() {
      let path: [PolicyPathComponent] = [.key("rules"), .index(index)]
      try checkID(rule.id, path, &ids)
      try checkSelector(
        id: rule.id, action: rule.action, resources: rule.resources, instances: rule.instances,
        declared: declared, path)
    }
    for (index, entry) in document.guards.enumerated() {
      let path: [PolicyPathComponent] = [.key("guards"), .index(index)]
      try checkID(entry.id, path, &ids)
      try checkSelector(
        id: entry.id, action: entry.action, resources: entry.resources,
        instances: entry.instances, declared: declared, path)
      switch entry.requirement {
      case .rateLimit(let capacity, let window):
        guard entry.action == .proxyRequest else {
          throw PolicyError(
            path + [.key("require")],
            "guard '\(entry.id)': rate_limit applies only to proxy.request")
        }
        guard PolicySchema.rateCapacity.contains(capacity) else {
          throw PolicyError(
            path + [.key("require"), .key("rate_limit"), .key("max_requests")],
            "guard '\(entry.id)': must be within 1...10000")
        }
        guard PolicySchema.rateWindowSeconds.contains(window) else {
          throw PolicyError(
            path + [.key("require"), .key("rate_limit"), .key("within_seconds")],
            "guard '\(entry.id)': must be within 1...3600")
        }
      case .approvalWithin(let seconds):
        guard entry.action == .workspacePullApply else {
          throw PolicyError(
            path + [.key("require")],
            "guard '\(entry.id)': approval_within applies only to workspace.pull.apply")
        }
        guard PolicySchema.approvalSeconds.contains(seconds) else {
          throw PolicyError(
            path + [.key("require"), .key("approval_within"), .key("seconds")],
            "guard '\(entry.id)': must be within 1...900")
        }
      }
    }
    try checkRateScopes(document.guards)
    let normalized = normalize(document)
    let bytes = PolicyCanonical.encode(normalized)
    guard bytes.count <= PolicySchema.maxCanonicalBytes else {
      throw PolicyError([], "canonical policy exceeds 64 KiB")
    }
    return CompiledPolicy(
      document: normalized, canonicalBytes: bytes, digest: PolicyCanonical.digest(bytes))
  }

  private static func checkID(
    _ id: String, _ path: [PolicyPathComponent], _ seen: inout Set<String>
  ) throws(PolicyError) {
    guard PolicySchema.isValidID(id) else {
      throw PolicyError(
        path + [.key("id")], "must be 1-64 characters matching [a-z][a-z0-9._-]*")
    }
    guard seen.insert(id).inserted else {
      throw PolicyError(path + [.key("id")], "duplicate rule or guard id '\(id)'")
    }
  }

  private static func checkSelector(
    id: String, action: PolicyAction, resources: [PolicyResource], instances: [String]?,
    declared: Set<PolicyAction>, _ path: [PolicyPathComponent]
  ) throws(PolicyError) {
    guard declared.contains(action) else {
      throw PolicyError(path + [.key("action")], "'\(id)': action is not listed in policy.actions")
    }
    guard !resources.isEmpty else {
      throw PolicyError(path + [.key("resources")], "'\(id)': must not be empty")
    }
    guard Set(resources).count == resources.count else {
      throw PolicyError(path + [.key("resources")], "'\(id)': duplicate resource")
    }
    guard resources.allSatisfy({ $0.kind == action.resourceKind }) else {
      throw PolicyError(
        path + [.key("resources")], "'\(id)': resource type does not match \(action.rawValue)")
    }
    guard let instances else { return }
    guard !instances.isEmpty else {
      throw PolicyError(
        path + [.key("instances")], "'\(id)': must not be empty (omit it to match every instance)")
    }
    guard instances.count <= PolicySchema.maxInstancesPerEntry else {
      throw PolicyError(path + [.key("instances")], "'\(id)': more than 64 instances")
    }
    guard Set(instances).count == instances.count else {
      throw PolicyError(path + [.key("instances")], "'\(id)': duplicate instance")
    }
    for (index, name) in instances.enumerated() where !PolicySchema.isValidInstanceName(name) {
      throw PolicyError(
        path + [.key("instances"), .index(index)],
        "'\(id)': not a valid instance name (a-z, A-Z, 0-9, '-', '_'; at most 64)")
    }
  }

  /// One proxy serves one provider for one instance: bound the rate guards
  /// and timestamp slots any such proxy could allocate.
  private static func checkRateScopes(_ guards: [PolicyGuard]) throws(PolicyError) {
    let rate = guards.filter {
      if case .rateLimit = $0.requirement { true } else { false }
    }
    let named = Set(rate.flatMap { $0.instances ?? [] })
    // `nil` stands for any instance no guard names.
    let scopes: [String?] = [nil] + named.sorted()
    for provider in [PolicyResource.anthropic, .openai] {
      for instance in scopes {
        let matching = rate.filter { entry in
          guard entry.resources.contains(provider) else { return false }
          guard let names = entry.instances else { return true }
          return instance.map(names.contains) ?? false
        }
        guard matching.count <= PolicySchema.maxRateGuardsPerScope else {
          throw PolicyError(
            [.key("guards")],
            "more than \(PolicySchema.maxRateGuardsPerScope) rate guards match \(provider.rawValue)"
          )
        }
        let slots = matching.reduce(0) { total, entry in
          if case .rateLimit(let capacity, _) = entry.requirement {
            total + capacity
          } else {
            total
          }
        }
        guard slots <= PolicySchema.maxTimestampSlots else {
          throw PolicyError(
            [.key("guards")],
            "rate guards matching \(provider.rawValue) allocate more than \(PolicySchema.maxTimestampSlots) admissions"
          )
        }
      }
    }
  }

  static func normalize(_ document: PolicyDocument) -> PolicyDocument {
    PolicyDocument(
      version: document.version, mode: document.mode, actions: document.actions.sorted(),
      rules: document.rules.map {
        PolicyRule(
          id: $0.id, effect: $0.effect, action: $0.action, resources: $0.resources.sorted(),
          instances: $0.instances.map(sortedBytes))
      }.sorted { utf8Less($0.id, $1.id) },
      guards: document.guards.map {
        PolicyGuard(
          id: $0.id, action: $0.action, resources: $0.resources.sorted(),
          instances: $0.instances.map(sortedBytes), requirement: $0.requirement)
      }.sorted { utf8Less($0.id, $1.id) })
  }
}

func utf8Less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }
func sortedBytes(_ values: [String]) -> [String] { values.sorted(by: utf8Less) }

/// `canonicalizationVersion = 1`: compact UTF-8 JSON, keys in byte order,
/// entries sorted by ID, set-valued arrays sorted, integers in plain decimal,
/// and strings escaped minimally (`"`, `\`, and U+0000–U+001F as `\u00XX`).
/// This is iso's own encoding, not a general JSON canonicalization standard.
public enum PolicyCanonical {
  public static func encode(_ document: PolicyDocument) -> [UInt8] {
    let normalized = PolicyCompiler.normalize(document)
    var out = "{\"actions\":" + list(normalized.actions.map(\.rawValue))
    out += ",\"guards\":[" + normalized.guards.map(guardJSON).joined(separator: ",") + "]"
    out += ",\"mode\":" + quote(normalized.mode.rawValue)
    out += ",\"rules\":[" + normalized.rules.map(ruleJSON).joined(separator: ",") + "]"
    out += ",\"version\":\(normalized.version)}"
    return Array(out.utf8)
  }

  public static func digest(_ bytes: [UInt8]) -> String {
    "sha256:" + SHA256.hash(data: bytes).map { hex($0) }.joined()
  }

  /// Parses canonical bytes and requires they are exactly the canonical
  /// encoding of what they decode to, so any alternative spelling (spacing,
  /// key order, `1.0`, duplicate keys, a boolean for a number) is refused.
  public static func decode(_ bytes: [UInt8]) throws(PolicyError) -> CompiledPolicy {
    guard bytes.count <= PolicySchema.maxCanonicalBytes else {
      throw PolicyError([], "canonical policy exceeds 64 KiB")
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: Data(bytes), options: [])
    } catch {
      throw PolicyError([], "not valid JSON")
    }
    let compiled = try PolicyCompiler.compile(PolicyDocument.parse(try tree(object, [])))
    guard compiled.canonicalBytes == bytes else {
      throw PolicyError([], "not in canonical form")
    }
    return compiled
  }

  static func tree(_ value: Any, _ path: [PolicyPathComponent]) throws(PolicyError)
    -> PolicyJSON
  {
    switch value {
    case is NSNull: return .null
    case let text as String: return .string(text)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
      // Exactness is re-checked by the byte comparison after re-encoding.
      return .number(Int64(exactly: number.doubleValue))
    case let items as [Any]:
      var out: [PolicyJSON] = []
      for (index, item) in items.enumerated() {
        out.append(try tree(item, path + [.index(index)]))
      }
      return .array(out)
    case let members as [String: Any]:
      var out: [String: PolicyJSON] = [:]
      for (key, item) in members { out[key] = try tree(item, path + [.key(key)]) }
      return .object(out)
    default: throw PolicyError(path, "unsupported JSON value")
    }
  }

  private static func ruleJSON(_ rule: PolicyRule) -> String {
    var out = "{\"action\":" + quote(rule.action.rawValue)
    out += ",\"effect\":" + quote(rule.effect.rawValue)
    out += ",\"id\":" + quote(rule.id)
    if let instances = rule.instances { out += ",\"instances\":" + list(instances) }
    out += ",\"resources\":" + list(rule.resources.map(\.rawValue)) + "}"
    return out
  }

  private static func guardJSON(_ entry: PolicyGuard) -> String {
    var out = "{\"action\":" + quote(entry.action.rawValue)
    out += ",\"id\":" + quote(entry.id)
    if let instances = entry.instances { out += ",\"instances\":" + list(instances) }
    switch entry.requirement {
    case .rateLimit(let capacity, let window):
      out +=
        ",\"require\":{\"rate_limit\":{\"max_requests\":\(capacity),\"within_seconds\":\(window)}}"
    case .approvalWithin(let seconds):
      out += ",\"require\":{\"approval_within\":{\"seconds\":\(seconds)}}"
    }
    out += ",\"resources\":" + list(entry.resources.map(\.rawValue)) + "}"
    return out
  }

  private static func list(_ values: [String]) -> String {
    "[" + values.map(quote).joined(separator: ",") + "]"
  }

  static func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case _ where scalar.value < 0x20:
        out += "\\u00" + hex(UInt8(scalar.value))
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  static func hex(_ byte: UInt8) -> String {
    let digits = Array("0123456789abcdef")
    return String([digits[Int(byte >> 4)], digits[Int(byte & 0xF)]])
  }
}
