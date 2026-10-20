// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// Environment variables requested for the guest. Every value is treated as
/// secret (API keys, tokens), so nothing here prints one. A requested name
/// never configures the host: `prepare` moves each value under a generated
/// alias, and a wrapper restores the original name inside the guest.
package struct EnvForward: Sendable, CustomStringConvertible {
  package private(set) var names: [String] = []
  private var values: [String: Secret<String>] = [:]

  package init() {}

  package mutating func set(_ name: String, _ value: Secret<String>) {
    if values[name] == nil { names.append(name) }
    values[name] = value
  }

  package func contains(_ name: String) -> Bool { values[name] != nil }

  package var description: String {
    "EnvForward { vars: {"
      + names.map { "\(debugQuoted($0)): \"<redacted>\"" }.joined(separator: ", ")
      + "} }"
  }

  /// Policy limits, not OpenSSH's: a request over any of them fails before
  /// ssh starts, and nothing is ever truncated.
  static let maxEntries = 64
  static let maxValueBytes = 8 * 1024
  static let maxTotalBytes = 64 * 1024
  static let maxWrapperBytes = 64 * 1024
  static let aliasPrefix = "ISO_SSH_ENV_"

  /// The guest command for `remote` with these variables. `terminal` is the
  /// caller's TERM intent; a normalized TERM replaces a requested one before
  /// encoding, so it still wins as it did before aliasing.
  func prepare(_ remote: String, terminal: GuestTerminal) throws -> PreparedGuestCommand {
    guard !names.isEmpty else { return PreparedGuestCommand(remote: remote, aliases: []) }
    guard names.count <= Self.maxEntries else {
      throw HostError(
        "Refusing to forward \(names.count) guest environment variables (limit \(Self.maxEntries))")
    }
    var total = 0
    var entries: [(name: EnvVarName, value: String)] = []
    for name in names {
      let valid: EnvVarName
      do { valid = try EnvVarName(name) } catch {
        throw HostError("Refusing to forward a guest environment variable: \(error.message)")
      }
      var value = values[name]?.expose() ?? ""
      if name == "TERM", case .normalized(let term) = terminal { value = term }
      guard !value.utf8.contains(0) else {
        throw HostError(
          "Refusing to forward guest environment variable \(name): its value contains NUL")
      }
      guard value.utf8.count <= Self.maxValueBytes else {
        throw HostError(
          "Refusing to forward guest environment variable \(name): its value exceeds \(Self.maxValueBytes) bytes"
        )
      }
      total += name.utf8.count + value.utf8.count
      entries.append((valid, value))
    }
    guard total <= Self.maxTotalBytes else {
      throw HostError(
        "Refusing to forward the guest environment: its names and values exceed \(Self.maxTotalBytes) bytes"
      )
    }
    let aliases = entries.indices.map { "\(Self.aliasPrefix)\($0)" }
    // Every value is captured into a positional parameter before any name is
    // exported, so a requested name that matches an alias, or the saved
    // login shell and command (`$1`, `$2`), cannot disturb the restore.
    // Names are validated `EnvVarName`s and aliases are iso's own, so both
    // are literal shell words; values never appear in the script.
    var script = RemoteCommand()
    for index in entries.indices {
      script = script.literal(index == 0 ? "" : " && ").literal("[ \"${\(3 + 2 * index)}\" = s ]")
    }
    script = script.literal(
      " || { echo 'iso: a forwarded guest environment variable did not arrive (the guest sshd must AcceptEnv ISO_SSH_ENV_*)' >&2; exit 125; }; "
    ).literal("unset \(aliases.joined(separator: " ")); ")
    for (index, entry) in entries.enumerated() {
      script = script.literal(index == 0 ? "" : " && ")
        .literal("export \(entry.name.rawValue)=\"${\(4 + 2 * index)}\"")
    }
    script = script.literal(
      " || { echo 'iso: failed to set a forwarded guest environment variable' >&2; exit 125; }; "
    ).literal("exec \"$2\" -c \"$1\"")
    var wrapper = RemoteCommand().literal("exec /bin/sh -c ").arg(script.rendered)
      .literal(" iso-env ").arg(remote).literal(" \"${SHELL:-/bin/sh}\"")
    for alias in aliases { wrapper = wrapper.literal(" \"${\(alias)+s}\" \"${\(alias)-}\"") }
    guard wrapper.rendered.utf8.count - shellEscape(remote).utf8.count <= Self.maxWrapperBytes
    else {
      throw HostError(
        "Refusing to forward the guest environment: its wrapper exceeds \(Self.maxWrapperBytes) bytes"
      )
    }
    return PreparedGuestCommand(
      remote: wrapper.rendered,
      aliases: zip(aliases, entries).map { ($0, Secret($1.value)) })
  }
}

