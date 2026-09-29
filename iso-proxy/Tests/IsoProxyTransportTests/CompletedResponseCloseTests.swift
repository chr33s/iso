import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOSSL
import Testing

@testable import IsoProxyTransport

@Test(arguments: [false, true], [false, true])
func completedResponseDrainsAfterUpstreamClosesDuringGuestWrite(
  tlsError: Bool, guestWriteFails: Bool
) throws {
  let loop = EmbeddedEventLoop()
  let guest = EmbeddedChannel(loop: loop)
  let writer = PendingGuestBody()
  let anchor = GuestRelayAnchor()
  try guest.pipeline.syncOperations.addHandlers([writer, anchor])
  let context = try guest.pipeline.syncOperations.context(handler: anchor)
  let relay = ResponseRelay(context: context, established: {}, ended: {})
  let state = OwnedHTTPRequest.State(relay: relay, eventLoop: loop)
  state.completion.futureResult.whenFailure { _ in }
  let upstream = EmbeddedChannel(
    handler: OwnedResponseHandler(
      state: NIOLoopBound(state, eventLoop: loop),
      head: HTTPRequestHead(version: .http1_1, method: .POST, uri: "/v1/messages"), body: nil
    ), loop: loop)
  try upstream.writeInbound(
    HTTPClientResponsePart.head(
      HTTPResponseHead(
        version: .http1_1, status: .ok, headers: HTTPHeaders([("content-length", "2")])
      )))
  loop.run()
  try upstream.writeInbound(HTTPClientResponsePart.body(ByteBuffer(string: "ok")))
  try upstream.writeInbound(HTTPClientResponsePart.end(nil))
  let acknowledgment = try #require(writer.pending)
  if tlsError { upstream.pipeline.fireErrorCaught(NIOSSLError.uncleanShutdown) }
  try upstream.close().wait()
  #expect(!state.finished, "a complete queued response must wait for the guest acknowledgment")
  if guestWriteFails {
    acknowledgment.fail(ChannelError.ioOnClosedChannel)
  } else {
    acknowledgment.succeed(())
  }
  loop.run()
  var parts: [HTTPServerResponsePart] = []
  while let part = try guest.readOutbound(as: HTTPServerResponsePart.self) { parts.append(part) }
  #expect(
    parts.count == (guestWriteFails ? 2 : 3),
    "only a successful guest write may complete the queued response")
  if parts.count == 3 {
    guard case .head(let head) = parts[0], case .body(.byteBuffer(let body)) = parts[1],
      case .end = parts[2]
    else {
      Issue.record("response framing changed after peer close")
      return
    }
    #expect(head.status == .ok)
    #expect(String(buffer: body) == "ok")
  }
  #expect(state.finished)
  #expect(!guest.isActive)
  _ = try upstream.finish(acceptAlreadyClosed: true)
  _ = try guest.finish(acceptAlreadyClosed: true)
}

private final class GuestRelayAnchor: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
}

private final class PendingGuestBody: ChannelOutboundHandler {
  typealias OutboundIn = HTTPServerResponsePart
  var pending: EventLoopPromise<Void>?
  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    if case .body = unwrapOutboundIn(data) {
      pending = promise
      context.write(data, promise: nil)
    } else {
      context.write(data, promise: promise)
    }
  }
}
