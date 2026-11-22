import IsoInferenceCore
import IsoProxyCore
import IsoProxyTransport
import NIOCore
import NIOHTTP1

/// One guest connection: one request, then close (§8.1). All state lives on
/// the connection's event loop; scheduler, normalizer and timer callbacks
/// hop onto it.
///
/// Two lifetimes meet here. The client side ends when the socket closes;
/// the connection's slots are released then, and only then, by the close
/// future. The work side ends when the backend's work settles (completion
/// evidence, §9.2), which can be after the client has gone. The handler
/// holds no reference to its channel context once the pipeline removes it,
/// so it is freed as soon as the work side is done too.
final class RequestHandler: ChannelInboundHandler, UpstreamDelegate {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  enum Phase {
    case head, body, normalizing, queued, active, cancelling, done
  }

  enum Cancellation {
    /// Relay stopped; upstream output is read and discarded until its end.
    case draining
    /// Upstream closed; the slot is released after the qualified interval.
    case closing
  }

  /// What the handler keeps of a normalized request once its body has gone
  /// upstream.
  struct Plan {
    let api: FrontendAPI
    let grant: ServiceGrant
    let clientStreams: Bool
    let upstreamStreams: Bool
    let inputBound: Int
    let requestBytes: Int

    var backend: BackendPolicy { grant.backend }
  }

  private let gateway: Gateway
  private let session: GatewaySession
  private let wireBudget: HeaderWireBudget
  private let eventLoop: EventLoop
  private let timing: GatewayTiming
  private var context: ChannelHandlerContext?
  private var phase = Phase.head
  private var api: FrontendAPI?
  private var expected = 0
  private var body: [UInt8] = []
  /// The normalized upstream body, from normalization until dispatch.
  private var pending: [UInt8]?
  private var bufferLease: ByteBudget.Lease?
  private var readDeadline: Scheduled<Void>?
  private var queueDeadline: Scheduled<Void>?
  private var keepAlive: RepeatedTask?
  private var firstOutput: Scheduled<Void>?
  private var generation: Scheduled<Void>?
  private var plan: Plan?
  private var ticket: Scheduler.Ticket?
  private var upstream: UpstreamCall?
  private var translator: StreamTranslator?
  private var parser = SSEParser(maxEventBytes: SessionLimits.responseBytes)
  private var upstreamStatus: HTTPResponseStatus?
  /// Error bodies and token counts: bounded, never relayed verbatim.
  private var upstreamBody: [UInt8] = []
  private var upstreamBytes = 0
  /// Set when the backend's stream could not be translated at its end.
  private var streamFailure: InferenceError?
  private var responseStarted = false
  private var clientGone = false
  private var cancellation: Cancellation?
  private var settled = false
  private var pendingWrites = 0
  private var readWanted = false
  private var dispatchedAt: ContinuousClock.Instant?
  private var generationEnd: ContinuousClock.Instant?

  init(
    gateway: Gateway, session: GatewaySession, wireBudget: HeaderWireBudget, eventLoop: EventLoop
  ) {
    self.gateway = gateway
    self.session = session
    self.wireBudget = wireBudget
    self.eventLoop = eventLoop
    timing = gateway.timing
    gateway.liveHandlers.add(1, ordering: .relaxed)
  }

  deinit {
    // Accounting for tests and status only; no resource is released here.
    gateway.liveHandlers.subtract(1, ordering: .relaxed)
  }

  private var loopBound: NIOLoopBound<RequestHandler> {
    NIOLoopBound(self, eventLoop: eventLoop)
  }

  // MARK: Connection

  func handlerAdded(context: ChannelHandlerContext) {
    self.context = context
    guard !session.failures.tripped, let shared = gateway.sharedConnections.acquire() else {
      return refuseConnection(context)
    }
    guard let own = session.connections.acquire() else {
      shared.release()
      return refuseConnection(context)
    }
    // Both slots are held until the socket closes, however it closes: an
    // idle, slow or non-reading client is always counted (§9.1).
    context.channel.closeFuture.whenComplete { _ in
      own.release()
      shared.release()
    }
    guard session.track(context.channel) else { return refuseConnection(context) }
    arm(&readDeadline, after: timing.headerRead) { handler in
      handler.fail(
        InferenceError(.requestInvalid, "request header timeout"), status: .requestTimeout)
    }
  }

  private func refuseConnection(_ context: ChannelHandlerContext) {
    phase = .done
    clientGone = true
    context.close(promise: nil)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    // The context holds this handler; dropping it here breaks that cycle.
    // Backend work that is still draining keeps the handler alive through
    // the scheduler until it settles.
    self.context = nil
    clientGone = true
    cancelClientTimers()
  }

