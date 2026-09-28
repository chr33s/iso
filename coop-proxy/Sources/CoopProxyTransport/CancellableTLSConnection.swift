import CoopProxyCore
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS

/// Owns socket candidates before TCP connect, including while TLS is stalled.
/// Cancellation also rejects candidates created after an outstanding DNS lookup.
final class CancellableTLSConnection: Sendable {
  enum Failure: Error {
    case cancelled, establishmentTimeout, closedBeforeHandshake, capacityExceeded
  }
  private enum Phase { case connecting, ready, closed }
  private struct State {
    var phase = Phase.connecting
    var channels: [ObjectIdentifier: Channel] = [:]
    var deadline: Scheduled<Void>?
  }
  private let state = NIOLockedValueBox(State())
  private let completion: EventLoopPromise<Channel>
  private let resolver: (Resolver & Sendable)?
  private let socketCapacity: Capacity?
  var established: EventLoopFuture<Channel> { completion.futureResult }

  convenience init(provider: Provider, eventLoop: EventLoop) throws {
    try self.init(
      host: provider.hostname, port: 443, serverHostname: provider.hostname,
      configuration: UpstreamClient.tlsConfiguration(), eventLoop: eventLoop)
  }

  // Internal fixture seam. Startup configuration cannot select these values.
  init(
    host: String, port: Int, serverHostname: String, configuration: TLSConfiguration,
    eventLoop: EventLoop, timeout: TimeAmount = .seconds(Int64(Limits.establishmentSeconds)),
    resolver: (Resolver & Sendable)? = nil, socketCapacity: Capacity? = nil,
    application: @escaping @Sendable (Channel) throws -> Void = { _ in }
  ) throws {
    self.resolver = resolver
    self.socketCapacity = socketCapacity
    let tls = try NIOSSLContext(configuration: configuration)
    completion = eventLoop.makePromise(of: Channel.self)
    let deadline = eventLoop.scheduleTask(in: timeout) { [weak self] () -> Void in
      self?.fail(Failure.establishmentTimeout)
    }
    let retained = state.withLockedValue { state in
      guard state.phase == .connecting else { return false }
      state.deadline = deadline
      return true
    }
    if !retained { deadline.cancel() }
    ClientBootstrap(group: eventLoop)
      .resolver(resolver)
      .connectTimeout(timeout)
      .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
      .channelOption(
        ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16 * 1024)
      )
      .channelOption(ChannelOptions.maxMessagesPerRead, value: 1)
      .channelInitializer { [self] channel in
        if let failure = register(channel) {
          return channel.eventLoop.makeFailedFuture(failure)
        }
        return channel.eventLoop.makeSucceededVoidFuture()
      }
      .connect(host: host, port: port).whenComplete { [self] result in
        switch result {
        case .failure(let error): fail(error)
        case .success(let channel):
          guard state.withLockedValue({ $0.phase == .connecting }) else {
            Self.closeImmediately(channel)
            return
          }
          do {
            // Install only on the TCP winner. A losing Happy Eyeballs candidate
            // closing must not fail the winning candidate's TLS handshake.
            let handler = try NIOSSLClientHandler(context: tls, serverHostname: serverHostname)
            // HTTP handlers must exist before TLS can emit decrypted bytes.
            try application(channel)
            try channel.pipeline.syncOperations.addHandler(
              TLSCompletion(owner: self), position: .first)
            try channel.pipeline.syncOperations.addHandler(handler, position: .first)
          } catch { fail(error) }
        }
      }
  }

  private func register(_ channel: Channel) -> Failure? {
    let lease: Capacity.Lease?
    if let socketCapacity {
      guard let admitted = socketCapacity.acquire() else {
        Self.closeImmediately(channel)
        return .capacityExceeded
      }
      lease = admitted
    } else {
      lease = nil
    }
    let id = ObjectIdentifier(channel)
    let accepted = state.withLockedValue { state in
      guard state.phase == .connecting else { return false }
      state.channels[id] = channel
      return true
    }
    // The close future owns admission independently of request cancellation.
    // Removing a channel from State must not make its slot reusable early.
    channel.closeFuture.whenComplete { [weak self, lease] _ in
      lease?.release()
      _ = self?.state.withLockedValue { $0.channels.removeValue(forKey: id) }
    }
    if !accepted {
      Self.closeImmediately(channel)
      return .cancelled
    }
    return nil
  }

  fileprivate func handshakeCompleted(_ channel: Channel) {
    let result = state.withLockedValue { state -> (Bool, Scheduled<Void>?) in
      guard state.phase == .connecting else { return (false, nil) }
      state.phase = .ready
      let deadline = state.deadline
      state.deadline = nil
      return (true, deadline)
    }
    result.1?.cancel()
    if result.0 { completion.succeed(channel) }
  }

  func cancel() { fail(Failure.cancelled) }

  fileprivate func fail(_ error: Error) {
    let result = state.withLockedValue { state -> (Bool, [Channel], Scheduled<Void>?) in
      let pending = state.phase == .connecting
      state.phase = .closed
      let channels = Array(state.channels.values)
      state.channels.removeAll()
      let deadline = state.deadline
      state.deadline = nil
      return (pending, channels, deadline)
    }
    resolver?.cancelQueries()
    result.2?.cancel()
    if result.0 { completion.fail(error) }
    for channel in result.1 { Self.closeImmediately(channel) }
  }

  private static func closeImmediately(_ channel: Channel) {
    channel.eventLoop.execute {
      // Cancellation must not wait for the peer's TLS close_notify. Starting
      // the outbound close before the TLS handler closes the underlying socket.
      if let tls = try? channel.pipeline.syncOperations.context(
        handlerType: NIOSSLClientHandler.self)
      {
        tls.close(promise: nil)
      } else {
        channel.close(promise: nil)
      }
    }
  }

  deinit { cancel() }
}

private final class TLSCompletion: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  private weak var owner: CancellableTLSConnection?
  init(owner: CancellableTLSConnection) { self.owner = owner }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if case .handshakeCompleted = event as? TLSUserEvent {
      owner?.handshakeCompleted(context.channel)
    }
    context.fireUserInboundEventTriggered(event)
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    owner?.fail(error)
    context.close(promise: nil)
  }

  func channelInactive(context: ChannelHandlerContext) {
    owner?.fail(CancellableTLSConnection.Failure.closedBeforeHandshake)
    context.fireChannelInactive()
  }
}
