import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

struct RunCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Ensure a project environment is running, then launch an agent",
    discussion: """
      Reuses `up`'s project affinity. A running match is not pushed, rebuilt, or
      bootstrapped again. Guest output is not copied back. `--rm` always creates
      a new disposable instance and does not adopt an existing one.

      Filtered egress is not part of this build: network hints on a definition
      are reported and never granted.
      """)

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Agent id (`claude`, `codex`, or an installed definition)") var agent: String
  @Option(name: .long, help: "Project directory (default: current directory)") var workspace:
    String?
  @Option(help: "Instance name", transform: parseInstanceName) var name: InstanceName?
  @Option(
    help: "Named image when creating a new instance", transform: parseImageName)
  var image: ImageName?
  @Option(help: "Profile list when creating a new instance") var profile: [String] = []
  @Flag(
    name: .customLong("rm"),
    help: "Create a disposable instance and destroy it after the agent exits")
  var remove = false
  @Flag(help: "Ask the adapter for permission prompts instead of its default bypass") var ask =
    false
  @Flag(
    name: .customLong("dry-run"), help: "Print the prospective launch without starting anything")
  var dryRun = false
  @Flag(help: "With --dry-run, emit versioned preview JSON on stdout") var json = false
  @Flag(help: "Authorize image preparation, which uses the host network and no project credentials")
  var prepare = false
  @Argument(
    parsing: .postTerminator,
    help: "Arguments forwarded to the agent. Put them after `--`."
  )
  var args: [String] = []

  func validate() throws {
    if json && !dryRun {
      throw UsageError("the following required arguments were not provided:\n  --dry-run")
    }
    if image != nil && !profile.isEmpty {
      throw UsageError("the argument '--image' cannot be used with '--profile'")
    }
    _ = try AgentDefinitionID(agent)
  }

  var profiles: [String] { profile.flatMap { $0.split(separator: ",").map(String.init) } }

  func run() throws {
    try IsoCLI.run {
      let (ask, forwarded) = splitAsk(ask, args)
      let context = try CommandContext.load(global, backgroundWork: !dryRun)
      let flow = RunFlow(
        context: context, agent: try AgentDefinitionID(self.agent), workspace: workspace,
        name: name,
        image: image, profiles: profiles, remove: remove, ask: ask, prepare: prepare,
        forwarded: forwarded, json: json, configPath: global.config)
      if dryRun {
        try flow.preview()
      } else {
        try flow.execute()
      }
    }
  }
}

struct RunCleanup: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run-cleanup",
    abstract: "Reconcile an abandoned disposable run without deleting unproven objects")

  @OptionGroup var global: GlobalOptions
  @Flag(name: .customLong("dry-run"), help: "Show what would be destroyed") var dryRun = false
  @Option(help: "Session id to reconcile") var session: String?

  func validate() throws {
    if session == nil && !dryRun {
      throw UsageError("pass --session <ID> to reconcile, or --dry-run to list")
    }
  }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global, backgroundWork: false)
      if dryRun && session == nil {
        let records = try RunSessionStore.list(context.config)
        if records.isEmpty { context.output.out("No run sessions.") }
        for record in records {
          let decision = try RunSessionStore.reconcile(
            context.config, session: record, dryRun: true)
          context.output.out(
            "\(record.sessionID) \(record.state.rawValue) \(RunFlow.describe(decision))")
        }
        return
      }
      let id = try RunSessionID(session ?? "")
      guard var record = try RunSessionStore.load(context.config, id) else {
        throw HostError("No run session \(id)")
      }
      if record.state == .running || record.state == .creating || record.state == .ready {
        record.state = .cleanupPending
      }
      let decision = try RunSessionStore.reconcile(context.config, session: record, dryRun: dryRun)
      switch decision {
      case .leave(let message):
        context.output.error(message)
        if !dryRun && record.state == .cleanupPending {
          record.cleanupOutcome = message
          if message.contains("pending staged pull") { record.state = .retained }
          try RunSessionStore.save(record, config: context.config)
        }
      case .destroy(let name):
        guard !dryRun else { return }
        let instance = try InstanceStore.resolve(context.config, name: name)
        context.agents.proxies.stopAll(instance)
        try context.backend.destroyInstance(instance)
        record.state = .completed
        record.cleanupOutcome = "destroyed"
        try RunSessionStore.save(record, config: context.config)
        context.output.error("Destroyed disposable instance '\(name)'.")
      }
    }
  }
}

