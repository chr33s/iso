import AsyncHTTPClient
import CoopProxyCore
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import CoopProxyTransport

private struct Observed: Sendable {
  var bodyBytes = 0
  var requestEnded = false
  var closed = false
}

/// Either leaves an upload unanswered or rejects it after its first body part,
/// exercising cancellation during upload and while awaiting a model response.
private final class HangingProvider: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let observed: NIOLockedValueBox<Observed>
  let earlyResponse: Bool
  var replied = false
  init(_ observed: NIOLockedValueBox<Observed>, earlyResponse: Bool) {
    self.observed = observed
    self.earlyResponse = earlyResponse
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head: break
    case .body(let bytes):
      observed.withLockedValue { $0.bodyBytes += bytes.readableBytes }
      if earlyResponse && !replied {
        replied = true
        let head = HTTPResponseHead(
          version: .http1_1, status: .tooManyRequests,
          headers: HTTPHeaders([("content-length", "5")]))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(
          wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "retry")))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
      }
    case .end: observed.withLockedValue { $0.requestEnded = true }
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    observed.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
}

private func eventually(_ condition: @Sendable () -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition() {
    if ContinuousClock.now >= deadline { return false }
    try await Task.sleep(for: .milliseconds(10))
  }
  return true
}

private struct GuestObserved: Sendable {
  var wire = ""
  var closed = false
}
private final class CaptureGuest: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let observed: NIOLockedValueBox<GuestObserved>
  init(_ observed: NIOLockedValueBox<GuestObserved>) { self.observed = observed }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let bytes = unwrapInboundIn(data)
    observed.withLockedValue { $0.wire += String(buffer: bytes) }
  }
  func channelInactive(context: ChannelHandlerContext) {
    observed.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
}

@Test(arguments: [false, true], [false, true])
func guestDisconnectCancelsUpstream(completedUpload: Bool, proxyShutdown: Bool) async throws {
  try await exerciseLifecycle(completedUpload: completedUpload, proxyShutdown: proxyShutdown)
}

@Test func earlyResponseClosesUnfinishedUpload() async throws {
  try await exerciseLifecycle(completedUpload: false, proxyShutdown: false, earlyResponse: true)
}

private func exerciseLifecycle(
  completedUpload: Bool, proxyShutdown: Bool, earlyResponse: Bool = false
) async throws {
  let tls = try verifiedTLSFixture()
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let proxyChildren = ConnectionRegistry()
  let providerChildren = ConnectionRegistry()
  let observed = NIOLockedValueBox(Observed())
  let guestObserved = NIOLockedValueBox(GuestObserved())
  var listeners: [Channel] = []
  var guest: Channel?
  do {
    let config = try ProxyConfig(
      json: JSONSerialization.data(withJSONObject: [
        "version": 1, "provider": "anthropic", "listen": "127.0.0.1:0",
        "capability_token": String(repeating: "a", count: 64),
        "injection": ["scheme": "x_api_key", "credential": "lifecycle-test-only"],
      ]))
    let provider = try await ServerBootstrap(group: group).childChannelInitializer { channel in
      providerChildren.add(channel)
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls.server))
      }.flatMap { channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false) }
        .flatMap {
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
              HangingProvider(observed, earlyResponse: earlyResponse))
          }
        }
    }.bind(host: "127.0.0.1", port: 0).get()
    listeners.append(provider)
    let providerPort = try #require(provider.localAddress?.port)
    let proxy = try await Server.bind(config: config, group: group, registry: proxyChildren) {
      channel in
      channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            StreamingBridge(config: config) { request, relay, loop in
              // This destination override exists only in the test executable.
              let local = try! HTTPClient.Request(
                url: "https://api.anthropic.com:\(providerPort)/v1/messages",
                method: request.method, headers: request.headers, body: request.body)
              return OwnedHTTPRequest(
                request: local, relay: relay, eventLoop: loop,
                tlsConfiguration: tls.client, connectHost: "127.0.0.1")
            })
        }
      }
    }.get()
    listeners.append(proxy)
    let proxyPort = try #require(proxy.localAddress?.port)
    let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
      channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(CaptureGuest(guestObserved))
      }
    }.connect(
      host: "127.0.0.1", port: proxyPort
    ).get()
    guest = channel
    let length = completedUpload ? 4 : 100
    let wire =
      "POST /v1/messages HTTP/1.1\r\nHost: guest\r\nAuthorization: Bearer "
      + String(repeating: "a", count: 64) + "\r\nContent-Length: \(length)\r\n\r\nbody"
    try await channel.writeAndFlush(ByteBuffer(string: wire)).get()
    let received = try await eventually {
      observed.withLockedValue { $0.bodyBytes == 4 && (!completedUpload || $0.requestEnded) }
    }
    #expect(received, "controlled provider must receive the upload before cancellation")
    if earlyResponse {
      let closed = try await eventually { guestObserved.withLockedValue { $0.closed } }
      #expect(closed, "early response must close the unfinished guest upload")
      let wire = guestObserved.withLockedValue { $0.wire }
      #expect(wire.hasPrefix("HTTP/1.1 429 "))
      #expect(wire.hasSuffix("\r\n\r\nretry"))
      #expect(wire.components(separatedBy: "HTTP/1.1").count == 2)
      #expect(!observed.withLockedValue { $0.requestEnded })
    } else if proxyShutdown {
      await proxyChildren.closeAll()
      try await channel.closeFuture.get()
    } else {
      try await channel.close().get()
    }
    guest = nil
    let cancelled = try await eventually { observed.withLockedValue { $0.closed } }
    #expect(cancelled, "guest disconnect or proxy shutdown must close the active upstream socket")
  } catch {
    if let guest { try? await guest.close().get() }
    for listener in listeners { try? await listener.close().get() }
    await proxyChildren.closeAll()
    await providerChildren.closeAll()
    try await group.shutdownGracefully()
    throw error
  }
  for listener in listeners { try? await listener.close().get() }
  await proxyChildren.closeAll()
  await providerChildren.closeAll()
  try await group.shutdownGracefully()
}
