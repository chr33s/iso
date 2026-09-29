import Foundation
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import IsoProxyTransport

@Test func ownedTLSCancelsStalledHandshakePromptly() async throws {
  for provider in Provider.allCases {
    try await withTLSFixture { group, port, received, closed in
      let connection = try CancellableTLSConnection(
        host: "127.0.0.1", port: port, serverHostname: provider.hostname,
        configuration: UpstreamClient.tlsConfiguration(), eventLoop: group.next())
      try await waitForTLSObservation(received)
      connection.cancel()
      connection.cancel()
      do {
        _ = try await connection.established.get()
        Issue.record("cancelled handshake succeeded")
      } catch {
        #expect(error as? CancellableTLSConnection.Failure == .cancelled)
      }
      try await waitForTLSObservation(closed)
    }
  }
}

@Test func ownedTLSDeadlineClosesStalledHandshake() async throws {
  try await withTLSFixture { group, port, received, closed in
    let connection = try CancellableTLSConnection(
      host: "127.0.0.1", port: port, serverHostname: Provider.anthropic.hostname,
      configuration: UpstreamClient.tlsConfiguration(), eventLoop: group.next(),
      timeout: .milliseconds(250))
    try await waitForTLSObservation(received)
    do {
      _ = try await connection.established.get()
      Issue.record("stalled handshake succeeded")
    } catch {
      #expect(error as? CancellableTLSConnection.Failure == .establishmentTimeout)
    }
    try await waitForTLSObservation(closed)
  }
}

@Test func ownedTLSVerifiesProviderAndCancelsEstablishedSocket() async throws {
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
  for provider in Provider.allCases {
    try await withTLSFixture(tls: tls) { group, port, _, closed in
      var configuration = UpstreamClient.tlsConfiguration()
      configuration.additionalTrustRoots = [.certificates([ca])]
      let connection = try CancellableTLSConnection(
        host: "127.0.0.1", port: port, serverHostname: provider.hostname,
        configuration: configuration, eventLoop: group.next(), timeout: .seconds(1))
      let channel = try await connection.established.get()
      #expect(channel.isActive)
      try await Task.sleep(for: .milliseconds(1100))
      #expect(channel.isActive, "establishment deadline must stop after TLS succeeds")
      connection.cancel()
      try await waitForTLSObservation(closed)
      #expect(!channel.isActive)
    }
  }
  for trusted in [false, true] {
    try await withTLSFixture(tls: tls) { group, port, received, closed in
      var configuration = UpstreamClient.tlsConfiguration()
      if trusted { configuration.additionalTrustRoots = [.certificates([ca])] }
      let connection = try CancellableTLSConnection(
        host: "127.0.0.1", port: port,
        serverHostname: trusted ? "wrong-host.invalid" : Provider.anthropic.hostname,
        configuration: configuration, eventLoop: group.next())
      do {
        _ = try await connection.established.get()
        Issue.record("untrusted certificate or wrong hostname accepted")
      } catch {}
      try await waitForTLSObservation(closed)
      #expect(!received.withLockedValue { $0 }, "no plaintext reaches unverified peer")
    }
  }
}

@Test func ownedTLSRejectsLateDNSCandidatesAfterCancellation() async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let accepted = NIOLockedValueBox(0)
  let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    accepted.withLockedValue { $0 += 1 }
    return channel.close()
  }.bind(host: "127.0.0.1", port: 0).get()
  let loop = group.next()
  let resolver = DeferredTLSResolver(loop: loop)
  let port = try #require(server.localAddress?.port)
  let connection = try CancellableTLSConnection(
    host: "deferred.invalid", port: port, serverHostname: Provider.anthropic.hostname,
    configuration: UpstreamClient.tlsConfiguration(), eventLoop: loop, resolver: resolver)
  connection.cancel()
  do {
    _ = try await connection.established.get()
    Issue.record("cancelled DNS establishment succeeded")
  } catch {
    #expect(error as? CancellableTLSConnection.Failure == .cancelled)
  }
  resolver.ipv6.succeed([])
  resolver.ipv4.succeed([try SocketAddress(ipAddress: "127.0.0.1", port: port)])
  // Allow the completed DNS futures and Happy Eyeballs candidate to run.
  try await Task.sleep(for: .seconds(1))
  #expect(resolver.queries.withLockedValue { $0 } == 2)
  #expect(accepted.withLockedValue { $0 } == 0, "no TCP connect after cancellation")
  try await server.close().get()
  try await group.shutdownGracefully()
}

