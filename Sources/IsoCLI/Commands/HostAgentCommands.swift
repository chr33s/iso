import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

/// Internal host-control entrypoints (docs/design/local-and-remote-hosts-spec.md
/// section 3.3). None accepts a guest command or a filesystem operation; request
/// data and grant preambles arrive on stdin only.
struct HostAgentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "host-agent", abstract: "Internal host-control service entrypoints",
    shouldDisplay: false,
    subcommands: [
      HostAgentDaemon.self, HostAgentServe.self, HostAgentRelay.self, HostAgentConnect.self,
    ])
}

private func loadConfig(_ global: GlobalOptions) throws -> IsoConfig {
  let environment = ConfigEnvironment.process
  return try ConfigLoader.load(global.selection(environment: environment), environment: environment)
}

struct HostAgentDaemon: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "daemon", abstract: "Run the per-user host-control service")

  @OptionGroup var global: GlobalOptions
  @Option(help: "Expected installation id") var installation: String?

  func run() throws {
    try IsoCLI.run {
      let expected = try installation.map { try HostID($0) }
      let config = try loadConfig(global)
      try HostService.runDaemon(
        config: config, environment: ProcessInfo.processInfo.environment, installation: expected,
        diagnostics: Diagnostics(verbosity: global.verbose))
    }
  }
}

struct HostAgentServe: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "serve", abstract: "Forward host-control frames between stdio and the service")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Use stdin/stdout (the only supported mode)") var stdio = false

  func validate() throws {
    guard stdio else { throw ArgumentParser.ValidationError("--stdio is required") }
  }

  func run() throws {
    try IsoCLI.run {
      let code = try HostService.serveStdio(
        config: try loadConfig(global), configPath: global.config,
        diagnostics: Diagnostics(verbosity: global.verbose))
      if code != 0 { throw ExitCode(code) }
    }
  }
}

struct HostAgentRelay: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "relay", abstract: "Carry one admitted guest stream between stdio and the service")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Use stdin/stdout (the only supported mode)") var stdio = false

  func validate() throws {
    guard stdio else { throw ArgumentParser.ValidationError("--stdio is required") }
  }

  func run() throws {
    try IsoCLI.run {
      let code = try HostService.relayStdio(
        config: try loadConfig(global), configPath: global.config,
        diagnostics: Diagnostics(verbosity: global.verbose))
      if code != 0 { throw ExitCode(code) }
    }
  }
}

struct HostAgentConnect: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "connect", abstract: "ssh ProxyCommand: reach a guest through its host relay")

  @Option(help: "Private session descriptor written by the session coordinator")
  var descriptor: String

  func run() throws {
    try IsoCLI.run {
      let session = try SessionDescriptor.load(path: descriptor)
      let code = try session.connect(environment: ProcessInfo.processInfo.environment)
      if code != 0 { throw ExitCode(code) }
    }
  }
}
