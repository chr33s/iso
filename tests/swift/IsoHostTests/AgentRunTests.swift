import Foundation
import IsoConfiguration
import Testing

@testable import IsoCore
@testable import IsoHost

@Test func launchPlanReplacesProfilesAndRejectsIncompatibleAdapters() throws {
  let helper = try AgentDefinitionDecoder.decode(
    Array(
      #"{"schema_version":1,"id":"repo-helper","display_name":"h","environment":{"profiles":["node"]},"launch":{"argv":["repo-helper"]},"auth_adapter":"none","network_hints":{"suggested_hosts":["registry.npmjs.org"]}}"#
        .utf8), path: "d.json", format: .json)
  let plan = try AgentLaunchPlanner.plan(
    definition: helper, source: .installed, definitionHash: "sha256:abc", cliImage: nil,
    cliProfiles: ["python", "node"], ask: false)
  #expect(plan.environment.origin == .command)
  #expect(plan.environment.profiles == ["node", "python"])
  #expect(plan.environment.image.rawValue == "node-python")
  #expect(plan.networkHints.map(\.rawValue) == ["registry.npmjs.org"])
  #expect(throws: HostError.self) {
    try AgentLaunchPlanner.plan(
      definition: helper, source: .installed, definitionHash: "h", cliImage: nil, cliProfiles: [],
      ask: true)
  }
  let mismatched = AgentDefinition(
    id: try AgentDefinitionID("other-tool"), displayName: "o", environment: nil,
    launch: AgentLaunchSpec(
      argv: ["other"], workingDirectory: GuestPath("/workspace"), terminal: .auto, environment: []),
    authAdapter: .claude, networkHints: [])
  #expect(throws: HostError.self) {
    try AgentLaunchPlanner.plan(
      definition: mismatched, source: .installed, definitionHash: "h", cliImage: nil,
      cliProfiles: [], ask: false)
  }
}

@Test func dispatchUsesReviewedBinariesAndDoesNotGrantHints() throws {
  let claude = AgentCatalog.builtin(try AgentDefinitionID("claude"))!
  let plan = try AgentLaunchPlanner.plan(
    definition: claude, source: .builtin, definitionHash: AgentCatalog.definitionHash(claude),
    cliImage: nil, cliProfiles: [], ask: true)
  let invocation = try AgentDispatch.invocation(
    plan: plan, passthrough: ["--model", "opus"], guestUser: .default, codexAccount: false,
    stdinIsTerminal: true, stdoutIsTerminal: true)
  #expect(
    invocation.argv == [
      "/home/ubuntu/.local/bin/claude", "--permission-mode", "default", "--model", "opus",
    ])
  #expect(invocation.allocatePTY)
  let generic = try AgentDefinitionDecoder.decode(
    Array(
      #"{"schema_version":1,"id":"repo-helper","display_name":"h","launch":{"argv":["repo-helper","--fixed"],"terminal":"never","environment":{"NO_COLOR":"1"}},"auth_adapter":"none"}"#
        .utf8), path: "d.json", format: .json)
  let genericPlan = try AgentLaunchPlanner.plan(
    definition: generic, source: .installed, definitionHash: "h", cliImage: nil, cliProfiles: [],
    ask: false)
  let genericInvocation = try AgentDispatch.invocation(
    plan: genericPlan, passthrough: ["--help"], guestUser: .default, codexAccount: false,
    stdinIsTerminal: true, stdoutIsTerminal: true)
  #expect(genericInvocation.argv == ["repo-helper", "--fixed", "--help"])
  #expect(!genericInvocation.allocatePTY)
  #expect(genericInvocation.defaults.map(\.name.rawValue) == ["NO_COLOR"])
}

