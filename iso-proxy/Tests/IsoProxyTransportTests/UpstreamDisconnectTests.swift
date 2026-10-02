import AsyncHTTPClient
import Foundation
import IsoProxyCore
import IsoProxyTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import IsoProxyTransport

private enum DisconnectPhase: String, CaseIterable { case beforeHeaders, duringBody }
private enum DisconnectTransport: String, CaseIterable { case abruptTCP, cleanTLS }

@Test func upstreamDisconnectClosesGuestAndRestoresPermits() async throws {
  var observations: [[String: Any]] = []
  for provider in Provider.allCases {
    for phase in DisconnectPhase.allCases {
      for transport in DisconnectTransport.allCases {
        observations += try await exerciseUpstreamDisconnect(
          provider: provider, phase: phase, transport: transport)
      }
    }
  }
  try recordEvidence(observations, name: "disconnect", validate: ObservationContracts.disconnect)
  if let path = ProcessInfo.processInfo.environment["ISO_DISCONNECT_OBSERVATIONS"] {
    try JSONSerialization.data(
      withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

private func exerciseUpstreamDisconnect(
  provider: Provider, phase: DisconnectPhase, transport: DisconnectTransport
) async throws -> [[String: Any]] {
  var observations: [[String: Any]] = []
  let tls = try verifiedTLSFixture()
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let upstreamPeers = ConnectionRegistry()
  let proxyPeers = ConnectionRegistry()
  let guests = ConnectionRegistry()
  let admitted = NIOLockedValueBox<(any Channel)?>(nil)
  let connections = Capacity(1)
  let requests = Capacity(1)
  let path = provider == .anthropic ? "/v1/messages" : "/v1/responses"
  let token = String(repeating: "a", count: 64)
  let secret = "upstream-disconnect-test-only"
  let config = try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "listen": "127.0.0.1:0", "provider": provider.rawValue,
      "capability_token": token,
      "injection": [
        "scheme": provider == .anthropic ? "x_api_key" : "bearer", "credential": secret,
      ],
    ]))
  let upstream = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    upstreamPeers.add(channel)
    return channel.eventLoop.makeCompletedFuture {
      try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls.server))
    }.flatMap { channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false) }
      .flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            DisconnectingProvider(phase: phase, admitted: admitted))
        }
      }
  }.bind(host: "127.0.0.1", port: 0).get()
  let upstreamPort = try #require(upstream.localAddress?.port)
  // The production parser/gate/bridge with one slot makes any lost lease fail
  // the next request; a large default pool would conceal a small leak.
  let proxy = try await ServerBootstrap(group: group)
    .childChannelOption(
      ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16 * 1024)
    )
    .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
    .childChannelInitializer { channel in
      proxyPeers.add(channel)
      return channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try InboundPipeline.configure(
            channel: channel, config: config, connections: connections, requests: requests)
          try channel.pipeline.syncOperations.addHandler(
            StreamingBridge(config: config) { request, relay, loop in
              let local = try! HTTPClient.Request(
                url: "https://\(provider.hostname):\(upstreamPort)\(path)", method: request.method,
                headers: request.headers, body: request.body)
              return OwnedHTTPRequest(
                request: local, relay: relay, eventLoop: loop,
                tlsConfiguration: tls.client, connectHost: "127.0.0.1")
            })
        }
      }
    }.bind(host: "127.0.0.1", port: 0).get()
  do {
    for round in 0..<2 {
      admitted.withLockedValue { $0 = nil }
      let observed = NIOLockedValueBox(DisconnectedGuest())
      let guest = try await ClientBootstrap(group: group).channelInitializer { channel in
        guests.add(channel)
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(DisconnectGuestCapture(observed))
        }
      }.connect(host: "127.0.0.1", port: #require(proxy.localAddress?.port)).get()
      try await guest.writeAndFlush(
        ByteBuffer(
          string:
            "POST \(path) HTTP/1.1\r\nHost: ignored\r\nAuthorization: Bearer \(token)\r\nContent-Length: 0\r\n\r\n"
        )
      ).get()
      try await waitForDisconnectState { admitted.withLockedValue { $0 != nil } }
      if phase == .duringBody {
        try await waitForDisconnectState {
          observed.withLockedValue { $0.wire.hasSuffix("\r\n\r\npart") }
        }
      }
      let peer = try #require(admitted.withLockedValue { $0 })
      // In both modes the guest keeps its write side open. The provider omits
      // the remaining HTTP body, regardless of whether TLS closes cleanly.
      try await peer.eventLoop.submit {
        switch transport {
        case .abruptTCP:
          let tls = try peer.pipeline.syncOperations.context(handlerType: NIOSSLServerHandler.self)
          tls.close(promise: nil)
        case .cleanTLS:
          peer.close(promise: nil)
        }
      }.get()
      try await waitForDisconnectState { observed.withLockedValue { $0.closed } }
      let wire = observed.withLockedValue { $0.wire }
      #expect(
        wire.components(separatedBy: "HTTP/1.1").count == 2, "exactly one response status line")
      switch phase {
      case .beforeHeaders:
        #expect(wire.hasPrefix("HTTP/1.1 502 "))
        #expect(wire.hasSuffix("\r\n\r\n"))
      case .duringBody:
        #expect(wire.hasPrefix("HTTP/1.1 200 "))
        #expect(wire.lowercased().contains("content-length: 8\r\n"))
        #expect(
          wire.hasSuffix("\r\n\r\npart"), "partial body is not completed or replaced with an error")
      }
      #expect(!wire.contains(secret))
      #expect(!wire.contains(token))
      let connectionLease = try #require(connections.acquire(), "connection capacity recovered")
      let requestLease = try #require(requests.acquire(), "request capacity recovered")
      connectionLease.release()
      requestLease.release()
      let sections = wire.components(separatedBy: "\r\n\r\n")
      let status = try #require(Int(wire.split(separator: " ")[1]))
      observations.append([
        "id": "\(provider.rawValue)-\(phase.rawValue)-\(transport.rawValue)-\(round)",
        "response_status": status,
        "response_body": sections.dropFirst().joined(separator: "\r\n\r\n"),
        "connection_closed": observed.withLockedValue { $0.closed },
        "connection_slots": 1, "request_slots": 1,
      ])
    }
    try await proxy.close().get()
    try await upstream.close().get()
    await guests.closeAll()
    await proxyPeers.closeAll()
    await upstreamPeers.closeAll()
    try await group.shutdownGracefully()
    return observations
  } catch {
    try? await proxy.close().get()
    try? await upstream.close().get()
    await guests.closeAll()
    await proxyPeers.closeAll()
    await upstreamPeers.closeAll()
    try await group.shutdownGracefully()
    throw error
  }
}

