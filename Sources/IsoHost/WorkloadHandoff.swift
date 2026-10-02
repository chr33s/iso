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

  /// A fresh proof must describe the same prepared workload. A healthy new
  /// boot or restarted broker is not permission to reuse the old environment.
  static func require(
    _ expected: AppleBackend.Running,
    inspect: () throws -> AppleBackend.Running?
  ) throws {
    // Nonfiltered launches retain their existing compatibility behavior.
    guard expected.handoffIdentity != nil else { return }
    guard let current = try inspect() else {
      throw HostError("FILTERED_HANDOFF_NOT_READY: instance stopped before workload launch")
    }
    guard expected.ready == current.ready,
      expected.target == current.target,
      expected.handoffIdentity == current.handoffIdentity
    else {
      throw HostError(
        "FILTERED_HANDOFF_CHANGED: prepared session no longer matches the live readiness identity; reopen the session"
      )
    }
  }
}
