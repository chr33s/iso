import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private struct UnusedWorkflowOutput: OutputStreams {
  func out(_ line: String) { Issue.record("unexpected output during workflow resolution") }
  func write(_ text: String) { Issue.record("unexpected output during workflow resolution") }
  func error(_ line: String) { Issue.record("unexpected output during workflow resolution") }
}

private struct UnusedWorkflowSecrets: SecretReferenceResolver {
  func resolve(_ names: Set<SecretName>) throws -> [SecretName: Secret<[UInt8]>] {
    Issue.record("local workflow resolution must not unlock secrets")
    throw HostError("unexpected secret resolution")
  }
}

private func workflowFixture(_ root: String, config body: String = "") throws
  -> ProjectLifecycle
{
  let environment = ConfigEnvironment(home: root, variables: [:])
  let config = try testConfig(body, home: root)
  let diagnostics = Diagnostics(verbosity: 0) { _ in }
  let backend = AppleBackend(
    config: config, environment: [:], diagnostics: diagnostics,
    runtime: { () throws(RuntimeError) in
      Issue.record("local workflow resolution must not open the runtime")
      throw RuntimeError.unqualified("unexpected runtime access")
    })
  return ProjectLifecycle(
    context: CommandContext(
      environment: environment, config: config, backend: backend,
      output: UnusedWorkflowOutput(), diagnostics: diagnostics,
      ssh: SSHClient(environment: [:], tools: .searchPath)),
    noGitHub: false, secretResolver: UnusedWorkflowSecrets(), executable: nil,
    prepareGitHub: { _, _, _, _ in
      Issue.record("local workflow resolution must not prompt")
      throw HostError("unexpected prompt")
    })
}

private func runWorkflow(_ lifecycle: ProjectLifecycle, workspace: String, remove: Bool = false)
  throws -> RunWorkflow
{
  RunWorkflow(
    lifecycle: lifecycle, agent: try AgentDefinitionID("claude"), workspace: workspace,
    name: nil, image: nil, profiles: [], remove: remove, ask: false, prepare: false,
    forwarded: [], configPath: nil)
}

@Test func runResolutionUsesPersistentWorkspaceAffinityWithoutRuntimeOrSecrets() throws {
  let root = try scratchDirectory("workflow")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let lifecycle = try workflowFixture(root)
  let workflow = try runWorkflow(lifecycle, workspace: root)
  let plan = try workflow.plan()
  let fresh = try workflow.resolve(plan)
  #expect(fresh.action == .create)
  #expect(fresh.instance == nil)
  let instance = try Instance.allocate(
    lifecycle.config, name: try InstanceName("project"), image: .default, workspacePath: root)
  try WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: root)).save(instance)
  let existing = try workflow.resolve(plan)
  #expect(existing.action == .unresolved)
  #expect(existing.instance?.name == instance.name)
  #expect(existing.match == "workspace")
  let disposable = try runWorkflow(lifecycle, workspace: root, remove: true).resolve(plan)
  #expect(disposable.action == .create)
  #expect(disposable.instance == nil)
}

@Test func runResolutionRefusesImageMismatchBeforeRuntimeOrSecrets() throws {
  let root = try scratchDirectory("workflow-image")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let lifecycle = try workflowFixture(root)
  let instance = try Instance.allocate(
    lifecycle.config, name: try InstanceName("project"), image: try ImageName("custom"),
    workspacePath: root)
  try WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: root)).save(instance)
  let workflow = try runWorkflow(lifecycle, workspace: root)
  let resolution = try workflow.resolve(workflow.plan())
  #expect(resolution.action == .blocked)
  #expect(resolution.blockedReason?.contains("uses image 'custom'") == true)
  let error = try #require(throws: HostError.self) {
    try workflow.execute(
      confirmPreparation: { _ in
        Issue.record("blocked run must not prompt")
        return true
      },
      report: { _ in Issue.record("blocked run must not report a guest handoff") })
  }
  #expect(error.message == resolution.blockedReason)
}

