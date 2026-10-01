import Darwin

/// Confinement probes shared by `iso-proxy` and `iso-inference`. Each runs
/// the operation its Seatbelt profile must deny and reports the errno; a
/// denial is `EPERM` or `EACCES`, not a missing path or an unreachable host.
public enum JailProbes {
  public static func isDenial(_ error: Int32) -> Bool { error == EPERM || error == EACCES }

  /// Sets the core-dump limit to zero; false when that fails.
  public static func disableCoreDumps() -> Bool {
    var limit = rlimit(rlim_cur: 0, rlim_max: 0)
    return setrlimit(RLIMIT_CORE, &limit) == 0
  }

  /// Creates and removes `path`; 0 when the write was allowed.
  public static func createError(_ path: String) -> Int32 {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return errno }
    close(fd)
    unlink(path)
    return 0
  }

  /// Spawns `/bin/sh -c 'exit 0'`; 0 when execution was allowed.
  public static func spawnError() -> Int32 {
    var arguments: [UnsafeMutablePointer<CChar>?] = [
      strdup("/bin/sh"), strdup("-c"), strdup("exit 0"), nil,
    ]
    defer { for argument in arguments.compactMap({ $0 }) { free(argument) } }
    guard arguments.prefix(3).allSatisfy({ $0 != nil }) else { return ENOMEM }
    var environment: [UnsafeMutablePointer<CChar>?] = [nil]
    var pid: pid_t = 0
    let result = arguments.withUnsafeMutableBufferPointer { args in
      environment.withUnsafeMutableBufferPointer { env in
        guard let args = args.baseAddress, let env = env.baseAddress else { return EINVAL }
        return posix_spawn(&pid, "/bin/sh", nil, nil, args, env)
      }
    }
    if result == 0 {
      var status: Int32 = 0
      while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    }
    return result
  }

  /// Binds a TCP socket to `address` on an ephemeral port and listens; 0
  /// when that was allowed.
  public static func listenError(address text: String) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr(text))
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        bind(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { return errno }
    return listen(fd, 1) == 0 ? 0 : errno
  }

  /// A non-blocking TCP connect to `address:port`; the immediate errno (0,
  /// or `EINPROGRESS` when the connect was allowed and is pending).
  public static func connectError(address text: String, port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr(text))
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 ? 0 : errno
      }
    }
  }
}
