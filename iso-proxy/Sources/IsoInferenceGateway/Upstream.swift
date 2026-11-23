import IsoInferenceCore
import NIOCore
import NIOHTTP1
import NIOPosix

/// Why a call ended before its request was sent.
enum UpstreamRefusal: Sendable, Equatable {
  /// Nothing accepted the connection.
  case unreachable
  /// The listener did not prove it holds the launcher backend's token
  /// (§20.3): a wrong or missing answer, a closed connection or a timeout.
  case unproven
}

/// Receives one backend response, on the guest connection's event loop.
protocol UpstreamDelegate: AnyObject {
  func upstreamHead(_ head: HTTPResponseHead)
  func upstreamBody(_ buffer: ByteBuffer)
  func upstreamEnd()
  /// A socket read was fully delivered; call `read()` for more.
  func upstreamReadComplete()
  /// The connection ended without a complete response. `local` is true
  /// when the gateway closed it.
  func upstreamClosed(local: Bool)
  /// The request was never sent: no header or body of it reached the port.
  func upstreamUnavailable(_ refusal: UpstreamRefusal)
}

/// One HTTP/1.1 request to a fixed loopback backend port. The destination
/// never comes from guest input: only the port of a registered backend. No
/// proxy environment, redirects or decompression apply. Reads are driven by
/// the delegate so a slow guest applies backpressure to the backend.
///
/// With a ``LauncherChallenge`` the connection carries the challenge first,
/// with no credential, and the request (whose headers hold the credential)
/// is written only after the answer matches (§20.3).
final class UpstreamCall {
  private enum Stage {
    case connecting
    /// The challenge is out; its answer is collected here.
    case proving(LauncherChallenge, status: HTTPResponseStatus?, answer: [UInt8])
    /// The request was written.
    case dispatched
  }

  private var channel: Channel?
  private var closedLocally = false
  fileprivate var finished = false
  fileprivate weak var delegate: UpstreamDelegate?
  private let eventLoop: EventLoop
  private let proofTimeout: Duration
  private var stage = Stage.connecting
  private var proofDeadline: Scheduled<Void>?
  private var request: (head: HTTPRequestHead, body: [UInt8])?

  init(
    eventLoop: EventLoop, delegate: UpstreamDelegate,
    proofTimeout: Duration = .seconds(SessionLimits.backendProofSeconds)
  ) {
    self.eventLoop = eventLoop
    self.delegate = delegate
    self.proofTimeout = proofTimeout
  }

  /// Whether the request was written: before that, closing the call is not
  /// a cancellation the backend could have seen.
  var dispatched: Bool {
    if case .dispatched = stage { true } else { false }
  }

