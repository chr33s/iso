import CoopProxyCore
import NIOCore
import NIOHTTP1

/// Bounds whitespace and separators that the HTTP decoder excludes from its
/// metadata accounting. NIO alone determines when a request head is complete.
final class HeaderWireBudget: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias InboundOut = ByteBuffer

  private enum State {
    case headers(Int)
    case body, awaitingResponse, failed
  }
  private var state = State.headers(Limits.headerWireBytes)

  func headReceived() { state = .body }
  func requestEnded() { state = .awaitingResponse }
  func beginNextRequest() { state = .headers(Limits.headerWireBytes) }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)
    while buffer.readableBytes > 0 {
      switch state {
      case .failed:
        return
      case .awaitingResponse:
        state = .failed
        context.fireErrorCaught(HTTPParserError.invalidHeaderToken)
        return
      case .body:
        context.fireChannelRead(wrapInboundOut(buffer))
        return
      case .headers(let remaining):
        let count = min(remaining, buffer.readableBytes)
        guard let part = buffer.readSlice(length: count) else { return }
        state = .headers(remaining - count)
        context.fireChannelRead(wrapInboundOut(part))
        // Delivery is synchronous: a decoded head disables this budget before
        // any coalesced body bytes are delivered on the next iteration.
        if case .headers(0) = state {
          state = .failed
          context.fireErrorCaught(HTTPParserError.headerOverflow)
          return
        }
      }
    }
  }
}
