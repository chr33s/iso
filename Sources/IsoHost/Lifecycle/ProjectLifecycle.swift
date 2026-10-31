import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets

/// One command's lifecycle: the loaded configuration plus the explicit
/// overrides this command applies to it (S-02), and the services built
/// from the current value.
package final class ProjectLifecycle {
  package let context: CommandContext
  package private(set) var config: IsoConfig
  package let githubDisabled: Bool
  /// The store `vault:` references resolve through; the command's own unless
  /// a test supplies one.
  package let secrets: any SecretReferenceResolver

  package typealias GitHubPreparation = (IsoConfig, ConfigTarget, RepoSlug?, Bool) throws ->
    IsoConfig
  private let prepareGitHub: GitHubPreparation
  private let executable: String?

  package init(
    context: CommandContext, noGitHub: Bool, secretResolver: any SecretReferenceResolver,
    executable: String?, prepareGitHub: @escaping GitHubPreparation
  ) {
    self.context = context
    secrets = secretResolver
    githubDisabled = noGitHub
    config = noGitHub ? context.config.disablingGitHub() : context.config
    self.executable = executable
    self.prepareGitHub = prepareGitHub
  }

  package var diagnostics: Diagnostics { context.diagnostics }
  package var backend: AppleBackend { context.backend.reconfigured(config) }
  package var forwards: PortForwards { PortForwards(client: context.ssh, diagnostics: diagnostics) }
  package var sshConfig: SSHConfigFile {
    get throws { try SSHConfigFile.forHome(context.environment.home, diagnostics: diagnostics) }
  }

  package var tokens: HostGitHubTokens {
    HostGitHubTokens(
      config: config, environment: context.environment.variables, diagnostics: diagnostics,
      githubDisabled: githubDisabled)
  }

  package var agents: AgentBootstrap {
    let resolver = CredentialResolver(environment: context.environment.variables)
    return AgentBootstrap(
      config: config, client: context.ssh, environment: context.environment.variables,
      home: context.environment.home, resolver: resolver,
      proxies: ProxyLauncher(
        environment: context.environment.variables, resolver: resolver, diagnostics: diagnostics,
        isoExecutable: executable),
      github: tokens, diagnostics: diagnostics, secrets: secrets)
  }

  package func listInstances() throws -> [Instance] { try context.listInstances() }

  package func applyVMOverrides(vcpus: UInt8?, memory: VmMemory?) throws {
    if vcpus == 0 { throw HostError("--vcpus must be > 0") }
    config = config.overridingVM(vcpus: vcpus, memory: memory, templateSize: nil)
  }

  package func apply(_ translation: DevcontainerTranslation) throws {
    config = try Devcontainer.applyToConfig(config, translation)
  }

  /// CLI `--env` over `--env-file` over devcontainer `containerEnv`, folded
  /// into the guest variables of this command; the merged set is what gets
  /// persisted. `{vault:}` references are persisted as references and
  /// resolved per session, never folded in as values.
  package func mergeRuntimeGuestEnvironment(
    cli: [(EnvVarName, EnvValue)], envFile: String?,
    devcontainer: [(name: EnvVarName, value: String)]?
  ) throws -> [EnvVarName: EnvValue] {
    let merged = GuestEnvState.merge(
      devcontainer: Dictionary(
        (devcontainer ?? []).map { ($0.name, EnvValue.literal($0.value)) },
        uniquingKeysWith: { $1 }),
      envFile: try envFile.map(GuestEnvState.readEnvFile) ?? [:],
      cli: Dictionary(cli, uniquingKeysWith: { $1 }))
    _ = try GuestEnvState.providerSecrets(merged)
    for (name, value) in devcontainer ?? [] where value.contains("{vault:") {
      diagnostics.warn(
        "devcontainer containerEnv '\(name)' contains `{vault:`; it is passed to the guest as literal text. Stored-secret references work only in --env and --env-file."
      )
    }
    foldGuestEnvironment(merged)
    return merged
  }

  /// Resolves every `{vault:}` reference before any VM work, so a wrong
  /// passphrase or a missing secret fails the command up front, and in one
  /// unlock: `--env`, proxy credentials (configured and per-VM) and the
  /// GitHub PAT for `repo`. The values stay in the process's resolver cache
  /// for this command's sessions, so nothing later prompts again.
  /// `noAgents`: an agent-free boot needs no provider credential, so none
  /// is resolved (READY-01); only its own references are.
  package func preflightReferences(
    _ entries: [EnvVarName: EnvValue], instance: Instance? = nil, repo: RepoSlug? = nil,
    noAgents: Bool = false
  ) throws {
    let routed = try GuestEnvState.providerSecrets(entries)
    if config.proxy.mode == .off,
      let first = routed.values.sorted(by: { $0.variable < $1.variable }).first
    {
      throw ProxyState.unavailable(first)
    }
    let proxyNames = try ProxyState.storedCredentialNames(config.proxy, instance: instance)
    try GuestEnvState.checkCredentialSeparation(entries, proxyCredentialNames: proxyNames)
    // Configured `vault:` proxy credentials join the same unlock, but only
    // when an agent will need them.
    let names = Set(entries.values.compactMap(\.reference)).union(noAgents ? [] : proxyNames)
      .union(
        try GitHubAssignment.vaultName(
          config, instance: instance, repo: repo, githubDisabled: githubDisabled
        ).map { [$0] } ?? [])
    guard !names.isEmpty else { return }
    let resolved = try secrets.resolve(names)
    if let missing = names.subtracting(resolved.keys).sorted().first {
      throw HostError("unable to resolve required secret '\(missing)'")
    }
  }

  /// Literal entries become this command's guest variables; references are
  /// left to the session overlay.
  package func foldGuestEnvironment(_ entries: [EnvVarName: EnvValue]) {
    config = config.applyingDevcontainer(
      vcpus: nil, memory: nil, postStart: nil,
      guestEnvironment: entries.compactMap { name, value in
        if case .literal(let text) = value { (name: name, value: text) } else { nil }
      })
  }

  /// The PAT wizard runs before any VM cost, and only without an assignment.
  package func maybePromptForPAT(_ instance: Instance, repo: RepoSlug?, _ options: BootOptions)
    throws
  {
    if try GitHubAssignment.active(config, instance, githubDisabled: githubDisabled) == nil {
      config = try prepareGitHub(config, options.configTarget, repo, options.noPrompt)
    }
  }

  // MARK: Fresh start

  /// Allocate a new instance and run its first boot; any failure removes
  /// what was created.
  package func allocateAndStart(
    name: InstanceName?, image: ImageName, workspacePath: String?, _ options: CreationRequest
  ) throws -> Instance {
    let instance = try Instance.allocate(
      config, name: name, image: image, workspacePath: workspacePath)
    diagnostics.log(.info, "Starting instance '\(instance.name)' (index \(instance.index))")
    let shutdown = Shutdown.install()
    defer { shutdown.restore() }
    do {
      try startInstance(instance, options)
    } catch {
      diagnostics.log(.error, "Failed to start instance '\(instance.name)': \(error)")
      if let target = try? backend.sshTarget(instance) { forwards.teardown(instance, target) }
      agents.proxies.stopAll(instance)
      do { try backend.destroyInstance(instance) } catch {
        diagnostics.debug("Cleanup failed (non-fatal): \(error)")
      }
      do { try sshConfig.remove(instance) } catch {
        diagnostics.debug("SSH config cleanup failed (non-fatal): \(error)")
      }
      throw error
    }
    return instance
  }

  /// `--git-repo` URL, then the workspace's origin, then the first mount's.
  package func resolveStartRepo(_ options: CreationRequest) throws -> RepoSlug? {
    let tools = HostTools(environment: context.environment.variables)
    if let url = options.gitRepo, let slug = RepoSlug.parse(url: url) { return slug }
    if let directory = options.workspaceDirectory {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
        isDirectory.boolValue, let slug = try tools.detectWorkspaceRepo(directory)
      {
        return slug
      }
    }
    if let mount = options.mounts.first, let slug = try tools.detectWorkspaceRepo(mount.hostPath) {
      return slug
    }
    return nil
  }

  package func startInstance(_ instance: Instance, _ options: CreationRequest) throws {
    let repo = try resolveStartRepo(options)
    try preflightReferences(
      options.boot.persistedGuestEnvironment, instance: instance, repo: repo,
      noAgents: options.boot.noAgents)
    try maybePromptForPAT(instance, repo: repo, options.boot)
    // Busy host ports fail before any VM cost.
    let forwardSet = PortForward.merge(config: config.forwardPorts, cli: options.boot.forwardPorts)
    try PortForwards.checkCollisions(forwardSet)
    try agents.requireProviderProxy(
      instance, noAgents: options.boot.noAgents,
      guestEnvironment: options.boot.persistedGuestEnvironment)
    try backend.createAndStart(
      instance, diskGiB: options.disk.map { UInt64($0.value) },
      guestEnvironment: options.boot.persistedGuestEnvironment)
    try provisionFirstBoot(instance, options, repo: repo, forwardSet: forwardSet)
  }

  /// A guest carrying only its image: state, agents, then the workspace
  /// and mounts, then the post-start hook (only after provisioning
  /// succeeded), then forwards. Shared by a fresh start and a reprovision. The
  /// managed alias and port forwards use the target bootstrap proved, so
  /// neither reaches a filtered guest before its composite readiness.
  package func provisionFirstBoot(
    _ instance: Instance, _ options: CreationRequest, repo: RepoSlug?, forwardSet: [PortForward]
  ) throws {
    try Shutdown.check()
    let target = try readyTarget(instance)
    try Shutdown.check()
    let grants = try GrantLedger.reconcile(
      instance, revoked: config.revokedGrantIDs,
      environment: options.boot.persistedGuestEnvironment, forwards: forwardSet,
      fresh: options.boot.freshGrantScopes
        ?? Set(options.boot.persistedGuestEnvironment.keys.map(\.rawValue))
        .union(forwardSet.map(GrantLedger.scope)),
      knownElsewhere: GrantLedger.knownIDs(config, except: instance))
    warnGrantReconciliation(instance, grants)
    try PortForwards.save(grants.savedForwards, instance, diagnostics: diagnostics)
    try GuestEnvState(entries: grants.savedEnvironment).save(instance, diagnostics: diagnostics)
    if let applied = options.appliedDevcontainer {
      try DevcontainerState(applied: applied).save(instance)
    }
    let transfer = WorkspaceTransfer(client: context.ssh, diagnostics: diagnostics)
    let transferTarget = try agents.bootstrapAndPostStart(
      instance, target: target, repo: repo, noAgents: options.boot.noAgents,
      postStartOverride: options.boot.postStartOverride, mode: .firstBoot,
      skipAgentBootstrap: options.boot.skipAgentBootstrap, runtime: try backend.runtime()
    ) { transferTarget in
      try provisionWorkspace(instance, options, transfer: transfer, target: transferTarget)
    }
    try Shutdown.check()
    refreshSSHConfig(instance, transferTarget)
    try forwards.spawn(instance, transferTarget, grants.appliedForwards)
    diagnostics.log(
      .info, "Instance '\(instance.name)' started — SSH: \(target.endpointDescription)")
  }

  /// The one-time workspace copy or clone and mount sync of a first boot,
  /// run before the post-start hook.
  func provisionWorkspace(
    _ instance: Instance, _ options: CreationRequest, transfer: WorkspaceTransfer,
    target transferTarget: SSHTarget
  ) throws {
    var recorded = false
    // One outbound budget for the whole operation, across every root.
    let budget = InputBudget(config.workspaceInput.limits)
    if options.excludeGit {
      diagnostics.warn("--exclude-git is deprecated: transfers into the guest never carry .git")
    }
    if let directory = options.workspaceDirectory {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw HostError("Workspace path \(directory) is not a directory") }
      guard let absolute = canonicalPath(directory) else {
        throw HostError("Failed to resolve \(directory)")
      }
      try transfer.sendSnapshot(
        transferTarget, root: absolute, to: guestWorkspace, input: config.workspaceInput,
        budget: budget, stateDirectory: instance.directory + "/inputs", audit: instance)
      transfer.initializeGuestRepository(transferTarget, guestWorkspace)
      try WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: absolute))
        .save(instance, diagnostics: diagnostics)
      recorded = true
    } else if let url = options.gitRepo {
      let assigned = try GitHubAssignment.active(config, instance, githubDisabled: githubDisabled)
      try GitHubGuest.clone(
        context.ssh, transferTarget, url: url, github: githubDisabled ? .off : config.github,
        assigned: assigned?.repo,
        tokens: GitHubTokens(environment: context.environment.variables, diagnostics: diagnostics))
      try WorkspaceState(guestPath: guestWorkspace, source: .gitRepo(url: url))
        .save(instance, diagnostics: diagnostics)
      recorded = true
    }
    try Shutdown.check()
    if !options.mounts.isEmpty {
      if recorded {
        try transfer.syncMountContents(
          transferTarget, options.mounts, input: config.workspaceInput, budget: budget,
          stateDirectory: instance.directory + "/inputs")
      } else {
        try transfer.syncMounts(
          transferTarget, instance, options.mounts, input: config.workspaceInput, budget: budget)
      }
      diagnostics.warn(
        "\(AppleBackend.name) mounts use one-time sync, not live filesystem sharing. Use `iso push` / `iso pull` to sync changes."
      )
    }
  }

  package func readyTarget(_ instance: Instance) throws -> SSHTarget {
    let target = try backend.sshTarget(instance)
    do {
      try context.ssh.waitUntilReady(target, timeout: .seconds(30), diagnostics: diagnostics)
    } catch {
      throw ContextError("Guest booted but SSH is not accepting connections", cause: error)
    }
    return target
  }

  /// Keeps an alias the user installed current; never installs one.
  func warnGrantReconciliation(_ instance: Instance, _ grants: GrantLedger.Reconciled) {
    if !grants.withheld.isEmpty {
      diagnostics.warn(
        "Not applying saved grants recorded without provenance (\(grants.withheld.joined(separator: ", "))); give them again on the command line to keep them, or revoke them by ID (`iso policy effective \(instance.name)`)"
      )
    }
    if !grants.unknownRevoked.isEmpty {
      diagnostics.warn(
        "security.revoked_grant_ids names \(grants.unknownRevoked.joined(separator: ", ")), which no current instance records; remove it from the configuration once it is no longer needed"
      )
    }
  }

  package func refreshSSHConfig(_ instance: Instance, _ target: SSHTarget) {
    do { try sshConfig.refreshIfPresent(target, instance) } catch {
      diagnostics.warn("Failed to refresh SSH config for '\(instance.name)': \(error)")
    }
  }

  // MARK: Restart

  /// Boot a stopped instance with the forwards and guest variables it was
  /// last started with (CLI values override per key).
  package func restart(_ instance: Instance, _ request: RestartRequest) throws {
    let options = request.boot
    diagnostics.log(.info, "Restarting stopped instance '\(instance.name)'")
    DevcontainerState.warnIfChanged(instance, diagnostics: diagnostics)
    let shutdown = Shutdown.install()
    defer { shutdown.restore() }
    let repo = tokens.instanceRepo(instance)
    try maybePromptForPAT(instance, repo: repo, options)
    let saved = try PortForwards.load(instance) ?? []
    var forwardSet = PortForward.merge(config: saved, cli: options.forwardPorts)
    try PortForwards.checkCollisions(forwardSet)
    var guestEnvironment = try GuestEnvState.tryLoad(instance)?.entries ?? [:]
    for (key, value) in options.persistedGuestEnvironment { guestEnvironment[key] = value }
    // Saved grants re-apply only under their recorded provenance; revoked
    // ones are withdrawn (and tombstoned) before anything is handed out.
    let grants = try GrantLedger.reconcile(
      instance, revoked: config.revokedGrantIDs, environment: guestEnvironment,
      forwards: forwardSet,
      fresh: Set(options.persistedGuestEnvironment.keys.map(\.rawValue))
        .union(options.forwardPorts.map(GrantLedger.scope)),
      knownElsewhere: GrantLedger.knownIDs(config, except: instance))
    warnGrantReconciliation(instance, grants)
    guestEnvironment = grants.appliedEnvironment
    forwardSet = grants.appliedForwards
    let savedEnvironment = grants.savedEnvironment
    let savedForwards = grants.savedForwards
    _ = try GuestEnvState.providerSecrets(guestEnvironment)
    try preflightReferences(
      guestEnvironment, instance: instance, repo: repo, noAgents: options.noAgents)
    foldGuestEnvironment(guestEnvironment)
    _ = try GitHubAssignment.active(config, instance, githubDisabled: githubDisabled)
    try agents.requireProviderProxy(
      instance, noAgents: options.noAgents, guestEnvironment: guestEnvironment)
    try backend.startExisting(instance, guestEnvironment: guestEnvironment)
    let target: SSHTarget
    do {
      try Shutdown.check()
      target = try readyTarget(instance)
      try Shutdown.check()
      try PortForwards.save(savedForwards, instance, diagnostics: diagnostics)
      try GuestEnvState(entries: savedEnvironment).save(instance, diagnostics: diagnostics)
      let proven = try agents.bootstrapAndPostStart(
        instance, target: target, repo: repo, noAgents: options.noAgents,
        postStartOverride: options.postStartOverride, mode: .restart,
        skipAgentBootstrap: options.skipAgentBootstrap, runtime: try backend.runtime())
      refreshSSHConfig(instance, proven)
      try forwards.spawn(instance, proven, forwardSet)
    } catch {
      rollBackRestart(instance, cause: error)
      throw error
    }
    diagnostics.log(
      .info, "Instance '\(instance.name)' restarted — SSH: \(target.endpointDescription)")
  }

  /// After a restart boots but provisioning or readiness fails: revoke what
  /// the attempt started (forwards, proxies, tunnels), then stop the VM with
  /// its disk kept. If the stop cannot be confirmed, fence the instance so no
  /// workload is handed to it until `iso stop` reconciles it.
  func rollBackRestart(_ instance: Instance, cause: any Error) {
    diagnostics.log(.error, "Restart of '\(instance.name)' failed: \(oneLine(cause)); stopping it")
    if let target = try? backend.sshTarget(instance) { forwards.teardown(instance, target) }
    agents.proxies.stopAll(instance)
    do {
      try backend.stopUnproven(instance)
    } catch {
      diagnostics.warn(
        "Could not confirm that '\(instance.name)' stopped (\(oneLine(error))); it is fenced until `iso stop \(instance.name)` succeeds"
      )
      BoundaryAudit.record(
        instance, .handoffFence(reason: "restart_cleanup_unconfirmed"), diagnostics: diagnostics)
      do { try HandoffFence.set(instance, reason: "restart cleanup unconfirmed") } catch {
        diagnostics.warn("Failed to record the fence for '\(instance.name)': \(error)")
      }
    }
  }

  // MARK: Instance lookup

  /// The one instance recorded for `canonical` (the project directory).
  /// `resolution` is the caller's argument that picks one of several matches.
  package func workspaceInstance(
    _ canonical: String, resolution: String? = nil, context message: (String, String) -> String
  )
    throws
    -> Instance?
  {
    let matching = try listInstances().filter {
      guard Self.affinityCandidate($0, diagnostics: diagnostics) else { return false }
      return WorkspaceState.loadOrWarn(
        $0, consequence: "workspace-affinity matching will skip this instance",
        diagnostics: diagnostics)?.source.hostPath == canonical
    }
    switch matching.count {
    case 0: return nil
    case 1: return matching[0]
    default:
      throw HostFailure(
        .ambiguousInstance(candidates: matching.map(\.name), resolution: resolution),
        message(canonical, matching.map(\.name.rawValue).joined(separator: ", ")))
    }
  }

  /// Disposable runs are not adopted by project affinity. Unreadable
  /// feature state is skipped rather than treated as a persistent match.
  package static func affinityCandidate(_ instance: Instance, diagnostics: Diagnostics) -> Bool {
    switch InstanceAffinity.eligibility(instance) {
    case .eligible: return true
    case .disposable:
      diagnostics.debug("skipping disposable instance '\(instance.name)' for project affinity")
      return false
    case .unreadable(let reason):
      diagnostics.warn(
        "skipping instance '\(instance.name)' for project affinity: \(reason)")
      return false
    }
  }

  package func gitRepoInstance(_ url: String) throws -> Instance? {
    let matching = try listInstances().filter {
      guard Self.affinityCandidate($0, diagnostics: diagnostics) else { return false }
      return WorkspaceState.loadOrWarn(
        $0, consequence: "git-repo matching will skip this instance", diagnostics: diagnostics)?
        .source == .gitRepo(url: url)
    }
    switch matching.count {
    case 0: return nil
    case 1: return matching[0]
    default:
      throw HostFailure(
        .ambiguousInstance(candidates: matching.map(\.name), resolution: nil),
        "Multiple instances share git repo \(url):\n  \(matching.map(\.name.rawValue).joined(separator: ", "))\nPick one explicitly with `iso start <name>` (for a stopped\ninstance) or `iso claude <name>` (for a running one)."
      )
    }
  }
  /// Forwards go down before the VM (their control master exits while SSH
  /// still answers); the credential proxy and model tunnels are stopped on
  /// every path.
  /// `.unchanged` when the instance was already stopped.
  @discardableResult
  package func stop(_ instance: Instance) throws -> LifecycleAction {
    context.diagnostics.log(.info, "Stopping instance '\(instance.name)'")
    let running: AppleBackend.Running?
    do {
      running = try context.backend.asRunning(instance)
    } catch let probeError {
      EgressLease.closeForwards(instance)
      agents.proxies.stopAll(instance)
      do { try context.backend.stopUnproven(instance) } catch {
        throw ContextError(
          "Could not determine whether instance '\(instance.name)' is running, and it could not be stopped without that (\((error as? ContextError)?.alternate ?? String(describing: error)))",
          cause: probeError)
      }
      BoundaryAudit.record(instance, .stop, diagnostics: context.diagnostics)
      return .stopped
    }
    let action: LifecycleAction
    if let running {
      forwards.teardown(running.instance, running.target)
      let guestComputerUse = context.backend.guestComputerUseAudit(instance)
      try context.backend.stop(running)
      if let guestComputerUse {
        BoundaryAudit.record(instance, guestComputerUse, diagnostics: context.diagnostics)
      }
      BoundaryAudit.record(instance, .stop, diagnostics: context.diagnostics)
      action = .stopped
    } else {
      action = .unchanged
      context.diagnostics.debug("Instance '\(instance.name)' is not running — nothing to stop")
      if let target = try? backend.sshTarget(instance) { forwards.teardown(instance, target) }
    }
    agents.proxies.stopAll(instance)
    context.diagnostics.log(.info, "Instance '\(instance.name)' stopped")
    return action
  }
}
