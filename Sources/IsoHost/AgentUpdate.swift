import Foundation
import IsoConfiguration
import IsoCore

/// `iso agent update`: refresh the agent binaries inside a running VM
/// without rebuilding the image. Codex is reinstalled as root through its
/// embedded installer wrapper (script on stdin); Claude Code runs its own
/// `claude update` as the guest user.
public enum AgentUpdate {
  public enum Agent: Sendable, Equatable {
    case claude, codex

    public var display: String {
      switch self {
      case .claude: "Claude Code"
      case .codex: "Codex"
      }
    }
  }

  /// No selection means "nothing"; either no flag or both means both.
  public enum Selection: Sendable, Equatable {
    case claude, codex, both

    public init(claude: Bool, codex: Bool) {
      switch (claude, codex) {
      case (true, false): self = .claude
      case (false, true): self = .codex
      default: self = .both
      }
    }

    public var agents: [Agent] {
      switch self {
      case .claude: [.claude]
      case .codex: [.codex]
      case .both: [.claude, .codex]
      }
    }

    public var phrase: String { agents.map(\.display).joined(separator: " and ") }
  }

  /// The `openai/codex` release feed the guest binary is compared against.
  public static let codexRepository = "openai/codex"

  public enum Outcome: Sendable, Equatable {
    case updated(from: SemanticVersion?, to: SemanticVersion)
    case alreadyCurrent(SemanticVersion)
  }

  public enum CheckStatus: Sendable, Equatable {
    case upToDate, updateAvailable, autoUpdates, unknown
  }

  public struct CheckRow: Sendable, Equatable {
    public let agent: Agent
    public let installed: SemanticVersion?
    public let latest: SemanticVersion?
    public let status: CheckStatus
  }

  static func binary(_ agent: Agent, user: GuestUser) -> GuestPath {
    agent == .claude ? user.claudeBinary : GuestBinaries.codex
  }

  /// `<bin> --version` over SSH; nil when absent or unparsable.
  static func installedVersion(_ client: SSHClient, _ session: SSHSession, _ agent: Agent)
    -> SemanticVersion?
  {
    let bin = binary(agent, user: session.target.user)
    guard
      let raw = try? client.captureChecked(
        session.target, RemoteCommand().arg(bin.rawValue).literal(" --version"))
    else { return nil }
    return SemanticVersion.first(in: raw)
  }

  public static func checkStatus(
    _ agent: Agent, installed: SemanticVersion?, latest: SemanticVersion?
  ) -> CheckStatus {
    switch (agent, installed, latest) {
    case (.claude, _, _): .autoUpdates
    case (.codex, let installed?, let latest?): installed < latest ? .updateAvailable : .upToDate
    default: .unknown
    }
  }

  /// `--check`: report only. `latestCodexTag` failing degrades to unknown.
  public static func check(
    _ client: SSHClient, _ session: SSHSession, _ selection: Selection,
    latestCodexTag: () throws -> String, diagnostics: Diagnostics
  ) -> [String] {
    selection.agents.map { agent in
      let installed = installedVersion(client, session, agent)
      var latest: SemanticVersion?
      if agent == .codex {
        do { latest = SemanticVersion.first(in: try latestCodexTag()) } catch {
          diagnostics.debug("Failed to look up latest Codex release: \(oneLineError(error))")
        }
      }
      return checkLine(
        CheckRow(
          agent: agent, installed: installed, latest: latest,
          status: checkStatus(agent, installed: installed, latest: latest)))
    }
  }

  public static func checkLine(_ row: CheckRow) -> String {
    let installed = row.installed?.description ?? "?"
    let (version, note): (String, String) =
      switch row.status {
      case .upToDate: (installed, "up to date")
      case .updateAvailable:
        (
          "\(installed) → \(row.latest?.description ?? "?")",
          "update available — run: iso agent update --codex"
        )
      case .autoUpdates: (installed, "up to date (auto-updates in background)")
      case .unknown: (installed, "could not determine latest version")
      }
    return "\(paddedText(row.agent.display, 12)) \(paddedText(version, 16)) \(note)"
  }

  public static func outcomeLine(_ agent: Agent, _ outcome: Outcome) -> String {
    switch outcome {
    case .updated(let from?, let to): "\(agent.display): updated \(from) → \(to)"
    case .updated(nil, let to): "\(agent.display): updated to \(to)"
    case .alreadyCurrent(let version):
      "\(agent.display): already at the latest version (\(version))"
    }
  }

  /// Update each selected agent, reporting every outcome; fails after all
  /// have run if any failed.
  public static func run(
    _ client: SSHClient, _ session: SSHSession, _ selection: Selection, out: (String) -> Void
  ) throws {
    var failed = false
    for agent in selection.agents {
      do {
        out(outcomeLine(agent, try update(client, session, agent)))
        if agent == .claude { out("  note: Claude Code also auto-updates in the background.") }
      } catch {
        failed = true
        out("\(agent.display): update failed — \(oneLineError(error))")
      }
    }
    if failed { throw HostError("one or more agents failed to update") }
  }

  static func update(_ client: SSHClient, _ session: SSHSession, _ agent: Agent) throws -> Outcome {
    let before = installedVersion(client, session, agent)
    switch agent {
    case .codex:
      do {
        try client.exec(
          session.target,
          RemoteCommand().literal("sudo env GUEST_USER=").arg(session.target.user.rawValue)
            .literal(" ISO_FORCE_INSTALL=1 bash -s"),
          stdin: Array(EmbeddedResources.guestScript("codex.sh").utf8))
      } catch {
        throw ContextError("failed to reinstall \(agent.display)", cause: error)
      }
    case .claude:
      do {
        try client.exec(
          session.target,
          RemoteCommand().arg(binary(agent, user: session.target.user).rawValue).literal(" update"))
      } catch {
        throw ContextError("failed to update \(agent.display)", cause: error)
      }
    }
    guard let after = installedVersion(client, session, agent) else {
      throw HostError(
        "could not read \(agent.display) version after update — the binary may be missing or broken"
      )
    }
    return before == after ? .alreadyCurrent(after) : .updated(from: before, to: after)
  }
}

/// Rust `{:<width$}` on a `&str`.
func paddedText(_ text: String, _ width: Int) -> String {
  let count = text.count
  return count >= width ? text : text + String(repeating: " ", count: width - count)
}

extension SemanticVersion {
  /// Nil unless `text` is a whole SemVer 2.0 version.
  public init?(_ text: String) {
    guard let version = try? SemanticVersion(parsing: text) else { return nil }
    self = version
  }

  /// The first whitespace token that parses: whole (minus a leading `v`),
  /// else the part after its last `v` (`rust-v0.42.0`).
  public static func first(in raw: String) -> SemanticVersion? {
    for token in raw.split(whereSeparator: { $0.isWhitespace }) {
      let stripped = token.hasPrefix("v") ? token.dropFirst() : token
      if let version = SemanticVersion(String(stripped)) { return version }
      if let v = token.lastIndex(of: "v"),
        let version = SemanticVersion(String(token[token.index(after: v)...]))
      {
        return version
      }
    }
    return nil
  }
}