@Test func previewJSONOmitsSecretsAndDoesNotApproveHints() throws {
  let definition = AgentCatalog.builtins[0]
  let plan = try AgentLaunchPlanner.plan(
    definition: definition, source: .builtin, definitionHash: "sha256:abc", cliImage: nil,
    cliProfiles: [], ask: false)
  let preview = RunPreview.make(
    action: .unresolved, instanceName: "dev", match: "workspace", definition: definition,
    source: .builtin, definitionHash: plan.definitionHash, adapter: plan.adapter,
    environment: plan.environment, workingDirectory: plan.workingDirectory, terminal: plan.terminal,
    preparationRequired: false, egress: .none, proxyMode: .required, pullMode: .stage,
    recordedEgress: nil, networkHints: [try ExactHostname("github.com")],
    unresolved: ["runtime state"],
    cleanupIntent: "retain", ask: false, blockedReason: nil)
  let text = preview.json.rendered()
  #expect(text.contains("\"approved_hosts\": []"))
  #expect(text.contains("github.com"))
  #expect(!text.contains("sk-"))
  #expect(!text.contains("cmd:"))
  #expect(text.contains("run_preview"))
}

@Test func catalogInstallUsesTheReviewedValueAndRejectsSymlinks() throws {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "iso-agent-\(UUID().uuidString)"
  )
  .path
  defer { try? FileManager.default.removeItem(atPath: root) }
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  let config = try agentConfig(root)
  let source = root + "/repo-helper.json"
  let text = """
    {"schema_version":1,"id":"repo-helper","display_name":"Helper","launch":{"argv":["repo-helper"]},"auth_adapter":"none"}
    """
  try Data(text.utf8).write(to: URL(fileURLWithPath: source))
  let (definition, _) = try AgentCatalog.review(sourcePath: source)
  try Data("tampered".utf8).write(to: URL(fileURLWithPath: source))
  let installed = try AgentCatalog.install(definition, config: config, replace: false)
  let stored = try String(contentsOfFile: installed.path, encoding: .utf8)
  #expect(stored.contains("repo-helper"))
  #expect(!stored.contains("tampered"))
  #expect(throws: HostError.self) {
    try AgentCatalog.install(definition, config: config, replace: false)
  }
  let link = root + "/link.json"
  symlink(source, link)
  #expect(throws: HostError.self) { try AgentCatalog.readSource(link) }
  let reserved = root + "/claude.json"
  try Data(
    #"{"schema_version":1,"id":"claude","display_name":"x","launch":{"argv":["claude"]},"auth_adapter":"claude"}"#
      .utf8
  ).write(to: URL(fileURLWithPath: reserved))
  #expect(throws: HostError.self) { try AgentCatalog.review(sourcePath: reserved) }
}

@Test func disposableMarkerIsNotAnAffinityCandidateAndCleanupRequiresProof() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "iso-run-\(UUID().uuidString)")
    .path
  defer { try? FileManager.default.removeItem(atPath: root) }
  try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  let config = try agentConfig(root)
  let owner = Owner(
    schemaVersion: StateSchema.ownerVersion, backend: StateSchema.backend,
    ownerID: try OwnerID(String(repeating: "ab", count: 16)))
  try StateStore.ensurePrivateDirectory(config.stateRoot.path)
  try StateStore.writeControlFile(owner, to: Owner.path(config))
  let instance = try Instance.allocate(
    config, name: try InstanceName("scratch"), image: .default, workspacePath: nil)
  let session = try RunSessionStore.create(
    config, name: instance.name, workspace: "/tmp/proj", owner: owner)
  try RunSessionStore.writeMarker(instance, session)
  #expect(InstanceAffinity.eligibility(instance) == .disposable)
  var finished = session
  finished.state = .cleanupPending
  let decision = try RunSessionStore.reconcile(config, session: finished, dryRun: true)
  guard case .leave(let message) = decision else {
    Issue.record("expected a dry-run leave, got \(decision)")
    return
  }
  #expect(message.contains("would destroy"))
  var foreign = finished
  foreign.ownerID = try OwnerID(String(repeating: "cd", count: 16))
  #expect(throws: HostError.self) {
    try RunSessionStore.reconcile(config, session: foreign, dryRun: true)
  }
}

private func agentConfig(_ root: String) throws -> IsoConfig {
  let value = try ConfigLoader.parse(
    Array("{\"data_dir\": \"\(root)\"}".utf8), format: .json, path: "c", limits: .configuration)
  return try ConfigLoader.decode(value, path: "c", environment: .empty)
}
