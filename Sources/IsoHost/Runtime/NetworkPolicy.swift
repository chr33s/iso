import Foundation
import IsoConfiguration
import IsoCore

/// Creation-time egress policy. A later config change does not retarget a
/// running boot; every instance must retain the policy recorded at creation.
package struct NetworkPolicy: Sendable, Equatable, Codable {
  package static let currentSchema: UInt32 = 3
  package var schemaVersion: UInt32
  package var backend: String
  package var mode: String
  package var allowedHosts: [String]
  package var policyHash: String

  package static func path(_ instance: Instance) -> String {
    instance.directory + "/network-policy.json"
  }

  package static func make(_ config: IsoConfig) -> NetworkPolicy {
    let hosts = config.egress == .filtered ? config.egressFilter.allowedHosts.map(\.rawValue) : []
    return NetworkPolicy(
      schemaVersion: currentSchema, backend: StateSchema.backend, mode: config.egress.rawValue,
      allowedHosts: hosts, policyHash: hash(mode: config.egress.rawValue, hosts: hosts))
  }

  private static func hash(mode: String, hosts: [String]) -> String {
    let canonical = "mode=\(mode)\nhosts=\(hosts.joined(separator: ","))\nport=443\n"
    return "sha256:" + sha256Hex(Array(canonical.utf8))
  }

  package static func save(_ config: IsoConfig, _ instance: Instance) throws {
    try StateStore.writeControlFile(make(config), to: path(instance))
  }

  package static func load(_ instance: Instance) throws -> NetworkPolicy? {
    let path = path(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    let record = try StateStore.decode(NetworkPolicy.self, bytes, path: path)
    guard record.schemaVersion == currentSchema, record.backend == StateSchema.backend else {
      throw HostError("\(path) is not a supported network policy record")
    }
    guard let mode = EgressMode(rawValue: record.mode),
      mode == .filtered || record.allowedHosts.isEmpty,
      record.allowedHosts == Set(record.allowedHosts).sorted(),
      record.allowedHosts.allSatisfy({ (try? ExactHostname($0))?.rawValue == $0 }),
      record.policyHash == hash(mode: record.mode, hosts: record.allowedHosts)
    else { throw HostError("\(path) has an invalid or inconsistent network policy") }
    return record
  }

  /// Require the creation-time record in every mode before boot or handoff.
  package static func enforce(_ instance: Instance, config: IsoConfig) throws {
    guard let recorded = try load(instance) else {
      throw HostError(
        "Instance '\(instance.name)' has no recorded network policy. Recreate it with `iso destroy` and `iso up`; its creation-time egress policy cannot be established."
      )
    }
    if config.egress == .filtered {
      guard recorded.mode == EgressMode.filtered.rawValue else {
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
    if recorded.mode != config.egress.rawValue {
      throw HostError(
        "POLICY_CHANGE_REQUIRES_RESTART: instance '\(instance.name)' was created with egress \(recorded.mode), not \(config.egress.rawValue)."
      )
    }
  }
}
