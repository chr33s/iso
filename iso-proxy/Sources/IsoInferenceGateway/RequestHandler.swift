import IsoInferenceCore
import IsoProxyCore
import IsoProxyTransport
import NIOCore
import NIOHTTP1

/// One guest connection: one request, then close (§8.1). All state lives on
/// the connection's event loop; scheduler callbacks hop onto it.
final class RequestHandler: ChannelInboundHandler, UpstreamDelegate {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  enum Phase {
    case head, body, queued, active, cancelling, done
  }

  enum Cancellation {
    /// Relay stopped; upstream output is read and discarded until its end.
    case draining
    /// Upstream closed; the slot is released after the qualified interval.
    case closing
  }

  private let gateway: Gateway
  private let session: GatewaySession
  private let wireBudget: HeaderWireBudget
  private var context: ChannelHandlerContext?
  private var phase = Phase.head
  private var slots: [SlotPool.Slot] = []
  private var api: FrontendAPI?
  private var expected = 0
  private var body: [UInt8] = []
  private var bufferLease: ByteBudget.Lease?
  private var readDeadline: Scheduled<Void>?
  private var queueDeadline: Scheduled<Void>?
  private var keepAlive: RepeatedTask?
  private var firstOutput: Scheduled<Void>?
  private var generation: Scheduled<Void>?
  private var request: NormalizedRequest?
  private var ticket: Scheduler.Ticket?
  private var upstream: UpstreamCall?
  private var translator: StreamTranslator?
  private var parser = SSEParser(maxEventBytes: SessionLimits.responseBytes)
  private var upstreamStatus: HTTPResponseStatus?
  private var upstreamBody: [UInt8] = []
  private var upstreamBytes = 0
  private var responseStarted = false
  private var clientGone = false
  private var cancellation: Cancellation?
  private var settled = false
  private var pendingWrites = 0
  private var readWanted = false
  private var dispatchedAt: ContinuousClock.Instant?
  private var generationEnd: ContinuousClock.Instant?

  init(gateway: Gateway, session: GatewaySession, wireBudget: HeaderWireBudget) {
    self.gateway = gateway
    self.session = session
    self.wireBudget = wireBudget
  }

  private var loopBound: NIOLoopBound<RequestHandler> {
    NIOLoopBound(self, eventLoop: context!.eventLoop)
  }

  // MARK: Connection

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
    guard !session.failures.tripped, let shared = gateway.sharedConnections.acquire(),
      let own = session.connections.acquire(), session.track(context.channel)
    else {
      phase = .done
      context.close(promise: nil)
      return
    }
    slots = [shared, own]
    arm(&readDeadline, seconds: SessionLimits.headerReadSeconds) { handler in
      handler.fail(
        InferenceError(.requestInvalid, "request header timeout"), status: .requestTimeout)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    clientGone = true
    readDeadline?.cancel()
    keepAlive?.cancel()
    switch phase {
    case .head, .body:
      phase = .done
      release()
    case .queued:
      queueDeadline?.cancel()
      // Otherwise dispatch raced ahead; `dispatched` finishes it unsent.
      if let ticket, gateway.scheduler.withdraw(ticket) {
        phase = .done
        release()
      }
    case .active:
      beginCancellation()
    case .cancelling, .done: break
    }
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    // Bytes after the request (pipelining, garbage) end the connection;
    // admitted work then follows the disconnect path.
    guard phase == .head || phase == .body else { return context.close(promise: nil) }
    // Parser errors may contain hostile bytes: never logged or echoed.
    let status: HTTPResponseStatus =
      (error as? HTTPParserError) == .headerOverflow ? .requestHeaderFieldsTooLarge : .badRequest
    fail(InferenceError(.requestInvalid, "malformed HTTP request"), status: status)
  }

