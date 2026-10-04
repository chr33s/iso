// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import IsoSecrets

/// Host CLI entrypoint and supported command tree.
@main
struct IsoCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "iso",
    abstract: "Isolated VM environment for running Claude Code and Codex",
    version: IsoVersion.string,
    subcommands: [
      Up.self, Setup.self, DevcontainerCommand.self, Start.self, Shell.self,
      ClaudeCommand.self, ClaudeAgentsCommand.self, CodexCommand.self, RunCommand.self,
      RunCleanup.self, Stop.self, Destroy.self,
      List.self, Status.self, AgentCommand.self, ModelCommand.self, Logs.self, Push.self,
      Pull.self, Diff.self, Exec.self, Editor.self, SSHConfigCommand.self, Images.self, Resize.self,
      Commit.self, Restore.self, ProfilesCommand.self, GitHubCommand.self, ProxyCommand.self,
      SecretsCommand.self, Audit.self, Capabilities.self,
      Validate.self, Update.self, Uninstall.self, Completions.self,
      EgressLeaseCommand.self,
    ])

  @OptionGroup var global: GlobalOptions

  /// Usage errors exit 2; override Argument Parser's default of 64.
  static func main() {
    ChildGroups.installTerminationHandlers()
    do {
      var command = try parseAsRoot()
      let global = GlobalOptions.parsed(in: command)
      // A group command carries no options of its own; its argv still asks.
      if global?.output == .json
        || (global == nil && GlobalOptions.requestsMachineOutput(CommandLine.arguments))
      {
        try MachineSession.begin(quiet: global?.quiet ?? false)
        guard command is any MachineCommand else {
          return try rejectUnsupportedMachineOutput(command)
        }
      }
      try command.run()
    } catch {
      let code = exitCode(for: error)
      guard code == .validationFailure else { exit(withError: error) }
      FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
      Foundation.exit(2)
    }
  }
}

enum IsoVersion {
  static let string = "iso " + IsoBuild.current.versionString
}

struct GlobalOptions: ParsableArguments {
  @Option(name: .long, help: "Path to iso config file (.jsonc or .json)")
  var config: String?

  @Flag(name: .shortAndLong, help: "Increase verbosity")
  var verbose: Int

  @Option(
    help: ArgumentHelp(
      "Output format: text, or json for the versioned iso.machine/v1 document (docs/machine-interface.md)",
      valueName: "FORMAT"))
  var output: OutputFormat = .text

  @Flag(help: "With --output json, discard all stderr diagnostics")
  var quiet = false

  func validate() throws {
    if quiet && output != .json {
      throw ArgumentParser.ValidationError("--quiet requires --output json")
    }
  }

  func selection(environment: ConfigEnvironment) throws(ConfigError) -> ConfigSelection {
    try ConfigLoader.select(explicitPath: config, home: environment.home)
  }

  /// Target for commands that create the file: the explicit path or the
  /// default JSONC location.
  func writableTarget(environment: ConfigEnvironment) throws(ConfigError) -> (
    path: String, format: ConfigFormat
  ) {
    if let config { return (config, try ConfigFormat(path: config)) }
    let directory = ConfigLoader.defaultDirectory(home: environment.home)
    return (directory + "/" + ConfigLoader.defaultFileName, .jsonc)
  }
}

/// Maps typed failures to stderr and exit status 1.
func run(_ body: () throws -> Void) throws {
  do {
    try body()
  } catch let error as ExitCode {
    throw error
  } catch let error as IsoCore.ValidationError {
    throw ArgumentParser.ValidationError(error.message)
  } catch {
    // Error chains can carry guest, runtime or registry text (remote stderr,
    // devcontainer keys): control characters never reach the terminal raw.
    FileHandle.standardError.write(Data("Error: \(neutralizeControls("\(error)"))\n".utf8))
    throw ExitCode.failure
  }
}

enum SetupConfigOnly {
  /// Create the configuration template without installing or starting anything.
  /// An existing file is left untouched and reported.
  static func run(_ path: String, format: ConfigFormat, output: some OutputStreams) throws {
    if try ConfigStore.createTemplate(at: path, format: format) {
      output.out("Created \(path). Edit to customize, or leave as-is for defaults.")
    } else {
      output.out("Config file already exists at \(path); left unchanged.")
    }
  }
}

