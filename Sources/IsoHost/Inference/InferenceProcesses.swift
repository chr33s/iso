import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// The sessions one command has established or verified, so later agent
/// and session steps of that command reuse them without asking the gateway
/// again. An entry holds only while the sandbox owner that carries the
/// relay is the same process (PID and start time), and records whether
/// Claude's managed settings already carry its capability.
final class SessionMemo: Sendable {
  struct Entry: Sendable {
    let fingerprint: String
    let session: InferenceSession
    /// The sandbox owner and, for a brokered boot, the forward.
    let bound: [BoundProcess]
    var claudeSettingsWritten = false
  }

  /// Keyed by instance directory.
  private let entries = Mutex<[String: Entry]>([:])

  func remember(_ instance: Instance, _ entry: Entry) {
    entries.withLock { $0[instance.directory] = entry }
  }

  func forget(_ instance: Instance) {
    _ = entries.withLock { $0.removeValue(forKey: instance.directory) }
  }

  /// The remembered session, while every process it is bound to still runs.
  func session(_ instance: Instance, fingerprint: String) -> InferenceSession? {
    guard let entry = entries.withLock({ $0[instance.directory] }),
      entry.fingerprint == fingerprint,
      !entry.bound.isEmpty, entry.bound.allSatisfy(\.isAlive)
    else { return nil }
    return entry.session
  }

  /// Marks Claude's managed settings as written for `session`; false when
  /// this command already wrote them for it.
  func markClaudeSettings(_ instance: Instance, session: InferenceSession) -> Bool {
    entries.withLock { entries in
      guard var entry = entries[instance.directory], entry.session == session else { return true }
      guard !entry.claudeSettingsWritten else { return false }
      entry.claudeSettingsWritten = true
      entries[instance.directory] = entry
      return true
    }
  }
}

/// Process facts from the kernel (`proc_pidinfo`), for binding a gateway
/// session to an exact process rather than a reusable PID.
enum HostProcess {
  /// `SECONDS.MICROSECONDS` start time, the gateway's wire form.
  static func start(_ pid: Int32) -> String? {
    bsdInfo(pid).map { "\($0.pbi_start_tvsec).\($0.pbi_start_tvusec)" }
  }

  private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
  }

  static func uid(_ pid: Int32) -> uid_t? {
    bsdInfo(pid)?.pbi_uid
  }

  /// The audit token's PID version of `pid` (`TASK_AUDIT_TOKEN` through its
  /// task name port): with the PID, it names one process. nil when the
  /// process is gone or not inspectable.
  static func pidVersion(_ pid: Int32) -> UInt32? {
    var name = mach_port_name_t(MACH_PORT_NULL)
    guard task_name_for_pid(mach_task_self_, pid, &name) == KERN_SUCCESS else { return nil }
    defer { mach_port_deallocate(mach_task_self_, name) }
    var token = audit_token_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &token) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(name, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
      }
    }
    guard result == KERN_SUCCESS, Int32(bitPattern: token.val.5) == pid else { return nil }
    return token.val.7
  }

  static func executablePath(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

/// Client side of the gateway's control socket.
enum ControlSocket {
  struct Peer {
    let pid: Int32
    let uid: uid_t
  }

  static func open(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HostError.posix("Failed to create socket for", path) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      throw HostError("control socket path \(path) is too long")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else {
      close(fd)
      throw HostError.posix("Failed to connect to", path)
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
  }

  static func peer(_ path: String) throws -> Peer {
    let fd = try open(path)
    defer { close(fd) }
    return try peer(fd)
  }

  static func peer(_ fd: Int32) throws -> Peer {
    var uid: uid_t = 0
    var gid: gid_t = 0
    var pid: pid_t = 0
    var length = socklen_t(MemoryLayout<pid_t>.size)
    guard getpeereid(fd, &uid, &gid) == 0,
      getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0
    else { throw HostError("cannot identify the inference control socket's peer") }
    return Peer(pid: pid, uid: uid)
  }

  /// No gateway accepted a connection.
  struct Unreachable: Error {
    let reason: String
  }

  /// One framed request and reply; `verify` checks the peer of this very
  /// connection before anything is sent.
  static func exchange(
    _ path: String, _ body: [UInt8], timeoutSeconds: Int, verify: (Peer) throws -> Void
  ) throws -> [UInt8] {
    let fd: Int32
    do { fd = try open(path) } catch { throw Unreachable(reason: "\(error)") }
    defer { close(fd) }
    try verify(try peer(fd))
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    let length = UInt32(body.count)
    let frame =
      [
        UInt8(length >> 24), UInt8((length >> 16) & 0xFF), UInt8((length >> 8) & 0xFF),
        UInt8(length & 0xFF),
      ] + body
    var offset = 0
    while offset < frame.count {
      let sent = frame[offset...].withUnsafeBytes {
        send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL)
      }
      if sent < 0 && errno == EINTR { continue }
      guard sent > 0 else { throw HostError("the inference gateway closed the control socket") }
      offset += sent
    }
    let header = try read(fd, 4)
    let size = header.reduce(0) { ($0 << 8) | Int($1) }
    guard size <= 256 << 10 else {
      throw HostError("the inference gateway sent an oversized reply")
    }
    return try read(fd, size)
  }

  static func read(_ fd: Int32, _ count: Int) throws -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let received = buffer[offset...].withUnsafeMutableBytes {
        recv(fd, $0.baseAddress, $0.count, 0)
      }
      if received < 0 && errno == EINTR { continue }
      guard received > 0 else { throw HostError("the inference gateway did not reply") }
      offset += received
    }
    return buffer
  }
}

/// Unprivileged TCP reachability probes.
enum Socket {
  /// IPv4 and IPv6 addresses of every up, non-loopback interface: the
  /// addresses a guest (or the LAN) could use to reach a host service.
  static func nonLoopbackAddresses() -> [String] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }
    var out: [String] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      let flags = Int32(entry.pointee.ifa_flags)
      guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr
      else { continue }
      let family = Int32(address.pointee.sa_family)
      guard family == AF_INET || family == AF_INET6 else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      let text = String(
        decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      if !out.contains(text) { out.append(text) }
    }
    return out
  }

  static func connects(host: String, port: UInt16, timeoutMilliseconds: Int32) -> Bool {
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else {
      return false
    }
    defer { freeaddrinfo(result) }
    let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    if Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&descriptor, 1, timeoutMilliseconds) == 1 else { return false }
    var error: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
  }
}
