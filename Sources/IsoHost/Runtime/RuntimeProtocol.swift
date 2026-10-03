import Foundation
import IsoCore

/// Typed parsers for `iso-sandbox` JSON output (protocol 5). Runtime output
/// is untrusted input: every record is decoded into a closed type, reported
/// identifiers are checked against the one requested, and the effective VM
/// configuration the isolation gate reads rejects unknown fields, so a
/// runtime that grows a host-facing setting fails closed.
/// Stable diagnostic classes; each message starts with the identifier
/// documented in `docs/backends.md`.
package enum RuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
  case unavailable(String)
  /// Missing, unrecognized, or unexpected runtime output.
  case unqualified(String)
  case networkIsolation(String)
  case hostExposure(String)
  /// A record names a sandbox or owner other than the one expected.
  case identityConflict(String)
  case hostKeyChanged(String)
  case bootTimeout(String)
  /// The instance's session TTL has passed.
  case sessionExpired(String)
  /// A call timed out, was cancelled, or overflowed: its effect is unknown.
  case operationUncertain(String)
  /// The runtime ran and reported failure (no diagnostic class, as in Rust).
  case failed(String)

  package var description: String {
    switch self {
    case .unavailable(let m): "APPLE_RUNTIME_UNAVAILABLE: \(m)"
    case .unqualified(let m): "APPLE_RUNTIME_UNQUALIFIED: \(m)"
    case .networkIsolation(let m): "APPLE_NETWORK_ISOLATION: \(m)"
    case .hostExposure(let m): "APPLE_HOST_EXPOSURE: \(m)"
    case .identityConflict(let m): "APPLE_IDENTITY_CONFLICT: \(m)"
    case .hostKeyChanged(let m): "APPLE_HOST_KEY_CHANGED: \(m)"
    case .bootTimeout(let m): "APPLE_BOOT_TIMEOUT: \(m)"
    case .sessionExpired(let m): "APPLE_SESSION_EXPIRED: \(m)"
    case .operationUncertain(let m): "APPLE_OPERATION_UNCERTAIN: \(m)"
    case .failed(let m): m
    }
  }
}

package enum SandboxStatus: String, Sendable, Codable, CaseIterable {
  case running
  /// The owner exists but its control channel is not answering yet.
  case booting
  case stopped
  /// The owner died without cleaning up; `start` recovers it.
  case crashed
}

package struct RuntimeVersion: Sendable, Equatable, Codable {
  package let name: String
  package let version: String
  package let `protocol`: UInt32
  package let containerization: String
}

package struct SandboxRecord: Sendable, Equatable, Codable {
  package let id: String
  package let owner: String
  package let imageReference: String
  package let imageDigest: String
  package let cpus: UInt32
  package let memoryBytes: UInt64
  package let diskBytes: UInt64
  package let diskGeneration: UInt64
  /// The last `set`, `grow`, or `restore` the runtime committed.
  package let lastOperation: OperationID?
  /// The runtime always reports the effective network mode.
  package let network: String
  /// ISO 8601 end of the current session, absent without a session TTL.
  package let expiresAt: String?

  /// The session deadline, if one is recorded and parses.
  package var sessionDeadline: Date? {
    expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
  }
}

package struct LiveState: Sendable, Equatable, Codable {
  package let pid: Int32
  package let ipv4: IPv4Address?
  /// Identity of this boot, required by the current runtime contract.
  package let bootId: String
}

package struct EffectiveMount: Sendable, Equatable, Decodable {
  package let type: String
  package let source: String
  package let destination: String
  package let options: [String]

  enum CodingKeys: String, CodingKey, CaseIterable { case type, source, destination, options }

  package init(from decoder: any Decoder) throws {
    let c = try StrictKeys.container(decoder, CodingKeys.self)
    type = try c.decode(String.self, forKey: .type)
    source = try c.decode(String.self, forKey: .source)
    destination = try c.decode(String.self, forKey: .destination)
    options = try c.decode([String].self, forKey: .options)
  }
}

