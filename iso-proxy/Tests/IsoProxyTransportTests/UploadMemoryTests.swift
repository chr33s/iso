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

private struct UploadMemoryState: Sendable {
  var peer: (any Channel)?
  var sent = 0
  var received = 0
  var closed = false
  var producerStopped = false
}

/// Stop reading only after verified TLS and HTTP headers have reached the peer.
private final class StalledUploadProvider: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  let state: NIOLockedValueBox<UploadMemoryState>
  init(_ state: NIOLockedValueBox<UploadMemoryState>) { self.state = state }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head:
      let channel = context.channel
      let state = state
      channel.setOption(ChannelOptions.autoRead, value: false).whenSuccess {
        state.withLockedValue { $0.peer = channel }
      }
    case .body(let buffer): state.withLockedValue { $0.received += buffer.readableBytes }
    case .end: break
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    state.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
}

/// The guest retains one 64 KiB buffer and awaits every socket flush.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ISO_PROXY_UPLOAD_MEMORY_GATE"] == "1"))
func slowProviderBoundsResidentMemoryAndGuestUploadProgress() async throws {
  let offered = try #require(
    Int(ProcessInfo.processInfo.environment["ISO_MEMORY_UPLOAD_BYTES"] ?? ""))
  try #require([16 * 1024 * 1024, Limits.requestBodyBytes].contains(offered))
  let connections = Int(ProcessInfo.processInfo.environment["ISO_MEMORY_CONNECTIONS"] ?? "1") ?? 0
  try #require([1, 256].contains(connections))
  let tls = try verifiedTLSFixture()
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let providerChildren = ConnectionRegistry()
  let proxyChildren = ConnectionRegistry()
  let guests = ConnectionRegistry()
  let states = NIOLockedValueBox<[NIOLockedValueBox<UploadMemoryState>]>([])
  @Sendable func snapshots() -> [UploadMemoryState] {
    states.withLockedValue { $0 }.map { $0.withLockedValue { $0 } }
  }
  var guestChannels: [any Channel] = []
  var producers: [Task<Void, Never>] = []
  var listeners: [Channel] = []
  do {
    let provider = try await ServerBootstrap(group: group)
      .childChannelOption(ChannelOptions.socketOption(.so_rcvbuf), value: 16 * 1024)
      .childChannelOption(
        ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16 * 1024)
      )
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .childChannelInitializer { channel in
        providerChildren.add(channel)
        let state = NIOLockedValueBox(UploadMemoryState())
        states.withLockedValue { $0.append(state) }
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls.server))
        }.flatMap {
          channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false)
        }.flatMap {
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(StalledUploadProvider(state))
          }
        }
      }.bind(host: "127.0.0.1", port: 0).get()
    listeners.append(provider)
    let port = try #require(provider.localAddress?.port)
    let token = String(repeating: "a", count: 64)
    let config = try ProxyConfig(
      json: JSONSerialization.data(withJSONObject: [
        "version": 1, "provider": "anthropic", "listen": "127.0.0.1:0",
        "capability_token": token,
        "injection": ["scheme": "bearer", "credential": "upload-memory-test-only"],
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
                tlsConfiguration: tls.client, connectHost: "127.0.0.1")
            })
        }
      }
    }.get()
    listeners.append(proxy)
    for index in 0..<connections {
      let guest = try await ClientBootstrap(group: group).channelInitializer { channel in
        guests.add(channel)
        return channel.eventLoop.makeSucceededVoidFuture()
      }.connect(to: #require(proxy.localAddress)).get()
      try await guest.writeAndFlush(
        ByteBuffer(
          string:
            "POST /v1/messages HTTP/1.1\r\nHost: guest\r\nContent-Length: \(offered)\r\nAuthorization: Bearer \(token)\r\n\r\n"
        )
      ).get()
      guestChannels.append(guest)
      // Establish one peer at a time so its state maps to this guest producer.
      try await waitMemoryState {
        let peers = snapshots()
        return peers.count == index + 1 && peers.allSatisfy { $0.peer != nil }
      }
    }
    let baseline = try residentBytes()
    for (guest, state) in zip(guestChannels, states.withLockedValue { $0 }) {
      producers.append(
        Task {
          defer { state.withLockedValue { $0.producerStopped = true } }
          do {
            let chunk = ByteBuffer(repeating: 0x5a, count: 64 * 1024)
            for _ in stride(from: 0, to: offered, by: chunk.readableBytes) {
              try await guest.writeAndFlush(chunk).get()
              state.withLockedValue { $0.sent += chunk.readableBytes }
            }
          } catch {
            // Guest closure must interrupt the pending write.
          }
        }
      )
    }
    try await waitMemoryState { snapshots().allSatisfy { $0.sent > 0 } }
    var peak = baseline
    var samples: [[String: UInt64]] = []
    let started = ContinuousClock.now
    var lastProgress = started
    var lastSent = snapshots().reduce(0) { $0 + $1.sent }
    var plateauMilliseconds: Int64 = 0
    while started.duration(to: .now) < .seconds(20) {
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
        "resident_bytes": resident, "guest_sent": UInt64(sent),
        "plateau_ms": UInt64(plateauMilliseconds),
      ])
      if plateauMilliseconds >= 3000 { break }
    }
    let peers = snapshots()
    let sent = peers.reduce(0) { $0 + $1.sent }
    let received = peers.reduce(0) { $0 + $1.received }
    let growthLimit = (connections == 1 ? 32 : 256) * 1024 * 1024
    var observation: [String: Any] = [
      "connections": connections, "offered_bytes": offered, "baseline_rss": baseline,
      "peak_rss": peak,
      "growth_rss": peak - baseline, "guest_sent": sent, "per_peer_sent": peers.map { $0.sent },
      "samples": samples,
      "plateau_ms": plateauMilliseconds, "provider_received_while_stalled": received,
      "per_peer_received": peers.map { $0.received },
      "upstream_closed": peers.allSatisfy { $0.closed },
      "producer_stopped": peers.allSatisfy { $0.producerStopped },
    ]
    try writeMemoryObservation(observation)
    try #require(
      peak - baseline < growthLimit, "stalled provider allowed excessive RSS growth")
    try #require(
      peers.allSatisfy { $0.sent > 0 && $0.sent < 8 * 1024 * 1024 },
      "stalled provider did not bound guest progress")
    // Disabling autoRead cannot retract an outstanding TLS read. Permit one
    // bounded batch, while forbidding sustained provider consumption.
    try #require(
      peers.allSatisfy { $0.received <= 64 * 1024 }, "provider unexpectedly consumed the upload")
    try #require(plateauMilliseconds >= 3000, "guest upload did not stop advancing")
    try #require(peers.allSatisfy { !$0.closed && !$0.producerStopped })
    await guests.closeAll()
    try await waitMemoryState { snapshots().allSatisfy { $0.producerStopped } }
    for producer in producers { await producer.value }
    // Resume only to observe transport EOF after cancellation, draining bytes
    // already in socket buffers. This does not contribute to the RSS samples.
    for snapshot in peers {
      let peer = try #require(snapshot.peer)
      try await peer.setOption(ChannelOptions.autoRead, value: true).get()
    }
    try await waitMemoryState { snapshots().allSatisfy { $0.closed } }
    observation["upstream_closed"] = snapshots().allSatisfy { $0.closed }
    observation["producer_stopped"] = snapshots().allSatisfy { $0.producerStopped }
    try writeMemoryObservation(observation)
  } catch {
    for listener in listeners { try? await listener.close().get() }
    await guests.closeAll()
    // Stalled fixture peers must read TLS close_notify during error cleanup too.
    // Otherwise sequential TLS closes can each wait for their shutdown deadline.
    for snapshot in snapshots() {
      if let peer = snapshot.peer {
        try? await peer.setOption(ChannelOptions.autoRead, value: true).get()
      }
    }
    await proxyChildren.closeAll()
    await providerChildren.closeAll()
    for producer in producers { await producer.value }
    try await group.shutdownGracefully()
    throw error
  }
  for listener in listeners { try? await listener.close().get() }
  await guests.closeAll()
  await proxyChildren.closeAll()
  await providerChildren.closeAll()
  try await group.shutdownGracefully()
}
