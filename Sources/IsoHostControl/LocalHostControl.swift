import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Synchronization

/// Where one installation's private sockets live (spec 3.3): a bounded name derived from the
/// installation identity, so a long data-root path never meets the socket path limit.
package struct HostControlPaths: Sendable, Equatable {
  package let directory: String

  package init(directory: String) { self.directory = directory }

  package init(hostID: HostID) throws(HostError) {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    guard length > 0, length <= buffer.count else {
      throw HostError("Failed to resolve the per-user temporary directory")
    }
    let base = String(
      decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let tag = hostID.rawValue.replacingOccurrences(of: "-", with: "").prefix(12)
    directory = (base.hasSuffix("/") ? base : base + "/") + "iso-hc-" + tag
  }

  package var control: String { directory + "/control.sock" }
  /// Only the SSH `serve` frontend connects here; requests on it are remote.
  package var remote: String { directory + "/remote.sock" }
  package var relay: String { directory + "/relay.sock" }

  /// Creates (or verifies) the directory: a real directory, owned by this
  /// user, mode 0700. Anything else is refused rather than repaired.
  package func prepare() throws(HostError) {
    if mkdir(directory, 0o700) != 0 && errno != EEXIST {
      throw .posix("Failed to create", directory)
    }
    try verify()
  }

  package func verify() throws(HostError) {
    var status = stat()
    guard lstat(directory, &status) == 0 else { throw .posix("Failed to inspect", directory) }
    guard (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == getuid(),
      status.st_mode & 0o077 == 0
    else { throw HostError("\(directory) is not a private directory owned by this user") }
  }
}

/// The supervisor's private Unix-socket listeners. Every connection's peer
/// must be this user; nothing listens on the network.
package final class LocalHostServer: Sendable {
  /// Each listener has its own connection budget (spec 9.4), so long-lived
  /// relay streams never take the slots control requests (renewals, stop,
  /// destroy) need.
  package struct Limits: Sendable, Equatable {
    package var control: Int
    package var remote: Int
    /// Admitted streams are capped again by ``RelayRegistry``.
    package var relay: Int
    /// How long a connection may take to send its next frame, or a relay its
    /// preamble, before the service closes it. Admitted relay streams have
    /// no idle timeout.
    package var readDeadline: Duration

    package static let standard = Limits(
      control: 64, remote: 64, relay: RelayRegistry.maxStreams, readDeadline: .seconds(10))

    func connections(_ kind: Kind) -> Int {
      switch kind {
      case .control: control
      case .remote: remote
      case .relay: relay
      }
    }
  }

  let supervisor: HostSupervisor
  let paths: HostControlPaths
  let diagnostics: Diagnostics
  let limits: Limits
  private let connections = Mutex<[Kind: Int]>([:])

  package init(
    supervisor: HostSupervisor, paths: HostControlPaths, diagnostics: Diagnostics,
    limits: Limits = .standard
  ) {
    self.supervisor = supervisor
    self.paths = paths
    self.diagnostics = diagnostics
    self.limits = limits
  }

  /// Bound sockets. Provenance comes from which socket accepted a stream,
  /// never from a request field.
  package struct Listeners: Sendable {
    package let control: Int32
    package let remote: Int32
    package let relay: Int32
  }

  enum Kind: String {
    case control
    case remote
    case relay
  }

  /// Binds the sockets. The caller holds the service-ownership lock, so a
  /// leftover socket file belongs to a dead previous owner.
  package func bind() throws(HostError) -> Listeners {
    try paths.prepare()
    return Listeners(
      control: try Self.listen(paths.control), remote: try Self.listen(paths.remote),
      relay: try Self.listen(paths.relay))
  }

  /// Accept loops; returns once any listener fails for good so the service exits and
  /// launchd restarts it, rather than hold its lock with a dead socket.
  package func serve(_ listeners: Listeners) {
    let stopped = DispatchSemaphore(value: 0)
    for (listener, kind) in [
      (listeners.control, Kind.control), (listeners.remote, .remote), (listeners.relay, .relay),
    ] {
      Thread.detachNewThread { [self] in
        acceptLoop(listener, kind: kind)
        stopped.signal()
      }
    }
    stopped.wait()
  }

  /// Descriptor or buffer exhaustion clears as connections close; `accept`
  /// is retried after a pause instead of ending the listener.
  static func isTransientAcceptError(_ code: Int32) -> Bool {
    code == EMFILE || code == ENFILE || code == ENOBUFS || code == ENOMEM
  }

  func acceptLoop(_ listener: Int32, kind: Kind) {
    while true {
      let client = accept(listener, nil, nil)
      if client < 0 {
        let code = errno
        if code == EINTR || code == ECONNABORTED { continue }
        if Self.isTransientAcceptError(code) {
          diagnostics.warn(
            "host-control \(kind.rawValue) listener paused: \(String(cString: strerror(code)))")
          usleep(100_000)
          continue
        }
        diagnostics.warn(
          "host-control \(kind.rawValue) listener stopped: \(String(cString: strerror(code)))")
        return
      }
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)
      var noSigPipe: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      guard Self.peerIsSelf(client) else {
        close(client)
        continue
      }
      let admitted = connections.withLock { counts in
        guard counts[kind, default: 0] < limits.connections(kind) else { return false }
        counts[kind, default: 0] += 1
        return true
      }
      guard admitted else {
        close(client)
        continue
      }
      Thread.detachNewThread { [self] in
        defer { connections.withLock { $0[kind, default: 0] -= 1 } }
        switch kind {
        case .relay: supervisor.serveRelay(client: client, preambleDeadline: limits.readDeadline)
        case .control: serveControl(client, transport: .local)
        case .remote: serveControl(client, transport: .ssh)
        }
      }
    }
  }

  /// One request at a time per stream (spec 6.1). A frame that cannot be
  /// correlated closes the stream with a bounded stderr diagnostic.
  func serveControl(_ client: Int32, transport: HostTransportKind) {
    defer { close(client) }
    // An idle stream is closed after the deadline instead of holding a slot.
    Socket.setReceiveTimeout(client, limits.readDeadline)
    while let frame = Socket.readLine(client, limit: HostWire.maxRequestFrame) {
      let response: HostResponse
      do {
        response = supervisor.handle(try HostRequest.decode(frame: frame), transport: transport)
      } catch {
        switch error {
        case .uncorrelated(let failure):
          diagnostics.warn("closed a host-control stream: \(failure.message)")
          return
        case .correlated(let id, let failure):
          response = supervisor.failure(id, failure)
        }
      }
      guard (try? AtomicFile.writeAll(client, response.frame, "control")) != nil else { return }
    }
  }

  static func listen(_ path: String) throws(HostError) -> Int32 {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw .posix("Failed to create socket for", path) }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    guard var address = unixAddress(path) else {
      close(fd)
      throw HostError("socket path is too long: \(path)")
    }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 64) == 0 else {
      close(fd)
      throw .posix("Failed to listen on", path)
    }
    return fd
  }

  static func peerIsSelf(_ fd: Int32) -> Bool {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
  }
}

