import AsyncHTTPClient
import IsoProxyCore
import NIOCore
import NIOHTTP1

/// Reads at most one 16 KiB socket batch ahead of upstream consumption. The
/// StreamWriter future gates upload reads; ResponseRelay gates response reads
/// on guest write completion. Neither direction accumulates the whole body.
final class StreamingBridge: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  private let config: ProxyConfig
  typealias Execute =
    @Sendable (HTTPClient.Request, ResponseRelay, EventLoop) -> OwnedHTTPRequest
  private let execute: Execute
  private var upload: UploadStream?
  private var task: OwnedHTTPRequest?
  private var relay: ResponseRelay?
  private var establishment: Scheduled<Void>?
  private var readOutstanding = false
  private var requestEnded = false
  private var stopped = false

  init(config: ProxyConfig, upstream: UpstreamClient) {
    self.config = config
    self.execute = { request, relay, loop in
      upstream.execute(request: request, relay: relay, eventLoop: loop)
    }
  }

  // Internal dependency injection for the controlled upstream harness. No
  // startup schema or public launcher accepts an alternate destination.
  init(config: ProxyConfig, execute: @escaping Execute) {
    self.config = config
    self.execute = execute
  }

  func channelActive(context: ChannelHandlerContext) {
    readIfReady(context)
    context.fireChannelActive()
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !stopped else { return }
    do {
      switch unwrapInboundIn(data) {
      case .head(let head):
        guard task == nil else { return stop(context) }
        let upload = UploadStream(eventLoop: context.eventLoop)
        self.upload = upload
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        upload.readyForMore = {
          let (bridge, context) = bound.value
          bridge.readIfReady(context)
        }
        let relay = ResponseRelay(
          context: context,
          established: {
            bound.value.0.establishment?.cancel()
            bound.value.0.establishment = nil
          },
          ended: {
            let bridge = bound.value.0
            bridge.establishment?.cancel()
            bridge.establishment = nil
            bridge.upload?.cancel()
          })
        self.relay = relay
        let length = head.headers.first(name: "content-length").flatMap(Int.init)
        let request = try UpstreamClient.request(
          head: head, config: config, body: upload.body(length: length))
        task = execute(request, relay, context.eventLoop)
        guard !stopped else {
          task?.cancel()
          task = nil
          return
        }
        establishment = context.eventLoop.scheduleTask(
          in: .seconds(Int64(Limits.establishmentSeconds))
        ) {
          let bridge = bound.value.0
          bridge.relay?.fail()
          bridge.task?.cancel()
        }
      case .body(let buffer): try upload?.receive(buffer)
      case .end:
        requestEnded = true
        upload?.end()
      }
    } catch { stop(context) }
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    readOutstanding = false
    readIfReady(context)
    context.fireChannelReadComplete()
  }

  private func readIfReady(_ context: ChannelHandlerContext) {
    guard !stopped, !readOutstanding else { return }
    if upload == nil || upload?.canRead == true || requestEnded {
      readOutstanding = true
      context.read()
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    stopped = true
    establishment?.cancel()
    establishment = nil
    upload?.cancel()
    relay?.fail()
    task?.cancel()
    task = nil
    relay = nil
    upload = nil
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) { stop(context) }

  private func stop(_ context: ChannelHandlerContext) {
    stopped = true
    upload?.cancel()
    if let relay {
      relay.fail()  // closes after the local error response flushes
    } else {
      context.close(promise: nil)
    }
    task?.cancel()
  }
}
