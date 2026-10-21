import Darwin
import Foundation
import IsoEgressCore

struct Startup: Decodable {
  let listen: String
  let capability: String
  let allowedHosts: [String]
  let readiness: ReadinessIdentity?

  struct ReadinessIdentity: Decodable {
    let version: Int
    let privateKeyHex: String
    let bootID: String
  }
}

enum EgressMain {
  static func run() throws {
    let startup = try JSONDecoder().decode(
      Startup.self, from: FileHandle.standardInput.readDataToEndOfFile())
    guard let portText = startup.listen.split(separator: ":").last,
      startup.listen.hasPrefix("127.0.0.1:"),
      let port = UInt16(portText)
    else { throw PolicyError("listener must be 127.0.0.1:<port>") }
    var rules: [HostRule] = []
    for raw in startup.allowedHosts { rules.append(try HostRule(raw)) }
    let allow = EgressAllowlist(rules: rules)
    let readiness: EgressReadiness?
    if let identity = startup.readiness {
      guard identity.version == 2 else { throw PolicyError("unsupported readiness version") }
      readiness = try EgressReadiness(
        privateKeyHex: identity.privateKeyHex, bootID: identity.bootID, allow: allow)
    } else {
      readiness = nil
    }
    let fd = try listenLoopback(port)
    let admission = Admission()
    // fd 3 belongs to the host supervisor, never to a guest HTTP connection.
    let lease = ControlLease(descriptor: 3)
    FileHandle.standardError.write(Data("iso-egress listening 127.0.0.1:\(port)\n".utf8))
    while lease.alive() {
      var listen = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      if unsafe poll(&listen, 1, 200) < 0 {
        if errno == EINTR { continue }
        break
      }
      if listen.revents & Int16(POLLIN) == 0 { continue }
      let client = accept(fd, nil, nil)
      guard client >= 0 else { continue }
      guard admission.trySocket() else {
        close(client)
        continue
      }
      let capability = startup.capability
      Thread {
        defer { admission.endSocket() }
        EgressSession.handle(
          client, allow: allow, capability: capability, admission: admission, lease: lease,
          readiness: readiness)
      }.start()
    }
    close(fd)
    Foundation.exit(0)
  }

  static func listenLoopback(_ port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw PolicyError("socket failed") }
    var reuse: Int32 = 1
    unsafe setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: unsafe inet_addr("127.0.0.1"))
    // One sockaddr_in viewed as a sockaddr of its exact length, for the call only.
    let bound = withUnsafePointer(to: &address) {
      unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, Int32(EgressBudgets.maxSockets)) == 0 else {
      throw PolicyError("bind failed")
    }
    return fd
  }

}

if CommandLine.arguments.dropFirst().elementsEqual(["--version"]) {
  print("iso-egress \(EgressVersion.string)")
  exit(0)
}

if CommandLine.arguments.dropFirst().elementsEqual(["--jail-selftest"]) {
  exit(JailSelfTest.run())
}

do { try EgressMain.run() } catch {
  FileHandle.standardError.write(Data("iso-egress: \(error)\n".utf8))
  exit(1)
}

enum JailSelfTest {
  static func run() -> Int32 {
    var failures: [String] = []
    if writeAllowed() { failures.append("file write was allowed") }
    if execAllowed() { failures.append("child execution was allowed") }
    if connectErrno(80) != EPERM { failures.append("port 80 was not denied") }
    if connectErrno(443) == EPERM { failures.append("port 443 was denied by the profile") }
    if !bindAllowed() { failures.append("loopback bind was denied") }
    if unsafe getenv("HTTP_PROXY") != nil || getenv("http_proxy") != nil {
      failures.append("inherited proxy variable was visible")
    }
    if failures.isEmpty {
      FileHandle.standardError.write(
        Data("iso-egress jail self-test: write/exec/non-443 denied; loopback bind allowed\n".utf8))
      return 0
    }
    let text = "iso-egress jail self-test failed: \(failures.joined(separator: "; "))\n"
    FileHandle.standardError.write(Data(text.utf8))
    return 1
  }

  static func writeAllowed() -> Bool {
    let path = "/tmp/iso-egress-jail-\(getpid())"
    // The C path is borrowed for each call only.
    let fd = unsafe open(path, O_CREAT | O_WRONLY | O_EXCL, 0o600)
    if fd >= 0 {
      close(fd)
      unsafe unlink(path)
      return true
    }
    return false
  }

  static func execAllowed() -> Bool {
    var pid: pid_t = 0
    // A strdup copy, freed on return, in a NULL-terminated argv; the self-test
    // does not check strdup for failure.
    let path = unsafe strdup("/usr/bin/true")
    defer { unsafe free(path) }
    var arguments: [UnsafeMutablePointer<CChar>?] = unsafe [path, nil]
    let result = unsafe posix_spawn(&pid, path, nil, nil, &arguments, nil)
    if result == 0 {
      waitpid(pid, nil, 0)
      return true
    }
    return false
  }

  static func connectErrno(_ port: UInt16) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return errno }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: unsafe inet_addr("127.0.0.1"))
    // One sockaddr_in viewed as a sockaddr of its exact length, for the call only.
    let connected = withUnsafePointer(to: &address) {
      unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        unsafe Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return connected == 0 ? 0 : errno
  }

  static func bindAllowed() -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr = in_addr(s_addr: unsafe inet_addr("127.0.0.1"))
    // One sockaddr_in viewed as a sockaddr of its exact length, for the call only.
    return withUnsafePointer(to: &address) {
      unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        unsafe bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }
}