struct RunFlow {
  let context: CommandContext
  let agent: AgentDefinitionID
  let workspace: String?
  let name: InstanceName?
  let image: ImageName?
  let profiles: [String]
  let remove: Bool
  let ask: Bool
  let prepare: Bool
  let forwarded: [String]
  let json: Bool
  let configPath: String?

  var diagnostics: Diagnostics { context.diagnostics }

  func preview() throws {
    let planned = try plan()
    let resolution = try resolve(planned)
    let preview = makePreview(planned, resolution)
    if json {
      context.output.write(preview.json.rendered())
    } else {
      for line in SessionSummary.lines(
        facts(planned, resolution, instanceName: resolution.instanceName))
      {
        context.output.error(line)
      }
      if let reason = resolution.blockedReason { context.output.error(reason) }
      context.output.error(
        "Preview only. No VM, image build, credential, or update check was performed.")
    }
  }

  func execute() throws {
    let started = ContinuousClock.now
    let planned = try plan()
    let resolution = try resolve(planned)
    if let reason = resolution.blockedReason { throw HostError(reason) }
    if resolution.action == .unresolved && !remove {
      // An existing instance whose runtime state was not part of local
      // resolution. Probe only on the real path.
    }
    let instance: Instance
    let created: Bool
    var sessionRecord: RunSessionRecord?
    switch try executionTarget(resolution) {
    case .attach(let existing):
      instance = existing
      created = false
    case .restart(let existing):
      try ensureCompatible(existing, planned)
      var options = try startOptions()
      options.name = existing.name
      try ProjectLifecycle(context, noGitHub: false).restart(existing, options)
      instance = existing
      created = false
    case .create(let directory, let requestedName):
      try authorizePreparation(planned)
      let lifecycle = ProjectLifecycle(context, noGitHub: false)
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
        var options = try startOptions()
        options.skipAgentBootstrap = planned.adapter.id == .none
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
        var options = try startOptions()
        options.skipAgentBootstrap = planned.adapter.id == .none
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
      planned, running: running, created: created, session: &sessionRecord, started: started)
  }

  func plan() throws -> AgentLaunchPlan {
    let resolved = try AgentCatalog.resolve(agent, config: context.config)
    return try AgentLaunchPlanner.plan(
      definition: resolved.definition, source: resolved.source, definitionHash: resolved.hash,
      cliImage: image, cliProfiles: profiles, ask: ask)
  }

  struct Resolution {
    var action: RunAction
    var instance: Instance?
    var instanceName: String?
    var workspace: String
    var match: String
    var blockedReason: String?
    var preparationRequired: Bool
  }

  func resolve(_ planned: AgentLaunchPlan) throws -> Resolution {
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
    let lifecycle = ProjectLifecycle(context, noGitHub: false)
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

  enum Target {
    case attach(Instance)
    case restart(Instance)
    case create(String, InstanceName?)
  }

  func executionTarget(_ resolution: Resolution) throws -> Target {
    if let instance = resolution.instance {
      if context.backend.isRunning(instance) { return .attach(instance) }
      return .restart(instance)
    }
    return .create(resolution.workspace, name)
  }

  func launch(
    _ planned: AgentLaunchPlan, running: AppleBackend.Running, created: Bool,
    session record: inout RunSessionRecord?, started: ContinuousClock.Instant
  ) throws {
    let codexAccount =
      context.config.codexAuth == .chatgpt
      && planned.adapter.id.rawValue == AgentAdapterID.codex.rawValue
    if planned.adapter.id == .codex && codexAccount {
      let state = try ModelState.loadOrDefault(running.instance)
      try CodexChecks.ensureRemoteAuthConsistent(
        context.config, instance: running.instance, modelState: state)
    }
    var ssh = try context.agents.session(for: running)
    for item in planned.defaults where !ssh.env.contains(item.name.rawValue) {
      ssh.env.set(item.name.rawValue, Secret(item.value))
    }
    let invocation = try AgentDispatch.invocation(
      plan: planned, passthrough: forwarded, guestUser: running.sidecar.guestUser,
      codexAccount: codexAccount, stdinIsTerminal: isatty(0) == 1, stdoutIsTerminal: isatty(1) == 1)
    let facts = facts(
      planned,
      Resolution(
        action: created ? .create : .attach, instance: running.instance,
        instanceName: running.instance.name.rawValue, workspace: "", match: "",
        blockedReason: nil, preparationRequired: false),
      instanceName: running.instance.name.rawValue)
    for line in SessionSummary.lines(facts) { context.output.error(line) }
    let handoff = ContinuousClock.now
    context.output.error(
      PhaseTiming(
        name: "resolution-and-start", status: .measured,
        milliseconds: milliseconds(started, handoff)
      ).line)
    context.output.error(
      PhaseTiming(name: "image-build", status: .notSeparatelyMeasured, milliseconds: nil).line)
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
      try finishCleanup(&record, agent: "unknown")
      throw error
    }
    let agentStatus = statusText(termination)
    if remove {
      try finishCleanup(&record, agent: agentStatus)
    } else {
      context.output.error(
        "Agent \(agentStatus). Instance '\(running.instance.name)' is still running.")
      context.output.error(
        "Review guest changes with `iso diff \(running.instance.name)` and return them with `iso pull \(running.instance.name)`."
      )
    }
    switch termination {
    case .exited(0): break
    case .exited(let code): throw ExitCode(code)
    case .signaled:
      throw HostError("agent status unknown after signal; cleanup outcome is recorded separately")
    }
  }

