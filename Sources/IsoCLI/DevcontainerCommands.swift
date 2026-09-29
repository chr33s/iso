// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

struct DevcontainerCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "devcontainer",
    abstract: "Inspect devcontainer.json support without starting setup or a VM",
    subcommands: [
      DevcontainerCheck.self, DevcontainerIgnore.self, DevcontainerStatus.self,
      DevcontainerClear.self,
    ])

  /// A subcommand is required: help on stderr, usage exit status (2).
  func run() throws {
    let help = IsoCommand.helpMessage(for: Self.self)
    FileHandle.standardError.write(Data((help.hasSuffix("\n") ? help : help + "\n").utf8))
    throw ExitCode(2)
  }
}

enum DevcontainerCheckStage: String, ExpressibleByArgument, CaseIterable {
  case setup, start, both

  static let allValueStrings = allCases.map(\.rawValue)
}

struct DevcontainerCheck: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "check", abstract: "Parse devcontainer.json and print iso's translation report")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Path to the devcontainer.json file to inspect") var path: String
  @Option(
    help: ArgumentHelp(
      "Which lifecycle translation to report (setup: features, hostRequirements, remoteUser; start: postStartCommand, containerEnv, ports, mounts; both)"
    ))
  var stage: DevcontainerCheckStage = .both
  @Flag(help: "Emit machine-readable JSON on stdout instead of the text report on stderr")
  var json = false

  /// Reads no configuration, as the baseline did.
  func run() throws {
    try IsoCLI.run {
      let environment = ConfigEnvironment.process.variables
      let resolver = DevcontainerResolver(
        environment: environment, diagnostics: Diagnostics(verbosity: global.verbose))
      try Self.run(
        path: path, stage: stage, json: json, resolver: resolver, output: StandardStreams())
    }
  }

  static func run(
    path: String, stage: DevcontainerCheckStage, json: Bool, resolver: DevcontainerResolver,
    output: some OutputStreams
  ) throws {
    let options = DevcontainerOptions(input: .explicit(path), dryRun: true)
    let setupInputs = DevcontainerTranslatorInputs()
    let startInputs = { (user: GuestUser) in DevcontainerTranslatorInputs(persistedGuestUser: user)
    }
    if json {
      let value: OutputJSON
      switch stage {
      case .setup:
        value =
          try resolver.collect(options, inputs: setupInputs, stage: .setup)?.report.json ?? .null
      case .start:
        value =
          try resolver.collect(options, inputs: startInputs(.default), stage: .start)?.report.json
          ?? .null
      case .both:
        let setup = try resolver.collect(options, inputs: setupInputs, stage: .setup)
        let start = try resolver.collect(
          options, inputs: startInputs(assumedGuestUser(setup)), stage: .start)
        value = .object([
          ("setup", setup?.report.json ?? .null), ("start", start?.report.json ?? .null),
        ])
      }
      output.write(value.rendered())
      return
    }
    switch stage {
    case .setup: _ = try resolver.resolve(options, inputs: setupInputs, stage: .setup)
    case .start: _ = try resolver.resolve(options, inputs: startInputs(.default), stage: .start)
    case .both:
      output.error("setup-stage translation:")
      let setup = try resolver.resolve(options, inputs: setupInputs, stage: .setup)
      output.error("")
      output.error("start-stage translation:")
      _ = try resolver.resolve(
        options, inputs: startInputs(assumedGuestUser(setup)), stage: .start)
    }
  }

  /// `--stage both` assumes the image was set up with the file's user.
  static func assumedGuestUser(_ setup: DevcontainerTranslation?) -> GuestUser {
    setup?.guestUser ?? .default
  }
}

struct DevcontainerIgnore: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ignore",
    abstract: "Persistently ignore discovered devcontainer.json for a project")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Project directory whose discovered devcontainer.json should be ignored")
  var project: String

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      try Self.run(
        project: project, preferencePath: Devcontainer.preferencesPath(context.config),
        output: context.output)
    }
  }

  static func run(project: String, preferencePath: String, output: some OutputStreams) throws {
    var preferences = try DevcontainerPreferences.load(preferencePath)
    let key = try preferences.setIgnored(project)
    try preferences.save(preferencePath)
    output.out("Devcontainer discovery disabled for project \(key)")
  }
}

struct DevcontainerStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Show persistent devcontainer opt-outs")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Project directory to inspect; omitted lists every stored opt-out")
  var project: String?

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      try Self.run(
        project: project, preferencePath: Devcontainer.preferencesPath(context.config),
        output: context.output)
    }
  }

  static func run(project: String?, preferencePath: String, output: some OutputStreams) throws {
    let preferences = try DevcontainerPreferences.load(preferencePath)
    if let project {
      if let key = try preferences.ignoredProject(project) {
        output.out("Devcontainer discovery disabled for project \(key)")
      } else {
        output.out(
          "Devcontainer discovery enabled for project \(try DevcontainerPreferences.lookupKey(project))"
        )
      }
      return
    }
    let ignored = preferences.ignoredProjects
    if ignored.isEmpty {
      output.out("No persistent devcontainer opt-outs recorded.")
    } else {
      output.out("Persistent devcontainer opt-outs:")
      for key in ignored { output.out("  \(key)") }
    }
  }
}

struct DevcontainerClear: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "clear", abstract: "Clear a persistent devcontainer opt-out for a project")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Project directory whose opt-out should be cleared") var project: String

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      try Self.run(
        project: project, preferencePath: Devcontainer.preferencesPath(context.config),
        output: context.output)
    }
  }

  static func run(project: String, preferencePath: String, output: some OutputStreams) throws {
    var preferences = try DevcontainerPreferences.load(preferencePath)
    let key = try DevcontainerPreferences.lookupKey(project)
    let removed = try preferences.clear(project)
    try preferences.save(preferencePath)
    if removed {
      output.out("Cleared devcontainer opt-out for project \(key)")
    } else {
      output.out("No persistent devcontainer opt-out recorded for project \(key)")
    }
  }
}
