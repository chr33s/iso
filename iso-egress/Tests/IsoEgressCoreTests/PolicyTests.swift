import Darwin
import Foundation
import Testing

@testable import IsoEgressCore

@Test func hostnamesAreExact() throws {
  #expect(try ExactHostname("Example.COM.").rawValue == "example.com")
  #expect(try ExactHostname("a.example.com") != ExactHostname("example.com"))
  for bad in ["*.example.com", "127.0.0.1", "localhost", "http://example.com", "user@example.com"] {
    #expect(throws: PolicyError.self) { try ExactHostname(bad) }
  }
}

@Test func addressesDenySpecialPurposeRanges() {
  #expect(!AddressPolicy.isPublic("127.0.0.1"))
  #expect(!AddressPolicy.isPublic("10.1.2.3"))
  #expect(!AddressPolicy.isPublic("192.168.1.1"))
  #expect(!AddressPolicy.isPublic("169.254.1.1"))
  #expect(!AddressPolicy.isPublic("224.0.0.1"))
  #expect(!AddressPolicy.isPublic("::1"))
  #expect(!AddressPolicy.isPublic("fe80::1"))
  #expect(!AddressPolicy.isPublic("1.2.3.4", local: ["1.2.3.4"]))
  #expect(AddressPolicy.isPublic("1.1.1.1"))
}

@Test func unapprovedConnectIsDeniedBeforeAnyTargetIsChosen() throws {
  let allow = EgressAllowlist([try ExactHostname("example.com")])
  let denied = Array(
    "CONNECT other.example:443 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n"
      .utf8)
  #expect(
    ConnectGate.connectTarget(denied, allow: allow, capability: "secret")
      == .deny(.hostNotAllowed))
  let approved = Array(
    "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n".utf8)
  #expect(
    ConnectGate.connectTarget(approved, allow: allow, capability: "secret")
      == .connect(
        "example.com"))
  var pair: [Int32] = [-1, -1]
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  defer {
    close(pair[0])
    close(pair[1])
  }
  #expect(denied.withUnsafeBytes { send(pair[0], $0.baseAddress, $0.count, 0) } == denied.count)
  #expect(ConnectGate.approvedHost(pair[1], allow: allow, capability: "secret") == nil)
  let expected = ConnectGate.responseBytes(.hostNotAllowed)
  var buffer = [UInt8](repeating: 0, count: expected.count)
  #expect(recv(pair[0], &buffer, buffer.count, 0) == expected.count)
  #expect(buffer == expected)
  #expect(approved.withUnsafeBytes { send(pair[0], $0.baseAddress, $0.count, 0) } == approved.count)
  #expect(ConnectGate.approvedHost(pair[1], allow: allow, capability: "secret") == "example.com")
}

@Test func approvedTunnelIsByteTransparentAndDropsTheRequestHead() throws {
  var client: [Int32] = [-1, -1]
  var upstream: [Int32] = [-1, -1]
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &client) == 0)
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &upstream) == 0)
  let proxyClient = client[1]
  let proxyUpstream = upstream[1]
  let seen = TunnelHosts()
  let done = NSCondition()
  let finished = TunnelFlag()
  var timeout = timeval(tv_sec: 2, tv_usec: 0)
  setsockopt(client[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  setsockopt(upstream[0], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  let opened = Thread {
    try? Tunnel.open(
      proxyClient, host: "example.com",
      connect: { host in
        seen.add(host)
        return proxyUpstream
      })
    finished.mark()
    done.lock()
    done.signal()
    done.unlock()
  }
  opened.start()
  let established = ConnectGate.responseBytes(nil)
  var header = [UInt8](repeating: 0, count: established.count)
  #expect(recv(client[0], &header, header.count, 0) == established.count)
  #expect(header == established)
  let text = String(decoding: header, as: UTF8.self)
  #expect(!text.contains("Content-Length"))
  #expect(!text.contains("Transfer-Encoding"))
  #expect(!text.contains("Proxy-Authorization"))
  let ping = Array("ping".utf8)
  let pong = Array("pong".utf8)
  #expect(ping.withUnsafeBytes { send(client[0], $0.baseAddress, $0.count, 0) } == ping.count)
  #expect(pong.withUnsafeBytes { send(upstream[0], $0.baseAddress, $0.count, 0) } == pong.count)
  var fromClient = [UInt8](repeating: 0, count: ping.count)
  var fromUpstream = [UInt8](repeating: 0, count: pong.count)
  #expect(recv(upstream[0], &fromClient, fromClient.count, 0) == ping.count)
  #expect(fromClient == ping)
  #expect(String(decoding: fromClient, as: UTF8.self) == "ping")
  #expect(recv(client[0], &fromUpstream, fromUpstream.count, 0) == pong.count)
  #expect(fromUpstream == pong)
  close(client[0])
  client[0] = -1
  done.lock()
  while !finished.isSet {
    if !done.wait(until: Date().addingTimeInterval(2)) { break }
  }
  done.unlock()
  #expect(finished.isSet)
  #expect(seen.hosts == ["example.com"])
  close(client[1])
  close(upstream[0])
}

private final class TunnelHosts: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  func add(_ host: String) {
    lock.lock()
    values.append(host)
    lock.unlock()
  }
  var hosts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

private final class TunnelFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  func mark() {
    lock.lock()
    value = true
    lock.unlock()
  }
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

@Test func connectRequiresAuthAndPort443() throws {
  let ok = Array(
    "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n".utf8)
  let request = try ConnectParser.parse(ok)
  #expect(request.host.rawValue == "example.com")
  #expect(request.password == "secret")
  let missing = Array("CONNECT example.com:443 HTTP/1.1\r\n\r\n".utf8)
  #expect(throws: DenialError.self) { try ConnectParser.parse(missing) }
  let port = Array(
    "CONNECT example.com:80 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n".utf8)
  #expect(throws: DenialError.self) { try ConnectParser.parse(port) }
  let body = Array(
    "CONNECT example.com:443 HTTP/1.1\r\nContent-Length: 1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n"
      .utf8)
  #expect(throws: DenialError.self) { try ConnectParser.parse(body) }
}
