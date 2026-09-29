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

private struct StreamPeers: Sendable {
  var channels: [Channel] = []
  var admitted = 0
  var closed = 0
}

private final class HeldStreamProvider: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let peers: NIOLockedValueBox<StreamPeers>
  let provider: String
  init(_ peers: NIOLockedValueBox<StreamPeers>, provider: String) {
    self.peers = peers
    self.provider = provider
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      #expect(head.method == .POST)
      #expect(head.uri == streamOperation(provider))
      #expect(head.headers["host"] == ["api.\(provider).com"])
      #expect(head.headers["authorization"] == ["Bearer stream-test-secret"])
    case .body(let bytes): #expect(bytes.readableBytes == 0)
    case .end:
      peers.withLockedValue {
        $0.channels.append(context.channel)
        $0.admitted += 1
      }
      context.write(
        wrapOutboundOut(
          .head(
            .init(
              version: .http1_1, status: .ok,
              headers: HTTPHeaders([("transfer-encoding", "chunked")])))), promise: nil)
      context.writeAndFlush(
        wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: "data: held\n\n")))), promise: nil)
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    peers.withLockedValue { $0.closed += 1 }
    context.fireChannelInactive()
  }
}

private struct StreamCapture: Sendable {
  var wire = ""
  var closed = false
}

private final class StreamGuest: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let capture: NIOLockedValueBox<StreamCapture>
  init(_ capture: NIOLockedValueBox<StreamCapture>) { self.capture = capture }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let bytes = unwrapInboundIn(data)
    capture.withLockedValue { $0.wire += String(buffer: bytes) }
  }
  func channelInactive(context: ChannelHandlerContext) {
    capture.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    context.close(promise: nil)
  }
}

private func streamOperation(_ provider: String) -> String {
  provider == "anthropic" ? "/v1/messages" : "/v1/responses"
}

private func awaitStreamCondition(_ stage: String, _ condition: @Sendable () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(1))
  }
  try #require(condition(), "stream state did not settle within five seconds: \(stage)")
}

@Test func realTLSStreamsHold256SlotsUntilCompletionOrDisconnect() async throws {
  try await runStreamCapacity(measureMemory: false)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["ISO_PROXY_STREAM_MEMORY_GATE"] == "1"))
func heldTLSStreamsBoundAggregateResidentMemory() async throws {
  try await runStreamCapacity(measureMemory: true)
}

