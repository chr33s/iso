import Foundation
import IsoConfiguration
import IsoCore

package enum RunAction: String, Sendable, Equatable {
  case create
  case restart
  case attach
  case blocked
  case unresolved
}

/// Versioned dry-run document. It is not a live readiness proof and contains
/// no credentials, capabilities, or caller passthrough arguments.
package struct RunPreview: Sendable, Equatable, Encodable {
  package static let schemaVersion = 1
  package var action: RunAction
  package var instanceName: String?
  package var match: String
  package var definition: AgentDefinition
  package var source: AgentDefinitionSource
  package var definitionHash: String
  package var adapter: AgentAdapterContract
  package var environment: ResolvedAgentEnvironment
  package var workingDirectory: GuestPath
  package var terminal: AgentTerminalMode
  package var preparationRequired: Bool
  package var egress: EgressMode
  package var proxyMode: ProxyMode
  package var pullMode: WorkspacePullMode
  package var recordedEgress: String?
  package var networkHints: [ExactHostname]
  package var unresolved: [String]
  package var cleanupIntent: String
  package var ask: Bool
  package var blockedReason: String?

  enum CodingKeys: String, CodingKey {
    case kind, action, instance, definition, adapter, environment, guest, unresolved, ask
    case schemaVersion = "schema_version"
    case preparationRequired = "preparation_required"
    case desiredPolicy = "desired_policy"
    case recordedPolicy = "recorded_policy"
    case approvedHosts = "approved_hosts"
    case networkHints = "network_hints"
    case cleanupIntent = "cleanup_intent"
    case blockedReason = "blocked_reason"
  }

  private struct InstanceOutput: Encodable {
    let name: String
    let match: String
  }
  private struct DefinitionOutput: Encodable {
    let id: String
    let source: String
    let hash: String
  }
  private struct AdapterOutput: Encodable {
    let id: String
    let contractVersion: Int
    enum CodingKeys: String, CodingKey {
      case id
      case contractVersion = "contract_version"
    }
  }
  private struct EnvironmentOutput: Encodable {
    let image: String
    let profiles: [String]
    let origin: String
  }
  private struct GuestOutput: Encodable {
    let workingDirectory: String
    let terminal: String
    enum CodingKeys: String, CodingKey {
      case terminal
      case workingDirectory = "working_directory"
    }
  }
  private struct PolicyOutput: Encodable {
    let egress: String
    let proxyMode: String
    let pullMode: String
    enum CodingKeys: String, CodingKey {
      case egress
      case proxyMode = "proxy_mode"
      case pullMode = "pull_mode"
    }
  }
  private struct RecordedPolicyOutput: Encodable { let egress: String }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(Self.schemaVersion, forKey: .schemaVersion)
    try values.encode("run_preview", forKey: .kind)
    try values.encode(action.rawValue, forKey: .action)
    try values.encode(
      instanceName.map { InstanceOutput(name: $0, match: match) }, forKey: .instance)
    try values.encode(
      DefinitionOutput(
        id: definition.id.rawValue,
        source: source == .builtin ? "builtin" : "installed", hash: definitionHash),
      forKey: .definition)
    try values.encode(
      AdapterOutput(
        id: adapter.id.rawValue,
        contractVersion: Int(adapter.contractVersion)), forKey: .adapter)
    try values.encode(
      EnvironmentOutput(
        image: environment.image.rawValue,
        profiles: environment.profiles, origin: environment.origin.rawValue), forKey: .environment)
    try values.encode(
      GuestOutput(
        workingDirectory: workingDirectory.rawValue,
        terminal: terminal.rawValue), forKey: .guest)
    try values.encode(preparationRequired, forKey: .preparationRequired)
    try values.encode(
      PolicyOutput(
        egress: egress.rawValue, proxyMode: proxyMode.rawValue,
        pullMode: pullMode.rawValue), forKey: .desiredPolicy)
    try values.encode(
      recordedEgress.map { RecordedPolicyOutput(egress: $0) }, forKey: .recordedPolicy)
    try values.encode([String](), forKey: .approvedHosts)
    try values.encode(networkHints.map(\.rawValue), forKey: .networkHints)
    try values.encode(unresolved, forKey: .unresolved)
    try values.encode(cleanupIntent, forKey: .cleanupIntent)
    try values.encode(ask, forKey: .ask)
    try values.encode(blockedReason, forKey: .blockedReason)
  }

}

extension RunPreview {
  package static func make(
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

package enum SessionSummary {
  /// Compact stderr summary. Every interpolated field is escaped and bounded.
  package static func lines(_ facts: Facts) -> [String] {
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

  package static func bound(_ text: String, limit: Int = 160) -> String {
    let clean = sanitizeForDisplay(text)
    guard clean.unicodeScalars.count > limit else { return clean }
    return String(clean.unicodeScalars.prefix(limit)) + "…"
  }

  package struct Facts: Sendable {
    package var instanceName: String
    package var displayName: String
    package var definitionID: String
    package var definitionHash: String
    package var source: String
    package var adapterID: String
    package var contractVersion: Int
    package var image: String
    package var environmentOrigin: String
    package var workspace: String
    package var workingDirectory: String
    package var terminal: String
    package var provider: String
    package var rawForwarding: String
    package var rawForwardingWarning: String?
    package var egress: String
    package var pullMode: String
    package var lifecycle: String
    package var ttl: String
    package var networkHints: [String]
    package var discardsGuestChanges: Bool

    package init(
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

package struct PhaseTiming: Sendable, Equatable {
  package enum Status: String, Sendable {
    case measured
    case skipped
    case notSeparatelyMeasured = "not-separately-measured"
  }
  package let name: String
  package let status: Status
  package let milliseconds: UInt64?

  package init(name: String, status: Status, milliseconds: UInt64?) {
    self.name = name
    self.status = status
    self.milliseconds = milliseconds
  }

  package var line: String {
    switch status {
    case .measured: "\(name): \(milliseconds ?? 0)ms"
    case .skipped: "\(name): skipped"
    case .notSeparatelyMeasured: "\(name): not separately measured"
    }
  }
}
