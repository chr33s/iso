import Foundation
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import IsoProxyTransport

@Test func cancelledDNSRetainsAll256LeasesUntilBothFamiliesFinish() throws {
  let loop = EmbeddedEventLoop()
  let capacity = Capacity(Limits.requests)
  let cancelled = NIOLockedValueBox(0)
  var workers: [HeldDNS] = []
  for _ in 0..<Limits.requests {
    let worker = HeldDNS(loop: loop)
    workers.append(worker)
    let resolver = BoundedResolver(eventLoop: loop, capacity: capacity, factory: { _ in worker })
    for future in [
      resolver.initiateAQuery(host: "held.invalid", port: 443),
      resolver.initiateAAAAQuery(host: "held.invalid", port: 443),
    ] {
      future.whenFailure { error in
        #expect(error as? BoundedResolver.Failure == .cancelled)
        cancelled.withLockedValue { $0 += 1 }
      }
    }
    resolver.cancelQueries()
    loop.run()
  }
  #expect(cancelled.withLockedValue { $0 } == 512)
  #expect(workers.allSatisfy { $0.queries.withLockedValue { $0 } == 2 })
  let overflowStarted = NIOLockedValueBox(false)
  let overflow = BoundedResolver(eventLoop: loop, capacity: capacity) { eventLoop in
    overflowStarted.withLockedValue { $0 = true }
    let worker = HeldDNS(loop: eventLoop)
    worker.finish()
    return worker
  }
  let refused = NIOLockedValueBox(0)
  for future in [
    overflow.initiateAQuery(host: "held.invalid", port: 443),
    overflow.initiateAAAAQuery(host: "held.invalid", port: 443),
  ] {
    future.whenFailure { error in
      #expect(error as? BoundedResolver.Failure == .capacityExceeded)
      refused.withLockedValue { $0 += 1 }
    }
  }
  loop.run()
  #expect(refused.withLockedValue { $0 } == 2)
  #expect(!overflowStarted.withLockedValue { $0 })
  for worker in workers { worker.ipv4.succeed([]) }
  loop.run()
  #expect(capacity.acquire() == nil, "one completed family must not release the lookup budget")
  for worker in workers { worker.ipv6.succeed([]) }
  loop.run()
  let recovered = (0..<Limits.requests).compactMap { _ in capacity.acquire() }
  #expect(recovered.count == Limits.requests)
  for lease in recovered { lease.release() }
}

@Test func dnsCancellationBeforeStartDoesNotSubmitWork() {
  let loop = EmbeddedEventLoop()
  let started = NIOLockedValueBox(false)
  let resolver = BoundedResolver(eventLoop: loop, capacity: Capacity(1)) { eventLoop in
    started.withLockedValue { $0 = true }
    let worker = HeldDNS(loop: eventLoop)
    worker.finish()
    return worker
  }
  resolver.cancelQueries()
  loop.run()
  let failed = NIOLockedValueBox(0)
  for future in [
    resolver.initiateAAAAQuery(host: "held.invalid", port: 443),
    resolver.initiateAQuery(host: "held.invalid", port: 443),
  ] {
    future.whenFailure { error in
      #expect(error as? BoundedResolver.Failure == .cancelled)
      failed.withLockedValue { $0 += 1 }
    }
  }
  loop.run()
  #expect(failed.withLockedValue { $0 } == 2)
  #expect(!started.withLockedValue { $0 })
}

