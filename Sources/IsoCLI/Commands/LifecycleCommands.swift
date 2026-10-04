// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

typealias UsageError = ArgumentParser.ValidationError

// MARK: - setup

struct Setup: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Create the configuration file and prepare the machine image")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Only create the JSONC configuration template, then exit") var configOnly = false
  @Flag(name: .shortAndLong, help: "Skip confirmation prompts (accept all)") var yes = false
  @Option(help: "Number of vCPUs (overrides config)") var vcpus: UInt8?
  @Option(help: "Memory in MiB (overrides config)", transform: parseMemory) var mem: VmMemory?
  @Flag(help: "Force rebuild of the machine image") var rebuild = false
  @Option(
    help: "Install profiles (comma-separated: python,node,c,fuzz,rust,go)", transform: splitCommas)
  var profile: [[String]] = []
  @Option(help: "Extra apt packages (not used by the Apple backend)", transform: splitCommas)
  var extraPackages: [[String]] = []
  @Option(help: "Post-install script (not used by the Apple backend)") var postInstall: String?
  @Option(help: "Template disk size in GiB (default: 8)", transform: parseGiB) var templateSize:
    GiB?
  @Option(help: "Named image to build", transform: parseImageName) var image: ImageName = .default
  @Option(
    help: ArgumentHelp(
      "Guest username to create in the image (default: \"ubuntu\")", valueName: "NAME"),
    transform: parseGuestUser) var guestUser: GuestUser?
  @Option(
    help: ArgumentHelp(
      "Build deadline: seconds, or an s/m/h suffix (e.g. 90s, 30m, 2h)", valueName: "DURATION"),
    transform: parseDurationArgument) var builderTimeout: Duration?
  @Option(help: "Workspace directory to scan for .devcontainer/devcontainer.json") var workspace:
    String?
  @Option(help: ArgumentHelp("Explicit path to a devcontainer.json", valueName: "PATH"))
  var devcontainer: String?
  @Flag(help: "Ignore any discovered devcontainer.json") var noDevcontainer = false
  @Flag(help: "Translate devcontainer.json and print the report, then exit") var dryRun = false

  func validate() throws {
    if devcontainer != nil && noDevcontainer {
      throw UsageError("--devcontainer cannot be used with --no-devcontainer")
    }
    if configOnly {
      let imageFlags =
        yes || vcpus != nil || mem != nil || rebuild || !profile.isEmpty || !extraPackages.isEmpty
        || postInstall != nil || templateSize != nil || image != .default || guestUser != nil
        || builderTimeout != nil || workspace != nil || devcontainer != nil || noDevcontainer
        || dryRun
      if imageFlags {
        throw UsageError(
          "--config-only only creates the configuration file; image options cannot be combined with it"
        )
      }
    }
  }

  func run() throws {
    try IsoCLI.run {
      if configOnly {
        let environment = ConfigEnvironment.process
        let target = try global.writableTarget(environment: environment)
        try SetupConfigOnly.run(target.path, format: target.format, output: StandardStreams())
        return
      }
      let context = try CommandContext.load(global) {
        $0.overridingVM(vcpus: vcpus, memory: mem, templateSize: templateSize)
      }
      if vcpus == 0 { throw HostError("--vcpus must be > 0") }
      for warning in try context.config.validated() { context.diagnostics.warn(warning) }
      var names = profile.flatMap { $0 }
      let translation = try DevcontainerResolver(
        environment: context.environment.variables, diagnostics: context.diagnostics
      ).resolve(
        DevcontainerOptions(
          input: .fromFlags(path: devcontainer, noDevcontainer: noDevcontainer), dryRun: dryRun,
          workspace: workspace, githubAuth: context.config.github,
          preferencePath: Devcontainer.preferencesPath(context.config)),
        inputs: DevcontainerTranslatorInputs(
          cliVcpus: vcpus, cliMemory: mem, cliProfiles: names, cliGuestUser: guestUser),
        stage: .setup)
      if dryRun { return }
      if !extraPackages.isEmpty || postInstall != nil {
        context.diagnostics.warn(
          "--extra-packages and --post-install are not used by the Apple backend; ignoring them")
      }
      var backend = context.backend
      var config = context.config
      if let translation {
        for name in translation.profiles where !names.contains(name) { names.append(name) }
        config = try Devcontainer.applyToConfig(config, translation)
        backend = AppleBackend(
          config: config, environment: context.environment.variables,
          executable: CommandLine.executablePath, diagnostics: context.diagnostics)
      }
      let definitions = try resolveProfiles(names, config)
      let shutdown = Shutdown.install()
      defer { shutdown.restore() }
      try backend.setup(
        SetupOptions(
          rebuild: rebuild, profiles: definitions, image: image,
          guestUser: guestUser ?? translation?.guestUser ?? .default,
          builderTimeout: builderTimeout, ociFeatures: translation?.ociFeatures ?? []))
    }
  }
}

