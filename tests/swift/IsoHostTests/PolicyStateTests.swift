import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy
import Testing

@testable import IsoHost

func compiledPolicy(
  mode: String = "enforce",
  actions: [String] = ["credential.use", "proxy.request", "workspace.pull.apply"],
  rules: String =
    #"{"id":"use","effect":"permit","action":"credential.use","resources":["provider:anthropic"]},{"id":"request","effect":"permit","action":"proxy.request","resources":["provider:anthropic"]},{"id":"apply","effect":"permit","action":"workspace.pull.apply","resources":["workspace:attached"]}"#,
  guards: String =
    #"{"id":"review","action":"workspace.pull.apply","resources":["workspace:attached"],"require":{"approval_within":{"seconds":900}}}"#
) throws -> CompiledPolicy {
  let list = actions.map { "\"\($0)\"" }.joined(separator: ",")
  let json =
    "{\"version\":1,\"mode\":\"\(mode)\",\"actions\":[\(list)],\"rules\":[\(rules)],\"guards\":[\(guards)]}"
  return try PolicyCompiler.compile(
    PolicyDocument.parse(
      PolicyJSON(foundation: JSONSerialization.jsonObject(with: Data(json.utf8)))))
}

private func instance() throws -> Instance {
  try testInstance(try scratchDirectory("policy"))
}

@Test func everyBootRecordsAFreshImmutableBinding() throws {
  let instance = try instance()
  let sink = LogSink()
  let off = try PolicyBoot.begin(instance, configured: nil, diagnostics: sink.diagnostics)
  #expect(off.policyMode == .off)
  #expect(off.canonicalPolicy == nil)
  guard case .off = try ActivePolicy.load(instance) else {
    Issue.record("an explicit off binding must be recorded")
    return
  }
  let policy = try compiledPolicy()
  let first = try PolicyBoot.begin(instance, configured: policy, diagnostics: sink.diagnostics)
  let second = try PolicyBoot.begin(instance, configured: policy, diagnostics: sink.diagnostics)
  #expect(first.instanceID == off.instanceID)
  #expect(second.instanceID == first.instanceID)
  #expect(first.policyEpoch != second.policyEpoch)
  #expect(first.bootID != second.bootID)
  #expect(second.policyDigest == policy.digest)
  #expect(try ActivePolicy.load(instance).policy == policy)
  var info = stat()
  #expect(stat(PolicyBinding.path(instance), &info) == 0 && info.st_mode & 0o777 == 0o600)
  let events = try BoundaryAudit.load(instance).filter { $0["event"] as? String == "policy_boot" }
  #expect(events.count == 3)
  #expect(events.last?["digest"] as? String == policy.digest)
}

@Test func corruptOrTamperedBindingsFailClosed() throws {
  let instance = try instance()
  let sink = LogSink()
  try PolicyBoot.begin(instance, configured: try compiledPolicy(), diagnostics: sink.diagnostics)
  let path = PolicyBinding.path(instance)
  let original = try #require(readFile(path))
  let other = try compiledPolicy(mode: "shadow")
  // A policy swapped under the recorded digest.
  try writeFile(
    path,
    original.replacingOccurrences(
      of: "\"policyMode\" : \"enforce\"", with: "\"policyMode\" : \"shadow\""))
  #expect(throws: HostError.self) { try ActivePolicy.load(instance) }
  try writeFile(path, "{}")
  #expect(throws: HostError.self) { try ActivePolicy.load(instance) }
  #expect(throws: HostError.self) {
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: other, diagnostics: sink.diagnostics)
  }
}

@Test func enforcingBootClaimsOneProxyLaunchPerProvider() throws {
  let instance = try instance()
  let sink = LogSink()
  let policy = try compiledPolicy()
  let binding = try PolicyBoot.begin(instance, configured: policy, diagnostics: sink.diagnostics)
  let startup = try #require(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: policy, diagnostics: sink.diagnostics))
  #expect(startup.policyEpoch == binding.policyEpoch)
  #expect(startup.policyDigest == policy.digest)
  #expect(startup.instanceName == "dev")
  // A second launch in the same epoch would reset the quota: refused,
  // whether or not the first one ever served.
  #expect(throws: HostError.self) {
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: policy, diagnostics: sink.diagnostics)
  }
  #expect(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .openai, configured: policy, diagnostics: sink.diagnostics) != nil)
  // Removing the policy from the configuration does not loosen this boot.
  #expect(throws: HostError.self) {
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: nil, diagnostics: sink.diagnostics)
  }
  #expect(try ProxyAuthorizationStartup.expected(instance, provider: .anthropic) == startup)
  // A new boot is the explicit reset.
  try PolicyBoot.begin(instance, configured: policy, diagnostics: sink.diagnostics)
  #expect(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: policy, diagnostics: sink.diagnostics) != nil)
  let outcomes = try BoundaryAudit.load(instance).compactMap {
    $0["event"] as? String == "policy_proxy_claim" ? $0["outcome"] as? String : nil
  }
  #expect(outcomes == ["claimed", "refused", "claimed", "refused", "claimed"])
}

