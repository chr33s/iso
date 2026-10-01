// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import IsoSecrets

/// Swift host CLI. Development build during the port: commands not listed
/// here are not yet ported and do not exist in this binary.
@main
struct IsoCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "iso",
    abstract: "Isolated VM environment for running Claude Code and Codex",
    version: IsoVersion.string,
    subcommands: [
      Up.self, Quickstart.self, Setup.self, DevcontainerCommand.self, Start.self, Shell.self,
      ClaudeCommand.self, ClaudeAgentsCommand.self, CodexCommand.self, RunCommand.self,
      RunCleanup.self, Stop.self, Destroy.self,
      List.self, Status.self, AgentCommand.self, ModelCommand.self, Logs.self, Push.self,
      Pull.self, Diff.self, Exec.self, Editor.self, SSHConfigCommand.self, Images.self, Resize.self,
      Commit.self, Restore.self, ProfilesCommand.self, GitHubCommand.self, ProxyCommand.self,
      SecretsCommand.self, Audit.self,
      Validate.self, Init.self, Update.self, Uninstall.self, Completions.self,
      EgressLeaseCommand.self,
    ])

  @OptionGroup var global: GlobalOptions

  /// Usage errors exit 2, as the baseline clap parser did (Argument Parser
  /// defaults to 64).
  static func main() {
    ChildGroups.installTerminationHandlers()
    do {
      var command = try parseAsRoot()
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

  func selection(environment: ConfigEnvironment) throws(ConfigError) -> ConfigSelection {
    try ConfigLoader.select(explicitPath: config, home: environment.home)
  }

  /// Target for commands that create the file: the explicit path or the
  /// default JSONC location (never a legacy TOML path).
  func writableTarget(environment: ConfigEnvironment) throws(ConfigError) -> (
    path: String, format: ConfigFormat
  ) {
    if let config { return (config, try ConfigFormat(path: config)) }
    let directory = ConfigLoader.defaultDirectory(home: environment.home)
    return (directory + "/" + ConfigLoader.defaultFileName, .jsonc)
  }
}

/// Maps typed failures to stderr and the baseline exit status (1).
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

struct Init: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Deprecated alias for `iso setup --config-only`")

  @OptionGroup var global: GlobalOptions

  func run() throws {
    try IsoCLI.run {
      let streams = StandardStreams()
      streams.error("note: `iso init` is deprecated; use `iso setup --config-only`")
      let target = try global.writableTarget(environment: .process)
      try SetupConfigOnly.run(target.path, format: target.format, output: streams)
    }
  }
}

/// C-03: `quickstart` is gone; say what replaces it instead of a usage error.
struct Quickstart: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Removed: use `iso setup`, then `iso up`, then `iso claude` or `iso codex`",
    shouldDisplay: false)

  @OptionGroup var global: GlobalOptions
  @Argument(parsing: .allUnrecognized) var ignored: [String] = []

  func run() throws {
    try IsoCLI.run {
      throw HostError(
        "`iso quickstart` has been removed. Run `iso setup` to create the config and build the image, then `iso up [DIR]` to start a VM for your project, then `iso claude` or `iso codex` to launch an agent."
      )
    }
  }
}

enum SetupConfigOnly {
  /// Shared by `setup --config-only` and `init`. An existing file is left
  /// untouched and reported; nothing else is installed or started.
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
  /// place `validate` runs `cmd:` references, as the baseline did). A
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

/// C-02: static, Argument Parser-generated scripts only. Generation reads no
/// configuration, secrets, state or runtime.
enum CompletionScripts {
  static let supported: [(name: String, shell: CompletionShell)] = [
    ("bash", .bash), ("zsh", .zsh), ("fish", .fish),
  ]
  static let retired: Set<String> = ["powershell", "elvish"]

  static func script(for name: String) -> String? {
    supported.first { $0.name == name }.map { IsoCommand.completionScript(for: $0.shell) }
  }

  static func unsupportedMessage(_ name: String) -> String {
    if retired.contains(name) {
      return "\(name) completions are no longer provided; supported shells: bash, zsh, fish"
    }
    return "unsupported shell '\(name)'; supported shells: bash, zsh, fish"
  }
}

protocol OutputStreams {
  /// One line to stdout.
  func out(_ line: String)
  /// Raw text to stdout (already newline-terminated).
  func write(_ text: String)
  func error(_ line: String)
}

struct StandardStreams: OutputStreams {
  func out(_ line: String) { write(line + "\n") }
  func write(_ text: String) { FileHandle.standardOutput.write(Data(text.utf8)) }
  func error(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }
}
