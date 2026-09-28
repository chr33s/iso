import ArgumentParser
import CoopConfiguration
import CoopCore
import CoopHost
import CoopSecrets
import Foundation

// MARK: - Shared start/restart machinery

/// Inputs to a fresh start, a restart or a reprovision. Creation-only
/// fields (`disk`, `mounts`, `excludeGit`, `appliedDevcontainer`) are
/// ignored on a restart.
struct StartOptions {
  var name: InstanceName?
  var workspaceDirectory: String?
  var gitRepo: String?
  var noAgents = false
  var noPrompt = false
  var disk: GiB?
  var mounts: [Mount] = []
  var excludeGit = false
  var forwardPorts: [PortForward] = []
  var configTarget: ConfigTarget
  var postStartOverride: String?
  var persistedGuestEnvironment: [EnvVarName: EnvValue] = [:]
  var devcontainerPath: String?
  var appliedDevcontainer: AppliedDevcontainer?
}

/// One command's lifecycle: the loaded configuration plus the explicit
/// overrides this command applies to it (S-02), and the services built
/// from the current value.
final class ProjectLifecycle {
  let context: CommandContext
  private(set) var config: CoopConfig
  let githubDisabled: Bool

  init(_ context: CommandContext, noGitHub: Bool) {
    self.context = context
    githubDisabled = noGitHub
    config = noGitHub ? context.config.disablingGitHub() : context.config
  }

  var diagnostics: Diagnostics { context.diagnostics }
  var backend: AppleBackend { context.backend.reconfigured(config) }
  var forwards: PortForwards { context.forwards }
  var sshConfig: SSHConfigFile { get throws { try context.sshConfigFile() } }

  var tokens: HostGitHubTokens {
    HostGitHubTokens(
      config: config, environment: context.environment.variables, diagnostics: diagnostics,
      githubDisabled: githubDisabled)
  }

  var agents: AgentBootstrap {
    let resolver = CredentialResolver(environment: context.environment.variables)
    return AgentBootstrap(
      config: config, client: context.ssh, environment: context.environment.variables,
      home: context.environment.home, resolver: resolver,
      proxies: ProxyLauncher(
        environment: context.environment.variables, resolver: resolver, diagnostics: diagnostics,
        coopExecutable: CommandLine.executablePath),
      github: tokens, diagnostics: diagnostics, secrets: context.secretResolver)
  }

  func listInstances() throws -> [Instance] { try context.listInstances() }

  func applyVMOverrides(vcpus: UInt8?, memory: VmMemory?) throws {
    if vcpus == 0 { throw HostError("--vcpus must be > 0") }
    config = config.overridingVM(vcpus: vcpus, memory: memory, templateSize: nil)
  }

  func apply(_ translation: DevcontainerTranslation) throws {
    config = try Devcontainer.applyToConfig(config, translation)
  }

  /// CLI `--env` over `--env-file` over devcontainer `containerEnv`, folded
  /// into the guest variables of this command; the merged set is what gets
  /// persisted. `{vault:}` references are persisted as references and
  /// resolved per session, never folded in as values.
  func mergeRuntimeGuestEnvironment(
    cli: [(EnvVarName, EnvValue)], envFile: String?,
    devcontainer: [(name: EnvVarName, value: String)]?
  ) throws -> [EnvVarName: EnvValue] {
    let merged = GuestEnvState.merge(
      devcontainer: Dictionary(
        (devcontainer ?? []).map { ($0.name, EnvValue.literal($0.value)) },
        uniquingKeysWith: { $1 }),
      envFile: try envFile.map(GuestEnvState.readEnvFile) ?? [:],
      cli: Dictionary(cli, uniquingKeysWith: { $1 }))
    try GuestEnvState.rejectProviderReferences(merged)
    for (name, value) in devcontainer ?? [] where value.contains("{vault:") {
      diagnostics.warn(
        "devcontainer containerEnv '\(name)' contains `{vault:`; it is passed to the guest as literal text. Stored-secret references work only in --env and --env-file."
      )
    }
    try preflightReferences(merged)
    foldGuestEnvironment(merged)
    return merged
  }

