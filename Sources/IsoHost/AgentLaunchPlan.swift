import Foundation
import IsoConfiguration
import IsoCore

/// What a compiled adapter will do. Definitions select an entry; they do not
/// supply its code, credential destination, or broker routes.
public struct AgentAdapterContract: Sendable, Equatable {
  public static let contractVersion = 1
  public let id: AgentAdapterID
  public let contractVersion: Int
  /// Empty means the declared guest executable is used as given (`none`).
  public let logicalExecutables: Set<String>
  public let supportsAsk: Bool
  public let terminalModes: Set<AgentTerminalMode>
  /// Flags the adapter injects. A definition must not set them.
  public let managedFlags: Set<String>
  public let providerName: String?

  public static let none = AgentAdapterContract(
    id: .none, contractVersion: contractVersion, logicalExecutables: [], supportsAsk: false,
    terminalModes: Set(AgentTerminalMode.allCases), managedFlags: [], providerName: nil)
  public static let claude = AgentAdapterContract(
    id: .claude, contractVersion: contractVersion, logicalExecutables: ["claude"],
    supportsAsk: true, terminalModes: Set(AgentTerminalMode.allCases),
    managedFlags: ["--permission-mode", "--dangerously-skip-permissions"],
    providerName: "anthropic")
  public static let codex = AgentAdapterContract(
    id: .codex, contractVersion: contractVersion, logicalExecutables: ["codex"],
    supportsAsk: true, terminalModes: Set(AgentTerminalMode.allCases),
    managedFlags: ["--dangerously-bypass-approvals-and-sandbox"], providerName: "openai")
}

public enum AgentAdapterRegistry {
  public static func contract(_ id: AgentAdapterID) -> AgentAdapterContract? {
    switch id.rawValue {
    case AgentAdapterID.none.rawValue: AgentAdapterContract.none
    case AgentAdapterID.claude.rawValue: AgentAdapterContract.claude
    case AgentAdapterID.codex.rawValue: AgentAdapterContract.codex
    default: nil
    }
  }
}

public enum EnvironmentSelectionOrigin: String, Sendable, Equatable {
  case command = "cli"
  case definition
  case configurationDefault = "configuration-default"
}

public struct ResolvedAgentEnvironment: Sendable, Equatable {
  public let image: ImageName
  public let profiles: [String]
  public let origin: EnvironmentSelectionOrigin
}

/// Immutable plan built before side effects. It holds no credentials and no
/// caller passthrough arguments.
public struct AgentLaunchPlan: Sendable, Equatable {
  public let definition: AgentDefinition
  public let source: AgentDefinitionSource
  public let definitionHash: String
  public let adapter: AgentAdapterContract
  public let environment: ResolvedAgentEnvironment
  public let argv: [String]
  public let workingDirectory: GuestPath
  public let terminal: AgentTerminalMode
  public let defaults: [GuestEnvironmentDefault]
  public let networkHints: [ExactHostname]
  public let ask: Bool
  public var unresolved: [String]
}

public enum AgentLaunchPlanner {
  /// Local compatibility only. Does not resolve credentials, start a VM, or
  /// merge network hints into any allowlist.
  public static func plan(
    definition: AgentDefinition, source: AgentDefinitionSource, definitionHash: String,
    cliImage: ImageName?, cliProfiles: [String], ask: Bool
  ) throws -> AgentLaunchPlan {
    if cliImage != nil, !cliProfiles.isEmpty {
      throw HostError(
        "`--image` and `--profile` are mutually exclusive; profiles derive their own image name")
    }
    guard let adapter = AgentAdapterRegistry.contract(definition.authAdapter) else {
      throw HostError("unknown adapter '\(definition.authAdapter)'")
    }
    let logical = definition.launch.argv[0]
    if !adapter.logicalExecutables.isEmpty && !adapter.logicalExecutables.contains(logical) {
      throw HostError(
        "adapter '\(adapter.id)' does not accept executable '\(logical)' (expected \(adapter.logicalExecutables.sorted().joined(separator: ", ")))"
      )
    }
    if ask && !adapter.supportsAsk {
      throw HostError("adapter '\(adapter.id)' does not support --ask")
    }
    guard adapter.terminalModes.contains(definition.launch.terminal) else {
      throw HostError(
        "adapter '\(adapter.id)' does not support terminal mode '\(definition.launch.terminal.rawValue)'"
      )
    }
    for flag in definition.launch.argv where adapter.managedFlags.contains(flag) {
      throw HostError(
        "definition argv must not set adapter-managed flag \(flag); pass --ask or omit it")
    }
    let environment = try resolveEnvironment(
      definition: definition, cliImage: cliImage, cliProfiles: cliProfiles)
    var unresolved = [
      "guest executable presence",
      "runtime readiness",
    ]
    if environment.origin != .configurationDefault || environment.image != .default {
      unresolved.append("image preparation")
    }
    return AgentLaunchPlan(
      definition: definition, source: source, definitionHash: definitionHash, adapter: adapter,
      environment: environment, argv: definition.launch.argv,
      workingDirectory: definition.launch.workingDirectory, terminal: definition.launch.terminal,
      defaults: definition.launch.environment, networkHints: definition.networkHints, ask: ask,
      unresolved: unresolved)
  }

