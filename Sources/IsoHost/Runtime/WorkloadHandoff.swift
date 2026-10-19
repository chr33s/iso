import IsoConfiguration
import IsoCore

/// Public identities actually verified during resolution, not files reread
/// afterwards. Process-local only: neither this identity nor its proof is Codable.
enum WorkloadHandoff {
  struct Identity: Sendable, Equatable {
    let policy: FilteredHandoff.BootPolicy
    let egressKey: String
    let brokerKeys: [ProxyProvider: String]
  }

  static func bind(
    _ expected: AppleBackend.Running,
    inspect: @escaping @Sendable () throws -> AppleBackend.Running?
  ) -> SSHTarget {
    guard expected.hasLiveProof else { return expected.target }
    return expected.target.validating { try require(expected, inspect: inspect) }
  }

  /// Bootstrap may replace brokers, never the original transport identity.
  static func requireTransport(_ expected: AppleBackend.Running, _ current: AppleBackend.Running)
    throws
  {
    guard let identity = expected.handoffIdentity else { return }
    guard current.ready == expected.ready, current.target == expected.target,
      current.handoffIdentity?.policy == identity.policy,
      current.handoffIdentity?.egressKey == identity.egressKey
    else {
      throw HostError(
        "FILTERED_HANDOFF_CHANGED: bootstrap completion no longer matches the prepared transport identity"
      )
    }
  }

  /// A fresh proof must describe the same prepared session. A healthy new
  /// boot or restarted broker is not permission to reuse the old environment.
  static func require(
    _ expected: AppleBackend.Running,
    inspect: () throws -> AppleBackend.Running?
  ) throws {
    // Vmnet launches without filtered egress keep their existing behavior.
    guard expected.hasLiveProof else { return }
    let kind = expected.handoffIdentity != nil ? "FILTERED" : "BROKERED"
    guard let current = try inspect() else {
      throw HostError("\(kind)_HANDOFF_NOT_READY: instance stopped before guest operation")
    }
    // A brokered route carries the boot id and both digests, so a restart
    // or a new policy is a different route.
    guard expected.ready == current.ready,
      expected.target == current.target,
      expected.handoffIdentity == current.handoffIdentity
    else {
      throw HostError(
        "\(kind)_HANDOFF_CHANGED: prepared session no longer matches the live readiness identity; reopen the session"
      )
    }
  }
}

extension AppleBackend.Running {
  /// Whether this handoff has a live proof that later guest operations and
  /// running workloads must keep matching: filtered egress, or a brokered
  /// boot (whose route binds its boot id and policy digests).
  package var hasLiveProof: Bool {
    handoffIdentity != nil || ready.route.transport == .brokered
  }
}
