import Darwin
import Dispatch
import IsoInferenceCore
import IsoProxyCore
import IsoProxyTransport
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization

/// The per-user inference gateway (§5.1): session listeners, the shared
/// scheduler and budgets, and the control operations. Control operations
/// block and must not run on an event loop.
package final class Gateway: Sendable {
  package static let version = "0.1.0"
  /// An inactive session not activated within this window is revoked.
  static let activationWindow: Duration = .seconds(120)
  /// With no sessions and no outstanding work for this long, the gateway
  /// exits (§5.1).
  static let idleExit: Duration = .seconds(600)

  package let epoch: String
  package let pid = getpid()
  let group: EventLoopGroup
  package let scheduler: Scheduler
  package let buffers: ByteBudget
  package let sharedConnections: SlotPool
  let journal: Journal
  package let audit: AuditLog
  package let timing: GatewayTiming
  package let normalizers = NormalizerPool(threads: 2)
  /// Live request handlers, for the leak tests and diagnostics.
  package let liveHandlers = Atomic<Int>(0)
  /// Serializes binding and removing session socket files (§22.4).
  let sockets = Mutex(())
  let started = ContinuousClock.now
  package let sessions = Mutex<[String: GatewaySession]>([:])
  let backends = Mutex<[BackendID: BackendPolicy]>([:])
  let idleSince = Mutex<ContinuousClock.Instant?>(ContinuousClock.now)
  let ticker: Mutex<DispatchSourceTimer?> = Mutex(nil)
  let stopped = Mutex(false)
  let onExit: @Sendable () -> Void
  /// Backend ports the launch profile allows; nil only in tests.
  let backendPorts: Set<UInt16>?
  /// Where session sockets are bound: the host ends of the instances' vsock
  /// relays (§22). The launch profile allows Unix sockets only here.
  let relayDirectory: String
  /// The broker's session workers (§5.1): with them, this process binds no
  /// session socket and parses no guest bytes; each session's worker does.
  /// nil runs every session in this process (tests).
  package let workers: WorkerRegistry?

  package init(
    group: EventLoopGroup, journal: Journal, audit: AuditLog, limits: GlobalLimits = .defaults,
    relayDirectory: String, backendPorts: Set<UInt16>? = nil,
    timing: GatewayTiming = .standard,
    sharedConnections: Int = SessionLimits.sharedConnections, workers: WorkerRegistry? = nil,
    onExit: @escaping @Sendable () -> Void
  ) {
    self.workers = workers
    self.timing = timing
    self.sharedConnections = SlotPool(sharedConnections)
    self.relayDirectory = relayDirectory
    self.backendPorts = backendPorts
    self.group = group
    self.journal = journal
    self.audit = audit
    self.onExit = onExit
    scheduler = Scheduler(limits: limits)
    buffers = ByteBudget(limits.maxRequestBufferBytes)
    epoch = randomHex(16)
    for backend in journal.unresolved() {
      scheduler.quarantine(backend, .crashJournal)
      audit.record(
        "backend_quarantined",
        ["backend": .int(Int64(backend.port)), "reason": .string("crash-journal")])
    }
  }

  /// Start the deadline, activation-window and idle checks. They compare
  /// `ContinuousClock` instants, which keep counting while the host sleeps.
  package func startTicker(interval: DispatchTimeInterval = .seconds(2)) {
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + interval, repeating: interval)
    timer.setEventHandler { [weak self] in self?.tick() }
    timer.resume()
    ticker.withLock { $0 = timer }
  }

  func tick() {
    let now = ContinuousClock.now
    let snapshot = sessions.withLock { Array($0.values) }
    for session in snapshot {
      let (phase, deadline) = session.state.withLock { ($0.phase, $0.deadline) }
      if phase == .inactive, now - session.registered >= Self.activationWindow {
        revoke(session, reason: "activation-timeout")
      } else if phase == .active, let deadline, now >= deadline {
        revoke(session, reason: "session-deadline")
      }
    }
    audit.flush()
    let idle = sessions.withLock { $0.isEmpty } && !scheduler.hasWork
    let exit = idleSince.withLock { since -> Bool in
      guard idle else {
        since = nil
        return false
      }
      if since == nil { since = now }
      return now - since! >= Self.idleExit
    }
    if exit {
      audit.record("gateway_idle_exit")
      stop()
    }
  }

  // MARK: Control operations

  package struct Registered: Sendable {
    package let sessionID: String
    package let socket: String
    package let capability: Secret
    package let policyDigest: String
    /// The one-time key the session's worker presents (broker only).
    package var workerKey: Secret? = nil
  }

  package func register(_ registration: ControlProtocol.Registration) throws(InferenceError)
    -> Registered
  {
    try checkBackends(registration.grants)
    let live = sessions.withLock { Array($0.values) }
    // A socket name is the runtime's hash of one instance's sandbox: another
    // instance's live session never gives it up (§22.4).
    if live.contains(where: {
      $0.socketName == registration.socket && $0.instance != registration.instance
    }) {
      throw InferenceError(.policyDenied, "the session socket belongs to another instance")
    }
    // One session per instance: a new registration replaces the old one.
    for old in live where old.instance == registration.instance {
      revoke(old, reason: "replaced")
    }
    let token = randomHex(32)
    let capability: Capability
    do { capability = try Capability(token) } catch {
      throw InferenceError(.backendUnavailable, "capability generation failed")
    }
    let session = GatewaySession(
      id: randomHex(16), registration: registration, capability: capability,
      registered: ContinuousClock.now,
      failures: FailureWindow(limit: SessionLimits.authFailuresPerMinute))
    if workers != nil {
      // The session's worker binds the socket; nothing guest-facing here.
      try adoptBackends(registration.grants)
    } else {
      let (listener, socket) = try bind(session, name: registration.socket)
      do { try adoptBackends(registration.grants) } catch {
        listener.close(promise: nil)
        removeSocket(socket)
        throw error
      }
      session.state.withLock {
        $0.listener = listener
        $0.socket = socket
      }
    }
    scheduler.tighten(registration.limits)
    buffers.tighten(to: scheduler.limits.maxRequestBufferBytes)
    let workerKey = workers?.expect(
      session.id, registration: registration, capability: Secret(token))
    sessions.withLock { $0[session.id] = session }
    scheduler.addSession(session.id)
    audit.record(
      "session_registered",
      [
        "session": .string(session.id), "instance": .string(registration.instance.name),
        "aliases": .array(registration.grants.map(\.alias).sorted().map(JSON.string)),
        "policy_digest": .string(session.policyDigest),
        "transport_kind": .string(registration.transport.rawValue),
      ])
    var registered = Registered(
      sessionID: session.id, socket: registration.socket, capability: Secret(token),
      policyDigest: session.policyDigest)
    registered.workerKey = workerKey
    return registered
  }

  /// Binds the session socket (`0600`) and records which file it is, so
  /// revocation removes that file and no later one.
  private func bind(_ session: GatewaySession, name: String) throws(InferenceError) -> (
    Channel, BoundSocket
  ) {
    let path = relayDirectory + "/" + name
    let result: Result<(Channel, BoundSocket), InferenceError> = sockets.withLock { _ in
      let listener: Channel
      do {
        listener = try SessionListener.bind(
          host: self, session: session, path: path, group: group
        ).wait()
      } catch {
        return .failure(InferenceError(.backendUnavailable, "cannot bind a session socket"))
      }
      // The C path is borrowed for the call only.
      guard unsafe chmod(path, 0o600) == 0, let socket = BoundSocket(path: path) else {
        listener.close(promise: nil)
        return .failure(InferenceError(.backendUnavailable, "cannot restrict the session socket"))
      }
      return .success((listener, socket))
    }
    return try result.get()
  }

  /// Unlinks the session's socket file if it is still the one it bound.
  func removeSocket(_ socket: BoundSocket) {
    sockets.withLock { _ in socket.removeIfUnchanged() }
  }

  /// Backends must be in the launch profile's port list, and a port already
  /// registered must keep its qualification profile and credential.
  func checkBackends(_ grants: [ServiceGrant]) throws(InferenceError) {
    if let allowed = backendPorts,
      let outside = grants.first(where: { !allowed.contains($0.backend.id.port) })
    {
      throw InferenceError(
        .backendUnavailable,
        "backend \(outside.backend.id) is outside this gateway's confinement; restart the gateway"
      )
    }
    let known = backends.withLock { $0 }
    if let conflict = Self.merged(known, grants).error { throw conflict }
  }

  /// Backends are identified by port. A second registration naming the same
  /// port must agree on the qualification profile; its concurrency limit can
  /// only tighten the shared one. All grants are adopted, or none.
  func adoptBackends(_ grants: [ServiceGrant]) throws(InferenceError) {
    let conflict: InferenceError? = backends.withLock { known in
      let merged = Self.merged(known, grants)
      if merged.error == nil { known = merged.backends }
      return merged.error
    }
    if let conflict { throw conflict }
  }

  /// `known` with `grants` adopted, or the first conflict (with the grants
  /// before it adopted, which callers then discard).
  static func merged(_ known: [BackendID: BackendPolicy], _ grants: [ServiceGrant]) -> (
    backends: [BackendID: BackendPolicy], error: InferenceError?
  ) {
    var result = known
    for grant in grants {
      let incoming = grant.backend
      if let existing = result[incoming.id] {
        guard existing.profile == incoming.profile,
          existing.credential?.expose() == incoming.credential?.expose(),
          existing.front == incoming.front
        else {
          return (
            result,
            InferenceError(
              .modelUnqualified,
              "backend \(incoming.id) is already registered with a different qualification profile, credential or front end"
            )
          )
        }
        if incoming.maxActive < existing.maxActive { result[incoming.id] = incoming }
      } else {
        result[incoming.id] = incoming
      }
    }
    return (result, nil)
  }

  package func backendPolicy(_ id: BackendID) -> BackendPolicy? { backends.withLock { $0[id] } }

  package func activate(_ activation: ControlProtocol.Activation) throws(InferenceError) {
    guard activation.epoch == epoch else {
      throw InferenceError(.sessionRevoked, "the gateway restarted; register again")
    }
    guard let session = sessions.withLock({ $0[activation.sessionID] }),
      session.phase == .inactive
    else { throw InferenceError(.sessionRevoked, "no inactive session with that id") }
    let binding = activation.transport
    if let workers {
      // The worker binds its socket and transport; the broker records the
      // session as active once it answers.
      try session.checkTransportKind(binding)
      guard let link = workers.readyLink(session.id) else {
        throw InferenceError(.backendUnavailable, "the session's worker did not start")
      }
      try link.activate(
        binding, deadlineSeconds: activation.deadlineSeconds, timeout: workers.attachTimeout)
      guard session.markActive(binding, deadlineSeconds: activation.deadlineSeconds) else {
        throw InferenceError(.sessionRevoked, "the session was revoked")
      }
    } else {
      try session.bindTransport(binding, deadlineSeconds: activation.deadlineSeconds) {
        [weak self, weak session] pid in
        guard let self, let session else { return }
        self.audit.record(
          "transport_exited", ["session": .string(session.id), "pid": .int(Int64(pid))])
        self.revoke(session, reason: "transport-exited")
      }
    }
    audit.record(
      "session_activated",
      [
        "session": .string(session.id), "transport_pid": .int(Int64(binding.pid)),
        "transport_kind": .string(session.transportKind.rawValue),
        "deadline_seconds": activation.deadlineSeconds.map { .int($0) } ?? .null,
      ])
  }

  @discardableResult
  package func revoke(_ revocation: ControlProtocol.Revocation) -> Int {
    let targets = sessions.withLock { sessions -> [GatewaySession] in
      switch revocation {
      case .session(let id): sessions[id].map { [$0] } ?? []
      case .instance(let key): sessions.values.filter { $0.instance == key }
      }
    }
    for session in targets { revoke(session, reason: "host-revoked") }
    return targets.count
  }

  /// Disable admission, drop queued work, cancel active work, close the
  /// listener and every connection. Idempotent.
  func revoke(_ session: GatewaySession, reason: String) {
    let taken = session.state.withLock {
      state -> (Channel?, [ExitWatch], BoundSocket?, [Channel])? in
      guard !isRevoked(state.phase) else { return nil }
      state.phase = .revoked(reason)
      defer {
        state.listener = nil
        state.watches = []
        state.socket = nil
      }
      return (state.listener, state.watches, state.socket, Array(state.channels.values))
    }
    guard let (listener, watches, socket, channels) = taken else { return }
    sessions.withLock { _ = $0.removeValue(forKey: session.id) }
    for watch in watches { watch.cancel() }
    workers?.revoke(session.id, reason: reason)
    scheduler.removeSession(session.id, reason: .sessionRevoked)
    listener?.close(promise: nil)
    // Removed only while it is still this session's file: a registration
    // that reuses the name binds under the same lock and gets a new file.
    if let socket { removeSocket(socket) }
    for channel in channels { channel.close(promise: nil) }
    audit.record("session_revoked", ["session": .string(session.id), "reason": .string(reason)])
  }

  /// A worker's link closed: the work it still held has no evidence and
  /// quarantines its backend, and its session ends.
  func workerExited(_ link: WorkerLink, holding held: [(Scheduler.Ticket, BackendID)]) {
    let active = Set(scheduler.activeTickets(session: link.session))
    for (ticket, backend) in held where active.contains(ticket) {
      scheduler.markUncertain(ticket)
      audit.record(
        "backend_quarantined",
        [
          "backend": .int(Int64(backend.port)), "reason": .string("uncertain-cancellation"),
          "detail": .string("worker-exited"),
        ])
    }
    if let session = sessions.withLock({ $0[link.session] }) {
      revoke(session, reason: "worker-exited")
    }
    workers?.remove(link.session, link: link)
  }

  /// The worker revoked its session itself (its transport exited).
  func revokeFromWorker(_ id: String, reason: String) {
    guard let session = sessions.withLock({ $0[id] }) else { return }
    revoke(session, reason: reason)
  }

  package func requalify(_ backend: BackendID) throws(InferenceError) {
    try scheduler.requalify(backend)
    journal.clear(backend)
    audit.record("backend_requalified", ["backend": .int(Int64(backend.port))])
  }

  /// Revoke every session ahead of `stop`. Refused while sessions are
  /// active unless forced.
  package func prepareShutdown(force: Bool) throws(InferenceError) {
    let live = sessions.withLock { Array($0.values) }
    guard force || live.isEmpty else {
      throw InferenceError(
        .backendUnavailable, "\(live.count) session(s) are active; pass --force to revoke them")
    }
    for session in live { revoke(session, reason: "gateway-shutdown") }
    audit.record("gateway_shutdown")
  }

  package func stop() {
    let first = stopped.withLock { stopped -> Bool in
      defer { stopped = true }
      return !stopped
    }
    guard first else { return }
    ticker.withLock { $0?.cancel() }
    normalizers.stop()
    onExit()
  }

  package func inspect(_ instance: ControlProtocol.InstanceKey?) -> JSONObject {
    let now = ContinuousClock.now
    let live = sessions.withLock { Array($0.values) }
      .filter { instance == nil || $0.instance == instance }
      .sorted { $0.id < $1.id }
    let sessionList: [JSON] = live.map { session in
      let (phase, transport, deadline) = session.state.withLock {
        ($0.phase, $0.transport, $0.deadline)
      }
      let worker = workers?.info(session.id)
      return .object(
        JSONObject([
          "session_id": .string(session.id), "state": .string(phase.name),
          "instance": .object(
            JSONObject([
              "data_root": .string(session.instance.dataRoot),
              "name": .string(session.instance.name),
            ])),
          "socket": .string(session.socketName),
          "worker": worker.map { .string($0.state) } ?? .null,
          "worker_pid": worker?.pid.map { .int(Int64($0)) } ?? .null,
          "nonce": .string(session.nonce),
          "policy_digest": .string(session.policyDigest),
          "aliases": .array(session.grants.keys.sorted().map(JSON.string)),
          "apis": .array(session.apis.map(\.rawValue).sorted().map(JSON.string)),
          "transport_kind": .string(session.transportKind.rawValue),
          "transport_pid": transport.map { .int(Int64($0.pid)) } ?? .null,
          "connections": .int(
            Int64(session.connections.capacity - session.connections.available)),
          "deadline_seconds": deadline.map { .int(max(0, ($0 - now).components.seconds)) } ?? .null,
        ]))
    }
    let statuses = Dictionary(
      uniqueKeysWithValues: scheduler.backendStatus().map { ($0.id, $0) })
    let policies = backends.withLock { $0 }
    let backendList: [JSON] = policies.keys.sorted().map { id in
      let policy = policies[id]!
      let status = statuses[id]
      return .object(
        JSONObject([
          "backend": .string(id.description), "name": .string(policy.name),
          "max_active": .int(Int64(policy.maxActive)),
          "front": .string(policy.front.rawValue),
          "qualification_profile": .string(policy.profile.name),
          "protocol": .string(policy.profile.backendProtocol.rawValue),
          "completion_evidence": .string(policy.profile.evidence.rawValue),
          "context_overflow": .string(policy.profile.contextOverflow.rawValue),
          "backend_cancellation_verified": .bool(
            policy.profile.evidence == .drain || policy.profile.evidence == .streamClose),
          // Attached backends run unconfined as far as iso knows (§10).
          "backend_isolation_verified": .bool(false),
          "active": .int(Int64(status?.active ?? 0)), "queued": .int(Int64(status?.queued ?? 0)),
          "uncertain": .int(Int64(status?.uncertain ?? 0)),
          "quarantine": status?.quarantine.map { .string($0.rawValue) } ?? .null,
        ]))
    }
    let limits = scheduler.limits
    return JSONObject([
      "gateway": .object(
        JSONObject([
          "pid": .int(Int64(pid)), "epoch": .string(epoch), "version": .string(Self.version),
          "protocol": .int(ControlProtocol.version),
          "uptime_seconds": .int((now - started).components.seconds),
          "gateway_enforced": .bool(true),
          "gateway_egress_ports": backendPorts.map {
            .array($0.sorted().map { .int(Int64($0)) })
          } ?? .null,
          "limits": .object(
            JSONObject([
              "max_active_requests": .int(Int64(limits.maxActiveRequests)),
              "max_queued_requests": .int(Int64(limits.maxQueuedRequests)),
              "max_request_buffer_bytes": .int(Int64(limits.maxRequestBufferBytes)),
              "connections_per_session": .int(Int64(SessionLimits.connections)),
              "shared_connections": .int(Int64(sharedConnections.capacity)),
              "request_buffer_bytes_per_session": .int(
                Int64(SessionLimits.requestBufferBytesPerSession)),
              "queued_per_session": .int(Int64(SessionLimits.queuedPerSession)),
              "requests_per_minute": .int(Int64(SessionLimits.requestsPerMinute)),
              "generated_tokens_per_minute": .int(Int64(SessionLimits.generatedTokensPerMinute)),
              "queue_wait_seconds": .int(Int64(SessionLimits.queueWaitSeconds)),
              "generation_seconds": .int(Int64(SessionLimits.generationSeconds)),
            ])),
        ])),
      "sessions": .array(sessionList), "backends": .array(backendList),
    ])
  }
}

