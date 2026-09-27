import Darwin
import Foundation

/// These probes run before reading stdin, while no provider secret is present.
/// Denial must specifically be a permission error, not a missing path or socket.
enum Jail {
  enum Failure: Error { case coreLimit, fileWriteAllowed, execAllowed, egressAllowed, httpsDenied }

  static func disableCoreDumps() throws {
    var limit = rlimit(rlim_cur: 0, rlim_max: 0)
    guard setrlimit(RLIMIT_CORE, &limit) == 0 else { throw Failure.coreLimit }
  }

  static func requireConfinement() throws {
    let path = "/private/tmp/coop-proxy-jail-" + UUID().uuidString
    let fd = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    if fd >= 0 {
      Darwin.close(fd)
      Darwin.unlink(path)
      throw Failure.fileWriteAllowed
    }
    guard errno == EPERM || errno == EACCES else { throw Failure.fileWriteAllowed }

    let spawnError = probeExec()
    guard spawnError == EPERM || spawnError == EACCES else { throw Failure.execAllowed }

    let blockedPort = UInt16.random(in: 49152...65535)
    let other = connectError(port: blockedPort)
    guard other == EPERM || other == EACCES else { throw Failure.egressAllowed }
    let https = connectError(port: 443)
    guard https != EPERM && https != EACCES else { throw Failure.httpsDenied }
  }

  private static func probeExec() -> Int32 {
    var arguments: [UnsafeMutablePointer<CChar>?] = [
      strdup("/bin/sh"), strdup("-c"), strdup("exit 0"), nil,
    ]
    defer {
      for argument in arguments.compactMap({ $0 }) { free(argument) }
    }
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

  private static func connectError(port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { Darwin.close(fd) }
    _ = fcntl(fd, F_SETFL, O_NONBLOCK)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    return withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
        Darwin.connect(fd, pointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 ? 0 : errno
      }
    }
  }
}