  func finishCleanup(_ record: inout RunSessionRecord?, agent: String) throws {
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
      context.output.error(message)
      if agent == "exited 0" {
        throw HostError("agent succeeded but cleanup did not destroy the instance: \(message)")
      }
    case .destroy(let name):
      let instance = try InstanceStore.resolve(context.config, name: name)
      context.agents.proxies.stopAll(instance)
      do {
        try context.backend.destroyInstance(instance)
        record.state = .completed
        record.cleanupOutcome = "destroyed"
        try RunSessionStore.save(record, config: context.config)
        context.output.error(
          "Disposable instance '\(name)' destroyed. Guest changes were discarded.")
      } catch {
        record.state = .cleanupPending
        record.cleanupOutcome = "destroy failed"
        try RunSessionStore.save(record, config: context.config)
        context.output.error("Cleanup failed: \(error)")
        throw HostError("agent \(agent); cleanup failed")
      }
    }
  }

  func startOptions() throws -> StartOptions {
    StartOptions(
      noPrompt: true, configTarget: try globalTarget(),
      persistedGuestEnvironment: [:])
  }

  func globalTarget() throws -> ConfigTarget {
    if let configPath {
      return ConfigTarget(path: configPath, format: try ConfigFormat(path: configPath))
    }
    let directory = ConfigLoader.defaultDirectory(home: context.environment.home)
    return ConfigTarget(path: directory + "/" + ConfigLoader.defaultFileName, format: .jsonc)
  }

  func authorizePreparation(_ planned: AgentLaunchPlan) throws {
    guard !planned.environment.profiles.isEmpty else { return }
    if !prepare && !hostImagePresent(planned.environment.image) {
      let message =
        "Image '\(planned.environment.image)' is not prepared. Preparation uses the host network and does not receive the project workspace or provider credentials. Re-run with --prepare."
      guard isatty(0) == 1 else { throw HostError(message) }
      guard TerminalPrompt.confirm(message) else { throw HostError("preparation not authorized") }
    }
    let definitions = try resolveProfiles(planned.environment.profiles, context.config)
    try context.backend.setup(
      SetupOptions(
        rebuild: false, profiles: definitions, image: planned.environment.image,
        guestUser: .default,
        builderTimeout: nil, refuseRebuild: !prepare))
  }

  func ensureCompatible(_ instance: Instance, _ planned: AgentLaunchPlan) throws {
    if let reason = incompatibility(instance, planned) { throw HostError(reason) }
  }

  func incompatibility(_ instance: Instance, _ planned: AgentLaunchPlan) -> String? {
    guard instance.image != planned.environment.image else { return nil }
    return
      "Instance '\(instance.name)' uses image '\(instance.image)', not '\(planned.environment.image)'. `iso run` does not recreate an existing instance.\nUse `iso destroy \(instance.name)` first to recreate it."
  }

  func projectDirectory() throws -> String {
    if workspace != nil { return try canonicalWorkspace() }
    return try UpFlow.projectDirectory(nil)
  }

  func canonicalWorkspace() throws -> String {
    try UpFlow.projectDirectory(workspace)
  }

  func hostImagePresent(_ image: ImageName) -> Bool {
    FileManager.default.fileExists(atPath: ImageManifest.path(context.config, image))
  }

  func instanceExists(_ name: InstanceName) -> Bool { load(name) != nil }

  func load(_ name: InstanceName) -> Instance? {
    (try? InstanceStore.list(context.config))?.first { $0.name == name }
  }

  func disposableName() throws -> InstanceName {
    for _ in 0..<8 {
      let candidate = try InstanceName("d-" + String(randomHex(4).prefix(12)))
      if !instanceExists(candidate) { return candidate }
    }
    throw HostError("could not allocate a disposable instance name")
  }

  func makePreview(_ planned: AgentLaunchPlan, _ resolution: Resolution) -> RunPreview {
    var unresolved = planned.unresolved
    unresolved.append("runtime state was not probed")
    if resolution.action == .unresolved {
      unresolved.append("attach versus restart")
    }
    return RunPreview.make(
      action: resolution.action, instanceName: resolution.instanceName, match: resolution.match,
      definition: planned.definition, source: planned.source,
      definitionHash: planned.definitionHash,
      adapter: planned.adapter, environment: planned.environment,
      workingDirectory: planned.workingDirectory, terminal: planned.terminal,
      preparationRequired: resolution.preparationRequired, egress: context.config.egress,
      proxyMode: context.config.proxy.mode, pullMode: context.config.workspacePull.mode,
      recordedEgress: nil, networkHints: planned.networkHints, unresolved: unresolved,
      cleanupIntent: remove ? "destroy" : "retain", ask: ask,
      blockedReason: resolution.blockedReason)
  }

  func facts(_ planned: AgentLaunchPlan, _ resolution: Resolution, instanceName: String?)
    -> SessionSummary.Facts
  {
    let raw = rawForwarding()
    return SessionSummary.Facts(
      instanceName: instanceName ?? "(new)", displayName: planned.definition.displayName,
      definitionID: planned.definition.id.rawValue, definitionHash: planned.definitionHash,
      source: planned.source == .builtin ? "builtin" : "installed",
      adapterID: planned.adapter.id.rawValue, contractVersion: planned.adapter.contractVersion,
      image: planned.environment.image.rawValue,
      environmentOrigin: planned.environment.origin.rawValue,
      workspace: resolution.workspace.isEmpty ? "recorded" : "host copy -> /workspace",
      workingDirectory: planned.workingDirectory.rawValue, terminal: planned.terminal.rawValue,
      provider: planned.adapter.providerName ?? "none requested",
      rawForwarding: raw.summary, rawForwardingWarning: raw.warning,
      egress: context.config.egress.rawValue, pullMode: context.config.workspacePull.mode.rawValue,
      lifecycle: remove ? "disposable" : "persistent",
      ttl: context.config.limits.sessionTTL.map {
        "\($0) configured (remaining not recorded locally)"
      }
        ?? "none",
      networkHints: planned.networkHints.map(\.rawValue), discardsGuestChanges: remove)
  }

  func rawForwarding() -> (summary: String, warning: String?) {
    if context.config.proxy.mode == .required || context.config.egress == .none {
      return ("none", nil)
    }
    let names = ProxyProvider.allCases.flatMap(\.recognizedVariables)
    return (
      "not proven",
      "proxy.mode is \(context.config.proxy.mode.rawValue); recognized variables \(names.joined(separator: ", ")) may be forwarded if present. Values are not shown."
    )
  }

  func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> UInt64 {
    let (seconds, attoseconds) = (end - start).components
    let millis = max(0, seconds) * 1000 + attoseconds / 1_000_000_000_000_000
    return UInt64(millis)
  }

  func statusText(_ termination: ProcessRunner.Termination) -> String {
    switch termination {
    case .exited(let code): "exited \(code)"
    case .signaled(let signal): "signaled \(signal)"
    }
  }

  static func describe(_ decision: RunSessionStore.CleanupDecision) -> String {
    switch decision {
    case .leave(let message): message
    case .destroy(let name): "would destroy \(name)"
    }
  }
}