struct Validate: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Validate configuration and check prerequisites")

  @OptionGroup var global: GlobalOptions
  @Flag(
    help:
      "Probe live state for each `[github.pat]` entry (talks to api.github.com); also unlocks the secret store to resolve `vault:` entries"
  )
  var probe = false

  func run() throws {
    try IsoCLI.run {
      let environment = ConfigEnvironment.process
      let config = try ConfigLoader.load(
        global.selection(environment: environment), environment: environment)
      AdminSupport.updateNotice(
        config, environment: environment, diagnostics: Diagnostics(verbosity: global.verbose))
      // The secret store is unlocked only for `--probe`, which already
      // reaches out; a plain validate never prompts for the passphrase.
      let store =
        probe
        ? StoreSecretResolver.shared(
          EnclaveStore(directory: config.dataDirectory.appending("secrets").path)) : nil
      try ValidateReport.run(
        config: config,
        resolver: CredentialResolver(environment: environment.variables, secrets: store),
        fileSystem: LocalConfigFileSystem(), output: StandardStreams(),
        probe: probe
          ? GitHubAPI(
            tools: HostTools(environment: environment.variables),
            diagnostics: Diagnostics(verbosity: global.verbose)) : nil)
    }
  }
}

/// The one GitHub call `validate --probe` makes per resolved token.
protocol GitHubUserProbe {
  func userLogin(token: Secret<String>) throws -> String
}

extension GitHubAPI: GitHubUserProbe {}

enum ValidateReport {
  /// Environmental checks, then each PAT entry resolved explicitly (the one
  /// place `validate` runs `cmd:` references). A
  /// `vault:` entry is left unresolved unless `probe` is set, which unlocks
  /// the secret store once for all of them and checks each resolved token
  /// against `GET /user`.
  static func run(
    config: IsoConfig, resolver: CredentialResolver, fileSystem: some ConfigFileSystem,
    output: some OutputStreams, probe: (any GitHubUserProbe)? = nil
  ) throws {
    output.out("Validating config (backend: apple-container)...")
    for warning in try config.validated(fileSystem: fileSystem) {
      output.out("  warning: \(warning)")
    }
    if case .pat(let pat)? = config.github {
      var batchFailure: (any Error)?
      let resolveStored = probe != nil
      if resolveStored {
        do { try resolver.prefetchStored(Array(pat.entries.values)) } catch { batchFailure = error }
      }
      for repo in pat.entries.keys.sorted() {
        let entry = pat.entries[repo]!
        if entry.expose().hasPrefix("vault:") {
          if !resolveStored {
            output.out(
              "  github.pat.\"\(repo)\": stored secret, not resolved (run with --probe to check it)"
            )
            continue
          }
          if let batchFailure {
            output.out("  github.pat.\"\(repo)\": FAILED to resolve token (\(batchFailure))")
            continue
          }
        }
        do {
          let token = try resolver.resolveAllowingStored(entry)
          if token.expose().hasPrefix("github_pat_") {
            output.out("  github.pat.\"\(repo)\": ok (resolves, fine-grained PAT format)")
          } else {
            output.out(
              "  github.pat.\"\(repo)\": warning — token resolves but is not a fine-grained PAT (no 'github_pat_' prefix)"
            )
          }
          if let probe {
            do {
              let login = try probe.userLogin(token: token)
              output.out("    probe: /user as '\(sanitizeForDisplay(login))'")
            } catch {
              output.out("    probe: FAILED (\((error as? ContextError)?.context ?? "\(error)"))")
            }
          }
        } catch {
          output.out("  github.pat.\"\(repo)\": FAILED to resolve token (\(error))")
        }
      }
    }
    output.out("Config OK")
  }
}

struct Completions: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Print a shell completion script (run `iso completions --help` for setup)",
    discussion: """
      Examples:
        # bash — user
        iso completions bash > ~/.local/share/bash-completion/completions/iso

        # zsh — user (ensure the directory is on $fpath; restart the shell)
        iso completions zsh > ~/.zfunc/_iso

        # fish — user
        iso completions fish > ~/.config/fish/completions/iso.fish
      """)

  @Argument(help: "Shell to generate completions for (bash, zsh, fish)")
  var shell: String

  func run() throws {
    guard let script = CompletionScripts.script(for: shell) else {
      throw ArgumentParser.ValidationError(CompletionScripts.unsupportedMessage(shell))
    }
    print(script, terminator: "")
  }
}

/// Static Argument Parser-generated scripts. Generation reads no
/// configuration, secrets, state or runtime.
enum CompletionScripts {
  static let supported: [(name: String, shell: CompletionShell)] = [
    ("bash", .bash), ("zsh", .zsh), ("fish", .fish),
  ]

  static func script(for name: String) -> String? {
    supported.first { $0.name == name }.map { IsoCommand.completionScript(for: $0.shell) }
  }

  static func unsupportedMessage(_ name: String) -> String {
    return "unsupported shell '\(name)'; supported shells: bash, zsh, fish"
  }
}

struct StandardStreams: OutputStreams {
  func out(_ line: String) { write(line + "\n") }
  func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
  func error(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
}