package struct EffectiveInterface: Sendable, Equatable, Decodable {
  /// CIDR, e.g. `10.231.4.2/24`.
  package let ipv4: String
  package let ipv4Gateway: String?
  package let ipv6: String?
  package let network: String

  enum CodingKeys: String, CodingKey, CaseIterable { case ipv4, ipv4Gateway, ipv6, network }

  package init(from decoder: any Decoder) throws {
    let c = try StrictKeys.container(decoder, CodingKeys.self)
    ipv4 = try c.decode(String.self, forKey: .ipv4)
    ipv4Gateway = try c.decodeIfPresent(String.self, forKey: .ipv4Gateway)
    ipv6 = try c.decodeIfPresent(String.self, forKey: .ipv6)
    network = try c.decode(String.self, forKey: .network)
  }
}

/// What the running VM was configured with, reported by its owner process.
package struct Effective: Sendable, Equatable, Decodable {
  package let id: String
  package let imageReference: String
  package let imageDigest: String
  package let cpus: UInt32
  package let memoryBytes: UInt64
  package let rootfs: EffectiveMount
  package let mounts: [EffectiveMount]
  package let interfaces: [EffectiveInterface]
  package let socketRelays: UInt32
  package let publishedPorts: UInt32
  package let sshAgentForwarding: Bool
  package let maskedPaths: [String]
  package let readonlyPaths: [String]
  package let initArgv: [String]
  package let virtualization: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, imageReference, imageDigest, cpus, memoryBytes, rootfs, mounts, interfaces
    case socketRelays, publishedPorts, sshAgentForwarding, maskedPaths, readonlyPaths, initArgv
    case virtualization
  }

  package init(from decoder: any Decoder) throws {
    let c = try StrictKeys.container(decoder, CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    imageReference = try c.decode(String.self, forKey: .imageReference)
    imageDigest = try c.decode(String.self, forKey: .imageDigest)
    cpus = try c.decode(UInt32.self, forKey: .cpus)
    memoryBytes = try c.decode(UInt64.self, forKey: .memoryBytes)
    rootfs = try c.decode(EffectiveMount.self, forKey: .rootfs)
    mounts = try c.decode([EffectiveMount].self, forKey: .mounts)
    interfaces = try c.decode([EffectiveInterface].self, forKey: .interfaces)
    socketRelays = try c.decode(UInt32.self, forKey: .socketRelays)
    publishedPorts = try c.decode(UInt32.self, forKey: .publishedPorts)
    sshAgentForwarding = try c.decode(Bool.self, forKey: .sshAgentForwarding)
    maskedPaths = try c.decode([String].self, forKey: .maskedPaths)
    readonlyPaths = try c.decode([String].self, forKey: .readonlyPaths)
    initArgv = try c.decode([String].self, forKey: .initArgv)
    virtualization = try c.decode(Bool.self, forKey: .virtualization)
  }
}

package struct DiskUsage: Sendable, Equatable, Codable {
  package let logicalBytes: UInt64
  package let allocatedBytes: UInt64
}

/// `iso-sandbox inspect <id>`.
package struct SandboxInspection: Sendable, Equatable, Decodable {
  package let record: SandboxRecord
  package let status: SandboxStatus
  package let live: LiveState?
  package let effective: Effective?
  package let disk: DiskUsage

  package var ipv4: IPv4Address? { live?.ipv4 }
}

package struct ListedSandbox: Sendable, Equatable, Decodable {
  package let id: String
  package let status: SandboxStatus
}

package struct RuntimeImage: Sendable, Equatable, Decodable {
  package let reference: String
  package let digest: String
}

package struct RuntimeDisk: Sendable, Equatable, Decodable {
  package let name: String
  package let logicalBytes: UInt64
}

package struct MaintenanceArtifact: Sendable, Equatable, Decodable {
  package let version: String
  package let reference: String
  package let digest: String
}

