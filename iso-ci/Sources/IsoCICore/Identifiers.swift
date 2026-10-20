import CryptoKit
import Foundation

/// Validated identities. Values crossing configuration, the control channel,
/// the database, the host wire or the guest data plane are decoded into one
/// of these once; holders never re-check.

package func isCanonicalUUID(_ value: String) -> Bool {
  let bytes = Array(value.utf8)
  guard bytes.count == 36 else { return false }
  for (index, byte) in bytes.enumerated() {
    switch index {
    case 8, 13, 18, 23: guard byte == UInt8(ascii: "-") else { return false }
    default: guard isLowerHex(byte) else { return false }
    }
  }
  return true
}

package func isLowerHex(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
}

/// `[A-Za-z0-9._-]`.
package func isSafeNameScalar(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar {
  case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".": true
  default: false
  }
}

/// A type decoded from one wire string through its validating initializer.
package protocol WireParsable {
  init(parsing raw: String) throws(CIError)
}

package protocol UUIDIdentifier: WireParsable, Hashable, Comparable, Sendable,
  CustomStringConvertible, Codable
{
  static var kind: String { get }
  var rawValue: String { get }
  init(unchecked rawValue: String)
}

extension UUIDIdentifier {
  package init(_ value: String) throws(CIError) {
    guard isCanonicalUUID(value) else { throw CIError.invalid("invalid \(Self.kind)") }
    self.init(unchecked: value)
  }

  package init(parsing raw: String) throws(CIError) { try self.init(raw) }

