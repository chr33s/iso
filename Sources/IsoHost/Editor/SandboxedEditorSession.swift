import Foundation
import IsoConfiguration
import IsoCore

/// A supervised sandboxed editor session. Every exit removes the editor's
/// process tree, the tunnel, the guest key and the enclave.
package struct SandboxedEditorSession {
  let provider: any EditorProvider
  let app: TrustedEditorApp
  let running: AppleBackend.Running
  let target: SSHConnectionTarget
  let capabilities: [EditorHostCapability]
  let ssh: SSHClient
  let callerEnvironment: [String: String]
  let hostHome: String?
  let diagnostics: Diagnostics
  let revalidate: @Sendable () throws -> Void
  var supervision: Duration = SessionSupervisor.interval
  var enclaveParent: () throws -> String = { try EditorEnclave.sessionsDirectory() }
  var sandboxExec = "/usr/bin/sandbox-exec"

  /// Why supervision stopped.
  enum End {
    case exited
    case tunnelClosed
    case proofLost
    case interrupted
  }

  package func run() throws {
    // Signals set a flag, so deferred cleanup always runs.
    let guardian = Shutdown.install()
    defer { guardian.restore() }
    let parent = try enclaveParent()
    EditorEnclave.removeStale(in: parent)
    let enclave = try EditorEnclave.create(in: parent)
    defer { enclave.remove() }
    try enclave.pinHostKey(from: running.target.knownHosts)
    let publicKey = try enclave.generateIdentity(runner: ssh.runner)
    let tunnelPort = try Self.freeLoopbackPort()
    var forwardPort = try Self.freeLoopbackPort()
    while forwardPort == tunnelPort { forwardPort = try Self.freeLoopbackPort() }
    let plan = try provider.prepareSandboxed(
      SandboxedEditorContext(
        enclave: enclave, app: app, target: target, capabilities: capabilities,
        forwardPort: forwardPort, hostHome: hostHome))
    try enclave.write(
      try enclave.sshConfigText(
        tunnelPort: tunnelPort, user: running.target.user, hostKeyAlias: running.target.alias),
      to: enclave.sshConfig)

    try authorize(EditorEnclave.authorizedKey(publicKey, options: plan.keyOptions))
    defer { revoke(enclave.keyComment) }
    let log = open(enclave.log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard log >= 0 else { throw HostError.posix("Failed to open", enclave.log) }
    defer { close(log) }
    var tunnel = try startTunnel(port: tunnelPort, log: log)
    defer { tunnel.kill() }
    try Shutdown.check()

    let policy = EditorSandboxPolicy(
      tunnelPort: tunnelPort, forwardPort: plan.usesForwardPort ? forwardPort : nil,
      terminal: plan.terminal, machServicePrefix: plan.machServicePrefix,
      capabilities: capabilities)
    try running.target.requireHandoff()
    try revalidate()
    let arguments =
      ["-p", policy.profile]
      + EditorSandboxPolicy.parameters(
        app: app.bundle, session: enclave.root, prefix: plan.machServicePrefix)
      + [app.executable] + plan.arguments
    diagnostics.log(
      .info, "Starting a sandboxed \(provider.displayName) \(app.version) from \(app.bundle)")
    var editor = try DetachedChild.spawn(
      executable: sandboxExec, arguments: arguments,
      environment: enclave.environment(caller: callerEnvironment), stdin: .null, stderr: log,
      workingDirectory: enclave.home)
    diagnostics.log(
      .info,
      "\(provider.displayName) is running in an isolated profile; iso supervises it until you quit the editor (Ctrl-C ends the session)."
    )
    let end = supervise(&editor, tunnel: &tunnel)
    let status = Self.terminate(&editor)
    switch end.reason {
    case .exited:
      let termination = status ?? .exited(-1)
      guard termination == .exited(0) || termination == .signaled(SIGTERM) else {
        throw HostFailure(
          .editorLaunchFailed(provider.id),
          "The sandboxed \(provider.displayName) exited with \(termination)")
      }
    case .tunnelClosed:
      throw HostError(
        "The SSH tunnel to instance '\(target.instance)' closed; the editor session ended")
    case .proofLost:
      throw SessionSupervisor.ended(
        end.failure ?? HostError("the instance's readiness proof was lost"))
    case .interrupted:
      try Shutdown.check()
    }
  }

  func supervise(_ editor: inout DetachedChild, tunnel: inout DetachedChild) -> (
    reason: End, failure: (any Error)?
  ) {
    let supervisor = SessionSupervisor(revalidate: revalidate, interval: supervision)
    let reason: End
    while true {
      if editor.hasExited() {
        reason = .exited
        break
      }
      if tunnel.hasExited() {
        reason = .tunnelClosed
        break
      }
      if supervisor.lost {
        reason = .proofLost
        break
      }
      if Shutdown.isRequested {
        reason = .interrupted
        break
      }
      usleep(100_000)
    }
    return (reason, supervisor.finish())
  }

  /// SIGTERM, then SIGKILL, to the editor's tree and group while its unreaped
  /// pid keeps them reserved. Returns its status if it exited on its own.
  static func terminate(_ editor: inout DetachedChild, grace: Duration = .seconds(3))
    -> ProcessRunner.Termination?
  {
    let natural = editor.hasExited()
    let tree = natural ? [] : [editor.pid] + ProcessRunner.descendants(of: editor.pid)
    for pid in tree { kill(pid, SIGTERM) }
    kill(-editor.pid, SIGTERM)
    let start = ContinuousClock.now
    while !editor.hasExited(), ContinuousClock.now - start < grace { usleep(50_000) }
    if !natural {
      for pid in [editor.pid] + ProcessRunner.descendants(of: editor.pid) { kill(pid, SIGKILL) }
      for pid in tree { kill(pid, SIGKILL) }
    }
    kill(-editor.pid, SIGKILL)
    kill(editor.pid, SIGKILL)
    var status = editor.poll()
    while status == nil {
      usleep(10_000)
      status = editor.poll()
    }
    return natural ? status : nil
  }

  /// The key line travels on stdin; the remote command is a fixed literal.
  func authorize(_ line: String) throws {
    let command = RemoteCommand().literal(
      "umask 077 && mkdir -p ~/.ssh && IFS= read -r line && printf '%s\\n' \"$line\" >> ~/.ssh/authorized_keys"
    )
    do {
      try ssh.exec(running.target, command, stdin: Array((line + "\n").utf8))
    } catch {
      throw ContextError(
        "Failed to authorize the editor session's SSH key in the guest", cause: error)
    }
  }

  /// Best effort: the private key is deleted with the enclave anyway.
  func revoke(_ comment: String) {
    let command = RemoteCommand()
      .literal("f=~/.ssh/authorized_keys; [ -f \"$f\" ] || exit 0; { grep -vF -- ")
      .arg(comment)
      .literal(
        " \"$f\" || true; } > \"$f.iso-editor\" && chmod 600 \"$f.iso-editor\" && mv \"$f.iso-editor\" \"$f\""
      )
    if !ssh.succeeds(running.target, command) {
      diagnostics.debug("Could not remove the editor session key from the guest")
    }
  }

  /// Runs outside the sandbox so the VM key never enters the enclave.
  func startTunnel(port: UInt16, log: Int32) throws -> DetachedChild {
    guard let executable = ssh.sshExecutable() else {
      throw HostError("Failed to run SSH command: ssh not found on PATH")
    }
    try running.target.requireHandoff()
    var tunnel = try DetachedChild.spawn(
      executable: executable,
      arguments: running.target.sshOptions + [
        "-N", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:\(port):127.0.0.1:22",
        running.target.address,
      ],
      environment: ssh.environment, stdin: .null, stderr: log)
    let start = ContinuousClock.now
    while !Self.accepts(port) {
      if tunnel.hasExited() || ContinuousClock.now - start > .seconds(20) {
        tunnel.kill()
        throw HostError("Failed to open the SSH tunnel for the editor session")
      }
      usleep(100_000)
    }
    return tunnel
  }

  static func accepts(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = loopback(port)
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }

  static func loopback(_ port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
  }

  static func freeLoopbackPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HostError("Failed to create a socket") }
    defer { close(fd) }
    var address = loopback(0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    guard bound, address.sin_port != 0 else {
      throw HostError("Failed to find a free loopback port")
    }
    return UInt16(bigEndian: address.sin_port)
  }
}
