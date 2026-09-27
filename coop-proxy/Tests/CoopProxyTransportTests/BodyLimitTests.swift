import AsyncHTTPClient
import CoopProxyCore
import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import CoopProxyTransport

private let bodyCap = 64 * 1024 * 1024
private let expectedBodyHash = "98dc891b284e4d84ac25b0c0a24fdbe39a7f0dbd643ad5e8aa06e02fc6258254"

private struct LimitUploadState: Sendable {
  var connections = 0
  var requests = 0
  var bytes = 0
  var digest: String?
  var closed = 0
}

private final class LimitUploadPeer: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let state: NIOLockedValueBox<LimitUploadState>
  let provider: String
  var hasher = SHA256()
  init(_ state: NIOLockedValueBox<LimitUploadState>, provider: String) {
    self.state = state
    self.provider = provider
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      #expect(head.method == .POST)
      #expect(head.headers["host"] == ["api.\(provider).com"])
      #expect(head.headers["authorization"] == ["Bearer limit-test-secret"])
      state.withLockedValue { $0.requests += 1 }
    case .body(let bytes):
      hasher.update(data: Data(bytes.readableBytesView))
      state.withLockedValue { $0.bytes += bytes.readableBytes }
    case .end:
      let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
      state.withLockedValue { $0.digest = digest }
      context.write(
        wrapOutboundOut(
          .head(
            .init(
              version: .http1_1, status: .ok,
              headers: HTTPHeaders([("content-length", "8")])))), promise: nil)
      context.write(
        wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "accepted")))), promise: nil)
      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    state.withLockedValue { $0.closed += 1 }
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private struct LimitGuestState: Sendable {
  var wire = ""
  var closed = false
}

private final class LimitGuestCapture: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let state: NIOLockedValueBox<LimitGuestState>
  init(_ state: NIOLockedValueBox<LimitGuestState>) { self.state = state }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let bytes = unwrapInboundIn(data)
    state.withLockedValue { $0.wire += String(buffer: bytes) }
  }
  func channelInactive(context: ChannelHandlerContext) {
    state.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
}

private func waitForLimitState(_ stage: String, seconds: Int = 5, _ condition: @Sendable () -> Bool)
  async throws
{
  let deadline = ContinuousClock.now + .seconds(seconds)
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  try #require(condition(), "\(stage)")
}

