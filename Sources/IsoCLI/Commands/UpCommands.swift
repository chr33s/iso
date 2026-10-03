// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import IsoSecrets

extension ProjectLifecycle {
  convenience init(
    _ context: CommandContext, noGitHub: Bool, secrets: (any SecretReferenceResolver)? = nil
  ) {
    self.init(
      context: context, noGitHub: noGitHub, secretResolver: secrets ?? context.secretResolver,
      executable: CommandLine.executablePath,
      prepareGitHub: { config, target, repo, noPrompt in
        try context.github.maybePrompt(config, target: target, repo: repo, noPrompt: noPrompt)
      })
  }
}

/// CLI selection arguments are resolved before constructing a restart request.
struct StoppedInstanceSelection {
  var name: InstanceName?
  var workspaceDirectory: String?
  var devcontainerPath: String?
}

func resolveCanonical(_ path: String, _ what: String) throws -> String {
  guard let canonical = canonicalPath(path) else {
    throw ContextError(
      "Failed to resolve \(what) \(path)", cause: HostError(ioErrorDescription(errno)))
  }
  return canonical
}

func ioErrorDescription(_ code: Int32) -> String {
  "\(String(cString: strerror(code))) (os error \(code))"
}

func parseMountSpec(_ text: String) throws -> Mount {
  do { return try Mount.parse(text) } catch { throw UsageError(oneLine(error)) }
}

func parsePortForward(_ text: String) throws -> PortForward {
  do { return try PortForward.parse(text) } catch { throw UsageError(oneLine(error)) }
}

struct EgressOptions: ParsableArguments {
  @Option(help: "Egress mode when creating an instance: open, none, or filtered") var egress:
    String?
  @Option(
    name: .customLong("allow-host"),
    help: "Exact host to approve for a filtered boot. Does not change none or open to filtered"
  )
  var allowHost: [String] = []
}

func applyEgressOverride(_ config: IsoConfig, mode: String?, hosts: [String]) throws -> IsoConfig {
  guard mode != nil || !hosts.isEmpty else { return config }
  let resolved: EgressMode
  if let mode {
    guard let parsed = EgressMode(rawValue: mode) else {
      throw HostError("--egress must be open, none, or filtered")
    }
    resolved = parsed
  } else {
    resolved = config.egress
  }
  if !hosts.isEmpty, resolved != .filtered {
    throw HostError(
      "--allow-host requires an effective filtered egress; it does not change none or open to filtered"
    )
  }
  var extra: [ExactHostname] = []
  for host in hosts { extra.append(try ExactHostname(host)) }
  return config.overridingEgress(resolved, extraHosts: extra)
}

func parseGuestEnvironment(_ text: String) throws -> (EnvVarName, EnvValue) {
  do { return try GuestEnvState.parseCLIArgument(text) } catch { throw UsageError(oneLine(error)) }
}

// MARK: - up

