import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy
import IsoSecrets
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

/// POL-01/MIG-01: the effective report compares requested with recorded
/// policy, names every relaxation, and stays read-only.
@Test func effectivePolicyReportNamesRelaxationsAndRecordedConflicts() throws {
  let instance = try testInstance(try scratchDirectory("effective") + "/instances/dev")
  let open = try testConfig(#""egress": "open", "workspace": {"pull": {"mode": "direct"}}"#)
  try NetworkPolicy.save(open, instance)
  let strict = try testConfig(
    #""egress": "none", "proxy": {"mode": "required"}, "network": {"transport": "brokered"}, "workspace": {"pull": {"mode": "stage"}}, "limits": {"session_ttl": "8h"}"#
  )
  let before = try FileManager.default.contentsOfDirectory(atPath: instance.directory).sorted()
  let report = EffectivePolicyReport.json(strict, instance: instance)
  let text = EffectivePolicyReport.text(report).joined(separator: "\n")
  #expect(text.contains("Relaxations: none"))
  #expect(text.contains("egress is fixed at open"))
  #expect(text.contains("transport is fixed at vmnet"))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: instance.directory).sorted() == before)
  let relaxed = EffectivePolicyReport.relaxations(open)
  #expect(relaxed.contains { $0.hasPrefix("egress open") })
  #expect(relaxed.contains { $0.hasPrefix("workspace.pull.mode direct") })
}

/// `--json` fields keep one type: an unlimited TTL and an unreadable record
/// are null (the latter named in `unknown`), never a placeholder string.
@Test func effectivePolicyJSONKeepsOneTypePerField() throws {
  let instance = try testInstance(try scratchDirectory("effective-json") + "/instances/dev")
  try writeFile(instance.directory + "/grants.json", "{corrupt")
  let unlimited = try testConfig(#""limits": {"session_ttl": "unlimited"}"#)
  guard case .object(let top) = EffectivePolicyReport.json(unlimited, instance: instance),
    case .object(let requested)? = top.first(where: { $0.0 == "requested" })?.1,
    case .object(let recorded)? = top.first(where: { $0.0 == "instance" })?.1
  else {
    Issue.record("unexpected report shape")
    return
  }
  let fields = Dictionary(recorded, uniquingKeysWith: { a, _ in a })
  #expect(requested.first { $0.0 == "session_ttl_seconds" }?.1 == .null)
  #expect(fields["grants"] == .null && fields["revoked"] == .null)
  #expect(
    fields["unknown"]
      == .array(
        ["transport", "egress", "grants", "pending_revocations", "revoked"].map(OutputJSON.string)))
  let text = EffectivePolicyReport.text(EffectivePolicyReport.json(unlimited, instance: instance))
  #expect(text.contains("  session_ttl_seconds: unlimited"))
  #expect(text.contains("  grants: unknown"))
}

/// POL-01: saved grants carry provenance; legacy ones are withheld (not
/// erased) until given again; a revocation withdraws exactly one, survives
/// removing the setting, and an unknown ID is an error.
@Test func savedGrantsAreRevokedByIDAndStayRevoked() throws {
  let instance = try testInstance(try scratchDirectory("grants") + "/instances/dev")
  let keep = try EnvVarName("KEEP")
  let drop = try EnvVarName("DROP")
  let old = try EnvVarName("OLD")
  let forward = try PortForward(guest: 8080, host: 18080)
  var r = try GrantLedger.reconcile(
    instance, revoked: [],
    environment: [keep: .literal("1"), drop: .literal("2"), old: .literal("3")],
    forwards: [forward], fresh: ["KEEP", "DROP", "18080:8080"])
  let ledger = try GrantLedger.load(instance)
  #expect(ledger.grants.count == 4)
  #expect(ledger.grants.first { $0.scope == "OLD" }?.origin == .legacy)
  // The legacy entry is kept on disk but not handed to the boot.
  #expect(r.savedEnvironment[old] == .literal("3") && r.appliedEnvironment[old] == nil)
  #expect(r.withheld == ["--env OLD"])
  let dropID = try #require(ledger.grants.first { $0.scope == "DROP" }).id

  // An ID no instance records (its instance destroyed) is reported, and
  // withdraws nothing.
  let stray = try GrantLedger.reconcile(
    instance, revoked: ["0123456789abcdef"], environment: r.savedEnvironment,
    forwards: r.savedForwards, fresh: [])
  #expect(stray.unknownRevoked == ["0123456789abcdef"])
  #expect(stray.savedEnvironment == r.savedEnvironment)
  r = try GrantLedger.reconcile(
    instance, revoked: [dropID], environment: r.savedEnvironment, forwards: r.savedForwards,
    fresh: [])
  #expect(r.savedEnvironment[drop] == nil && r.appliedEnvironment[keep] == .literal("1"))
  #expect(r.appliedForwards == [forward])
  // Sessions forward only live command grants: the legacy OLD and the
  // revoked DROP are withheld, and a revocation only in the configuration
  // applies before any restart.
  #expect(try GrantLedger.sessionEnvironment(instance, revoked: []) == ["KEEP"])
  let keepID = try #require(try GrantLedger.load(instance).grants.first { $0.scope == "KEEP" }).id
  #expect(try GrantLedger.sessionEnvironment(instance, revoked: [keepID]).isEmpty)
  // Given again on the command line: a legacy entry becomes a command grant,
  // and a revoked one gets a new ID; the tombstone stays.
  var again = r.savedEnvironment
  again[drop] = .literal("again")
  r = try GrantLedger.reconcile(
    instance, revoked: [], environment: again, forwards: r.savedForwards, fresh: ["DROP", "OLD"])
  let after = try GrantLedger.load(instance)
  #expect(after.revoked == [dropID])
  #expect(after.grants.first { $0.scope == "DROP" }.map { $0.id != dropID } == true)
  #expect(after.grants.first { $0.scope == "OLD" }?.origin == .command)
  #expect(r.appliedEnvironment[old] == .literal("3") && r.withheld.isEmpty)
  // Another instance's ID is not an error here.
  _ = try GrantLedger.reconcile(
    instance, revoked: ["fedcba9876543210"], environment: r.savedEnvironment,
    forwards: r.savedForwards, fresh: [], knownElsewhere: ["fedcba9876543210"])
}

@Test func legacyForwardsAreWithheldAndRevocableByID() throws {
  let instance = try testInstance(try scratchDirectory("grant-forwards") + "/instances/dev")
  let given = try PortForward(guest: 3000, host: 13000)
  let legacy = try PortForward(guest: 4000, host: 14000)
  var r = try GrantLedger.reconcile(
    instance, revoked: [], environment: [:], forwards: [given, legacy], fresh: ["13000:3000"])
  // A forward saved without provenance stays saved but is not applied.
  #expect(r.appliedForwards == [given])
  #expect(r.savedForwards == [given, legacy])
  #expect(r.withheld == ["forward 14000:4000"])
  let ledger = try GrantLedger.load(instance)
  #expect(ledger.grants.first { $0.scope == "14000:4000" }?.origin == .legacy)
  let givenID = try #require(ledger.grants.first { $0.scope == "13000:3000" }).id

  // Revoking a forward grant by ID drops it from both sets.
  r = try GrantLedger.reconcile(
    instance, revoked: [givenID], environment: [:], forwards: r.savedForwards, fresh: [])
  #expect(r.appliedForwards.isEmpty)
  #expect(r.savedForwards == [legacy])
  #expect(try GrantLedger.load(instance).revoked == [givenID])
}
