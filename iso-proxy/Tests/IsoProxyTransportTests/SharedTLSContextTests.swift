import Foundation
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import Testing

@testable import IsoProxyTransport

/// The fixture CA is trusted only by the context handed to the client. A
/// client that built its own context from `tlsConfiguration()` for each
/// connection would refuse every handshake below.
@Test func productionClientVerifiesEveryConnectionWithItsOneContext() async throws {
  let tls = try verifiedTLSFixture()
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let handshakes = NIOLockedValueBox(0)
  let peers = ConnectionRegistry()
  let provider = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    peers.add(channel)
    return channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls.server))
      try channel.pipeline.syncOperations.addHandler(HandshakeCounter(handshakes))
    }
  }.bind(host: "127.0.0.1", port: 0).get()
  let address = try SocketAddress(
    ipAddress: "127.0.0.1", port: #require(provider.localAddress?.port))
  let factory: BoundedResolver.Factory = { loop in FixtureResolver(loop: loop, address: address) }
  let upstream = try UpstreamClient(group: group, tls: tls.client, resolutionFactory: factory)
  let system = try UpstreamClient(group: group, resolutionFactory: factory)
  let token = String(repeating: "a", count: 64)
  let config = try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "listen": "127.0.0.1:0", "provider": "anthropic",
      "capability_token": token,
      "injection": ["scheme": "x_api_key", "credential": "shared-context-test-only"],
    ]))
  let guests = ConnectionRegistry()
  let proxy = try await Server.bind(config: config, group: group, upstream: upstream).get()
  do {
    // The probe and request paths both take the client's context.
    for provider in Provider.allCases { try await upstream.probeTLS(provider: provider) }
    // The client side completes before the server reads its Finished message,
    // so the server-side count can trail `probeTLS` returning.
    let probes = Provider.allCases.count
    try await waitForHandshakes(handshakes, atLeast: probes)
    #expect(handshakes.withLockedValue { $0 } == probes)
    let guest = try await ClientBootstrap(group: group).channelInitializer { channel in
      guests.add(channel)
      return channel.eventLoop.makeSucceededVoidFuture()
    }.connect(host: "127.0.0.1", port: #require(proxy.localAddress?.port)).get()
    try await guest.writeAndFlush(
      ByteBuffer(
        string:
          "POST /v1/messages HTTP/1.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n"
      )
    ).get()
    try await waitForHandshakes(handshakes, atLeast: probes + 1)
    #expect(
      handshakes.withLockedValue { $0 } == probes + 1, "forwarded request did not use the context")
    // The default context still verifies against system trust only.
    await #expect(throws: (any Error).self) { try await system.probeTLS(provider: .anthropic) }
    #expect(handshakes.withLockedValue { $0 } == probes + 1)
  } catch {
    Issue.record(error)
  }
  await guests.closeAll()
  try await proxy.close().get()
  try await upstream.shutdown()
  try await system.shutdown()
  await peers.closeAll()
  try await provider.close().get()
  try await group.shutdownGracefully()
}

private func waitForHandshakes(_ handshakes: NIOLockedValueBox<Int>, atLeast count: Int)
  async throws
{
  let deadline = ContinuousClock.now + .seconds(5)
  while handshakes.withLockedValue({ $0 }) < count, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
}

private final class HandshakeCounter: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let count: NIOLockedValueBox<Int>
  init(_ count: NIOLockedValueBox<Int>) { self.count = count }
  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if case .handshakeCompleted = event as? TLSUserEvent { count.withLockedValue { $0 += 1 } }
    context.fireUserInboundEventTriggered(event)
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private final class FixtureResolver: Resolver, Sendable {
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