  /// Resolves every `{vault:}` reference before any VM work, so a wrong
  /// passphrase or a missing secret fails the command up front. The values
  /// stay in the process's resolver cache for this command's sessions.
  func preflightReferences(_ entries: [EnvVarName: EnvValue]) throws {
    let names = Set(entries.values.compactMap(\.reference))
    guard !names.isEmpty else { return }
    let resolved = try context.secretResolver.resolve(names)
    if let missing = names.subtracting(resolved.keys).sorted().first {
      throw HostError("unable to resolve required secret '\(missing)'")
    }
  }

  /// Literal entries become this command's guest variables; references are
  /// left to the session overlay.
  func foldGuestEnvironment(_ entries: [EnvVarName: EnvValue]) {
    config = config.applyingDevcontainer(
      vcpus: nil, memory: nil, postStart: nil,
      guestEnvironment: entries.compactMap { name, value in
        if case .literal(let text) = value { (name: name, value: text) } else { nil }
      })
  }

  /// The PAT wizard runs before any VM cost, and only without an assignment.
  func maybePromptForPAT(_ instance: Instance, repo: RepoSlug?, _ options: StartOptions) throws {
    if try GitHubAssignment.active(config, instance, githubDisabled: githubDisabled) == nil {
      config = try context.github.maybePrompt(
        config, target: options.configTarget, repo: repo, noPrompt: options.noPrompt)
    }
  }

  // MARK: Fresh start

  /// Allocate a new instance and run its first boot; any failure removes
  /// what was created.
  func allocateAndStart(
    name: InstanceName?, image: ImageName, workspacePath: String?, _ options: StartOptions
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
  func resolveStartRepo(_ options: StartOptions) throws -> RepoSlug? {
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

  func startInstance(_ instance: Instance, _ options: StartOptions) throws {
    let repo = try resolveStartRepo(options)
    try maybePromptForPAT(instance, repo: repo, options)
    // Busy host ports fail before any VM cost.
    let forwardSet = PortForward.merge(config: config.forwardPorts, cli: options.forwardPorts)
    try PortForwards.checkCollisions(forwardSet)
    try backend.createAndStart(instance, diskGiB: options.disk.map { UInt64($0.value) })
    try provisionFirstBoot(instance, options, repo: repo, forwardSet: forwardSet)
  }

  /// A guest carrying only its image: forwards, state, agents, then the
  /// workspace and mounts. Shared by a fresh start and a reprovision.
  func provisionFirstBoot(
    _ instance: Instance, _ options: StartOptions, repo: RepoSlug?, forwardSet: [PortForward]
  ) throws {
    try Shutdown.check()
    let target = try readyTarget(instance)
    try Shutdown.check()
    refreshSSHConfig(instance, target)
    try PortForwards.save(forwardSet, instance, diagnostics: diagnostics)
    try forwards.spawn(instance, target, forwardSet)
    try GuestEnvState(entries: options.persistedGuestEnvironment).save(
      instance, diagnostics: diagnostics)
    if let applied = options.appliedDevcontainer {
      try DevcontainerState(applied: applied).save(instance)
    }
    try agents.bootstrapAndPostStart(
      instance, target: target, repo: repo, noAgents: options.noAgents,
      postStartOverride: options.postStartOverride, mode: .firstBoot)
    try Shutdown.check()

    let transfer = context.transfer
    var recorded = false
    if let directory = options.workspaceDirectory {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { throw HostError("Workspace path \(directory) is not a directory") }
      guard let absolute = canonicalPath(directory) else {
        throw HostError("Failed to resolve \(directory)")
      }
      try transfer.tarPipe(
        target, source: absolute, to: guestWorkspace, excludeGit: options.excludeGit)
      try WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: absolute))
        .save(instance, diagnostics: diagnostics)
      recorded = true
    } else if let url = options.gitRepo {
      let assigned = try GitHubAssignment.active(config, instance, githubDisabled: githubDisabled)
      try GitHubGuest.clone(
        context.ssh, target, url: url, github: config.github, assigned: assigned?.repo,
        tokens: GitHubTokens(environment: context.environment.variables, diagnostics: diagnostics))
      try WorkspaceState(guestPath: guestWorkspace, source: .gitRepo(url: url))
        .save(instance, diagnostics: diagnostics)
      recorded = true
    }
    if !options.mounts.isEmpty {
      if recorded {
        try transfer.syncMountContents(target, options.mounts, excludeGit: options.excludeGit)
      } else {
        try transfer.syncMounts(target, instance, options.mounts, excludeGit: options.excludeGit)
      }
      diagnostics.warn(
        "\(AppleBackend.name) mounts use one-time sync, not live filesystem sharing. Use `coop push` / `coop pull` to sync changes."
      )
    }
    diagnostics.log(
      .info, "Instance '\(instance.name)' started — SSH: \(target.host):\(target.port)")
  }

