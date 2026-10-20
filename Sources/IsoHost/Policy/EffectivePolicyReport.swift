import Foundation
import IsoConfiguration
import IsoCore

/// The read-only effective-policy and migration report (POL-01, MIG-01):
/// what the configuration requests, what an instance recorded at creation
/// and since, and every relaxation from the secure-default baseline. It
/// reads host files only: it resolves no secret, runs no credential command,
/// contacts no provider, and never starts, changes or audits anything.
/// Unreadable evidence is reported as unknown.
package enum EffectivePolicyReport {
  /// The DEF-01 baseline each requested value is compared with.
  static let baselineTTL: UInt32 = 8 * 3600

  package static func json(_ config: IsoConfig, instance: Instance?) -> OutputJSON {
    var members: [(String, OutputJSON)] = [
      ("requested", requested(config)),
      ("relaxations", .array(relaxations(config).map(OutputJSON.string))),
    ]
    if let instance { members.append(("instance", recorded(config, instance))) }
    return .object(members)
  }

  static func imports(_ directory: ConfigDirectory) -> String {
    switch directory {
    case .disabled: "disabled"
    case .default: "agent home"
    case .custom(let path): path.path
    }
  }

  static func requested(_ config: IsoConfig) -> OutputJSON {
    .object([
      ("transport", .string(config.network.transport.rawValue)),
      ("security_preset", config.securityPreset.map { .string($0.rawValue) } ?? .null),
      ("egress", .string(config.egress.rawValue)),
      ("proxy_mode", .string(config.proxy.mode.rawValue)),
      ("return_mode", .string(config.workspacePull.mode.rawValue)),
      ("input_mode", .string(config.workspaceInput.mode.rawValue)),
      ("claude_imports", .string(imports(config.claude.configDirectory))),
      ("codex_imports", .string(imports(config.codex.configDirectory))),
      ("github", .string(config.github?.modeName ?? "off")),
      ("editor", .string(config.editor.security.rawValue)),
      ("editor_allow", .array(config.editor.allow.map { .string($0.rawValue) })),
      // Null means no boot lifetime ("unlimited").
      ("session_ttl_seconds", config.limits.sessionTTL.map { .uint(UInt64($0.seconds)) } ?? .null),
    ])
  }

  /// Every requested value weaker than the baseline, in plain words.
  static func relaxations(_ config: IsoConfig) -> [String] {
    var out: [String] = []
    if config.network.transport == .vmnet {
      out.append("network.transport vmnet: the guest has a NIC on the host's vmnet network")
    }
    if config.egress != .none {
      out.append("egress \(config.egress.rawValue): the guest may reach the network")
    }
    if config.proxy.mode != .required {
      out.append("proxy.mode \(config.proxy.mode.rawValue): provider keys may reach the guest")
    }
    if config.workspacePull.mode == .direct {
      out.append("workspace.pull.mode direct: additions apply without a separate review")
    }
    for (agent, directory) in [
      ("claude", config.claude.configDirectory), ("codex", config.codex.configDirectory),
    ]
    where directory != .disabled {
      out.append("\(agent).config_dir: host agent settings are imported (\(imports(directory)))")
    }
    if let github = config.github, github != .off {
      out.append("github \(github.modeName): host GitHub credentials may be used")
    }
    if config.editor.security != .sandboxed || !config.editor.allow.isEmpty {
      out.append("editor: host editor capabilities beyond the sandbox")
    }
    if let ttl = config.limits.sessionTTL {
      if ttl.seconds > baselineTTL {
        out.append("limits.session_ttl \(ttl): longer than the 8h baseline")
      }
    } else {
      out.append("limits.session_ttl: no boot lifetime")
    }
    return out
  }

  static func recorded(_ config: IsoConfig, _ instance: Instance) -> OutputJSON {
    var members: [(String, OutputJSON)] = [("name", .string(instance.name.rawValue))]
    var conflicts: [String] = []
    // A field whose record cannot be read is null and named in `unknown`, so
    // every field keeps one JSON type.
    var unknown: [String] = []
    do {
      if let policy = try NetworkPolicy.load(instance) {
        members += [
          ("transport", .string(policy.recordedTransport.rawValue)),
          ("egress", .string(policy.mode)),
        ]
        if policy.recordedTransport != config.network.transport {
          conflicts.append(
            "transport is fixed at \(policy.recordedTransport.rawValue); the configuration requests \(config.network.transport.rawValue)"
          )
        }
        if policy.mode != config.egress.rawValue {
          conflicts.append(
            "egress is fixed at \(policy.mode) for this VM; the configuration requests \(config.egress.rawValue)"
          )
        }
      } else {
        members += [("transport", .null), ("egress", .null)]
        unknown += ["transport", "egress"]
      }
    } catch {
      members += [("transport", .null), ("egress", .null)]
      unknown += ["transport", "egress"]
      conflicts.append("the network policy record is unreadable or corrupt")
    }
    do {
      let names = try GuestEnvState.tryLoad(instance)?.entries.keys.map(\.rawValue).sorted() ?? []
      members.append(("saved_environment", .array(names.map(OutputJSON.string))))
    } catch {
      members.append(("saved_environment", .null))
      unknown.append("saved_environment")
    }
    do {
      members.append(
        ("saved_forwards", .uint(UInt64((try PortForwards.load(instance) ?? []).count))))
    } catch {
      members.append(("saved_forwards", .null))
      unknown.append("saved_forwards")
    }
    do {
      let ledger = try GrantLedger.load(instance)
      members.append(
        (
          "grants",
          .array(
            ledger.grants.map { grant in
              .string(
                "\(grant.id) \(grant.capability.rawValue) \(grant.scope) (\(grant.origin.rawValue))"
              )
            })
        ))
      let pending = config.revokedGrantIDs.filter { id in ledger.grants.contains { $0.id == id } }
      members.append(("pending_revocations", .array(pending.map(OutputJSON.string))))
      members.append(("revoked", .array(ledger.revoked.map(OutputJSON.string))))
    } catch {
      members += [("grants", .null), ("pending_revocations", .null), ("revoked", .null)]
      unknown += ["grants", "pending_revocations", "revoked"]
      conflicts.append("the grant ledger is unreadable or corrupt")
    }
    members.append(
      ("fenced", .bool(FileManager.default.fileExists(atPath: HandoffFence.path(instance)))))
    members.append(("retained_stage", .bool(StageLocation(instance).exists)))
    members.append(("unknown", .array(unknown.map(OutputJSON.string))))
    members.append(("conflicts", .array(conflicts.map(OutputJSON.string))))
    return .object(members)
  }

  package static func text(_ report: OutputJSON) -> [String] {
    guard case .object(let members) = report else { return [] }
    let fields = Dictionary(members, uniquingKeysWith: { a, _ in a })
    var lines: [String] = []
    if case .object(let requested) = fields["requested"] {
      lines.append("Requested:")
      for (key, value) in requested {
        let text = key == "session_ttl_seconds" && value == .null ? "unlimited" : render(value)
        lines.append("  \(key): \(text)")
      }
    }
    if case .array(let relaxations) = fields["relaxations"] {
      lines.append(relaxations.isEmpty ? "Relaxations: none" : "Relaxations:")
      for case .string(let item) in relaxations { lines.append("  - \(item)") }
    }
    if case .object(let instance) = fields["instance"] {
      lines.append("Recorded:")
      for (key, value) in instance where key != "unknown" {
        lines.append("  \(key): \(value == .null ? "unknown" : render(value))")
      }
    }
    return lines
  }

  static func render(_ value: OutputJSON) -> String {
    switch value {
    case .string(let text): text
    case .array(let items): items.isEmpty ? "[]" : items.map(render).joined(separator: ", ")
    case .null: "-"
    default: value.compactRendered()
    }
  }
}