  // MARK: Request

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard phase == .head || phase == .body else { return context.close(promise: nil) }
    switch unwrapInboundIn(data) {
    case .head(let head): receiveHead(head)
    case .body(let buffer):
      guard phase == .body else { return fail(InferenceError(.requestInvalid, "unexpected body")) }
      guard buffer.readableBytes <= expected - body.count else {
        return fail(InferenceError(.requestInvalid, "body longer than Content-Length"))
      }
      body.append(contentsOf: buffer.readableBytesView)
    case .end(let trailers):
      guard phase == .body, trailers == nil else {
        return fail(InferenceError(.requestInvalid, "unexpected end of request"))
      }
      guard body.count == expected else {
        return fail(InferenceError(.requestInvalid, "body shorter than Content-Length"))
      }
      readDeadline?.cancel()
      wireBudget.requestEnded()
      process()
    }
  }

  private func receiveHead(_ head: HTTPRequestHead) {
    guard phase == .head else { return fail(InferenceError(.requestInvalid, "pipelined request")) }
    wireBudget.headReceived()
    guard head.version == .http1_1 else {
      return fail(
        InferenceError(.requestInvalid, "HTTP/1.1 only"), status: .httpVersionNotSupported)
    }
    let headers = head.headers.map { Header($0.name, $0.value) }
    // 2. Capability and session before anything expensive (§8.1).
    guard session.capability.authorizes(headers) else {
      session.failures.record()
      return fail(InferenceError(.authInvalid, "missing or invalid capability"))
    }
    guard session.admits(at: .now) else {
      return fail(InferenceError(.sessionRevoked, "session is not active"))
    }
    // 3. Exact method, path and framing.
    guard (try? RequestTarget(head.uri)) != nil,
      let api = FrontendAPI.route(method: head.method.rawValue, target: head.uri),
      session.apis.contains(api)
    else { return fail(InferenceError(.policyDenied, "operation is not permitted")) }
    self.api = api
    let hasBody = api.method == "POST"
    do { try HeaderTable.check(headers, hasBody: hasBody) } catch { return fail(error) }
    let lengths = head.headers["content-length"]
    guard lengths.count <= 1 else {
      return fail(InferenceError(.requestInvalid, "duplicate Content-Length"))
    }
    if hasBody {
      guard let text = lengths.first else {
        return fail(InferenceError(.lengthRequired, "Content-Length is required"))
      }
      guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), text.utf8.count <= 10,
        let length = Int(text)
      else { return fail(InferenceError(.requestInvalid, "invalid Content-Length")) }
      let limit = session.grants(for: api).values.map(\.maxRequestBodyBytes).max() ?? 0
      guard length <= limit else {
        return fail(InferenceError(.requestTooLarge, "request body exceeds \(limit) bytes"))
      }
      guard let lease = gateway.buffers.reserve(length) else {
        return fail(InferenceError(.capacity, "gateway request buffers are exhausted"))
      }
      bufferLease = lease
      expected = length
      body.reserveCapacity(length)
    } else {
      guard lengths.first.map({ $0 == "0" }) ?? true else {
        return fail(InferenceError(.requestInvalid, "this operation takes no body"))
      }
    }
    phase = .body
    arm(&readDeadline, seconds: SessionLimits.bodyReadSeconds) { handler in
      handler.fail(InferenceError(.requestInvalid, "request body timeout"), status: .requestTimeout)
    }
    if hasBody, expected > 0,
      head.headers["expect"].contains(where: { $0.lowercased() == "100-continue" })
    {
      context?.writeAndFlush(
        wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .continue))),
        promise: nil)
    }
  }

  private func process() {
    guard let api else { return }
    if api == .modelDiscovery {
      return respond(
        status: .ok, body: Normalizer.discovery(session.grants(for: api)),
        contentType: "application/json")
    }
    let normalized: NormalizedRequest
    do {
      normalized = try Normalizer.normalize(api: api, body: body, grants: session.grants(for: api))
    } catch {
      return fail(error)
    }
    body = []
    request = normalized
    if normalized.clamped {
      gateway.audit.record(
        "limit_clamped",
        [
          "session": .string(session.id), "alias": .string(normalized.grant.alias),
          "output_tokens": .int(Int64(normalized.outputTokens)),
        ])
    }
    translator = StreamTranslator(
      api: api, alias: normalized.grant.alias, maxEventBytes: SessionLimits.responseBytes)
    let bound = loopBound
    let loop = context!.eventLoop
    let backend = gateway.backendPolicy(normalized.grant.backend.id) ?? normalized.grant.backend
    let work = Scheduler.Work(
      session: session.id, backend: backend.id, backendMaxActive: backend.maxActive,
      outputTokens: normalized.outputTokens,
      dispatch: { loop.execute { bound.value.dispatched() } },
      cancel: { reason in loop.execute { bound.value.cancelled(reason) } })
    phase = .queued
    do {
      switch try gateway.scheduler.admit(work) {
      case .dispatched(let ticket): self.ticket = ticket
      case .queued(let ticket):
        self.ticket = ticket
        armQueue()
      }
    } catch {
      phase = .body
      fail(error)
    }
  }

  private func armQueue() {
    arm(&queueDeadline, seconds: SessionLimits.queueWaitSeconds) { handler in
      guard handler.phase == .queued, let ticket = handler.ticket,
        handler.gateway.scheduler.withdraw(ticket)
      else { return }
      handler.fail(InferenceError(.deadline, "queue wait exceeded"))
    }
    guard request?.clientStreams == true, let context else { return }
    let bound = loopBound
    keepAlive = context.eventLoop.scheduleRepeatedTask(
      initialDelay: .seconds(Int64(SessionLimits.keepAliveSeconds)),
      delay: .seconds(Int64(SessionLimits.keepAliveSeconds))
    ) { task in
      let handler = bound.value
      guard handler.phase == .queued, !handler.clientGone else { return task.cancel() }
      handler.startStream()
      handler.write(SSEEvent.keepAlive)
    }
  }

  // MARK: Dispatch

  private func dispatched() {
    guard let ticket, let request else { return }
    queueDeadline?.cancel()
    keepAlive?.cancel()
    guard phase == .queued, !clientGone else {
      // Withdrawn or gone before anything was sent upstream.
      gateway.scheduler.finish(ticket, outputTokens: 0)
      release()
      return
    }
    let backend = request.grant.backend
    do { try gateway.journal.dispatched(backend.id) } catch {
      gateway.scheduler.finish(ticket, outputTokens: 0)
      return fail(InferenceError(.backendUnavailable, "cannot record outstanding work"))
    }
    phase = .active
    dispatchedAt = .now
    generationEnd = .now + .seconds(SessionLimits.generationSeconds)
    var headers = HTTPHeaders([
      ("host", backend.id.description), ("content-type", "application/json"),
      ("content-length", String(request.upstreamBody.count)), ("accept-encoding", "identity"),
      ("connection", "close"),
      ("accept", request.upstreamStreams ? "text/event-stream" : "application/json"),
    ])
    if request.api == .anthropicMessages || request.api == .anthropicCountTokens {
      headers.add(name: "anthropic-version", value: "2023-06-01")
    }
    if let credential = backend.credential {
      headers.add(name: "authorization", value: "Bearer " + credential.expose())
    }
    let call = UpstreamCall(eventLoop: context!.eventLoop, delegate: self)
    upstream = call
    arm(&firstOutput, seconds: SessionLimits.firstOutputSeconds) { handler in
      handler.timedOut("time to first output exceeded")
    }
    arm(&generation, seconds: SessionLimits.generationSeconds) { handler in
      handler.generationExpired()
    }
    call.start(
      port: backend.id.port,
      head: HTTPRequestHead(
        version: .http1_1, method: .POST, uri: request.upstreamPath, headers: headers),
      body: request.upstreamBody)
  }

  private func cancelled(_ reason: CancelReason) {
    let error: InferenceError =
      switch reason {
      case .sessionRevoked: InferenceError(.sessionRevoked, "session was revoked")
      case .backendQuarantined: InferenceError(.backendQuarantined, "backend is quarantined")
      case .shutdown: InferenceError(.backendUnavailable, "gateway is shutting down")
      }
    switch phase {
    case .queued:
      queueDeadline?.cancel()
      keepAlive?.cancel()
      fail(error)
    case .active:
      clientError(error)
      beginCancellation()
    default: break
    }
  }

  // MARK: Upstream

  func upstreamHead(_ head: HTTPResponseHead) {
    upstreamStatus = head.status
    guard phase == .active, head.status == .ok else { return }
    let type = head.headers.first(name: "content-type")?.lowercased() ?? ""
    let wanted = request?.upstreamStreams == true ? "text/event-stream" : "application/json"
    if !type.hasPrefix(wanted) {
      upstreamStatus = .badGateway
    }
  }

  func upstreamBody(_ buffer: ByteBuffer) {
    upstreamBytes += buffer.readableBytes
    if upstreamBytes > SessionLimits.responseBytes {
      guard cancellation == nil else { return }
      clientError(InferenceError(.upstreamInvalid, "backend response exceeds the byte limit"))
      return beginCancellation()
    }
    guard let status = upstreamStatus, status == .ok, request?.upstreamStreams == true else {
      // Error bodies and token counts: bounded, never relayed verbatim.
      if upstreamBody.count < 64 << 10 {
        upstreamBody.append(
          contentsOf: buffer.readableBytesView.prefix((64 << 10) - upstreamBody.count))
      }
      return
    }
    guard cancellation == nil else { return }
    do {
      for event in try parser.feed(buffer.readableBytesView) {
        guard let emitted = try translator!.consume(event) else { continue }
        if translator!.sawOutput { firstOutput?.cancel() }
        if request!.clientStreams {
          startStream()
          write(emitted)
        }
      }
    } catch let error as InferenceError {
      clientError(error)
      beginCancellation()
    } catch {
      clientError(InferenceError(.upstreamInvalid, "backend sent an invalid event stream"))
      beginCancellation()
    }
  }

  func upstreamReadComplete() {
    if pendingWrites == 0 || cancellation == .draining {
      upstream?.read()
    } else {
      readWanted = true
    }
  }

  func upstreamEnd() {
    // The backend finished its response: completion evidence (§9.2).
    settle()
    guard cancellation == nil else { return finishClient() }
    respondToCompletion()
  }

  func upstreamUnavailable() {
    // Nothing reached the backend: release without evidence questions.
    settle()
    if cancellation == nil {
      clientError(InferenceError(.backendUnavailable, "backend is not reachable"))
    }
    finishClient()
  }

  func upstreamClosed(local: Bool) {
    if local {
      // Our own close: evidence depends on the class, handled where closed.
      return
    }
    // The backend ended the connection before a complete response. Its work
    // is over unless the profile says closure proves nothing.
    if request?.grant.backend.profile.evidence == CompletionEvidence.none {
      markUncertain()
    } else {
      settle()
    }
    if cancellation == nil {
      clientError(InferenceError(.upstreamInvalid, "backend closed the connection"))
    }
    finishClient()
  }

  private func respondToCompletion() {
    guard let request, var translator else { return finishClient() }
    guard let status = upstreamStatus, status == .ok else {
      let code = upstreamStatus?.code ?? 0
      let error =
        (400..<500).contains(code)
        ? InferenceError(.unsupported, "backend rejected the request (HTTP \(code))")
        : InferenceError(.upstreamInvalid, "backend failed the request (HTTP \(code))")
      clientError(error)
      return finishClient()
    }
    if !request.upstreamStreams {
      do {
        let body = try CountTokensResponse.translate(upstreamBody)
        return respond(status: .ok, body: body, contentType: "application/json")
      } catch {
        clientError(error)
        return finishClient()
      }
    }
    // Any bytes left without a trailing blank line are an incomplete event.
    do {
      for event in try parser.feed([0x0A, 0x0A]) { _ = try translator.consume(event) }
      self.translator = translator
    } catch {
      clientError(InferenceError(.upstreamInvalid, "backend sent an invalid event stream"))
      return finishClient()
    }
    switch translator.outcome {
    case .completed?:
      if request.clientStreams {
        finishClient()
      } else {
        do {
          respond(status: .ok, body: try translator.aggregated(), contentType: "application/json")
        } catch {
          clientError(error)
          finishClient()
        }
      }
    case .failed?:
      if !request.clientStreams {
        clientError(InferenceError(.upstreamInvalid, "backend reported an error"))
      }
      finishClient()
    case nil:
      clientError(InferenceError(.upstreamInvalid, "backend stream ended without a terminal event"))
      finishClient()
    }
  }

  // MARK: Cancellation and deadlines

  private func timedOut(_ message: String) {
    guard phase == .active, cancellation == nil else { return }
    clientError(InferenceError(.deadline, message))
    beginCancellation()
  }

  private func generationExpired() {
    guard phase == .active || phase == .cancelling else { return }
    if cancellation == .draining {
      // Draining ran out of time: nothing proves the backend stopped.
      markUncertain()
      upstream?.close()
      return finishClient()
    }
    timedOut("generation deadline exceeded")
  }

  /// §9.2: the backend's completion-evidence procedure.
  private func beginCancellation() {
    guard phase == .active, cancellation == nil, !settled, let request else { return }
    phase = .cancelling
    firstOutput?.cancel()
    let profile = request.grant.backend.profile
    switch profile.evidence {
    case .drain:
      cancellation = .draining
      // Drain within the remaining generation time, but never less than
      // the cancellation grace when the deadline itself triggered this.
      let remaining = generationEnd.map { $0 - ContinuousClock.now } ?? .zero
      let grace = Duration.seconds(SessionLimits.cancellationGraceSeconds)
      arm(&generation, after: max(remaining, grace)) { handler in handler.generationExpired() }
      upstream?.read()
    case .streamClose:
      cancellation = .closing
      upstream?.close()
      let bound = loopBound
      context?.eventLoop.scheduleTask(
        in: .milliseconds(Int64(profile.streamCloseDrainMilliseconds))
      ) { bound.value.settle() }
    case .none, .explicit:
      cancellation = .closing
      upstream?.close()
      markUncertain()
    }
    finishClient()
  }

  private func settle() {
    guard !settled, let ticket, let request else { return }
    settled = true
    generation?.cancel()
    firstOutput?.cancel()
    let usage = translator?.usage ?? Usage()
    gateway.scheduler.finish(ticket, outputTokens: usage.outputTokens)
    gateway.journal.settled(request.grant.backend.id)
    if let input = usage.inputTokens, input > request.inputBound {
      gateway.scheduler.quarantine(request.grant.backend.id, .qualificationFailure)
      gateway.audit.record(
        "backend_quarantined",
        [
          "backend": .int(Int64(request.grant.backend.id.port)),
          "reason": .string("qualification-failure"),
        ])
    }
    gateway.audit.record(
      "request_completed",
      [
        "session": .string(session.id), "alias": .string(request.grant.alias),
        "api": .string(request.api.rawValue),
        "request_bytes": .int(Int64(request.upstreamBody.count)),
        "response_bytes": .int(Int64(upstreamBytes)),
        "input_tokens": usage.inputTokens.map { .int(Int64($0)) } ?? .null,
        "output_tokens": usage.outputTokens.map { .int(Int64($0)) } ?? .null,
        "cancelled": .bool(cancellation != nil),
        "milliseconds": .int(
          dispatchedAt.map { ContinuousClock.now - $0 }.map {
            $0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000
          } ?? 0),
      ])
    release()
  }

  private func markUncertain() {
    guard !settled, let ticket, let request else { return }
    settled = true
    generation?.cancel()
    gateway.scheduler.markUncertain(ticket)
    gateway.audit.record(
      "backend_quarantined",
      [
        "backend": .int(Int64(request.grant.backend.id.port)),
        "reason": .string("uncertain-cancellation"),
      ])
    release()
  }

  // MARK: Client output

  private func startStream() {
    guard !responseStarted, !clientGone, let context else { return }
    responseStarted = true
    let head = HTTPResponseHead(
      version: .http1_1, status: .ok,
      headers: HTTPHeaders([
        ("content-type", "text/event-stream"), ("cache-control", "no-cache"),
        ("connection", "close"),
      ]))
    context.write(wrapOutboundOut(.head(head)), promise: nil)
  }

  private func write(_ bytes: [UInt8]) {
    guard !clientGone, let context else { return }
    var buffer = context.channel.allocator.buffer(capacity: bytes.count)
    buffer.writeBytes(bytes)
    pendingWrites += 1
    let bound = loopBound
    context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer)))).whenComplete { _ in
      let handler = bound.value
      handler.pendingWrites -= 1
      if handler.pendingWrites == 0, handler.readWanted {
        handler.readWanted = false
        handler.upstream?.read()
      }
    }
  }

  /// An error for the guest: a JSON response before streaming starts, the
  /// protocol's error event after.
  private func clientError(_ error: InferenceError) {
    gateway.audit.rejected(session: session.id, code: error.code)
    guard !clientGone, let context, phase != .done else { return }
    if responseStarted {
      write(streamError(error))
      return
    }
    responseStarted = true
    let body = error.body(for: api)
    var buffer = context.channel.allocator.buffer(capacity: body.count)
    buffer.writeBytes(body)
    let head = HTTPResponseHead(
      version: .http1_1, status: HTTPResponseStatus(statusCode: error.code.status),
      headers: HTTPHeaders([
        ("content-type", "application/json"), ("content-length", String(body.count)),
        ("connection", "close"),
      ]))
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
  }

  private func streamError(_ error: InferenceError) -> [UInt8] {
    switch api {
    case .anthropicMessages?:
      let data = JSON.object(
        JSONObject([
          "type": .string("error"),
          "error": .object(
            JSONObject([
              "type": .string("overloaded_error"), "message": .string(error.message),
            ])),
        ]))
      return SSEEvent.encode(name: "error", data: data.serialized)
    case .openAIResponses?:
      let data = JSON.object(
        JSONObject([
          "type": .string("error"), "code": .string(error.code.rawValue),
          "message": .string(error.message),
        ]))
      return SSEEvent.encode(name: "error", data: data.serialized)
    default:
      return SSEEvent.encode(name: nil, data: error.body(for: .openAIChat))
    }
  }

  private func respond(status: HTTPResponseStatus, body: [UInt8], contentType: String) {
    guard !clientGone, let context, !responseStarted else { return finishClient() }
    responseStarted = true
    var buffer = context.channel.allocator.buffer(capacity: body.count)
    buffer.writeBytes(body)
    let head = HTTPResponseHead(
      version: .http1_1, status: status,
      headers: HTTPHeaders([
        ("content-type", contentType), ("content-length", String(body.count)),
        ("connection", "close"),
      ]))
    context.write(wrapOutboundOut(.head(head)), promise: nil)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    finishClient()
  }

  /// End the guest response and close the connection. Backend-side work may
  /// continue (draining) and settles on its own.
  private func finishClient() {
    readDeadline?.cancel()
    queueDeadline?.cancel()
    keepAlive?.cancel()
    if phase != .cancelling { phase = .done }
    guard !clientGone, let context else { return }
    clientGone = true
    let channel = context.channel
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }

  /// Refuse before any work was admitted.
  private func fail(_ error: InferenceError, status: HTTPResponseStatus? = nil) {
    guard phase == .head || phase == .body || phase == .queued else { return }
    readDeadline?.cancel()
    gateway.audit.rejected(session: session.id, code: error.code)
    if clientGone {
      phase = .done
      release()
      return
    }
    if let status {
      responseStarted = true
      let head = HTTPResponseHead(
        version: .http1_1, status: status,
        headers: HTTPHeaders([("content-length", "0"), ("connection", "close")]))
      context?.write(wrapOutboundOut(.head(head)), promise: nil)
    } else {
      clientError(error)
    }
    phase = .done
    release()
    finishClient()
  }

  /// Buffers go once the request is parsed or abandoned; connection slots
  /// go only when no admitted work is outstanding for this connection.
  private func release() {
    bufferLease?.release()
    bufferLease = nil
    body = []
    guard settled || ticket == nil || phase == .done else { return }
    for slot in slots { slot.release() }
    slots = []
  }

  private func arm(
    _ slot: inout Scheduled<Void>?, seconds: Int, _ action: @escaping (RequestHandler) -> Void
  ) {
    arm(&slot, after: .seconds(seconds), action)
  }

  private func arm(
    _ slot: inout Scheduled<Void>?, after duration: Duration,
    _ action: @escaping (RequestHandler) -> Void
  ) {
    slot?.cancel()
    guard let context else { return }
    let bound = NIOLoopBound((self, action), eventLoop: context.eventLoop)
    let nanoseconds =
      duration.components.seconds * 1_000_000_000 + duration.components.attoseconds / 1_000_000_000
    slot = context.eventLoop.scheduleTask(in: .nanoseconds(max(nanoseconds, 0))) {
      let (handler, action) = bound.value
      action(handler)
    }
  }
}