  func readyTarget(_ instance: Instance) throws -> SSHTarget {
    let target = try backend.sshTarget(instance)
    do {
      try context.ssh.waitUntilReady(target, timeout: .seconds(30), diagnostics: diagnostics)
    } catch {
      throw ContextError("Guest booted but SSH is not accepting connections", cause: error)
    }
    return target
  }

  /// Keeps an alias the user installed current; never installs one.
  func refreshSSHConfig(_ instance: Instance, _ target: SSHTarget) {
    do { try sshConfig.refreshIfPresent(target, instance) } catch {
      diagnostics.warn("Failed to refresh SSH config for '\(instance.name)': \(error)")
    }
  }

  // MARK: Restart

  /// Boot a stopped instance with the forwards and guest variables it was
  /// last started with (CLI values override per key).
  func restart(_ instance: Instance, _ options: StartOptions) throws {
    diagnostics.log(.info, "Restarting stopped instance '\(instance.name)'")
    DevcontainerState.warnIfChanged(instance, diagnostics: diagnostics)
    let shutdown = Shutdown.install()
    defer { shutdown.restore() }
    let repo = tokens.instanceRepo(instance)
    try maybePromptForPAT(instance, repo: repo, options)
    let saved = try PortForwards.load(instance) ?? []
    let forwardSet = PortForward.merge(config: saved, cli: options.forwardPorts)
    try PortForwards.checkCollisions(forwardSet)
    var guestEnvironment = try GuestEnvState.tryLoad(instance)?.entries ?? [:]
    for (key, value) in options.persistedGuestEnvironment { guestEnvironment[key] = value }
    try GuestEnvState.rejectProviderReferences(guestEnvironment)
    try preflightReferences(guestEnvironment)
    foldGuestEnvironment(guestEnvironment)
    _ = try GitHubAssignment.active(config, instance, githubDisabled: githubDisabled)
    try backend.startExisting(instance)
    try Shutdown.check()
    let target = try readyTarget(instance)
    try Shutdown.check()
    refreshSSHConfig(instance, target)
    try PortForwards.save(forwardSet, instance, diagnostics: diagnostics)
    try forwards.spawn(instance, target, forwardSet)
    try GuestEnvState(entries: guestEnvironment).save(instance, diagnostics: diagnostics)
    try agents.bootstrapAndPostStart(
      instance, target: target, repo: repo, noAgents: options.noAgents,
      postStartOverride: options.postStartOverride, mode: .restart)
    diagnostics.log(
      .info, "Instance '\(instance.name)' restarted — SSH: \(target.host):\(target.port)")
  }

  // MARK: Instance lookup

  /// The one instance recorded for `canonical` (the project directory).
  func workspaceInstance(_ canonical: String, context message: (String, String) -> String) throws
    -> Instance?
  {
    let matching = try listInstances().filter {
      WorkspaceState.loadOrWarn(
        $0, consequence: "workspace-affinity matching will skip this instance",
        diagnostics: diagnostics)?.source.hostPath == canonical
    }
    switch matching.count {
    case 0: return nil
    case 1: return matching[0]
    default:
      throw HostError(message(canonical, matching.map(\.name.rawValue).joined(separator: ", ")))
    }
  }

