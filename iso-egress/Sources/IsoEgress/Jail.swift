// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0
// Mirrors iso-proxy/Sources/IsoProxy/Jail.swift; the packages share no code.

import Darwin
import Foundation

/// These probes run before reading stdin, while neither the readiness key nor the
/// CONNECT capability is present.
/// Denial must specifically be a permission error, not a missing path or socket.
enum Jail {
  enum Failure: Error {
    case coreLimit, fileWriteAllowed, execAllowed, egressAllowed, loopbackHTTPSAllowed
    case loopbackDNSAllowed, httpsDenied, homeReadAllowed
  }

  static func disableCoreDumps() throws {
    var limit = rlimit(rlim_cur: 0, rlim_max: 0)
    // setrlimit only reads the one rlimit borrowed for this call.
    guard unsafe setrlimit(RLIMIT_CORE, &limit) == 0 else { throw Failure.coreLimit }
  }

  static func requireConfinement() throws {
    let path = "/private/tmp/iso-egress-jail-" + UUID().uuidString
    // The C path is borrowed for each call only.
    let fd = unsafe Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    if fd >= 0 {
      Darwin.close(fd)
      unsafe Darwin.unlink(path)
      throw Failure.fileWriteAllowed
    }
    guard denied(errno) else { throw Failure.fileWriteAllowed }

    guard denied(probeExec()) else { throw Failure.execAllowed }

    let blockedPort = UInt16.random(in: 49152...65535)
    guard denied(connectError("127.0.0.1", port: blockedPort)) else { throw Failure.egressAllowed }
    // Ports 443 and 53 are open to the network only; loopback services stay out of reach.
    guard denied(connectError("127.0.0.1", port: 443)) else { throw Failure.loopbackHTTPSAllowed }
    guard denied(connectError("127.0.0.1", port: 53)) else { throw Failure.loopbackDNSAllowed }
    // A TEST-NET-1 address: the non-blocking connect is only started, never completed.
    guard !denied(connectError("192.0.2.1", port: 443)) else { throw Failure.httpsDenied }

    // A missing home proves nothing; /Users always exists.
    var home = openError(homeDirectory())
    if home == ENOENT { home = openError("/Users") }
    guard denied(home) else { throw Failure.homeReadAllowed }
  }

  private static func denied(_ code: Int32) -> Bool { code == EPERM || code == EACCES }

  /// The invoking user's home directory from the user database, not `HOME`,
  /// which sandbox-exec does not pass.
  private static func homeDirectory() -> String {
    // getpwuid's static record is read immediately on this thread.
    guard let entry = unsafe getpwuid(getuid()), let directory = unsafe entry.pointee.pw_dir else {
      return "/Users"
    }
    let home = unsafe String(cString: directory)
    return home.hasPrefix("/") && home != "/" ? home : "/Users"
  }

  private static func openError(_ path: String) -> Int32 {
    // The C path is borrowed for the call only.
    let fd = unsafe Darwin.open(path, O_RDONLY)
    guard fd >= 0 else { return errno }
    Darwin.close(fd)
    return 0
  }

  private static func probeExec() -> Int32 {
    // A NULL-terminated argv of owned strdup copies, each freed once on return.
    var arguments: [UnsafeMutablePointer<CChar>?] = unsafe [
      strdup("/bin/sh"), strdup("-c"), strdup("exit 0"), nil,
    ]
    defer {
      for unsafe argument in unsafe arguments.compactMap({ unsafe $0 }) { unsafe free(argument) }
    }
    guard unsafe arguments.prefix(3).allSatisfy({ unsafe $0 != nil }) else { return ENOMEM }
    var environment: [UnsafeMutablePointer<CChar>?] = unsafe [nil]
    var pid: pid_t = 0
    // posix_spawn reads both NULL-terminated arrays only during the call.
    let result = arguments.withUnsafeMutableBufferPointer { args in
      environment.withUnsafeMutableBufferPointer { env in
        guard let args = args.baseAddress, let env = env.baseAddress else { return EINVAL }
        return unsafe posix_spawn(&pid, "/bin/sh", nil, nil, args, env)
      }
    }
    if result == 0 {
      var status: Int32 = 0
      while unsafe waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    return result
  }

  /// The errno of a non-blocking connect; 0 or EINPROGRESS when permitted.
  private static func connectError(_ host: String, port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { Darwin.close(fd) }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: unsafe inet_addr(host))
    // One sockaddr_in viewed as a sockaddr of its exact length, for this call only.
    return withUnsafePointer(to: &address) { pointer in
      unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        unsafe Darwin.connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
          ? 0 : errno
      }
    }
  }
}
