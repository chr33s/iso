import Foundation
import Synchronization

/// The private, same-user operator control channel (spec section 3): a Unix
/// socket in a 0700 per-user directory, peer uid checked on every
/// connection, one bounded JSON line per request and per response. Workload
/// streams never travel here; machine-readable responses carry typed codes.
package enum ControlProtocol {
  package static let version = "iso-ci.control/v1"
  package static let maxFrame = 256 << 10
  package static let maxConnections = 32
}

package struct ControlRequest: Sendable, Equatable {
  package let id: RequestID
  package let method: String
  package let params: JSONValue

  package init(id: RequestID = .generate(), method: String, params: JSONValue = [:]) {
    self.id = id
    self.method = method
    self.params = params
  }

  package var frame: [UInt8] {
    JSONValue.object([
      "api": .string(ControlProtocol.version), "request_id": .string(id.rawValue),
      "method": .string(method), "params": params,
    ]).frame
  }

  package static func decode(_ bytes: [UInt8]) throws(CIError) -> ControlRequest {
    var r = try ObjectReader(try StrictJSON.parse(bytes, limits: .control), field: "")
    guard try r.string("api") == ControlProtocol.version else {
      throw CIError(.unsupported, "unsupported control API version")
    }
    let id = try r.parsed("request_id", as: RequestID.self)
    let method = try r.string("method")
    guard (1...64).contains(method.utf8.count),
      method.unicodeScalars.allSatisfy({ isSafeNameScalar($0) })
    else { throw CIError.invalid("invalid method") }
    let params = try r.required("params")
    guard case .object = params else { throw CIError.invalid("params must be an object") }
    try r.finish()
    return ControlRequest(id: id, method: method, params: params)
  }
}

package struct ControlResponse: Sendable, Equatable {
  package let id: RequestID
  package let outcome: Result<JSONValue, CIError>

  package var frame: [UInt8] {
    var members: [String: JSONValue] = [
      "api": .string(ControlProtocol.version), "request_id": .string(id.rawValue),
    ]
    switch outcome {
    case .success(let value):
      members["ok"] = true
      members["result"] = value
    case .failure(let error):
      members["ok"] = false
      members["error"] = error.json
    }
    return JSONValue.object(members).frame
  }

  package static func decode(_ bytes: [UInt8]) throws(CIError) -> ControlResponse {
    var r = try ObjectReader(
      try StrictJSON.parse(
        bytes, limits: .init(maxBytes: 16 << 20, maxKeys: 1 << 20, maxArrayElements: 1 << 18)),
      field: "")
    guard try r.string("api") == ControlProtocol.version else {
      throw CIError(.unsupported, "unsupported control API version")
    }
    let id = try r.parsed("request_id", as: RequestID.self)
    let ok = try r.bool("ok")
    let outcome: Result<JSONValue, CIError>
    if ok {
      outcome = .success(r.optional("result") ?? .null)
    } else {
      outcome = .failure(try CIError(json: try r.required("error")))
    }
    try r.finish()
    return ControlResponse(id: id, outcome: outcome)
  }
}

/// Reads one newline-terminated line (without it), bounded by `limit`.
package func readLine(_ fd: Int32, limit: Int) -> [UInt8]? {
  var line: [UInt8] = []
  var byte: UInt8 = 0
  while true {
    let count = Darwin.read(fd, &byte, 1)
    if count < 0 && errno == EINTR { continue }
    if count <= 0 { return line.isEmpty ? nil : line }
    if byte == 0x0A { return line }
    line.append(byte)
    if line.count > limit { return nil }
  }
}

package func unixAddress(_ path: String) -> sockaddr_un? {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
  withUnsafeMutableBytes(of: &address.sun_path) { raw in
    for (index, byte) in bytes.enumerated() { raw[index] = byte }
    raw[bytes.count] = 0
  }
  return address
}

package func peerIsSelf(_ fd: Int32) -> Bool {
  var uid: uid_t = 0
  var gid: gid_t = 0
  return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
}