private func runStreamCapacity(measureMemory: Bool) async throws {
  let fixtures = try generateForwardingFixtures()
  defer { try? FileManager.default.removeItem(at: fixtures) }
  var observations: [[String: Any]] = []
  for provider in ["anthropic", "openai"] {
    observations.append(
      contentsOf: try await streamCapacity(
        provider: provider, fixtures: fixtures, measureMemory: measureMemory))
  }
  if let path = ProcessInfo.processInfo.environment["ISO_STREAM_OBSERVATIONS"] {
    try JSONSerialization.data(
      withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

private func streamCapacity(provider: String, fixtures: URL, measureMemory: Bool) async throws
  -> [[String: Any]]
{
  var observations: [[String: Any]] = []
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
  let peers = NIOLockedValueBox(StreamPeers())
  var listeners: [Channel] = []
  do {
    let upstream = try await ServerBootstrap(group: group).childChannelInitializer { channel in
      upstreamChildren.add(channel)
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
      }.flatMap {
        // Continue reading peer EOF while a response is deliberately held open.
        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false)
      }.flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            HeldStreamProvider(peers, provider: provider))
        }
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    listeners.append(upstream)
    let port = try #require(upstream.localAddress?.port)
    let config = try ProxyConfig(
      json: JSONSerialization.data(withJSONObject: [
        "version": 1, "listen": "127.0.0.1:0", "provider": provider,
        "capability_token": String(repeating: "a", count: 64),
        "injection": ["scheme": "bearer", "credential": "stream-test-secret"],
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
    let baseline = measureMemory ? try residentBytes() : 0
    var firstRoundPeak: UInt64 = 0
    for (round, disconnect) in [true, false, true].enumerated() {
      let before = peers.withLockedValue { ($0.admitted, $0.closed) }
      var completed = 0
      var held: [(Channel, NIOLockedValueBox<StreamCapture>)] = []
      for index in 0..<256 {
        let guest = try await openStreamGuest(
          group: group, address: address, registry: guests, provider: provider)
        held.append(guest)
        try await awaitStreamCondition("\(provider) round \(round) first chunk \(index)") {
          guest.1.withLockedValue { $0.wire.contains("data: held\n\n") }
        }
        #expect(guest.1.withLockedValue { $0.wire.hasPrefix("HTTP/1.1 200 ") && !$0.closed })
      }
      #expect(peers.withLockedValue { $0.admitted == (round + 1) * 256 })
      let excess = try await openStreamGuest(
        group: group, address: address, registry: guests, provider: provider, tolerateClosure: true)
      try await awaitStreamCondition("excess guest closure") {
        excess.1.withLockedValue { $0.closed }
      }
      #expect(excess.1.withLockedValue { $0.wire.isEmpty })
      #expect(peers.withLockedValue { $0.admitted == (round + 1) * 256 })
      var rssSamples: [UInt64] = []
      if measureMemory { rssSamples.append(try residentBytes()) }
      var heldDurationMilliseconds: Int64 = 0
      if !disconnect {
        let started = ContinuousClock.now
        if measureMemory {
          while started.duration(to: .now) < .seconds(31) {
            try await Task.sleep(for: .milliseconds(100))
            rssSamples.append(try residentBytes())
          }
        } else {
          try await Task.sleep(for: .seconds(31))
        }
        let elapsed = started.duration(to: .now)
        heldDurationMilliseconds =
          elapsed.components.seconds * 1000
          + elapsed.components.attoseconds / 1_000_000_000_000_000
        for (_, capture) in held {
          try #require(
            capture.withLockedValue { !$0.closed }, "stream closed before final SSE chunk")
        }
        #expect(peers.withLockedValue { $0.closed == before.1 })
      }
      if disconnect {
        for (channel, _) in held { try await channel.close().get() }
      } else {
        for channel in peers.withLockedValue({ Array($0.channels.suffix(256)) }) {
          try await channel.writeAndFlush(
            HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "data: finished\n\n")))
          ).get()
          try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
        }
        for (_, capture) in held {
          try await awaitStreamCondition("completed guest closure") {
            capture.withLockedValue { $0.closed }
          }
          #expect(
            capture.withLockedValue {
              $0.wire.contains("data: finished\n\n") && $0.wire.hasSuffix("0\r\n\r\n")
            })
          completed += 1
        }
      }
      try await awaitStreamCondition("\(provider) round \(round) upstream closure") {
        peers.withLockedValue { $0.closed == (round + 1) * 256 }
      }
      let after = peers.withLockedValue { ($0.admitted, $0.closed) }
      var observation: [String: Any] = [
        "provider": provider, "round": round,
        "termination": disconnect ? "disconnect" : "complete",
        "held_responses": held.count, "upstream_requests": after.0 - before.0,
        "upstream_closed": after.1 - before.1,
        "excess_response_bytes": excess.1.withLockedValue { $0.wire.utf8.count },
        "completed_responses": completed, "held_duration_ms": heldDurationMilliseconds,
      ]
      // Do not let fixture bookkeeping retain every closed TLS channel across
      // rounds. Admission counts are independent of the current channel array.
      peers.withLockedValue { $0.channels.removeAll() }
      held.removeAll()
      if measureMemory {
        rssSamples.append(try residentBytes())
        let peak = max(baseline, try #require(rssSamples.max()))
        if round == 0 { firstRoundPeak = peak }
        let laterGrowth = peak > firstRoundPeak ? peak - firstRoundPeak : 0
        observation["baseline_rss"] = baseline
        observation["rss_samples"] = rssSamples
        observation["peak_rss"] = peak
        observation["growth_rss"] = peak - baseline
        observation["growth_after_first_round"] = laterGrowth
        try #require(
          peak - baseline < 256 * 1024 * 1024, "256 held TLS streams exceeded RSS budget")
        try #require(
          laterGrowth < 64 * 1024 * 1024, "repeated stream rounds retained excessive memory")
      }
      observations.append(observation)
    }
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
  return observations
}

private func openStreamGuest(
  group: EventLoopGroup, address: SocketAddress,
  registry: ConnectionRegistry, provider: String, tolerateClosure: Bool = false
) async throws -> (Channel, NIOLockedValueBox<StreamCapture>) {
  let capture = NIOLockedValueBox(StreamCapture())
  let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
    registry.add(channel)
    return channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(StreamGuest(capture))
    }
  }.connect(to: address).get()
  let wire =
    "POST \(streamOperation(provider)) HTTP/1.1\r\nHost: guest.invalid\r\nAuthorization: Bearer "
    + String(repeating: "a", count: 64) + "\r\nContent-Length: 0\r\n\r\n"
  do { try await channel.writeAndFlush(ByteBuffer(string: wire)).get() } catch {
    if !tolerateClosure { throw error }
  }
  return (channel, capture)
}