@Test func upAffinityFailuresAreTypedBeforeRuntimeOrSecrets() throws {
  let root = try scratchDirectory("workflow-up")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let lifecycle = try workflowFixture(root)
  let project = try Instance.allocate(
    lifecycle.config, name: try InstanceName("project"), image: .default, workspacePath: root)
  try WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: root)).save(project)
  var request = UpRequest(
    configTarget: ConfigTarget(path: root + "/config.jsonc", format: .jsonc))
  request.dir = root
  request.name = try InstanceName("other")
  let associated = try #require(throws: HostFailure.self) {
    try UpWorkflow(request: request, lifecycle: lifecycle, target: nil).run()
  }
  #expect(associated.reason == .projectAlreadyAssociated(project.name))
  #expect(associated.message.hasPrefix("Project \(root) is already associated"))

  let twin = try Instance.allocate(
    lifecycle.config, name: try InstanceName("twin"), image: .default, workspacePath: root)
  try WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: root)).save(twin)
  request.name = nil
  let ambiguous = try #require(throws: HostFailure.self) {
    try UpWorkflow(request: request, lifecycle: lifecycle, target: nil).run()
  }
  guard case .ambiguousInstance(let candidates, let resolution) = ambiguous.reason else {
    Issue.record("expected an ambiguous instance, got \(ambiguous.reason)")
    return
  }
  #expect(Set(candidates) == [project.name, twin.name])
  // No argument of `up` picks one.
  #expect(resolution == nil)
}

@Test func aRunningInstanceRefusesADifferentRequestedEgressPolicy() throws {
  let root = try scratchDirectory("workflow-egress")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let open = try workflowFixture(root)
  let instance = try Instance.allocate(
    open.config, name: try InstanceName("project"), image: .default, workspacePath: root)
  try NetworkPolicy.save(open.config, instance)
  var request = UpRequest(configTarget: ConfigTarget(path: root + "/c.jsonc", format: .jsonc))
  request.command = "zed"

  // Not requested, or requested and matching: nothing to refuse.
  try UpWorkflow(request: request, lifecycle: open, target: nil).rejectEgressChange(instance)
  request.egressRequested = true
  try UpWorkflow(request: request, lifecycle: open, target: nil).rejectEgressChange(instance)

  let none = try workflowFixture(root, config: #""egress": "none""#)
  let refusal = try #require(throws: HostFailure.self) {
    try UpWorkflow(request: request, lifecycle: none, target: nil).rejectEgressChange(instance)
  }
  #expect(refusal.reason == .instanceIncompatible(instance.name))
  #expect(refusal.message.contains("was created with egress open, not none"))
  // Only an explicit request is refused here; config drift is left to the
  // running-guest policy check and its own error.
  request.egressRequested = false
  try UpWorkflow(request: request, lifecycle: none, target: nil).rejectEgressChange(instance)

  // A record that cannot be read is refused, not taken as a match.
  request.egressRequested = true
  try writeFile(NetworkPolicy.path(instance), "{}", mode: 0o600)
  let unreadable = try #require(throws: HostFailure.self) {
    try UpWorkflow(request: request, lifecycle: open, target: nil).rejectEgressChange(instance)
  }
  #expect(unreadable.reason == .instanceIncompatible(instance.name))
}

@Test func aDevcontainerDiskHintIsIgnoredForAMacOSImageButAnExplicitDiskIsKept() throws {
  let root = try scratchDirectory("workflow-macdisk")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let lifecycle = try workflowFixture(root)
  let mac = try ImageName("mac")
  try ImageManifest(
    schemaVersion: StateSchema.version, backend: StateSchema.backend,
    imageRef: "iso-0a1b2c3d-0011223344556677", digest: "macos:26A434:helper-b", disk: nil,
    manifestID: "macos-provision-p", baseImage: "macOS 27.0.1", platform: ImageManifest.macPlatform,
    guestUser: MacProvision.guestUser, created: "t"
  ).save(lifecycle.config, mac)
  var translation = DevcontainerTranslation()
  translation.disk = GiB(100)
  var request = UpRequest(configTarget: ConfigTarget(path: root + "/c.jsonc", format: .jsonc))
  request.image = mac
  let hinted = try UpWorkflow(request: request, lifecycle: lifecycle, target: nil)
    .creationOptions(translation, rule: .copyProject, leading: [])
  #expect(hinted.disk == nil)
  request.disk = GiB(80)
  let explicit = try UpWorkflow(request: request, lifecycle: lifecycle, target: nil)
    .creationOptions(translation, rule: .copyProject, leading: [])
  #expect(explicit.disk == GiB(80))
  request.disk = nil
  request.image = .default
  let linux = try UpWorkflow(request: request, lifecycle: lifecycle, target: nil)
    .creationOptions(translation, rule: .copyProject, leading: [])
  #expect(linux.disk == GiB(100))
}

