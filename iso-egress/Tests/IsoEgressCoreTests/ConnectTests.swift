import Darwin
import Foundation
import Testing

@testable import IsoEgressCore

private func connectPair() throws -> (Int32, Int32) {
  var pair: [Int32] = [-1, -1]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  var capacity: Int32 = 65536
  do {
    for fd in pair {
      try #require(
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size)) == 0)
    }
  } catch {
    for fd in pair { close(fd) }
    throw error
  }
  return (pair[0], pair[1])
}

private func connectSend(_ bytes: [UInt8], to fd: Int32) throws {
  try #require(bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) } == bytes.count)
}

private func connectFill(_ fd: Int32) throws {
  let flags = fcntl(fd, F_GETFL)
  try #require(flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0)
  defer { _ = fcntl(fd, F_SETFL, flags) }
  var size: Int32 = 4096
  try #require(
    setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0)
  let block = [UInt8](repeating: 1, count: 4096)
  while block.withUnsafeBytes({ send(fd, $0.baseAddress, block.count, 0) }) > 0 {}
  var byte: UInt8 = 1
  while send(fd, &byte, 1, 0) == 1 {}
  try #require(errno == EAGAIN || errno == EWOULDBLOCK)
}

private let connectHead =
  "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n"

@Test func connectRejectsIncompleteAndAmbiguousFramingBeforeChoosingATarget() throws {
  let allow = EgressAllowlist([try ExactHostname("example.com")])
  #expect(
    ConnectGate.connectTarget(Array(connectHead.utf8), allow: allow, capability: "secret")
      == .connect("example.com"))
  for invalid in [
    String(decoding: connectHead.utf8.dropLast(2), as: UTF8.self),
    String(decoding: connectHead.utf8.dropLast(4), as: UTF8.self) + "XX\r\n",
    String(decoding: connectHead.utf8.dropLast(2), as: UTF8.self) + "X-End: v\r\nX-End: v",
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length: 0\r\n\r\n"),
    connectHead.replacingOccurrences(
      of: "\r\n\r\n", with: "\r\nTransfer-Encoding: chunked\r\n\r\n"),
    connectHead + "\r\n",
    connectHead + "body",
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length : 0\r\n\r\n"),
    connectHead.replacingOccurrences(
      of: "\r\n\r\n", with: "\r\nTransfer-Encoding\t: chunked\r\n\r\n"),
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\n folded-value\r\n\r\n"),
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\n: empty-name\r\n\r\n"),
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHeaderWithoutColon\r\n\r\n"),
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Test: a\nb\r\n\r\n"),
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Test: a\u{7f}b\r\n\r\n"),
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: other.example:443\r\n\r\n"),
    connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\nHost: example.com:80\r\n\r\n"),
    connectHead.replacingOccurrences(
      of: "\r\n\r\n", with: "\r\nHost: example.com:443\r\nhost: example.com:443\r\n\r\n"),
  ] {
    #expect(
      ConnectGate.connectTarget(Array(invalid.utf8), allow: allow, capability: "secret")
        == .deny(.unsupported))
  }
}

@Test func connectPreservesValidClientsAndClosedAuthentication() throws {
  let allow = EgressAllowlist([try ExactHostname("example.com")])
  for headers in [
    "", "Host: EXAMPLE.COM.:443\r\n",
    "Host: example.com\r\nProxy-Connection: Keep-Alive\r\nUser-Agent: fixture\r\n",
    "X-T!#$%&'*+-.^_`|~: \tvalue\t\r\n",
  ] {
    let valid = connectHead.replacingOccurrences(of: "\r\n\r\n", with: "\r\n" + headers + "\r\n")
    #expect(
      ConnectGate.connectTarget(Array(valid.utf8), allow: allow, capability: "secret")
        == .connect("example.com"))
  }
  let duplicate = connectHead.replacingOccurrences(
    of: "\r\n\r\n", with: "\r\npRoXy-AuThOrIzAtIoN: Basic aXNvOnNlY3JldA==\r\n\r\n")
  #expect(
    ConnectGate.connectTarget(Array(duplicate.utf8), allow: allow, capability: "secret")
      == .deny(.authRequired))
  #expect(
    ConnectGate.connectTarget(Array(connectHead.utf8), allow: allow, capability: "different")
      == .deny(.authRequired))
}

