import AsyncHTTPClient
import Foundation
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import IsoProxyTransport

private func proxyConfig() throws -> ProxyConfig {
  try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "provider": "anthropic", "listen": "127.0.0.1:0",
      "capability_token": String(repeating: "a", count: 64),
      "injection": ["scheme": "x_api_key", "credential": "upstream-test-secret"],
    ]))
}

@Test func upstreamEndpointAndHeadersAreFixed() throws {
  let config = try proxyConfig()
  let head = HTTPRequestHead(
    version: .http1_1, method: .POST,
    uri: "/v1/messages?x=%2f&beta=true",
    headers: HTTPHeaders([
      ("host", "evil:1234"), ("authorization", "Bearer guest"),
      ("connection", "x-private"), ("x-private", "discard"),
    ]))
  let request = try UpstreamClient.request(head: head, config: config, body: .bytes([]))
  #expect(request.host == "api.anthropic.com")
  #expect(request.port == 443)
  #expect(request.useTLS)
  #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages?x=%2f&beta=true")
  #expect(request.headers.first(name: "host") == "api.anthropic.com")
  #expect(request.headers.first(name: "x-api-key") == "upstream-test-secret")
  #expect(!request.headers.contains(name: "authorization"))
  #expect(!request.headers.contains(name: "x-private"))
  let client = UpstreamClient.configuration()
  #expect(client.proxy == nil)
  #expect(client.httpVersion == .http1Only)
  #expect(client.timeout.connect == .seconds(30))
  #expect(client.timeout.read == nil)
  #expect(client.maximumUsesPerConnection == 1)
  #expect(client.connectionPool.concurrentHTTP1ConnectionsPerHostSoftLimit == 256)
  #expect(client.tlsConfiguration?.certificateVerification == .fullVerification)
  guard case .default? = client.tlsConfiguration?.trustRoots else {
    Issue.record("system trust roots must remain selected")
    return
  }
  #expect(client.tlsConfiguration?.additionalTrustRoots.isEmpty == true)
}

@Test func uploadWaitsForEachWriteAndCancels() throws {
  let loop = EmbeddedEventLoop()
  let upload = UploadStream(eventLoop: loop)
  final class Recorded {
    var writes: [String] = []
    var acknowledgments: [EventLoopPromise<Void>] = []
  }
  let recorded = Recorded()
  let state = NIOLoopBound(recorded, eventLoop: loop)
  // Hold write completion to exercise the production pump under backpressure.
  let writer = HTTPClient.Body.StreamWriter { data in
    let promise = loop.makePromise(of: Void.self)
    if case .byteBuffer(let bytes) = data { state.value.writes.append(String(buffer: bytes)) }
    state.value.acknowledgments.append(promise)
    return promise.futureResult
  }
  let completed = upload.attach(writer)
  completed.whenFailure { _ in }
  try upload.receive(ByteBuffer(string: "one"))
  try upload.receive(ByteBuffer(string: "two"))
  #expect(recorded.writes == ["one"])
  #expect(!upload.canRead)
  recorded.acknowledgments[0].succeed(())
  loop.run()
  #expect(recorded.writes == ["one", "two"])
  recorded.acknowledgments[1].succeed(())
  loop.run()
  #expect(upload.canRead)
  upload.cancel()
  #expect(!upload.canRead)
}

@Test func controlledForwardingInjectsAndReturnsRedirectWithoutFollowing() async throws {
  let tls = try verifiedTLSFixture()
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let client = HTTPClient(eventLoopGroup: group, configuration: UpstreamClient.configuration())
  let recorded = NIOLockedValueBox<[CapturedRequest]>([])
  do {
    let provider = try await ServerBootstrap(group: group)
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls.server))
        }.flatMap { channel.pipeline.configureHTTPServerPipeline() }.flatMap {
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(MockProvider(recorded: recorded))
          }
        }
      }.bind(host: "127.0.0.1", port: 0).get()
    let port = try #require(provider.localAddress?.port)
    let config = try proxyConfig()
    let proxy = try await Server.bind(config: config, group: group) { channel in
      channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            StreamingBridge(config: config) { request, relay, loop in
              // This substitution exists only in the test binary. Policy has
              // already built the fixed HTTPS provider request above this seam.
              let local = try! HTTPClient.Request(
                url: "https://api.anthropic.com:\(port)/v1/messages?beta=true",
                method: request.method, headers: request.headers, body: request.body)
              return OwnedHTTPRequest(
                request: local, relay: relay, eventLoop: loop,
                tlsConfiguration: tls.client, connectHost: "127.0.0.1")
            })
        }
      }
    }.get()
    let proxyPort = try #require(proxy.localAddress?.port)
    let request = try HTTPClient.Request(
      url: "http://127.0.0.1:\(proxyPort)/v1/messages?beta=true",
      method: .POST,
      headers: HTTPHeaders([
        ("authorization", "Bearer " + String(repeating: "a", count: 64)),
        ("connection", "x-private"), ("x-private", "do-not-forward"),
      ]), body: .bytes(Array("hello".utf8)))
    let response = try await client.execute(request: request, deadline: .now() + .seconds(10)).get()
    #expect(response.status == .temporaryRedirect)
    #expect(response.headers.first(name: "location") == "/redirect-target")
    #expect(!response.headers.contains(name: "x-private"))
    #expect(response.body.map { String(buffer: $0) } == "redirect")
    let requests = recorded.withLockedValue { $0 }
    #expect(requests.count == 1)
    let captured = try #require(requests.first)
    #expect(captured.body == "hello")
    #expect(captured.head.uri == "/v1/messages?beta=true")
    #expect(captured.head.headers.first(name: "x-api-key") == "upstream-test-secret")
    #expect(captured.head.headers.first(name: "host") == "api.anthropic.com")
    #expect(!captured.head.headers.contains(name: "authorization"))
    #expect(!captured.head.headers.contains(name: "x-private"))
    try await proxy.close().get()
    try await provider.close().get()
    try await client.shutdown()
    try await group.shutdownGracefully()
  } catch {
    try? await client.shutdown()
    try await group.shutdownGracefully()
    throw error
  }
}

private struct CapturedRequest: Sendable {
  let head: HTTPRequestHead
  let body: String
}

private final class MockProvider: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let recorded: NIOLockedValueBox<[CapturedRequest]>
  var head: HTTPRequestHead?
  var body = ""
  init(recorded: NIOLockedValueBox<[CapturedRequest]>) { self.recorded = recorded }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head): self.head = head
    case .body(let buffer): body += String(buffer: buffer)
    case .end:
      if let head {
        recorded.withLockedValue { $0.append(CapturedRequest(head: head, body: body)) }
      }
      let headers = HTTPHeaders([
        ("location", "/redirect-target"), ("content-length", "8"),
        ("connection", "x-private"), ("x-private", "discard"),
      ])
      context.write(
        wrapOutboundOut(
          .head(.init(version: .http1_1, status: .temporaryRedirect, headers: headers))),
        promise: nil)
      context.write(
        wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "redirect")))), promise: nil)
      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
  }
}
