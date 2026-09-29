import AsyncHTTPClient
import Foundation
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import IsoProxyTransport

private final class StalledGuestWrite: ChannelOutboundHandler {
  typealias OutboundIn = HTTPServerResponsePart
  typealias OutboundOut = HTTPServerResponsePart
  let count: NIOLockedValueBox<Int>
  let blocked: EventLoopPromise<Void>
  init(count: NIOLockedValueBox<Int>, blocked: EventLoopPromise<Void>) {
    self.count = count
    self.blocked = blocked
  }
  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    if case .body = unwrapOutboundIn(data) {
      let first = count.withLockedValue { value in
        value += 1
        return value == 1
      }
      if first {
        // Let bytes reach the guest, but hold their acknowledgment. The real
        // response delegate must propagate this exact future upstream.
        let written = context.eventLoop.makePromise(of: Void.self)
        context.write(data, promise: written)
        let acknowledgment = blocked.futureResult
        written.futureResult.flatMap { acknowledgment }.cascade(to: promise)
        return
      }
    }
    context.write(data, promise: promise)
  }
}

private final class LargeResponse: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  static let bytes = 1024 * 1024
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .end = unwrapInboundIn(data) else { return }
    let head = HTTPResponseHead(
      version: .http1_1, status: .ok,
      headers: HTTPHeaders([("content-length", String(Self.bytes))]))
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    let body = ByteBuffer(repeating: 0x5a, count: Self.bytes)
    context.write(wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
  }
}

@Test func responseDelegateWaitsForGuestWriteAcknowledgment() async throws {
  let tls = try verifiedTLSFixture()
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let loop = group.next()
  let client = HTTPClient(eventLoopGroup: group, configuration: UpstreamClient.configuration())
  let providerChildren = ConnectionRegistry()
  let proxyChildren = ConnectionRegistry()
  let count = NIOLockedValueBox(0)
  let blocked = loop.makePromise(of: Void.self)
  var released = false
  var listeners: [Channel] = []
  do {
    let config = try ProxyConfig(
      json: JSONSerialization.data(withJSONObject: [
        "version": 1, "provider": "anthropic", "listen": "127.0.0.1:0",
        "capability_token": String(repeating: "a", count: 64),
        "injection": ["scheme": "x_api_key", "credential": "backpressure-test-only"],
      ]))
    let provider = try await ServerBootstrap(group: group).childChannelInitializer { channel in
      providerChildren.add(channel)
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls.server))
      }.flatMap { channel.pipeline.configureHTTPServerPipeline() }.flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(LargeResponse())
        }
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    listeners.append(provider)
    let providerPort = try #require(provider.localAddress?.port)
    let proxy = try await Server.bind(config: config, group: group, registry: proxyChildren) {
      channel in
      channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandlers([
            StalledGuestWrite(count: count, blocked: blocked),
            StreamingBridge(config: config) { request, relay, eventLoop in
              let local = try! HTTPClient.Request(
                url: "https://api.anthropic.com:\(providerPort)/v1/messages",
                method: request.method, headers: request.headers, body: request.body)
              return OwnedHTTPRequest(
                request: local, relay: relay, eventLoop: eventLoop,
                tlsConfiguration: tls.client, connectHost: "127.0.0.1")
            },
          ])
        }
      }
    }.get()
    listeners.append(proxy)
    let port = try #require(proxy.localAddress?.port)
    let request = try HTTPClient.Request(
      url: "http://127.0.0.1:\(port)/v1/messages", method: .POST,
      headers: HTTPHeaders([("authorization", "Bearer " + String(repeating: "a", count: 64))]),
      body: .bytes([]))
    let response = client.execute(request: request, deadline: .now() + .seconds(10))
    let deadline = ContinuousClock.now + .seconds(5)
    while count.withLockedValue({ $0 }) == 0 && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(count.withLockedValue { $0 } == 1)
    // Give the response pump several event-loop turns with a whole response available.
    try await Task.sleep(for: .milliseconds(200))
    #expect(
      count.withLockedValue { $0 } == 1, "the response pump must await the stalled guest write")
    blocked.succeed(())
    released = true
    let result = try await response.get()
    #expect(result.status == .ok)
    let bytes = try #require(result.body)
    #expect(bytes.readableBytes == LargeResponse.bytes)
    #expect(bytes.readableBytesView.allSatisfy { $0 == 0x5a })
    #expect(count.withLockedValue { $0 } > 1)
  } catch {
    if !released { blocked.succeed(()) }
    for listener in listeners { try? await listener.close().get() }
    await proxyChildren.closeAll()
    await providerChildren.closeAll()
    try? await client.shutdown()
    try await group.shutdownGracefully()
    throw error
  }
  for listener in listeners { try? await listener.close().get() }
  await proxyChildren.closeAll()
  await providerChildren.closeAll()
  try await client.shutdown()
  try await group.shutdownGracefully()
}
