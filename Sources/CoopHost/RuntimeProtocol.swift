import CoopCore
import Foundation

/// Typed parsers for `coop-sandbox` JSON output (protocol 2). Runtime output
/// is untrusted input: every record is decoded into a closed type, reported
/// identifiers are checked against the one requested, and the effective VM
/// configuration the isolation gate reads rejects unknown fields, so a
/// runtime that grows a host-facing setting fails closed.
/// Stable diagnostic classes; each message starts with the identifier
/// documented in `docs/backends.md`.
public enum RuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
  case unavailable(String)
  /// Missing, unrecognized, or unexpected runtime output.
  case unqualified(String)
  case networkIsolation(String)
  case hostExposure(String)
  /// A record names a sandbox or owner other than the one expected.
  case identityConflict(String)
  case hostKeyChanged(String)
  case bootTimeout(String)
  /// A call timed out, was cancelled, or overflowed: its effect is unknown.
  case operationUncertain(String)
  /// The runtime ran and reported failure (no diagnostic class, as in Rust).
  case failed(String)

  public var description: String {
    switch self {
    case .unavailable(let m): "APPLE_RUNTIME_UNAVAILABLE: \(m)"
    case .unqualified(let m): "APPLE_RUNTIME_UNQUALIFIED: \(m)"
    case .networkIsolation(let m): "APPLE_NETWORK_ISOLATION: \(m)"
    case .hostExposure(let m): "APPLE_HOST_EXPOSURE: \(m)"
    case .identityConflict(let m): "APPLE_IDENTITY_CONFLICT: \(m)"
    case .hostKeyChanged(let m): "APPLE_HOST_KEY_CHANGED: \(m)"
    case .bootTimeout(let m): "APPLE_BOOT_TIMEOUT: \(m)"
    case .operationUncertain(let m): "APPLE_OPERATION_UNCERTAIN: \(m)"
    case .failed(let m): m
    }
  }
}

public enum SandboxStatus: String, Sendable, Codable, CaseIterable {
  case running
  /// The owner exists but its control channel is not answering yet.
  case booting
  case stopped
  /// The owner died without cleaning up; `start` recovers it.
  case crashed
}

public struct RuntimeVersion: Sendable, Equatable, Codable {
  public let name: String
  public let version: String
  public let `protocol`: UInt32
  public let containerization: String
}

public struct SandboxRecord: Sendable, Equatable, Codable {
  public let id: String
  public let owner: String
  public let imageReference: String
  public let imageDigest: String
  public let cpus: UInt32
  public let memoryBytes: UInt64
  public let diskBytes: UInt64
  public let diskGeneration: UInt64
  /// The last `set`, `grow`, or `restore` the runtime committed.
  public let lastOperation: OperationID?
}

public struct LiveState: Sendable, Equatable, Codable {
  public let pid: Int32
  public let ipv4: IPv4Address?
}

public struct EffectiveMount: Sendable, Equatable, Decodable {
  public let type: String
  public let source: String
  public let destination: String
  public let options: [String]

  enum CodingKeys: String, CodingKey, CaseIterable { case type, source, destination, options }

  public init(from decoder: any Decoder) throws {
    let c = try StrictKeys.container(decoder, CodingKeys.self)
    type = try c.decode(String.self, forKey: .type)
    source = try c.decode(String.self, forKey: .source)
    destination = try c.decode(String.self, forKey: .destination)
    options = try c.decode([String].self, forKey: .options)
  }
}

public struct EffectiveInterface: Sendable, Equatable, Decodable {
  /// CIDR, e.g. `10.231.4.2/24`.
  public let ipv4: String
  public let ipv4Gateway: String?
  public let ipv6: String?
  public let network: String

  enum CodingKeys: String, CodingKey, CaseIterable { case ipv4, ipv4Gateway, ipv6, network }

  public init(from decoder: any Decoder) throws {
    let c = try StrictKeys.container(decoder, CodingKeys.self)
    ipv4 = try c.decode(String.self, forKey: .ipv4)
    ipv4Gateway = try c.decodeIfPresent(String.self, forKey: .ipv4Gateway)
    ipv6 = try c.decodeIfPresent(String.self, forKey: .ipv6)
    network = try c.decode(String.self, forKey: .network)
  }
}

