import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets

/// Parsed options for project creation or affinity-based reconnection.
package struct UpRequest {
  package var dir: String?
  package var gitRepo: String?
  package var name: InstanceName?
  package var image: ImageName?
  package var transport: ProjectTransport = .copy
  package var newInstance = false
  package var devcontainerInput: DevcontainerInput = .discover
  package var vcpus: UInt8?
  package var mem: VmMemory?
  package var disk: GiB?
  package var postStart: String?
  package var guestEnvironment: [(EnvVarName, EnvValue)] = []
  package var envFile: String?
  package var forwardPort: [PortForward] = []
  package var extraMount: [Mount] = []
  package var excludeGit = false
  package var noAgents = false
  package var noGithub = false
  package var noPrompt = false
  /// `--egress` or `--allow-host` was given; the effective policy is in the
  /// lifecycle's configuration.
  package var egressRequested = false
  /// The subcommand refusal messages name (`up`, `code`, `zed`).
  package var command = "up"
  package let configTarget: ConfigTarget

  package init(configTarget: ConfigTarget) { self.configTarget = configTarget }
}

/// Project-affinity lookup, image preparation and first-boot orchestration.
package struct UpWorkflow {
  package let request: UpRequest
  package let lifecycle: ProjectLifecycle
  package let target: (profiles: [String], image: ImageName)?

  package init(
    request: UpRequest, lifecycle: ProjectLifecycle, target: (profiles: [String], image: ImageName)?
  ) {
    self.request = request
    self.lifecycle = lifecycle
    self.target = target
  }

  package func previewOptions() throws -> DevcontainerOptions {
    if let url = request.gitRepo {
      return options(dryRun: true, workspace: nil, mounts: [], gitRepo: url)
    }
    let directory = try Self.projectDirectory(request.dir)
    let mounts = transport == .mount ? [try Mount(host: directory, guest: guestWorkspace)] : []
    return options(dryRun: true, workspace: directory, mounts: mounts, gitRepo: nil)
  }

  package var context: CommandContext { lifecycle.context }
  package var diagnostics: Diagnostics { lifecycle.diagnostics }
  package var transport: ProjectTransport { request.transport }
  package var effectiveImage: ImageName { target?.image ?? request.image ?? .default }
  package var input: DevcontainerInput { request.devcontainerInput }

  package func translatorInputs() -> DevcontainerTranslatorInputs {
    DevcontainerTranslatorInputs(
      cliVcpus: request.vcpus, cliMemory: request.mem, cliDisk: request.disk,
      cliPostStart: request.postStart, cliGuestEnvKeys: request.guestEnvironment.map(\.0),
      cliForwardPorts: request.forwardPort, cliMounts: request.extraMount,
      cliProfiles: target?.profiles ?? [],
      persistedGuestUser: Devcontainer.persistedGuestUser(lifecycle.config, image: effectiveImage),
      cliWorkspaceOrGitRepo: true)
  }

  package var resolver: DevcontainerResolver {
    DevcontainerResolver(environment: context.environment.variables, diagnostics: diagnostics)
  }

  package func options(dryRun: Bool, workspace: String?, mounts: [Mount], gitRepo: String?)
    -> DevcontainerOptions
  {
    DevcontainerOptions(
      input: input, dryRun: dryRun, workspace: workspace, mounts: mounts, gitRepo: gitRepo,
      githubAuth: lifecycle.config.github,
      preferencePath: Devcontainer.preferencesPath(lifecycle.config))
  }

  @discardableResult
  package func run() throws -> UpOutcome {
    if let url = request.gitRepo { return try runGitRepo(url) }
    let projectDirectory = try Self.projectDirectory(request.dir)
    let projectMount = try Mount(host: projectDirectory, guest: guestWorkspace)
    let discoveryMounts = transport == .mount ? [projectMount] : []
    if !request.newInstance,
      let instance = try lifecycle.workspaceInstance(
        projectDirectory,
        context: { path, names in
          "Multiple instances share workspace \(path):\n  \(names)\nPick one explicitly with `iso start <name>` (for a stopped\ninstance) or `iso claude <name>` (for a running one)."
        })
    {
      if let name = request.name, instance.name != name {
        throw HostFailure(
          .projectAlreadyAssociated(instance.name),
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
        return UpOutcome(action: .reused, instance: instance)
      }
      try restart(instance)
      return UpOutcome(action: .started, instance: instance)
    }
    try ensureProfileImage()
    return UpOutcome(
      action: .created,
      instance: try create(
        projectDirectory: projectDirectory, projectMount: projectMount, discovery: discoveryMounts))
  }

  package func runGitRepo(_ url: String) throws -> UpOutcome {
    if !request.newInstance, let instance = try lifecycle.gitRepoInstance(url) {
      if let name = request.name, instance.name != name {
        throw HostFailure(
          .projectAlreadyAssociated(instance.name),
          "Git repo \(url) is already associated with instance '\(instance.name)', not '\(name)'.")
      }
      try ensureExistingCompatible(instance, subject: "this git repo")
      if lifecycle.backend.isRunning(instance) {
        try rejectRestartOnlyInputs(instance)
        diagnostics.log(.info, "Instance '\(instance.name)' is already running for \(url)")
        return UpOutcome(action: .reused, instance: instance)
      }
      try restart(instance)
      return UpOutcome(action: .started, instance: instance)
    }
    try ensureProfileImage()
    return UpOutcome(action: .created, instance: try createFromGitRepo(url))
  }

  package static func projectDirectory(_ dir: String?) throws -> String {
    try ProjectDirectory.resolve(dir)
  }

  package func ensureExistingCompatible(_ instance: Instance, subject: String) throws {
    if let image = request.image, instance.image != image {
      throw HostFailure(
        .instanceIncompatible(instance.name),
        "Instance '\(instance.name)' already exists for \(subject) using image '\(instance.image)'. `iso \(request.command) --image \(image)` only applies when creating a new instance.\nUse `iso destroy \(instance.name)` first to recreate it with a different image."
      )
    }
    if let target, instance.image != target.image {
      throw HostFailure(
        .instanceIncompatible(instance.name),
        "Instance '\(instance.name)' already exists for \(subject) using image '\(instance.image)'. `iso \(request.command) --profile \(target.profiles.joined(separator: ","))` would use image '\(target.image)', but profiles only apply when creating a new instance.\nUse `iso destroy \(instance.name)` first to recreate it with those profiles."
      )
    }
    let explicitDevcontainer = if case .explicit = input { true } else { false }
    let isProject = subject == "this project"
    if request.disk != nil || request.vcpus != nil || request.mem != nil
      || !request.extraMount.isEmpty || (isProject && request.excludeGit) || explicitDevcontainer
    {
      let flags =
        isProject
        ? "--vcpus, --mem, --disk, --extra-mount, --exclude-git, and --devcontainer only apply"
        : "--vcpus, --mem, --disk, --extra-mount, and --devcontainer only apply"
      throw HostFailure(
        .instanceIncompatible(instance.name),
        "Instance '\(instance.name)' already exists for \(subject). \(flags) when creating a new instance.\nTo change memory, vCPUs, or disk on the existing instance, stop it and run `iso resize`. Otherwise `iso destroy \(instance.name)` first to recreate it with those options."
      )
    }
  }

  package func ensureSameTransport(_ instance: Instance) throws {
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
      throw HostFailure(
        .instanceIncompatible(instance.name),
        "Instance '\(instance.name)' already exists for this project using \(existing.rawValue) transport, but this command requested \(transport.rawValue).\nRe-run with the original transport, or `iso destroy \(instance.name)` first to recreate it."
      )
    }
  }

  package func rejectRestartOnlyInputs(_ instance: Instance) throws {
    if request.noAgents || request.noGithub || !request.forwardPort.isEmpty
      || request.postStart != nil || !request.guestEnvironment.isEmpty || request.envFile != nil
    {
      throw HostFailure(
        .instanceIncompatible(instance.name),
        "Instance '\(instance.name)' is already running for this project. --no-agents, --no-github, --forward-port, --post-start, --env, and --env-file only take effect during start or restart.\nRun `iso stop \(instance.name)` first, then repeat `iso \(request.command)` with those options."
      )
    }
    try rejectEgressChange(instance)
  }

  /// A running instance keeps the egress policy it booted with; a different
  /// requested mode or allowlist, or a policy record that cannot be read, is
  /// refused rather than silently ignored. The comparison is the running-guest
  /// handoff's own (`NetworkPolicy.enforce`). Without a request, the handoff
  /// checks the configured policy later.
  package func rejectEgressChange(_ instance: Instance) throws {
    guard request.egressRequested else { return }
    do {
      try NetworkPolicy.enforce(instance, config: lifecycle.config)
    } catch {
      throw HostFailure(
        .instanceIncompatible(instance.name),
        "Instance '\(instance.name)' is already running, and its boot egress policy does not match the requested --egress / --allow-host: \(error)\n--egress and --allow-host only take effect when an instance starts. Run `iso stop \(instance.name)` first to apply a new allowlist, or `iso destroy \(instance.name)` to change the egress mode."
      )
    }
  }

  package func bootOptions() throws -> BootOptions {
    BootOptions(
      noAgents: request.noAgents, noPrompt: request.noPrompt, forwardPorts: request.forwardPort,
      configTarget: request.configTarget,
      postStartOverride: request.postStart)
  }

  package func restart(_ instance: Instance) throws {
    var options = RestartRequest(boot: try bootOptions())
    options.boot.persistedGuestEnvironment = try lifecycle.mergeRuntimeGuestEnvironment(
      cli: request.guestEnvironment, envFile: request.envFile, devcontainer: nil)
    try lifecycle.restart(instance, options)
  }

  package func ensureProfileImage() throws {
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
  package func creationOptions(
    _ translation: DevcontainerTranslation?, rule: WorkspaceMountRule, leading: [Mount]
  )
    throws -> CreationRequest
  {
    try lifecycle.applyVMOverrides(vcpus: request.vcpus, memory: request.mem)
    if let translation { try lifecycle.apply(translation) }
    var options = CreationRequest(boot: try bootOptions())
    if let translation {
      options.boot.forwardPorts = Devcontainer.mergeIntoForwardPorts(
        config: translation.forwardPorts, translation: request.forwardPort)
    }
    options.boot.persistedGuestEnvironment = try lifecycle.mergeRuntimeGuestEnvironment(
      cli: request.guestEnvironment, envFile: request.envFile,
      devcontainer: translation?.guestEnvironment)
    options.disk = Devcontainer.effectiveDisk(
      cli: request.disk, translation ?? DevcontainerTranslation())
    options.boot.postStartOverride = request.postStart ?? translation?.postStart
    options.mounts =
      try ValidatedMounts(rule, leading + (translation?.mounts ?? []) + request.extraMount).mounts
    options.excludeGit = request.excludeGit
    options.appliedDevcontainer = translation?.applied
    return options
  }

  package func create(projectDirectory: String, projectMount: Mount, discovery: [Mount]) throws
    -> Instance
  {
    let translation = try resolver.resolve(
      options(dryRun: false, workspace: projectDirectory, mounts: discovery, gitRepo: nil),
      inputs: translatorInputs(), stage: .start)
    var options: CreationRequest
    switch transport {
    case .copy:
      options = try creationOptions(translation, rule: .copyProject, leading: [])
      options.workspaceDirectory = projectDirectory
    case .mount:
      options = try creationOptions(
        translation, rule: .projectMountedOrNone, leading: [projectMount])
    }
    return try lifecycle.allocateAndStart(
      name: request.name, image: effectiveImage, workspacePath: projectDirectory, options)
  }

  package func createFromGitRepo(_ url: String) throws -> Instance {
    let translation = try resolver.resolve(
      options(dryRun: false, workspace: nil, mounts: [], gitRepo: url), inputs: translatorInputs(),
      stage: .start)
    var options = try creationOptions(translation, rule: .gitRepoClone, leading: [])
    options.gitRepo = url
    return try lifecycle.allocateAndStart(
      name: request.name ?? GitRepoURL.defaultInstanceName(url), image: effectiveImage,
      workspacePath: nil, options)
  }
}

package enum ProjectTransport: String {
  case copy
  case mount
}
