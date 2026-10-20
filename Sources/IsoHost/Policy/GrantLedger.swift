import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets

/// Provenance for an instance's saved command grants (POL-01): the
/// start-time guest environment entries and port forwards that later
/// starts re-apply. Each has an opaque ID, its capability and scope, where
/// it came from and how long it lasts. `security.revoked_grant_ids`
/// withdraws one by ID; the tombstone is recorded here, owner-only, before
/// the instance is handed out again, and survives removing the setting.
package struct GrantLedger: Codable, Equatable, Sendable {
  package enum Capability: String, Codable, Sendable {
    case guestEnvironment = "guest_env"
    case portForward = "forward"
  }

  package enum Origin: String, Codable, Sendable {
    /// Given on the command line (or by an accepted devcontainer) at start.
    case command
    /// Saved by an earlier iso without provenance; shown so it can be
    /// reviewed and revoked. An ID is a handle, not an authorization.
    case legacy
  }

  package struct Grant: Codable, Equatable, Sendable {
    package let id: String
    package let capability: Capability
    package let scope: String
    package let origin: Origin
    /// Always `instance` here: these grants outlive a boot by design.
    package var persistence = "instance"
    package let createdAt: String

    enum CodingKeys: String, CodingKey {
      case id, capability, scope, origin, persistence
      case createdAt = "created_at"
    }
  }

  package var schema = 1
  package var grants: [Grant] = []
  /// Revoked IDs, kept so a removed setting does not restore the grant.
  package var revoked: [String] = []

  static func path(_ instance: Instance) -> String { instance.directory + "/grants.json" }

  package static func load(_ instance: Instance) throws -> GrantLedger {
    let path = path(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return GrantLedger() }
    let ledger = try StateStore.decode(GrantLedger.self, bytes, path: path)
    guard ledger.schema == 1 else { throw HostError("\(path) has an unsupported schema") }
    return ledger
  }

  /// Every grant and tombstone ID across the configuration's instances,
  /// except `instance`'s own. Unreadable ledgers contribute nothing.
  package static func knownIDs(_ config: IsoConfig, except instance: Instance) -> Set<String> {
    let instances = (try? InstanceStore.list(config, skipped: { _, _ in })) ?? []
    var ids = Set<String>()
    for other in instances where other.directory != instance.directory {
      if let ledger = try? load(other) {
        ids.formUnion(ledger.grants.map(\.id))
        ids.formUnion(ledger.revoked)
      }
    }
    return ids
  }

  func save(_ instance: Instance) throws {
    try StateStore.writeControlFile(self, to: Self.path(instance))
  }

  static func scope(_ name: EnvVarName) -> String { name.rawValue }
  static func scope(_ forward: PortForward) -> String { "\(forward.host):\(forward.guest)" }

  /// What a reconciliation hands to the boot (`applied`), what stays in the
  /// saved files (`saved`: still includes withheld legacy entries, so
  /// nothing is erased), and the legacy entries withheld until they are
  /// given again on the command line.
  package struct Reconciled: Sendable {
    package var appliedEnvironment: [EnvVarName: EnvValue]
    package var appliedForwards: [PortForward]
    package var savedEnvironment: [EnvVarName: EnvValue]
    package var savedForwards: [PortForward]
    package var withheld: [String]
    /// Revoked IDs no instance knows (for example one whose instance was
    /// destroyed): reported, never a reason to refuse the boot.
    package var unknownRevoked: [String]
  }

  /// Saved guest environment names a session may forward: each needs a
  /// command grant that neither the ledger nor `revoked` withdraws. Legacy
  /// and revoked entries stay in `guest_env.json` but reach no session, so
  /// a revocation holds from the next handoff, not the next restart. An
  /// unreadable ledger fails closed.
  package static func sessionEnvironment(_ instance: Instance, revoked: [String]) throws
    -> Set<String>
  {
    let ledger = try load(instance)
    let withdrawn = Set(ledger.revoked).union(revoked)
    return Set(
      ledger.grants.filter {
        $0.capability == .guestEnvironment && $0.origin == .command && !withdrawn.contains($0.id)
      }.map(\.scope))
  }

  /// Applies `revoked` (tombstoning each active grant and dropping its
  /// entry), records provenance for every saved entry without a grant
  /// (`fresh` entries came from this command, the rest are legacy), and
  /// withholds every legacy grant: an entry saved without provenance is
  /// applied again only when it is given again explicitly, which records it
  /// as a new command grant (POL-01). Saved before any handoff. An ID that
  /// names no grant of any instance is returned in `unknownRevoked`.
  package static func reconcile(
    _ instance: Instance, revoked: [String], environment: [EnvVarName: EnvValue],
    forwards: [PortForward], fresh: Set<String>, knownElsewhere: Set<String> = [],
    now: String = utcTimestamp()
  ) throws -> Reconciled {
    var environment = environment
    var forwards = forwards
    var ledger = try load(instance)
    let mine = Set(ledger.grants.map(\.id)).union(ledger.revoked)
    let unknown = revoked.filter { !mine.contains($0) && !knownElsewhere.contains($0) }
    // Another instance's IDs are that instance's business.
    for id in revoked where mine.contains(id) && !ledger.revoked.contains(id) {
      ledger.revoked.append(id)
    }
    let withdrawn = ledger.grants.filter { ledger.revoked.contains($0.id) }
    ledger.grants.removeAll { ledger.revoked.contains($0.id) }
    for grant in withdrawn {
      switch grant.capability {
      case .guestEnvironment:
        if let name = try? EnvVarName(grant.scope), !fresh.contains(grant.scope) {
          environment[name] = nil
        }
      case .portForward:
        if !fresh.contains(grant.scope) { forwards.removeAll { scope($0) == grant.scope } }
      }
    }
    func record(_ capability: Capability, _ scope: String) {
      if let index = ledger.grants.firstIndex(where: {
        $0.capability == capability && $0.scope == scope
      }) {
        // Given again explicitly: a legacy entry becomes a command grant.
        guard ledger.grants[index].origin == .legacy, fresh.contains(scope) else { return }
        ledger.grants.remove(at: index)
      }
      ledger.grants.append(
        Grant(
          id: randomHex(8), capability: capability, scope: scope,
          origin: fresh.contains(scope) ? .command : .legacy, createdAt: now))
    }
    for name in environment.keys.sorted() { record(.guestEnvironment, scope(name)) }
    for forward in forwards { record(.portForward, scope(forward)) }
    // Grants whose entry is gone (overwritten or dropped) are not kept.
    let liveEnvironment = Set(environment.keys.map(scope))
    let liveForwards = Set(forwards.map(scope))
    ledger.grants.removeAll {
      $0.capability == .guestEnvironment
        ? !liveEnvironment.contains($0.scope) : !liveForwards.contains($0.scope)
    }
    try ledger.save(instance)
    let legacy = ledger.grants.filter { $0.origin == .legacy }
    let legacyEnvironment = Set(legacy.filter { $0.capability == .guestEnvironment }.map(\.scope))
    let legacyForwards = Set(legacy.filter { $0.capability == .portForward }.map(\.scope))
    return Reconciled(
      appliedEnvironment: environment.filter { !legacyEnvironment.contains(scope($0.key)) },
      appliedForwards: forwards.filter { !legacyForwards.contains(scope($0)) },
      savedEnvironment: environment, savedForwards: forwards,
      withheld: legacy.map { "\($0.capability == .portForward ? "forward" : "--env") \($0.scope)" },
      unknownRevoked: unknown)
  }
}