private final class DeferredTLSResolver: Resolver, Sendable {
  let ipv4: EventLoopPromise<[SocketAddress]>
  let ipv6: EventLoopPromise<[SocketAddress]>
  let queries = NIOLockedValueBox(0)
  init(loop: EventLoop) {
    ipv4 = loop.makePromise()
    ipv6 = loop.makePromise()
  }
  func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
    queries.withLockedValue { $0 += 1 }
    return ipv4.futureResult
  }
  func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
    queries.withLockedValue { $0 += 1 }
    return ipv6.futureResult
  }
  func cancelQueries() {}
}

private func waitForTLSObservation(_ value: NIOLockedValueBox<Bool>) async throws {
  let deadline = ContinuousClock.now + .seconds(2)
  while !value.withLockedValue({ $0 }) && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  try #require(value.withLockedValue { $0 }, "socket observation exceeded two seconds")
}

private func withTLSFixture(
  tls: NIOSSLContext? = nil,
  body: (MultiThreadedEventLoopGroup, Int, NIOLockedValueBox<Bool>, NIOLockedValueBox<Bool>)
    async throws -> Void
) async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let received = NIOLockedValueBox(false)
  let closed = NIOLockedValueBox(false)
  let server = try await ServerBootstrap(group: group).childChannelInitializer { channel in
    channel.eventLoop.makeCompletedFuture {
      if let tls {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
      }
      try channel.pipeline.syncOperations.addHandler(
        TLSFixtureObserver(received: received, closed: closed))
    }
  }.bind(host: "127.0.0.1", port: 0).get()
  do {
    try await body(group, #require(server.localAddress?.port), received, closed)
    try await server.close().get()
    try await group.shutdownGracefully()
  } catch {
    try? await server.close().get()
    try await group.shutdownGracefully()
    throw error
  }
}

private final class TLSFixtureObserver: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let received: NIOLockedValueBox<Bool>
  let closed: NIOLockedValueBox<Bool>
  init(received: NIOLockedValueBox<Bool>, closed: NIOLockedValueBox<Bool>) {
    self.received = received
    self.closed = closed
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    received.withLockedValue { $0 = true }
  }
  func channelInactive(context: ChannelHandlerContext) {
    closed.withLockedValue { $0 = true }
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

@Test func cancelledSocketKeepsAdmissionUntilDelayedCloseCompletes() async throws {
  try await withTLSFixture { group, port, received, closed in
    let capacity = Capacity(1)
    let captured = NIOLockedValueBox<(any Channel)?>(nil)
    let connection = try CancellableTLSConnection(
      host: "127.0.0.1", port: port, serverHostname: Provider.anthropic.hostname,
      configuration: UpstreamClient.tlsConfiguration(), eventLoop: group.next(),
      socketCapacity: capacity,
      application: { channel in
        captured.withLockedValue { $0 = channel }
      })
    try await waitForTLSObservation(received)
    let channel = try #require(captured.withLockedValue { $0 })
    let closing = NIOLockedValueBox(false)
    let blocker = try await channel.eventLoop.submit {
      let handler = DelayedSocketClose(closing)
      // Before TLS, so the transport-level cancellation close reaches it.
      try channel.pipeline.syncOperations.addHandler(handler, position: .first)
      return NIOLoopBound(handler, eventLoop: channel.eventLoop)
    }.get()
    do {
      connection.cancel()
      do {
        _ = try await connection.established.get()
        Issue.record("cancelled handshake succeeded")
      } catch {
        #expect(error as? CancellableTLSConnection.Failure == .cancelled)
      }
      try await waitForTLSObservation(closing)
      #expect(channel.isActive)
      #expect(capacity.acquire() == nil, "cancellation must not release a still-open socket's slot")
      try await blocker.eventLoop.submit { blocker.value.release() }.get()
      try await channel.closeFuture.get()
      let recovered = capacity.acquire()
      #expect(recovered != nil)
      recovered?.release()
      try await waitForTLSObservation(closed)
    } catch {
      try? await blocker.eventLoop.submit { blocker.value.release() }.get()
      throw error
    }
  }
}

private final class DelayedSocketClose: ChannelOutboundHandler {
  typealias OutboundIn = ByteBuffer
  private let closing: NIOLockedValueBox<Bool>
  private var pending: [(ChannelHandlerContext, CloseMode, EventLoopPromise<Void>?)] = []
  private var released = false
  init(_ closing: NIOLockedValueBox<Bool>) { self.closing = closing }
  func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
    if released {
      context.close(mode: mode, promise: promise)
    } else {
      pending.append((context, mode, promise))
      closing.withLockedValue { $0 = true }
    }
  }
  func release() {
    released = true
    let closes = pending
    pending.removeAll()
    for (context, mode, promise) in closes { context.close(mode: mode, promise: promise) }
  }
}