/// Binds a private listening socket (mode 0600 in a verified 0700 directory).
package func listenUnix(_ path: String) throws(CIError) -> Int32 {
  try PrivateFiles.ensureDirectory((path as NSString).deletingLastPathComponent)
  unlink(path)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw CIError(.internalError, "cannot create a socket") }
  _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
  guard var address = unixAddress(path) else {
    close(fd)
    throw CIError.invalid("socket path is too long")
  }
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 32) == 0 else {
    close(fd)
    throw CIError(.internalError, "cannot listen on the control socket")
  }
  return fd
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
  guard connected == 0, peerIsSelf(fd) else {
    close(fd)
    return nil
  }
  return fd
}

/// Serves the control socket; each request is dispatched to `handler`.
package final class ControlServer: Sendable {
  private let path: String
  private let handler: @Sendable (ControlRequest) -> Result<JSONValue, CIError>
  private let connections = Mutex(0)
  private let listener = Mutex<Int32>(-1)

  package init(
    path: String, handler: @escaping @Sendable (ControlRequest) -> Result<JSONValue, CIError>
  ) {
    self.path = path
    self.handler = handler
  }

  package func start() throws(CIError) {
    let fd = try listenUnix(path)
    listener.withLock { $0 = fd }
    Thread.detachNewThread { [self] in acceptLoop(fd) }
  }

  package func stop() {
    let fd = listener.withLock { fd -> Int32 in
      let old = fd
      fd = -1
      return old
    }
    if fd >= 0 { close(fd) }
    unlink(path)
  }

  private func acceptLoop(_ listener: Int32) {
    while true {
      let client = accept(listener, nil, nil)
      if client < 0 {
        if errno == EINTR || errno == ECONNABORTED { continue }
        return
      }
      _ = fcntl(client, F_SETFD, FD_CLOEXEC)
      var noSigPipe: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      guard peerIsSelf(client) else {
        close(client)
        continue
      }
      let admitted = connections.withLock { count -> Bool in
        guard count < ControlProtocol.maxConnections else { return false }
        count += 1
        return true
      }
      guard admitted else {
        close(client)
        continue
      }
      Thread.detachNewThread { [self] in
        defer {
          close(client)
          connections.withLock { $0 -= 1 }
        }
        serve(client)
      }
    }
  }

  private func serve(_ client: Int32) {
    while let line = readLine(client, limit: ControlProtocol.maxFrame) {
      let response: ControlResponse
      do {
        let request = try ControlRequest.decode(line)
        response = ControlResponse(id: request.id, outcome: handler(request))
      } catch {
        // Uncorrelatable frames close the stream.
        guard let value = try? StrictJSON.parse(line, limits: .control),
          let raw = value["request_id"]?.stringValue, let id = try? RequestID(raw)
        else { return }
        response = ControlResponse(id: id, outcome: .failure(error))
      }
      guard writeAll(client, response.frame) else { return }
    }
  }
}

/// The CLI side of the control channel.
package struct ControlClient: Sendable {
  package let path: String
  package let timeout: Int

  package init(path: String, timeout: Int = 600) {
    self.path = path
    self.timeout = timeout
  }

  package func call(_ method: String, _ params: JSONValue = [:]) throws(CIError) -> JSONValue {
    guard let fd = connectUnix(path) else {
      throw CIError(
        .controllerUnavailable, "the iso-ci controller is not running; start it with `iso-ci serve`"
      )
    }
    defer { close(fd) }
    var tv = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let request = ControlRequest(method: method, params: params)
    guard writeAll(fd, request.frame), let line = readLine(fd, limit: 16 << 20) else {
      throw CIError(.controllerUnavailable, "the controller did not reply")
    }
    let response = try ControlResponse.decode(line)
    guard response.id == request.id else { throw CIError.invalid("control reply does not match") }
    return try response.outcome.get()
  }
}
