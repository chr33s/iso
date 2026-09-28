import ArgumentParser
import CoopConfiguration
import CoopCore
import CoopHost
import Foundation

extension CommandContext {
  var transfer: WorkspaceTransfer { WorkspaceTransfer(client: ssh, diagnostics: diagnostics) }

  var forwards: PortForwards { PortForwards(client: ssh, diagnostics: diagnostics) }

  /// Best effort: only a reachable (running, gate-verified) instance has a
  /// forwarder to close.
  func teardownForwards(_ instance: Instance) {
    if let target = try? backend.sshTarget(instance) { forwards.teardown(instance, target) }
  }

  func sshConfigFile() throws -> SSHConfigFile {
    try SSHConfigFile.forHome(environment.home, diagnostics: diagnostics)
  }
}

struct Push: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Push local workspace into the running VM")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(help: "Local directory to push (defaults to `workspace.json` `host_path`)")
  var dir: String?
  @Flag(help: "Overwrite guest changes without confirmation") var force = false
  @Flag(help: "Skip the `.git` directory in this transfer") var excludeGit = false

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      try context.transfer.push(running, directory: dir, force: force, excludeGit: excludeGit)
    }
  }
}

struct Pull: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Pull guest workspace to local directory",
    discussion:
      "With `workspace.pull.mode = \"stage\"` (or --review), the pull lands in a host-side stage and is printed for review; nothing reaches the local directory until `--apply`."
  )

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(help: "Local directory to pull into (defaults to `workspace.json` `host_path`)")
  var dir: String?
  @Flag(help: "Overwrite local changes without confirmation") var force = false
  @Flag(help: "Skip the `.git` directory in this transfer") var excludeGit = false
  @Flag(help: "Stage the pull and print it for review without applying it") var review = false
  @Flag(help: "Apply the reviewed stage to the local directory") var apply = false
  @Flag(help: "Delete the current stage") var discard = false
  @Option(help: "With --apply, the stage id shown at review; refuses any other stage")
  var stageId: String?
  @Flag(help: "When reviewing, print only the summary, not text diffs") var stat = false

  /// Whether a plain pull (not --apply / --discard) goes through a stage.
  static func stages(review: Bool, mode: WorkspacePullMode) -> Bool {
    review || mode == .stage
  }

  func validate() throws {
    if [review, apply, discard].filter({ $0 }).count > 1 {
      throw UsageError("--review, --apply and --discard cannot be combined")
    }
    if stageId != nil && !apply { throw UsageError("--stage-id requires --apply") }
    if dir != nil && (apply || discard) {
      throw UsageError(
        "--dir is fixed when the stage is created; it cannot be used with --\(apply ? "apply" : "discard")"
      )
    }
    if stat && (apply || discard) { throw UsageError("--stat applies only to a review") }
  }

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      if discard {
        let instance = try InstanceStore.resolve(context.config, name: name)
        let removed = try context.transfer.discardStage(instance)
        context.diagnostics.log(
          .info, removed ? "Discarded the stage of '\(instance.name)'" : "No stage to discard")
        return
      }
      if apply {
        let instance = try InstanceStore.resolve(context.config, name: name)
        let (manifest, applied) = try context.transfer.applyStage(
          instance, stageID: stageId, force: force)
        context.diagnostics.log(
          .info,
          "Applied \(applied.count) changes from stage \(manifest.id) to \(neutralizeControls(manifest.destination))"
        )
        return
      }
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      guard Self.stages(review: review, mode: context.config.workspacePull.mode) else {
        if stat { throw UsageError("--stat requires --review or workspace.pull.mode \"stage\"") }
        try context.transfer.pull(running, directory: dir, force: force, excludeGit: excludeGit)
        return
      }
      let manifest = try context.transfer.stage(
        running, directory: dir, excludeGit: excludeGit, limits: context.config.workspacePull.limits
      )
      context.printStage(manifest, instance: running.instance, diffs: !stat)
    }
  }
}

struct Diff: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Stage the guest workspace and show what `coop pull --apply` would change")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(help: "Local directory to compare with (defaults to `workspace.json` `host_path`)")
  var dir: String?
  @Flag(help: "Skip the `.git` directory in this transfer") var excludeGit = false
  @Flag(help: "Print only the summary, not text diffs") var stat = false

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      let manifest = try context.transfer.stage(
        running, directory: dir, excludeGit: excludeGit, limits: context.config.workspacePull.limits
      )
      context.printStage(manifest, instance: running.instance, diffs: !stat)
    }
  }
}

extension CommandContext {
  /// The review goes to stdout; the next-step hint to stderr.
  func printStage(_ manifest: StageManifest, instance: Instance, diffs: Bool) {
    let review = StageReview(manifest: manifest, location: StageLocation(instance))
    review.summary(instance: instance.name.rawValue).forEach(output.out)
    if diffs { review.textDiffs().forEach(output.out) }
    if !manifest.applicable {
      output.error("Discard it with `coop pull \(instance.name) --discard`.")
    } else if manifest.changes.isEmpty {
      output.error("Nothing to apply.")
    } else {
      output.error(
        "Apply it with `coop pull \(instance.name) --apply --stage-id \(manifest.id)`, or discard it with `--discard`."
      )
    }
  }
}

struct SSHConfigCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ssh-config",
    abstract: "Install a `coop-<name>` SSH alias for ad-hoc ssh/scp/rsync")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Remove the SSH config entry for this instance and exit") var clean = false

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      if clean {
        let instance = try InstanceStore.resolve(context.config, name: name)
        try context.sshConfigFile().remove(instance)
        context.diagnostics.log(.info, "Removed SSH config for '\(instance.name)'")
        return
      }
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      try context.sshConfigFile().install(running, stderr: context.output.error)
    }
  }
}

extension EditorKind: ExpressibleByArgument {}

struct Editor: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Open an editor (VS Code or Zed) connected to the guest VM")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(help: "Remote path to open in the editor") var project = "/workspace"
  @Option(help: "Editor to launch. Omitted: try VS Code first, then Zed") var editor: EditorKind?
  @Flag(help: "Remove the SSH config entry for this instance and exit") var clean = false

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      if clean {
        let instance = try InstanceStore.resolve(context.config, name: name)
        try context.sshConfigFile().remove(instance)
        context.diagnostics.log(.info, "Removed SSH config for '\(instance.name)'")
        return
      }
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      let path: GuestPath
      do {
        path = try GuestPath.absolute(project)
      } catch {
        throw ContextError(
          "--project must be an absolute guest path: \(debugQuoted(project))", cause: error)
      }
      try context.sshConfigFile().install(running, stderr: context.output.error)
      try EditorLauncher(
        environment: context.environment.variables, diagnostics: context.diagnostics
      )
      .launch(running.instance, path: path, editor: editor)
    }
  }
}