/// What a guest PTY's TERM should be: the caller's requested value, or iso's
/// normalized host-derived terminal type.
enum GuestTerminal: Sendable, Equatable {
  case requested
  case normalized(String)
}

/// A guest command with its matched wrapper, `SendEnv` options and alias
/// values. Only `EnvForward.prepare` builds one, so the three cannot drift.
struct PreparedGuestCommand: Sendable {
  let remote: String
  private let aliases: [(name: String, value: Secret<String>)]

  fileprivate init(remote: String, aliases: [(String, Secret<String>)]) {
    self.remote = remote
    self.aliases = aliases.map { (name: $0.0, value: $0.1) }
  }

  /// Exactly the generated aliases, nothing a requested name chose.
  var options: [String] { aliases.flatMap { ["-o", "SendEnv=\($0.name)"] } }

  /// The host ssh environment: `base` (an independent host snapshot, kept
  /// even where a guest asked for the same name) with stale aliases removed
  /// and the generated ones added.
  func environment(_ base: [String: String]) -> [String: String] {
    var merged = base.filter { !$0.key.hasPrefix(EnvForward.aliasPrefix) }
    for alias in aliases { merged[alias.name] = alias.value.expose() }
    return merged
  }

  /// The ssh argv and environment, refused before spawning when they would
  /// not fit the host's argument space.
  func launch(
    _ target: SSHTarget, base: [String: String], pty: Bool
  ) throws -> (arguments: [String], environment: [String: String]) {
    // A fixed escape character keeps `Enter ~.` working whatever the
    // user's ssh config says.
    let arguments =
      target.sshOptions + options + (pty ? ["-e", "~", "-t"] : []) + [target.address, remote]
    let environment = environment(base)
    let size =
      arguments.reduce(0) { $0 + $1.utf8.count + 1 }
      + environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 2 }
    guard size <= Self.hostArgumentLimit else {
      throw HostError("Refusing to launch SSH: its arguments and environment exceed the host limit")
    }
    return (arguments, environment)
  }

  /// Half of the host's `ARG_MAX`, leaving room for pointers and the
  /// runner's own additions.
  static var hostArgumentLimit: Int {
    let limit = sysconf(_SC_ARG_MAX)
    return limit > 0 ? limit / 2 : 128 * 1024
  }
}

/// A pinned target plus the environment it forwards.
package struct SSHSession: Sendable {
  package let target: SSHTarget
  package var env: EnvForward

  package init(target: SSHTarget, env: EnvForward = EnvForward()) {
    self.target = target
    self.env = env
  }
}