struct Up: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Ensure an environment for a project directory exists and is running",
    discussion:
      "Re-runnable: if an instance already exists for DIR it is reused (running) or restarted (stopped) instead of being recreated."
  )

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Project directory (default: current directory)") var dir: String?
  @Option(
    help: "Instance name to use when creating the project environment", transform: parseInstanceName
  )
  var name: InstanceName?
  @Flag(help: "Create a separate named instance even when DIR already has one")
  var newInstance = false
  @Flag(help: "Copy/sync DIR into the guest as /workspace (default)") var copy = false
  @Flag(help: "Mount DIR at /workspace instead of using --copy") var mount = false
  @Option(
    help:
      "Additional host directory to mount into the guest (`HOST_PATH[:GUEST_PATH]`, repeatable)",
    transform: parseMountSpec)
  var extraMount: [Mount] = []
  @Option(
    help: "Clone a git repository into /workspace instead of copying a local project directory")
  var gitRepo: String?
  @Option(help: "Number of vCPUs (overrides config when creating a new instance)") var vcpus: UInt8?
  @Option(
    help: "Memory in MiB (overrides config when creating a new instance)", transform: parseMemory)
  var mem: VmMemory?
  @Option(
    help: "Instance disk size in GiB (only used when creating a new instance)", transform: parseGiB)
  var disk: GiB?
  @Flag(
    name: .customLong("no-agents"),
    help: "Skip injecting Claude Code and Codex credentials/config into the VM")
  var noAgents = false
  @Flag(help: "Use github = \"off\" for this invocation and skip the GitHub PAT prompt")
  var noGithub = false
  @Option(
    help: "Named image to use when creating a new instance (default: \"default\")",
    transform: parseImageName)
  var image: ImageName?
  @Option(help: "Build or reuse a profile-derived image when creating a new instance")
  var profile: [String] = []
  @Flag(help: "Skip `.git/` when copying/syncing local directories") var excludeGit = false
  @Flag(
    help:
      "Suppress the interactive prompt to set up a scoped GitHub PAT when one is missing for the resolved repo"
  )
  var noPrompt = false
  @Option(
    help: "Forward a guest port to the host (`GUEST[:HOST]`, repeatable)",
    transform: parsePortForward)
  var forwardPort: [PortForward] = []
  @Option(
    help: ArgumentHelp(
      "Shell command to run inside the guest after boot (overrides `post_start` from the config). Failure is logged but does not fail the start",
      valueName: "CMD"))
  var postStart: String?
  @Option(
    name: .customLong("env"),
    help: ArgumentHelp(
      "Env var to set in the guest (`KEY=VALUE`, repeatable). A whole value `{vault:NAME}` is resolved from `iso secrets` for each session. Overrides `--env-file`, `guest_env` entries from config and any forwarded values with the same name",
      valueName: "KEY=VALUE"),
    transform: parseGuestEnvironment)
  var guestEnvironment: [(EnvVarName, EnvValue)] = []
  @Option(
    help: ArgumentHelp(
      "A `.env` file of guest env vars (`KEY=value`, `{vault:NAME}` references). Parsed strictly; never run by a shell",
      valueName: "PATH"))
  var envFile: String?
  @Option(
    help: ArgumentHelp(
      "Explicit path to a `devcontainer.json` to use (skips discovery)", valueName: "PATH"))
  var devcontainer: String?
  @Flag(help: "Ignore any discovered `devcontainer.json` (escape hatch for CI)")
  var noDevcontainer = false
  @Flag(help: "Translate `devcontainer.json` and print the report, then exit before any VM work")
  var dryRun = false
  @Flag(help: "With --dry-run, emit the resolved plan as JSON on stdout") var json = false
  @OptionGroup var egressOptions: EgressOptions

  func validate() throws {
    if newInstance && name == nil {
      throw UsageError("the following required arguments were not provided:\n  --name <NAME>")
    }
    if copy && mount { throw UsageError("the argument '--copy' cannot be used with '--mount'") }
    if gitRepo != nil && (dir != nil || copy || mount) {
      throw UsageError(
        "the argument '--git-repo <GIT_REPO>' cannot be used with '[DIR]', '--copy' or '--mount'")
    }
    if devcontainer != nil && noDevcontainer {
      throw UsageError(
        "the argument '--devcontainer <PATH>' cannot be used with '--no-devcontainer'")
    }
    if json && !dryRun {
      throw UsageError("the following required arguments were not provided:\n  --dry-run")
    }
  }

  var profiles: [String] { profile.flatMap { $0.split(separator: ",").map(String.init) } }

  /// Sorted, deduplicated profile list and the image named after it.
  static func profileTarget(_ profiles: [String]) throws -> (profiles: [String], image: ImageName)?
  {
    guard !profiles.isEmpty else { return nil }
    let names = Array(Set(profiles)).sorted {
      Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
    }
    do {
      return (names, try ImageName(names.joined(separator: "-")))
    } catch {
      throw ContextError(
        "Cannot derive an image name from profile list: \(names.joined(separator: ", "))",
        cause: error)
    }
  }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global) {
        try applyEgressOverride($0, mode: egressOptions.egress, hosts: egressOptions.allowHost)
      }
      for warning in try context.config.validated() { context.diagnostics.warn(warning) }
      let target = try Self.profileTarget(profiles)
      if target != nil, let image {
        throw HostError(
          "`iso up --profile` derives the image name from the sorted profile list; use `iso setup --image \(image) --profile ...` and then `iso up --image \(image)` for an explicit named image."
        )
      }
      let workflow = try UpWorkflow(
        command: self, lifecycle: ProjectLifecycle(context, noGitHub: noGithub), target: target)
      if dryRun { try workflow.emitDryRun(json: json) } else { try workflow.run() }
    }
  }
}