func unixAddress(_ path: String) -> sockaddr_un? {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  guard bytes.count < capacity else { return nil }
  withUnsafeMutableBytes(of: &address.sun_path) { raw in
    for (index, byte) in bytes.enumerated() { raw[index] = byte }
    raw[bytes.count] = 0
  }
  return address
}

package func connectUnix(_ path: String) -> Int32? {
  guard var address = unixAddress(path) else { return nil }
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { return nil }
  _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
  var noSigPipe: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
  let connected = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connected == 0, LocalHostServer.peerIsSelf(fd) else {
    close(fd)
    return nil
  }
  return fd
}

package protocol HostTransport: Sendable {
  /// `frame` includes its newline. Throws `.hostUnreachable` when no reply
  /// arrived; the caller decides whether a mutation became uncertain.
  func exchange(_ frame: [UInt8]) throws(HostControlError) -> [UInt8]
}

package struct LocalHostTransport: HostTransport {
  package let paths: HostControlPaths

  package init(paths: HostControlPaths) { self.paths = paths }

  package func exchange(_ frame: [UInt8]) throws(HostControlError) -> [UInt8] {
    do { try paths.verify() } catch {
      throw HostControlError(.hostUnreachable, "the host service socket directory is not private")
    }
    guard let fd = connectUnix(paths.control) else {
      throw HostControlError(.hostUnreachable, "the host service is not running")
    }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard (try? AtomicFile.writeAll(fd, frame, "control")) != nil,
      let reply = Socket.readLine(fd, limit: HostWire.maxResponseFrame)
    else { throw HostControlError(.hostUnreachable, "the host service did not reply") }
    return reply
  }
}

package struct HostControlClient: Sendable {
  package let transport: any HostTransport
  package let expected: (host: HostID, owner: OwnerID)?

  package init(transport: any HostTransport, expected: (host: HostID, owner: OwnerID)?) {
    self.transport = transport
    self.expected = expected
  }

  package func hello(clientBuild: String, includeBuild: Bool = false) throws(HostControlError)
    -> HelloResult
  {
    let request = HostRequest(
      hostID: nil, ownerID: nil,
      body: .hello(
        protocols: HostProtocol.supported, clientBuild: clientBuild, includeBuild: includeBuild))
    let result = try HelloResult(wire: try call(request))
    guard result.protocolVersion == HostProtocol.v1 else {
      throw HostControlError(.hostProtocolIncompatible, "the host selected an unknown protocol")
    }
    return result
  }

  /// One request; a mutation whose reply was lost is `OPERATION_UNCERTAIN`.
  package func call(_ body: HostRequestBody, operation: HostOperationID? = nil)
    throws(HostControlError) -> JSONValue
  {
    guard let (host, owner) = expected else {
      throw .invalidRequest("this host is not enrolled")
    }
    return try call(HostRequest(hostID: host, ownerID: owner, operationID: operation, body: body))
  }

  package func call(_ request: HostRequest) throws(HostControlError) -> JSONValue {
    let reply: [UInt8]
    do { reply = try transport.exchange(request.frame) } catch {
      guard request.body.method.isDurableMutation, let operation = request.operationID else {
        throw error
      }
      throw HostControlError(
        .operationUncertain,
        "no reply after sending the request; query or retry the same operation",
        details: ["operation_id": operation.rawValue, "cause": error.code.rawValue])
    }
    let response = try HostResponse.decode(frame: reply).validated(
      for: request, expected: expected.map { ($0.host, $0.owner) })
    return try response.outcome.get()
  }

  package func wait(_ operation: HostOperationID, timeout: Duration) throws(HostControlError)
    -> OperationReceipt
  {
    let deadline = ContinuousClock.now + timeout
    while true {
      let receipt = try OperationReceipt(wire: try call(.operationGet(operation)))
      if receipt.state.isTerminal || ContinuousClock.now >= deadline { return receipt }
      Thread.sleep(forTimeInterval: 0.5)
    }
  }
}