  public static func resolveEnvironment(
    definition: AgentDefinition, cliImage: ImageName?, cliProfiles: [String]
  ) throws -> ResolvedAgentEnvironment {
    if !cliProfiles.isEmpty {
      let names = Array(Set(cliProfiles)).sorted {
        $0.utf8.lexicographicallyPrecedes($1.utf8)
      }
      let image: ImageName
      do { image = try ImageName(names.joined(separator: "-")) } catch {
        throw ContextError(
          "Cannot derive an image name from profile list: \(names.joined(separator: ", "))",
          cause: error)
      }
      return ResolvedAgentEnvironment(image: image, profiles: names, origin: .command)
    }
    if let cliImage {
      return ResolvedAgentEnvironment(image: cliImage, profiles: [], origin: .command)
    }
    switch definition.environment {
    case .image(let image):
      return ResolvedAgentEnvironment(image: image, profiles: [], origin: .definition)
    case .profiles(let profiles):
      let names = Array(Set(profiles)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      let image: ImageName
      do { image = try ImageName(names.joined(separator: "-")) } catch {
        throw ContextError(
          "Cannot derive an image name from profile list: \(names.joined(separator: ", "))",
          cause: error)
      }
      return ResolvedAgentEnvironment(image: image, profiles: names, origin: .definition)
    case nil:
      return ResolvedAgentEnvironment(image: .default, profiles: [], origin: .configurationDefault)
    }
  }
}

/// Guest argv a reviewed adapter will execute. Passthrough is appended here
/// and is not part of the stored plan.
public struct AgentInvocation: Sendable, Equatable {
  public let argv: [String]
  public let workingDirectory: GuestPath
  public let allocatePTY: Bool
  public let defaults: [GuestEnvironmentDefault]
}

public enum AgentDispatch {
  public static func invocation(
    plan: AgentLaunchPlan, passthrough: [String], guestUser: GuestUser, codexAccount: Bool,
    stdinIsTerminal: Bool, stdoutIsTerminal: Bool
  ) throws -> AgentInvocation {
    guard plan.adapter.terminalModes.contains(plan.terminal) else {
      throw HostError(
        "adapter '\(plan.adapter.id)' does not support terminal mode '\(plan.terminal.rawValue)'")
    }
    let allocatePTY: Bool
    switch plan.terminal {
    case .required:
      guard stdinIsTerminal && stdoutIsTerminal else {
        throw HostError("terminal mode 'required' needs a terminal on stdin and stdout")
      }
      allocatePTY = true
    case .never:
      allocatePTY = false
    case .auto:
      allocatePTY = stdinIsTerminal && stdoutIsTerminal
    }
    let defaults = Array(plan.argv.dropFirst())
    for flag in defaults + passthrough where plan.adapter.managedFlags.contains(flag) && plan.ask {
      throw HostError(
        "passthrough flag \(flag) conflicts with --ask on adapter '\(plan.adapter.id)'")
    }
    let binary: String
    var tail: [String]
    switch plan.adapter.id.rawValue {
    case AgentAdapterID.claude.rawValue:
      binary = guestUser.claudeBinary.rawValue
      tail = defaults + passthrough
      if plan.ask {
        guard !tail.contains("--permission-mode") else {
          throw HostError("passthrough flag --permission-mode conflicts with --ask")
        }
        tail = ["--permission-mode", "default"] + tail
      }
    case AgentAdapterID.codex.rawValue:
      let forwarded = defaults + passthrough
      let auth = ["login", "logout"].contains(forwarded.first ?? "")
      if !plan.ask && !auth && forwarded.contains("--dangerously-bypass-approvals-and-sandbox") {
        throw HostError(
          "passthrough flag --dangerously-bypass-approvals-and-sandbox conflicts with the adapter default"
        )
      }
      binary = (codexAccount ? GuestBinaries.codexAccount : GuestBinaries.codex).rawValue
      tail = CodexChecks.launchArguments(ask: plan.ask, forwarded)
    case AgentAdapterID.none.rawValue:
      binary = plan.argv[0]
      tail = defaults + passthrough
    default:
      throw HostError("unknown adapter '\(plan.adapter.id)'")
    }
    return AgentInvocation(
      argv: [binary] + tail, workingDirectory: plan.workingDirectory, allocatePTY: allocatePTY,
      defaults: plan.defaults)
  }
}