func splitCommas(_ text: String) -> [String] {
  text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
}

func parseMemory(_ text: String) throws -> VmMemory {
  do { return try VmMemory.parseCLI(text) } catch { throw UsageError("\(error)") }
}

func parseGiB(_ text: String) throws -> GiB {
  do { return try GiB.parseCLI(text) } catch { throw UsageError("\(error)") }
}

func parseImageName(_ text: String) throws -> ImageName {
  do { return try ImageName(text) } catch { throw UsageError("\(error)") }
}

func parseGuestUser(_ text: String) throws -> GuestUser {
  do { return try GuestUser(text) } catch { throw UsageError("\(error)") }
}

func parseDiskSize(_ text: String) throws -> DiskSize {
  do { return try DiskSize.parse(text) } catch { throw UsageError("\(error)") }
}

/// Plain seconds or an `s`/`m`/`h` suffix, greater than zero.
func parseDurationArgument(_ text: String) throws -> Duration {
  let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty else { throw UsageError("duration cannot be empty") }
  let seconds: UInt64
  switch DurationText(parsing: value) {
  case .invalid:
    throw UsageError("invalid duration \(debugQuoted(value)); use seconds, or suffix s/m/h")
  case .overflow:
    throw UsageError("duration \(debugQuoted(value)) is too large")
  case .seconds(let parsed): seconds = parsed
  }
  guard seconds <= UInt64(Int64.max) else {
    throw UsageError("duration \(debugQuoted(value)) is too large")
  }
  guard seconds > 0 else { throw UsageError("duration must be greater than zero") }
  return .seconds(Int64(seconds))
}

// MARK: - stop

struct Stop: MachineCommand {
  static let configuration = CommandConfiguration(abstract: "Gracefully stop the VM")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?

  func run() throws {
    try IsoCLI.run(global, Self.self) {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      let action = try ProjectLifecycle(context, noGitHub: false).stop(instance)
      return MachineLifecycleResult(action, instance, state: .stopped)
    }
  }
}

// MARK: - destroy

struct Destroy: MachineCommand {
  static let configuration = CommandConfiguration(
    abstract: "Stop and clean up instance resources (keeps images)")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Also remove every image and the VM access key") var all = false

  func run() throws {
    try IsoCLI.run(global, Self.self) { () -> MachineDestroyResult in
      let context = try CommandContext.load(global)
      let shutdown = Shutdown.install()
      defer { shutdown.restore() }
      if all {
        var destroyed: [MachineRemovedInstance] = []
        do {
          for instance in try context.listInstances() {
            try destroy(context, instance)
            destroyed.append(MachineRemovedInstance(instance))
          }
        } catch  where !destroyed.isEmpty {
          throw PartialDestroy(destroyed: destroyed, cause: error)
        }
        context.backend.destroyShared()
        for suffix in ["", ".pub"] {
          try? FileManager.default.removeItem(atPath: context.config.sshKeyPath.path + suffix)
        }
        try? FileManager.default.removeItem(atPath: context.config.instancesDirectory.path)
        try context.sshConfigFile().removeAll()
        context.diagnostics.log(.info, "All resources cleaned up")
        return .all(destroyed)
      }
      let instance = try InstanceStore.resolve(context.config, name: name)
      try destroy(context, instance)
      return .one(MachineRemovedInstance(instance))
    }
  }

  func destroy(_ context: CommandContext, _ instance: Instance) throws {
    context.diagnostics.log(.info, "Destroying instance '\(instance.name)'")
    context.teardownForwards(instance)
    context.agents.proxies.stopAll(instance)
    try context.backend.destroyInstance(instance)
    try context.sshConfigFile().remove(instance)
    context.diagnostics.log(.info, "Instance '\(instance.name)' destroyed")
  }
}

// MARK: - resize

