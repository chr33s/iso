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

private struct IdleObservation: Encodable, Sendable {
  let provider: String
  let status: Int
  let upstreamBody: [UInt8]
  let uploadComplete: Bool
  let guestClosed: Bool
  let upstreamClosed: Bool
  let elapsedMs: Int64
  enum CodingKeys: String, CodingKey {
    case provider, status
    case upstreamBody = "upstream_body"
    case uploadComplete = "upload_complete"
    case guestClosed = "guest_closed"
    case upstreamClosed = "upstream_closed"
    case elapsedMs = "elapsed_ms"
  }
}

private struct IdleUploadState: Sendable {
  var body: [UInt8] = []
  var complete = false
  var closed = false
}

private final class IdleUploadPeer: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  let state: NIOLockedValueBox<IdleUploadState>
  let provider: String
  init(_ state: NIOLockedValueBox<IdleUploadState>, provider: String) {
    self.state = state
    self.provider = provider
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      #expect(head.method == .POST)
      #expect(head.headers["host"] == ["api.\(provider).com"])
      #expect(head.headers["authorization"] == ["Bearer idle-test-secret"])
    case .body(let bytes): state.withLockedValue { $0.body += bytes.readableBytesView }
    case .end: state.withLockedValue { $0.complete = true }
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    state.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

private struct IdleGuestState: Sendable {
  var wire = ""
  var closed = false
}

private final class IdleGuestCapture: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let state: NIOLockedValueBox<IdleGuestState>
  init(_ state: NIOLockedValueBox<IdleGuestState>) { self.state = state }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let bytes = unwrapInboundIn(data)
    state.withLockedValue { $0.wire += String(buffer: bytes) }
  }
  func channelInactive(context: ChannelHandlerContext) {
    state.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
}

private func waitForIdleState(seconds: Int = 5, _ condition: @Sendable () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  try #require(condition(), "body-idle state did not settle")
}

@Test func realTLSUploadIdleDeadlineResetsAndCancelsUpstream() async throws {
  let fixtures = try generateForwardingFixtures()
  defer { try? FileManager.default.removeItem(at: fixtures) }
  async let anthropic = idleUpload(provider: "anthropic", fixtures: fixtures)
  async let openai = idleUpload(provider: "openai", fixtures: fixtures)
  let observations = try await [anthropic, openai]
  if let path = ProcessInfo.processInfo.environment["COOP_IDLE_OBSERVATIONS"] {
    try JSONEncoder().encode(observations).write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

private func idleUpload(provider: String, fixtures: URL) async throws -> IdleObservation {
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
  let upload = NIOLockedValueBox(IdleUploadState())
  let capture = NIOLockedValueBox(IdleGuestState())
  var listeners: [Channel] = []
  let observation: IdleObservation
  do {
    let upstream = try await ServerBootstrap(group: group).childChannelInitializer { channel in
      upstreamChildren.add(channel)
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
      }.flatMap {
        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false)
      }.flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(IdleUploadPeer(upload, provider: provider))
        }
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    listeners.append(upstream)
    let port = try #require(upstream.localAddress?.port)
    let config = try ProxyConfig(
      json: JSONSerialization.data(withJSONObject: [
        "version": 1, "listen": "127.0.0.1:0", "provider": provider,
        "capability_token": String(repeating: "a", count: 64),
        "injection": ["scheme": "bearer", "credential": "idle-test-secret"],
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
        try channel.pipeline.syncOperations.addHandler(IdleGuestCapture(capture))
      }
    }.connect(to: address).get()
    let path = provider == "anthropic" ? "/v1/messages" : "/v1/responses"
    let started = ContinuousClock.now
    let wire =
      "POST \(path) HTTP/1.1\r\nHost: guest.invalid\r\nAuthorization: Bearer "
      + String(repeating: "a", count: 64) + "\r\nContent-Length: 3\r\n\r\na"
    try await guest.writeAndFlush(ByteBuffer(string: wire)).get()
    try await waitForIdleState { upload.withLockedValue { $0.body == [97] } }
    try await Task.sleep(for: .seconds(15))
    try await guest.writeAndFlush(ByteBuffer(string: "b")).get()
    try await waitForIdleState { upload.withLockedValue { $0.body == [97, 98] } }
    try await waitForIdleState(seconds: 35) { capture.withLockedValue { $0.closed } }
    let elapsed = started.duration(to: .now)
    let milliseconds =
      elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
    try #require((44000...51000).contains(milliseconds), "body idle deadline failed to reset")
    let response = capture.withLockedValue { $0.wire }
    #expect(response.hasPrefix("HTTP/1.1 408 "))
    #expect(!response.contains("idle-test-secret"))
    #expect(!response.contains(String(repeating: "a", count: 64)))
    try await waitForIdleState { upload.withLockedValue { $0.closed } }
    #expect(!upload.withLockedValue { $0.complete })
    let statusText = try #require(response.split(separator: " ").dropFirst().first)
    let status = try #require(Int(statusText))
    observation = IdleObservation(
      provider: provider, status: status,
      upstreamBody: upload.withLockedValue { $0.body },
      uploadComplete: upload.withLockedValue { $0.complete },
      guestClosed: capture.withLockedValue { $0.closed },
      upstreamClosed: upload.withLockedValue { $0.closed },
      elapsedMs: milliseconds)
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