@Test func shadowRelaunchReportsASimulationReset() throws {
  let instance = try instance()
  let sink = LogSink()
  let policy = try compiledPolicy(mode: "shadow")
  try PolicyBoot.begin(instance, configured: policy, diagnostics: sink.diagnostics)
  let first = try #require(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: policy, diagnostics: sink.diagnostics))
  let second = try #require(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: policy, diagnostics: sink.diagnostics))
  #expect(first.proxyGenerationID != second.proxyGenerationID)
  #expect(sink.text.contains("restarts with empty counters"))
}

@Test func legacyAndUngovernedLaunchesUseTheExistingProtocol() throws {
  let instance = try instance()
  let sink = LogSink()
  // No binding and no requested enforcement: legacy behavior.
  #expect(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: nil, diagnostics: sink.diagnostics) == nil)
  // No binding but enforcement requested: needs a new boot.
  #expect(throws: HostError.self) {
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: try compiledPolicy(),
      diagnostics: sink.diagnostics)
  }
  let workspaceOnly = try compiledPolicy(
    actions: ["workspace.pull.apply"],
    rules:
      #"{"id":"apply","effect":"permit","action":"workspace.pull.apply","resources":["workspace:attached"]}"#
  )
  try PolicyBoot.begin(instance, configured: workspaceOnly, diagnostics: sink.diagnostics)
  #expect(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: workspaceOnly, diagnostics: sink.diagnostics)
      == nil)
}

@Test func version3StartupCarriesPolicyButNoCredentialInIt() throws {
  let instance = try instance()
  let sink = LogSink()
  let policy = try compiledPolicy()
  try PolicyBoot.begin(instance, configured: policy, diagnostics: sink.diagnostics)
  let authorization = try #require(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: policy, diagnostics: sink.diagnostics))
  let wire = ProxyLauncher.wireConfig(
    listen: "127.0.0.1:1", capabilityToken: Secret(String(repeating: "a", count: 64)),
    provider: .anthropic, auth: .apiKey, credential: Secret("synthetic-credential"),
    readiness: .init(identity: .init(), policy: nil, authorization: authorization))
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(wire.expose())) as? [String: Any])
  #expect(object["version"] as? Int == 3)
  let block = try #require(object["authorization"] as? [String: Any])
  #expect(block["policy"] as? String == policy.canonicalJSON)
  #expect(block["policyDigest"] as? String == policy.digest)
  #expect(block["proxyGenerationID"] as? String == authorization.proxyGenerationID)
  let serialized = String(
    decoding: try JSONSerialization.data(withJSONObject: block), as: UTF8.self)
  #expect(!serialized.contains("synthetic-credential"))
  let readiness = try #require(object["readiness"] as? [String: Any])
  #expect(Set(readiness.keys) == ["privateKeyHex"])
  // Off-mode launches keep version 1.
  let legacy = ProxyLauncher.wireConfig(
    listen: "127.0.0.1:1", capabilityToken: Secret(String(repeating: "a", count: 64)),
    provider: .anthropic, auth: .apiKey, credential: Secret("x"))
  let legacyObject = try #require(
    try JSONSerialization.jsonObject(with: Data(legacy.expose())) as? [String: Any])
  #expect(legacyObject["version"] as? Int == 1)
  #expect(legacyObject["authorization"] == nil)
}