@Test func aRunThatFailsToResolveRecordsItsStageAndNoHandoff() throws {
  let root = try scratchDirectory("workflow-audit")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let lifecycle = try workflowFixture(root)
  let store = AuditStore(config: lifecycle.config)
  let audit = AuditInvocation.begin(
    store: store,
    request: .init(
      command: .run, role: .managed, lifecycle: .persistent, requestedAgent: "missing-agent",
      requestedInstance: nil, permissionMode: .bypass, isoVersion: "iso test"),
    diagnostics: Diagnostics(verbosity: 0) { _ in }, notice: { _ in })
  let workflow = RunWorkflow(
    lifecycle: lifecycle, agent: try AgentDefinitionID("missing-agent"), workspace: root,
    name: nil, image: nil, profiles: [], remove: false, ask: false, prepare: false,
    forwarded: [], configPath: nil, audit: audit)
  #expect(throws: (any Error).self) {
    try workflow.execute(confirmPreparation: { _ in false }, report: { _ in })
  }
  let summary = try #require(
    try AuditReader(store: store).page(.run(audit.runID), after: nil).run?.summary)
  #expect(summary.outcome == .preparationFailed(.resolve))
  #expect(summary.handoff == nil && summary.environment == nil)
}

/// ALLOC: corrupt, unknown or non-directory entries occupy their names and
/// refuse allocation rather than being treated as free slots.
@Test func allocationReservesEveryExistingEntry() throws {
  let root = try scratchDirectory("alloc")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let config = try workflowFixture(root).config
  let first = try Instance.allocate(
    config, name: try InstanceName("app"), image: .default, workspacePath: nil)
  let instances = config.instancesDirectory.path
  // Case-colliding and exact names are taken.
  #expect(throws: HostError.self) {
    try Instance.allocate(
      config, name: try InstanceName("APP"), image: .default, workspacePath: nil)
  }
  // A derived name skips the existing one.
  let derived = try Instance.allocate(config, name: nil, image: .default, workspacePath: "/x/app")
  #expect(derived.name.rawValue == "app-2" && derived.index != first.index)

  // A corrupt record blocks allocation; nothing is reused or overwritten.
  try FileManager.default.createDirectory(
    atPath: instances + "/broken", withIntermediateDirectories: true)
  try writeFile(instances + "/broken/instance.json", "{not json")
  #expect(throws: HostError.self) {
    try Instance.allocate(
      config, name: try InstanceName("new"), image: .default, workspacePath: nil)
  }
  #expect(readFile(instances + "/broken/instance.json") == "{not json")
  #expect(!FileManager.default.fileExists(atPath: instances + "/new"))
  try FileManager.default.removeItem(atPath: instances + "/broken")

  // A symlink or file also occupies its name.
  try FileManager.default.createSymbolicLink(
    atPath: instances + "/linked", withDestinationPath: root)
  #expect(throws: HostError.self) {
    try Instance.allocate(
      config, name: try InstanceName("other"), image: .default, workspacePath: nil)
  }
  try FileManager.default.removeItem(atPath: instances + "/linked")
  _ = try Instance.allocate(
    config, name: try InstanceName("other"), image: .default, workspacePath: nil)
  // The tolerant listing still works with a corrupt entry present.
  try writeFile(instances + "/stray", "x")
  #expect(try InstanceStore.list(config, skipped: { _, _ in }).count == 3)
}

/// READY-01: a launch refuses an agent whose own provider is not brokered
/// before it opens a workload session or reports a handoff.
@Test func aLaunchRequiresTheSelectedAgentsOwnProviderBroker() throws {
  let root = try scratchDirectory("workflow-provider")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let lifecycle = try workflowFixture(
    root, config: #""proxy": {"mode": "required", "anthropic": {"credential": "cmd:printf k"}}"#)
  let guest = try FakeGuest()
  defer { guest.remove() }
  let running = try workloadRunning(guest, identity: nil)
  let workflow = RunWorkflow(
    lifecycle: lifecycle, agent: try AgentDefinitionID("codex"), workspace: root,
    name: nil, image: nil, profiles: [], remove: false, ask: false, prepare: false,
    forwarded: [], configPath: nil)
  let planned = try workflow.plan()
  var record: RunSessionRecord? = nil
  let error = try #require(throws: HostError.self) {
    try workflow.launch(
      planned, running: running, action: .attached, session: &record,
      started: ContinuousClock.now,
      report: { _ in Issue.record("an unbrokered agent was handed off") })
  }
  #expect(error.message.contains("needs the openai credential proxy"))
}