extension UpWorkflow {
  init(command: Up, lifecycle: ProjectLifecycle, target: (profiles: [String], image: ImageName)?)
    throws
  {
    var request = UpRequest(
      configTarget: try command.global.configTarget(lifecycle.context.environment))
    request.dir = command.dir
    request.gitRepo = command.gitRepo
    request.name = command.name
    request.image = command.image
    request.newInstance = command.newInstance
    request.vcpus = command.vcpus
    request.mem = command.mem
    request.disk = command.disk
    request.postStart = command.postStart
    request.guestEnvironment = command.guestEnvironment
    request.envFile = command.envFile
    request.forwardPort = command.forwardPort
    request.extraMount = command.extraMount
    request.excludeGit = command.excludeGit
    request.noAgents = command.noAgents
    request.noGithub = command.noGithub
    request.noPrompt = command.noPrompt
    request.transport = command.mount ? .mount : .copy
    request.devcontainerInput = .fromFlags(
      path: command.devcontainer, noDevcontainer: command.noDevcontainer)
    self.init(request: request, lifecycle: lifecycle, target: target)
  }

  func emitDryRun(json: Bool) throws {
    let options = try previewOptions()
    if !json {
      _ = try resolver.resolve(options, inputs: translatorInputs(), stage: .start)
      return
    }
    let translation = try resolver.collect(options, inputs: translatorInputs(), stage: .start)
    // Profile-mapped features are baked at setup; a start-stage translation
    // contributes none, so the effective set is the CLI list.
    var plan = DevcontainerDryRunPlan(
      report: translation?.report, profiles: target?.profiles ?? [],
      guestUser: Devcontainer.persistedGuestUser(lifecycle.config, image: effectiveImage),
      vcpus: request.vcpus, memory: request.mem?.mib, disk: request.disk)
    plan.security = lifecycle.config.securitySummary
    try context.output.writeJSON(plan)
  }

}

// MARK: - start

