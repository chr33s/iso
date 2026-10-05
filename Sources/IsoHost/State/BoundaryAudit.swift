import Foundation
import IsoConfiguration
import IsoCore

/// Host-owned metadata about what crossed an instance's boundary
/// (selective-hardening spec §9): which host capabilities a boot granted and
/// what workspace returns happened. Never values, request bodies, file
/// contents or tokens — only names, counts, modes and times. One JSON object
/// per line in `<instance>/audit.jsonl` (owner-only), bounded in size.
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
    case pullStage(changes: Int, bytes: UInt64, applicable: Bool)
    case pullApply(applied: Int)
    case pullDirect

    var kind: String {
      switch self {
      case .boot: "boot"
      case .rawProviderForward: "raw_provider_forward"
      case .stop: "stop"
      case .pullStage: "pull_stage"
      case .pullApply: "pull_apply"
      case .pullDirect: "pull_direct"
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
      case .pullStage(let changes, let bytes, let applicable):
        members += [
          ("changes", .uint(UInt64(changes))), ("staged_bytes", .uint(bytes)),
          ("applicable", .bool(applicable)),
        ]
      case .pullApply(let applied): members.append(("applied", .uint(UInt64(applied))))
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
