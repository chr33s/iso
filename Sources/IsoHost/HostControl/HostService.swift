import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// Process entrypoints behind `iso host-agent` (spec 3.3) and the launchd
/// user service that keeps the supervisor alive independently of frontends.
package enum HostService {
  package static func root(_ config: IsoConfig) -> String {
    config.stateRoot.appending("host-control").path
  }

  /// `iso host-agent daemon`: owns the installation until it exits.
  package static func runDaemon(
    config: IsoConfig, environment: [String: String], installation expected: HostID?,
    diagnostics: Diagnostics
  ) throws -> Never {
    let owner: Owner
    do { owner = try Owner.load(config) } catch {
      throw HostError("this host has no iso installation owner; run `iso setup` here first")
    }
    let store = try OperationStore(root: root(config))
    guard let ownership = try FileLock.attempt(path: store.serviceLockPath) else {
      throw HostError("another host-control service already owns \(root(config))")
    }
    let backend = AppleBackend(
      config: config, environment: environment, executable: nil, diagnostics: diagnostics)
    // Activation-only first: a prepared migration completes (or stays
    // pending) before any ordinary work can be dispatched.
    do {
      try HostMigration.complete(config: config, backend: backend, diagnostics: diagnostics)
    } catch { diagnostics.warn("host-control migration is still pending: \(error)") }
    var settings = HostSupervisor.Settings()
    settings.localDefaultTTL = config.limits.sessionTTL.map { UInt64($0.seconds) }
    let supervisor = try HostSupervisor(
      root: root(config), owner: owner.id, native: AppleNativeHost(backend: backend),
      settings: settings, diagnostics: diagnostics)
    if let expected, expected != supervisor.installation.hostID {
      throw HostError("installation \(supervisor.installation.hostID) is not \(expected)")
    }
    let paths = try HostControlPaths(hostID: supervisor.installation.hostID)
    let server = LocalHostServer(supervisor: supervisor, paths: paths, diagnostics: diagnostics)
    let listeners = try server.bind()
    supervisor.start()
    diagnostics.log(
      .info,
      "host-control service \(supervisor.installation.hostID) epoch \(supervisor.epoch) listening")
    server.serve(listeners)
    ownership.release()
    throw HostError("host-control listeners stopped")
  }

  /// `iso host-agent serve --stdio`: forwards bounded frames between stdin/
  /// stdout and the local service, starting the service if needed.
  package static func serveStdio(config: IsoConfig, configPath: String?, diagnostics: Diagnostics)
    throws -> Int32
  {
    let paths = try ensureRunning(config: config, configPath: configPath)
    // The remote socket marks every request on this stream as SSH-originated.
    guard let socket = connectUnix(paths.remote) else {
      throw HostError("the host-control service is not accepting connections")
    }
    defer { close(socket) }
    while let frame = Socket.readLine(0, limit: HostWire.maxRequestFrame) {
      guard (try? AtomicFile.writeAll(socket, frame + [UInt8(ascii: "\n")], "control")) != nil,
        let reply = Socket.readLine(socket, limit: HostWire.maxResponseFrame),
        (try? AtomicFile.writeAll(1, reply + [UInt8(ascii: "\n")], "stdout")) != nil
      else {
        diagnostics.warn("host-control stream closed")
        return 1
      }
    }
    return 0
  }

  /// `iso host-agent relay --stdio`: forwards the preamble, reports a
  /// refusal on stderr, then carries raw bytes in both directions.
  package static func relayStdio(config: IsoConfig, configPath: String?, diagnostics: Diagnostics)
    throws -> Int32
  {
    guard let preamble = Socket.readLine(0, limit: RelayPreamble.maxBytes) else {
      throw HostError("missing relay preamble")
    }
    let paths = try ensureRunning(config: config, configPath: configPath)
    return try relay(socketPath: paths.relay, preamble: preamble)
  }

  /// Admits `preamble` on a local relay socket, then splices stdio with it.
  package static func relay(socketPath: String, preamble: [UInt8]) throws -> Int32 {
    guard let socket = connectUnix(socketPath) else {
      throw HostError("the host-control relay is not accepting connections")
    }
    defer { close(socket) }
    guard (try? AtomicFile.writeAll(socket, preamble + [UInt8(ascii: "\n")], "relay")) != nil,
      let status = Socket.readLine(socket, limit: HostWire.maxResponseFrame)
    else { throw HostError("the relay closed before admission") }
    guard String(decoding: status, as: UTF8.self) == #"{"ok":true}"# else {
      let value = try? HostWire.parse(status, limits: HostWire.responseLimits)
      let error = value?["error"].flatMap { try? HostControlError(wire: $0) }
      throw HostError("relay refused: \(error?.description ?? "unknown reason")")
    }
    Socket.splice(socket, stdio: (0, 1))
    return 0
  }

  // MARK: - User service

  static func label(_ hostID: HostID) -> String {
    "dev.iso.host-control." + hostID.rawValue.replacingOccurrences(of: "-", with: "").prefix(12)
  }

  /// Starts the per-user service when its socket is not answering and
  /// returns its socket paths. The plist lives in the data root (not
  /// LaunchAgents) and is loaded into the background user domain.
  package static func ensureRunning(config: IsoConfig, configPath: String?) throws
    -> HostControlPaths
  {
    let owner = try Owner.load(config)
    let store = try OperationStore(root: root(config))
    let installation = try store.installation(owner: owner.id, now: WireTime(Date()))
    let paths = try HostControlPaths(hostID: installation.hostID)
    if let fd = connectUnix(paths.control) {
      close(fd)
      return paths
    }
    guard let executable = Bundle.main.executablePath, executable.hasPrefix("/") else {
      throw HostError("cannot resolve the iso executable path")
    }
    let label = label(installation.hostID)
    let plist = store.root + "/service.plist"
    let log = store.root + "/service.log"
    let arguments =
      [executable] + (configPath.map { ["--config", $0] } ?? [])
      + ["host-agent", "daemon", "--installation", installation.hostID.rawValue]
    let document: [String: Any] = [
      "Label": label,
      "ProgramArguments": arguments,
      "RunAtLoad": true,
      "LimitLoadToSessionType": "Background",
      "KeepAlive": ["SuccessfulExit": false],
      "ThrottleInterval": 5,
      "ProcessType": "Interactive",
      "StandardOutPath": log,
      "StandardErrorPath": log,
      "EnvironmentVariables": [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin",
        "HOME": NSHomeDirectory(),
      ],
    ]
    let data: Data
    do {
      data = try PropertyListSerialization.data(
        fromPropertyList: document, format: .xml, options: 0)
    } catch { throw HostError("Failed to encode the host service plist") }
    try AtomicFile.write(Array(data), to: plist, mode: .atMost(0o600))
    let domain = "user/\(getuid())"
    let runner = ProcessRunner()
    func launchctl(_ arguments: [String]) -> ProcessRunner.Termination? {
      try? runner.capture(
        .init(
          executable: "/bin/launchctl", arguments: arguments, environment: [:],
          deadline: .seconds(15), outputLimit: 64 << 10, overflow: .drain)
      ).termination
    }
    if launchctl(["print", "\(domain)/\(label)"]) != .exited(0) {
      _ = launchctl(["bootstrap", domain, plist])
    }
    _ = launchctl(["kickstart", "\(domain)/\(label)"])
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
      if let fd = connectUnix(paths.control) {
        close(fd)
        return paths
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw HostError("the host-control service did not start; see \(log)")
  }

  /// Unloads the service (used by `iso host migrate`) and waits until its
  /// process has released the ownership lock: until then it still answers
  /// its socket, and a following ``ensureRunning(config:configPath:)`` would
  /// reach the exiting service instead of starting a new one.
  package static func stop(config: IsoConfig, waitingForExit: Duration = .seconds(10)) throws {
    let owner = try Owner.load(config)
    let store = try OperationStore(root: root(config))
    guard let installation = try store.loadInstallation(), installation.ownerID == owner.id else {
      return
    }
    _ = try? ProcessRunner().capture(
      .init(
        executable: "/bin/launchctl",
        arguments: ["bootout", "user/\(getuid())/\(label(installation.hostID))"],
        environment: [:], deadline: .seconds(30), outputLimit: 64 << 10, overflow: .drain))
    let deadline = ContinuousClock.now + waitingForExit
    while true {
      if let probe = try FileLock.attempt(path: store.serviceLockPath) {
        probe.release()
        return
      }
      guard ContinuousClock.now < deadline else {
        throw HostError(
          "the host service did not exit after it was stopped; see \(store.root)/service.log")
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }
}

extension Socket {
  /// Splices a socket with this process's stdin/stdout and returns when
  /// either side ends. The relay runs as an ssh ProxyCommand: stdin EOF means
  /// ssh is gone, so the guest side gets a short grace to finish rather than
  /// an unbounded wait (an orphaned relay would otherwise keep its caller's
  /// inherited stderr open).
  static func splice(
    _ socket: Int32, stdio: (Int32, Int32), grace: DispatchTimeInterval = .seconds(5)
  ) {
    let inbound = DispatchSemaphore(value: 0)
    let outbound = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      copy(from: stdio.0, to: socket)
      shutdown(socket, SHUT_WR)
      inbound.signal()
    }
    Thread.detachNewThread {
      copy(from: socket, to: stdio.1)
      outbound.signal()
    }
    while true {
      if outbound.wait(timeout: .now() + .milliseconds(100)) == .success {
        // The guest side ended: stop waiting for stdin.
        _ = inbound.wait(timeout: .now() + 1)
        return
      }
      if inbound.wait(timeout: .now()) == .success {
        _ = outbound.wait(timeout: .now() + grace)
        return
      }
    }
  }
}

/// A client's private description of one live access session: what the
/// relay helper needs to reach the guest. Owner-only; holds the bearer.
package struct SessionDescriptor: Codable, Sendable {
  package var schema = 1
  package let host: HostAlias
  package let sshAlias: HostAlias
  package let agentPath: AgentPath
  package let session: SessionID
  package let bearer: String
  package let epoch: DaemonEpoch
  package let instance: InstanceID
  package let guestHostKey: String
  /// For the local host: its relay socket, reached directly instead of over ssh.
  package var localRelay: String?

  package init(
    host: HostAlias, sshAlias: HostAlias, agentPath: AgentPath, session: SessionID,
    bearer: AccessBearer, epoch: DaemonEpoch, instance: InstanceID, guestHostKey: String,
    localRelay: String? = nil
  ) {
    self.localRelay = localRelay
    self.host = host
    self.sshAlias = sshAlias
    self.agentPath = agentPath
    self.session = session
    self.bearer = bearer.rawValue
    self.epoch = epoch
    self.instance = instance
    self.guestHostKey = guestHostKey
  }

  package static func directory(_ config: IsoConfig) -> String {
    config.stateRoot.appending("host-sessions").path
  }

  package static func path(_ config: IsoConfig, _ session: SessionID) -> String {
    directory(config) + "/" + session.rawValue + ".json"
  }

  package func save(_ config: IsoConfig) throws(HostError) {
    try StateStore.ensurePrivateDirectory(Self.directory(config))
    try StateStore.writeControlFile(self, to: Self.path(config, session))
  }

  /// Reads a descriptor that this user owns and nobody else can read.
  package static func load(path: String) throws(HostError) -> SessionDescriptor {
    var status = stat()
    guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == getuid(), status.st_mode & 0o077 == 0
    else { throw HostError("\(path) is not a private session descriptor") }
    guard let bytes = try StateStore.readControlFile(path) else {
      throw HostError("\(path) does not exist")
    }
    return try StateStore.decode(SessionDescriptor.self, bytes, path: path)
  }

  /// `iso host-agent connect`: ssh's ProxyCommand. Opens the fixed remote
  /// relay entrypoint and feeds it the preamble on stdin, then this process's
  /// stdin; guest SSH bytes flow end to end with the guest pin verified by
  /// the outer ssh.
  package func connect(environment: [String: String]) throws -> Int32 {
    let bearer = try AccessBearer(self.bearer)
    guard let ssh = SSHClient(environment: environment).sshExecutable() else {
      throw HostError("ssh is not installed")
    }
    let preamble = RelayPreamble(session: session, bearer: bearer, epoch: epoch).frame
    if let localRelay {
      return try HostService.relay(socketPath: localRelay, preamble: Array(preamble.dropLast()))
    }
    let termination = try ProcessRunner().relayed(
      .init(
        executable: ssh,
        arguments: managementSSHArguments(alias: sshAlias, agent: agentPath, .relay),
        environment: SSHClient.transportEnvironment(environment), deadline: .seconds(0)),
      preamble: preamble)
    if case .exited(let code) = termination { return code }
    return 1
  }
}

extension HostService {
  /// `iso host-agent client` to an enrolled host: the pinned management SSH
  /// to its fixed entrypoint, carrying this process's stdio. For a relay the
  /// preamble line is read from stdin and written to ssh first; nothing from
  /// stdin reaches argv.
  package static func bridgeRemote(
    ssh: String, alias: HostAlias, agent: AgentPath, entry: HostAgentEntrypoint,
    environment: [String: String], input: Int32 = 0, output: Int32 = 1,
    diagnostics: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
  ) throws -> Int32 {
    let request = ProcessRunner.Request(
      executable: ssh, arguments: managementSSHArguments(alias: alias, agent: agent, entry),
      environment: SSHClient.transportEnvironment(environment), deadline: .seconds(0))
    switch entry {
    case .serve:
      // ssh inherits stdio (and stderr, for its own diagnostics).
      return try ProcessRunner().attached(request, inheritStdin: true, deadline: nil).exitStatus
    case .relay:
      guard let preamble = Socket.readLine(input, limit: RelayPreamble.maxBytes) else {
        throw HostError("missing relay preamble")
      }
      // ssh's stderr is collected (bounded) rather than passed through, so a
      // failure is reported once, sanitized, with ssh's own exit status.
      let (termination, stderr) = try ProcessRunner().relayed(
        request, preamble: preamble + [UInt8(ascii: "\n")], input: input, output: output,
        stderrLimit: Self.bridgeDiagnosticBytes)
      let code: Int32 = if case .exited(let status) = termination { status } else { 1 }
      if code != 0 {
        let reason =
          code == 255
          ? SSHHostTransport.classify(stderr, alias: alias).message
          : HostControlError.sanitize(String(decoding: stderr, as: UTF8.self))
        diagnostics(
          "host-agent client: relay to \(alias) ended with status \(code): \(reason)")
      }
      return code
    }
  }

  /// Bound on the ssh stderr a relay bridge keeps for its diagnostic.
  package static let bridgeDiagnosticBytes = 2_048
}