struct Resize: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Resize a stopped instance's disk, memory, or vCPU count")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(
    help: "New disk size: absolute GiB (e.g. 150, 150G) or relative (e.g. +20, +20G)",
    transform: parseDiskSize)
  var size: DiskSize?
  @Option(help: "New memory in MiB (minimum 128)", transform: parseMemory) var mem: VmMemory?
  @Option(help: "New vCPU count") var vcpus: UInt8?
  @Flag(help: "Start the instance after applying the change instead of leaving it stopped")
  var start = false

  func validate() throws {
    if size == nil && mem == nil && vcpus == nil {
      throw UsageError("at least one of --size, --mem or --vcpus is required")
    }
    if vcpus == 0 { throw UsageError("--vcpus must be > 0") }
  }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      let stopped = try context.backend.asStopped(instance)
      if let size {
        let current = try context.backend.currentDiskGiB(stopped)
        let newSize: GiB
        do { newSize = try size.resolve(current: GiB(UInt32(clamping: current))!) } catch {
          throw HostError("\(error)")
        }
        try context.backend.resizeDisk(stopped, toGiB: UInt64(newSize.value))
      }
      if mem != nil || vcpus != nil {
        try context.backend.setMachineResources(
          stopped, memoryMiB: mem?.mib.value, vcpus: vcpus, startAfter: start)
      } else if start {
        try context.backend.startExisting(instance)
      }
    }
  }
}

// MARK: - commit

struct Commit: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Save a stopped instance's filesystem as a reusable image")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(help: "Name of the image to create", transform: parseImageName) var image: ImageName
  @Flag(help: "Overwrite an existing image with the same name") var force = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      if context.backend.imageIsBuilt(image) && !force {
        throw HostError("Image '\(image)' already exists. Pass --force to overwrite it.")
      }
      let stopped = try context.backend.asStopped(instance)
      let template = try TemplateStore.load(context.config, instance.image)
      try context.backend.commitDisk(stopped, image: image)
      try TemplateStore.save(
        template, recreatedAt: utcTimestamp(), config: context.config, image: image)
      context.diagnostics.log(
        .info,
        "Committed instance '\(instance.name)' to image '\(image)'. Relaunch with `iso up --image \(image)`."
      )
    }
  }
}

// MARK: - restore

struct Restore: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Replace an instance's filesystem with an image's, in place",
    discussion: """
      Keeps the name, index, IP and workspace association; only the disk changes. On the Apple sandbox backend the next start pins a new host key, and the address can change if the sandbox's subnet was quarantined.

      Needs a stopped instance, and leaves it stopped: the `iso commit` loop.

      --reprovision instead runs the first-boot path and leaves it running.

      It also accepts a running instance, stopping it itself.

      Use it for a base image, where `iso start` leaves /workspace empty.

      See docs/commands.md for what --reprovision does not replay.
      """)

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(
    help: "Image to restore from (--reprovision defaults to the recorded one)",
    transform: parseImageName)
  var image: ImageName?
  @Flag(help: "Provision the new disk as a first boot and leave the instance running")
  var reprovision = false
  @Flag(
    name: .shortAndLong, help: "Skip the --reprovision confirmation prompt (required off a TTY)")
  var yes = false
  @Flag(
    name: .customLong("no-agents"),
    help: "Skip injecting Claude Code and Codex credentials/config into the VM")
  var noAgents = false
  @Flag(help: "Suppress the interactive prompt to set up a scoped GitHub PAT") var noPrompt = false

  func validate() throws {
    if !reprovision {
      if image == nil {
        throw UsageError("the following required arguments were not provided:\n  --image <IMAGE>")
      }
      for (set, flag) in [(yes, "--yes"), (noAgents, "--no-agents"), (noPrompt, "--no-prompt")]
      where set {
        throw UsageError(
          "the following required arguments were not provided:\n  --reprovision\n(\(flag) requires it)"
        )
      }
    }
  }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      if reprovision {
        try ReprovisionWorkflow(
          lifecycle: ProjectLifecycle(context, noGitHub: false), name: name, image: image,
          noAgents: noAgents, noPrompt: noPrompt,
          configTarget: try global.configTarget(context.environment)
        ).run { name, image, workspace in
          try yes || Prompt.confirm(ReprovisionWorkflow.confirmation(name, image, workspace))
        }
        return
      }
      guard let image else { throw UsageError("`--image` is required without `--reprovision`") }
      let instance = try InstanceStore.resolve(context.config, name: name)
      guard context.backend.imageIsBuilt(image) else {
        throw HostError("No image '\(image)' found. Run `iso images` to list available images.")
      }
      let stopped = try context.backend.asStopped(instance)
      try context.backend.restoreDisk(stopped, image: image)
      _ = try instance.withImage(image)
      context.diagnostics.log(
        .info,
        "Restored instance '\(instance.name)' from image '\(image)'. Run `iso start \(instance.name)` to bring it back up — or, if '\(image)' is a base image rather than a checkpoint, `iso restore \(instance.name) --image \(image) --reprovision` to re-sync /workspace and reinstall plugins."
      )
    }
  }
}