  func channelInactive(context: ChannelHandlerContext) {
    clientGone = true
    cancelClientTimers()
    switch phase {
    case .head, .body:
      phase = .done
      releaseBuffers()
    case .normalizing:
      // `normalized` sees the phase and releases the buffers.
      phase = .done
    case .queued:
      queueDeadline?.cancel()
      // Otherwise dispatch raced ahead; `dispatched` finishes it unsent.
      if let ticket, gateway.scheduler.withdraw(ticket) {
        phase = .done
        settled = true
        releaseBuffers()
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

  private func cancelClientTimers() {
    readDeadline?.cancel()
    keepAlive?.cancel()
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
      // The session's share first, then the shared budget: one session
      // cannot hold the buffers every session needs (§9.1).
      guard let lease = gateway.buffers.reserve(length, alsoFrom: session.buffers) else {
        return fail(InferenceError(.capacity, "request buffers are exhausted"))
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
    arm(&readDeadline, after: timing.bodyRead) { handler in
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
    // A request that reaches this point costs a rate token whether or not
    // its body normalizes, so malformed bodies cannot be parsed at will.
    let permit: Scheduler.Permit
    do { permit = try gateway.scheduler.permit(session: session.id) } catch { return fail(error) }
    phase = .normalizing
    let body = self.body
    self.body = []
    let grants = session.grants(for: api)
    let bound = loopBound
    let loop = eventLoop
    // Parsing and validation of a large body take long enough to stall
    // every connection on this event loop; they run on the normalizer pool.
    gateway.normalizers.submit {
      let result = Result { () throws(InferenceError) -> NormalizedRequest in
        try Normalizer.normalize(api: api, body: body, grants: grants)
      }
      loop.execute { bound.value.normalized(result, permit: permit) }
    }
  }

  private func normalized(
    _ result: Result<NormalizedRequest, InferenceError>, permit: Scheduler.Permit
  ) {
    guard phase == .normalizing, !clientGone else {
      phase = .done
      return releaseBuffers()
    }
    let normalized: NormalizedRequest
    switch result {
    case .success(let request): normalized = request
    case .failure(let error): return fail(error)
    }
    if normalized.clamped {
      gateway.audit.record(
        "limit_clamped",
        [
          "session": .string(session.id), "alias": .string(normalized.grant.alias),
          "output_tokens": .int(Int64(normalized.outputTokens)),
        ])
    }
    plan = Plan(
      api: normalized.api, grant: normalized.grant, clientStreams: normalized.clientStreams,
      upstreamStreams: normalized.upstreamStreams, inputBound: normalized.inputBound,
      requestBytes: normalized.upstreamBody.count)
    pending = normalized.upstreamBody
    translator = StreamTranslator(
      api: normalized.api, alias: normalized.grant.alias,
      maxEventBytes: SessionLimits.responseBytes)
    let bound = loopBound
    let loop = eventLoop
    let backend = gateway.backendPolicy(normalized.grant.backend.id) ?? normalized.grant.backend
    let work = Scheduler.Work(
      session: session.id, backend: backend.id, backendMaxActive: backend.maxActive,
      outputTokens: normalized.outputTokens,
      dispatch: { loop.execute { bound.value.dispatched() } },
      cancel: { reason in loop.execute { bound.value.cancelled(reason) } })
    phase = .queued
    do {
      switch try gateway.scheduler.admit(work, permit: permit) {
      case .dispatched(let ticket): self.ticket = ticket
      case .queued(let ticket):
        self.ticket = ticket
        armQueue()
      }
    } catch {
      fail(error)
    }
  }

  private func armQueue() {
    arm(&queueDeadline, after: timing.queueWait) { handler in
      guard handler.phase == .queued, let ticket = handler.ticket,
        handler.gateway.scheduler.withdraw(ticket)
      else { return }
      handler.settled = true
      handler.fail(InferenceError(.deadline, "queue wait exceeded"))
    }
    guard plan?.clientStreams == true else { return }
    let bound = loopBound
    let interval = TimeAmount(timing.keepAlive)
    keepAlive = eventLoop.scheduleRepeatedTask(initialDelay: interval, delay: interval) { task in
      let handler = bound.value
      guard handler.phase == .queued, !handler.clientGone else { return task.cancel() }
      handler.startStream()
      handler.write(SSEEvent.keepAlive)
    }
  }

  // MARK: Dispatch

  private func dispatched() {
    guard let ticket else { return }
    queueDeadline?.cancel()
    keepAlive?.cancel()
    guard phase == .queued, !clientGone, !settled, let plan, let body = pending else {
      // Refused, cancelled or gone before anything was sent upstream. The
      // scheduler may have started it anyway (a cancellation can arrive
      // first), so its slot is returned here; `finish` ignores a ticket it
      // no longer holds.
      gateway.scheduler.finish(ticket, outputTokens: 0)
      settled = true
      if phase == .queued { phase = .done }
      return releaseBuffers()
    }
    let backend = plan.backend
    do { try gateway.journal.dispatched(backend.id) } catch {
      settled = true
      gateway.scheduler.finish(ticket, outputTokens: 0)
      return fail(InferenceError(.backendUnavailable, "cannot record outstanding work"))
    }
    phase = .active
    pending = nil
    dispatchedAt = .now
    generationEnd = .now + timing.generation
    var headers = HTTPHeaders([
      ("host", backend.id.description), ("content-type", "application/json"),
      ("content-length", String(body.count)), ("accept-encoding", "identity"),
      ("connection", "close"),
      ("accept", plan.upstreamStreams ? "text/event-stream" : "application/json"),
    ])
    if plan.api == .anthropicMessages || plan.api == .anthropicCountTokens {
      headers.add(name: "anthropic-version", value: "2023-06-01")
    }
    if let credential = backend.credential {
      headers.add(name: "authorization", value: "Bearer " + credential.expose())
    }
    let call = UpstreamCall(eventLoop: eventLoop, delegate: self)
    upstream = call
    arm(&firstOutput, after: timing.firstOutput) { handler in
      handler.timedOut("time to first output exceeded")
    }
    arm(&generation, after: timing.generation) { handler in handler.generationExpired() }
    call.start(
      port: backend.id.port,
      head: HTTPRequestHead(version: .http1_1, method: .POST, uri: plan.api.path, headers: headers),
      body: body)
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
      // The scheduler already removed the queued entry.
      queueDeadline?.cancel()
      keepAlive?.cancel()
      settled = true
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
    let wanted = plan?.upstreamStreams == true ? "text/event-stream" : "application/json"
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
    guard let status = upstreamStatus, status == .ok, let plan, plan.upstreamStreams else {
      if upstreamBody.count < 64 << 10 {
        upstreamBody.append(
          contentsOf: buffer.readableBytesView.prefix((64 << 10) - upstreamBody.count))
      }
      return
    }
    guard cancellation == nil, var translator = translator.take() else { return }
    defer { self.translator = translator }
    do {
      for event in try parser.feed(buffer.readableBytesView) {
        guard let emitted = try translator.consume(event) else { continue }
        if translator.sawOutput { firstOutput?.cancel() }
        if plan.clientStreams {
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
    // The backend finished its response: completion evidence (§9.2). Any
    // bytes left without a trailing blank line are an incomplete event;
    // they are translated first, so their usage counts when settling.
    if cancellation == nil { flushStream() }
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
    if plan?.backend.profile.evidence == CompletionEvidence.none {
      markUncertain()
    } else {
      settle()
    }
    if cancellation == nil {
      clientError(InferenceError(.upstreamInvalid, "backend closed the connection"))
    }
    finishClient()
  }

  private func flushStream() {
    guard upstreamStatus == .ok, plan?.upstreamStreams == true,
      var translator = translator.take()
    else { return }
    defer { self.translator = translator }
    do {
      for event in try parser.feed([0x0A, 0x0A]) { _ = try translator.consume(event) }
    } catch {
      streamFailure = InferenceError(.upstreamInvalid, "backend sent an invalid event stream")
    }
  }

  private func respondToCompletion() {
    defer { translator = nil }
    guard let plan, let translator else { return finishClient() }
    guard let status = upstreamStatus, status == .ok else {
      let code = upstreamStatus?.code ?? 0
      let error =
        (400..<500).contains(code)
        ? InferenceError(.unsupported, "backend rejected the request (HTTP \(code))")
        : InferenceError(.upstreamInvalid, "backend failed the request (HTTP \(code))")
      clientError(error)
      return finishClient()
    }
    if !plan.upstreamStreams {
      do {
        let body = try CountTokensResponse.translate(upstreamBody)
        return respond(status: .ok, body: body, contentType: "application/json")
      } catch {
        clientError(error)
        return finishClient()
      }
    }
    if let streamFailure {
      clientError(streamFailure)
      return finishClient()
    }
    switch translator.outcome {
    case .completed?:
      if plan.clientStreams {
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
      if !plan.clientStreams {
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
    guard phase == .active, cancellation == nil, !settled, let plan else { return }
    phase = .cancelling
    firstOutput?.cancel()
    let profile = plan.backend.profile
    switch profile.evidence {
    case .drain:
      cancellation = .draining
      // Drain within the remaining generation time, but never less than
      // the cancellation grace when the deadline itself triggered this.
      let remaining = generationEnd.map { $0 - ContinuousClock.now } ?? .zero
      arm(&generation, after: max(remaining, timing.cancellationGrace)) { handler in
        handler.generationExpired()
      }
      upstream?.read()
    case .streamClose:
      cancellation = .closing
      upstream?.close()
      // Closing the stream stops generation; the qualified drain interval
      // covers work the backend cannot interrupt (prefill).
      arm(&generation, after: .milliseconds(profile.streamCloseDrainMilliseconds)) { handler in
        handler.settle()
      }
    case .none, .explicit:
      cancellation = .closing
      upstream?.close()
      markUncertain()
    }
    finishClient()
  }

  private func settle() {
    guard !settled, let ticket, let plan else { return }
    settled = true
    generation?.cancel()
    firstOutput?.cancel()
    let usage = translator?.usage ?? Usage()
    gateway.scheduler.finish(ticket, outputTokens: usage.outputTokens)
    gateway.journal.settled(plan.backend.id)
    // Reported usage above the input bound breaks the qualification's
    // byte-bound property; a completed stream that reports none cannot be
    // checked at all (§8.4.1).
    let completed = translator?.outcome == .completed && plan.upstreamStreams
    if let input = usage.inputTokens, input > plan.inputBound {
      quarantine(plan, reason: "input usage above the bound")
    } else if completed, usage.inputTokens == nil {
      quarantine(plan, reason: "no input usage")
    }
    gateway.audit.record(
      "request_completed",
      [
        "session": .string(session.id), "alias": .string(plan.grant.alias),
        "api": .string(plan.api.rawValue), "request_bytes": .int(Int64(plan.requestBytes)),
        "response_bytes": .int(Int64(upstreamBytes)),
        "input_tokens": usage.inputTokens.map { .int(Int64($0)) } ?? .null,
        "output_tokens": usage.outputTokens.map { .int(Int64($0)) } ?? .null,
        "cancelled": .bool(cancellation != nil),
        "milliseconds": .int(dispatchedAt.map { milliseconds(ContinuousClock.now - $0) } ?? 0),
      ])
    upstream = nil
    upstreamBody = []
    releaseBuffers()
  }

  private func quarantine(_ plan: Plan, reason detail: String) {
    gateway.scheduler.quarantine(plan.backend.id, .qualificationFailure)
    gateway.audit.record(
      "backend_quarantined",
      [
        "backend": .int(Int64(plan.backend.id.port)), "reason": .string("qualification-failure"),
        "detail": .string(detail),
      ])
  }

  private func markUncertain() {
    guard !settled, let ticket, let plan else { return }
    settled = true
    generation?.cancel()
    gateway.scheduler.markUncertain(ticket)
    gateway.audit.record(
      "backend_quarantined",
      [
        "backend": .int(Int64(plan.backend.id.port)),
        "reason": .string("uncertain-cancellation"),
      ])
    releaseBuffers()
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
  /// protocol's error event after. Each rejection is audited here once.
  private func clientError(_ error: InferenceError) {
    gateway.audit.rejected(session: session.id, code: error.code)
    guard !clientGone, let context, phase != .done else { return }
    if responseStarted {
      write(error.streamEvent(for: api))
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
    // A guest that stops reading cannot keep the socket: the close deadline
    // ends it whether or not the response was flushed.
    let deadline = eventLoop.scheduleTask(in: TimeAmount(timing.close)) {
      channel.close(promise: nil)
    }
    channel.closeFuture.whenComplete { _ in deadline.cancel() }
    context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
      channel.close(promise: nil)
    }
  }

  /// Refuse before any work was dispatched.
  private func fail(_ error: InferenceError, status: HTTPResponseStatus? = nil) {
    guard [.head, .body, .normalizing, .queued].contains(phase) else { return }
    readDeadline?.cancel()
    if clientGone {
      gateway.audit.rejected(session: session.id, code: error.code)
      phase = .done
      return releaseBuffers()
    }
    if let status {
      gateway.audit.rejected(session: session.id, code: error.code)
      responseStarted = true
      let head = HTTPResponseHead(
        version: .http1_1, status: status,
        headers: HTTPHeaders([("content-length", "0"), ("connection", "close")]))
      context?.write(wrapOutboundOut(.head(head)), promise: nil)
    } else {
      clientError(error)
    }
    phase = .done
    releaseBuffers()
    finishClient()
  }

  /// Buffers go once the request is refused, settled or abandoned.
  /// Connection slots are not released here but when the socket closes.
  private func releaseBuffers() {
    bufferLease?.release()
    bufferLease = nil
    body = []
    pending = nil
  }

  private func arm(
    _ slot: inout Scheduled<Void>?, after duration: Duration,
    _ action: @escaping (RequestHandler) -> Void
  ) {
    slot?.cancel()
    let bound = NIOLoopBound((self, action), eventLoop: eventLoop)
    slot = eventLoop.scheduleTask(in: TimeAmount(duration)) {
      let (handler, action) = bound.value
      action(handler)
    }
  }
}

func milliseconds(_ duration: Duration) -> Int64 {
  duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
}
