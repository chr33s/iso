import IsoCore
import IsoPolicy

// The optional top-level `policy` object (docs/design/iso-policy.md §4).
// The existing JSONC scanner and duplicate-key preflight have already run;
// this maps the decoded value onto IsoPolicy's strict parser and compiler.

extension ConfigDecoder {
  /// Absent → nil. `null` is not absence, and nothing selects `off` silently.
  static func policy(_ r: ObjectReader) throws(FieldError) -> CompiledPolicy? {
    guard let value = r.members["policy"] else { return nil }
    let path = r.child("policy")
    guard value != .null else {
      throw FieldError(path, "must not be null (omit `policy` to leave it unset)")
    }
    do {
      return try PolicyCompiler.compile(PolicyDocument.parse(policyTree(value)))
    } catch {
      throw FieldError(
        path
          + error.path.map {
            switch $0 {
            case .key(let key): JSONPathComponent.key(key)
            case .index(let index): JSONPathComponent.index(index)
            }
          }, error.reason)
    }
  }

  /// Exponent and fraction literals stay `decimal` through preflight, so
  /// they reach the policy parser as non-integers.
  static func policyTree(_ value: JSONValue) -> PolicyJSON {
    switch value {
    case .null: .null
    case .bool(let bool): .bool(bool)
    case .number(.integer(let n)): .number(n)
    case .number(.unsigned(let n)): .number(Int64(exactly: n))
    case .number(.decimal): .number(nil)
    case .string(let text): .string(text)
    case .array(let items): .array(items.map(policyTree))
    case .object(let members): .object(members.mapValues(policyTree))
    }
  }

  /// An enforcing policy cannot coexist with a path that bypasses it. The
  /// requested modes are never rewritten.
  static func requirePolicyCombinations(_ config: IsoConfig) throws(FieldError) {
    guard let policy = config.policy, policy.mode == .enforce else { return }
    let mode: [JSONPathComponent] = [.key("policy"), .key("mode")]
    if policy.enforcesProviderActions {
      guard config.proxy.mode == .required else {
        throw FieldError(
          mode,
          "enforcing credential.use or proxy.request requires proxy.mode \"required\" (currently \"\(config.proxy.mode.rawValue)\"); raw-key and proxy-off paths would bypass the policy"
        )
      }
      guard config.codexAuth != .chatgpt else {
        throw FieldError(
          mode,
          "enforcing credential.use or proxy.request is incompatible with codex.auth \"chatgpt\", which reaches OpenAI without the credential proxy"
        )
      }
    }
    if policy.enforces(.workspacePullApply) {
      guard config.workspacePull.mode == .stage else {
        throw FieldError(
          mode,
          "enforcing workspace.pull.apply requires workspace.pull.mode \"stage\" (currently \"\(config.workspacePull.mode.rawValue)\")"
        )
      }
    }
  }
}
