// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// Environment variables forwarded to the guest with `SendEnv`: names go
/// on the ssh argv, values only into ssh's own environment. Every value is
/// treated as secret (API keys, tokens), so nothing here prints one.
public struct EnvForward: Sendable, CustomStringConvertible {
  public private(set) var names: [String] = []
  private var values: [String: Secret<String>] = [:]

  public init() {}

  /// Insert or overwrite, keeping first-insertion order.
  public mutating func set(_ name: String, _ value: Secret<String>) {
    if values[name] == nil { names.append(name) }
    values[name] = value
  }

  public func contains(_ name: String) -> Bool { values[name] != nil }

  public var sendEnvOptions: [String] { names.flatMap { ["-o", "SendEnv=\($0)"] } }

  /// Added to ssh's own environment only.
  func overlay(_ environment: [String: String]) -> [String: String] {
    var merged = environment
    for name in names { merged[name] = values[name]?.expose() }
    return merged
  }

  public var description: String {
    "EnvForward { vars: {"
      + names.map { "\(debugQuoted($0)): \"<redacted>\"" }.joined(separator: ", ")
      + "} }"
  }
}

/// A pinned target plus the environment it forwards.
public struct SSHSession: Sendable {
  public let target: SSHTarget
  public var env: EnvForward

  public init(target: SSHTarget, env: EnvForward = EnvForward()) {
    self.target = target
    self.env = env
  }

  public var sshOptions: [String] { target.sshOptions + env.sendEnvOptions }
}

/// A prepared workload whose original readiness identity is rechecked at launch.
/// Only the host session factory can construct it; bootstrap uses SSHSession.
/// No proof or private signing material is persisted or forwarded to the guest.
public struct WorkloadSession: Sendable {
  fileprivate var session: SSHSession
  fileprivate let revalidate: @Sendable () throws -> Void

  init(session: SSHSession, revalidate: @escaping @Sendable () throws -> Void) throws {
    try revalidate()
    self.session = session
    self.revalidate = revalidate
  }

  public var target: SSHTarget { session.target }
  public var env: EnvForward {
    get { session.env }
    set { session.env = newValue }
  }
}

extension SSHTarget {
  /// `scp` takes the port as `-P`.
  public var scpOptions: [String] { ["-q"] + transportOptions + ["-P", String(port)] }

  /// rsync's `-e`: it splits on whitespace but honors quotes.
  public var rsyncSSHCommand: String {
    "ssh "
      + sshOptions.map { option in
        option.unicodeScalars.contains(where: { $0.properties.isWhitespace })
          ? "'\(option)'" : option
      }.joined(separator: " ")
  }
}

