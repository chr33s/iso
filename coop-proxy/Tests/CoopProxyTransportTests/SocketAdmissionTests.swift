import CoopProxyCore
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import CoopProxyTransport

@Test(arguments: [1, Limits.connections], [false, true])
func productionClientSharesSocketBudgetUntilPhysicalClose(limit: Int, shutdown: Bool) async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let peers = ConnectionRegistry()
  let guests = ConnectionRegistry()
  let proxyChildren = ConnectionRegistry()
  let counts = NIOLockedValueBox(SocketObservations())
  let provider = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    peers.add(channel)
    counts.withLockedValue { $0.accepted += 1 }
    return channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(SocketObserver(counts))
    }
  }.bind(host: "127.0.0.1", port: 0).get()
  let address = try SocketAddress(
    ipAddress: "127.0.0.1", port: #require(provider.localAddress?.port))
  let factory: BoundedResolver.Factory = { loop in
    StaticSocketResolver(loop: loop, address: address)
  }
  let upstream =
    limit == Limits.connections
    ? UpstreamClient(group: group, resolutionFactory: factory)
    : UpstreamClient(group: group, socketCapacity: Capacity(limit), resolutionFactory: factory)
  let token = String(repeating: "a", count: 64)
  let config = try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "listen": "127.0.0.1:0", "provider": "anthropic",
      "capability_token": token,
      "injection": ["scheme": "x_api_key", "credential": "socket-admission-test-only"],
    ]))
  let proxy = try await Server.bind(
    config: config, group: group, upstream: upstream, registry: proxyChildren
  ).get()
  let port = try #require(proxy.localAddress?.port)
  func send(tolerateWriteClosure: Bool = false) async throws -> Channel {
    let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
      guests.add(channel)
      return channel.eventLoop.makeSucceededVoidFuture()
    }.connect(host: "127.0.0.1", port: port).get()
    do {
      try await channel.writeAndFlush(
        ByteBuffer(
          string:
            "POST /v1/messages HTTP/1.1\r\nHost: ignored\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n"
        )
      ).get()
    } catch {
      if !tolerateWriteClosure { throw error }
    }
    return channel
  }
  do {
    var held: [Channel] = []
    for count in 1...limit {
      held.append(try await send())
      try await waitForSocketCondition { counts.withLockedValue { $0.hellos } == count }
    }
    if shutdown {
      let started = ContinuousClock.now
      try await upstream.shutdown()
      #expect(
        started.duration(to: .now) < .seconds(2),
        "shutdown must cancel without waiting for TLS timeout")
      try await waitForSocketCondition { counts.withLockedValue { $0.closed } == limit }
      try await waitForSocketCondition { held.allSatisfy { !$0.isActive } }
      let rejected = try await send(tolerateWriteClosure: true)
      try await waitForSocketCondition { !rejected.isActive }
      #expect(
        counts.withLockedValue { $0.accepted } == limit, "shutdown prevents new upstream sockets")
    } else {
      let first = try #require(held.first)
      let excess = try await send(tolerateWriteClosure: true)
      try await waitForSocketCondition { !excess.isActive }
      #expect(
        counts.withLockedValue { $0.accepted } == limit, "socket budget applies before TCP connect")
      try await first.close().get()
      try await waitForSocketCondition { counts.withLockedValue { $0.closed } == 1 }
      let recovered = try await send()
      try await waitForSocketCondition { counts.withLockedValue { $0.hellos } == limit + 1 }
      #expect(counts.withLockedValue { $0.accepted } == limit + 1)
      try await recovered.close().get()
      try await waitForSocketCondition { counts.withLockedValue { $0.closed } == 2 }
    }
    try await proxy.close().get()
    try await provider.close().get()
    await guests.closeAll()
    await proxyChildren.closeAll()
    await peers.closeAll()
    try await upstream.shutdown()
    try await group.shutdownGracefully()
  } catch {
    try? await proxy.close().get()
    try? await provider.close().get()
    await guests.closeAll()
    await proxyChildren.closeAll()
    await peers.closeAll()
    try? await upstream.shutdown()
    try await group.shutdownGracefully()
    throw error
  }
}

private func waitForSocketCondition(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(2)
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(1))
  }
  try #require(condition(), "socket admission observation exceeded two seconds")
}

private struct SocketObservations {
  var accepted = 0
  var hellos = 0
  var closed = 0
}

private final class SocketObserver: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let observed: NIOLockedValueBox<SocketObservations>
  var received = false
  init(_ observed: NIOLockedValueBox<SocketObservations>) { self.observed = observed }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if !received {
      received = true
      observed.withLockedValue { $0.hellos += 1 }
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    observed.withLockedValue { $0.closed += 1 }
    context.fireChannelInactive()
  }
}

private final class StaticSocketResolver: Resolver, Sendable {
  let ipv4: EventLoopFuture<[SocketAddress]>
  let ipv6: EventLoopFuture<[SocketAddress]>
  init(loop: EventLoop, address: SocketAddress) {
    ipv4 = loop.makeSucceededFuture([address])
    ipv6 = loop.makeSucceededFuture([])
  }
  func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> { ipv4 }
  func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> { ipv6 }
  func cancelQueries() {}
}

@Test(arguments: [false, true])
func tlsProbeCancellationReleasesItsOwnedSocketForBothProviders(shutdown: Bool) async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let peers = ConnectionRegistry()
  let counts = NIOLockedValueBox(SocketObservations())
  let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    peers.add(channel)
    counts.withLockedValue { $0.accepted += 1 }
    return channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(SocketObserver(counts))
    }
  }.bind(host: "127.0.0.1", port: 0).get()
  let address = try SocketAddress(ipAddress: "127.0.0.1", port: #require(server.localAddress?.port))
  let upstream = UpstreamClient(group: group, socketCapacity: Capacity(1)) { loop in
    StaticSocketResolver(loop: loop, address: address)
  }
  do {
    for (index, provider) in Provider.allCases.enumerated() {
      let probe = Task { try await upstream.probeTLS(provider: provider) }
      defer { probe.cancel() }
      try await waitForSocketCondition { counts.withLockedValue { $0.hellos } == index + 1 }
      if shutdown {
        let started = ContinuousClock.now
        try await upstream.shutdown()
        #expect(started.duration(to: .now) < .seconds(2), "probe shutdown must cancel promptly")
      } else {
        probe.cancel()
      }
      do {
        try await probe.value
        Issue.record("cancelled TLS probe succeeded")
      } catch {
        #expect(error as? CancellableTLSConnection.Failure == .cancelled)
      }
      try await waitForSocketCondition { counts.withLockedValue { $0.closed } == index + 1 }
      if shutdown {
        do {
          try await upstream.probeTLS(provider: provider)
          Issue.record("shutdown must reject new probes")
        } catch {
          #expect(error as? UpstreamWork.Failure == .shuttingDown)
        }
        #expect(counts.withLockedValue { $0.accepted } == 1)
        // Shutdown is permanent and idempotent. The cancellation-only case
        // above still checks both provider identities on the same live client.
        try await upstream.shutdown()
        break
      }
    }
    try await server.close().get()
    await peers.closeAll()
    try await upstream.shutdown()
    try await group.shutdownGracefully()
  } catch {
    try? await server.close().get()
    await peers.closeAll()
    try? await upstream.shutdown()
    try await group.shutdownGracefully()
    throw error
  }
}
