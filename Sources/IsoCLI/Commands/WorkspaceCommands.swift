// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

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
  @Option(
    help: "Local directory to push (defaults to `workspace.json` `host_path`)")
  var dir: String?
  @Flag(help: "Overwrite guest changes without confirmation") var force = false
  @Flag(help: ArgumentHelp(DeprecatedExcludeGit.help)) var excludeGit = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      DeprecatedExcludeGit.warn(excludeGit, context.diagnostics)
      try context.transfer.push(
        running, directory: dir, force: force, input: context.config.workspaceInput)
    }
  }
}

struct Pull: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Pull guest workspace to local directory",
    discussion:
      "Every pull is received into a host-side stage and validated before anything reaches the local directory; host Git never runs. With `workspace.pull.mode = \"stage\"` (or --review) the stage is printed for review and applied with `--apply --stage-id ID`. In direct mode a plan of additions applies at once; replacing files needs --force, and execution-sensitive paths (.envrc, .husky, .vscode/tasks.json) always need --apply --stage-id ID --approve-sensitive PATH. `.git` is never installed."
  )

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(
    help: "Local directory to pull into (defaults to `workspace.json` `host_path`)")
  var dir: String?
  @Flag(help: "In direct mode, allow replacing existing local files (never sensitive paths)")
  var force = false
  @Flag(help: ArgumentHelp(DeprecatedExcludeGit.help)) var excludeGit = false
  @Flag(help: "Stage the pull and print it for review without applying it") var review = false
  @Flag(help: "Apply the reviewed stage named by --stage-id to the local directory")
  var apply = false
  @Flag(help: "Delete the current stage") var discard = false
  @Option(
    help: "With --apply, the stage id shown at review; required, refuses any other stage")
  var stageId: String?
  @Option(
    help: ArgumentHelp(
      "With --apply --stage-id, approve one execution-sensitive entry shown at review (repeatable; exact path, no globs)",
      valueName: "PATH"))
  var approveSensitive: [String] = []
  @Flag(help: "When reviewing, print only the summary, not text diffs") var stat = false

  /// Whether a plain pull (not --apply / --discard) only stages.
  static func stages(review: Bool, mode: WorkspacePullMode) -> Bool {
    review || mode == .stage
  }

  func validate() throws {
    if [review, apply, discard].filter({ $0 }).count > 1 {
      throw UsageError("--review, --apply and --discard cannot be combined")
    }
    if stageId != nil && !apply { throw UsageError("--stage-id requires --apply") }
    if !approveSensitive.isEmpty && (!apply || stageId == nil) {
      throw UsageError("--approve-sensitive requires --apply --stage-id")
    }
    if dir != nil && (apply || discard) {
      throw UsageError(
        "--dir is fixed when the stage is created; it cannot be used with --\(apply ? "apply" : "discard")"
      )
    }
    if stat && (apply || discard) { throw UsageError("--stat applies only to a review") }
  }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      DeprecatedExcludeGit.warn(excludeGit, context.diagnostics)
      if discard {
        let instance = try InstanceStore.resolve(context.config, name: name)
        let removed = try context.transfer.discardStage(instance)
        context.diagnostics.log(
          .info, removed ? "Discarded the stage of '\(instance.name)'" : "No stage to discard")
        return
      }
      if apply {
        let instance = try InstanceStore.resolve(context.config, name: name)
        guard let stageId else {
          let selected = try? StageLocation(instance).loadSelectedLocked()
          throw UsageError(
            selected.map {
              "--apply needs the exact stage id. The selected stage is \($0.manifest.id): \(StageReview($0).applyCommand(instance: instance.name.rawValue))"
            } ?? "--apply needs --stage-id; create and review a stage with `iso diff` first")
        }
        // --force adds nothing here: the exact stage id is the overwrite
        // authority, and it never stands in for a policy approval or a
        // sensitive-path grant.
        if force {
          context.diagnostics.warn(
            "--force has no effect with --apply: the stage id is the overwrite authority")
        }
        let (manifest, applied) = try context.transfer.applyStage(
          instance,
          WorkspaceTransfer.ApplyRequest(
            stageID: stageId, replace: true, sensitive: approveSensitive),
          configuredPolicy: context.config.policy,
          confirm: TerminalStageConfirmation.make(global: global, instance: instance))
        context.diagnostics.log(
          .info,
          "Applied \(applied.count) changes from stage \(manifest.id) to \(neutralizeControls(manifest.destination))"
        )
        return
      }
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      guard Self.stages(review: review, mode: context.config.workspacePull.mode) else {
        if stat { throw UsageError("--stat requires --review or workspace.pull.mode \"stage\"") }
        do {
          let (manifest, applied) = try context.transfer.pull(
            running, directory: dir, force: force, limits: context.config.workspacePull.limits,
            configuredPolicy: context.config.policy)
          context.diagnostics.log(
            .info,
            "Applied \(applied.count) changes to \(neutralizeControls(manifest.destination))")
        } catch let held as ReturnError where held.stageID != nil {
          // The whole stage is kept: show it so it can be reviewed and
          // applied with the exact authority it needs.
          if let selected = try? StageLocation(running.instance).loadSelected(),
            selected.manifest.id == held.stageID
          {
            context.printStage(selected, instance: running.instance, diffs: false)
          }
          throw held
        }
        return
      }
      try context.reviewStage(running, directory: dir, diffs: !stat)
    }
  }
}

