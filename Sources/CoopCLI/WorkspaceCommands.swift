// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

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
    abstract: "Pull guest workspace to local directory")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Option(help: "Local directory to pull into (defaults to `workspace.json` `host_path`)")
  var dir: String?
  @Flag(help: "Overwrite local changes without confirmation") var force = false
  @Flag(help: "Skip the `.git` directory in this transfer") var excludeGit = false

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
      try context.transfer.pull(running, directory: dir, force: force, excludeGit: excludeGit)
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
