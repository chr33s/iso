import Foundation

/// Validated identities of the host-control boundary (docs/design/local-and-remote-hosts-spec.md
/// section 4.1). Every value crossing configuration, the wire, or a state file is
/// decoded into one of these types once; holders never re-check.

/// Whether `value` is a canonical lowercase UUID: `8-4-4-4-12` hex digits.
package func isCanonicalUUID(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  guard bytes.count == 36 else { return false }
  for (index, byte) in bytes.enumerated() {
    switch index {
    case 8, 13, 18, 23:
      guard byte == UInt8(ascii: "-") else { return false }
    default:
      guard isLowerHex(byte) else { return false }
    }
  }
  return true
}

private func isLowerHex(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
}

/// A UUID-shaped identifier with one kind label for error text.
package protocol UUIDIdentifier: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  static var kind: String { get }
  var rawValue: String { get }
  init(unchecked rawValue: String)
}

extension UUIDIdentifier {
  package init(_ value: String) throws(ValidationError) {
    guard isCanonicalUUID(value) else {
      throw ValidationError("invalid \(Self.kind) \(debugQuoted(value))")
    }
    self.init(unchecked: value)
  }

  /// A fresh random (version 4) identifier.
  package static func generate() -> Self {
    Self(unchecked: UUID().uuidString.lowercased())
  }

  package var description: String { rawValue }
  package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

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

/// One host-control installation (data root); never inferred from a hostname.
package struct HostID: UUIDIdentifier {
  package static let kind = "host id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// One VM creation; never reused after deletion.
package struct InstanceID: UUIDIdentifier {
  package static let kind = "instance id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A client-chosen durable mutation identity, scoped by host and owner and
/// stable across retries. Distinct from the runtime `OperationID`, which
/// names one native `iso-sandbox` call underneath it.
package struct HostOperationID: UUIDIdentifier {
  package static let kind = "operation id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }

  /// The native runtime operation this host operation drives; deterministic
  /// so a reconciling retry addresses the same runtime journal.
  package var runtimeOperation: OperationID {
    // A canonical UUID is lowercase hex and dashes, which OperationID accepts.
    try! OperationID("h-" + rawValue)
  }
}

/// One wire request/response correlation.
package struct RequestID: UUIDIdentifier {
  package static let kind = "request id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// One live access session, chosen by the client.
package struct SessionID: UUIDIdentifier {
  package static let kind = "session id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// One supervisor lifetime; a restart invalidates every grant from the last.
package struct DaemonEpoch: UUIDIdentifier {
  package static let kind = "daemon epoch"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A client-owned file-return stage.
package struct StageID: UUIDIdentifier {
  package static let kind = "stage id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A worker-owned disposable run.
package struct RunID: UUIDIdentifier {
  package static let kind = "run id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A client-local mapping of a project to a qualified instance.
package struct WorkspaceBindingID: UUIDIdentifier {
  package static let kind = "workspace binding id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A host-owned staging handle; random, never a path.
package struct ArtifactHandle: UUIDIdentifier {
  package static let kind = "artifact handle"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A SHA-256 hex digest (policy hashes, request and content digests). Either
/// case is accepted and normalized to lowercase.
package struct SHA256Hex: Hashable, Sendable, CustomStringConvertible, Codable {
  package let rawValue: String

  package init(_ value: String) throws(ValidationError) {
    let bytes = Array(value.utf8)
    guard bytes.count == 64 else {
      throw ValidationError("expected 64 hex characters, got \(bytes.count)")
    }
    guard
      bytes.allSatisfy({ isLowerHex($0) || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains($0) })
    else {
      throw ValidationError("invalid hex in sha256 digest: \(debugQuoted(value))")
    }
    rawValue = value.lowercased()
  }

  package init(digest bytes: some Sequence<UInt8>) {
    rawValue = bytes.map { byte in
      let hex = String(byte, radix: 16)
      return hex.count == 1 ? "0" + hex : hex
    }.joined()
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

/// A runtime-reported boot identity: `[A-Za-z0-9._-]`, 1–128 bytes.
package struct BootID: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 128
  package let rawValue: String

  package init(_ value: String) throws(ValidationError) {
    let length = value.utf8.count
    guard length > 0, length <= Self.maxLength,
      value.unicodeScalars.allSatisfy(isSafeNameCharacter)
    else { throw ValidationError("invalid boot id \(debugQuoted(value))") }
    rawValue = value
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

/// A user-chosen execution host name (`execution.hosts` key, `--host`).
/// `local` is reserved for the implicit local host. Conservative so it is
/// safe as an ssh argument, a file name and a display label: starts with a
/// letter or digit, then `[A-Za-z0-9._-]`, at most 64 bytes.
package struct HostAlias: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 64
  package static let local = HostAlias(unchecked: "local")
  package let rawValue: String

  private init(unchecked rawValue: String) { self.rawValue = rawValue }

  package init(_ value: String) throws(ValidationError) {
    let length = value.utf8.count
    guard length > 0, length <= Self.maxLength else {
      throw ValidationError("host name must be 1-\(Self.maxLength) characters")
    }
    guard let first = value.unicodeScalars.first, first.isASCIILetterOrDigit else {
      throw ValidationError("host name \(debugQuoted(value)) must start with a letter or digit")
    }
    try validateSafeCharacters(value, kind: "Host name")
    rawValue = value
  }

  package var isLocal: Bool { self == .local }
  package var description: String { rawValue }
  package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

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

/// A client installation label for audit and session association. Never an
/// authorization credential.
package struct ClientLabel: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 128
  package let rawValue: String

  package init(_ value: String) throws(ValidationError) {
    let length = value.utf8.count
    guard length > 0, length <= Self.maxLength,
      value.unicodeScalars.allSatisfy(isSafeNameCharacter)
    else { throw ValidationError("invalid client label \(debugQuoted(value))") }
    rawValue = value
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

extension Unicode.Scalar {
  fileprivate var isASCIILetterOrDigit: Bool {
    ("a"..."z").contains(self) || ("A"..."Z").contains(self) || ("0"..."9").contains(self)
  }
}

/// The installed `iso` path on an execution host, chosen by the user at
/// enrollment (never from a project): absolute, `[A-Za-z0-9/._-]` only, no
/// `.`/`..` components. Safe as one shell word on the remote side.
package struct AgentPath: Hashable, Sendable, CustomStringConvertible, Codable {
  package static let maxLength = 1_024
  package let rawValue: String

  package init(_ value: String) throws(ValidationError) {
    guard value.hasPrefix("/"), value.utf8.count <= Self.maxLength else {
      throw ValidationError("agent path must be an absolute path")
    }
    guard
      value.unicodeScalars.allSatisfy({ $0 == "/" || isSafeNameCharacter($0) }),
      !value.split(separator: "/", omittingEmptySubsequences: false).dropFirst().contains(where: {
        $0.isEmpty || $0 == "." || $0 == ".."
      })
    else { throw ValidationError("agent path \(debugQuoted(value)) has unsupported characters") }
    rawValue = value
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