private func waitForDisconnectState(_ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(2)
  while !condition() && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(1))
  }
  try #require(condition(), "disconnect observation exceeded two seconds")
}

private final class DisconnectingProvider: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  let phase: DisconnectPhase
  let admitted: NIOLockedValueBox<(any Channel)?>
  init(phase: DisconnectPhase, admitted: NIOLockedValueBox<(any Channel)?>) {
    self.phase = phase
    self.admitted = admitted
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard case .end = unwrapInboundIn(data) else { return }
    admitted.withLockedValue { $0 = context.channel }
    if phase == .duringBody {
      context.write(
        NIOAny(
          HTTPServerResponsePart.head(
            HTTPResponseHead(
              version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "8")])
            ))), promise: nil)
      context.writeAndFlush(
        NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(string: "part")))), promise: nil)
    }
  }
}

private struct DisconnectedGuest {
  var wire = ""
  var closed = false
}
private final class DisconnectGuestCapture: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let observed: NIOLockedValueBox<DisconnectedGuest>
  init(_ observed: NIOLockedValueBox<DisconnectedGuest>) { self.observed = observed }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let text = String(buffer: unwrapInboundIn(data))
    observed.withLockedValue { $0.wire += text }
  }
  func channelInactive(context: ChannelHandlerContext) {
    observed.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
}