package enum RuntimeProtocol {
  /// Protocol advertised by this checkout's runtime.
  package static let version: UInt32 = 5
  package static let bootIdentity: UInt32 = 5

  /// Filtered egress needs the current protocol and a non-empty live boot id.
  package static func filteredBootAllowed(advertised: UInt32, bootID: String?) -> Bool {
    advertised == bootIdentity && !(bootID?.isEmpty ?? true)
  }

  static func decode<T: Decodable>(_ type: T.Type, _ bytes: [UInt8], _ what: String)
    throws(RuntimeError)
    -> T
  {
    do {
      return try JSONDecoder().decode(T.self, from: Data(bytes))
    } catch {
      throw .unqualified("`iso-sandbox \(what)` output: \(Self.describe(error))")
    }
  }

  /// Decoding failures name the path and category only.
  static func describe(_ error: any Error) -> String {
    guard let error = error as? DecodingError else { return "invalid JSON" }
    func path(_ context: DecodingError.Context) -> String {
      let rendered = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
        .joined(separator: ".")
      return rendered.isEmpty ? "<root>" : rendered
    }
    switch error {
    case .keyNotFound(let key, let context):
      return "missing field \(path(context)).\(key.stringValue)"
    case .typeMismatch(_, let context): return "wrong type at \(path(context))"
    case .valueNotFound(_, let context): return "missing value at \(path(context))"
    case .dataCorrupted(let context):
      return context.codingPath.isEmpty
        ? "invalid JSON" : "\(context.debugDescription) at \(path(context))"
    @unknown default: return "invalid JSON"
    }
  }

  package static func parseVersion(_ bytes: [UInt8]) throws(RuntimeError) -> RuntimeVersion {
    try decode(RuntimeVersion.self, bytes, "version")
  }

  package static func parseInspect(_ bytes: [UInt8], expected: MachineName) throws(RuntimeError)
    -> SandboxInspection
  {
    let inspection = try decode(SandboxInspection.self, bytes, "inspect")
    guard inspection.record.id == expected.rawValue else {
      throw .identityConflict(
        "inspect for \(expected) returned sandbox \(debugQuoted(inspection.record.id))")
    }
    if let effective = inspection.effective, effective.id != expected.rawValue {
      throw .identityConflict(
        "sandbox \(expected) reports an effective config for \(debugQuoted(effective.id))")
    }
    return inspection
  }

  /// Duplicate ids are a protocol error, never merged.
  package static func parseList(_ bytes: [UInt8]) throws(RuntimeError) -> [ListedSandbox] {
    let listed = try decode([ListedSandbox].self, bytes, "list")
    var seen = Set<String>()
    for entry in listed where !seen.insert(entry.id).inserted {
      throw .unqualified("`iso-sandbox list` reported \(entry.id) twice")
    }
    return listed
  }

  package static func parseImages(_ bytes: [UInt8]) throws(RuntimeError) -> [RuntimeImage] {
    let images = try decode([RuntimeImage].self, bytes, "image")
    for image in images where !isSHA256Digest(image.digest) {
      throw .unqualified(
        "image \(image.reference) has an invalid digest \(debugQuoted(image.digest))")
    }
    return images
  }

  package static func parseDisks(_ bytes: [UInt8]) throws(RuntimeError) -> [RuntimeDisk] {
    try decode([RuntimeDisk].self, bytes, "disk")
  }

  /// `null` means no maintenance disk is installed.
  package static func parseMaintenance(_ bytes: [UInt8]) throws(RuntimeError)
    -> MaintenanceArtifact?
  {
    try decode(MaintenanceArtifact?.self, bytes, "maintenance")
  }

  package static func isSHA256Digest(_ digest: String) -> Bool {
    guard digest.hasPrefix("sha256:") else { return false }
    let hex = digest.utf8.dropFirst(7)
    return hex.count == 64 && hex.allSatisfy { isASCIIHexDigit($0) }
  }
}

func isASCIIHexDigit(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
    || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
}

/// Keyed containers that refuse members outside `Keys` (serde
/// `deny_unknown_fields`); Foundation ignores unknown keys by default.
enum StrictKeys {
  struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }

  static func container<Keys: CodingKey & CaseIterable>(_ decoder: any Decoder, _: Keys.Type) throws
    -> KeyedDecodingContainer<Keys>
  {
    let all = try decoder.container(keyedBy: AnyKey.self)
    let known = Set(Keys.allCases.map(\.stringValue))
    if let unknown = all.allKeys.map(\.stringValue).first(where: { !known.contains($0) }) {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "unknown field `\(unknown)`"))
    }
    return try decoder.container(keyedBy: Keys.self)
  }
}