@Test func realTLSDeclaredBodyLimitAcceptsExactAndRefusesExcess() async throws {
  let fixtures = try generateForwardingFixtures()
  defer { try? FileManager.default.removeItem(at: fixtures) }
  var observations: [[String: Any]] = []
  for provider in ["anthropic", "openai"] {
    for declared: Int? in [bodyCap, bodyCap + 1, nil] {
      observations.append(
        try await bodyLimit(provider: provider, declared: declared, fixtures: fixtures))
    }
  }
  if let path = ProcessInfo.processInfo.environment["COOP_BODY_LIMIT_OBSERVATIONS"] {
    try JSONSerialization.data(
      withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

private func bodyLimit(provider: String, declared: Int?, fixtures: URL) async throws -> [String:
  Any]
{
  let ca = try NIOSSLCertificate.fromDERFile(fixtures.appendingPathComponent("forward_ca.der").path)
  let leaf = try NIOSSLCertificate.fromDERFile(
    fixtures.appendingPathComponent("forward_leaf.der").path)
  let key = try NIOSSLPrivateKey(
    file: fixtures.appendingPathComponent("forward_leaf.pkcs8.der").path, format: .der)
  let tls = try NIOSSLContext(
    configuration: .makeServerConfiguration(
      certificateChain: [.certificate(leaf), .certificate(ca)], privateKey: .privateKey(key)))
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  var clientConfig = UpstreamClient.configuration()
  clientConfig.tlsConfiguration?.additionalTrustRoots = [.certificates([ca])]
  clientConfig.dnsOverride = ["api.\(provider).com": "127.0.0.1"]
  let transportTLS = try #require(clientConfig.tlsConfiguration)
  let proxyChildren = ConnectionRegistry()
  let upstreamChildren = ConnectionRegistry()
  let guests = ConnectionRegistry()
  let upload = NIOLockedValueBox(LimitUploadState())
  let capture = NIOLockedValueBox(LimitGuestState())
  var listeners: [Channel] = []
  let observation: [String: Any]
  do {
    let upstream = try await ServerBootstrap(group: group).childChannelInitializer { channel in
      upstreamChildren.add(channel)
      upload.withLockedValue { $0.connections += 1 }
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
      }.flatMap {
        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false)
      }.flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            LimitUploadPeer(upload, provider: provider))
        }
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    listeners.append(upstream)
    let port = try #require(upstream.localAddress?.port)
    let config = try ProxyConfig(
      json: JSONSerialization.data(withJSONObject: [
        "version": 1, "listen": "127.0.0.1:0", "provider": provider,
        "capability_token": String(repeating: "a", count: 64),
        "injection": ["scheme": "bearer", "credential": "limit-test-secret"],
      ]))
    let proxy = try await Server.bind(config: config, group: group, registry: proxyChildren) {
      channel in
      channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            StreamingBridge(config: config) { request, relay, loop in
              let prefix = "https://api.\(provider).com"
              let target = String(request.url.absoluteString.dropFirst(prefix.count))
              let local = try! HTTPClient.Request(
                url: "\(prefix):\(port)\(target)",
                method: request.method, headers: request.headers, body: request.body)
              return OwnedHTTPRequest(
                request: local, relay: relay, eventLoop: loop,
                tlsConfiguration: transportTLS, connectHost: "127.0.0.1")
            })
        }
      }
    }.get()
    listeners.append(proxy)
    let address = try #require(proxy.localAddress)
    let guest = try await ClientBootstrap(group: group).channelInitializer { channel in
      guests.add(channel)
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(LimitGuestCapture(capture))
      }
    }.connect(to: address).get()
    let path = provider == "anthropic" ? "/v1/messages" : "/v1/responses"
    let framing =
      declared.map { "Content-Length: \($0)" }
      ?? "Transfer-Encoding: chunked\r\nExpect: 100-continue"
    let wire =
      "POST \(path) HTTP/1.1\r\nHost: guest.invalid\r\nAuthorization: Bearer "
      + String(repeating: "a", count: 64) + "\r\n\(framing)\r\n\r\n"
    try await guest.writeAndFlush(ByteBuffer(string: wire)).get()
    if declared == bodyCap {
      for offset in stride(from: 0, to: bodyCap, by: 65536) {
        let chunk = (0..<65536).map { UInt8((offset + $0) % 251) }
        try await guest.writeAndFlush(ByteBuffer(bytes: chunk)).get()
        if offset == 0 {
          try await waitForLimitState("first body chunk did not reach upstream") {
            upload.withLockedValue { $0.bytes >= 65536 }
          }
        }
      }
    }
    try await waitForLimitState("body-limit response did not close") {
      capture.withLockedValue { $0.closed }
    }
    let response = capture.withLockedValue { $0.wire }
    let statusText = try #require(response.split(separator: " ").dropFirst().first)
    let status = try #require(Int(statusText))
    #expect(status == (declared == nil ? 411 : (declared == bodyCap ? 200 : 413)))
    if declared == bodyCap { #expect(response.hasSuffix("accepted")) }
    #expect(!response.contains("limit-test-secret"))
    #expect(!response.contains(String(repeating: "a", count: 64)))
    try await waitForLimitState("upstream body-limit socket did not close") {
      upload.withLockedValue { $0.closed == $0.connections }
    }
    let observed = upload.withLockedValue { $0 }
    let count = declared == bodyCap ? 1 : 0
    #expect(observed.connections == count)
    #expect(observed.requests == count)
    #expect(observed.bytes == (declared == bodyCap ? bodyCap : 0))
    #expect(observed.digest == (declared == bodyCap ? expectedBodyHash : nil))
    observation = [
      "provider": provider, "declared_bytes": declared.map { $0 as Any } ?? NSNull(),
      "status": status,
      "upstream_connections": observed.connections, "upstream_requests": observed.requests,
      "upstream_body_bytes": observed.bytes,
      "upstream_sha256": observed.digest.map { $0 as Any } ?? NSNull(),
      "upstream_closed": observed.closed, "guest_closed": capture.withLockedValue { $0.closed },
    ]

  } catch {
    for listener in listeners { try? await listener.close().get() }
    await guests.closeAll()
    await proxyChildren.closeAll()
    await upstreamChildren.closeAll()
    try await group.shutdownGracefully()
    throw error
  }
  for listener in listeners { try? await listener.close().get() }
  await guests.closeAll()
  await proxyChildren.closeAll()
  await upstreamChildren.closeAll()
  try await group.shutdownGracefully()
  return observation
}
