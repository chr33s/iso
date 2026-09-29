import AsyncHTTPClient
import Darwin
import Foundation
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import IsoProxyTransport

private struct MemoryPeerState: Sendable {
  var requested = false
  var sent = 0
  var closed = false
  var producerStopped = false
}

/// The fixture itself retains one 64 KiB buffer and awaits each socket flush.
private final class MemoryProvider: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  let state: NIOLockedValueBox<MemoryPeerState>
  let start: EventLoopFuture<Void>
  let offered: Int
  init(state: NIOLockedValueBox<MemoryPeerState>, start: EventLoopFuture<Void>, offered: Int) {
    self.state = state
    self.start = start
    self.offered = offered
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .end = unwrapInboundIn(data) else { return }
    let channel = context.channel
    let state = state
    let start = start
    let offered = offered
    state.withLockedValue { $0.requested = true }
    Task {
      defer { state.withLockedValue { $0.producerStopped = true } }
      do {
        try await start.get()
        let head = HTTPResponseHead(
          version: .http1_1, status: .ok,
          headers: HTTPHeaders([("content-length", String(offered))]))
        try await channel.writeAndFlush(HTTPServerResponsePart.head(head)).get()
        let chunk = ByteBuffer(repeating: 0x5a, count: 64 * 1024)
        for _ in stride(from: 0, to: offered, by: chunk.readableBytes) {
          try await channel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(chunk))).get()
          state.withLockedValue { $0.sent += chunk.readableBytes }
        }
        try await channel.writeAndFlush(HTTPServerResponsePart.end(nil)).get()
      } catch {
        // Closing the deliberately stalled guest must cancel this write loop.
      }
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    state.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
}

func residentBytes() throws -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
  let result = withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  try #require(result == KERN_SUCCESS)
  return UInt64(info.resident_size)
}

func waitMemoryState(_ condition: @Sendable () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  try #require(condition(), "memory fixture did not reach its expected state")
}