/// Guest commands over the pinned transport. Error texts match the Rust
/// host; the rendered remote command never carries a secret (those travel
/// on stdin or in forwarded variables).
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
  public func exec(_ target: SSHTarget, _ command: RemoteCommand) throws {
    try target.requireHandoff()
    let termination = try runner.attached(
      request(try ssh(), target.sshOptions + [target.address, command.rendered]),
      inheritStdin: true)
    guard termination.succeeded else { throw HostError("SSH command failed: \(command)") }
  }

  /// Like `exec`, with `env` forwarded.
  public func exec(_ session: SSHSession, _ command: RemoteCommand) throws {
    try session.target.requireHandoff()
    let termination = try runner.attached(
      request(
        try ssh(), session.sshOptions + [session.target.address, command.rendered],
        environment: session.env.overlay(environment)),
      inheritStdin: true)
    guard termination.succeeded else { throw HostError("SSH command failed: \(command)") }
  }

  /// Like `exec(session:)`, with `stdin` for the remote command: a value
  /// that must not appear on the host argv (or in this error text).
  public func exec(_ session: SSHSession, _ command: RemoteCommand, stdin: [UInt8]) throws {
    try session.target.requireHandoff()
    let termination = try runner.attached(
      request(
        try ssh(), session.sshOptions + [session.target.address, command.rendered],
        environment: session.env.overlay(environment), input: stdin),
      inheritStdin: false)
    guard termination.succeeded else { throw HostError("SSH command failed: \(command)") }
  }

  /// `stdin` goes to the remote command (for secrets read with `read -r`).
  public func exec(_ target: SSHTarget, _ command: RemoteCommand, stdin: [UInt8]) throws {
    let ssh = try ssh()
    let arguments = target.sshOptions + [target.address, command.rendered]
    try target.requireHandoff()
    let termination = try runner.attached(
      request(ssh, arguments, input: stdin), inheritStdin: false)
    guard termination.succeeded else {
      throw ContextError(
        "SSH command failed: \(command)",
        cause: HostError("ssh \(arguments.joined(separator: " ")) exited with \(termination)"))
    }
  }

  /// Whether the command succeeds; output discarded.
  public func succeeds(_ target: SSHTarget, _ command: RemoteCommand) -> Bool {
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

  /// stdout of a successful command; stderr is discarded.
  public func captureChecked(_ target: SSHTarget, _ command: RemoteCommand) throws -> String {
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

  /// `scp` one file (or, `recursive`, a directory) to the guest.
  public func copy(
    _ target: SSHTarget, local: String, remote: GuestPath, recursive: Bool = false
  ) throws {
    guard let scp = executable(named: "scp") else { throw HostError("Failed to run scp") }
    try target.requireHandoff()
    let termination = try runner.attached(
      request(
        scp, target.scpOptions + (recursive ? ["-r"] : []) + [local, "\(target.address):\(remote)"]),
      inheritStdin: true)
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
public enum InteractiveSSH {
  /// Empty `command` opens a login shell at `/workspace`.
  public static func render(_ command: [String]) -> String {
    command.isEmpty
      ? "cd /workspace && exec $SHELL -l"
      : "cd /workspace && " + command.map(shellEscape).joined(separator: " ")
  }

  /// A TERM a stock Ubuntu guest has terminfo for.
  public static func guestTerm(_ environment: [String: String]) -> String {
    let term = environment["TERM"] ?? ""
    return ["xterm", "xterm-256color", "screen", "vt100"].contains(term) ? term : "xterm-256color"
  }

  public static func arguments(_ session: SSHSession, remote: String) -> [String] {
    // A fixed escape character keeps `Enter ~.` working whatever the
    // user's ssh config says.
    session.sshOptions + ["-e", "~", "-t", session.target.address, remote]
  }

  /// Guest command in `workingDirectory`. A missing directory fails the
  /// remote `cd`; nothing is created on the host or in the guest.
  public static func remote(_ command: [String], workingDirectory: GuestPath) -> String {
    "cd \(shellEscape(workingDirectory.rawValue)) && "
      + command.map(shellEscape).joined(separator: " ")
  }

  /// Like `run`, but returns the ssh status and can skip the PTY. Used by
  /// `iso run` so agent and cleanup outcomes stay distinguishable.
  public static func runReporting(
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
    let termination = try client.runner.attached(
      client.request(ssh, arguments, environment: environment), inheritStdin: true)
    if allocatePTY && !termination.succeeded { restoreTerminal(client) }
    return termination
  }

  /// With a PTY; a failed session leaves the terminal restored.
  public static func run(
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
    let termination = try client.runner.attached(
      client.request(ssh, arguments(session, remote: remote), environment: environment),
      inheritStdin: true)
    if !termination.succeeded {
      diagnostics.warn("SSH session exited with status: \(termination)")
      restoreTerminal(client)
    }
  }

  /// Without a PTY; fails when the remote command does.
  public static func runCommand(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String], diagnostics: Diagnostics
  ) throws {
    let session = workload.session
    let remote = command.map(shellEscape).joined(separator: " ")
    diagnostics.log(.info, "Running (non-interactive): \(remote)")
    guard let ssh = client.sshExecutable() else { throw HostError("Failed to launch SSH") }
    try workload.revalidate()
    let termination = try client.runner.attached(
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
  public static func exec(
    _ client: SSHClient, _ workload: WorkloadSession, _ command: [String], diagnostics: Diagnostics
  ) throws {
    let session = workload.session
    let remote = command.map(shellEscape).joined(separator: " ")
    diagnostics.debug("exec: \(remote)")
    guard let ssh = client.sshExecutable() else { throw HostError("Failed to launch SSH") }
    try workload.revalidate()
    let termination = try client.runner.attached(
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
        deadline: .seconds(10)), inheritStdin: true)
  }
}

extension ProcessRunner.Request {
  func with(overflow: ProcessRunner.OverflowPolicy) -> Self {
    var copy = self
    copy.overflow = overflow
    return copy
  }
}
