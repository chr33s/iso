import CoopProxyCore
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import CoopProxyTransport

private final class CountAggregateInput: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let bytes: NIOLockedValueBox<Int>
  init(_ bytes: NIOLockedValueBox<Int>) { self.bytes = bytes }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    bytes.withLockedValue { $0 += unwrapInboundIn(data).readableBytes }
    context.fireChannelRead(data)
  }
}

private final class UnexpectedAggregateRequest: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  let count: NIOLockedValueBox<Int>
  init(_ count: NIOLockedValueBox<Int>) { self.count = count }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    count.withLockedValue { $0 += 1 }
  }
}

private struct AggregateReply: Sendable {
  var wire = ""
  var closed = false
  var overflow = false
}

private final class AggregateGuest: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let state: NIOLockedValueBox<AggregateReply>
  init(_ state: NIOLockedValueBox<AggregateReply>) { self.state = state }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let buffer = unwrapInboundIn(data)
    state.withLockedValue {
      if $0.wire.utf8.count + buffer.readableBytes <= 4096 {
        $0.wire += String(buffer: buffer)
      } else {
        $0.overflow = true
      }
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    state.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["COOP_PROXY_AGGREGATE_MEMORY_GATE"] == "1"))
func concurrentPartialAndMalformedHeadersBoundResidentMemory() async throws {
  let rounds = try #require(Int(ProcessInfo.processInfo.environment["COOP_MEMORY_ROUNDS"] ?? ""))
  try #require([2, 8].contains(rounds))
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
  let peers = ConnectionRegistry()
  let guests = ConnectionRegistry()
  let received = NIOLockedValueBox(0)
  let forwarded = NIOLockedValueBox(0)
  let config = try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "provider": "anthropic", "listen": "127.0.0.1:0",
      "capability_token": String(repeating: "a", count: 64),
      "injection": ["scheme": "bearer", "credential": "aggregate-memory-test-only"],
    ]))
  let server = try await Server.bind(config: config, group: group, registry: peers) { channel in
    channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(
        CountAggregateInput(received), position: .first)
      try channel.pipeline.syncOperations.addHandler(UnexpectedAggregateRequest(forwarded))
    }
  }.get()
  let address = try #require(server.localAddress)
  func connect(_ reply: NIOLockedValueBox<AggregateReply>) async throws -> Channel {
    try await ClientBootstrap(group: group).channelInitializer { channel in
      guests.add(channel)
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(AggregateGuest(reply))
      }
    }.connect(to: address).get()
  }
  // Roughly 48 KiB retained by each parser, with an unfinished final field.
  // The same immutable source buffer is reused by all fixture clients.
  let partial = ByteBuffer(
    string: "POST /v1/messages HTTP/1.1\r\nHost: guest\r\n"
      + String(repeating: "X-Pad: " + String(repeating: "p", count: 8192) + "\r\n", count: 4)
      + "X-Unfinished: " + String(repeating: "q", count: Limits.headerFieldBytes - 64))
  let malformed = ByteBuffer(repeating: 0x71, count: 128)
  let baseline = try residentBytes()
  var samples: [[String: UInt64]] = []
  do {
    for round in 0..<rounds {
      received.withLockedValue { $0 = 0 }
      var channels: [Channel] = []
      var replies: [NIOLockedValueBox<AggregateReply>] = []
      for _ in 0..<Limits.connections {
        let reply = NIOLockedValueBox(AggregateReply())
        let channel = try await connect(reply)
        channels.append(channel)
        replies.append(reply)
        try await channel.writeAndFlush(partial).get()
      }
      let expected = Limits.connections * partial.readableBytes
      try await waitMemoryState { received.withLockedValue { $0 >= expected } }
      try #require(
        channels.allSatisfy { $0.isActive }, "all 256 partial headers must remain admitted")
      try #require(replies.allSatisfy { $0.withLockedValue { $0.wire.isEmpty && !$0.closed } })
      let excessReply = NIOLockedValueBox(AggregateReply())
      _ = try await connect(excessReply)
      try await waitMemoryState { excessReply.withLockedValue { $0.closed } }
      try #require(excessReply.withLockedValue { $0.wire.isEmpty && !$0.overflow })
      for _ in 0..<3 {
        try await Task.sleep(for: .milliseconds(100))
        samples.append(["round": UInt64(round), "resident_bytes": try residentBytes()])
      }
      for channel in channels { try await channel.writeAndFlush(malformed).get() }
      let observedReplies = replies
      try await waitMemoryState { observedReplies.allSatisfy { $0.withLockedValue { $0.closed } } }
      for reply in replies {
        let value = reply.withLockedValue { $0 }
        try #require(!value.overflow && value.wire.hasPrefix("HTTP/1.1 431 "))
        try #require(value.wire.components(separatedBy: "HTTP/1.1").count == 2)
      }
      try #require(forwarded.withLockedValue { $0 } == 0)
      samples.append(["round": UInt64(round), "resident_bytes": try residentBytes()])
    }
    let peak = max(baseline, samples.map { $0["resident_bytes"]! }.max()!)
    let firstPeak = samples.filter { $0["round"] == 0 }.map { $0["resident_bytes"]! }.max()!
    let laterGrowth = peak > firstPeak ? peak - firstPeak : 0
    try writeMemoryObservation([
      "rounds": rounds, "connections_per_round": Limits.connections,
      "partial_bytes_per_connection": partial.readableBytes, "baseline_rss": baseline,
      "peak_rss": peak, "growth_rss": peak - baseline, "growth_after_first_round": laterGrowth,
      "samples": samples, "refusals": rounds * Limits.connections,
      "excess_closed": rounds, "forwarded_parts": forwarded.withLockedValue { $0 },
    ])
    try #require(peak - baseline < 96 * 1024 * 1024, "aggregate header RSS exceeded its budget")
    try #require(
      laterGrowth < 32 * 1024 * 1024, "repeated malformed clients retained excessive memory")
  } catch {
    try? await server.close().get()
    await guests.closeAll()
    await peers.closeAll()
    try await group.shutdownGracefully()
    throw error
  }
  try await server.close().get()
  await guests.closeAll()
  await peers.closeAll()
  try await group.shutdownGracefully()
}