/// Run only in an isolated test process so other tests cannot distort RSS.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ISO_PROXY_MEMORY_GATE"] == "1"))
func slowGuestBoundsResidentMemoryAndUpstreamProgress() async throws {
  let offered = try #require(
    Int(ProcessInfo.processInfo.environment["ISO_MEMORY_RESPONSE_BYTES"] ?? ""))
  try #require([256 * 1024 * 1024, 1024 * 1024 * 1024].contains(offered))
  let connections = Int(ProcessInfo.processInfo.environment["ISO_MEMORY_CONNECTIONS"] ?? "1") ?? 0
  try #require([1, 256].contains(connections))
  let fixtures = try generateForwardingFixtures()
  defer { try? FileManager.default.removeItem(at: fixtures) }
  let ca = try NIOSSLCertificate.fromDERFile(fixtures.appendingPathComponent("forward_ca.der").path)
  let leaf = try NIOSSLCertificate.fromDERFile(
    fixtures.appendingPathComponent("forward_leaf.der").path)
  let key = try NIOSSLPrivateKey(
    file: fixtures.appendingPathComponent("forward_leaf.pkcs8.der").path, format: .der)
  let tls = try NIOSSLContext(
    configuration: .makeServerConfiguration(
      certificateChain: [.certificate(leaf), .certificate(ca)], privateKey: .privateKey(key)))
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  var settings = UpstreamClient.configuration()
  settings.tlsConfiguration?.additionalTrustRoots = [.certificates([ca])]
  settings.dnsOverride = ["api.anthropic.com": "127.0.0.1"]
  let transportTLS = try #require(settings.tlsConfiguration)
  let providerChildren = ConnectionRegistry()
  let proxyChildren = ConnectionRegistry()
  let guests = ConnectionRegistry()
  let states = NIOLockedValueBox<[NIOLockedValueBox<MemoryPeerState>]>([])
  @Sendable func snapshots() -> [MemoryPeerState] {
    states.withLockedValue { $0 }.map { $0.withLockedValue { $0 } }
  }
  let start = group.next().makePromise(of: Void.self)
  var started = false
  var listeners: [Channel] = []
  var observation: [String: Any] = [:]
  do {
    let provider = try await ServerBootstrap(group: group).childChannelInitializer { channel in
      providerChildren.add(channel)
      let state = NIOLockedValueBox(MemoryPeerState())
      states.withLockedValue { $0.append(state) }
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
      }.flatMap {
        channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false)
      }.flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            MemoryProvider(state: state, start: start.futureResult, offered: offered))
        }
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    listeners.append(provider)
    let port = try #require(provider.localAddress?.port)
    let config = try ProxyConfig(
      json: JSONSerialization.data(withJSONObject: [
        "version": 1, "provider": "anthropic", "listen": "127.0.0.1:0",
        "capability_token": String(repeating: "a", count: 64),
        "injection": ["scheme": "bearer", "credential": "memory-test-only"],
      ]))
    let proxy = try await Server.bind(config: config, group: group, registry: proxyChildren) {
      channel in
      channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            StreamingBridge(config: config) { request, relay, loop in
              let local = try! HTTPClient.Request(
                url: "https://api.anthropic.com:\(port)/v1/messages",
                method: request.method, headers: request.headers, body: request.body)
              return OwnedHTTPRequest(
                request: local, relay: relay, eventLoop: loop,
                tlsConfiguration: transportTLS, connectHost: "127.0.0.1")
            })
        }
      }
    }.get()
    listeners.append(proxy)
    for _ in 0..<connections {
      let guest = try await ClientBootstrap(group: group)
        .channelOption(ChannelOptions.autoRead, value: false)
        .channelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 16 * 1024)
        .channelInitializer { channel in
          guests.add(channel)
          return channel.eventLoop.makeSucceededVoidFuture()
        }.connect(to: #require(proxy.localAddress)).get()
      let wire =
        "POST /v1/messages HTTP/1.1\r\nHost: guest\r\nContent-Length: 0\r\nAuthorization: Bearer "
        + String(repeating: "a", count: 64) + "\r\n\r\n"
      try await guest.writeAndFlush(ByteBuffer(string: wire)).get()
    }
    try await waitMemoryState {
      let peers = snapshots()
      return peers.count == connections && peers.allSatisfy { $0.requested }
    }
    let baseline = try residentBytes()
    start.succeed(())
    started = true
    try await waitMemoryState { snapshots().allSatisfy { $0.sent > 0 } }
    var peak = baseline
    var samples: [[String: UInt64]] = []
    let samplingStarted = ContinuousClock.now
    var lastProgress = samplingStarted
    var lastSent = snapshots().reduce(0) { $0 + $1.sent }
    var plateauMilliseconds: Int64 = 0
    while samplingStarted.duration(to: .now) < .seconds(20) {
      try await Task.sleep(for: .milliseconds(100))
      let resident = try residentBytes()
      let sent = snapshots().reduce(0) { $0 + $1.sent }
      if sent != lastSent {
        lastProgress = .now
        lastSent = sent
      }
      let plateau = lastProgress.duration(to: .now)
      plateauMilliseconds =
        plateau.components.seconds * 1000
        + plateau.components.attoseconds / 1_000_000_000_000_000
      peak = max(peak, resident)
      samples.append([
        "resident_bytes": resident, "upstream_sent": UInt64(sent),
        "plateau_ms": UInt64(plateauMilliseconds),
      ])
      if plateauMilliseconds >= 3000 { break }
    }
    let peers = snapshots()
    let sent = peers.reduce(0) { $0 + $1.sent }
    let growthLimit = (connections == 1 ? 32 : 256) * 1024 * 1024
    let growth = peak - baseline
    observation = [
      "connections": connections, "offered_bytes": offered, "baseline_rss": baseline,
      "peak_rss": peak,
      "growth_rss": growth, "upstream_sent": sent, "per_peer_sent": peers.map { $0.sent },
      "samples": samples,
      "plateau_ms": plateauMilliseconds, "upstream_closed": peers.allSatisfy { $0.closed },
      "producer_stopped": peers.allSatisfy { $0.producerStopped },
    ]
    try writeMemoryObservation(observation)
    try #require(growth < growthLimit, "slow guest allowed excessive resident-memory growth")
    try #require(
      peers.allSatisfy { $0.sent > 0 && $0.sent < 16 * 1024 * 1024 },
      "slow guest did not bound upstream progress")
    try #require(
      plateauMilliseconds >= 3000, "upstream never stopped advancing while guest was stalled")
    #expect(peers.allSatisfy { !$0.closed && !$0.producerStopped })
    await guests.closeAll()
    try await waitMemoryState { snapshots().allSatisfy { $0.closed && $0.producerStopped } }
    observation["upstream_closed"] = snapshots().allSatisfy { $0.closed }
    observation["producer_stopped"] = snapshots().allSatisfy { $0.producerStopped }

  } catch {
    if !started { start.succeed(()) }
    for listener in listeners { try? await listener.close().get() }
    await guests.closeAll()
    await proxyChildren.closeAll()
    await providerChildren.closeAll()
    try await group.shutdownGracefully()
    throw error
  }
  for listener in listeners { try? await listener.close().get() }
  await guests.closeAll()
  await proxyChildren.closeAll()
  await providerChildren.closeAll()
  try await group.shutdownGracefully()
  try writeMemoryObservation(observation)
}

func writeMemoryObservation(_ observation: [String: Any]) throws {
  if let path = ProcessInfo.processInfo.environment["ISO_MEMORY_OBSERVATIONS"] {
    try JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}
