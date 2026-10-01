import Foundation
import IsoConfiguration
import IsoCore

/// Creation-time egress policy. A later config change does not retarget a
/// running boot, and a legacy instance is not silently adopted as filtered.
public struct NetworkPolicy: Sendable, Equatable, Codable {
  public static let currentSchema: UInt32 = 3
  public var schemaVersion: UInt32
  public var backend: String
  public var mode: String
  public var allowedHosts: [String]
  public var policyHash: String

  public static func path(_ instance: Instance) -> String {
    instance.directory + "/network-policy.json"
  }

  public static func make(_ config: IsoConfig) -> NetworkPolicy {
    let hosts = config.egress == .filtered ? config.egressFilter.allowedHosts.map(\.rawValue) : []
    let canonical =
      "mode=\(config.egress.rawValue)\nhosts=\(hosts.joined(separator: ","))\nport=443\n"
    return NetworkPolicy(
      schemaVersion: currentSchema, backend: StateSchema.backend, mode: config.egress.rawValue,
      allowedHosts: hosts, policyHash: "sha256:" + sha256Hex(Array(canonical.utf8)))
  }

  public static func save(_ config: IsoConfig, _ instance: Instance) throws {
    try StateStore.writeControlFile(make(config), to: path(instance))
  }

  public static func load(_ instance: Instance) throws -> NetworkPolicy? {
    let path = path(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    let record = try StateStore.decode(NetworkPolicy.self, bytes, path: path)
    guard record.schemaVersion == currentSchema, record.backend == StateSchema.backend else {
      throw HostError("\(path) is not a supported network policy record")
    }
    return record
  }

  /// Filtered requires a matching frozen record. A missing record is a legacy
  /// open/none instance and cannot be treated as filtered.
  public static func enforce(_ instance: Instance, config: IsoConfig) throws {
    let recorded = try load(instance)
    if config.egress == .filtered {
      guard let recorded, recorded.mode == EgressMode.filtered.rawValue else {
        throw HostError(
          "POLICY_CHANGE_REQUIRES_RESTART: instance '\(instance.name)' was not created with filtered egress. Recreate it; this flag cannot change an existing instance's mode."
        )
      }
      let wanted = Set(config.egressFilter.allowedHosts.map(\.rawValue))
      guard Set(recorded.allowedHosts) == wanted else {
        throw HostError(
          "POLICY_CHANGE_REQUIRES_RESTART: filtered allowlist differs from the recorded boot policy for '\(instance.name)'."
        )
      }
      return
    }
    if let recorded, recorded.mode != config.egress.rawValue {
      throw HostError(
        "POLICY_CHANGE_REQUIRES_RESTART: instance '\(instance.name)' was created with egress \(recorded.mode), not \(config.egress.rawValue)."
      )
    }
  }
}
