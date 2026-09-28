// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoopConfiguration
import CoopCore
import CoopHost
import Foundation

// MARK: - github

struct GitHubCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "github", abstract: "Manage GitHub PAT entries and VM assignments",
    subcommands: [
      GitHubAssignPAT.self, GitHubUnassignPAT.self, GitHubSetupPAT.self, GitHubRotatePAT.self,
      GitHubStatus.self, GitHubForgetPAT.self,
    ])
}

func parseRepoSlug(_ text: String) throws -> RepoSlug {
  do { return try RepoSlug.parseCLI(text) } catch {
    throw ArgumentParser.ValidationError(error.message)
  }
}

extension CommandContext {
  var github: GitHubHost { GitHubHost(environment: environment, diagnostics: diagnostics) }
}

extension GlobalOptions {
  /// The file a GitHub edit writes: the loaded file, or the default JSONC
  /// path when none exists yet.
  func configTarget(_ environment: ConfigEnvironment) throws -> ConfigTarget {
    let target = try writableTarget(environment: environment)
    return ConfigTarget(path: target.path, format: target.format)
  }
}

struct GitHubAssignPAT: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "assign-pat",
    abstract: "Select an existing stored PAT entry for subsequent VM sessions")

  @OptionGroup var global: GlobalOptions
  @Option(help: ArgumentHelp(valueName: "NAME"), transform: parseInstanceName) var vm: InstanceName
  @Option(
    help: ArgumentHelp(
      "Stored entry key, not the workspace or the token's permission scope", valueName: "REPO"),
    transform: parseRepoSlug) var repo: RepoSlug

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: vm)
      try GitHubAssignment(repo: repo).save(context.config, instance)
    }
  }
}

struct GitHubUnassignPAT: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unassign-pat",
    abstract: "Remove only the VM association; keep the shared stored credential")

  @OptionGroup var global: GlobalOptions
  @Option(help: ArgumentHelp(valueName: "NAME"), transform: parseInstanceName) var vm: InstanceName

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      try GitHubAssignment.remove(InstanceStore.resolve(context.config, name: vm))
    }
  }
}

struct GitHubSetupPAT: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "setup-pat", abstract: "Run the fine-grained PAT wizard for a repo")

  @OptionGroup var global: GlobalOptions
  @Option(
    help: ArgumentHelp("Repo slug to scope to (auto-detected if omitted)", valueName: "REPO"),
    transform: parseRepoSlug) var repo: RepoSlug?

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      try context.github.setupPAT(
        context.config, target: global.configTarget(context.environment), repo: repo)
    }
  }
}

struct GitHubRotatePAT: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rotate-pat", abstract: "Re-run the wizard against an existing entry")

  @OptionGroup var global: GlobalOptions
  @Option(help: ArgumentHelp("Repo slug to rotate", valueName: "REPO"), transform: parseRepoSlug)
  var repo: RepoSlug

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      try context.github.rotatePAT(
        context.config, target: global.configTarget(context.environment), repo: repo)
    }
  }
}

struct GitHubStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Print configured PAT entries and their validation state")

  @OptionGroup var global: GlobalOptions
  @Option(
    help: ArgumentHelp(
      "Also show this VM's assigned entry and effective selection source", valueName: "NAME"),
    transform: parseInstanceName) var vm: InstanceName?
  @Flag(
    help:
      "Resolve each entry's `cmd:` invocation (may trigger Keychain / 1Password prompts) to confirm the secret store still serves it"
  ) var probe = false
  @Flag(help: "Emit machine-readable JSON instead of the text report") var json = false

  func run() throws {
    try CoopCLI.run {
      try Self.run(CommandContext.load(global), vm: vm, probe: probe, json: json)
    }
  }

  static func run(_ context: CommandContext, vm: InstanceName?, probe: Bool, json: Bool) throws {
    let instance = try vm.map { try InstanceStore.resolve(context.config, name: $0) }
    let view = try context.github.status(context.config, probe: probe, instance: instance)
    context.output.write(json ? view.json().rendered() : view.text())
  }
}

struct GitHubForgetPAT: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "forget-pat", abstract: "Remove a configured PAT entry and its stored secret")

  @OptionGroup var global: GlobalOptions
  @Option(
    help: ArgumentHelp("Repo slug whose entry should be removed", valueName: "REPO"),
    transform: parseRepoSlug) var repo: RepoSlug

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      try context.github.forgetPAT(
        context.config, target: global.configTarget(context.environment), repo: repo)
    }
  }
}
