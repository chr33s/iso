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
      HostAgentClient.self,
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

/// The supported external client bridge: a companion process (not part of
/// iso) speaks `iso.host/v1` through this command without reading iso's
/// state. `local` goes through the local service's remote socket, so every
/// remote-v1 restriction applies; an enrolled host through its pinned
/// management SSH. Frames and the relay preamble arrive on stdin only.
struct HostAgentClient: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "client",
    abstract: "Bridge iso.host/v1 frames or one relay stream between stdio and a host")

  @OptionGroup var global: GlobalOptions
  @Option(help: "`local` or an enrolled host alias") var host: String
  @Flag(help: "Carry one relay stream: a preamble line on stdin, then raw bytes") var relay = false
  @Flag(help: "Use stdin/stdout (the only supported mode)") var stdio = false

  func validate() throws {
    guard stdio else { throw ArgumentParser.ValidationError("--stdio is required") }
  }

  func run() throws {
    try IsoCLI.run {
      let alias = try HostAlias(host)
      let config = try loadConfig(global)
      let environment = ProcessInfo.processInfo.environment
      let diagnostics = Diagnostics(verbosity: global.verbose)
      let code: Int32
      if alias.isLocal {
        code =
          relay
          ? try HostService.relayStdio(
            config: config, configPath: global.config, diagnostics: diagnostics)
          : try HostService.serveStdio(
            config: config, configPath: global.config, diagnostics: diagnostics)
      } else {
        guard let enrollment = try HostRegistry(config: config).load(alias) else {
          throw HostError("host '\(alias)' is not enrolled; run `iso host add \(alias) ...` first")
        }
        // A disabled host takes observation and cleanup only through
        // `iso host`; the bridge cannot tell new work from cleanup.
        guard !enrollment.disabled else {
          throw HostError("host '\(alias)' is disabled; the client bridge is refused")
        }
        guard let ssh = SSHClient(environment: environment).sshExecutable() else {
          throw HostError("ssh is not installed")
        }
        code = try HostService.bridgeRemote(
          ssh: ssh, alias: enrollment.sshAlias, agent: enrollment.agentPath,
          entry: relay ? .relay : .serve, environment: environment)
      }
      if code != 0 { throw ExitCode(code) }
    }
  }
}