@Test func connectHeadRetriesWaitsAndInterruptionsWithoutConsumingTunnelBytes() throws {
  let (peer, proxy) = try connectPair()
  defer {
    close(peer)
    close(proxy)
  }
  let payload: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0x04, 0, 255, 1, 2]
  let bytes = Array(connectHead.utf8)
  try connectSend(Array(bytes.dropLast()), to: peer)
  let tail = Array(bytes.suffix(1)) + payload
  var waits = 0
  let head = ConnectGate.readHead(
    proxy, deadline: .seconds(1), alive: { true },
    pollEvents: { event, timeout in
      waits += 1
      if waits == 1 {
        errno = EINTR
        return -1
      }
      if waits == 2 { return 0 }
      if waits == 4 {
        #expect(tail.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) } == tail.count)
      }
      return poll(&event, 1, timeout)
    })
  #expect(head == bytes)
  #expect(waits > 2)
  var received = [UInt8](repeating: 0, count: 64)
  let count = recv(proxy, &received, received.count, MSG_DONTWAIT)
  #expect(count == payload.count)
  #expect(Array(received.prefix(max(0, count))) == payload)
}

@Test func connectHeadNeverReturnsAnIncompleteOrRevokedRequest() throws {
  let (peer, proxy) = try connectPair()
  defer {
    close(peer)
    close(proxy)
  }
  let partial = Array(connectHead.utf8.dropLast(2))
  try connectSend(partial, to: peer)
  let start = ContinuousClock.now
  #expect(ConnectGate.readHead(proxy, deadline: .milliseconds(60)).isEmpty)
  #expect(start.duration(to: .now) >= .milliseconds(40))
  #expect(start.duration(to: .now) < .seconds(2))
  try connectSend(Array(connectHead.utf8), to: peer)
  #expect(ConnectGate.readHead(proxy, alive: { false }).isEmpty)
  #expect(ConnectGate.readHead(proxy) == Array(connectHead.utf8))
  try connectSend(partial, to: peer)
  try #require(shutdown(peer, SHUT_WR) == 0)
  #expect(ConnectGate.readHead(proxy).isEmpty)
}

@Test func connectHeadBoundsFramingBytesAndHeaderCount() throws {
  let prefix = String(decoding: connectHead.utf8.dropLast(2), as: UTF8.self) + "X-Fill: "
  let exact =
    prefix + String(repeating: "x", count: EgressBudgets.maxHeadBytes - prefix.utf8.count - 4)
    + "\r\n\r\n"
  let allow = EgressAllowlist([try ExactHostname("example.com")])
  #expect(exact.utf8.count == EgressBudgets.maxHeadBytes)
  #expect(
    ConnectGate.connectTarget(Array(exact.utf8), allow: allow, capability: "secret")
      == .connect("example.com"))
  let tooLarge = exact.replacingOccurrences(of: "X-Fill: ", with: "X-Fill: xx")
  #expect(
    ConnectGate.connectTarget(Array(tooLarge.utf8), allow: allow, capability: "secret")
      == .deny(.unsupported))
  let (peer, proxy) = try connectPair()
  defer {
    close(peer)
    close(proxy)
  }
  try connectSend(Array(exact.utf8) + [42], to: peer)
  #expect(ConnectGate.readHead(proxy) == Array(exact.utf8))
  var extra: UInt8 = 0
  #expect(recv(proxy, &extra, 1, MSG_DONTWAIT) == 1 && extra == 42)
  let full = Array(String(repeating: "x", count: EgressBudgets.maxHeadBytes).utf8)
  try connectSend(full + Array(connectHead.utf8), to: peer)
  #expect(ConnectGate.readHead(proxy).isEmpty)
  let permitted =
    String(decoding: connectHead.utf8.dropLast(2), as: UTF8.self)
    + (0..<63).map { "X-H\($0): v\r\n" }.joined() + "\r\n"
  #expect(
    ConnectGate.connectTarget(Array(permitted.utf8), allow: allow, capability: "secret")
      == .connect("example.com"))
  let overflow = permitted.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Extra: v\r\n\r\n")
  #expect(
    ConnectGate.connectTarget(Array(overflow.utf8), allow: allow, capability: "secret")
      == .deny(.unsupported))
}

