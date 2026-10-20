import Foundation
import Synchronization

/// The controller's ed25519 SSH client key. Only the public key travels (in
/// `access.open`); the private key never leaves the controller data root.
package struct ClientKey: Sendable, Equatable {
  package let privateKeyPath: String
  package let publicKey: String

  package static func ensure(directory: String) throws(CIError) -> ClientKey {
    try PrivateFiles.ensureDirectory(directory)
    let path = directory + "/client_ed25519"
    if access(path, F_OK) != 0 {
      guard let keygen = Subprocess.which("ssh-keygen") else {
        throw CIError(.unsupported, "ssh-keygen is not installed")
      }
      let output = try Subprocess.run(
        .init(
          executable: keygen,
          arguments: ["-q", "-t", "ed25519", "-N", "", "-C", "iso-ci", "-f", path],
          environment: Subprocess.baseEnvironment(), timeout: .seconds(30)))
      guard output.succeeded else {
        throw CIError(.internalError, "cannot create the SSH client key")
      }
    }
    guard let bytes = try PrivateFiles.read(path + ".pub", limit: 4_096),
      let text = String(validating: bytes, as: UTF8.self)
    else { throw CIError.storage("the SSH client public key is missing") }
    let fields = text.split(separator: " ")
    guard fields.count >= 2, fields[0] == "ssh-ed25519" else {
      throw CIError.storage("the SSH client key is not ed25519")
    }
    return ClientKey(privateKeyPath: path, publicKey: "ssh-ed25519 " + fields[1])
  }
}

/// What the relay helper needs to reach one guest through its host relay.
/// Written 0600 in the controller's private sessions directory; the bearer
/// never appears in argv, environment or logs.
package struct RelayDescriptor: Codable, Sendable, Equatable {
  package let iso: String
  package let isoConfig: String?
  package let host: String
  package let session: SessionID
  package let bearer: String
  package let epoch: DaemonEpoch

  package static func load(path: String) throws(CIError) -> RelayDescriptor {
    guard let bytes = try PrivateFiles.read(path, limit: 8_192) else {
      throw CIError(.notFound, "relay descriptor is gone")
    }
    return try ControllerStore.decode(RelayDescriptor.self, String(decoding: bytes, as: UTF8.self))
  }

  /// The ssh ProxyCommand body: start iso's relay bridge, send the preamble,
  /// then carry raw bytes both ways until either side closes.
  package func connect() throws(CIError) -> Int32 {
    var inputPipe: [Int32] = [-1, -1]
    guard pipe(&inputPipe) == 0 else { throw CIError(.internalError, "cannot create a pipe") }
    let pid = try Subprocess.spawn(
      iso, IsoBridgeTransport.clientArguments(isoConfig: isoConfig, host: host, relay: true),
      Subprocess.hostConnectionEnvironment(), stdin: inputPipe[0], stdout: 1, stderr: 2)
    close(inputPipe[0])
    _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)
    let preamble = relayPreamble(session: session, bearer: bearer, epoch: epoch)
    var ok = writeAll(inputPipe[1], preamble)
    var buffer = [UInt8](repeating: 0, count: 32 << 10)
    while ok {
      let count = buffer.withUnsafeMutableBytes { Darwin.read(0, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      if count <= 0 { break }
      ok = writeAll(inputPipe[1], Array(buffer[0..<count]))
    }
    close(inputPipe[1])
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 1
  }
}

@discardableResult
package func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
  var offset = 0
  while offset < bytes.count {
    let count = bytes.withUnsafeBytes {
      Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset)
    }
    if count < 0 {
      if errno == EINTR { continue }
      return false
    }
    offset += count
  }
  return true
}

/// Paths that reach ssh's shell-run ProxyCommand must be plain.
package func requireRouteSafe(_ path: String) throws(CIError) {
  guard !path.isEmpty, path.unicodeScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" }) else {
    throw CIError(
      .invalidConfiguration,
      "\(path) has characters the guest route cannot carry; use paths of [A-Za-z0-9/._-]")
  }
}

