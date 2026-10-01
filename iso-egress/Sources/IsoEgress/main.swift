import Darwin
import Foundation
import IsoEgressCore

/// fd 3 is the supervisor's renewal pipe. No byte for 2 seconds, or EOF,
/// closes the listener. This is not a runtime boot-id check.
enum Lease {
  static let fd: Int32 = 3
  static let limit: TimeInterval = 2
  nonisolated(unsafe) static var last = Date()

  static func alive() -> Bool {
    var probe = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&probe, 1, 0)
    if ready < 0 { return errno == EINTR && Date().timeIntervalSince(last) <= limit }
    if probe.revents & Int16(POLLIN) != 0 {
      var byte: UInt8 = 0
      let count = recv(fd, &byte, 1, 0)
      if count <= 0 { return false }
      last = Date()
    }
    if probe.revents & (Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)) != 0 { return false }
    return Date().timeIntervalSince(last) <= limit
  }
}

struct Startup: Decodable {
  let listen: String
  let capability: String
  let allowedHosts: [String]
}

enum EgressMain {
  static func run() throws {
    let startup = try JSONDecoder().decode(
      Startup.self, from: FileHandle.standardInput.readDataToEndOfFile())
    guard let portText = startup.listen.split(separator: ":").last,
      startup.listen.hasPrefix("127.0.0.1:"),
      let port = UInt16(portText)
    else { throw PolicyError("listener must be 127.0.0.1:<port>") }
    var hosts: [ExactHostname] = []
    for raw in startup.allowedHosts { hosts.append(try ExactHostname(raw)) }
    let allow = EgressAllowlist(hosts)
    let fd = try listenLoopback(port)
    FileHandle.standardError.write(Data("iso-egress listening 127.0.0.1:\(port)\n".utf8))
    while Lease.alive() {
      var listen = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      if poll(&listen, 1, 200) < 0 {
        if errno == EINTR { continue }
        break
      }
      if listen.revents & Int16(POLLIN) == 0 { continue }
      let client = accept(fd, nil, nil)
      if client >= 0 { handle(client, allow: allow, capability: startup.capability) }
    }
    close(fd)
    Foundation.exit(0)
  }

  static func listenLoopback(_ port: UInt16) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw PolicyError("socket failed") }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 16) == 0 else {
      throw PolicyError("bind failed")
    }
    return fd
  }

  static func handle(_ client: Int32, allow: EgressAllowlist, capability: String) {
    defer { close(client) }
    var head = [UInt8]()
    var byte: UInt8 = 0
    while head.count < 16 * 1024 {
      if recv(client, &byte, 1, 0) != 1 { return }
      head.append(byte)
      if head.suffix(4) == [13, 10, 13, 10] { break }
    }
    do {
      let request = try ConnectParser.parse(head)
      guard ConnectParser.constantTimeEqual(request.password, capability) else {
        return respond(client, .authRequired)
      }
      guard allow.allows(request.host) else { return respond(client, .hostNotAllowed) }
      guard let upstream = try connectPublic(request.host.rawValue) else {
        return respond(client, .addressNotPublic)
      }
      defer { close(upstream) }
      respond(client, nil)
      relay(client, upstream)
    } catch let error as DenialError {
      respond(client, error.denial)
    } catch {
      respond(client, .unsupported)
    }
  }

  static func connectPublic(_ host: String) throws -> Int32? {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, "443", &hints, &info) == 0, let info else { return nil }
    defer { freeaddrinfo(info) }
    var cursor: UnsafeMutablePointer<addrinfo>? = info
    var addresses: [String] = []
    while let node = cursor {
      if let text = numeric(node) { addresses.append(text) }
      cursor = node.pointee.ai_next
    }
    guard !addresses.isEmpty, addresses.allSatisfy({ AddressPolicy.isPublic($0) }) else {
      return nil
    }
    guard let first = info.pointee.ai_addr else { return nil }
    let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    if connect(fd, first, info.pointee.ai_addrlen) != 0 {
      close(fd)
      return nil
    }
    return fd
  }

  static func numeric(_ node: UnsafeMutablePointer<addrinfo>) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    guard
      getnameinfo(
        node.pointee.ai_addr, node.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0,
        NI_NUMERICHOST) == 0
    else { return nil }
    return String(cString: buffer)
  }

  static func respond(_ client: Int32, _ denial: Denial?) {
    let text =
      denial == nil
      ? "HTTP/1.1 200 Connection Established\r\n\r\n"
      : "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    _ = Array(text.utf8).withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
  }

  static func relay(_ left: Int32, _ right: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    var fds = [
      pollfd(fd: left, events: Int16(POLLIN), revents: 0),
      pollfd(fd: right, events: Int16(POLLIN), revents: 0),
    ]
    while Lease.alive() {
      if poll(&fds, 2, 200) <= 0 { continue }
      for index in 0..<2 where fds[index].revents & Int16(POLLIN) != 0 {
        let count = recv(fds[index].fd, &buffer, buffer.count, 0)
        if count <= 0 { return }
        let peer = fds[1 - index].fd
        var sent = 0
        while sent < count {
          let n = buffer.withUnsafeBytes { send(peer, $0.baseAddress! + sent, count - sent, 0) }
          if n <= 0 { return }
          sent += n
        }
      }
    }
  }
}

do { try EgressMain.run() } catch {
  FileHandle.standardError.write(Data("iso-egress: \(error)\n".utf8))
  exit(1)
}
