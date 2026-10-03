import Foundation
import IsoConfiguration
import IsoCore

package struct RunWorkflow {
  package let lifecycle: ProjectLifecycle
  package var context: CommandContext { lifecycle.context }
  package let agent: AgentDefinitionID
  package let workspace: String?
  package let name: InstanceName?
  package let image: ImageName?
  package let profiles: [String]
  package let remove: Bool
  package let ask: Bool
  package let prepare: Bool
  package let forwarded: [String]
  package let configPath: String?

  package init(
    lifecycle: ProjectLifecycle, agent: AgentDefinitionID, workspace: String?, name: InstanceName?,
    image: ImageName?, profiles: [String], remove: Bool, ask: Bool, prepare: Bool,
    forwarded: [String], configPath: String?
  ) {
    self.lifecycle = lifecycle
    self.agent = agent
    self.workspace = workspace
    self.name = name
    self.image = image
    self.profiles = profiles
    self.remove = remove
    self.ask = ask
    self.prepare = prepare
    self.forwarded = forwarded
    self.configPath = configPath
  }

  package enum Event {
    case handoff(AgentLaunchPlan, AppleBackend.Running, created: Bool, elapsed: Duration)
    case retained(ProcessRunner.Termination, InstanceName)
    case cleanupDeferred(String)
    case destroyed(InstanceName)
    case cleanupFailed(any Error)
  }

  package struct AgentExit: Error {
    package let code: Int32
  }

  package var diagnostics: Diagnostics { context.diagnostics }

  package func execute(
    confirmPreparation: (String) -> Bool, report: (Event) -> Void
  ) throws {
    let started = ContinuousClock.now
    let planned = try plan()
    let resolution = try resolve(planned)
    if let reason = resolution.blockedReason { throw HostError(reason) }
    let instance: Instance
    let created: Bool
    var sessionRecord: RunSessionRecord?
    switch try executionTarget(resolution) {
    case .attach(let existing):
      instance = existing
      created = false
    case .restart(let existing):
      try ensureCompatible(existing, planned)
      let options = RestartRequest(boot: try bootOptions())
      try lifecycle.restart(existing, options)
      instance = existing
      created = false
    case .create(let directory, let requestedName):
      try authorizePreparation(planned, confirm: confirmPreparation)
      if remove {
        let owner = try Owner.loadOrInit(context.config)
        let record = try RunSessionStore.create(
          context.config, name: requestedName ?? (try disposableName()), workspace: directory,
          owner: owner)
        sessionRecord = record
        let allocated = try Instance.allocate(
          context.config, name: record.intendedName, image: planned.environment.image,
          workspacePath: directory)
        try RunSessionStore.writeMarker(allocated, record)
        var creating = record
        creating.state = .creating
        try RunSessionStore.save(creating, config: context.config)
        sessionRecord = creating
        var options = CreationRequest(boot: try bootOptions())
        options.boot.skipAgentBootstrap = planned.adapter.id == .none
        options.workspaceDirectory = directory
        do {
          try lifecycle.startInstance(allocated, options)
          guard let sidecar = try MachineSidecar.loadIfPresent(allocated) else {
            throw HostError("disposable instance '\(allocated.name)' has no sandbox record")
          }
          try sidecar.markingDisposable().save(allocated)
          creating.sandboxID = sidecar.machineID.rawValue
          creating.state = .ready
          try RunSessionStore.save(creating, config: context.config)
          sessionRecord = creating
        } catch {
          lifecycle.agents.proxies.stopAll(allocated)
          try? lifecycle.backend.destroyInstance(allocated)
          creating.state = .cleanupPending
          creating.cleanupOutcome = "start failed"
          try? RunSessionStore.save(creating, config: context.config)
          throw error
        }
        instance = allocated
      } else {
        var options = CreationRequest(boot: try bootOptions())
        options.boot.skipAgentBootstrap = planned.adapter.id == .none
        options.workspaceDirectory = directory
        instance = try lifecycle.allocateAndStart(
          name: requestedName, image: planned.environment.image, workspacePath: directory, options)
      }
      created = true
    }
    let running = try context.backend.asRunning(instance)
    guard let running else {
      throw HostError("Instance '\(instance.name)' is not running after start")
    }
    try launch(
      planned, running: running, created: created, session: &sessionRecord, started: started,
      report: report)
  }

  package func plan() throws -> AgentLaunchPlan {
    let resolved = try AgentCatalog.resolve(agent, config: context.config)
    return try AgentLaunchPlanner.plan(
      definition: resolved.definition, source: resolved.source, definitionHash: resolved.hash,
      cliImage: image, cliProfiles: profiles, ask: ask)
  }

  package struct Resolution {
    package var action: RunAction
    package var instance: Instance?
    package var instanceName: String?
    package var workspace: String
    package var match: String
    package var blockedReason: String?
    package var preparationRequired: Bool

    package init(
      action: RunAction, instance: Instance?, instanceName: String?, workspace: String,
      match: String, blockedReason: String?, preparationRequired: Bool
    ) {
      self.action = action
      self.instance = instance
      self.instanceName = instanceName
      self.workspace = workspace
      self.match = match
      self.blockedReason = blockedReason
      self.preparationRequired = preparationRequired
    }
  }

  package func resolve(_ planned: AgentLaunchPlan) throws -> Resolution {
    let directory = try projectDirectory()
    let preparation = !hostImagePresent(planned.environment.image)
    if remove {
      if let name, instanceExists(name) {
        return Resolution(
          action: .blocked, instance: nil, instanceName: name.rawValue, workspace: directory,
          match: "name", blockedReason: "--rm requires an unused instance name; '\(name)' exists",
          preparationRequired: preparation)
      }
      return Resolution(
        action: .create, instance: nil, instanceName: name?.rawValue, workspace: directory,
        match: "none", blockedReason: nil, preparationRequired: preparation)
    }
    if let name {
      guard let instance = load(name) else {
        if workspace != nil {
          let canonical = try canonicalWorkspace()
          return Resolution(
            action: .create, instance: nil, instanceName: name.rawValue, workspace: canonical,
            match: "none", blockedReason: nil, preparationRequired: preparation)
        }
        return Resolution(
          action: .create, instance: nil, instanceName: name.rawValue,
          workspace: directory, match: "none", blockedReason: nil, preparationRequired: preparation)
      }
      if workspace != nil {
        let canonical = try canonicalWorkspace()
        let recorded = try WorkspaceState.load(instance)?.source.hostPath
        guard recorded == canonical else {
          return Resolution(
            action: .blocked, instance: instance, instanceName: instance.name.rawValue,
            workspace: canonical, match: "name",
            blockedReason:
              "Instance '\(instance.name)' records workspace \(recorded ?? "none"), not \(canonical).",
            preparationRequired: false)
        }
      }
      if let reason = incompatibility(instance, planned) {
        return Resolution(
          action: .blocked, instance: instance, instanceName: instance.name.rawValue,
          workspace: directory, match: "name", blockedReason: reason, preparationRequired: false)
      }
      return Resolution(
        action: .unresolved, instance: instance, instanceName: instance.name.rawValue,
        workspace: directory, match: "name", blockedReason: nil, preparationRequired: false)
    }
    if let instance = try lifecycle.workspaceInstance(
      directory,
      context: { path, names in
        "Multiple instances share workspace \(path):\n  \(names)\nPick one explicitly with --name."
      })
    {
      if let reason = incompatibility(instance, planned) {
        return Resolution(
          action: .blocked, instance: instance, instanceName: instance.name.rawValue,
          workspace: directory, match: "workspace", blockedReason: reason,
          preparationRequired: false)
      }
      return Resolution(
        action: .unresolved, instance: instance, instanceName: instance.name.rawValue,
        workspace: directory, match: "workspace", blockedReason: nil, preparationRequired: false)
    }
    return Resolution(
      action: .create, instance: nil, instanceName: nil, workspace: directory, match: "none",
      blockedReason: nil, preparationRequired: preparation)
  }

  package enum Target {
    case attach(Instance)
    case restart(Instance)
    case create(String, InstanceName?)
  }

  package func executionTarget(_ resolution: Resolution) throws -> Target {
    if let instance = resolution.instance {
      if context.backend.isRunning(instance) { return .attach(instance) }
      return .restart(instance)
    }
    return .create(resolution.workspace, name)
  }

  package func launch(
    _ planned: AgentLaunchPlan, running: AppleBackend.Running, created: Bool,
    session record: inout RunSessionRecord?, started: ContinuousClock.Instant,
    report: (Event) -> Void
  ) throws {
    let codexAccount =
      context.config.codexAuth == .chatgpt
      && planned.adapter.id.rawValue == AgentAdapterID.codex.rawValue
    if planned.adapter.id == .codex && codexAccount {
      let state = try ModelState.loadOrDefault(running.instance)
      try CodexChecks.ensureRemoteAuthConsistent(
        context.config, instance: running.instance, modelState: state)
    }
    var ssh = try lifecycle.agents.workloadSession(for: running, backend: context.backend)
    for item in planned.defaults where !ssh.env.contains(item.name.rawValue) {
      ssh.env.set(item.name.rawValue, Secret(item.value))
    }
    let invocation = try AgentDispatch.invocation(
      plan: planned, passthrough: forwarded, guestUser: running.sidecar.guestUser,
      codexAccount: codexAccount, stdinIsTerminal: isatty(0) == 1, stdoutIsTerminal: isatty(1) == 1)
    report(.handoff(planned, running, created: created, elapsed: ContinuousClock.now - started))
    if var record {
      record.state = .running
      try RunSessionStore.save(record, config: context.config)
    }
    let shutdown = remove ? Shutdown.install() : nil
    defer { shutdown?.restore() }
    let termination: ProcessRunner.Termination
    do {
      termination = try InteractiveSSH.runReporting(
        context.ssh, ssh, invocation.argv, workingDirectory: invocation.workingDirectory,
        allocatePTY: invocation.allocatePTY, diagnostics: diagnostics)
    } catch {
      try finishCleanup(&record, agent: "unknown", report: report)
      throw error
    }
    let agentStatus = statusText(termination)
    if remove {
      try finishCleanup(&record, agent: agentStatus, report: report)
    } else {
      report(.retained(termination, running.instance.name))
    }
    switch termination {
    case .exited(0): break
    case .exited(let code): throw AgentExit(code: code)
    case .signaled:
      throw HostError("agent status unknown after signal; cleanup outcome is recorded separately")
    }
  }

  package func finishCleanup(
    _ record: inout RunSessionRecord?, agent: String, report: (Event) -> Void
  ) throws {
    guard var record else { return }
    record.state = .finalizing
    record.agentOutcome = agent
    try RunSessionStore.save(record, config: context.config)
    let decision = try RunSessionStore.reconcile(context.config, session: record, dryRun: false)
    switch decision {
    case .leave(let message):
      record.state = message.contains("pending staged pull") ? .retained : .cleanupPending
      record.cleanupOutcome = message
      try RunSessionStore.save(record, config: context.config)
      report(.cleanupDeferred(message))
      if agent == "exited 0" {
        throw HostError("agent succeeded but cleanup did not destroy the instance: \(message)")
      }
    case .destroy(let name):
      let instance = try InstanceStore.resolve(context.config, name: name)
      lifecycle.agents.proxies.stopAll(instance)
      do {
        try context.backend.destroyInstance(instance)
        record.state = .completed
        record.cleanupOutcome = "destroyed"
        try RunSessionStore.save(record, config: context.config)
        report(.destroyed(name))
      } catch {
        record.state = .cleanupPending
        record.cleanupOutcome = "destroy failed"
        try RunSessionStore.save(record, config: context.config)
        report(.cleanupFailed(error))
        throw HostError("agent \(agent); cleanup failed")
      }
    }
  }

  package func bootOptions() throws -> BootOptions {
    BootOptions(
      noPrompt: true, configTarget: try globalTarget(),
      persistedGuestEnvironment: [:])
  }

  package func globalTarget() throws -> ConfigTarget {
    if let configPath {
      return ConfigTarget(path: configPath, format: try ConfigFormat(path: configPath))
    }
    let directory = ConfigLoader.defaultDirectory(home: context.environment.home)
    return ConfigTarget(path: directory + "/" + ConfigLoader.defaultFileName, format: .jsonc)
  }

  package func authorizePreparation(_ planned: AgentLaunchPlan, confirm: (String) -> Bool) throws {
    guard !planned.environment.profiles.isEmpty else { return }
    if !prepare && !hostImagePresent(planned.environment.image) {
      let message =
        "Image '\(planned.environment.image)' is not prepared. Preparation uses the host network and does not receive the project workspace or provider credentials. Re-run with --prepare."
      guard isatty(0) == 1 else { throw HostError(message) }
      guard confirm(message) else { throw HostError("preparation not authorized") }
    }
    let definitions = try resolveProfiles(planned.environment.profiles, context.config)
    try context.backend.setup(
      SetupOptions(
        rebuild: false, profiles: definitions, image: planned.environment.image,
        guestUser: .default,
        builderTimeout: nil, refuseRebuild: !prepare))
  }

  package func ensureCompatible(_ instance: Instance, _ planned: AgentLaunchPlan) throws {
    if let reason = incompatibility(instance, planned) { throw HostError(reason) }
  }

  package func incompatibility(_ instance: Instance, _ planned: AgentLaunchPlan) -> String? {
    guard instance.image != planned.environment.image else { return nil }
    return
      "Instance '\(instance.name)' uses image '\(instance.image)', not '\(planned.environment.image)'. `iso run` does not recreate an existing instance.\nUse `iso destroy \(instance.name)` first to recreate it."
  }

  package func projectDirectory() throws -> String {
    if workspace != nil { return try canonicalWorkspace() }
    return try ProjectDirectory.resolve(nil)
  }

  package func canonicalWorkspace() throws -> String {
    try ProjectDirectory.resolve(workspace)
  }

  package func hostImagePresent(_ image: ImageName) -> Bool {
    FileManager.default.fileExists(atPath: ImageManifest.path(context.config, image))
  }

  package func instanceExists(_ name: InstanceName) -> Bool { load(name) != nil }

  package func load(_ name: InstanceName) -> Instance? {
    (try? InstanceStore.list(context.config))?.first { $0.name == name }
  }

  package func disposableName() throws -> InstanceName {
    for _ in 0..<8 {
      let candidate = try InstanceName("d-" + String(randomHex(4).prefix(12)))
      if !instanceExists(candidate) { return candidate }
    }
    throw HostError("could not allocate a disposable instance name")
  }

  package func statusText(_ termination: ProcessRunner.Termination) -> String {
    switch termination {
    case .exited(let code): "exited \(code)"
    case .signaled(let signal): "signaled \(signal)"
    }
  }

  package static func describe(_ decision: RunSessionStore.CleanupDecision) -> String {
    switch decision {
    case .leave(let message): message
    case .destroy(let name): "would destroy \(name)"
    }
  }
}
