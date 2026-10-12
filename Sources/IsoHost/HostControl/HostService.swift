import Foundation
import IsoConfiguration
import IsoCore

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

  /// Unloads the service (used by `iso host migrate` rollback and tests).
  package static func stop(config: IsoConfig) throws {
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
  }
}

extension Socket {
  /// Splices a socket with this process's stdin/stdout.
  static func splice(_ socket: Int32, stdio: (Int32, Int32)) {
    let done = DispatchGroup()
    done.enter()
    Thread.detachNewThread {
      copy(from: stdio.0, to: socket)
      shutdown(socket, SHUT_WR)
      done.leave()
    }
    copy(from: socket, to: stdio.1)
    // The guest side ended: stop waiting for stdin.
    _ = done.wait(timeout: .now() + 1)
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