struct Diff: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Stage the guest workspace and show what `iso pull --apply` would change")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(
    help: "Local directory to compare with (defaults to `workspace.json` `host_path`)")
  var dir: String?
  @Flag(help: ArgumentHelp(DeprecatedExcludeGit.help)) var excludeGit = false
  @Flag(help: "Print only the summary, not text diffs") var stat = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      DeprecatedExcludeGit.warn(excludeGit, context.diagnostics)
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      try context.reviewStage(running, directory: dir, diffs: !stat)
    }
  }
}

extension CommandContext {
  /// A staged `pull` (`--review` or `workspace.pull.mode "stage"`) and `diff`:
  /// stage the running guest's workspace, then print it for review. Applying
  /// and discarding stay separate operations.
  func reviewStage(_ running: AppleBackend.Running, directory: String?, diffs: Bool) throws {
    _ = try transfer.stage(
      running, directory: directory, limits: config.workspacePull.limits,
      configuredPolicy: config.policy)
    let selected = try StageLocation(running.instance).loadSelectedLocked()
    printStage(selected, instance: running.instance, diffs: diffs)
  }

  /// The review goes to stdout; the next-step hint to stderr.
  func printStage(_ selected: SelectedStage, instance: Instance, diffs: Bool) {
    let manifest = selected.manifest
    let review = StageReview(selected)
    review.summary(instance: instance.name.rawValue).forEach(output.out)
    if diffs { review.textDiffs().forEach(output.out) }
    if !manifest.applicable {
      output.error("Discard it with `iso pull \(instance.name) --discard`.")
    } else if manifest.changes.isEmpty {
      output.error("Nothing to apply.")
    } else {
      output.error(
        "Apply it with `\(review.applyCommand(instance: instance.name.rawValue))`, or discard it with `--discard`."
      )
    }
  }
}

struct SSHConfigCommand: MachineCommand {
  static let configuration = CommandConfiguration(
    commandName: "ssh-config",
    abstract: "Install a `iso-<name>` SSH alias for ad-hoc ssh/scp/rsync")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Remove the SSH config entry for this instance and exit") var clean = false

  func run() throws {
    try IsoCLI.run(global, Self.self) {
      let context = try CommandContext.load(global)
      if clean {
        let instance = try InstanceStore.resolve(context.config, name: name)
        try context.sshConfigFile().remove(instance)
        context.diagnostics.log(.info, "Removed SSH config for '\(instance.name)'")
        return MachineSSHConfigResult(
          instance: .removed(name: instance.name.rawValue), connection: nil)
      }
      // The same running proof, isolation check and pinned-key block either
      // way; machine mode only skips the human usage text.
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      let file = try context.sshConfigFile()
      let alias =
        global.output == .json
        ? try file.update(running.target, running.instance)
        : try file.install(running, stderr: context.output.error)
      return MachineSSHConfigResult(
        instance: .running(MachineInstance(running.instance, .running)),
        connection: MachineConnection(alias))
    }
  }
}

struct Editor: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Open an editor (VS Code or Zed) connected to the guest VM",
    discussion:
      "Opens an instance that is already running, trying VS Code and then Zed unless --editor names one. `iso code` and `iso zed` instead create, restart or reuse the project's instance as `iso up` does and open only that editor."
  )

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(
    name: [.customLong("guest-path"), .customLong("project")],
    help: "Guest path to open in the editor (inside the VM, never a host path)")
  var guestPath = "/workspace"
  @Option(help: "Editor to launch. Omitted: try VS Code first, then Zed")
  var editor: EditorProviderID?
  @Flag(help: "Remove the SSH config entry for this instance and exit") var clean = false
  @OptionGroup var securityOptions: EditorSecurityOptions

  func validate() throws { _ = try parseGuestPath(guestPath) }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      if clean {
        let instance = try InstanceStore.resolve(context.config, name: name)
        try context.sshConfigFile().remove(instance)
        context.diagnostics.log(.info, "Removed SSH config for '\(instance.name)'")
        return
      }
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      let path = try parseGuestPath(guestPath)
      try context.sshConfigFile().install(running, stderr: context.output.error)
      try EditorLauncher(
        environment: context.environment.variables, diagnostics: context.diagnostics,
        security: securityOptions.resolve(context.config.editor), home: context.environment.home
      )
      .launch(
        running, SSHConnectionTarget(running, guestPath: path, egress: context.config.egress),
        choice: editor.map { .only($0.provider) }
          ?? .firstAvailable(EditorProviderID.allCases.map(\.provider)),
        revalidate: context.backend.editorProof(running))
    }
  }
}
