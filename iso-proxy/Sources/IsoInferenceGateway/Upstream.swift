import IsoInferenceCore
import NIOCore
import NIOHTTP1
import NIOPosix

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
  /// The backend could not be reached; nothing was sent.
  func upstreamUnavailable()
}

/// One HTTP/1.1 request to a fixed loopback backend port. The destination
/// never comes from guest input: only the port of a registered backend. No
/// proxy environment, redirects or decompression apply. Reads are driven by
/// the delegate so a slow guest applies backpressure to the backend.
final class UpstreamCall {
  private var channel: Channel?
  private var closedLocally = false
  fileprivate var finished = false
  fileprivate weak var delegate: UpstreamDelegate?
  private let eventLoop: EventLoop

  init(eventLoop: EventLoop, delegate: UpstreamDelegate) {
    self.eventLoop = eventLoop
    self.delegate = delegate
  }

  func start(port: UInt16, head: HTTPRequestHead, body: [UInt8]) {
    let bound = NIOLoopBound(self, eventLoop: eventLoop)
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
          var buffer = channel.allocator.buffer(capacity: body.count)
          buffer.writeBytes(body)
          channel.write(HTTPClientRequestPart.head(head), promise: nil)
          channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
          channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
          channel.read()
        case .failure:
          guard !call.finished else { return }
          call.finished = true
          call.delegate?.upstreamUnavailable()
        }
      }
  }

  func read() { channel?.read() }

  /// Close the upstream connection (stream-close evidence, or abandoning).
  func close() {
    closedLocally = true
    channel?.close(promise: nil)
  }

  fileprivate func deliverHead(_ head: HTTPResponseHead) { delegate?.upstreamHead(head) }
  fileprivate func deliverBody(_ buffer: ByteBuffer) { delegate?.upstreamBody(buffer) }
  fileprivate func deliverReadComplete() {
    guard !finished else { return }
    delegate?.upstreamReadComplete()
  }
  fileprivate func deliverEnd() {
    guard !finished else { return }
    finished = true
    delegate?.upstreamEnd()
    channel?.close(promise: nil)
  }
  fileprivate func deliverClosed() {
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
    case .head(let head):
      // Interim responses carry nothing a guest needs.
      guard head.status.code >= 200 else { return }
      owner.deliverHead(head)
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