/// A prepared workload whose original readiness identity is rechecked at launch.
/// Only the host session factory can construct it; bootstrap uses SSHSession.
/// No proof or private signing material is persisted or forwarded to the guest.
package struct WorkloadSession: Sendable {
  fileprivate var session: SSHSession
  fileprivate let revalidate: @Sendable () throws -> Void
  /// How often a running workload re-proves its instance; nil when there is
  /// no live proof to supervise (a vmnet instance without filtered egress).
  fileprivate let supervision: Duration?

  init(
    session: SSHSession, supervision: Duration?,
    revalidate: @escaping @Sendable () throws -> Void
  ) throws {
    try revalidate()
    self.session = session
    self.supervision = supervision
    self.revalidate = revalidate
  }

  /// Spawns the workload's ssh under supervision: while it runs, the proof is
  /// repeated, and a lost proof kills the ssh and its descendants and fails
  /// with that readiness error instead of letting the session outlive it. A
  /// session that ended on its own keeps its result.
  fileprivate func attached(
    _ client: SSHClient, _ request: ProcessRunner.Request, inheritStdin: Bool
  ) throws -> ProcessRunner.Termination {
    guard let supervision else {
      return try client.runner.attached(request, inheritStdin: inheritStdin, deadline: nil)
    }
    let supervisor = SessionSupervisor(revalidate: revalidate, interval: supervision)
    var supervised = request
    supervised.isCancelled = { supervisor.lost }
    let result = Result {
      try client.runner.attached(supervised, inheritStdin: inheritStdin, deadline: nil)
    }
    let failure = supervisor.finish()
    if case .failure = result, let failure, !Shutdown.isRequested {
      throw SessionSupervisor.ended(failure)
    }
    return try result.get()
  }

  package var target: SSHTarget { session.target }
  package var env: EnvForward {
    get { session.env }
    set { session.env = newValue }
  }
}

/// Re-proves a running workload on its own thread until finished, so a slow
/// proof never delays reaping the session. Two consecutive failed proofs end
/// it; one transient probe failure, or a proof briefly in flux while a tunnel
/// is replaced, does not.
final class SessionSupervisor: Sendable {
  /// The production interval for filtered and brokered workloads.
  static let interval: Duration = .seconds(10)

  /// Only a filtered or brokered instance has a live proof to supervise.
  static func interval(for running: AppleBackend.Running) -> Duration? {
    running.hasLiveProof ? interval : nil
  }

  private let state = Mutex<(failure: (any Error)?, finished: Bool)>((nil, false))

  init(revalidate: @escaping @Sendable () throws -> Void, interval: Duration) {
    Thread.detachNewThread { [self] in
      var pending: (any Error)?
      while true {
        let wake = ContinuousClock.now + interval
        while ContinuousClock.now < wake {
          if state.withLock({ $0.finished }) { return }
          usleep(50_000)
        }
        if state.withLock({ $0.finished }) { return }
        do {
          try revalidate()
          pending = nil
        } catch {
          guard pending != nil else {
            pending = error
            continue
          }
          state.withLock { $0.failure = $0.failure ?? error }
          return
        }
      }
    }
  }

  var lost: Bool { state.withLock { $0.failure != nil } }

  /// Stops supervising; the failure that ended the session, if any.
  func finish() -> (any Error)? {
    state.withLock {
      $0.finished = true
      return $0.failure
    }
  }

  static func ended(_ failure: any Error) -> GuestHandoffFailure {
    GuestHandoffFailure(
      cause: ContextError(
        "Ended the guest session: its instance readiness proof no longer holds", cause: failure))
  }
}

extension SSHTarget {
  /// `scp` takes the port as `-P`; `-S` pins the ssh it runs (SSH-01),
  /// so neither `PATH` nor scp's own default chooses it.
  package func scpOptions(ssh: String) -> [String] {
    ["-q", "-S", ssh] + transportOptions + ["-P", String(port)]
  }

  /// rsync's `-e`, serialized for rsync's own tokenizer (whitespace splits;
  /// single quotes group and keep `"` literal) rather than a shell's. A word rsync cannot carry
  /// intact (a `'`, a backslash or a control character) is refused, never mangled.
  func rsyncSSHCommand(ssh: String) throws -> String {
    try ([ssh] + sshOptions).map { word in
      guard
        !word.isEmpty,
        !word.unicodeScalars.contains(where: {
          $0 == "'" || $0 == "\\" || $0.properties.generalCategory == .control
        })
      else { throw HostError("an SSH option cannot be passed to rsync intact") }
      return word.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0 == "\"" })
        ? "'\(word)'" : word
    }.joined(separator: " ")
  }
}

