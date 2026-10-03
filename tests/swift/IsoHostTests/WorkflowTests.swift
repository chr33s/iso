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

private func workflowFixture(_ root: String) throws -> ProjectLifecycle {
  let environment = ConfigEnvironment(home: root, variables: [:])
  let config = try testConfig(home: root)
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
      output: UnusedWorkflowOutput(), diagnostics: diagnostics, ssh: SSHClient(environment: [:])),
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
