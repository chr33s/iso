import Foundation
import IsoConfiguration
import IsoCore

public enum RunAction: String, Sendable, Equatable {
  case create
  case restart
  case attach
  case blocked
  case unresolved
}

/// Versioned dry-run document. It is not a live readiness proof and contains
/// no credentials, capabilities, or caller passthrough arguments.
public struct RunPreview: Sendable, Equatable {
  public static let schemaVersion = 1
  public var action: RunAction
  public var instanceName: String?
  public var match: String
  public var definition: AgentDefinition
  public var source: AgentDefinitionSource
  public var definitionHash: String
  public var adapter: AgentAdapterContract
  public var environment: ResolvedAgentEnvironment
  public var workingDirectory: GuestPath
  public var terminal: AgentTerminalMode
  public var preparationRequired: Bool
  public var egress: EgressMode
  public var proxyMode: ProxyMode
  public var pullMode: WorkspacePullMode
  public var recordedEgress: String?
  public var networkHints: [ExactHostname]
  public var unresolved: [String]
  public var cleanupIntent: String
  public var ask: Bool
  public var blockedReason: String?

  public var json: OutputJSON {
    .object([
      ("schema_version", .int(Int64(Self.schemaVersion))),
      ("kind", .string("run_preview")),
      ("action", .string(action.rawValue)),
      (
        "instance",
        instanceName.map {
          .object([("name", .string($0)), ("match", .string(match))])
        } ?? .null
      ),
      (
        "definition",
        .object([
          ("id", .string(definition.id.rawValue)),
          ("source", .string(source == .builtin ? "builtin" : "installed")),
          ("hash", .string(definitionHash)),
        ])
      ),
      (
        "adapter",
        .object([
          ("id", .string(adapter.id.rawValue)),
          ("contract_version", .int(Int64(adapter.contractVersion))),
        ])
      ),
      (
        "environment",
        .object([
          ("image", .string(environment.image.rawValue)),
          ("profiles", .array(environment.profiles.map(OutputJSON.string))),
          ("origin", .string(environment.origin.rawValue)),
        ])
      ),
      (
        "guest",
        .object([
          ("working_directory", .string(workingDirectory.rawValue)),
          ("terminal", .string(terminal.rawValue)),
        ])
      ),
      ("preparation_required", .bool(preparationRequired)),
      (
        "desired_policy",
        .object([
          ("egress", .string(egress.rawValue)),
          ("proxy_mode", .string(proxyMode.rawValue)),
          ("pull_mode", .string(pullMode.rawValue)),
        ])
      ),
      ("recorded_policy", recordedEgress.map { .object([("egress", .string($0))]) } ?? .null),
      ("approved_hosts", .array([])),
      ("network_hints", .array(networkHints.map { .string($0.rawValue) })),
      ("unresolved", .array(unresolved.map(OutputJSON.string))),
      ("cleanup_intent", .string(cleanupIntent)),
      ("ask", .bool(ask)),
      ("blocked_reason", .optional(blockedReason)),
    ])
  }
}

extension RunPreview {
  public static func make(
    action: RunAction, instanceName: String?, match: String, definition: AgentDefinition,
    source: AgentDefinitionSource, definitionHash: String, adapter: AgentAdapterContract,
    environment: ResolvedAgentEnvironment, workingDirectory: GuestPath, terminal: AgentTerminalMode,
    preparationRequired: Bool, egress: EgressMode, proxyMode: ProxyMode,
    pullMode: WorkspacePullMode,
    recordedEgress: String?, networkHints: [ExactHostname], unresolved: [String],
    cleanupIntent: String,
    ask: Bool, blockedReason: String?
  ) -> RunPreview {
    RunPreview(
      action: action, instanceName: instanceName, match: match, definition: definition,
      source: source,
      definitionHash: definitionHash, adapter: adapter, environment: environment,
      workingDirectory: workingDirectory, terminal: terminal,
      preparationRequired: preparationRequired,
      egress: egress, proxyMode: proxyMode, pullMode: pullMode, recordedEgress: recordedEgress,
      networkHints: networkHints, unresolved: unresolved, cleanupIntent: cleanupIntent, ask: ask,
      blockedReason: blockedReason)
  }
}

