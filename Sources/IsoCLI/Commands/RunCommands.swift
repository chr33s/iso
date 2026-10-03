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
  @Option(help: "Egress mode when creating an instance: open, none, or filtered") var egress:
    String?
  @Option(help: "Exact host to add for a new filtered boot") var allowHost: [String] = []
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
      let context = try CommandContext.load(
        global,
        override: { try applyEgressOverride($0, mode: egress, hosts: allowHost) },
        backgroundWork: !dryRun)
      let flow = RunWorkflow(
        lifecycle: ProjectLifecycle(context, noGitHub: false),
        agent: try AgentDefinitionID(self.agent), workspace: workspace,
        name: name,
        image: image, profiles: profiles, remove: remove, ask: ask, prepare: prepare,
        forwarded: forwarded, configPath: global.config)
      if dryRun {
        try flow.preview(json: json)
      } else {
        do {
          try flow.execute(confirmPreparation: TerminalPrompt.confirm, report: flow.render)
        } catch let error as RunWorkflow.AgentExit {
          throw ExitCode(error.code)
        }
      }
    }
  }
}

struct EgressLeaseCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "egress-lease",
    abstract: "Renew a filtered-egress companion until its recorded boot identity changes",
    shouldDisplay: false)

  @Argument var instanceDirectory: String
  @Argument var machineID: String
  @Argument var ownerPID: Int32
  @Argument var bootID: String
  @Argument var livePath: String

  func run() {
    EgressLease.run(
      directory: instanceDirectory, machineID: machineID, ownerPID: ownerPID, bootID: bootID,
      livePath: livePath)
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
            "\(record.sessionID) \(record.state.rawValue) \(RunWorkflow.describe(decision))")
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

extension RunWorkflow {
  func preview(json: Bool) throws {
    let planned = try plan()
    let resolution = try resolve(planned)
    let preview = makePreview(planned, resolution)
    if json {
      try context.output.writeJSON(preview)
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

  func milliseconds(_ duration: Duration) -> UInt64 {
    let (seconds, attoseconds) = duration.components
    let millis = max(0, seconds) * 1000 + attoseconds / 1_000_000_000_000_000
    return UInt64(millis)
  }

  func render(_ event: Event) {
    switch event {
    case .handoff(let planned, let running, let created, let elapsed):
      let resolution = Resolution(
        action: created ? .create : .attach, instance: running.instance,
        instanceName: running.instance.name.rawValue, workspace: "", match: "",
        blockedReason: nil, preparationRequired: false)
      for line in SessionSummary.lines(
        facts(planned, resolution, instanceName: running.instance.name.rawValue))
      {
        context.output.error(line)
      }
      context.output.error(
        PhaseTiming(
          name: "resolution-and-start", status: .measured, milliseconds: milliseconds(elapsed)
        ).line)
      context.output.error(
        PhaseTiming(
          name: "image-build", status: .notSeparatelyMeasured, milliseconds: nil
        ).line)
    case .retained(let termination, let name):
      context.output.error("Agent \(statusText(termination)). Instance '\(name)' is still running.")
      context.output.error(
        "Review guest changes with `iso diff \(name)` and return them with `iso pull \(name)`.")
    case .cleanupDeferred(let message): context.output.error(message)
    case .destroyed(let name):
      context.output.error("Disposable instance '\(name)' destroyed. Guest changes were discarded.")
    case .cleanupFailed(let error): context.output.error("Cleanup failed: \(error)")
    }
  }
}