struct Start: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Restart a stopped VM")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Stopped instance name (optional only when exactly one stopped instance exists)",
    transform: parseInstanceName)
  var name: InstanceName?
  @Option(help: "Project directory used to select an associated stopped instance")
  var workspace: String?
  @Flag(
    name: .customLong("no-agents"),
    help: "Skip injecting Claude Code and Codex credentials/config into the VM")
  var noAgents = false
  @Flag(help: "Use github = \"off\" for this invocation and skip the GitHub PAT prompt")
  var noGithub = false
  @Option(
    help:
      "Forward a guest port to the host (`GUEST[:HOST]`, repeatable). `--forward-port 3000` forwards guest 3000 to host 3000; `--forward-port 3000:3001` forwards guest 3000 to host 3001",
    transform: parsePortForward)
  var forwardPort: [PortForward] = []
  @Flag(
    help:
      "Suppress the interactive prompt to set up a scoped GitHub PAT when one is missing for the resolved repo"
  )
  var noPrompt = false
  @Option(
    help: ArgumentHelp(
      "Shell command to run inside the guest after boot (overrides `post_start` from the config). Failure is logged but does not fail the start",
      valueName: "CMD"))
  var postStart: String?
  @Option(
    name: .customLong("env"),
    help: ArgumentHelp(
      "Env var to set in the guest (`KEY=VALUE`, repeatable). A whole value `{vault:NAME}` is resolved from `iso secrets` for each session. Overrides `--env-file`, `guest_env` entries from config and any forwarded values with the same name",
      valueName: "KEY=VALUE"),
    transform: parseGuestEnvironment)
  var guestEnvironment: [(EnvVarName, EnvValue)] = []
  @Option(
    help: ArgumentHelp(
      "A `.env` file of guest env vars (`KEY=value`, `{vault:NAME}` references). Parsed strictly; never run by a shell",
      valueName: "PATH"))
  var envFile: String?
  @Option(
    help: ArgumentHelp(
      "Explicit path to a `devcontainer.json` to use (skips discovery)", valueName: "PATH"))
  var devcontainer: String?
  @Flag(help: "Ignore any discovered `devcontainer.json` (escape hatch for CI)")
  var noDevcontainer = false
  @Flag(
    help: "Translate `devcontainer.json` and print the report, then exit before doing any VM work")
  var dryRun = false
  @Flag(help: "With --dry-run, emit the resolved plan as JSON on stdout") var json = false
  @OptionGroup var egressOptions: EgressOptions

  func validate() throws {
    if devcontainer != nil && noDevcontainer {
      throw UsageError(
        "the argument '--devcontainer <PATH>' cannot be used with '--no-devcontainer'")
    }
    if json && !dryRun {
      throw UsageError("the following required arguments were not provided:\n  --dry-run")
    }
  }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global) {
        try applyEgressOverride($0, mode: egressOptions.egress, hosts: egressOptions.allowHost)
      }
      for warning in try context.config.validated() { context.diagnostics.warn(warning) }
      let lifecycle = ProjectLifecycle(context, noGitHub: noGithub)
      if dryRun { return try dryRunReport(lifecycle) }
      let selection = StoppedInstanceSelection(
        name: name, workspaceDirectory: workspace, devcontainerPath: devcontainer)
      let instance = try Self.stoppedTarget(lifecycle, selection)
      var options = RestartRequest(
        boot: BootOptions(
          noAgents: noAgents, noPrompt: noPrompt,
          forwardPorts: forwardPort, configTarget: try global.configTarget(context.environment),
          postStartOverride: postStart))
      options.boot.persistedGuestEnvironment = try lifecycle.mergeRuntimeGuestEnvironment(
        cli: guestEnvironment, envFile: envFile, devcontainer: nil)
      try lifecycle.restart(instance, options)
    }
  }

  func dryRunReport(_ lifecycle: ProjectLifecycle) throws {
    let guestUser = Devcontainer.persistedGuestUser(lifecycle.config, image: .default)
    let inputs = DevcontainerTranslatorInputs(
      cliPostStart: postStart, cliGuestEnvKeys: guestEnvironment.map(\.0),
      cliForwardPorts: forwardPort, persistedGuestUser: guestUser,
      cliWorkspaceOrGitRepo: workspace != nil)
    let options = DevcontainerOptions(
      input: .fromFlags(path: devcontainer, noDevcontainer: noDevcontainer), dryRun: true,
      workspace: workspace, githubAuth: lifecycle.config.github,
      preferencePath: Devcontainer.preferencesPath(lifecycle.config))
    let resolver = DevcontainerResolver(
      environment: lifecycle.context.environment.variables, diagnostics: lifecycle.diagnostics)
    guard json else {
      _ = try resolver.resolve(options, inputs: inputs, stage: .start)
      return
    }
    let translation = try resolver.collect(options, inputs: inputs, stage: .start)
    var plan = DevcontainerDryRunPlan(
      report: translation?.report, profiles: [], guestUser: guestUser, vcpus: nil, memory: nil,
      disk: nil)
    plan.security = lifecycle.config.securitySummary
    try lifecycle.context.output.writeJSON(plan)
  }

  /// The stopped instance `start` restarts: by name, by recorded
  /// workspace, or the only stopped one. Creation options are refused.
  static func stoppedTarget(_ lifecycle: ProjectLifecycle, _ options: StoppedInstanceSelection)
    throws
    -> Instance
  {
    guard let instance = try findStopped(lifecycle, options) else {
      throw HostError(noStoppedInstanceMessage(options))
    }
    let workspaceWasKey = options.name == nil && options.workspaceDirectory != nil
    if options.devcontainerPath != nil || (options.workspaceDirectory != nil && !workspaceWasKey) {
      throw HostError(
        "Instance '\(instance.name)' already exists (stopped). These creation options would be silently ignored on restart.\nTo apply new options, destroy the instance first:\n  iso destroy \(instance.name)\n  iso up [DIR]"
      )
    }
    return instance
  }

  static func findStopped(_ lifecycle: ProjectLifecycle, _ options: StoppedInstanceSelection) throws
    -> Instance?
  {
    let instances = try lifecycle.listInstances()
    let backend = lifecycle.backend
    if let name = options.name {
      guard let instance = instances.first(where: { $0.name == name }) else { return nil }
      if backend.isRunning(instance) {
        throw HostError(
          "Instance '\(name)' is already running.\nUse `iso shell \(name)` to connect, or `iso stop \(name)` first."
        )
      }
      return instance
    }
    if let directory = options.workspaceDirectory {
      let canonical = try resolveCanonical(directory, "workspace path")
      guard
        let instance = try lifecycle.workspaceInstance(
          canonical,
          context: { path, names in
            "Multiple instances share workspace \(path):\n  \(names)\nSpecify which to restart: iso start <name>"
          })
      else { return nil }
      if backend.isRunning(instance) {
        throw HostError(
          "Instance '\(instance.name)' is already running with this workspace.\nUse `iso shell \(instance.name)` to connect."
        )
      }
      return instance
    }
    let stopped = instances.filter { !backend.isRunning($0) }
    switch stopped.count {
    case 0: return nil
    case 1: return stopped[0]
    default:
      throw HostError(
        "Multiple stopped instances exist: \(stopped.map(\.name.rawValue).joined(separator: ", "))\nSpecify which to restart: iso start <name>"
      )
    }
  }

  static func noStoppedInstanceMessage(_ options: StoppedInstanceSelection) -> String {
    var message: String
    if let name = options.name {
      message = "No stopped instance named '\(name)' exists."
    } else if let path = options.workspaceDirectory {
      message = "No stopped instance is associated with workspace \(path)."
    } else {
      message = "No stopped instances exist."
    }
    if options.devcontainerPath != nil {
      message +=
        "\n`iso start` only starts stopped instances; creation options belong to `iso up`."
    }
    if let path = options.workspaceDirectory {
      message += "\nCreate or reconnect to this project with:\n  iso up \(path)"
    } else {
      message += "\nCreate or reconnect to a project with:\n  iso up [DIR]"
    }
    return message + "\nUse `iso list` to see existing instances."
  }
}

