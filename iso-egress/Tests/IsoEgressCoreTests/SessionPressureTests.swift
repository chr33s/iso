import Darwin
import Foundation
import Synchronization
import Testing

@testable import IsoEgressCore

private final class SessionRequest: Sendable {
  let client: Int32
  let done = DispatchSemaphore(value: 0)

  init(
    admission: Admission, alive: @escaping @Sendable () -> Bool,
    connect: @escaping @Sendable (String) throws -> Int32?
  ) throws {
    let allow = EgressAllowlist([try ExactHostname("example.com")])
    var pair: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    let server = pair[1]
    let head = Array(
      "CONNECT example.com:443 HTTP/1.1\r\nProxy-Authorization: Basic aXNvOnNlY3JldA==\r\n\r\n".utf8
    )
    guard head.withUnsafeBytes({ send(pair[0], $0.baseAddress, $0.count, 0) }) == head.count else {
      close(server)
      close(pair[0])
      throw PolicyError("could not write fixture request")
    }
    client = pair[0]
    shutdown(client, SHUT_WR)
    let done = done
    Thread {
      EgressSession.handle(
        server, allow: allow, capability: "secret", admission: admission,
        readiness: nil, alive: alive, connect: connect)
      done.signal()
    }.start()
  }

  deinit { close(client) }

  func joined() throws {
    try #require(done.wait(timeout: .now() + .seconds(3)) == .success)
    done.signal()  // The unconditional cleanup also joins.
  }

  func response() -> String {
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = recv(client, &buffer, buffer.count, MSG_DONTWAIT)
      if count <= 0 { break }
      bytes.append(contentsOf: buffer.prefix(count))
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}

@Test func pendingConnectionsStayBoundedThroughDisconnectRevocationAndRecovery() throws {
  let admission = Admission()
  let alive = Mutex(true)
  let calls = Mutex(0)
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  var requests: [SessionRequest] = []
  defer {
    alive.withLock { $0 = false }
    for _ in 0..<(EgressBudgets.maxTunnels + 2) { release.signal() }
    for request in requests { try? request.joined() }
  }
  let connector: @Sendable (String) -> Int32? = { host in
    #expect(host == "example.com")
    calls.withLock { $0 += 1 }
    entered.signal()
    #expect(release.wait(timeout: .now() + .seconds(10)) == .success)
    var upstream: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &upstream) == 0 else {
      Issue.record("could not create late upstream")
      return nil
    }
    close(upstream[0])
    return upstream[1]
  }
  for _ in 0..<EgressBudgets.maxTunnels {
    requests.append(
      try SessionRequest(
        admission: admission,
        alive: { alive.withLock { $0 } }, connect: connector))
    try #require(entered.wait(timeout: .now() + .seconds(2)) == .success)
  }
  let overflow = try SessionRequest(
    admission: admission,
    alive: { alive.withLock { $0 } }, connect: connector)
  requests.append(overflow)
  try overflow.joined()
  #expect(overflow.response().hasPrefix("HTTP/1.1 403"))
  #expect(calls.withLock { $0 } == EgressBudgets.maxTunnels)
  // Client disconnect and lease revocation must not free a slot while its
  // underlying connector still runs, or permit a late success response.
  for request in requests.prefix(EgressBudgets.maxTunnels / 2) {
    shutdown(request.client, SHUT_RDWR)
  }
  alive.withLock { $0 = false }
  let spare = admission.tryTunnel()
  #expect(!spare)
  if spare { admission.endTunnel() }
  for _ in 0..<EgressBudgets.maxTunnels { release.signal() }
  for request in requests { try request.joined() }
  for request in requests.dropFirst(EgressBudgets.maxTunnels / 2).dropLast() {
    #expect(request.response().isEmpty)
  }
  for _ in 0..<EgressBudgets.maxTunnels { #expect(admission.tryTunnel()) }
  #expect(!admission.tryTunnel())
  for _ in 0..<EgressBudgets.maxTunnels { admission.endTunnel() }

  var upstream: [Int32] = [-1, -1]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &upstream) == 0)
  let peer = upstream[0]
  defer { close(peer) }
  let server = upstream[1]
  let payload = Array("recovered".utf8)
  #expect(payload.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) } == payload.count)
  shutdown(peer, SHUT_WR)
  let recovered = try SessionRequest(
    admission: admission, alive: { true }, connect: { _ in server })
  requests.append(recovered)
  try recovered.joined()
  let response = recovered.response()
  #expect(response.hasPrefix("HTTP/1.1 200"))
  #expect(response.hasSuffix("\r\n\r\nrecovered"))
}

@Test func sessionDNSPressureRetainsWorkersAfterRequestTimeoutAndRecovers() throws {
  let admission = Admission()
  let calls = Mutex(0)
  let release = DispatchSemaphore(value: 0)
  let alive = Mutex(true)
  var requests: [SessionRequest] = []
  defer {
    alive.withLock { $0 = false }
    for _ in 0..<(EgressBudgets.maxDNS + 8) { release.signal() }
    for request in requests { try? request.joined() }
  }
  for index in 0..<(EgressBudgets.maxDNS + 8) {
    let request = try SessionRequest(
      admission: admission, alive: { alive.withLock { $0 } },
      connect: { _ in
        let result = Resolver.lookup(admission: admission, deadline: .milliseconds(20)) {
          calls.withLock { $0 += 1 }
          #expect(release.wait(timeout: .now() + .seconds(10)) == .success)
          return nil
        }
        #expect(result == nil)
        return nil
      })
    requests.append(request)
    if index % 2 == 0 { shutdown(request.client, SHUT_RDWR) }
    try request.joined()
    if index % 2 != 0 { #expect(request.response().hasPrefix("HTTP/1.1 403")) }
  }
  #expect(calls.withLock { $0 } == EgressBudgets.maxDNS)
  let spare = admission.tryDNS()
  #expect(!spare)
  if spare { admission.endDNS() }
  for _ in 0..<EgressBudgets.maxDNS { release.signal() }
  let deadline = Monotonic.now() + 2_000_000_000
  var reclaimed = false
  repeat {
    var reserved = 0
    for _ in 0...EgressBudgets.maxDNS {
      if admission.tryDNS() { reserved += 1 } else { break }
    }
    reclaimed = reserved == EgressBudgets.maxDNS
    for _ in 0..<reserved { admission.endDNS() }
    if !reclaimed { Thread.sleep(forTimeInterval: 0.005) }
  } while !reclaimed && Monotonic.now() < deadline
  try #require(reclaimed)
  let recovered = try SessionRequest(
    admission: admission, alive: { true },
    connect: { _ in
      #expect(Resolver.lookup("8.8.8.8", admission: admission) != nil)
      return nil
    })
  requests.append(recovered)
  try recovered.joined()
  #expect(recovered.response().hasPrefix("HTTP/1.1 403"))
}
