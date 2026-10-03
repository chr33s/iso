/// Validated identifiers for declarative agent definitions, reviewed adapters,
/// and run/launch records. Character classes are closed here so a definition
/// file cannot become a path, a shell word, or a shadow of a compiled adapter.

/// `1`–`64` lowercase ASCII letters, digits, or hyphens, starting with a letter.
package struct AgentDefinitionID: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 64
  /// Built-in definition ids and every compiled adapter id. A catalog file
  /// cannot use one of these, so it cannot shadow an implementation.
  package static let reserved: Set<String> = ["claude", "codex", "none"]
  package let rawValue: String

  package init(_ raw: String) throws(ValidationError) {
    guard !raw.isEmpty else { throw ValidationError("agent id must not be empty") }
    guard raw.utf8.count <= Self.maxLength else {
      throw ValidationError(
        "agent id too long (\(raw.utf8.count) chars, max \(Self.maxLength))")
    }
    let scalars = Array(raw.unicodeScalars)
    guard let first = scalars.first, ("a"..."z").contains(first) else {
      throw ValidationError("agent id must start with a lowercase letter")
    }
    for scalar in scalars
    where !(("a"..."z").contains(scalar) || scalar.isASCIIDigit || scalar == "-") {
      throw ValidationError(
        "agent id contains invalid character \(quoted(scalar)) (allowed: a-z, 0-9, '-')")
    }
    rawValue = raw
  }

  package var isReserved: Bool { Self.reserved.contains(rawValue) }
  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Identifier of a compiled, reviewed adapter binding. The same character
/// class as a definition id, so it cannot be a path or a plugin reference.
package struct AgentAdapterID: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 64
  package static let none = AgentAdapterID(unchecked: "none")
  package static let claude = AgentAdapterID(unchecked: "claude")
  package static let codex = AgentAdapterID(unchecked: "codex")
  package static let compiled: [AgentAdapterID] = [.none, .claude, .codex]
  package let rawValue: String

  /// Literals above are valid by inspection; the validating initializer is
  /// the only path for untrusted input.
  private init(unchecked raw: String) { rawValue = raw }

  package init(_ raw: String) throws(ValidationError) {
    guard !raw.isEmpty else { throw ValidationError("adapter id must not be empty") }
    guard raw.utf8.count <= Self.maxLength else {
      throw ValidationError(
        "adapter id too long (\(raw.utf8.count) chars, max \(Self.maxLength))")
    }
    let scalars = Array(raw.unicodeScalars)
    guard let first = scalars.first, ("a"..."z").contains(first) else {
      throw ValidationError("adapter id must start with a lowercase letter")
    }
    for scalar in scalars
    where !(("a"..."z").contains(scalar) || scalar.isASCIIDigit || scalar == "-") {
      throw ValidationError(
        "adapter id contains invalid character \(quoted(scalar)) (allowed: a-z, 0-9, '-')")
    }
    guard Self.compiled.contains(where: { $0.rawValue == raw }) else {
      throw ValidationError(
        "unknown adapter '\(raw)' (compiled adapters: \(Self.compiled.map(\.rawValue).joined(separator: ", ")))"
      )
    }
    rawValue = raw
  }

  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// 32 lowercase hex characters. Used for run sessions and launch records so
/// a file name cannot carry a path.
package struct HexID: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let length = 32
  package let rawValue: String

  package init(_ raw: String) throws(ValidationError) {
    guard raw.utf8.count == Self.length else {
      throw ValidationError("id must be \(Self.length) lowercase hex characters")
    }
    for scalar in raw.unicodeScalars {
      let hex = ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
      guard hex else {
        throw ValidationError("id must be \(Self.length) lowercase hex characters")
      }
    }
    rawValue = raw
  }

  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

package typealias RunSessionID = HexID
package typealias AgentLaunchID = HexID

/// Literal guest defaults a definition may set. Anything else — provider
/// variables, proxy variables, loaders, SSH — is not representable.
package enum AgentEnvironmentAllowlist {
  package static let names: Set<String> = ["TERM", "COLORTERM", "NO_COLOR"]
  package static let maxEntries = 3
  package static let maxValueBytes = 128
}

/// Exact ASCII DNS name for network hints. Comparison is the canonical
/// lowercase form with one terminal dot removed. A name does not match its
/// parent or a sibling; wildcards and address literals are rejected.
package struct ExactHostname: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 253
  package let rawValue: String

  package init(_ raw: String) throws(ValidationError) {
    guard !raw.isEmpty else { throw ValidationError("hostname must not be empty") }
    for scalar in raw.unicodeScalars {
      guard scalar.isASCII, scalar.value >= 0x21, scalar.value <= 0x7E else {
        throw ValidationError("hostname must be printable ASCII without spaces")
      }
    }
    if raw.contains("://") || raw.contains("/") || raw.contains("?") || raw.contains("#")
      || raw.contains("@") || raw.contains("%") || raw.contains("\\") || raw.contains("*")
      || raw.contains(":") || raw.contains("[") || raw.contains("]")
    {
      throw ValidationError(
        "hostname must be an exact DNS name, not a wildcard, address, or URI")
    }
    var name = raw
    if name.hasSuffix(".") {
      name.removeLast()
      guard !name.hasSuffix("."), !name.isEmpty else {
        throw ValidationError("hostname has an empty label")
      }
    }
    let lower = name.lowercased()
    guard lower.utf8.count <= Self.maxLength else {
      throw ValidationError("hostname is longer than \(Self.maxLength) bytes")
    }
    let labels = lower.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count >= 2 else {
      throw ValidationError("single-label hostnames are not allowed")
    }
    var allNumeric = true
    for label in labels {
      guard !label.isEmpty, label.utf8.count <= 63 else {
        throw ValidationError("hostname has an empty or overlong label")
      }
      guard label.unicodeScalars.first != "-", label.unicodeScalars.last != "-" else {
        throw ValidationError("hostname label must not start or end with '-'")
      }
      for scalar in label.unicodeScalars
      where !(scalar.isASCIILetter || scalar.isASCIIDigit || scalar == "-") {
        throw ValidationError("hostname contains invalid character \(quoted(scalar))")
      }
      if !label.unicodeScalars.allSatisfy(\.isASCIIDigit) { allNumeric = false }
    }
    if allNumeric {
      throw ValidationError("numeric-address aliases are not allowed")
    }
    rawValue = lower
  }

  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: error.message))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