  func gitRepoInstance(_ url: String) throws -> Instance? {
    let matching = try listInstances().filter {
      WorkspaceState.loadOrWarn(
        $0, consequence: "git-repo matching will skip this instance", diagnostics: diagnostics)?
        .source == .gitRepo(url: url)
    }
    switch matching.count {
    case 0: return nil
    case 1: return matching[0]
    default:
      throw HostError(
        "Multiple instances share git repo \(url):\n  \(matching.map(\.name.rawValue).joined(separator: ", "))\nPick one explicitly with `coop start <name>` (for a stopped\ninstance) or `coop claude <name>` (for a running one)."
      )
    }
  }
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

func parseGuestEnvironment(_ text: String) throws -> (EnvVarName, EnvValue) {
  do { return try GuestEnvState.parseCLIArgument(text) } catch { throw UsageError(oneLine(error)) }
}

// MARK: - up

enum ProjectTransport: String {
  case copy
  case mount
}

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
    name: [.customLong("no-agents"), .customLong("no-claude", withSingleDash: false)],
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
      "Env var to set in the guest (`KEY=VALUE`, repeatable). A whole value `{vault:NAME}` is resolved from `coop secrets` for each session. Overrides `--env-file`, `guest_env` entries from config and any forwarded values with the same name",
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
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      for warning in try context.config.validated() { context.diagnostics.warn(warning) }
      let target = try Self.profileTarget(profiles)
      if target != nil, let image {
        throw HostError(
          "`coop up --profile` derives the image name from the sorted profile list; use `coop setup --image \(image) --profile ...` and then `coop up --image \(image)` for an explicit named image."
        )
      }
      try UpFlow(
        command: self, lifecycle: ProjectLifecycle(context, noGitHub: noGithub), target: target
      )
      .run()
    }
  }
}

/// `coop up`, split from the argument definitions.
struct UpFlow {
  let command: Up
  let lifecycle: ProjectLifecycle
  let target: (profiles: [String], image: ImageName)?

  var context: CommandContext { lifecycle.context }
  var diagnostics: Diagnostics { lifecycle.diagnostics }
  var transport: ProjectTransport { command.mount ? .mount : .copy }
  var effectiveImage: ImageName { target?.image ?? command.image ?? .default }
  var input: DevcontainerInput {
    .fromFlags(path: command.devcontainer, noDevcontainer: command.noDevcontainer)
  }

  func translatorInputs() -> DevcontainerTranslatorInputs {
    DevcontainerTranslatorInputs(
      cliVcpus: command.vcpus, cliMemory: command.mem, cliDisk: command.disk,
      cliPostStart: command.postStart, cliGuestEnvKeys: command.guestEnvironment.map(\.0),
      cliForwardPorts: command.forwardPort, cliMounts: command.extraMount,
      cliProfiles: target?.profiles ?? [],
      persistedGuestUser: Devcontainer.persistedGuestUser(lifecycle.config, image: effectiveImage),
      cliWorkspaceOrGitRepo: true)
  }

  var resolver: DevcontainerResolver {
    DevcontainerResolver(environment: context.environment.variables, diagnostics: diagnostics)
  }

  func options(dryRun: Bool, workspace: String?, mounts: [Mount], gitRepo: String?)
    -> DevcontainerOptions
  {
    DevcontainerOptions(
      input: input, dryRun: dryRun, workspace: workspace, mounts: mounts, gitRepo: gitRepo,
      githubAuth: lifecycle.config.github,
      preferencePath: Devcontainer.preferencesPath(lifecycle.config))
  }

  func run() throws {
    if let url = command.gitRepo { return try runGitRepo(url) }
    let projectDirectory = try Self.projectDirectory(command.dir)
    let projectMount = try Mount(host: projectDirectory, guest: guestWorkspace)
    let discoveryMounts = transport == .mount ? [projectMount] : []
    if command.dryRun {
      return try emitDryRun(
        options(dryRun: true, workspace: projectDirectory, mounts: discoveryMounts, gitRepo: nil))
    }
    if !command.newInstance,
      let instance = try lifecycle.workspaceInstance(
        projectDirectory,
        context: { path, names in
          "Multiple instances share workspace \(path):\n  \(names)\nPick one explicitly with `coop start <name>` (for a stopped\ninstance) or `coop claude <name>` (for a running one)."
        })
    {
      if let name = command.name, instance.name != name {
        throw HostError(
          "Project \(projectDirectory) is already associated with instance '\(instance.name)', not '\(name)'."
        )
      }
      try ensureExistingCompatible(instance, subject: "this project")
      try ensureSameTransport(instance)
      if lifecycle.backend.isRunning(instance) {
        DevcontainerState.warnIfChanged(instance, diagnostics: diagnostics)
        try rejectRestartOnlyInputs(instance)
        diagnostics.log(
          .info, "Instance '\(instance.name)' is already running for \(projectDirectory)")
        return
      }
      try restart(instance)
      return
    }
    try ensureProfileImage()
    try create(
      projectDirectory: projectDirectory, projectMount: projectMount, discovery: discoveryMounts)
  }