public enum SessionSummary {
  /// Compact stderr summary. Every interpolated field is escaped and bounded.
  public static func lines(_ facts: Facts) -> [String] {
    var lines = [
      "Instance: \(bound(facts.instanceName))    Agent: \(bound(facts.displayName))",
      "Definition: \(facts.source) \(bound(facts.definitionID)) \(bound(facts.definitionHash))",
      "Adapter: \(bound(facts.adapterID)) contract \(facts.contractVersion)",
      "Environment: \(bound(facts.image))    Origin: \(facts.environmentOrigin)",
      "Workspace: \(bound(facts.workspace))",
      "Guest directory: \(bound(facts.workingDirectory))    Terminal: \(facts.terminal)",
      "Live host mounts: none",
      "Provider: \(bound(facts.provider))",
      "Raw provider forwarding: \(bound(facts.rawForwarding))",
      "Network: \(facts.egress)    Approved destinations: none (filtered egress is not enabled)",
      "Host services: may remain reachable",
      "Return policy: \(facts.pullMode)",
      "Lifecycle: \(facts.lifecycle)    TTL: \(bound(facts.ttl))",
    ]
    if !facts.networkHints.isEmpty {
      let preview = facts.networkHints.prefix(4).map { bound($0) }.joined(separator: ", ")
      lines.append(
        "Network hints (not approved): \(preview)\(facts.networkHints.count > 4 ? "…" : "")")
    }
    if let warning = facts.rawForwardingWarning {
      lines.append("warning: \(bound(warning))")
    }
    if facts.discardsGuestChanges {
      lines.append("Guest changes: discarded when the agent exits")
    }
    lines.append("This summary is not a live readiness proof.")
    return lines
  }

  public static func bound(_ text: String, limit: Int = 160) -> String {
    let clean = sanitizeForDisplay(text)
    guard clean.unicodeScalars.count > limit else { return clean }
    return String(clean.unicodeScalars.prefix(limit)) + "…"
  }

  public struct Facts: Sendable {
    public var instanceName: String
    public var displayName: String
    public var definitionID: String
    public var definitionHash: String
    public var source: String
    public var adapterID: String
    public var contractVersion: Int
    public var image: String
    public var environmentOrigin: String
    public var workspace: String
    public var workingDirectory: String
    public var terminal: String
    public var provider: String
    public var rawForwarding: String
    public var rawForwardingWarning: String?
    public var egress: String
    public var pullMode: String
    public var lifecycle: String
    public var ttl: String
    public var networkHints: [String]
    public var discardsGuestChanges: Bool

    public init(
      instanceName: String, displayName: String, definitionID: String, definitionHash: String,
      source: String, adapterID: String, contractVersion: Int, image: String,
      environmentOrigin: String, workspace: String, workingDirectory: String, terminal: String,
      provider: String, rawForwarding: String, rawForwardingWarning: String?, egress: String,
      pullMode: String, lifecycle: String, ttl: String, networkHints: [String],
      discardsGuestChanges: Bool
    ) {
      self.instanceName = instanceName
      self.displayName = displayName
      self.definitionID = definitionID
      self.definitionHash = definitionHash
      self.source = source
      self.adapterID = adapterID
      self.contractVersion = contractVersion
      self.image = image
      self.environmentOrigin = environmentOrigin
      self.workspace = workspace
      self.workingDirectory = workingDirectory
      self.terminal = terminal
      self.provider = provider
      self.rawForwarding = rawForwarding
      self.rawForwardingWarning = rawForwardingWarning
      self.egress = egress
      self.pullMode = pullMode
      self.lifecycle = lifecycle
      self.ttl = ttl
      self.networkHints = networkHints
      self.discardsGuestChanges = discardsGuestChanges
    }
  }
}

public struct PhaseTiming: Sendable, Equatable {
  public enum Status: String, Sendable {
    case measured
    case skipped
    case notSeparatelyMeasured = "not-separately-measured"
  }
  public let name: String
  public let status: Status
  public let milliseconds: UInt64?

  public init(name: String, status: Status, milliseconds: UInt64?) {
    self.name = name
    self.status = status
    self.milliseconds = milliseconds
  }

  public var line: String {
    switch status {
    case .measured: "\(name): \(milliseconds ?? 0)ms"
    case .skipped: "\(name): skipped"
    case .notSeparatelyMeasured: "\(name): not separately measured"
    }
  }
}
