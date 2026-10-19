import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets

/// Creation-time egress mode and transport, and the most recently started
/// boot's allowlist (and, for a brokered VM, its resolved network policy).
/// Configuration changes never retarget a running boot.
package struct NetworkPolicy: Sendable, Equatable {
  package static let currentSchema: UInt32 = 3
  /// Brokered records only, so a vmnet record is unchanged and an older
  /// build refuses a brokered one instead of reading it as vmnet.
  package static let brokeredSchema: UInt32 = 4
  package var backend: String
  package var mode: String
  package var allowedHosts: [String]
  package var policyHash: String
  /// A brokered VM's boot policy; nil exactly for vmnet. The transport,
  /// digest and schema follow from it and are not stored separately.
  package var brokered: BrokeredNetworkPolicy? = nil

  package var schemaVersion: UInt32 { brokered == nil ? Self.currentSchema : Self.brokeredSchema }
  package var recordedTransport: NetworkTransport { brokered == nil ? .vmnet : .brokered }
  /// The digest the runtime binds the boot's streams to.
  package var brokeredDigest: SHA256Hex? { brokered?.digest }

  package init(
    backend: String, mode: String, allowedHosts: [String], policyHash: String,
    brokered: BrokeredNetworkPolicy? = nil
  ) {
    self.backend = backend
    self.mode = mode
    self.allowedHosts = allowedHosts
    self.policyHash = policyHash
    self.brokered = brokered
  }

  package static func path(_ instance: Instance) -> String {
    instance.directory + "/network-policy.json"
  }

  /// The egress half, from configuration alone.
  package static func make(_ config: IsoConfig) -> NetworkPolicy {
    let hosts = config.egress == .filtered ? config.egressFilter.allowedHosts.map(\.rawValue) : []
    return NetworkPolicy(
      backend: StateSchema.backend, mode: config.egress.rawValue,
      allowedHosts: hosts, policyHash: hash(mode: config.egress.rawValue, hosts: hosts))
  }

  /// The complete record for a boot of `instance` under `config`: for a
  /// brokered VM, `brokered` is resolved by the caller before the boot so
  /// the runtime can be started with its digest.
  package static func make(_ config: IsoConfig, brokered: BrokeredNetworkPolicy?) -> NetworkPolicy {
    var record = make(config)
    record.brokered = brokered
    return record
  }

  /// The brokered policy `config` resolves to for `instance`, or nil for vmnet.
  package static func resolveBrokered(
    _ config: IsoConfig, _ instance: Instance, guestEnvironment: [EnvVarName: EnvValue]? = nil
  ) throws -> BrokeredNetworkPolicy? {
    guard config.network.transport == .brokered else { return nil }
    return try BrokeredNetworkPolicy.resolve(config, instance, guestEnvironment: guestEnvironment)
  }

  private static func hash(mode: String, hosts: [String]) -> String {
    let canonical = "mode=\(mode)\nhosts=\(hosts.joined(separator: ","))\nport=443\n"
    return "sha256:" + sha256Hex(Array(canonical.utf8))
  }

  package static func save(_ config: IsoConfig, _ instance: Instance) throws {
    try save(config, instance, brokered: try resolveBrokered(config, instance))
  }

  package static func save(
    _ config: IsoConfig, _ instance: Instance, brokered: BrokeredNetworkPolicy?
  ) throws {
    try StateStore.writeControlFile(make(config, brokered: brokered), to: path(instance))
  }

  package static func load(_ instance: Instance) throws -> NetworkPolicy? {
    let path = path(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    let record = try StateStore.decode(NetworkPolicy.self, bytes, path: path)
    guard record.backend == StateSchema.backend else {
      throw HostError("\(path) is not a supported network policy record")
    }
    guard let mode = EgressMode(rawValue: record.mode),
      mode == .filtered || record.allowedHosts.isEmpty,
      record.allowedHosts == Set(record.allowedHosts).sorted(),
      record.allowedHosts.allSatisfy({ (try? ExactHostname($0))?.rawValue == $0 }),
      record.policyHash == hash(mode: record.mode, hosts: record.allowedHosts),
      record.brokeredConsistent(mode)
    else { throw HostError("\(path) has an invalid or inconsistent network policy") }
    return record
  }

  /// A brokered record's egress half agrees with its boot policy.
  private func brokeredConsistent(_ mode: EgressMode) -> Bool {
    guard let brokered else { return true }
    switch brokered.publicEgress {
    case nil: return mode == .none
    case let egress?:
      return mode == .filtered && egress.allowedHosts == allowedHosts
        && egress.policyHash == policyHash
    }
  }

  /// Require the fixed mode and transport before boot; allowlists and the
  /// brokered policy are checked separately.
  @discardableResult
  package static func enforceMode(_ instance: Instance, config: IsoConfig) throws -> NetworkPolicy {
    guard let recorded = try load(instance) else {
      throw HostError(
        "Instance '\(instance.name)' has no recorded network policy. Recreate it with `iso destroy` and `iso up`; its creation-time egress policy cannot be established."
      )
    }
    guard recorded.mode == config.egress.rawValue else {
      throw HostError(
        "POLICY_CHANGE_REQUIRES_RESTART: instance '\(instance.name)' was created with egress \(recorded.mode), not \(config.egress.rawValue). Recreate it to change mode."
      )
    }
    guard recorded.recordedTransport == config.network.transport else {
      throw HostError(
        "POLICY_CHANGE_REQUIRES_RESTART: instance '\(instance.name)' was created with network.transport \(recorded.recordedTransport.rawValue), not \(config.network.transport.rawValue). The transport is fixed at creation and never converted; recreate the instance to change it."
      )
    }
    return recorded
  }

  /// Require the complete boot policy at every running-guest handoff.
  @discardableResult
  package static func enforce(_ instance: Instance, config: IsoConfig) throws -> NetworkPolicy {
    let recorded = try enforceMode(instance, config: config)
    guard recorded.allowedHosts == make(config).allowedHosts else {
      throw HostError(
        "POLICY_CHANGE_REQUIRES_RESTART: filtered allowlist differs from the recorded boot policy for '\(instance.name)'. Stop and start it to apply the new allowlist."
      )
    }
    if recorded.recordedTransport == .brokered {
      let current = try BrokeredNetworkPolicy.resolve(config, instance)
      guard current.digest == recorded.brokeredDigest else {
        throw HostError(
          "POLICY_CHANGE_REQUIRES_RESTART: the brokered network policy of '\(instance.name)' (provider grants, local services or egress) differs from the one its boot was started with. Stop and start it to apply the new policy."
        )
      }
    }
    return recorded
  }
}

/// `network-policy.json`: schema 3 carries no `brokered` member, schema 4
/// requires one; any other combination fails to decode.
extension NetworkPolicy: Codable {
  enum CodingKeys: String, CodingKey {
    case schemaVersion, backend, mode, allowedHosts, policyHash, brokered
  }

  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let schema = try c.decode(UInt32.self, forKey: .schemaVersion)
    backend = try c.decode(String.self, forKey: .backend)
    mode = try c.decode(String.self, forKey: .mode)
    allowedHosts = try c.decode([String].self, forKey: .allowedHosts)
    policyHash = try c.decode(String.self, forKey: .policyHash)
    switch schema {
    case Self.currentSchema:
      guard !c.contains(.brokered) else {
        throw DecodingError.dataCorruptedError(
          forKey: .brokered, in: c, debugDescription: "schema 3 has no brokered policy")
      }
      brokered = nil
    case Self.brokeredSchema:
      brokered = try c.decode(BrokeredNetworkPolicy.self, forKey: .brokered)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: c, debugDescription: "unsupported network policy schema")
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(backend, forKey: .backend)
    try c.encode(mode, forKey: .mode)
    try c.encode(allowedHosts, forKey: .allowedHosts)
    try c.encode(policyHash, forKey: .policyHash)
    try c.encodeIfPresent(brokered, forKey: .brokered)
  }
}
