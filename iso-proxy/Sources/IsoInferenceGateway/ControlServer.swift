import Darwin
import IsoInferenceCore
import Synchronization

/// The owner-only control socket (§5.1, §7). One request per connection,
/// served serially on a dedicated thread: control traffic is rare, and
/// operations such as registration block on a listener bind. Peers must be
/// the gateway's own user (`getpeereid`); the socket is `0600` in a `0700`
/// directory and is never relayed into a guest.
public final class ControlServer: Sendable {
  static let ioTimeoutSeconds = 5

  private let path: String
  private let gateway: Gateway
  private let listener: Int32
  private let closed = Mutex(false)

  public init(path: String, gateway: Gateway) throws {
    self.path = path
    self.gateway = gateway
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw GatewayError.startup("cannot create the control socket") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      throw GatewayError.startup("control socket path is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    // The caller holds the startup lock, so a leftover socket is stale.
    unlink(path)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
      close(fd)
      throw GatewayError.startup("cannot bind the control socket")
    }
    listener = fd
  }

  public func run() {
    while !closed.withLock({ $0 }) {
      let connection = accept(listener, nil, nil)
      if connection < 0 {
        if errno == EINTR { continue }
        return
      }
      serve(connection)
      close(connection)
    }
  }

  public func stop() {
    closed.withLock { $0 = true }
    shutdown(listener, SHUT_RDWR)
    close(listener)
    unlink(path)
  }

  private func serve(_ fd: Int32) {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
    var timeout = timeval(tv_sec: Self.ioTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    guard let header = readExactly(fd, 4), let length = ControlProtocol.frameLength(header),
      let body = readExactly(fd, length)
    else { return }
    var stop = false
    let response: JSONObject
    do {
      let request = try ControlProtocol.decodeRequest(ControlProtocol.parseFrame(body))
      (response, stop) = try handle(request)
    } catch {
      response = ControlProtocol.failure(error)
    }
    writeAll(fd, ControlProtocol.frame(response))
    if stop { gateway.stop() }
  }

  private func handle(_ request: ControlProtocol.Request) throws(InferenceError) -> (
    JSONObject, Bool
  ) {
    switch request {
    case .register(let registration):
      let registered = try gateway.register(registration)
      return (
        ControlProtocol.success(
          JSONObject([
            "session_id": .string(registered.sessionID), "epoch": .string(gateway.epoch),
            "socket": .string(registered.socket),
            "capability": .string(registered.capability.expose()),
            "gateway_pid": .int(Int64(gateway.pid)),
            "policy_digest": .string(registered.policyDigest),
          ])), false
      )
    case .activate(let activation):
      try gateway.activate(activation)
      return (ControlProtocol.success(), false)
    case .revoke(let revocation):
      let count = gateway.revoke(revocation)
      return (ControlProtocol.success(JSONObject(["revoked": .int(Int64(count))])), false)
    case .inspect(let instance):
      return (ControlProtocol.success(gateway.inspect(instance)), false)
    case .requalify(let backend):
      try gateway.requalify(backend)
      return (ControlProtocol.success(), false)
    case .shutdown(let force):
      try gateway.prepareShutdown(force: force)
      return (ControlProtocol.success(), true)
    }
  }
}

func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
  var buffer = [UInt8](repeating: 0, count: count)
  var offset = 0
  while offset < count {
    let received = buffer[offset...].withUnsafeMutableBytes {
      recv(fd, $0.baseAddress, $0.count, 0)
    }
    if received < 0 && errno == EINTR { continue }
    guard received > 0 else { return nil }
    offset += received
  }
  return buffer
}

func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
  var offset = 0
  while offset < bytes.count {
    let sent = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
    if sent < 0 && errno == EINTR { continue }
    guard sent > 0 else { return }
    offset += sent
  }
}
