/// Static matches and the mandatory guards for one request batch.
public struct StaticEvaluation: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    /// Every governed action has a permit and no forbid.
    case permitted
    /// No action in the batch is governed.
    case notGoverned
    case denied(PolicyReason)
  }

  public let outcome: Outcome
  /// Governed requests in the batch; ungoverned ones are left to existing checks.
  public let governed: [PolicyRequest]
  public let matchedPermitIDs: [String]
  public let matchedForbidIDs: [String]
  /// Every guard matching a governed action and its concrete resource,
  /// regardless of which permit matched. Sorted by ID.
  public let guards: [PolicyGuard]

  /// The approval guards among `guards`, as (ID, seconds).
  public var approvalGuards: [(id: String, seconds: Int)] {
    guards.compactMap { entry in
      if case .approvalWithin(let seconds) = entry.requirement { (entry.id, seconds) } else { nil }
    }
  }

  public var requiresApproval: Bool { !approvalGuards.isEmpty }
}

public enum PolicyEvaluator {
  /// Pure: any matching forbid denies; otherwise each governed action needs
  /// a permit. Rule order is not precedence. Never mutates state.
  public static func evaluateStatic(_ requests: [PolicyRequest], policy: CompiledPolicy)
    -> StaticEvaluation
  {
    let governed = requests.filter { policy.governedActions.contains($0.action) }
    guard !governed.isEmpty else {
      return StaticEvaluation(
        outcome: .notGoverned, governed: [], matchedPermitIDs: [], matchedForbidIDs: [],
        guards: [])
    }
    var permits = Set<String>()
    var forbids = Set<String>()
    var unpermitted = false
    var guards: [String: PolicyGuard] = [:]
    for request in governed {
      let rules = policy.document.rules.filter {
        matches(action: $0.action, resources: $0.resources, instances: $0.instances, request)
      }
      let requestPermits = rules.filter { $0.effect == .permit }.map(\.id)
      forbids.formUnion(rules.filter { $0.effect == .forbid }.map(\.id))
      permits.formUnion(requestPermits)
      if requestPermits.isEmpty { unpermitted = true }
      for entry in policy.document.guards
      where matches(
        action: entry.action, resources: entry.resources, instances: entry.instances, request)
      {
        guards[entry.id] = entry
      }
    }
    let outcome: StaticEvaluation.Outcome =
      !forbids.isEmpty ? .denied(.explicitForbid) : (unpermitted ? .denied(.noPermit) : .permitted)
    return StaticEvaluation(
      outcome: outcome, governed: governed, matchedPermitIDs: sortedBytes(Array(permits)),
      matchedForbidIDs: sortedBytes(Array(forbids)),
      guards: guards.values.sorted { utf8Less($0.id, $1.id) })
  }

  static func matches(
    action: PolicyAction, resources: [PolicyResource], instances: [String]?,
    _ request: PolicyRequest
  ) -> Bool {
    action == request.action && resources.contains(request.resource)
      && (instances?.contains(request.instance) ?? true)
  }

  /// The provider-action pair one proxied request checks.
  public static func providerBatch(_ provider: PolicyResource, instance: String)
    -> [PolicyRequest]
  {
    [
      PolicyRequest(action: .credentialUse, resource: provider, instance: instance),
      PolicyRequest(action: .proxyRequest, resource: provider, instance: instance),
    ]
  }
}
