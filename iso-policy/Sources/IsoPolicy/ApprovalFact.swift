/// What one approval authorizes: one exact staged apply attempt.
public struct ApprovalBinding: Sendable, Equatable {
  public let instanceID: String
  public let bootID: String
  public let policyEpoch: String
  public let policyDigest: String
  /// From the host workspace record, not a user-supplied path.
  public let workspaceIdentity: String
  /// The checked destination directory handle (`device:inode`).
  public let destinationIdentity: String
  public let stageID: String
  /// Covers the complete authorized mutation plan.
  public let manifestDigest: String

  public init(
    instanceID: String, bootID: String, policyEpoch: String, policyDigest: String,
    workspaceIdentity: String, destinationIdentity: String, stageID: String,
    manifestDigest: String
  ) {
    self.instanceID = instanceID
    self.bootID = bootID
    self.policyEpoch = policyEpoch
    self.policyDigest = policyDigest
    self.workspaceIdentity = workspaceIdentity
    self.destinationIdentity = destinationIdentity
    self.stageID = stageID
    self.manifestDigest = manifestDigest
  }
}

/// An in-memory record of an explicit trusted-host confirmation. Not a
/// proof that a person read every file; never persisted, exported, or
/// reconstructed. Process exit discards it.
public struct ApprovalReceipt: Sendable, Equatable {
  public let approvalID: String
  public let action = PolicyAction.workspacePullApply
  public let binding: ApprovalBinding
  /// `MonotonicClock` nanoseconds in the issuing process.
  public let issuedAt: UInt64
  public private(set) var consumed = false

  public init(approvalID: String, binding: ApprovalBinding, issuedAt: UInt64) {
    self.approvalID = approvalID
    self.binding = binding
    self.issuedAt = issuedAt
  }

  mutating func consume() { consumed = true }
}

public enum ApprovalCheck {
  /// Whether applying in `instance` needs a receipt at all, before prompting.
  public static func evaluate(_ policy: CompiledPolicy, instance: String) -> StaticEvaluation {
    PolicyEvaluator.evaluateStatic(
      [
        PolicyRequest(action: .workspacePullApply, resource: .attachedWorkspace, instance: instance)
      ],
      policy: policy)
  }

  /// Verifies the receipt against `expected` and every matching approval
  /// guard (`0 <= now - issuedAt < seconds`), consuming it on any attempt:
  /// a receipt authorizes at most one check, allowed or not.
  public static func authorizeAndConsume(
    _ receipt: inout ApprovalReceipt?, expected: ApprovalBinding, policy: CompiledPolicy,
    instance: String, now: UInt64?, decisionID: String
  ) -> PolicyDecision {
    let evaluation = evaluate(policy, instance: instance)
    func decision(_ reason: PolicyReason, failed: [String] = []) -> PolicyDecision {
      .from(
        evaluation, policy: policy, epoch: expected.policyEpoch, decisionID: decisionID,
        reason: reason, failed: failed)
    }
    switch evaluation.outcome {
    case .notGoverned: return decision(.notGoverned)
    case .denied(let reason): return decision(reason)
    case .permitted: break
    }
    let approvals = evaluation.approvalGuards
    guard !approvals.isEmpty else { return decision(.allowed) }
    guard var current = receipt else {
      return decision(.approvalRequired, failed: approvals.map(\.0))
    }
    defer { receipt = current }
    guard !current.consumed else { return decision(.approvalConsumed) }
    current.consume()
    guard current.binding == expected, current.binding.policyDigest == policy.digest else {
      return decision(.approvalMismatch)
    }
    guard let now, now >= current.issuedAt else { return decision(.internalError) }
    let age = now - current.issuedAt
    let expired = approvals.filter { age >= UInt64($0.1) * 1_000_000_000 }.map(\.0)
    guard expired.isEmpty else { return decision(.approvalExpired, failed: expired) }
    return decision(.allowed)
  }
}
