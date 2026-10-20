import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy

/// Host-owned metadata about what crossed an instance's boundary
/// (selective-hardening spec §9): which host capabilities a boot granted and
/// what workspace returns happened. Never values, request bodies, file
/// contents or tokens — only names, counts, modes and times. One JSON object
/// per line in `<instance>/audit.jsonl` (owner-only), bounded in size; each
/// event also goes to the instance-independent `AuditStore`.
package enum BoundaryAudit {
  package static let maxBytes = 1 << 20

  package enum Event: Sendable, Equatable {
    /// `up`/`start`: the policy the boot ran under and what it granted.
    case boot(
      egress: EgressMode, proxyMode: ProxyMode, proxied: [ProxyProvider],
      providerSecrets: [String], guestReferences: Int, sessionTTL: SessionTTL?)
    /// Recognized provider variables forwarded into the guest raw.
    case rawProviderForward([String])
    case stop
    case pullStage(
      changes: Int, bytes: UInt64, applicable: Bool, stageID: String = "", sensitive: Int = 0,
      excluded: UInt64 = 0)
    case pullApply(applied: Int)
    /// A return refused or held with its whole stage kept (RET-09).
    case pullHeld(stageID: String, reason: String)
    /// An outbound selected-content snapshot (INPUT-01): counts only.
    case inputSnapshot(
      snapshotID: String, selected: Int, bytes: UInt64, secretsOmitted: Int, otherOmitted: Int,
      deletedTracked: Int)
    /// An instance fenced after an unconfirmed restart cleanup (LIFE-01).
    case handoffFence(reason: String)
    case pullDirect
    /// The immutable policy binding recorded for a new VM boot.
    case policyBoot(mode: PolicyMode, digest: String?, epoch: String, actions: [PolicyAction])
    /// A proxy launch slot claimed, refused, or (shadow) re-simulated.
    case policyProxyClaim(provider: ProxyProvider, generation: String, outcome: ClaimOutcome)
    /// A host-side policy decision on a governed operation (or a shadow report).
    case policyDecision(
      action: PolicyAction, outcome: DecisionOutcome, decisionID: String, digest: String?,
      shadow: Bool)
    case approvalIssued(approvalID: String, stageID: String)
    case approvalConsumed(approvalID: String, reason: PolicyReason)
    /// A stage apply that stopped partway; the receipt stays consumed.
    case pullApplyPartial(applied: Int)

    package enum ClaimOutcome: String, Sendable, Equatable {
      case claimed, refused, shadow
    }

    /// Why shadow mode could not evaluate an operation.
    package enum ShadowUnavailable: String, Sendable, Equatable {
      case notStaged = "not_staged"
      case unsupportedPath = "unsupported_path"
    }

    package enum DecisionOutcome: Sendable, Equatable {
      case decided(PolicyVerdict, PolicyReason)
      case shadowUnavailable(ShadowUnavailable)

      var verdict: String {
        switch self {
        case .decided(let verdict, _): verdict.rawValue
        case .shadowUnavailable: "shadow_unavailable"
        }
      }
      var reason: String {
        switch self {
        case .decided(_, let reason): reason.rawValue
        case .shadowUnavailable(let why): why.rawValue
        }
      }
    }

    var kind: String {
      switch self {
      case .boot: "boot"
      case .rawProviderForward: "raw_provider_forward"
      case .stop: "stop"
      case .pullStage: "pull_stage"
      case .pullApply: "pull_apply"
      case .pullDirect: "pull_direct"
      case .policyBoot: "policy_boot"
      case .policyProxyClaim: "policy_proxy_claim"
      case .policyDecision: "policy_decision"
      case .approvalIssued: "approval_issued"
      case .approvalConsumed: "approval_consumed"
      case .pullApplyPartial: "pull_apply_partial"
      case .pullHeld: "pull_held"
      case .inputSnapshot: "input_snapshot"
      case .handoffFence: "handoff_fence"
      }
    }

    func json(at time: Date) -> OutputJSON {
      var members: [(String, OutputJSON)] = [
        ("time", .string(ISO8601DateFormatter().string(from: time))), ("event", .string(kind)),
      ]
      switch self {
      case .boot(let egress, let proxyMode, let proxied, let secrets, let references, let ttl):
        members += [
          ("egress", .string(egress.rawValue)), ("proxy_mode", .string(proxyMode.rawValue)),
          ("proxied", .array(proxied.map { .string($0.rawValue) })),
          ("provider_secrets", .array(secrets.sorted().map(OutputJSON.string))),
          ("guest_references", .uint(UInt64(references))),
          ("session_ttl_seconds", ttl.map { .uint(UInt64($0.seconds)) } ?? .null),
        ]
      case .rawProviderForward(let names):
        members.append(("variables", .array(names.sorted().map(OutputJSON.string))))
      case .stop, .pullDirect: break
      case .pullStage(
        let changes, let bytes, let applicable, let stageID, let sensitive, let excluded):
        members += [
          ("changes", .uint(UInt64(changes))), ("staged_bytes", .uint(bytes)),
          ("applicable", .bool(applicable)),
        ]
        if !stageID.isEmpty {
          members += [
            ("stage_id", .string(stageID)), ("sensitive", .uint(UInt64(sensitive))),
            ("excluded", .uint(excluded)),
          ]
        }
      case .pullHeld(let stageID, let reason):
        members += [("stage_id", .string(stageID)), ("reason", .string(reason))]
      case .inputSnapshot(
        let snapshotID, let selected, let bytes, let secrets, let other, let deleted):
        members += [
          ("snapshot_id", .string(snapshotID)), ("classifier", .string(LocalSecretNames.version)),
          ("selected", .uint(UInt64(selected))), ("bytes", .uint(bytes)),
          ("secrets_omitted", .uint(UInt64(secrets))), ("other_omitted", .uint(UInt64(other))),
          ("deleted_tracked", .uint(UInt64(deleted))),
        ]
      case .handoffFence(let reason):
        members.append(("reason", .string(reason)))
      case .pullApply(let applied), .pullApplyPartial(let applied):
        members.append(("applied", .uint(UInt64(applied))))
      case .policyBoot(let mode, let digest, let epoch, let actions):
        members += [
          ("mode", .string(mode.rawValue)), ("digest", digest.map(OutputJSON.string) ?? .null),
          ("epoch", .string(epoch)), ("actions", .array(actions.map { .string($0.rawValue) })),
        ]
      case .policyProxyClaim(let provider, let generation, let outcome):
        members += [
          ("provider", .string(provider.rawValue)), ("generation", .string(generation)),
          ("outcome", .string(outcome.rawValue)),
        ]
      case .policyDecision(let action, let outcome, let decisionID, let digest, let shadow):
        members += [
          ("action", .string(action.rawValue)), ("verdict", .string(outcome.verdict)),
          ("reason", .string(outcome.reason)), ("decision_id", .string(decisionID)),
          ("digest", digest.map(OutputJSON.string) ?? .null), ("shadow", .bool(shadow)),
        ]
      case .approvalIssued(let approvalID, let stageID):
        members += [("approval_id", .string(approvalID)), ("stage_id", .string(stageID))]
      case .approvalConsumed(let approvalID, let reason):
        members += [("approval_id", .string(approvalID)), ("reason", .string(reason.rawValue))]
      }
      return .object(members)
    }
  }

  package static func path(_ instance: Instance) -> String { instance.directory + "/audit.jsonl" }

  /// Best effort: an audit failure never fails the operation it describes.
  /// Events append under a lock, so concurrent iso processes lose none.
  /// Past `maxBytes` the older half of the log is dropped; if the log cannot
  /// be read for that, the new event is dropped rather than the history.
  package static func record(
    _ instance: Instance, _ event: Event, now: Date = Date(), diagnostics: Diagnostics? = nil
  ) {
    let line = Array((event.json(at: now).compactRendered() + "\n").utf8)
    let path = path(instance)
    do {
      let lock = try FileLock.sibling(of: path)
      defer { lock.release() }
      var size = stat()
      if lstat(path, &size) == 0, Int(size.st_size) + line.count > maxBytes {
        let existing = try readAll(path)
        let keep = Array(existing.suffix(maxBytes / 2).drop(while: { $0 != 0x0A }).dropFirst())
        try AtomicFile.write(keep, to: path, mode: .atMost(0o600))
      }
      let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard fd >= 0 else { throw HostError.posix("Failed to open", path) }
      defer { close(fd) }
      try StageBuilder.writeAll(fd, line, path: path)
    } catch {
      diagnostics?.debug("boundary audit write failed (non-fatal): \(error)")
    }
    recordAudit(instance, event, now: now, diagnostics: diagnostics)
  }

  static func readAll(_ path: String) throws -> [UInt8] {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw HostError.posix("Failed to open", path) }
    defer { close(fd) }
    return try StateStore.readBounded(
      fd, path: path, limit: maxBytes * 2, tooLarge: "\(path) is too large")
  }

  package static func lines(_ instance: Instance) throws -> [String] {
    guard FileManager.default.fileExists(atPath: path(instance)) else { return [] }
    return String(decoding: try readAll(path(instance)), as: UTF8.self)
      .split(separator: "\n").map(String.init)
  }

  /// The recorded events, oldest first. Lines that do not parse are skipped.
  package static func load(_ instance: Instance) throws -> [[String: Any]] {
    events(from: try lines(instance))
  }

  /// Parses recorded lines, so one read can serve both the events and the
  /// text of a log that other processes may be appending to.
  package static func events(from lines: [String]) -> [[String: Any]] {
    lines.compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
  }

  /// An advisory JSONC fragment from the recorded events. Deterministic for
  /// a given event list; it only narrows what was observed and never
  /// suggests wider authority.
  package static func suggestConfig(_ events: [[String: Any]]) -> [String] {
    let boots = events.filter { $0["event"] as? String == "boot" }
    let rawForwards = events.contains { $0["event"] as? String == "raw_provider_forward" }
    let proxied = Set(boots.flatMap { ($0["proxied"] as? [String]) ?? [] })
    let everyBootProxied =
      !boots.isEmpty && boots.allSatisfy { !(($0["proxied"] as? [String]) ?? []).isEmpty }
    let staged = events.contains { $0["event"] as? String == "pull_stage" }
    let direct = events.contains { $0["event"] as? String == "pull_direct" }
    var lines = [
      "// Suggested by `iso audit --suggest-config` from \(boots.count) recorded boot(s).",
      "// Advisory only: an observed run does not prove what future runs need.",
      "{",
    ]
    var members: [(text: String, isReal: Bool)] = []
    if everyBootProxied && !rawForwards {
      members.append(
        (
          "  // Every boot used the credential proxy (\(proxied.sorted().joined(separator: ", "))) and none forwarded a raw provider key.\n  \"proxy\": { \"mode\": \"required\" }",
          true
        ))
    } else if rawForwards || !proxied.isEmpty {
      members.append(
        (
          "  // Not every boot kept provider keys on the host; store them with `iso proxy setup` or `iso secrets`, then consider \"required\".\n  // \"proxy\": { \"mode\": \"required\" }",
          false
        ))
    }
    if boots.allSatisfy({ $0["egress"] as? String == "none" }) && !boots.isEmpty {
      members.append(("  // Every boot ran without egress.\n  \"egress\": \"none\"", true))
    } else {
      members.append(
        (
          "  // Guest network use is not observed; try \"none\" and watch for failures.\n  // \"egress\": \"none\"",
          false
        ))
    }
    if staged || direct {
      members.append(
        (
          "  // Workspace returns happened; review them before they reach the host.\n  \"workspace\": { \"pull\": { \"mode\": \"stage\" } }",
          true
        ))
    }
    // A comma follows a real member only when another real member comes
    // after it; commented-out members never carry one.
    for (index, member) in members.enumerated() {
      let moreReal = members[(index + 1)...].contains { $0.isReal }
      lines.append(member.isReal && moreReal ? member.text + "," : member.text)
    }
    lines.append("}")
    return lines
  }
}