@Test func version3ReadinessVerifiesOnlyTheBoundIdentity() throws {
  let signer = try Curve25519.Signing.PrivateKey(
    rawRepresentation: Data(repeating: 0xbb, count: 32))
  let key = try FilteredReadiness.VerificationKey(
    encoded: signer.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined())
  let nonce = String(repeating: "d", count: 32)
  let instance = try instance()
  let policy = try compiledPolicy()
  try PolicyBoot.begin(instance, configured: policy, diagnostics: LogSink().diagnostics)
  let expected = try #require(
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: policy, diagnostics: LogSink().diagnostics))
  func reply(epoch: String? = nil, generation: String? = nil, version: Int = 3) throws -> [UInt8] {
    let epoch = epoch ?? expected.policyEpoch
    let generation = generation ?? expected.proxyGenerationID
    let message = BrokerReadiness.messageV3(
      nonce: nonce, provider: "anthropic", bootID: "", policyHash: "",
      instanceID: expected.instanceID, policyBootID: expected.bootID, policyEpoch: epoch,
      policyDigest: expected.policyDigest, proxyGenerationID: generation)
    let body = try JSONSerialization.data(withJSONObject: [
      "version": version, "nonce": nonce, "provider": "anthropic", "bootID": "", "policyHash": "",
      "instanceID": expected.instanceID, "policyBootID": expected.bootID, "policyEpoch": epoch,
      "policyDigest": expected.policyDigest, "proxyGenerationID": generation,
      "signature": try signer.signature(for: Data(message.utf8)).base64EncodedString(),
    ])
    return Array(
      "HTTP/1.1 200 OK\r\ncontent-length: \(body.count)\r\nconnection: close\r\n\r\n".utf8)
      + body
  }
  #expect(
    BrokerReadiness.verifies(
      try reply(), nonce: nonce, provider: .anthropic, policy: nil, authorization: expected,
      key: key))
  for bad in [
    try reply(epoch: "00000000-0000-4000-8000-000000000009"),
    try reply(generation: "00000000-0000-4000-8000-000000000009"),
    try reply(version: 1),
  ] {
    #expect(
      !BrokerReadiness.verifies(
        bad, nonce: nonce, provider: .anthropic, policy: nil, authorization: expected, key: key))
  }
  // A v3 reply never satisfies a legacy expectation, nor the reverse.
  #expect(
    !BrokerReadiness.verifies(
      try reply(), nonce: nonce, provider: .anthropic,
      policy: .init(bootID: String(repeating: "a", count: 32), policyHash: "sha256:x"),
      authorization: nil, key: key))
  #expect(
    !BrokerReadiness.verifies(
      try reply(), nonce: nonce, provider: .anthropic, policy: nil, authorization: nil, key: key))
}

@Test func policyShowReportsActiveAndPendingWithoutSecrets() throws {
  let instance = try instance()
  let sink = LogSink()
  let unbound = try PolicyReport.json(instance, configured: nil, processObserved: { _ in false })
  #expect(PolicyReport.text(unbound).contains { $0.contains("none recorded") })
  let policy = try compiledPolicy()
  try PolicyBoot.begin(instance, configured: policy, diagnostics: sink.diagnostics)
  _ = try PolicyBoot.claimProxyLaunch(
    instance, provider: .anthropic, configured: policy, diagnostics: sink.diagnostics)
  let current = try PolicyReport.json(
    instance, configured: policy, processObserved: { _ in false })
  #expect(current.compactRendered().contains("\"pending_next_boot\":false"))
  #expect(current.compactRendered().contains("\"process_observed\":false"))
  let edited = try compiledPolicy(mode: "shadow")
  let pending = try PolicyReport.json(
    instance, configured: edited, processObserved: { _ in true })
  #expect(pending.compactRendered().contains("\"pending_next_boot\":true"))
  #expect(PolicyReport.text(pending).contains { $0.contains("applies at the next VM boot") })
  #expect(PolicyReport.text(pending).contains { $0.contains("not a health check") })
}

@Test func aLostBindingAfterPolicyBootsFailsClosed() throws {
  let instance = try instance()
  try PolicyBoot.begin(
    instance, configured: try compiledPolicy(), diagnostics: LogSink().diagnostics)
  unlink(PolicyBinding.path(instance))
  #expect(throws: HostError.self) { try ActivePolicy.load(instance) }
  // Relaxing the configuration does not turn a lost binding into "legacy".
  #expect(throws: HostError.self) {
    try PolicyBoot.claimProxyLaunch(
      instance, provider: .anthropic, configured: nil, diagnostics: LogSink().diagnostics)
  }
}

@Test func anEnforcingBootWithholdsRawKeysWhateverTheConfigSays() throws {
  let guest = try FakeGuest()
  let agents = guest.bootstrap(try testConfig(#""proxy": {"mode": "auto"}"#))
  #expect(agents.withheldVariables(proxyAnthropic: false, proxyOpenAI: false).isEmpty)
  let withheld = agents.withheldVariables(
    proxyAnthropic: false, proxyOpenAI: false, policyEnforced: true)
  #expect(withheld["ANTHROPIC_API_KEY"] != nil)
  #expect(withheld["OPENAI_API_KEY"] != nil)
}
