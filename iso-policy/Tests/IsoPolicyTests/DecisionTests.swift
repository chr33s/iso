import Testing

@testable import IsoPolicy

private func evaluate(
  _ policy: CompiledPolicy, _ action: PolicyAction, _ resource: PolicyResource,
  instance: String = "vm"
)
  -> StaticEvaluation
{
  PolicyEvaluator.evaluateStatic(
    [PolicyRequest(action: action, resource: resource, instance: instance)], policy: policy)
}

@Test func defaultDenyPermitAndForbidPrecedence() throws {
  let empty = try compile(policyJSON())
  #expect(evaluate(empty, .proxyRequest, .anthropic).outcome == .denied(.noPermit))

  let permitted = try compile(policyJSON(rules: anthropicPermits))
  #expect(evaluate(permitted, .proxyRequest, .anthropic).outcome == .permitted)
  #expect(evaluate(permitted, .proxyRequest, .anthropic).matchedPermitIDs == ["request"])
  // OpenAI has no permit: default deny, no catch-all forbid needed.
  #expect(evaluate(permitted, .proxyRequest, .openai).outcome == .denied(.noPermit))

  let forbidden = try compile(
    policyJSON(
      rules: anthropicPermits + ","
        + rule("deny", "forbid", "proxy.request", ["provider:anthropic"])))
  let result = evaluate(forbidden, .proxyRequest, .anthropic)
  #expect(result.outcome == .denied(.explicitForbid))
  #expect(result.matchedForbidIDs == ["deny"])
  #expect(result.matchedPermitIDs == ["request"])
}

@Test func ruleOrderIsNotPrecedence() throws {
  let permit = rule("p", "permit", "proxy.request", ["provider:anthropic"])
  let forbid = rule("f", "forbid", "proxy.request", ["provider:anthropic"])
  let a = try compile(policyJSON(rules: permit + "," + forbid))
  let b = try compile(policyJSON(rules: forbid + "," + permit))
  #expect(evaluate(a, .proxyRequest, .anthropic) == evaluate(b, .proxyRequest, .anthropic))
  #expect(a.digest == b.digest)
}

@Test func instanceFilters() throws {
  let policy = try compile(
    policyJSON(
      rules: rule("p", "permit", "proxy.request", ["provider:anthropic"], instances: ["one"])))
  #expect(evaluate(policy, .proxyRequest, .anthropic, instance: "one").outcome == .permitted)
  #expect(
    evaluate(policy, .proxyRequest, .anthropic, instance: "two").outcome == .denied(.noPermit))
  let omitted = try compile(
    policyJSON(rules: rule("p", "permit", "proxy.request", ["provider:anthropic"])))
  #expect(evaluate(omitted, .proxyRequest, .anthropic, instance: "two").outcome == .permitted)
}

@Test func unselectedActionsAreNotGoverned() throws {
  let policy = try compile(
    policyJSON(
      actions: ["proxy.request"],
      rules: rule("p", "permit", "proxy.request", ["provider:anthropic"])))
  #expect(evaluate(policy, .credentialUse, .openai).outcome == .notGoverned)
  #expect(evaluate(policy, .workspacePullApply, .attachedWorkspace).outcome == .notGoverned)
  // A batch is decided by its governed members only.
  let batch = PolicyEvaluator.evaluateStatic(
    PolicyEvaluator.providerBatch(.anthropic, instance: "vm"), policy: policy)
  #expect(batch.outcome == .permitted)
  #expect(batch.governed.map(\.action) == [.proxyRequest])
  let openai = PolicyEvaluator.evaluateStatic(
    PolicyEvaluator.providerBatch(.openai, instance: "vm"), policy: policy)
  #expect(openai.outcome == .denied(.noPermit))
}

@Test func modesDecideDifferently() throws {
  for mode in ["off", "shadow", "enforce"] {
    let policy = try compile(policyJSON(mode: mode, rules: anthropicPermits))
    let outcome = evaluate(policy, .proxyRequest, .openai).outcome
    // Off governs nothing; shadow and enforce produce the same policy
    // verdict, which only an enforcing mediator acts on.
    #expect(outcome == (mode == "off" ? .notGoverned : .denied(.noPermit)))
  }
}

@Test func unconditionalPermitDoesNotBypassAGuard() throws {
  // Regression: a later, broader permit must not lift a guard.
  let policy = try compile(
    policyJSON(
      rules: anthropicPermits + ","
        + rule("anything", "permit", "proxy.request", ["provider:anthropic", "provider:openai"])
        + "," + rule("apply", "permit", "workspace.pull.apply", ["workspace:attached"]) + ","
        + rule("apply-again", "permit", "workspace.pull.apply", ["workspace:attached"]),
      guards: rateGuard("limit", max: 1, within: 60) + "," + approvalGuard("review", seconds: 60)))
  #expect(evaluate(policy, .proxyRequest, .anthropic).guards.map(\.id) == ["limit"])
  #expect(evaluate(policy, .workspacePullApply, .attachedWorkspace).guards.map(\.id) == ["review"])
  var admissions = ProviderAdmissions(
    policy: policy, provider: .anthropic, instance: "vm", epoch: "e")
  #expect(admissions.checkAndAdmit(now: 1, decisionID: "1").verdict == .allow)
  #expect(admissions.checkAndAdmit(now: 2, decisionID: "2").reason == .quotaExceeded)
  var receipt: ApprovalReceipt? = nil
  let binding = ApprovalBinding(
    instanceID: "i", bootID: "b", policyEpoch: "e", policyDigest: policy.digest,
    workspaceIdentity: "w", destinationIdentity: "d", stageID: "s", manifestDigest: "m")
  #expect(
    ApprovalCheck.authorizeAndConsume(
      &receipt, expected: binding, policy: policy, instance: "vm", now: 1, decisionID: "3"
    ).reason == .approvalRequired)
}

@Test func decisionIDsAreSorted() {
  let decision = PolicyDecision(
    verdict: .deny, reason: .quotaExceeded, policyDigest: "d", policyEpoch: "e",
    matchedPermitIDs: ["b", "a"], requiredGuardIDs: ["z", "c"], failedGuardIDs: ["y", "x"],
    decisionID: "id")
  #expect(decision.matchedPermitIDs == ["a", "b"])
  #expect(decision.requiredGuardIDs == ["c", "z"])
  #expect(decision.failedGuardIDs == ["x", "y"])
  #expect(!decision.allows)
}
