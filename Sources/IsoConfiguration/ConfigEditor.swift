import Foundation

/// Structural configuration edits. An edit decodes the whole document into
/// `JSONValue`, changes only the addressed members, and re-encodes, so
/// unmodeled and unknown keys survive. Comments and formatting do not.
public enum ConfigEditor {
  /// Set `proxy.<provider>` to `{credential, auth}`, keeping any other
  /// members of that object. `existing` nil means the file does not exist.
  public static func upsertProxy(
    existing: [UInt8]?, format: ConfigFormat, path: String, provider: ProxyProvider,
    credential: CredentialReference, auth: ProxyAuthScheme, environment: ConfigEnvironment,
    limits: JSONLimits = .configuration
  ) throws(ConfigError) -> [UInt8] {
    var root =
      try existing.map { bytes throws(ConfigError) in
        try ConfigLoader.parse(bytes, format: format, path: path, limits: limits)
      } ?? .object([:])
    // Only a valid configuration is edited: re-encoding cannot keep a
    // literal's spelling, so an invalid `2.0` must not become a valid `2`.
    _ = try ConfigLoader.decode(root, path: path, environment: environment)
    guard case .object(var top) = root else { throw .rootNotObject(path: path) }
    var proxy = try object(top["proxy"], field: "proxy", path: path)
    var entry = try object(
      proxy[provider.rawValue], field: "proxy.\(provider.rawValue)", path: path)
    entry["credential"] = .string(credential.command.expose())
    entry["auth"] = .string(auth.rawValue)
    proxy[provider.rawValue] = .object(entry)
    top["proxy"] = .object(proxy)
    root = .object(top)
    return try encodeVerified(
      root, format: format, path: path, environment: environment, limits: limits)
  }

  /// `iso inference init` (secure-local-inference spec §20.6): set each
  /// dotted key to its value. A key already set to a different value is a
  /// conflict, refused unless `force`. Returns the new document and the keys
  /// it changed.
  public static func applyDefaults(
    existing: [UInt8]?, format: ConfigFormat, path: String, settings: [([String], JSONValue)],
    force: Bool, environment: ConfigEnvironment, limits: JSONLimits = .configuration
  ) throws(ConfigError) -> (bytes: [UInt8], changed: [String]) {
    var root =
      try existing.map { bytes throws(ConfigError) in
        try ConfigLoader.parse(bytes, format: format, path: path, limits: limits)
      } ?? .object([:])
    _ = try ConfigLoader.decode(root, path: path, environment: environment)
    var changed: [String] = []
    var conflicts: [String] = []
    for (parts, value) in settings {
      let key = parts.joined(separator: ".")
      let current = lookup(root, parts)
      if let current, current.semanticallyEquals(value) { continue }
      if current != nil && !force {
        conflicts.append(key)
        continue
      }
      root = try set(root, parts, value, path: path)
      changed.append(key)
    }
    guard conflicts.isEmpty else {
      throw .invalidField(
        path: path, field: conflicts.joined(separator: ", "),
        reason: "already set to a different value; pass --force to replace")
    }
    return (
      try encodeVerified(
        root, format: format, path: path, environment: environment, limits: limits),
      changed
    )
  }

  static func lookup(_ value: JSONValue, _ parts: [String]) -> JSONValue? {
    guard let first = parts.first else { return value }
    guard case .object(let members) = value, let next = members[first] else { return nil }
    return lookup(next, Array(parts.dropFirst()))
  }

  static func set(_ value: JSONValue, _ parts: [String], _ new: JSONValue, path: String)
    throws(ConfigError) -> JSONValue
  {
    guard let first = parts.first else { return new }
    var members = try object(value, field: first, path: path)
    members[first] = try set(
      members[first] ?? .object([:]), Array(parts.dropFirst()), new, path: path)
    return .object(members)
  }

  private static func object(_ value: JSONValue?, field: String, path: String) throws(ConfigError)
    -> [String: JSONValue]
  {
    switch value {
    case nil: return [:]
    case .object(let members)?: return members
    case let other?:
      throw .invalidField(
        path: path, field: field, reason: "expected an object, found \(other.typeName)")
    }
  }

  /// Encode, then prove the bytes parse back to the same value and decode to
  /// a valid configuration before anything is written.
  static func encodeVerified(
    _ value: JSONValue, format: ConfigFormat, path: String, environment: ConfigEnvironment,
    limits: JSONLimits
  ) throws(ConfigError) -> [UInt8] {
    let bytes = try encode(value, path: path)
    let reread = try ConfigLoader.parse(bytes, format: format, path: path, limits: limits)
    guard reread.semanticallyEquals(value) else {
      throw .invalidField(path: path, field: "<root>", reason: "edited document did not round-trip")
    }
    _ = try ConfigLoader.decode(reread, path: path, environment: environment)
    return bytes
  }

  public static func encode(_ value: JSONValue, path: String) throws(ConfigError) -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      return Array(try encoder.encode(value)) + [UInt8(ascii: "\n")]
    } catch {
      throw .invalidField(path: path, field: "<root>", reason: "could not be encoded as JSON")
    }
  }
}

extension JSONValue {
  /// Equality of meaning: numbers compare by value, so `1e2` equals `100`
  /// and `1.0` equals `1`; everything else compares structurally.
  public func semanticallyEquals(_ other: JSONValue) -> Bool {
    switch (self, other) {
    case (.number(let a), .number(let b)): a.decimalValue == b.decimalValue
    case (.array(let a), .array(let b)):
      a.count == b.count && zip(a, b).allSatisfy { $0.semanticallyEquals($1) }
    case (.object(let a), .object(let b)):
      a.count == b.count
        && a.allSatisfy { key, value in b[key].map(value.semanticallyEquals) ?? false }
    default: self == other
    }
  }
}

extension JSONNumber {
  public var decimalValue: Decimal {
    switch self {
    case .integer(let value): Decimal(value)
    case .unsigned(let value): Decimal(value)
    case .decimal(let value): value
    }
  }
}
