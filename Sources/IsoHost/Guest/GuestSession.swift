// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// Environment variables forwarded to the guest with `SendEnv`: names go
/// on the ssh argv, values only into ssh's own environment. Every value is
/// treated as secret (API keys, tokens), so nothing here prints one.
package struct EnvForward: Sendable, CustomStringConvertible {
  package private(set) var names: [String] = []
  private var values: [String: Secret<String>] = [:]

  package init() {}

  package mutating func set(_ name: String, _ value: Secret<String>) {
    if values[name] == nil { names.append(name) }
    values[name] = value
  }

  package func contains(_ name: String) -> Bool { values[name] != nil }

  package var sendEnvOptions: [String] { names.flatMap { ["-o", "SendEnv=\($0)"] } }

  /// Added to ssh's own environment only.
  func overlay(_ environment: [String: String]) -> [String: String] {
    var merged = environment
    for name in names { merged[name] = values[name]?.expose() }
    return merged
  }

  package var description: String {
    "EnvForward { vars: {"
      + names.map { "\(debugQuoted($0)): \"<redacted>\"" }.joined(separator: ", ")
      + "} }"
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

  package var sshOptions: [String] { target.sshOptions + env.sendEnvOptions }
}

/// A prepared workload whose original readiness identity is rechecked at launch.
/// Only the host session factory can construct it; bootstrap uses SSHSession.
/// No proof or private signing material is persisted or forwarded to the guest.
package struct WorkloadSession: Sendable {
  fileprivate var session: SSHSession
  fileprivate let revalidate: @Sendable () throws -> Void
  /// How often a running workload re-proves its instance; nil when there is
  /// no live proof to supervise (a nonfiltered instance).
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
  /// The production interval for filtered workloads.
  static let interval: Duration = .seconds(10)

  /// Only a filtered instance has a live proof to supervise.
  static func interval(for running: AppleBackend.Running) -> Duration? {
    running.handoffIdentity == nil ? nil : interval
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
  /// `scp` takes the port as `-P`.
  package var scpOptions: [String] { ["-q"] + transportOptions + ["-P", String(port)] }

  /// rsync's `-e`: it splits on whitespace but honors quotes.
  package var rsyncSSHCommand: String {
    "ssh "
      + sshOptions.map { option in
        option.unicodeScalars.contains(where: { $0.properties.isWhitespace })
          ? "'\(option)'" : option
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
    try session.target.requireHandoff()
    let termination = try runner.attached(
      request(
        try ssh(), session.sshOptions + [session.target.address, command.rendered],
        environment: session.env.overlay(environment)),
      inheritStdin: true, deadline: nil)
    guard termination.succeeded else { throw HostError("SSH command failed: \(command)") }
  }

  /// Like `exec(session:)`, with `stdin` for the remote command: a value
  /// that must not appear on the host argv (or in this error text).
  package func exec(_ session: SSHSession, _ command: RemoteCommand, stdin: [UInt8]) throws {
    try session.target.requireHandoff()
    let termination = try runner.attached(
      request(
        try ssh(), session.sshOptions + [session.target.address, command.rendered],
        environment: session.env.overlay(environment), input: stdin),
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
        scp, target.scpOptions + (recursive ? ["-r"] : []) + [local, "\(target.address):\(remote)"]),
      inheritStdin: true, deadline: nil)
    guard termination.succeeded else {
      throw HostError("\(recursive ? "scp -r" : "scp") failed: \(local) -> \(remote)")
    }
  }

  func executable(named name: String) -> String? {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
    where !directory.isEmpty {
      let candidate = "\(directory)/\(name)"
      if access(candidate, X_OK) == 0 { return candidate }
    }
    return nil
  }
}

/// `iso shell`, `claude`, `codex` and `exec`: the user's own sessions.
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

  package static func arguments(_ session: SSHSession, remote: String) -> [String] {
    // A fixed escape character keeps `Enter ~.` working whatever the
    // user's ssh config says.
    session.sshOptions + ["-e", "~", "-t", session.target.address, remote]
  }

  /// Guest command in `workingDirectory`. A missing directory fails the
  /// remote `cd`; nothing is created on the host or in the guest.
  package static func remote(_ command: [String], workingDirectory: GuestPath) -> String {
    "cd \(shellEscape(workingDirectory.rawValue)) && "
      + command.map(shellEscape).joined(separator: " ")
  }

  /// Like `run`, but returns the ssh status and can skip the PTY. Used by
  /// `iso run` so agent and cleanup outcomes stay distinguishable.
  package static func runReporting(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String],
    workingDirectory: GuestPath, allocatePTY: Bool, diagnostics: Diagnostics
  ) throws -> ProcessRunner.Termination {
    let session = workload.session
    let remote = Self.remote(command, workingDirectory: workingDirectory)
    diagnostics.log(
      .info, "Connecting via SSH to \(session.target.host):\(session.target.port) (\(remote))")
    guard let ssh = client.sshExecutable() else {
      throw HostError("Failed to launch SSH — is the ssh client installed?")
    }
    var environment = session.env.overlay(client.environment)
    if allocatePTY { environment["TERM"] = guestTerm(client.environment) }
    let arguments =
      allocatePTY
      ? session.sshOptions + ["-e", "~", "-t", session.target.address, remote]
      : session.sshOptions + [session.target.address, remote]
    try workload.revalidate()
    let termination: ProcessRunner.Termination
    do {
      termination = try workload.attached(
        client, client.request(ssh, arguments, environment: environment), inheritStdin: true)
    } catch {
      if allocatePTY { restoreTerminal(client) }
      throw error
    }
    if allocatePTY && !termination.succeeded { restoreTerminal(client) }
    return termination
  }

  /// With a PTY; a failed session leaves the terminal restored.
  package static func run(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String], diagnostics: Diagnostics
  ) throws {
    let session = workload.session
    let remote = render(command)
    diagnostics.log(
      .info, "Connecting via SSH to \(session.target.host):\(session.target.port) (\(remote))")
    diagnostics.log(
      .info,
      "If the remote session stops responding, type Enter, then ~. to disconnect; run `stty sane` if your terminal remains broken."
    )
    guard let ssh = client.sshExecutable() else {
      throw HostError("Failed to launch SSH — is the ssh client installed?")
    }
    var environment = session.env.overlay(client.environment)
    environment["TERM"] = guestTerm(client.environment)
    try workload.revalidate()
    let termination: ProcessRunner.Termination
    do {
      termination = try workload.attached(
        client, client.request(ssh, arguments(session, remote: remote), environment: environment),
        inheritStdin: true)
    } catch {
      restoreTerminal(client)
      throw error
    }
    if !termination.succeeded {
      diagnostics.warn("SSH session exited with status: \(termination)")
      restoreTerminal(client)
    }
  }

  package static func runCommand(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String], diagnostics: Diagnostics
  ) throws {
    let session = workload.session
    let remote = command.map(shellEscape).joined(separator: " ")
    diagnostics.log(.info, "Running (non-interactive): \(remote)")
    guard let ssh = client.sshExecutable() else { throw HostError("Failed to launch SSH") }
    try workload.revalidate()
    let termination = try workload.attached(
      client,
      client.request(
        ssh, session.sshOptions + [session.target.address, remote],
        environment: session.env.overlay(client.environment)),
      inheritStdin: true)
    guard termination.succeeded else {
      throw HostError("Remote command exited with status: \(termination)")
    }
  }

  /// `iso exec`: output passes through; stdin is `/dev/null` (a loop reading
  /// its own input keeps it); a failure reports the remote code.
  package static func exec(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String], diagnostics: Diagnostics
  ) throws {
    let session = workload.session
    let remote = command.map(shellEscape).joined(separator: " ")
    diagnostics.debug("exec: \(remote)")
    guard let ssh = client.sshExecutable() else { throw HostError("Failed to launch SSH") }
    try workload.revalidate()
    let termination = try workload.attached(
      client,
      client.request(
        ssh, session.sshOptions + [session.target.address, remote],
        environment: session.env.overlay(client.environment)),
      inheritStdin: false)
    guard termination.succeeded else {
      let code: Int32 = if case .exited(let code) = termination { code } else { 1 }
      throw HostError("Remote command exited with status \(code)")
    }
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