  package static func generate() -> Self { Self(unchecked: UUID().uuidString.lowercased()) }
  package var description: String { rawValue }
  package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
  package var short: String { String(rawValue.prefix(8)) }

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

// MARK: - iso-ci identities

/// One owned environment request (spec section 5).
package struct AllocationID: UUIDIdentifier {
  package static let kind = "allocation id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A controller mutation returned to the operator (spec section 12).
package struct ControlOperationID: UUIDIdentifier {
  package static let kind = "operation id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// One local preflight run (a compiled workflow graph).
package struct PreflightRunID: UUIDIdentifier {
  package static let kind = "preflight run id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// One whole-job attempt inside a preflight run.
package struct JobAttemptID: UUIDIdentifier {
  package static let kind = "job attempt id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// The controller installation identity (one per operator data root).
package struct ControllerID: UUIDIdentifier {
  package static let kind = "controller id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

// MARK: - iso host identities (mirrors of iso.host/v1 formats)

package struct HostID: UUIDIdentifier {
  package static let kind = "host id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

package struct InstanceID: UUIDIdentifier {
  package static let kind = "instance id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// A client-chosen durable host mutation identity, persisted before sending.
package struct HostOperationID: UUIDIdentifier {
  package static let kind = "host operation id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

package struct HostRunID: UUIDIdentifier {
  package static let kind = "host run id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

package struct RequestID: UUIDIdentifier {
  package static let kind = "request id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

package struct SessionID: UUIDIdentifier {
  package static let kind = "session id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

package struct DaemonEpoch: UUIDIdentifier {
  package static let kind = "daemon epoch"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

package struct StageID: UUIDIdentifier {
  package static let kind = "stage id"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

package struct ArtifactHandle: UUIDIdentifier {
  package static let kind = "artifact handle"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// 32 lowercase hex characters naming one iso installation's resources.
package struct OwnerID: Hashable, Sendable, CustomStringConvertible, Codable {
  package let rawValue: String
  package init(_ value: String) throws(CIError) {
    let bytes = Array(value.utf8)
    guard bytes.count == 32, bytes.allSatisfy(isLowerHex) else {
      throw CIError.invalid("invalid owner id")
    }
    rawValue = value
  }
  package var description: String { rawValue }
  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "owner id"))
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A runtime-reported boot identity: `[A-Za-z0-9._-]`, 1-128 bytes.
package struct BootID: Hashable, Sendable, CustomStringConvertible, Codable {
  package let rawValue: String
  package init(_ value: String) throws(CIError) {
    guard (1...128).contains(value.utf8.count), value.unicodeScalars.allSatisfy(isSafeNameScalar)
    else { throw CIError.invalid("invalid boot id") }
    rawValue = value
  }
  package var description: String { rawValue }
  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "boot id"))
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A lowercase SHA-256 hex digest.
package struct Digest: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  package let rawValue: String

  package init(_ value: String) throws(CIError) {
    let lowered = value.lowercased()
    let bytes = Array(lowered.utf8)
    guard bytes.count == 64, bytes.allSatisfy(isLowerHex) else {
      throw CIError.invalid("invalid sha256 digest")
    }
    rawValue = lowered
  }

  /// Accepts `sha256:<hex>` as well as bare hex.
  package init(prefixed value: String) throws(CIError) {
    try self.init(value.hasPrefix("sha256:") ? String(value.dropFirst(7)) : value)
  }

  package init(hashing bytes: some Sequence<UInt8>) {
    var hasher = SHA256()
    hasher.update(data: Array(bytes))
    rawValue = hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  package init(hashing data: Data) { self.init(hashing: Array(data)) }
  package init(hashing string: String) { self.init(hashing: Array(string.utf8)) }

  package var description: String { rawValue }
  package var prefixed: String { "sha256:" + rawValue }
  package var short: String { String(rawValue.prefix(12)) }
  package static func < (a: Digest, b: Digest) -> Bool { a.rawValue < b.rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(prefixed: raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "digest"))
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

// MARK: - Names

/// A configuration name: profiles, pools, host aliases, endpoint profiles.
/// Starts with a letter or digit, then `[A-Za-z0-9._-]`, at most 64 bytes.
package struct Name: Hashable, Comparable, Sendable, CustomStringConvertible, Codable,
  ExpressibleByStringLiteral
{
  package let rawValue: String

  package init(_ value: String) throws(CIError) {
    guard (1...64).contains(value.utf8.count), let first = value.unicodeScalars.first,
      first.properties.isASCIIHexDigit || ("a"..."z").contains(first)
        || ("A"..."Z").contains(first),
      value.unicodeScalars.allSatisfy(isSafeNameScalar)
    else { throw CIError.invalid("invalid name \"\(CIError.bounded(String(value.prefix(64))))\"") }
    rawValue = value
  }

  package init(stringLiteral value: String) {
    // Literals are compile-time constants written by developers.
    do { try self.init(value) } catch { fatalError("invalid Name literal \(value)") }
  }

  package static let local: Name = "local"
  package var description: String { rawValue }
  package static func < (a: Name, b: Name) -> Bool { a.rawValue < b.rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "name"))
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// `OWNER/REPOSITORY` as GitHub spells it.
package struct RepositoryName: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  package let owner: String
  package let name: String

  package init(_ value: String) throws(CIError) {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, Self.validOwner(parts[0]), Self.validRepository(parts[1]) else {
      throw CIError.invalid("repository must be OWNER/REPOSITORY")
    }
    owner = parts[0]
    name = parts[1]
  }

  static func validOwner(_ value: String) -> Bool {
    (1...39).contains(value.utf8.count)
      && value.unicodeScalars.allSatisfy { isSafeNameScalar($0) && $0 != "." && $0 != "_" }
      && !value.hasPrefix("-")
  }

  static func validRepository(_ value: String) -> Bool {
    (1...100).contains(value.utf8.count) && value.unicodeScalars.allSatisfy(isSafeNameScalar)
      && value != "." && value != ".."
  }

  package static func validOrganization(_ value: String) -> Bool { validOwner(value) }

  package var rawValue: String { owner + "/" + name }
  package var description: String { rawValue }
  package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "repository"))
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// A self-hosted runner label: 1-100 bytes, no commas or control characters.
package struct RunnerLabel: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  package let rawValue: String

  package init(_ value: String) throws(CIError) {
    guard (1...100).contains(value.utf8.count),
      value.unicodeScalars.allSatisfy({ isSafeNameScalar($0) })
    else { throw CIError.invalid("invalid runner label") }
    rawValue = value
  }

  /// GitHub compares labels case-insensitively.
  package var normalized: String { rawValue.lowercased() }
  package var description: String { rawValue }
  package static func < (a: Self, b: Self) -> Bool { a.normalized < b.normalized }

  package init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    do { try self.init(raw) } catch {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "label"))
    }
  }
  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// Seconds since the Unix epoch on the controller clock.
package typealias EpochSeconds = UInt64

/// Injectable time so reconciliation and budget tests are deterministic.
package protocol CIClock: Sendable {
  func now() -> EpochSeconds
}

package struct SystemClock: CIClock {
  package init() {}
  package func now() -> EpochSeconds { EpochSeconds(Date().timeIntervalSince1970) }
}

/// 256 bits from the system CSPRNG as lowercase hex.
package func randomHex(bytes count: Int = 32) -> String {
  var bytes = [UInt8](repeating: 0, count: count)
  arc4random_buf(&bytes, bytes.count)
  return bytes.map { String(format: "%02x", $0) }.joined()
}

/// Constant-time comparison for bearer verifiers.
package func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
  guard a.count == b.count else { return false }
  var difference: UInt8 = 0
  for index in a.indices { difference |= a[index] ^ b[index] }
  return difference == 0
}

extension OwnerID: WireParsable {
  package init(parsing raw: String) throws(CIError) { try self.init(raw) }
}

extension BootID: WireParsable {
  package init(parsing raw: String) throws(CIError) { try self.init(raw) }
}

/// Accepts bare hex or `sha256:<hex>`.
extension Digest: WireParsable {
  package init(parsing raw: String) throws(CIError) { try self.init(prefixed: raw) }
}

extension Name: WireParsable {
  package init(parsing raw: String) throws(CIError) { try self.init(raw) }
}

extension RepositoryName: WireParsable {
  package init(parsing raw: String) throws(CIError) { try self.init(raw) }
}

extension RunnerLabel: WireParsable {
  package init(parsing raw: String) throws(CIError) { try self.init(raw) }
}