/// What the running VM was configured with, reported by its owner process.
public struct Effective: Sendable, Equatable, Decodable {
  public let id: String
  public let imageReference: String
  public let imageDigest: String
  public let cpus: UInt32
  public let memoryBytes: UInt64
  public let rootfs: EffectiveMount
  public let mounts: [EffectiveMount]
  public let interfaces: [EffectiveInterface]
  public let socketRelays: UInt32
  public let publishedPorts: UInt32
  public let sshAgentForwarding: Bool
  public let maskedPaths: [String]
  public let readonlyPaths: [String]
  public let initArgv: [String]
  public let virtualization: Bool

  enum CodingKeys: String, CodingKey, CaseIterable {
    case id, imageReference, imageDigest, cpus, memoryBytes, rootfs, mounts, interfaces
    case socketRelays, publishedPorts, sshAgentForwarding, maskedPaths, readonlyPaths, initArgv
    case virtualization
  }

  public init(from decoder: any Decoder) throws {
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

public struct DiskUsage: Sendable, Equatable, Codable {
  public let logicalBytes: UInt64
  public let allocatedBytes: UInt64
}

/// `coop-sandbox inspect <id>`.
public struct SandboxInspection: Sendable, Equatable, Decodable {
  public let record: SandboxRecord
  public let status: SandboxStatus
  public let live: LiveState?
  public let effective: Effective?
  public let disk: DiskUsage

  public var ipv4: IPv4Address? { live?.ipv4 }
}

public struct ListedSandbox: Sendable, Equatable, Decodable {
  public let id: String
  public let status: SandboxStatus
}

public struct RuntimeImage: Sendable, Equatable, Decodable {
  public let reference: String
  public let digest: String
}

public struct RuntimeDisk: Sendable, Equatable, Decodable {
  public let name: String
  public let logicalBytes: UInt64
}

public struct MaintenanceArtifact: Sendable, Equatable, Decodable {
  public let version: String
  public let reference: String
  public let digest: String
}

public enum RuntimeProtocol {
  public static let version: UInt32 = 2

  static func decode<T: Decodable>(_ type: T.Type, _ bytes: [UInt8], _ what: String)
    throws(RuntimeError)
    -> T
  {
    do {
      return try JSONDecoder().decode(T.self, from: Data(bytes))
    } catch {
      throw .unqualified("`coop-sandbox \(what)` output: \(Self.describe(error))")
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

  public static func parseVersion(_ bytes: [UInt8]) throws(RuntimeError) -> RuntimeVersion {
    try decode(RuntimeVersion.self, bytes, "version")
  }

  public static func parseInspect(_ bytes: [UInt8], expected: MachineName) throws(RuntimeError)
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
  public static func parseList(_ bytes: [UInt8]) throws(RuntimeError) -> [ListedSandbox] {
    let listed = try decode([ListedSandbox].self, bytes, "list")
    var seen = Set<String>()
    for entry in listed where !seen.insert(entry.id).inserted {
      throw .unqualified("`coop-sandbox list` reported \(entry.id) twice")
    }
    return listed
  }

  public static func parseImages(_ bytes: [UInt8]) throws(RuntimeError) -> [RuntimeImage] {
    let images = try decode([RuntimeImage].self, bytes, "image")
    for image in images where !isSHA256Digest(image.digest) {
      throw .unqualified(
        "image \(image.reference) has an invalid digest \(debugQuoted(image.digest))")
    }
    return images
  }

  public static func parseDisks(_ bytes: [UInt8]) throws(RuntimeError) -> [RuntimeDisk] {
    try decode([RuntimeDisk].self, bytes, "disk")
  }

  /// `null` means no maintenance disk is installed.
  public static func parseMaintenance(_ bytes: [UInt8]) throws(RuntimeError) -> MaintenanceArtifact?
  {
    try decode(MaintenanceArtifact?.self, bytes, "maintenance")
  }

  public static func isSHA256Digest(_ digest: String) -> Bool {
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
