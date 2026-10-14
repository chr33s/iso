public enum PolicyVerdict: String, Sendable, Equatable, Codable {
  case allow
  case deny
  /// The policy does not decide this action. Existing checks stay
  /// authoritative; this never authorizes anything by itself.
  case notGoverned = "not_governed"
}

public enum PolicyReason: String, Sendable, Equatable, CaseIterable, Codable {
  case allowed
  case notGoverned = "not_governed"
  case explicitForbid = "explicit_forbid"
  case noPermit = "no_permit"
  case quotaExceeded = "quota_exceeded"
  case approvalRequired = "approval_required"
  case approvalExpired = "approval_expired"
  case approvalMismatch = "approval_mismatch"
  case approvalConsumed = "approval_consumed"
  case policyStateUnavailable = "policy_state_unavailable"
  case policyEpochMismatch = "policy_epoch_mismatch"
  case unsupportedPath = "unsupported_path"
  case internalError = "internal_error"
}

/// A typed decision, never a Boolean. IDs are sorted for stable output.
/// Guest-visible responses carry none of this; it is for host diagnostics.
public struct PolicyDecision: Sendable, Equatable {
  public let verdict: PolicyVerdict
  public let reason: PolicyReason
  public let policyDigest: String
  public let policyEpoch: String
  public let matchedPermitIDs: [String]
  public let matchedForbidIDs: [String]
  public let requiredGuardIDs: [String]
  public let failedGuardIDs: [String]
  public let decisionID: String
  /// For `quota_exceeded`: the rounded-up longest wait across failed guards.
  public let retryAfterSeconds: Int?

  public init(
    verdict: PolicyVerdict, reason: PolicyReason, policyDigest: String, policyEpoch: String,
    matchedPermitIDs: [String] = [], matchedForbidIDs: [String] = [],
    requiredGuardIDs: [String] = [], failedGuardIDs: [String] = [], decisionID: String,
    retryAfterSeconds: Int? = nil
  ) {
    self.verdict = verdict
    self.reason = reason
    self.policyDigest = policyDigest
    self.policyEpoch = policyEpoch
    self.matchedPermitIDs = sortedBytes(matchedPermitIDs)
    self.matchedForbidIDs = sortedBytes(matchedForbidIDs)
    self.requiredGuardIDs = sortedBytes(requiredGuardIDs)
    self.failedGuardIDs = sortedBytes(failedGuardIDs)
    self.decisionID = decisionID
    self.retryAfterSeconds = retryAfterSeconds
  }

  public var allows: Bool { verdict == .allow }

  /// The decision for `evaluation` with `reason` as the final outcome.
  static func from(
    _ evaluation: StaticEvaluation, policy: CompiledPolicy, epoch: String, decisionID: String,
    reason: PolicyReason, failed: [String] = [], retryAfter: Int? = nil
  ) -> PolicyDecision {
    PolicyDecision(
      verdict: reason == .allowed ? .allow : (reason == .notGoverned ? .notGoverned : .deny),
      reason: reason, policyDigest: policy.digest, policyEpoch: epoch,
      matchedPermitIDs: evaluation.matchedPermitIDs, matchedForbidIDs: evaluation.matchedForbidIDs,
      requiredGuardIDs: evaluation.guards.map(\.id), failedGuardIDs: failed,
      decisionID: decisionID, retryAfterSeconds: retryAfter)
  }
}
