import IsoProxyCore
import NIOCore
import NIOHTTP1

/// Callbacks run on the guest event loop. Flush futures propagate
/// guest backpressure to the provider; no response-body aggregation occurs.
final class ResponseRelay: Sendable {
  private let state: NIOLoopBound<State>
  final class State {
    let context: ChannelHandlerContext
    var started = false
    var finished = false
    var established: (() -> Void)?
    var ended: (() -> Void)?
    init(context: ChannelHandlerContext) { self.context = context }
  }
  init(
    context: ChannelHandlerContext, established: @escaping () -> Void, ended: @escaping () -> Void
  ) {
    let value = State(context: context)
    value.established = established
    value.ended = ended
    state = NIOLoopBound(value, eventLoop: context.eventLoop)
  }

  func requestHeadSent() {
    state.value.established?()
    state.value.established = nil
  }

  func receiveHead(_ head: HTTPResponseHead) -> EventLoopFuture<Void> {
    let value = state.value
    do {
      var head = head
      let filtered = try HeaderPolicy.response(head.headers.map { Header($0.name, $0.value) })
      head.headers = HTTPHeaders(filtered.map { ($0.name, $0.value) })
      // One response per guest connection simplifies cancellation and avoids
      // reusing a connection whose upstream rejected an unfinished upload.
      head.headers.replaceOrAdd(name: "connection", value: "close")
      value.started = true
      return value.context.writeAndFlush(NIOAny(HTTPServerResponsePart.head(head)))
    } catch { return value.context.eventLoop.makeFailedFuture(PolicyError.invalidHeader) }
  }

  func receiveBody(_ buffer: ByteBuffer) -> EventLoopFuture<Void> {
    state.value.context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))))
  }

  func finish() {
    let value = state.value
    guard !value.finished else { return }
    value.finished = true
    value.ended?()
    value.ended = nil
    value.established = nil
    let channel = value.context.channel
    value.context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }

  func fail() {
    let value = state.value
    guard !value.finished else { return }
    value.finished = true
    value.ended?()
    value.ended = nil
    value.established = nil
    let channel = value.context.channel
    guard channel.isActive else { return }
    if value.started {
      channel.close(promise: nil)
      return
    }
    let head = HTTPResponseHead(
      version: .http1_1, status: .badGateway,
      headers: HTTPHeaders([("content-length", "0"), ("connection", "close")]))
    value.context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
    value.context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }
}
