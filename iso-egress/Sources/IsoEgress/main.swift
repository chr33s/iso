import Darwin
import Foundation
import IsoEgressCore

/// fd 3 is the supervisor's renewal pipe. No byte for 2 seconds, or EOF,
/// closes the listener. This is not a runtime boot-id check.
enum Lease {
  static let fd: Int32 = 3
  static let limit = Monotonic.nanoseconds(EgressBudgets.lease)
  static let lock = NSLock()
  nonisolated(unsafe) static var last = Monotonic.now()

  static func alive() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    var probe = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&probe, 1, 0)
    if ready < 0 {
      return errno == EINTR && Monotonic.within(last, now: Monotonic.now(), limit: limit)
    }
    if probe.revents & Int16(POLLIN) != 0 {
      var byte: UInt8 = 0
      let count = recv(fd, &byte, 1, 0)
      if count <= 0 { return false }
      last = Monotonic.now()
    }
    if probe.revents & (Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)) != 0 { return false }
    return Monotonic.within(last, now: Monotonic.now(), limit: limit)
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
    let admission = Admission()
    FileHandle.standardError.write(Data("iso-egress listening 127.0.0.1:\(port)\n".utf8))
    while Lease.alive() {
      var listen = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      if poll(&listen, 1, 200) < 0 {
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
        handle(client, allow: allow, capability: capability, admission: admission)
      }.start()
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
    guard bound == 0, listen(fd, Int32(EgressBudgets.maxSockets)) == 0 else {
      throw PolicyError("bind failed")
    }
    return fd
  }

  static func handle(
    _ client: Int32, allow: EgressAllowlist, capability: String, admission: Admission
  ) {
    defer { close(client) }
    guard let host = ConnectGate.approvedHost(client, allow: allow, capability: capability) else {
      return
    }
    guard admission.tryTunnel() else {
      respond(client, .unsupported)
      return
    }
    defer { admission.endTunnel() }
    do {
      try Tunnel.open(
        client, host: host, connect: { try connectPublic($0, admission: admission) },
        alive: Lease.alive)
    } catch {
      respond(client, .unsupported)
    }
  }

  static func connectPublic(_ host: String, admission: Admission) throws -> Int32? {
    let local = HostAddresses.current()
    guard admission.tryDNS() else { return nil }
    defer { admission.endDNS() }
    guard let info = Resolver.lookup(host) else { return nil }
    defer { freeaddrinfo(info) }
    var cursor: UnsafeMutablePointer<addrinfo>? = info
    var addresses: [String] = []
    while let node = cursor {
      if let text = numeric(node) { addresses.append(text) }
      cursor = node.pointee.ai_next
    }
    guard AddressChoice.firstPublic(addresses, local: local) != nil else { return nil }
    guard let first = info.pointee.ai_addr else { return nil }
    let fd = socket(info.pointee.ai_family, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    guard Dial.connect(fd, address: first, length: info.pointee.ai_addrlen),
      Dial.peerIsPublic(fd, local: local)
    else {
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
    ConnectGate.writeResponse(client, denial)
  }
}

do { try EgressMain.run() } catch {
  FileHandle.standardError.write(Data("iso-egress: \(error)\n".utf8))
  exit(1)
}