/// One live, controller-held access session to a guest (spec section 2:
/// VM-bound management). Renews every 10 seconds; a renewal failure is
/// terminal and the session is never revived.
package final class GuestSession: @unchecked Sendable {
  package static let renewInterval: TimeInterval = 10

  package let grant: AccessGrant
  package let alias: String
  package let directory: String
  private let client: HostClient
  private let bearer: String
  private let ssh: String
  private let state = Mutex<(stopped: Bool, failure: CIError?, forwarders: [pid_t])>(
    (false, nil, []))

  private init(
    grant: AccessGrant, alias: String, directory: String, client: HostClient, bearer: String,
    ssh: String
  ) {
    self.grant = grant
    self.alias = alias
    self.directory = directory
    self.client = client
    self.bearer = bearer
    self.ssh = ssh
  }

  /// Opens a grant for the running VM after a fresh observation, writes the
  /// private route files and starts renewing.
  package static func open(
    client: HostClient, instance: QualifiedInstance, expectedPolicy: Digest?, key: ClientKey,
    sessionsDirectory: String, iso: String, isoConfig: String? = nil, relayExecutable: String
  ) throws(CIError) -> GuestSession {
    guard let ssh = Subprocess.which("ssh") else {
      throw CIError(.unsupported, "ssh is not installed")
    }
    for path in [sessionsDirectory, key.privateKeyPath, iso, relayExecutable] {
      try requireRouteSafe(path)
    }
    let (_, epoch) = try client.hello()
    let observation = try client.inspectVM(instance)
    guard observation.state == .running, let boot = observation.bootID,
      let policy = observation.policyHash
    else { throw CIError(.conflict, "the VM is not running") }
    // Revalidated at every handoff: the live proof, not a cached check.
    if let expectedPolicy {
      guard let proof = observation.network, proof.bootID == boot,
        proof.networkPolicy == expectedPolicy
      else {
        throw CIError(
          .admissionRefused, "the VM's live brokered proof does not match the admitted policy")
      }
    }
    let bearer = randomHex(bytes: 32)
    let session = SessionID.generate()
    let request = AccessOpenRequest(
      instance: instance, expectedEpoch: epoch, expectedBoot: boot,
      expectedGeneration: observation.generation, policyHash: policy, session: session,
      client: "iso-ci", clientPublicKey: key.publicKey, bearer: bearer)
    let grant = try AccessGrant(wire: try client.call(.accessOpen(request)))
    guard grant.instance == instance, grant.bootID == boot, grant.session == session else {
      _ = try? client.call(.accessClose(session: session, bearer: bearer, epoch: epoch))
      throw CIError(.hostRefused, "the host returned a grant for a different session")
    }
    let directory = sessionsDirectory + "/" + session.rawValue
    do {
      try PrivateFiles.ensureDirectory(directory)
      let alias = "g-\(instance.instanceID.short).iso-ci"
      try PrivateFiles.write(
        Array("\(alias) \(grant.guestHostKey)\n".utf8), to: directory + "/known_hosts")
      let descriptor = RelayDescriptor(
        iso: iso, isoConfig: isoConfig, host: client.alias.rawValue, session: session,
        bearer: bearer, epoch: grant.epoch)
      try PrivateFiles.write(
        Array(try ControllerStore.encode(descriptor).utf8), to: directory + "/relay.json")
      let config = """
        Host \(alias)
          HostName \(alias)
          User \(grant.guestUser)
          IdentityFile \(key.privateKeyPath)
          IdentitiesOnly yes
          IdentityAgent none
          HostKeyAlias \(alias)
          UserKnownHostsFile \(directory)/known_hosts
          GlobalKnownHostsFile /dev/null
          StrictHostKeyChecking yes
          UpdateHostKeys no
          ForwardAgent no
          ForwardX11 no
          PermitLocalCommand no
          ControlMaster no
          BatchMode yes
          ServerAliveInterval 10
          ServerAliveCountMax 3
          LogLevel ERROR
          ProxyCommand \(relayExecutable) _relay --descriptor \(directory)/relay.json

        """
      try PrivateFiles.write(Array(config.utf8), to: directory + "/ssh_config")
      let opened = GuestSession(
        grant: grant, alias: alias, directory: directory, client: client, bearer: bearer, ssh: ssh)
      opened.startRenewing()
      return opened
    } catch {
      _ = try? client.call(.accessClose(session: session, bearer: bearer, epoch: grant.epoch))
      PrivateFiles.removeTree(directory)
      throw error
    }
  }

  package var failure: CIError? { state.withLock { $0.failure } }
  package var isLive: Bool { state.withLock { !$0.stopped && $0.failure == nil } }

  private func startRenewing() {
    Thread.detachNewThread { [self] in
      while true {
        Thread.sleep(forTimeInterval: Self.renewInterval)
        if state.withLock({ $0.stopped }) { return }
        do throws(CIError) {
          _ = try client.call(
            .accessRenew(
              session: grant.session, bearer: bearer, epoch: grant.epoch, boot: grant.bootID,
              policy: grant.policyHash))
        } catch {
          state.withLock { $0.failure = error }
          stopForwarders()
          return
        }
      }
    }
  }

  private var sshBase: [String] { ["-F", directory + "/ssh_config"] }

  /// Runs one bounded command; stdin carries any secret-bearing material.
  package func run(_ command: GuestCommand) throws(CIError) -> GuestCommandResult {
    if let failure { throw CIError(.hostRefused, "the guest session ended: \(failure.message)") }
    let output = try Subprocess.run(
      .init(
        executable: ssh,
        arguments: sshBase + [
          "-T", "-o", "ClearAllForwardings=yes", alias, "--", command.rendered,
        ],
        // ssh passes it to the relay ProxyCommand; `IdentityAgent none` keeps
        // ssh itself from using the agent.
        environment: Subprocess.hostConnectionEnvironment(), input: command.stdin,
        timeout: .seconds(Int64(command.timeoutSeconds)), outputLimit: command.outputLimit))
    // Commands that carry secret material on stdin never surface guest
    // output: a hostile guest could echo stdin back into host records.
    let record = command.recordOutput
    if output.status == 255 && !output.timedOut {
      let detail =
        record ? ": \(String(decoding: output.stderr.suffix(200), as: UTF8.self))" : " (exit 255)"
      throw CIError(.hostUnreachable, "ssh to the guest failed\(detail)")
    }
    return GuestCommandResult(
      exitStatus: output.status, stdout: record ? output.stdout : [],
      stderr: record ? output.stderr : [],
      timedOut: output.timedOut)
  }

  /// Starts a supervised `ssh -N -R` carrying each forward from guest
  /// loopback to a controller-side Unix socket. Ends with the session.
  package func startForwards(_ forwards: [ServiceForward]) throws(CIError) {
    guard !forwards.isEmpty else { return }
    var arguments = sshBase + ["-N", "-T", "-o", "ExitOnForwardFailure=yes"]
    for forward in forwards {
      try requireRouteSafe(forward.hostSocket)
      arguments += ["-R", "127.0.0.1:\(forward.guestPort):\(forward.hostSocket)"]
    }
    arguments.append(alias)
    let devNull = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
    defer { Darwin.close(devNull) }
    let pid = try Subprocess.spawn(
      ssh, arguments, Subprocess.hostConnectionEnvironment(), stdin: devNull, stdout: devNull,
      stderr: devNull
    )
    state.withLock { $0.forwarders.append(pid) }
  }

  private func stopForwarders() {
    let pids = state.withLock { state -> [pid_t] in
      let pids = state.forwarders
      state.forwarders = []
      return pids
    }
    for pid in pids {
      kill(-pid, SIGTERM)
      kill(pid, SIGTERM)
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
  }

  /// Closes the grant (best effort when unreachable) and removes the files.
  package func close() {
    state.withLock { $0.stopped = true }
    stopForwarders()
    _ = try? client.call(.accessClose(session: grant.session, bearer: bearer, epoch: grant.epoch))
    PrivateFiles.removeTree(directory)
  }

  /// The ssh argv an operator's interactive debug session uses.
  package var interactiveArguments: [String] { sshBase + [alias] }
  package var sshExecutable: String { ssh }
}
