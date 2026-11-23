import Darwin
import IsoInferenceCore

/// A listening, owner-only (`0600`) Unix socket at `path`, replacing a stale
/// file. The caller owns the descriptor.
func bindUnixListener(_ path: String, backlog: Int32 = 16) throws -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw GatewayError.startup("cannot create a socket for \(path)") }
  var address = try unixAddress(path, fd: fd)
  unsafe unlink(path)
  // One sockaddr_un viewed as a sockaddr of its exact length, for this call only.
  let bound = withUnsafePointer(to: &address) {
    unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard bound == 0, unsafe chmod(path, 0o600) == 0, listen(fd, backlog) == 0 else {
    close(fd)
    throw GatewayError.startup("cannot bind \(path)")
  }
  return fd
}

/// A blocking connection to the Unix socket at `path`.
func connectUnix(_ path: String) throws -> Int32 {
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  guard fd >= 0 else { throw GatewayError.startup("cannot create a socket for \(path)") }
  var address = try unixAddress(path, fd: fd)
  // One sockaddr_un viewed as a sockaddr of its exact length, for this call only.
  let connected = withUnsafePointer(to: &address) {
    unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      unsafe connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  guard connected == 0 else {
    close(fd)
    throw GatewayError.startup("cannot connect to \(path)")
  }
  var one: Int32 = 1
  // setsockopt borrows one local value for the call.
  unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  return fd
}

private func unixAddress(_ path: String, fd: Int32) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
    close(fd)
    throw GatewayError.startup("socket path is too long")
  }
  // sun_path is a fixed inline array; the path and its NUL fit (checked above).
  withUnsafeMutableBytes(of: &address.sun_path) { raw in
    unsafe raw.copyBytes(from: bytes)
    unsafe raw[bytes.count] = 0
  }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return address
}

/// One length-prefixed frame from `fd`, or nil at EOF, on error or when the
/// frame is over the control protocol's bound.
func readFrame(_ fd: Int32) -> [UInt8]? {
  guard let header = readExactly(fd, 4), let length = ControlProtocol.frameLength(header) else {
    return nil
  }
  return readExactly(fd, length)
}

/// The peer of an accepted Unix-socket descriptor: its UID and PID.
func unixPeer(_ fd: Int32) -> (uid: uid_t, pid: pid_t)? {
  var uid: uid_t = 0
  var gid: gid_t = 0
  var pid: pid_t = 0
  var length = socklen_t(MemoryLayout<pid_t>.size)
  // getpeereid and getsockopt each borrow one local value for the call.
  guard unsafe getpeereid(fd, &uid, &gid) == 0,
    unsafe getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0
  else { return nil }
  return (uid, pid)
}

func setTimeouts(_ fd: Int32, seconds: Int) {
  var timeout = timeval(tv_sec: seconds, tv_usec: 0)
  // setsockopt borrows one local value for each call.
  unsafe setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  unsafe setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}
