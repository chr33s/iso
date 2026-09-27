import CoopProxyCore
import NIOCore
import NIOHTTP1

/// The event loop owns all mutable request state. Accepted body buffers pass
/// through unchanged, without aggregation. The upstream bridge downstream of
/// this gate controls socket reads to apply backpressure.
final class InboundGate: ChannelDuplexHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias InboundOut = HTTPServerRequestPart
  typealias OutboundIn = HTTPServerResponsePart
  typealias OutboundOut = HTTPServerResponsePart

  private enum State { case headers, body, response, closed }
  private var state = State.headers
  private let config: ProxyConfig
  private let connections: Capacity
  private let requests: Capacity
  private let wireBudget: HeaderWireBudget
  private var connectionLease: Capacity.Lease?
  private var requestLease: Capacity.Lease?
  private var deadline: Scheduled<Void>?
  private var bodyBytes = 0
  private var responseStarted = false

  init(config: ProxyConfig, connections: Capacity, requests: Capacity, wireBudget: HeaderWireBudget)
  {
    self.config = config
    self.connections = connections
    self.requests = requests
    self.wireBudget = wireBudget
  }

  func handlerAdded(context: ChannelHandlerContext) {
    guard let lease = connections.acquire() else {
      state = .closed
      context.close(promise: nil)
      return
    }
    connectionLease = lease
    arm(context, seconds: Limits.initialHeaderSeconds)
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard state != .closed else { return }
    switch unwrapInboundIn(data) {
    case .head(let head):
      wireBudget.headReceived()
      guard state == .headers else { return refuse(context, .badRequest) }
      guard head.version == .http1_1 else { return refuse(context, .httpVersionNotSupported) }
      // NIO bounds names and values separately; the contract bounds their sum.
      guard
        head.headers.allSatisfy({
          $0.name.utf8.count + $0.value.utf8.count <= Limits.headerFieldBytes
        })
      else { return refuse(context, .requestHeaderFieldsTooLarge) }
      let headers = head.headers.map { Header($0.name, $0.value) }
      guard let target = try? RequestTarget(head.uri) else { return refuse(context, .badRequest) }
      guard config.capability.authorizes(headers) else { return refuse(context, .unauthorized) }
      guard
        OperationPolicy.allows(
          method: head.method.rawValue, target: target, provider: config.provider)
      else { return refuse(context, .forbidden) }
      do {
        _ = try HeaderPolicy.request(
          headers, provider: config.provider, injection: config.injection)
      } catch { return refuse(context, .badRequest) }
      guard !head.headers.contains(name: "trailer") else { return refuse(context, .badRequest) }
      // NIO validates framing too; reject ambiguity explicitly before passing
      // a credential-bearing request to the upstream bridge.
      let lengths = head.headers["content-length"]
      guard lengths.count <= 1,
        !(head.headers.contains(name: "transfer-encoding") && !lengths.isEmpty)
      else { return refuse(context, .badRequest) }
      // Unknown-length uploads cannot satisfy pre-forwarding size admission.
      guard !head.headers.contains(name: "transfer-encoding")
      else { return refuse(context, .lengthRequired) }
      var hasBody = false
      if let length = lengths.first {
        guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
          let count = UInt64(length)
        else { return refuse(context, .badRequest) }
        guard count <= Limits.requestBodyBytes else { return refuse(context, .payloadTooLarge) }
        hasBody = count > 0
      }
      guard let lease = requests.acquire() else { return refuse(context, .serviceUnavailable) }
      requestLease = lease
      bodyBytes = 0
      state = .body
      arm(context, seconds: Limits.bodyIdleSeconds)
      // The upstream decoder drops interim responses. Acknowledge admitted
      // uploads here so clients waiting for Continue can send their body.
      if hasBody,
        head.headers[canonicalForm: "expect"].contains(where: { $0.lowercased() == "100-continue" })
      {
        let channel = context.channel
        context.writeAndFlush(
          wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .continue)))
        ).whenFailure { _ in channel.close(promise: nil) }
      }
      context.fireChannelRead(data)
    case .body(let buffer):
      guard state == .body else { return refuse(context, .badRequest) }
      guard buffer.readableBytes <= Limits.requestBodyBytes - bodyBytes
      else { return refuse(context, .payloadTooLarge) }
      bodyBytes += buffer.readableBytes
      arm(context, seconds: Limits.bodyIdleSeconds)
      context.fireChannelRead(data)
    case .end(let trailers):
      guard state == .body, trailers == nil else { return refuse(context, .badRequest) }
      wireBudget.requestEnded()
      deadline?.cancel()
      deadline = nil
      state = .response
      context.fireChannelRead(data)
    }
  }

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    switch unwrapOutboundIn(data) {
    case .head(let head):
      if head.status.code >= 200 { responseStarted = true }
      context.write(data, promise: promise)
    case .end:
      let lease = requestLease
      requestLease = nil
      let earlyResponse = state == .body
      deadline?.cancel()
      deadline = nil
      let completion = promise ?? context.eventLoop.makePromise(of: Void.self)
      let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
      completion.futureResult.whenComplete { result in
        lease?.release()
        let (gate, context) = bound.value
        guard gate.state != .closed else { return }
        if earlyResponse {
          gate.state = .closed
          context.close(promise: nil)
        } else if case .success = result {
          gate.responseStarted = false
          gate.state = .headers
          gate.wireBudget.beginNextRequest()
          gate.arm(context, seconds: Limits.initialHeaderSeconds)
        } else {
          gate.state = .closed
          context.close(promise: nil)
        }
      }
      context.write(data, promise: completion)
    case .body:
      context.write(data, promise: promise)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    // Do not log parser errors: an error may contain hostile request bytes.
    refuse(
      context,
      (error as? HTTPParserError) == .headerOverflow ? .requestHeaderFieldsTooLarge : .badRequest)
  }

  func channelInactive(context: ChannelHandlerContext) {
    cleanup()
    context.fireChannelInactive()
  }

  func handlerRemoved(context: ChannelHandlerContext) { cleanup() }

  private func cleanup() {
    state = .closed
    deadline?.cancel()
    deadline = nil
    requestLease = nil
    connectionLease = nil
  }

  private func arm(_ context: ChannelHandlerContext, seconds: Int) {
    deadline?.cancel()
    let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
    deadline = context.eventLoop.scheduleTask(in: .seconds(Int64(seconds))) {
      let (gate, context) = bound.value
      gate.refuse(context, .requestTimeout)
    }
  }

  private func refuse(_ context: ChannelHandlerContext, _ status: HTTPResponseStatus) {
    guard state != .closed else { return }
    state = .closed
    deadline?.cancel()
    deadline = nil
    if responseStarted {
      context.close(promise: nil)
      return
    }
    let headers = HTTPHeaders([("content-length", "0"), ("connection", "close")])
    context.write(
      wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))),
      promise: nil)
    let channel = context.channel
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }
}
