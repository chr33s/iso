import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

struct AgentListCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List built-in and installed agent definitions")

  @OptionGroup var global: GlobalOptions

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global, backgroundWork: false)
      for entry in AgentCatalog.list(context.config) {
        switch entry {
        case .builtin(let definition, let hash):
          context.output.out(
            "builtin   \(definition.id)  \(SessionSummary.bound(definition.displayName))  \(hash)")
        case .installed(let installed):
          context.output.out(
            "installed \(installed.definition.id)  \(SessionSummary.bound(installed.definition.displayName))  \(installed.definitionHash)"
          )
        case .invalid(let name, let reason):
          context.output.out(
            "invalid   \(SessionSummary.bound(name))  \(SessionSummary.bound(reason))")
        }
      }
    }
  }
}

struct AgentInspectCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inspect", abstract: "Show one agent definition without launching it")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Agent id") var id: String
  @Flag(help: "Emit JSON") var json = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global, backgroundWork: false)
      let identifier = try AgentDefinitionID(id)
      if let builtin = AgentCatalog.builtin(identifier) {
        emit(
          context, definition: builtin, source: "builtin",
          hash: AgentCatalog.definitionHash(builtin))
        return
      }
      let match = AgentCatalog.list(context.config).first {
        switch $0 {
        case .installed(let installed): installed.definition.id == identifier
        case .invalid(let name, _): name == "\(identifier).json"
        case .builtin: false
        }
      }
      switch match {
      case .installed(let installed):
        emit(
          context, definition: installed.definition, source: "installed",
          hash: installed.definitionHash)
      case .invalid(_, let reason):
        throw HostError("agent '\(identifier)' is installed but invalid: \(reason)")
      default:
        throw HostError("No agent definition '\(identifier)'")
      }
    }
  }

  func emit(
    _ context: CommandContext, definition: AgentDefinition, source: String, hash: String
  ) {
    if json {
      var document = AgentDefinitionDecoder.canonical(definition)
      if case .object(let members) = document {
        document = .object(
          members + [("source", .string(source)), ("hash", .string(hash))])
      }
      context.output.write(document.rendered())
      return
    }
    context.output.out("id: \(definition.id)")
    context.output.out("source: \(source)")
    context.output.out("hash: \(hash)")
    context.output.out("display_name: \(SessionSummary.bound(definition.displayName))")
    context.output.out("adapter: \(definition.authAdapter)")
    context.output.out(
      "argv: \(definition.launch.argv.map { SessionSummary.bound($0) }.joined(separator: " "))")
    context.output.out("working_directory: \(definition.launch.workingDirectory)")
    context.output.out("terminal: \(definition.launch.terminal.rawValue)")
    let hints = definition.networkHints.map(\.rawValue).joined(separator: ", ")
    context.output.out(
      "network_hints: \(hints.isEmpty ? "none (not grants)" : hints + " (not grants)")")
  }
}

struct AgentAddCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Validate, review, and install a host-owned agent definition")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Path to a .json or .jsonc definition") var file: String
  @Flag(help: "Replace an installed definition with the same id") var replace = false
  @Flag(name: .customLong("yes"), help: "Install without an interactive confirmation") var yes =
    false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global, backgroundWork: false)
      let (definition, _) = try AgentCatalog.review(sourcePath: file)
      let canonical = String(
        AgentDefinitionDecoder.canonical(definition).rendered().dropLast())
      context.output.error("Source: \(file)")
      context.output.error(
        "Install: \(AgentCatalog.directory(context.config))/\(definition.id).json")
      context.output.error(canonical)
      context.output.error(
        "Network hints are not grants. The adapter is a request, not a credential.")
      if !yes && !TerminalPrompt.confirm("Install agent '\(definition.id)'?") {
        throw HostError("agent installation cancelled")
      }
      let installed = try AgentCatalog.install(definition, config: context.config, replace: replace)
      context.output.error("Installed \(installed.definition.id) \(installed.definitionHash)")
    }
  }
}