  func runGitRepo(_ url: String) throws {
    if command.dryRun {
      return try emitDryRun(options(dryRun: true, workspace: nil, mounts: [], gitRepo: url))
    }
    if !command.newInstance, let instance = try lifecycle.gitRepoInstance(url) {
      if let name = command.name, instance.name != name {
        throw HostError(
          "Git repo \(url) is already associated with instance '\(instance.name)', not '\(name)'.")
      }
      try ensureExistingCompatible(instance, subject: "this git repo")
      if lifecycle.backend.isRunning(instance) {
        try rejectRestartOnlyInputs(instance)
        diagnostics.log(.info, "Instance '\(instance.name)' is already running for \(url)")
        return
      }
      try restart(instance)
      return
    }
    try ensureProfileImage()
    try createFromGitRepo(url)
  }

  static func projectDirectory(_ dir: String?) throws -> String {
    let path = dir ?? FileManager.default.currentDirectoryPath
    let canonical = try resolveCanonical(path, "project directory")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw HostError("Project directory is not a directory: \(canonical)") }
    return canonical
  }

  func emitDryRun(_ options: DevcontainerOptions) throws {
    if !command.json {
      _ = try resolver.resolve(options, inputs: translatorInputs(), stage: .start)
      return
    }
    let translation = try resolver.collect(options, inputs: translatorInputs(), stage: .start)
    // Profile-mapped features are baked at setup; a start-stage translation
    // contributes none, so the effective set is the CLI list.
    let plan = DevcontainerDryRunPlan(
      report: translation?.report, profiles: target?.profiles ?? [],
      guestUser: Devcontainer.persistedGuestUser(lifecycle.config, image: effectiveImage),
      vcpus: command.vcpus, memory: command.mem?.mib, disk: command.disk)
    context.output.out(String(plan.json.rendered().dropLast()))
  }

  func ensureExistingCompatible(_ instance: Instance, subject: String) throws {
    if let image = command.image, instance.image != image {
      throw HostError(
        "Instance '\(instance.name)' already exists for \(subject) using image '\(instance.image)'. `coop up --image \(image)` only applies when creating a new instance.\nUse `coop destroy \(instance.name)` first to recreate it with a different image."
      )
    }
    if let target, instance.image != target.image {
      throw HostError(
        "Instance '\(instance.name)' already exists for \(subject) using image '\(instance.image)'. `coop up --profile \(target.profiles.joined(separator: ","))` would use image '\(target.image)', but profiles only apply when creating a new instance.\nUse `coop destroy \(instance.name)` first to recreate it with those profiles."
      )
    }
    let explicitDevcontainer = if case .explicit = input { true } else { false }
    let isProject = subject == "this project"
    if command.disk != nil || command.vcpus != nil || command.mem != nil
      || !command.extraMount.isEmpty || (isProject && command.excludeGit) || explicitDevcontainer
    {
      let flags =
        isProject
        ? "--vcpus, --mem, --disk, --extra-mount, --exclude-git, and --devcontainer only apply"
        : "--vcpus, --mem, --disk, --extra-mount, and --devcontainer only apply"
      throw HostError(
        "Instance '\(instance.name)' already exists for \(subject). \(flags) when creating a new instance.\nTo change memory, vCPUs, or disk on the existing instance, stop it and run `coop resize`. Otherwise `coop destroy \(instance.name)` first to recreate it with those options."
      )
    }
  }

  func ensureSameTransport(_ instance: Instance) throws {
    guard
      let state = WorkspaceState.loadOrWarn(
        instance, consequence: "project transport check will skip this instance",
        diagnostics: diagnostics)
    else { return }
    let existing: ProjectTransport
    switch state.source {
    case .workspace: existing = .copy
    case .mount: existing = .mount
    case .gitRepo: return
    }
    if existing != transport {
      throw HostError(
        "Instance '\(instance.name)' already exists for this project using \(existing.rawValue) transport, but this command requested \(transport.rawValue).\nRe-run with the original transport, or `coop destroy \(instance.name)` first to recreate it."
      )
    }
  }

  func rejectRestartOnlyInputs(_ instance: Instance) throws {
    if command.noAgents || command.noGithub || !command.forwardPort.isEmpty
      || command.postStart != nil || !command.guestEnvironment.isEmpty || command.envFile != nil
    {
      throw HostError(
        "Instance '\(instance.name)' is already running for this project. --no-agents, --no-github, --forward-port, --post-start, --env, and --env-file only take effect during start or restart.\nRun `coop stop \(instance.name)` first, then repeat `coop up` with those options."
      )
    }
  }

  func baseStartOptions() throws -> StartOptions {
    StartOptions(
      noAgents: command.noAgents, noPrompt: command.noPrompt, forwardPorts: command.forwardPort,
      configTarget: try command.global.configTarget(context.environment),
      postStartOverride: command.postStart)
  }

  func restart(_ instance: Instance) throws {
    var options = try baseStartOptions()
    options.persistedGuestEnvironment = try lifecycle.mergeRuntimeGuestEnvironment(
      cli: command.guestEnvironment, envFile: command.envFile, devcontainer: nil)
    try lifecycle.restart(instance, options)
  }

  func ensureProfileImage() throws {
    guard let target else { return }
    let definitions = try resolveProfiles(target.profiles, lifecycle.config)
    let shutdown = Shutdown.install()
    defer { shutdown.restore() }
    try lifecycle.backend.setup(
      SetupOptions(
        rebuild: false, profiles: definitions, image: target.image, guestUser: .default,
        builderTimeout: nil))
  }

  /// Everything a new instance takes from the translation and the CLI.
  func creationOptions(
    _ translation: DevcontainerTranslation?, rule: WorkspaceMountRule, leading: [Mount]
  )
    throws -> StartOptions
  {
    try lifecycle.applyVMOverrides(vcpus: command.vcpus, memory: command.mem)
    if let translation { try lifecycle.apply(translation) }
    var options = try baseStartOptions()
    if let translation {
      options.forwardPorts = Devcontainer.mergeIntoForwardPorts(
        config: translation.forwardPorts, translation: command.forwardPort)
    }
    options.persistedGuestEnvironment = try lifecycle.mergeRuntimeGuestEnvironment(
      cli: command.guestEnvironment, envFile: command.envFile,
      devcontainer: translation?.guestEnvironment)
    options.disk = Devcontainer.effectiveDisk(
      cli: command.disk, translation ?? DevcontainerTranslation())
    options.postStartOverride = command.postStart ?? translation?.postStart
    options.mounts =
      try ValidatedMounts(rule, leading + (translation?.mounts ?? []) + command.extraMount).mounts
    options.excludeGit = command.excludeGit
    options.appliedDevcontainer = translation?.applied
    return options
  }

  func create(projectDirectory: String, projectMount: Mount, discovery: [Mount]) throws {
    let translation = try resolver.resolve(
      options(dryRun: false, workspace: projectDirectory, mounts: discovery, gitRepo: nil),
      inputs: translatorInputs(), stage: .start)
    var options: StartOptions
    switch transport {
    case .copy:
      options = try creationOptions(translation, rule: .copyProject, leading: [])
      options.workspaceDirectory = projectDirectory
    case .mount:
      options = try creationOptions(
        translation, rule: .projectMountedOrNone, leading: [projectMount])
    }
    _ = try lifecycle.allocateAndStart(
      name: command.name, image: effectiveImage, workspacePath: projectDirectory, options)
  }

  func createFromGitRepo(_ url: String) throws {
    let translation = try resolver.resolve(
      options(dryRun: false, workspace: nil, mounts: [], gitRepo: url), inputs: translatorInputs(),
      stage: .start)
    var options = try creationOptions(translation, rule: .gitRepoClone, leading: [])
    options.gitRepo = url
    _ = try lifecycle.allocateAndStart(
      name: command.name ?? GitRepoURL.defaultInstanceName(url), image: effectiveImage,
      workspacePath: nil, options)
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
    name: [.customLong("no-agents"), .customLong("no-claude", withSingleDash: false)],
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
      "Env var to set in the guest (`KEY=VALUE`, repeatable). A whole value `{vault:NAME}` is resolved from `coop secrets` for each session. Overrides `--env-file`, `guest_env` entries from config and any forwarded values with the same name",
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
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      for warning in try context.config.validated() { context.diagnostics.warn(warning) }
      if CommandLine.arguments.contains("--no-claude") {
        context.diagnostics.warn(
          "--no-claude is deprecated and will be removed in a future release; use --no-agents")
      }
      let lifecycle = ProjectLifecycle(context, noGitHub: noGithub)
      if dryRun { return try dryRunReport(lifecycle) }
      var options = StartOptions(
        name: name, workspaceDirectory: workspace, noAgents: noAgents, noPrompt: noPrompt,
        forwardPorts: forwardPort, configTarget: try global.configTarget(context.environment),
        postStartOverride: postStart, devcontainerPath: devcontainer)
      let instance = try Self.stoppedTarget(lifecycle, options)
      options.persistedGuestEnvironment = try lifecycle.mergeRuntimeGuestEnvironment(
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
    let plan = DevcontainerDryRunPlan(
      report: translation?.report, profiles: [], guestUser: guestUser, vcpus: nil, memory: nil,
      disk: nil)
    lifecycle.context.output.out(String(plan.json.rendered().dropLast()))
  }

  /// The stopped instance `start` restarts: by name, by recorded
  /// workspace, or the only stopped one. Creation options are refused.
  static func stoppedTarget(_ lifecycle: ProjectLifecycle, _ options: StartOptions) throws
    -> Instance
  {
    guard let instance = try findStopped(lifecycle, options) else {
      throw HostError(noStoppedInstanceMessage(options))
    }
    let workspaceWasKey = options.name == nil && options.workspaceDirectory != nil
    if options.devcontainerPath != nil || (options.workspaceDirectory != nil && !workspaceWasKey) {
      throw HostError(
        "Instance '\(instance.name)' already exists (stopped). These creation options would be silently ignored on restart.\nTo apply new options, destroy the instance first:\n  coop destroy \(instance.name)\n  coop up [DIR]"
      )
    }
    return instance
  }

  static func findStopped(_ lifecycle: ProjectLifecycle, _ options: StartOptions) throws
    -> Instance?
  {
    let instances = try lifecycle.listInstances()
    let backend = lifecycle.backend
    if let name = options.name {
      guard let instance = instances.first(where: { $0.name == name }) else { return nil }
      if backend.isRunning(instance) {
        throw HostError(
          "Instance '\(name)' is already running.\nUse `coop shell \(name)` to connect, or `coop stop \(name)` first."
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
            "Multiple instances share workspace \(path):\n  \(names)\nSpecify which to restart: coop start <name>"
          })
      else { return nil }
      if backend.isRunning(instance) {
        throw HostError(
          "Instance '\(instance.name)' is already running with this workspace.\nUse `coop shell \(instance.name)` to connect."
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
        "Multiple stopped instances exist: \(stopped.map(\.name.rawValue).joined(separator: ", "))\nSpecify which to restart: coop start <name>"
      )
    }
  }

  static func noStoppedInstanceMessage(_ options: StartOptions) -> String {
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
        "\n`coop start` only starts stopped instances; creation options belong to `coop up`."
    }
    if let path = options.workspaceDirectory {
      message += "\nCreate or reconnect to this project with:\n  coop up \(path)"
    } else {
      message += "\nCreate or reconnect to a project with:\n  coop up [DIR]"
    }
    return message + "\nUse `coop list` to see existing instances."
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
    try CoopCLI.run {
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
      "The command and its arguments must follow `--` to avoid conflicting with the optional instance name positional, e.g. `coop exec my-vm -- ls -la` or `coop exec -- ls -la`."
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
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let (_, session) = try context.agents.openSession(
        context.backend, name: name, instances: context.listInstances())
      try InteractiveSSH.exec(context.ssh, session, command, diagnostics: context.diagnostics)
    }
  }
}