/// Guest commands over the pinned transport. The rendered remote command
/// never carries a secret; those travel on stdin or in forwarded variables.
extension SSHClient {
  func ssh() throws -> String {
    guard let ssh = sshExecutable() else {
      throw HostError("Failed to run SSH command: ssh not found on PATH")
    }
    return ssh
  }

  func request(
    _ executable: String, _ arguments: [String], environment: [String: String]? = nil,
    input: [UInt8]? = nil
  ) -> ProcessRunner.Request {
    .init(
      executable: executable, arguments: arguments, environment: environment ?? self.environment,
      deadline: Self.captureDeadline, input: input)
  }

  /// Output passes through; fails when the remote command does.
  package func exec(_ target: SSHTarget, _ command: RemoteCommand) throws {
    try target.requireHandoff()
    let termination = try runner.attached(
      request(try ssh(), target.sshOptions + [target.address, command.rendered]),
      inheritStdin: true, deadline: nil)
    guard termination.succeeded else { throw HostError("SSH command failed: \(command)") }
  }

  /// Like `exec`, with `env` forwarded.
  package func exec(_ session: SSHSession, _ command: RemoteCommand) throws {
    let launch = try session.env.prepare(command.rendered, terminal: .requested).launch(
      session.target, base: environment, pty: false)
    try session.target.requireHandoff()
    let termination = try runner.attached(
      request(try ssh(), launch.arguments, environment: launch.environment),
      inheritStdin: true, deadline: nil)
    guard termination.succeeded else { throw HostError("SSH command failed: \(command)") }
  }

  /// Like `exec(session:)`, with `stdin` for the remote command: a value
  /// that must not appear on the host argv (or in this error text).
  package func exec(_ session: SSHSession, _ command: RemoteCommand, stdin: [UInt8]) throws {
    let launch = try session.env.prepare(command.rendered, terminal: .requested).launch(
      session.target, base: environment, pty: false)
    try session.target.requireHandoff()
    let termination = try runner.attached(
      request(try ssh(), launch.arguments, environment: launch.environment, input: stdin),
      inheritStdin: false, deadline: nil)
    guard termination.succeeded else { throw HostError("SSH command failed: \(command)") }
  }

  /// `stdin` goes to the remote command (for secrets read with `read -r`).
  package func exec(_ target: SSHTarget, _ command: RemoteCommand, stdin: [UInt8]) throws {
    let ssh = try ssh()
    let arguments = target.sshOptions + [target.address, command.rendered]
    try target.requireHandoff()
    let termination = try runner.attached(
      request(ssh, arguments, input: stdin), inheritStdin: false, deadline: nil)
    guard termination.succeeded else {
      throw ContextError(
        "SSH command failed: \(command)",
        cause: HostError("ssh \(arguments.joined(separator: " ")) exited with \(termination)"))
    }
  }

  /// Whether the command succeeds; output discarded.
  package func succeeds(_ target: SSHTarget, _ command: RemoteCommand) -> Bool {
    (try? succeedsChecked(target, command)) ?? false
  }

  /// Preserve readiness refusal where callers otherwise infer guest state.
  func succeedsChecked(_ target: SSHTarget, _ command: RemoteCommand) throws -> Bool {
    guard let ssh = sshExecutable() else { return false }
    try target.requireHandoff()
    guard
      let output = try? runner.capture(
        request(ssh, target.sshOptions + [target.address, command.rendered]).with(overflow: .drain))
    else { return false }
    return output.termination.succeeded
  }

  package func captureChecked(_ target: SSHTarget, _ command: RemoteCommand) throws -> String {
    try target.requireHandoff()
    let output: ProcessRunner.Output
    do {
      output = try runner.capture(
        request(try ssh(), target.sshOptions + [target.address, command.rendered]))
    } catch {
      throw ContextError("Failed to run SSH command", cause: error)
    }
    guard output.termination.succeeded else {
      throw HostError("SSH command failed: \(command)")
    }
    guard let text = String(validating: output.stdout, as: UTF8.self) else {
      throw HostError("SSH output is not valid UTF-8")
    }
    return text
  }

