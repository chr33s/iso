// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

// MARK: - update

struct Update: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Replace the running iso binary with the latest GitHub release")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Only check for an available update — do not download or install") var check = false
  @Flag(help: "Reinstall even if the current binary is already up to date") var force = false
  @Option(
    name: .customLong("version"),
    help: ArgumentHelp(
      "Install a specific version (e.g. `v0.3.2` or `0.3.2`)", valueName: "VERSION"))
  var targetVersion: String?
  @Flag(name: .shortAndLong, help: "Skip the interactive confirmation prompt") var yes = false
  @Flag(help: "Permit installing a release older than the current binary")
  var allowDowngrade = false

  func run() throws {
    try IsoCLI.run {
      let environment = ConfigEnvironment.process
      try checkDataRoot(global, environment)
      try AdminSupport.updater(environment, verbosity: global.verbose).run(
        Updater.Options(
          checkOnly: check, force: force, pinnedVersion: targetVersion, skipConfirm: yes,
          allowDowngrade: allowDowngrade))
    }
  }
}

// MARK: - uninstall

struct Uninstall: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Remove the iso binary and (optionally) its data directories")

  @OptionGroup var global: GlobalOptions
  @Flag(
    name: .shortAndLong,
    help: "Skip interactive confirmation prompts (removes data unless --keep-data)")
  var yes = false
  @Flag(help: "Remove only the binary, keep ~/.iso and update-check state") var keepData = false
  @Flag(help: "Also remove data without prompting (pairs with --yes for CI)") var purge = false

  func validate() throws {
    if keepData && purge {
      throw UsageError("the argument '--keep-data' cannot be used with '--purge'")
    }
  }

  func run() throws {
    try IsoCLI.run {
      let environment = ConfigEnvironment.process
      try checkDataRoot(global, environment)
      let diagnostics = Diagnostics(verbosity: global.verbose)
      let config = try AdminSupport.bestEffortConfig(global, environment, diagnostics)
      let backend = AppleBackend(
        config: config.config, environment: environment.variables,
        executable: CommandLine.executablePath, diagnostics: diagnostics)
      var uninstaller = Uninstaller(
        backend: backend, configPath: config.path, home: environment.home,
        binaryPath: CommandLine.executablePath, environment: environment.variables)
      let client = SSHClient(environment: environment.variables)
      let resolver = CredentialResolver(environment: environment.variables)
      let proxies = ProxyLauncher(
        environment: environment.variables, resolver: resolver, diagnostics: diagnostics,
        isoExecutable: CommandLine.executablePath)
      uninstaller.teardown = { instance in
        if let target = try? backend.sshTarget(instance) {
          PortForwards(client: client, diagnostics: diagnostics).teardown(instance, target)
        }
        proxies.stopAll(instance)
      }
      try uninstaller.run(Uninstaller.Options(yes: yes, keepData: keepData, purge: purge))
    }
  }
}

enum AdminSupport {
  static func updater(_ environment: ConfigEnvironment, verbosity: Int) -> Updater {
    Updater(
      environment: environment.variables, home: environment.home,
      currentExecutable: CommandLine.executablePath,
      diagnostics: Diagnostics(verbosity: verbosity))
  }

  /// Uninstall must work on a half-installed system: a configuration that
  /// fails to load falls back to defaults, with a warning that a custom
  /// `data_dir` may not be honoured.
  static func bestEffortConfig(
    _ global: GlobalOptions, _ environment: ConfigEnvironment, _ diagnostics: Diagnostics
  ) throws -> (config: IsoConfig, path: String) {
    let path =
      global.config
      ?? ConfigLoader.defaultDirectory(home: environment.home) + "/" + ConfigLoader.defaultFileName
    do {
      return (
        try ConfigLoader.load(global.selection(environment: environment), environment: environment),
        path
      )
    } catch {
      diagnostics.warn(
        "Failed to parse \(path) (\(error)); using defaults. A custom data_dir may not be honoured — re-run with --keep-data if your data lives outside \(ConfigLoader.defaultDirectory(home: environment.home))."
      )
      return (
        try ConfigLoader.load(.defaultsOnly(defaultPath: path), environment: environment), path
      )
    }
  }

  /// After configuration loads and before a command runs, show any saved
  /// update notice, then schedule the background check.
  static func updateNotice(
    _ config: IsoConfig, environment: ConfigEnvironment, diagnostics: Diagnostics
  ) {
    let updater = Updater(
      environment: environment.variables, home: environment.home,
      currentExecutable: CommandLine.executablePath, diagnostics: diagnostics)
    UpdateCheck.maybePrintNotify(
      config.updates, updater: updater, stdinIsTerminal: Prompt.stdinIsTerminal)
    UpdateCheck.maybeRunBackgroundCheck(
      config.updates, updater: updater, stdinIsTerminal: Prompt.stdinIsTerminal)
  }
}
