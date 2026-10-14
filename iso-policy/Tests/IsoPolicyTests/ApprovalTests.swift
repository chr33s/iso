import Testing

@testable import IsoPolicy

private let workspacePolicy = try! compile(
  policyJSON(
    rules: rule("apply", "permit", "workspace.pull.apply", ["workspace:attached"]),
    guards: approvalGuard("review", seconds: 900) + "," + approvalGuard("recent", seconds: 60)))

private let binding = ApprovalBinding(
  instanceID: "instance", bootID: "boot", policyEpoch: "epoch",
  policyDigest: workspacePolicy.digest, workspaceIdentity: "workspace",
  destinationIdentity: "1:2", stageID: "abcd1234", manifestDigest: "sha256:m")

private func check(
  _ receipt: inout ApprovalReceipt?, expected: ApprovalBinding = binding, now: UInt64?,
  policy: CompiledPolicy = workspacePolicy
) -> PolicyDecision {
  ApprovalCheck.authorizeAndConsume(
    &receipt, expected: expected, policy: policy, instance: "vm", now: now, decisionID: "d")
}

private func issued(at time: UInt64 = 10 * second) -> ApprovalReceipt? {
  ApprovalReceipt(approvalID: "a", binding: binding, issuedAt: time)
}

@Test func freshExactReceiptAllowsOnceAndIsConsumed() {
  var receipt = issued()
  let decision = check(&receipt, now: 20 * second)
  #expect(decision.verdict == .allow)
  #expect(decision.requiredGuardIDs == ["recent", "review"])
  #expect(receipt?.consumed == true)
  #expect(check(&receipt, now: 21 * second).reason == .approvalConsumed)
}

@Test func missingReceipt() {
  var receipt: ApprovalReceipt? = nil
  let decision = check(&receipt, now: 1)
  #expect(decision.reason == .approvalRequired)
  #expect(decision.failedGuardIDs == ["recent", "review"])
}

@Test func everyFreshnessBoundApplies() {
  // 60 s is the tighter guard; its boundary is exclusive.
  var atBoundary = issued()
  let expired = check(&atBoundary, now: 70 * second)
  #expect(expired.reason == .approvalExpired)
  #expect(expired.failedGuardIDs == ["recent"])
  #expect(atBoundary?.consumed == true)
  var justInside = issued()
  #expect(check(&justInside, now: 70 * second - 1).verdict == .allow)
}

@Test func anyBindingChangeIsAMismatch() {
  let changes: [ApprovalBinding] = [
    .init(
      instanceID: "other", bootID: "boot", policyEpoch: "epoch", policyDigest: binding.policyDigest,
      workspaceIdentity: "workspace", destinationIdentity: "1:2", stageID: "abcd1234",
      manifestDigest: "sha256:m"),
    .init(
      instanceID: "instance", bootID: "boot", policyEpoch: "epoch-2",
      policyDigest: binding.policyDigest, workspaceIdentity: "workspace",
      destinationIdentity: "1:2", stageID: "abcd1234", manifestDigest: "sha256:m"),
    .init(
      instanceID: "instance", bootID: "boot", policyEpoch: "epoch",
      policyDigest: binding.policyDigest, workspaceIdentity: "workspace",
      destinationIdentity: "1:3", stageID: "abcd1234", manifestDigest: "sha256:m"),
    .init(
      instanceID: "instance", bootID: "boot", policyEpoch: "epoch",
      policyDigest: binding.policyDigest, workspaceIdentity: "workspace",
      destinationIdentity: "1:2", stageID: "ffff0000", manifestDigest: "sha256:m"),
    .init(
      instanceID: "instance", bootID: "boot", policyEpoch: "epoch",
      policyDigest: binding.policyDigest, workspaceIdentity: "workspace",
      destinationIdentity: "1:2", stageID: "abcd1234", manifestDigest: "sha256:changed"),
  ]
  for expected in changes {
    var receipt = issued()
    #expect(check(&receipt, expected: expected, now: 11 * second).reason == .approvalMismatch)
    #expect(receipt?.consumed == true)
  }
}

@Test func clockRegressionDenies() {
  var receipt = issued(at: 10 * second)
  #expect(check(&receipt, now: 9 * second).reason == .internalError)
  var invalid = issued()
  #expect(check(&invalid, now: nil).reason == .internalError)
}

@Test func noApprovalGuardNeedsNoReceipt() throws {
  let policy = try compile(
    policyJSON(rules: rule("apply", "permit", "workspace.pull.apply", ["workspace:attached"])))
  var receipt: ApprovalReceipt? = nil
  #expect(check(&receipt, now: 1, policy: policy).verdict == .allow)
}

@Test func forbidAndNotGovernedComeBeforeTheReceipt() throws {
  let forbidden = try compile(
    policyJSON(
      rules: rule("apply", "permit", "workspace.pull.apply", ["workspace:attached"]) + ","
        + rule("no", "forbid", "workspace.pull.apply", ["workspace:attached"]),
      guards: approvalGuard("review", seconds: 900)))
  var receipt = issued()
  #expect(check(&receipt, now: 11 * second, policy: forbidden).reason == .explicitForbid)
  #expect(receipt?.consumed == false)
  let ungoverned = try compile(policyJSON(actions: ["proxy.request"]))
  #expect(check(&receipt, now: 11 * second, policy: ungoverned).verdict == .notGoverned)
}
