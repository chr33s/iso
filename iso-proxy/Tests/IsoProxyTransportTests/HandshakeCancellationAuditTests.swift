import AsyncHTTPClient
import Foundation
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import IsoProxyTransport

// Reproducer for the pinned AHC connection-start cancellation gap. This is an
// explicitly failing acceptance audit until upstream socket ownership is fixed.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ISO_PROXY_HANDSHAKE_AUDIT"] == "1"))
func auditCancellationDuringTLSHandshake() async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let received = NIOLockedValueBox(false)
  let closed = NIOLockedValueBox(false)
  let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(
        AuditStalledTLS(received: received, closed: closed))
    }
  }.bind(host: "127.0.0.1", port: 0).get()
  let client = HTTPClient(eventLoopGroup: group, configuration: UpstreamClient.configuration())
  let port = try #require(server.localAddress?.port)
  let request = try HTTPClient.Request(url: "https://127.0.0.1:\(port)/", method: .POST)
  let task = client.execute(request: request, delegate: ResponseAccumulator(request: request))
  let startDeadline = ContinuousClock.now + .seconds(5)
  while !received.withLockedValue({ $0 }) && ContinuousClock.now < startDeadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(received.withLockedValue { $0 }, "fixture received TLS ClientHello")
  let cancelled = ContinuousClock.now
  task.cancel()
  do {
    _ = try await task.get()
    Issue.record("cancelled task unexpectedly succeeded")
  } catch {
    print("AUDIT request cancellation returned: \(error)")
  }
  try await Task.sleep(for: .seconds(2))
  let closedPromptly = closed.withLockedValue { $0 }
  print("AUDIT upstream closed within two seconds: \(closedPromptly)")
  #expect(closedPromptly, "guest cancellation must release upstream handshake socket")
  try await client.shutdown()
  let closeDeadline = ContinuousClock.now + .seconds(2)
  while !closed.withLockedValue({ $0 }) && ContinuousClock.now < closeDeadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(closed.withLockedValue { $0 }, "handshake socket eventually closes")
  print(
    "AUDIT shutdown finished after cancellation: \(cancelled.duration(to: .now)); socket closed: \(closed.withLockedValue { $0 })"
  )
  try await server.close().get()
  try await group.shutdownGracefully()
}

private final class AuditStalledTLS: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let received: NIOLockedValueBox<Bool>
  let closed: NIOLockedValueBox<Bool>
  init(received: NIOLockedValueBox<Bool>, closed: NIOLockedValueBox<Bool>) {
    self.received = received
    self.closed = closed
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    received.withLockedValue { $0 = true }
  }
  func channelInactive(context: ChannelHandlerContext) {
    closed.withLockedValue { $0 = true }
    context.fireChannelInactive()
  }
}

@Test(arguments: Provider.allCases)
func bridgeCancellationClosesStalledTLSHandshake(provider: Provider) async throws {
  let path = provider == .anthropic ? "/v1/messages" : "/v1/responses"
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let received = NIOLockedValueBox(false)
  let closed = NIOLockedValueBox(false)
  let upstreamChildren = ConnectionRegistry()
  let guestChildren = ConnectionRegistry()
  let upstream = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    upstreamChildren.add(channel)
    return channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(
        AuditStalledTLS(received: received, closed: closed))
    }
  }.bind(host: "127.0.0.1", port: 0).get()
  let port = try #require(upstream.localAddress?.port)
  let token = String(repeating: "a", count: 64)
  let config = try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "listen": "127.0.0.1:0", "provider": provider.rawValue,
      "capability_token": token,
      "injection": [
        "scheme": provider == .anthropic ? "x_api_key" : "bearer",
        "credential": "handshake-test-only",
      ],
    ]))
  let proxy = try await Server.bind(config: config, group: group, registry: guestChildren) {
    channel in
    channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
      channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(
          StreamingBridge(config: config) { request, relay, loop in
            let local = try! HTTPClient.Request(
              url: "https://\(provider.hostname):\(port)\(path)", method: request.method,
              headers: request.headers, body: request.body)
            return OwnedHTTPRequest(
              request: local, relay: relay, eventLoop: loop, connectHost: "127.0.0.1")
          })
      }
    }
  }.get()
  do {
    let guest = try await ClientBootstrap(group: group)
      .connect(host: "127.0.0.1", port: #require(proxy.localAddress?.port)).get()
    try await guest.writeAndFlush(
      ByteBuffer(
        string:
          "POST \(path) HTTP/1.1\r\nHost: ignored\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n"
      )
    ).get()
    let started = ContinuousClock.now + .seconds(2)
    while !received.withLockedValue({ $0 }) && ContinuousClock.now < started {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(received.withLockedValue { $0 }, "upstream TLS handshake started")
    try await guest.close().get()
    let deadline = ContinuousClock.now + .seconds(2)
    while !closed.withLockedValue({ $0 }) && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    try #require(
      closed.withLockedValue { $0 }, "guest disconnect must promptly close upstream socket")
    try await proxy.close().get()
    try await upstream.close().get()
    await guestChildren.closeAll()
    await upstreamChildren.closeAll()
    try await group.shutdownGracefully()
  } catch {
    try? await proxy.close().get()
    try? await upstream.close().get()
    await guestChildren.closeAll()
    await upstreamChildren.closeAll()
    try await group.shutdownGracefully()
    throw error
  }
}
