// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Darwin

/// Confinement probes shared by `iso-proxy` and `iso-inference`. Each one
/// attempts an operation the process's Seatbelt profile must deny (or allow)
/// and reports the errno. A denial is specifically a permission error
/// (`EPERM` or `EACCES`), not a missing path or an unreachable host.
/// `iso-egress` keeps its own copy: that package links no `iso-proxy` code.
package enum JailProbes {
  package static func isDenial(_ code: Int32) -> Bool { code == EPERM || code == EACCES }

  /// Sets the core-dump limit to zero; false when that fails.
  package static func disableCoreDumps() -> Bool {
    var limit = rlimit(rlim_cur: 0, rlim_max: 0)
    // setrlimit only reads the one rlimit borrowed for this call.
    return unsafe setrlimit(RLIMIT_CORE, &limit) == 0
  }

  /// Creates `path` exclusively and removes it again; 0 when the write was
  /// allowed.
  package static func createError(_ path: String) -> Int32 {
    // The C path is borrowed for each call only.
    let fd = unsafe Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return errno }
    Darwin.close(fd)
    unsafe Darwin.unlink(path)
    return 0
  }

  /// Opens `path` read-only; 0 when the read was allowed.
  package static func openError(_ path: String) -> Int32 {
    // The C path is borrowed for the call only.
    let fd = unsafe Darwin.open(path, O_RDONLY)
    guard fd >= 0 else { return errno }
    Darwin.close(fd)
    return 0
  }

  /// The errno of reading the invoking user's home directory. A missing
  /// home proves nothing, so `/Users`, which always exists, stands in.
  package static func homeReadError() -> Int32 {
    let home = openError(homeDirectory())
    return home == ENOENT ? openError("/Users") : home
  }

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

  /// Spawns `/bin/sh -c 'exit 0'`; 0 when program execution was allowed.
  package static func spawnError() -> Int32 {
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

  /// The errno of a non-blocking TCP connect to `host:port`; 0 or
  /// `EINPROGRESS` when the connect was permitted.
  package static func connectError(_ host: String, port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { Darwin.close(fd) }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var address = ipv4(host, port: port)
    // One sockaddr_in viewed as a sockaddr of its exact length, for this call only.
    return withUnsafePointer(to: &address) { pointer in
      unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        unsafe Darwin.connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
          ? 0 : errno
      }
    }
  }

  /// The errno of binding a TCP socket to `host` on an ephemeral port and
  /// listening on it; 0 when both were permitted.
  package static func listenError(_ host: String) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { Darwin.close(fd) }
    var address = ipv4(host, port: 0)
    // One sockaddr_in viewed as a sockaddr of its exact length, for this call only.
    let bound = withUnsafePointer(to: &address) { pointer in
      unsafe pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        unsafe bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { return errno }
    return listen(fd, 1) == 0 ? 0 : errno
  }

  private static func ipv4(_ host: String, port: UInt16) -> sockaddr_in {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    // The C string is borrowed for the call only.
    address.sin_addr = in_addr(s_addr: unsafe inet_addr(host))
    return address
  }
}