// MARK: - shell / exec

struct Shell: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Open an interactive shell in the VM (or run a command non-interactively)",
    aliases: ["ssh"])

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Argument(parsing: .postTerminator, help: "Command to run (non-interactive, no PTY)")
  var command: [String] = []

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let (_, session) = try context.agents.openSession(
        context.backend, name: name, instances: context.listInstances())
      if command.isEmpty {
        try InteractiveSSH.run(context.ssh, session, [], diagnostics: context.diagnostics)
      } else {
        try InteractiveSSH.runCommand(
          context.ssh, session, command, diagnostics: context.diagnostics)
      }
    }
  }
}

struct Exec: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Run a command in the VM and return its output (non-interactive)",
    discussion:
      "The command and its arguments must follow `--` to avoid conflicting with the optional instance name positional, e.g. `iso exec my-vm -- ls -la` or `iso exec -- ls -la`."
  )

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Argument(parsing: .postTerminator, help: "Command and arguments to run (after `--`)")
  var command: [String] = []

  func validate() throws {
    if command.isEmpty {
      throw UsageError("the following required arguments were not provided:\n  <COMMAND>...")
    }
  }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let (_, session) = try context.agents.openSession(
        context.backend, name: name, instances: context.listInstances())
      try InteractiveSSH.exec(context.ssh, session, command, diagnostics: context.diagnostics)
    }
  }
}

extension ReprovisionWorkflow {
  static func confirmation(_ name: InstanceName, _ image: ImageName, _ state: WorkspaceState?)
    -> String
  {
    let restored =
      switch state?.source {
      case .workspace(let path)?: "\n/workspace will be re-synced from \(path)."
      case .gitRepo(let url)?: "\n/workspace will be re-cloned from \(url)."
      case .mount(let path)?: "\n\(path) is re-mounted from the host."
      case nil: "\nThis instance has no recorded workspace to restore."
      }
    return
      "Reprovision instance '\(name)' from image '\(image)'?\nEverything written inside the guest is destroyed.\(restored)\nName, IP, disk size, port forwards and guest env are kept."
  }
}