/// Lowercase hex from the system CSPRNG (`arc4random_buf`).
func randomHex(_ bytes: Int) -> String {
  var buffer = [UInt8](repeating: 0, count: bytes)
  // arc4random_buf fills exactly `bytes` bytes of the buffer of that size.
  unsafe arc4random_buf(&buffer, bytes)
  return ControlProtocol.hex(buffer)
}

/// Binds one session's Unix socket in the relay directory and keeps it for
/// the session's lifetime (§22). The instance's sandbox owner relays guest
/// connections to it over vsock, or iso's `ssh` reverse forward connects
/// them (§22.9); nothing listens on TCP.
package enum SessionListener {
  /// The session socket's listen backlog. Connections over the session's
  /// 16 are closed unread, so at most 16 are accepted at once.
  /// - owner: the runtime relays up to 32 guest connections per session
  ///   (§22.3, R2); a smaller backlog would refuse simultaneous dials the
  ///   relay still counts.
  /// - forward: nothing else caps the host `ssh`, so the backlog is what
  ///   keeps 16 accepted plus those pending within 32 (§22.9). A dial over
  ///   it is refused, and `ssh` closes that guest channel.
  package static func backlog(_ kind: TransportKind) -> Int32 {
    switch kind {
    case .owner: Int32(SessionLimits.relayedConnections)
    case .forward: Int32(SessionLimits.forwardedConnections - SessionLimits.connections)
    }
  }

  static func bind(
    host: any RequestServices, session: GatewaySession, path: String, group: EventLoopGroup
  ) -> EventLoopFuture<Channel> {
    ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: backlog(session.transportKind))
      .childChannelOption(ChannelOptions.autoRead, value: true)
      .childChannelOption(
        ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16 * 1024)
      )
      .childChannelInitializer { channel in
        // Only the bound transport process may connect (§12.3): the peer
        // token of every connection must name it, as this user.
        PeerIdentity.of(channel).flatMapThrowing { peer in
          guard let peer, session.admits(peer) else {
            host.auditService.rejected(session: session.id, code: .policyDenied)
            throw InferenceError(.policyDenied, "the connection is not from the bound transport")
          }
          var limits = NIOHTTPDecoderLimitConfiguration()
          limits.maxHeaderFieldSize = SessionLimits.headerBytes
          limits.maxHeaderListSize = SessionLimits.headerBytes
          limits.maxHeaderFieldCount = SessionLimits.headerFields
          let wireBudget = HeaderWireBudget(
            budget: SessionLimits.headerBytes + SessionLimits.headerFields * 4 + 64)
          try channel.pipeline.syncOperations.addHandlers([
            wireBudget,
            HTTPResponseEncoder(),
            ByteToMessageHandler(
              HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes, limitConfiguration: limits)),
            RequestHandler(
              host: host, session: session, wireBudget: wireBudget,
              eventLoop: channel.eventLoop),
          ])
        }
      }
      .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true)
  }
}

extension Gateway: RequestServices {
  package var admission: any AdmissionService { scheduler }
  package var journalService: any JournalService { journal }
  package var auditService: any AuditService { audit }
  package func handlerCount(_ delta: Int) {
    liveHandlers.add(delta, ordering: .relaxed)
  }
}