@Test func connectResponsesAreCompleteSignalSafeAndLeaseBound() throws {
  let (peer, proxy) = try connectPair()
  defer { close(proxy) }
  let flags = fcntl(proxy, F_GETFL)
  for denial: Denial? in [nil, .unsupported] {
    #expect(ConnectGate.writeResponse(proxy, denial))
    let expected = Array(
      (denial == nil
        ? "HTTP/1.1 200 Connection Established\r\n\r\n"
        : "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").utf8)
    var bytes = [UInt8](repeating: 0, count: 256)
    let count = recv(peer, &bytes, bytes.count, MSG_DONTWAIT)
    #expect(Array(bytes.prefix(max(0, count))) == expected)
    #expect(fcntl(proxy, F_GETFL) == flags)
  }
  #expect(!ConnectGate.writeResponse(proxy, nil, alive: { false }))
  var byte: UInt8 = 0
  #expect(recv(peer, &byte, 1, MSG_DONTWAIT) == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
  var noSignal: Int32 = 0
  var length = socklen_t(MemoryLayout<Int32>.size)
  try #require(getsockopt(proxy, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, &length) == 0)
  close(peer)
  // Assert before a disconnected send so a broken SIGPIPE guard cannot kill the suite.
  try #require(noSignal == 1)
  #expect(!ConnectGate.writeResponse(proxy, .unsupported))
  #expect(fcntl(proxy, F_GETFL) == flags)
}

@Test func connectPausedRefusalWriterIsBoundedAndRestoresFlags() throws {
  let (peer, proxy) = try connectPair()
  defer {
    close(peer)
    close(proxy)
  }
  try connectFill(proxy)
  let flags = fcntl(proxy, F_GETFL)
  let start = ContinuousClock.now
  #expect(!ConnectGate.writeResponse(proxy, .unsupported))
  let elapsed = start.duration(to: .now)
  #expect(elapsed >= .milliseconds(700))
  #expect(elapsed < .seconds(3))
  #expect(fcntl(proxy, F_GETFL) == flags)
}

@Test func tunnelRequiresACompleteHandshakeBeforeRelayingAndClosesItsUpstream() throws {
  let (peer, proxy) = try connectPair()
  let (upstreamPeer, upstreamProxy) = try connectPair()
  defer {
    close(peer)
    close(proxy)
    close(upstreamPeer)
  }
  try connectFill(proxy)
  try connectSend(Array("queued-tunnel-bytes".utf8), to: peer)
  try #require(shutdown(peer, SHUT_WR) == 0)
  try #require(shutdown(upstreamPeer, SHUT_WR) == 0)
  var calls = 0
  let start = ContinuousClock.now
  Tunnel.open(
    proxy, host: "example.com",
    connect: { host in
      #expect(host == "example.com")
      calls += 1
      return upstreamProxy
    })
  #expect(calls == 1)
  #expect(start.duration(to: .now) < .seconds(3))
  var byte: UInt8 = 0
  #expect(recv(upstreamPeer, &byte, 1, MSG_DONTWAIT) == 0)
}

@Test func connectHeadRefusesCompletionAfterItsDeadlineOrLease() throws {
  let (peer, proxy) = try connectPair()
  defer {
    close(peer)
    close(proxy)
  }
  try connectSend(Array(connectHead.utf8), to: peer)
  let late = ConnectGate.readHead(
    proxy, deadline: .milliseconds(40), alive: { true },
    pollEvents: { event, timeout in
      let result = poll(&event, 1, timeout)
      Thread.sleep(forTimeInterval: 0.06)
      return result
    })
  #expect(late.isEmpty)
  try connectSend(Array(connectHead.utf8), to: peer)
  var checks = 0
  #expect(
    ConnectGate.readHead(
      proxy,
      alive: {
        checks += 1
        return checks == 1
      }
    ).isEmpty)
  #expect(checks == 2)
}

@Test func tunnelDoesNotConnectOrRespondAfterRevocation() throws {
  let (peer, proxy) = try connectPair()
  defer {
    close(peer)
    close(proxy)
  }
  var calls = 0
  Tunnel.open(
    proxy, host: "example.com",
    connect: { _ in
      calls += 1
      return nil
    }, alive: { false })
  #expect(calls == 0)
  var byte: UInt8 = 0
  #expect(recv(peer, &byte, 1, MSG_DONTWAIT) == -1 && (errno == EAGAIN || errno == EWOULDBLOCK))
}