  package func copy(
    _ target: SSHTarget, local: String, remote: GuestPath, recursive: Bool = false
  ) throws {
    guard let scp = executable(named: "scp") else { throw HostError("Failed to run scp") }
    try target.requireHandoff()
    let termination = try runner.attached(
      request(
        scp,
        target.scpOptions(ssh: try ssh()) + (recursive ? ["-r"] : [])
          + [local, "\(target.address):\(remote)"]),
      inheritStdin: true, deadline: nil)
    guard termination.succeeded else {
      throw HostError("\(recursive ? "scp -r" : "scp") failed: \(local) -> \(remote)")
    }
  }

}

extension ProcessRunner.Termination {
  /// The one exit-status rule for a forwarded workload: its own code, or 1
  /// after a signal, whose code is unknown.
  package var exitStatus: Int32 {
    switch self {
    case .exited(let code): code
    case .signaled: 1
    }
  }
}

/// A guest workload that did not succeed. The CLI exits with `status`: the
/// workload's own code, or 1 after a signal, whose code is unknown.
package struct WorkloadExit: Error, Equatable, CustomStringConvertible {
  package let termination: ProcessRunner.Termination
  /// An interactive session already warned about its status on stderr.
  package let reported: Bool

  package init(_ termination: ProcessRunner.Termination, reported: Bool = false) {
    self.termination = termination
    self.reported = reported
  }

  /// Never 0: a `WorkloadExit` is a failure.
  package var status: Int32 { termination.succeeded ? 1 : termination.exitStatus }

  package var description: String {
    switch termination {
    case .exited(let code): "Remote command exited with status \(code)"
    case .signaled(let signal): "Remote command ended by signal \(signal); its status is unknown"
    }
  }
}