@Test func dnsFailurePreservesItsReasonAndWaitsForOtherFamily() {
  enum LookupFailure: Error { case refused }
  let loop = EmbeddedEventLoop()
  let capacity = Capacity(1)
  let worker = HeldDNS(loop: loop)
  let resolver = BoundedResolver(eventLoop: loop, capacity: capacity, factory: { _ in worker })
  let failed = NIOLockedValueBox(false)
  let succeeded = NIOLockedValueBox(false)
  resolver.initiateAQuery(host: "held.invalid", port: 443).whenFailure { error in
    #expect(error is LookupFailure)
    failed.withLockedValue { $0 = true }
  }
  resolver.initiateAAAAQuery(host: "held.invalid", port: 443).whenSuccess { addresses in
    #expect(addresses.isEmpty)
    succeeded.withLockedValue { $0 = true }
  }
  worker.ipv4.fail(LookupFailure.refused)
  loop.run()
  #expect(failed.withLockedValue { $0 })
  #expect(capacity.acquire() == nil)
  worker.ipv6.succeed([])
  loop.run()
  #expect(succeeded.withLockedValue { $0 })
  let recovered = capacity.acquire()
  #expect(recovered != nil)
  recovered?.release()
  // Both query APIs return the same results without submitting another job.
  _ = resolver.initiateAQuery(host: "held.invalid", port: 443)
  _ = resolver.initiateAAAAQuery(host: "held.invalid", port: 443)
  #expect(worker.queries.withLockedValue { $0 } == 2)
}

@Test func guestCancellationCannotQueueMoreThan256UnderlyingLookups() async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let workers = NIOLockedValueBox<[HeldDNS]>([])
  let upstream = UpstreamClient(group: group) { loop in
    let worker = HeldDNS(loop: loop)
    workers.withLockedValue { $0.append(worker) }
    return worker
  }
  let children = ConnectionRegistry()
  let token = String(repeating: "a", count: 64)
  let config = try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "listen": "127.0.0.1:0", "provider": "anthropic",
      "capability_token": token,
      "injection": ["scheme": "x_api_key", "credential": "dns-admission-test-only"],
    ]))
  let server = try await Server.bind(
    config: config, group: group, upstream: upstream, registry: children
  ).get()
  let port = try #require(server.localAddress?.port)
  func send() async throws -> Channel {
    let channel = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port)
      .get()
    try await channel.writeAndFlush(
      ByteBuffer(
        string:
          "POST /v1/messages HTTP/1.1\r\nHost: ignored\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n"
      )
    ).get()
    return channel
  }
  do {
    for count in 1...Limits.requests {
      let guest = try await send()
      try await waitForDNSCondition { workers.withLockedValue { $0.count } == count }
      try await guest.close().get()
    }
    // Guest/request slots are reusable, but every underlying lookup is held.
    let excess = try await send()
    try await waitForDNSCondition { !excess.isActive }
    #expect(workers.withLockedValue { $0.count } == Limits.requests)
    for worker in workers.withLockedValue({ $0 }) { worker.finish() }
    // The completion callbacks and permit release run on this same loop.
    try await group.next().submit {}.get()
    let recovered = try await send()
    try await waitForDNSCondition { workers.withLockedValue { $0.count } == Limits.requests + 1 }
    try await recovered.close().get()
    for worker in workers.withLockedValue({ $0 }) { worker.finish() }
    try await server.close().get()
    await children.closeAll()
    try await upstream.shutdown()
    try await group.shutdownGracefully()
  } catch {
    for worker in workers.withLockedValue({ $0 }) { worker.finish() }
    try? await server.close().get()
    await children.closeAll()
    try? await upstream.shutdown()
    try await group.shutdownGracefully()
    throw error
  }
}

private func waitForDNSCondition(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(2)
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(1))
  }
  try #require(condition(), "DNS admission observation exceeded two seconds")
}

private final class HeldDNS: Resolver, Sendable {
  let ipv4: EventLoopPromise<[SocketAddress]>
  let ipv6: EventLoopPromise<[SocketAddress]>
  let queries = NIOLockedValueBox(0)
  private let finished = NIOLockedValueBox(false)
  init(loop: EventLoop) {
    ipv4 = loop.makePromise()
    ipv6 = loop.makePromise()
  }
  func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
    queries.withLockedValue { $0 += 1 }
    return ipv4.futureResult
  }
  func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
    queries.withLockedValue { $0 += 1 }
    return ipv6.futureResult
  }
  // Like getaddrinfo, cancellation does not complete the actual work.
  func cancelQueries() {}
  func finish() {
    let complete = finished.withLockedValue { finished in
      guard !finished else { return false }
      finished = true
      return true
    }
    if complete {
      ipv4.succeed([])
      ipv6.succeed([])
    }
  }
}