// MARK: - restore --reprovision

/// Wipe the guest and bring the instance back with the settings coop
/// persisted: name, index, image, disk size, workspace association, port
/// forwards and guest variables. Everything that can fail cheaply runs
/// before the disk is replaced; after it, every error says how to finish.
struct Reprovision {
  let lifecycle: ProjectLifecycle
  let name: InstanceName?
  let image: ImageName?
  let yes: Bool
  let noAgents: Bool
  let noPrompt: Bool
  let configTarget: ConfigTarget

  var context: CommandContext { lifecycle.context }

  func run() throws {
    let instance = try InstanceStore.resolve(lifecycle.config, name: name)
    let image = self.image ?? instance.image
    guard lifecycle.backend.imageIsBuilt(image) else {
      throw HostError("No image '\(image)' found. Run `coop images` to list available images.")
    }
    let workspace = try WorkspaceState.load(instance)
    let savedForwards = try PortForwards.load(instance) ?? []
    let savedEnvironment = try GuestEnvState.tryLoad(instance)?.entries ?? [:]
    let applied = try DevcontainerState.load(instance)?.applied
    try Self.checkWorkspaceSource(instance.name, workspace)
    DevcontainerState.warnIfChanged(instance, diagnostics: lifecycle.diagnostics)
    var options = StartOptions(
      name: instance.name, noAgents: noAgents, noPrompt: noPrompt, configTarget: configTarget,
      persistedGuestEnvironment: savedEnvironment, appliedDevcontainer: applied)
    switch workspace?.source {
    case .workspace(let path)?: options.workspaceDirectory = path
    case .gitRepo(let url)?: options.gitRepo = url
    case .mount(let path)?:
      // Revalidated: this path comes from a state file, not the CLI.
      options.mounts = [try Mount(host: path, guest: workspace!.guestPath)]
    case nil: break
    }
    if try !yes && !Prompt.confirm(Self.confirmation(instance.name, image, workspace)) {
      throw HostError(
        "Aborted — instance '\(instance.name)' left untouched.\nPass -y to reprovision without the prompt (required when stdin is not a TTY)."
      )
    }
    // Saved references must resolve before the disk is replaced.
    try GuestEnvState.rejectProviderReferences(savedEnvironment)
    try lifecycle.preflightReferences(savedEnvironment)
    let repo = lifecycle.tokens.instanceRepo(instance)
    try lifecycle.maybePromptForPAT(instance, repo: repo, options)
    let shutdown = Shutdown.install()
    defer { shutdown.restore() }
    try Stop.stop(context, instance)
    // After the teardown: the instance's own forwarder held these ports.
    let forwardSet = PortForward.merge(config: lifecycle.config.forwardPorts, cli: savedForwards)
    do { try PortForwards.checkCollisions(forwardSet) } catch {
      throw ContextError(
        "Instance '\(instance.name)' is stopped and was not reprovisioned. Free the host port or drop the conflicting `forward_ports` entry from the config, then re-run `coop restore \(instance.name) --reprovision` — or `coop start \(instance.name)` to bring it back as it was.",
        cause: error)
    }
    let backend = lifecycle.backend
    let stopped = try backend.asStopped(instance)
    // An image disk is template-sized; re-grow to what the instance had.
    let previousDisk = try backend.currentDiskGiB(stopped)
    try Shutdown.check()
    try backend.restoreDisk(stopped, image: image)
    let partial = Self.partialMessage(instance.name, image, previousDisk)
    do {
      let restored = try instance.withImage(image)
      let current = try backend.currentDiskGiB(try backend.asStopped(restored))
      if previousDisk > current {
        try backend.resizeDisk(try backend.asStopped(restored), toGiB: previousDisk)
      }
      try Shutdown.check()
      lifecycle.foldGuestEnvironment(savedEnvironment)
      try lifecycle.backend.startExisting(restored)
      try lifecycle.provisionFirstBoot(restored, options, repo: repo, forwardSet: forwardSet)
    } catch {
      throw ContextError(partial, cause: error)
    }
    lifecycle.diagnostics.log(.info, "Instance '\(instance.name)' reprovisioned")
  }

  /// A recorded workspace that could not be re-synced is refused while the
  /// guest is still intact.
  static func checkWorkspaceSource(_ name: InstanceName, _ state: WorkspaceState?) throws {
    guard let path = state?.source.hostPath else { return }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw HostError(
        "Instance '\(name)' records workspace \(path), which is not a directory.\nPut it back at that path, or `coop destroy \(name)` and `coop up` from the new location — reprovisioning now would leave the guest with no workspace to sync back.\nNothing re-points an existing instance's recorded workspace: `coop up` matches on the canonical path and would create a second instance, and `coop push --dir` does not persist the new source."
      )
    }
  }

  static func partialMessage(_ name: InstanceName, _ image: ImageName, _ disk: UInt64) -> String {
    "Instance '\(name)' was reset but not fully provisioned. Re-run `coop restore \(name) --image \(image) --reprovision` to finish.\nIts disk was \(disk) GiB before the reset. Nothing persists that, and a re-run measures the replaced (template-sized) disk, so check `coop status \(name)` and run `coop resize \(name) --size \(disk)` if the re-grow did not complete."
  }

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
