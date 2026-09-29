import AsyncHTTPClient
import Foundation
import IsoProxyCore
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOTLS

/// One HTTP/1 request with socket ownership from TCP connect through response
/// completion. AHC request/body values remain adapters for the transition; its
/// connection pool is not involved here.
final class OwnedHTTPRequest: Sendable {
  enum Failure: Error { case incompleteResponse }
  private let state: NIOLoopBound<State>
  let futureResult: EventLoopFuture<Void>

  init(rejected error: Error, relay: ResponseRelay, eventLoop: EventLoop) {
    let value = State(relay: relay, eventLoop: eventLoop)
    state = NIOLoopBound(value, eventLoop: eventLoop)
    futureResult = value.completion.futureResult
    value.fail(error)
  }

  init(
    request: HTTPClient.Request, relay: ResponseRelay, eventLoop: EventLoop,
    tlsConfiguration: TLSConfiguration = UpstreamClient.tlsConfiguration(),
    connectHost: String? = nil, resolver: (Resolver & Sendable)? = nil,
    socketCapacity: Capacity? = nil
  ) {
    let value = State(relay: relay, eventLoop: eventLoop)
    let bound = NIOLoopBound(value, eventLoop: eventLoop)
    state = bound
    futureResult = value.completion.futureResult
    do {
      guard request.useTLS,
        Provider.allCases.contains(where: { $0.hostname == request.host }),
        let url = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
      else { throw PolicyError.invalidTarget }
      let uri = url.percentEncodedPath + (url.percentEncodedQuery.map { "?" + $0 } ?? "")
      var headers = request.headers
      headers.remove(name: "content-length")
      headers.remove(name: "transfer-encoding")
      if let length = request.body?.contentLength {
        headers.add(name: "content-length", value: String(length))
      } else if request.body != nil {
        headers.add(name: "transfer-encoding", value: "chunked")
      } else {
        headers.add(name: "content-length", value: "0")
      }
      let head = HTTPRequestHead(
        version: .http1_1, method: request.method, uri: uri, headers: headers)
      value.connection = try CancellableTLSConnection(
        host: connectHost ?? request.host, port: request.port, serverHostname: request.host,
        configuration: tlsConfiguration, eventLoop: eventLoop, resolver: resolver,
        socketCapacity: socketCapacity,
        application: { channel in
          var limits = NIOHTTPDecoderLimitConfiguration()
          limits.maxHeaderFieldSize = Limits.headerFieldBytes
          limits.maxHeaderListSize = Limits.headerBlockBytes
          limits.maxHeaderFieldCount = Limits.headerCount
          try channel.pipeline.syncOperations.addHandlers([
            HTTPRequestEncoder(),
            ByteToMessageHandler(
              HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes, limitConfiguration: limits)),
            OwnedResponseHandler(state: bound, head: head, body: request.body),
          ])
        })
      value.connection?.established.whenFailure { error in bound.value.fail(error) }
    } catch { value.fail(error) }
  }

  func cancel() {
    let state = state
    state.eventLoop.execute { state.value.fail(CancellableTLSConnection.Failure.cancelled) }
  }

  final class State {
    let relay: ResponseRelay
    let completion: EventLoopPromise<Void>
    var connection: CancellableTLSConnection?
    var finished = false
    init(relay: ResponseRelay, eventLoop: EventLoop) {
      self.relay = relay
      completion = eventLoop.makePromise()
    }
    func fail(_ error: Error) {
      guard !finished else { return }
      finished = true
      relay.fail()
      connection?.cancel()
      connection = nil
      completion.fail(error)
    }
    func finish() {
      guard !finished else { return }
      finished = true
      relay.finish()
      connection?.cancel()
      connection = nil
      completion.succeed(())
    }
  }
}

final class OwnedResponseHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPClientResponsePart
  private let state: NIOLoopBound<OwnedHTTPRequest.State>
  private let head: HTTPRequestHead
  private let body: HTTPClient.Body?
  private var queued: [HTTPClientResponsePart] = []
  private var writing = false
  private var reading = true
  private var receivedHead = false
  private var receivedEnd = false

  init(state: NIOLoopBound<OwnedHTTPRequest.State>, head: HTTPRequestHead, body: HTTPClient.Body?) {
    self.state = state
    self.head = head
    self.body = body
  }

  func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    if case .handshakeCompleted = event as? TLSUserEvent {
      let channel = context.channel
      channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { [state] error in
        state.value.fail(error)
      }
      reading = false
      pump(context)
      channel.writeAndFlush(HTTPClientRequestPart.head(head)).whenComplete { [state, body] result in
        switch result {
        case .failure(let error): state.value.fail(error)
        case .success:
          guard !state.value.finished else { return }
          state.value.relay.requestHeadSent()
          let uploaded =
            body?.stream(
              HTTPClient.Body.StreamWriter { bytes in
                channel.writeAndFlush(HTTPClientRequestPart.body(bytes))
              }) ?? channel.eventLoop.makeSucceededVoidFuture()
          uploaded.hop(to: channel.eventLoop).whenComplete { result in
            guard !state.value.finished else { return }
            switch result {
            case .failure(let error): state.value.fail(error)
            case .success:
              channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { error in
                state.value.fail(error)
              }
            }
          }
        }
      }
    }
    context.fireUserInboundEventTriggered(event)
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !state.value.finished else { return }
    let part = unwrapInboundIn(data)
    if case .end = part { receivedEnd = true }
    queued.append(part)
    pump(context)
  }

  func channelReadComplete(context: ChannelHandlerContext) {
    reading = false
    pump(context)
    context.fireChannelReadComplete()
  }

  private func pump(_ context: ChannelHandlerContext) {
    guard !writing, !state.value.finished else { return }
    while !queued.isEmpty {
      let acknowledgment: EventLoopFuture<Void>
      switch queued.removeFirst() {
      case .head(let head):
        if (100..<200).contains(head.status.code) {
          guard !receivedHead, head.status.code != 101 else {
            return state.value.fail(PolicyError.invalidHeader)
          }
          continue
        }
        guard !receivedHead else { return state.value.fail(PolicyError.invalidHeader) }
        receivedHead = true
        acknowledgment = state.value.relay.receiveHead(head)
      case .body(let buffer):
        guard receivedHead else { return state.value.fail(PolicyError.invalidHeader) }
        acknowledgment = state.value.relay.receiveBody(buffer)
      case .end:
        guard receivedHead else { return state.value.fail(PolicyError.invalidHeader) }
        state.value.finish()
        queued.removeAll()
        return
      }
      writing = true
      let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
      acknowledgment.whenComplete { result in
        // Even immediately completed writes must not recurse through a queued
        // socket batch containing thousands of tiny HTTP chunks.
        bound.eventLoop.execute {
          let (handler, context) = bound.value
          handler.writing = false
          switch result {
          case .success: handler.pump(context)
          case .failure(let error): handler.state.value.fail(error)
          }
        }
      }
      return
    }
    if !reading {
      reading = true
      context.read()
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    // Once HTTP framing is complete, a later transport error (including TLS
    // close without close_notify) cannot invalidate authenticated bytes already
    // decoded. Preserve the queue while the guest write acknowledgment is pending.
    if !receivedEnd { state.value.fail(error) }
  }
  func channelInactive(context: ChannelHandlerContext) {
    // EOF after a complete HTTP message is normal. Guest write completion may
    // still be pending, so preserve that bounded queue until it drains.
    if !receivedEnd {
      state.value.fail(OwnedHTTPRequest.Failure.incompleteResponse)
      queued.removeAll()
    }
    context.fireChannelInactive()
  }
}