  func start(
    port: UInt16, head: HTTPRequestHead, body: [UInt8], challenge: LauncherChallenge? = nil
  ) {
    let bound = NIOLoopBound(self, eventLoop: eventLoop)
    request = (head, body)
    ClientBootstrap(group: eventLoop)
      .connectTimeout(.seconds(10))
      .channelOption(ChannelOptions.autoRead, value: false)
      .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandlers([
            HTTPRequestEncoder(),
            ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)),
            UpstreamHandler(owner: bound.value),
          ])
        }
      }
      .connect(host: "127.0.0.1", port: Int(port))
      .whenComplete { result in
        let call = bound.value
        switch result {
        case .success(let channel):
          guard !call.closedLocally else {
            channel.close(promise: nil)
            return
          }
          call.channel = channel
          if let challenge {
            call.prove(challenge, port: port, on: channel)
          } else {
            call.dispatch(on: channel)
          }
        case .failure:
          guard !call.finished else { return }
          call.finished = true
          call.delegate?.upstreamUnavailable(.unreachable)
        }
      }
  }

  private func prove(_ challenge: LauncherChallenge, port: UInt16, on channel: Channel) {
    stage = .proving(challenge, status: nil, answer: [])
    let headers = HTTPHeaders([
      ("host", BackendID(port: port).description), ("connection", "keep-alive"),
      ("accept-encoding", "identity"),
    ])
    channel.write(
      HTTPClientRequestPart.head(
        HTTPRequestHead(version: .http1_1, method: .GET, uri: challenge.path, headers: headers)),
      promise: nil)
    channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
    let bound = NIOLoopBound(self, eventLoop: eventLoop)
    proofDeadline = eventLoop.scheduleTask(in: TimeAmount(proofTimeout)) {
      bound.value.refuse(.unproven)
    }
    channel.read()
  }

  private func dispatch(on channel: Channel) {
    guard let request else { return }
    self.request = nil
    stage = .dispatched
    var buffer = channel.allocator.buffer(capacity: request.body.count)
    buffer.writeBytes(request.body)
    channel.write(HTTPClientRequestPart.head(request.head), promise: nil)
    channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
    channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
    channel.read()
  }

  /// End the call without sending its request.
  private func refuse(_ refusal: UpstreamRefusal) {
    proofDeadline?.cancel()
    request = nil
    guard !finished else { return }
    finished = true
    closedLocally = true
    channel?.close(promise: nil)
    delegate?.upstreamUnavailable(refusal)
  }

  func read() {
    guard dispatched else { return }
    channel?.read()
  }

  /// Close the upstream connection (stream-close evidence, or abandoning).
  func close() {
    proofDeadline?.cancel()
    request = nil
    closedLocally = true
    channel?.close(promise: nil)
  }

  fileprivate func deliverHead(_ head: HTTPResponseHead) {
    switch stage {
    case .proving(let challenge, _, let answer):
      stage = .proving(challenge, status: head.status, answer: answer)
    case .dispatched:
      // Interim responses carry nothing a guest needs.
      guard head.status.code >= 200 else { return }
      delegate?.upstreamHead(head)
    case .connecting: break
    }
  }

  fileprivate func deliverBody(_ buffer: ByteBuffer) {
    switch stage {
    case .proving(let challenge, let status, var answer):
      // An answer longer than a digest is wrong; keep only enough to say so.
      answer += buffer.readableBytesView.prefix(128 - min(128, answer.count))
      stage = .proving(challenge, status: status, answer: answer)
    case .dispatched: delegate?.upstreamBody(buffer)
    case .connecting: break
    }
  }

  fileprivate func deliverEnd() {
    switch stage {
    case .proving(let challenge, let status, let answer):
      // Interim (1xx) responses end too; only the final one is the answer.
      guard let status, status.code >= 200 else { return }
      guard status == .ok, challenge.accepts(answer), let channel else {
        return refuse(.unproven)
      }
      proofDeadline?.cancel()
      dispatch(on: channel)
    case .dispatched:
      guard !finished else { return }
      finished = true
      delegate?.upstreamEnd()
      channel?.close(promise: nil)
    case .connecting: break
    }
  }

  fileprivate func deliverReadComplete() {
    guard !finished else { return }
    switch stage {
    case .proving: channel?.read()
    case .dispatched: delegate?.upstreamReadComplete()
    case .connecting: break
    }
  }

  fileprivate func deliverClosed() {
    // Closed during the proof: the request was never sent.
    if case .proving = stage { return refuse(.unproven) }
    guard !finished else { return }
    finished = true
    delegate?.upstreamClosed(local: closedLocally)
  }
}

private final class UpstreamHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPClientResponsePart
  private let owner: UpstreamCall

  init(owner: UpstreamCall) { self.owner = owner }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head): owner.deliverHead(head)
    case .body(let buffer): owner.deliverBody(buffer)
    case .end: owner.deliverEnd()
    }
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    owner.deliverReadComplete()
    context.fireChannelReadComplete()
  }

  func channelInactive(context: ChannelHandlerContext) {
    owner.deliverClosed()
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    context.close(promise: nil)
  }
}