/// `iso shell`, `claude`, `codex` and `exec`: the user's own sessions. A
/// session that does not succeed throws `WorkloadExit`, except
/// `runReporting`, which returns the termination to `iso run`.
package enum InteractiveSSH {
  /// Empty `command` opens a login shell at `/workspace`.
  package static func render(_ command: [String]) -> String {
    command.isEmpty
      ? "cd /workspace && exec $SHELL -l"
      : "cd /workspace && " + command.map(shellEscape).joined(separator: " ")
  }

  /// A TERM a stock Ubuntu guest has terminfo for.
  package static func guestTerm(_ environment: [String: String]) -> String {
    let term = environment["TERM"] ?? ""
    return ["xterm", "xterm-256color", "screen", "vt100"].contains(term) ? term : "xterm-256color"
  }

  /// Guest command in `workingDirectory`. A missing directory fails the
  /// remote `cd`; nothing is created on the host or in the guest.
  package static func remote(_ command: [String], workingDirectory: GuestPath) -> String {
    "cd \(shellEscape(workingDirectory.rawValue)) && "
      + command.map(shellEscape).joined(separator: " ")
  }

  /// The one launch path behind every wrapper: revalidates the workload,
  /// then runs ssh under its supervision. With a PTY the guest gets a TERM it
  /// has terminfo for, and a launch that throws restores the terminal.
  /// With `audit`, the handoff and the observed transport outcome are
  /// recorded for that invocation (names only, never values or argv).
  private static func attach(
    _ client: SSHClient, _ workload: WorkloadSession, remote: String, inheritStdin: Bool,
    allocatePTY: Bool, missingSSH: String, audit: AuditInvocation? = nil
  ) throws -> ProcessRunner.Termination {
    let session = workload.session
    guard let ssh = client.sshExecutable() else { throw HostError(missingSSH) }
    let term = guestTerm(client.environment)
    var launch = try session.env.prepare(
      remote, terminal: allocatePTY ? .normalized(term) : .requested
    ).launch(session.target, base: client.environment, pty: allocatePTY)
    // ssh sends its own TERM in the PTY request.
    if allocatePTY { launch.environment["TERM"] = term }
    do { try workload.revalidate() } catch {
      audit?.revalidationFailed()
      throw error
    }
    audit?.handoff(pty: allocatePTY, forwarded: session.env.names)
    do {
      let termination = try workload.attached(
        client, client.request(ssh, launch.arguments, environment: launch.environment),
        inheritStdin: inheritStdin)
      audit?.transportEnded(termination)
      return termination
    } catch {
      audit?.transportFailed(.sessionError)
      if allocatePTY { restoreTerminal(client) }
      throw error
    }
  }

  private static let missingInteractiveSSH = "Failed to launch SSH — is the ssh client installed?"

  /// Like `run`, but returns the ssh status and can skip the PTY. Used by
  /// `iso run` so agent and cleanup outcomes stay distinguishable.
  package static func runReporting(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String],
    workingDirectory: GuestPath, allocatePTY: Bool, diagnostics: Diagnostics,
    audit: AuditInvocation? = nil
  ) throws -> ProcessRunner.Termination {
    let target = workload.session.target
    let remote = Self.remote(command, workingDirectory: workingDirectory)
    diagnostics.log(.info, "Connecting via SSH to \(target.endpointDescription) (\(remote))")
    let termination = try attach(
      client, workload, remote: remote, inheritStdin: true, allocatePTY: allocatePTY,
      missingSSH: missingInteractiveSSH, audit: audit)
    if allocatePTY && !termination.succeeded { restoreTerminal(client) }
    return termination
  }

  /// With a PTY; a failed session leaves the terminal restored.
  package static func run(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String], diagnostics: Diagnostics,
    audit: AuditInvocation? = nil
  ) throws {
    let target = workload.session.target
    let remote = render(command)
    diagnostics.log(.info, "Connecting via SSH to \(target.endpointDescription) (\(remote))")
    diagnostics.log(
      .info,
      "If the remote session stops responding, type Enter, then ~. to disconnect; run `stty sane` if your terminal remains broken."
    )
    let termination = try attach(
      client, workload, remote: remote, inheritStdin: true, allocatePTY: true,
      missingSSH: missingInteractiveSSH, audit: audit)
    if !termination.succeeded {
      diagnostics.warn("SSH session exited with status: \(termination)")
      restoreTerminal(client)
      throw WorkloadExit(termination, reported: true)
    }
  }

  package static func runCommand(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String], diagnostics: Diagnostics
  ) throws {
    let remote = command.map(shellEscape).joined(separator: " ")
    diagnostics.log(.info, "Running (non-interactive): \(remote)")
    let termination = try attach(
      client, workload, remote: remote, inheritStdin: true, allocatePTY: false,
      missingSSH: "Failed to launch SSH")
    guard termination.succeeded else { throw WorkloadExit(termination) }
  }

  /// `iso exec`: output passes through; stdin is `/dev/null` (a loop reading
  /// its own input keeps it); a failure carries the remote code.
  package static func exec(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String], diagnostics: Diagnostics
  ) throws {
    let remote = command.map(shellEscape).joined(separator: " ")
    diagnostics.debug("exec: \(remote)")
    let termination = try attach(
      client, workload, remote: remote, inheritStdin: false, allocatePTY: false,
      missingSSH: "Failed to launch SSH")
    guard termination.succeeded else { throw WorkloadExit(termination) }
  }

  /// A remote TUI killed mid-session leaves raw mode and the alternate
  /// screen behind; undo both. No-op unless stdout is a terminal.
  static func restoreTerminal(_ client: SSHClient) {
    guard isatty(1) == 1 else { return }
    FileHandle.standardOutput.write(Data("\u{1b}[?1049l\u{1b}[?25h\u{1b}[?7h\u{1b}[0m".utf8))
    _ = try? client.runner.attached(
      .init(
        executable: "/bin/stty", arguments: ["sane"], environment: client.environment,
        deadline: .seconds(10)), inheritStdin: true, deadline: nil)
  }
}

extension ProcessRunner.Request {
  func with(overflow: ProcessRunner.OverflowPolicy) -> Self {
    var copy = self
    copy.overflow = overflow
    return copy
  }
}
