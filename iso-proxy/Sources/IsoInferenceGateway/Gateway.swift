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
public final class Gateway: Sendable {
  public static let version = "0.1.0"
  /// An inactive session not activated within this window is revoked.
  static let activationWindow: Duration = .seconds(120)
  /// With no sessions and no outstanding work for this long, the gateway
  /// exits (§5.1).
  static let idleExit: Duration = .seconds(600)

  public let epoch: String
  public let pid = getpid()
  let group: EventLoopGroup
  let scheduler: Scheduler
  let buffers: ByteBudget
  let sharedConnections = SlotPool(SessionLimits.sharedConnections)
  let journal: Journal
  let audit: AuditLog
  let started = ContinuousClock.now
  let sessions = Mutex<[String: GatewaySession]>([:])
  let backends = Mutex<[BackendID: BackendPolicy]>([:])
  let idleSince = Mutex<ContinuousClock.Instant?>(ContinuousClock.now)
  let ticker: Mutex<DispatchSourceTimer?> = Mutex(nil)
  let stopped = Mutex(false)
  let onExit: @Sendable () -> Void
  /// The command name a transport process must have: the instance's
  /// sandbox owner (`iso-sandbox`), whose VM carries the relay. A test seam.
  let transportCommand: String
  /// Backend ports the launch profile allows; nil only in tests.
  let backendPorts: Set<UInt16>?
  /// Where session sockets are bound: the host ends of the instances' vsock
  /// relays (§22). The launch profile allows Unix sockets only here.
  let relayDirectory: String

  public init(
    group: EventLoopGroup, journal: Journal, audit: AuditLog, limits: GlobalLimits = .defaults,
    relayDirectory: String, backendPorts: Set<UInt16>? = nil,
    transportCommand: String = "iso-sandbox", onExit: @escaping @Sendable () -> Void
  ) {
    self.relayDirectory = relayDirectory
    self.backendPorts = backendPorts
    self.transportCommand = transportCommand
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
  public func startTicker(interval: DispatchTimeInterval = .seconds(2)) {
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

  public struct Registered: Sendable {
    public let sessionID: String
    public let socket: String
    public let capability: Secret
    public let policyDigest: String
  }

  public func register(_ registration: ControlProtocol.Registration) throws(InferenceError)
    -> Registered
  {
    try adoptBackends(registration.grants)
    scheduler.tighten(registration.limits)
    buffers.tighten(to: scheduler.limits.maxRequestBufferBytes)
    // One session per instance: a new registration replaces the old one.
    for old in sessions.withLock({ $0.values.filter { $0.instance == registration.instance } }) {
      revoke(old, reason: "replaced")
    }
    let token = randomHex(32)
    let capability: Capability
    do { capability = try Capability(token) } catch {
      throw InferenceError(.backendUnavailable, "capability generation failed")
    }
    let session = GatewaySession(
      id: randomHex(16), registration: registration, capability: capability,
      registered: ContinuousClock.now)
    let path = relayDirectory + "/" + registration.socket
    let listener: Channel
    do {
      listener = try SessionListener.bind(gateway: self, session: session, path: path, group: group)
        .wait()
    } catch {
      throw InferenceError(.backendUnavailable, "cannot bind a session socket")
    }
    guard chmod(path, 0o600) == 0 else {
      listener.close(promise: nil)
      throw InferenceError(.backendUnavailable, "cannot restrict the session socket")
    }
    session.state.withLock {
      $0.listener = listener
      $0.socketPath = path
    }
    sessions.withLock { $0[session.id] = session }
    scheduler.addSession(session.id)
    audit.record(
      "session_registered",
      [
        "session": .string(session.id), "instance": .string(registration.instance.name),
        "aliases": .array(registration.grants.map(\.alias).sorted().map(JSON.string)),
        "policy_digest": .string(session.policyDigest),
      ])
    return Registered(
      sessionID: session.id, socket: registration.socket, capability: Secret(token),
      policyDigest: session.policyDigest)
  }

  /// Backends are identified by port. A second registration naming the same
  /// port must agree on the qualification profile; its concurrency limit can
  /// only tighten the shared one.
  func adoptBackends(_ grants: [ServiceGrant]) throws(InferenceError) {
    if let allowed = backendPorts,
      let outside = grants.first(where: { !allowed.contains($0.backend.id.port) })
    {
      throw InferenceError(
        .backendUnavailable,
        "backend \(outside.backend.id) is outside this gateway's confinement; restart the gateway"
      )
    }
    let conflict: InferenceError? = backends.withLock { known in
      for grant in grants {
        let incoming = grant.backend
        if let existing = known[incoming.id] {
          guard existing.profile == incoming.profile,
            existing.credential?.expose() == incoming.credential?.expose()
          else {
            return InferenceError(
              .modelUnqualified,
              "backend \(incoming.id) is already registered with a different qualification profile or credential"
            )
          }
          if incoming.maxActive < existing.maxActive { known[incoming.id] = incoming }
        } else {
          known[incoming.id] = incoming
        }
      }
      return nil
    }
    if let conflict { throw conflict }
  }

  func backendPolicy(_ id: BackendID) -> BackendPolicy? { backends.withLock { $0[id] } }

  public func activate(_ activation: ControlProtocol.Activation) throws(InferenceError) {
    guard activation.epoch == epoch else {
      throw InferenceError(.sessionRevoked, "the gateway restarted; register again")
    }
    guard let session = sessions.withLock({ $0[activation.sessionID] }),
      session.phase == .inactive
    else { throw InferenceError(.sessionRevoked, "no inactive session with that id") }
    let binding = activation.transport
    guard isTransport(binding) else {
      throw InferenceError(.policyDenied, "the transport process does not match")
    }
    let source = DispatchSource.makeProcessSource(
      identifier: binding.pid, eventMask: .exit, queue: .global())
    source.setEventHandler { [weak self, weak session] in
      guard let self, let session else { return }
      self.audit.record("transport_exited", ["session": .string(session.id)])
      self.revoke(session, reason: "transport-exited")
    }
    source.resume()
    // The process may have exited before the source was armed.
    guard isTransport(binding) else {
      source.cancel()
      revoke(session, reason: "transport-exited")
      throw InferenceError(.policyDenied, "the transport process exited")
    }
    let deadline = activation.deadlineSeconds.map { ContinuousClock.now + .seconds($0) }
    let activated = session.state.withLock { state -> Bool in
      guard state.phase == .inactive else { return false }
      state.phase = .active
      state.transport = binding
      state.deadline = deadline
      state.watch = source
      return true
    }
    guard activated else {
      source.cancel()
      throw InferenceError(.sessionRevoked, "the session was revoked")
    }
    audit.record(
      "session_activated",
      [
        "session": .string(session.id), "transport_pid": .int(Int64(binding.pid)),
        "deadline_seconds": activation.deadlineSeconds.map { .int($0) } ?? .null,
      ])
  }

  func isTransport(_ binding: TransportBinding) -> Bool {
    guard let identity = ProcessIdentity.of(binding.pid) else { return false }
    return identity.command == transportCommand && identity.uid == getuid()
      && identity.start == binding.start
  }

  @discardableResult
  public func revoke(_ revocation: ControlProtocol.Revocation) -> Int {
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
    let taken = session.state.withLock { state -> (Channel?, DispatchSourceProcess?, [Channel])? in
      guard !isRevoked(state.phase) else { return nil }
      state.phase = .revoked(reason)
      defer {
        state.listener = nil
        state.watch = nil
      }
      return (state.listener, state.watch, Array(state.channels.values))
    }
    guard let (listener, watch, channels) = taken else { return }
    sessions.withLock { _ = $0.removeValue(forKey: session.id) }
    watch?.cancel()
    scheduler.removeSession(session.id, reason: .sessionRevoked)
    // The socket file stays: a closed listener refuses the relay's
    // connections, and the instance's next registration replaces the file.
    // Unlinking here could race that registration, which reuses the name.
    listener?.close(promise: nil)
    for channel in channels { channel.close(promise: nil) }
    audit.record("session_revoked", ["session": .string(session.id), "reason": .string(reason)])
  }

  public func requalify(_ backend: BackendID) throws(InferenceError) {
    try scheduler.requalify(backend)
    journal.clear(backend)
    audit.record("backend_requalified", ["backend": .int(Int64(backend.port))])
  }

  /// Revoke every session ahead of `stop`. Refused while sessions are
  /// active unless forced.
  public func prepareShutdown(force: Bool) throws(InferenceError) {
    let live = sessions.withLock { Array($0.values) }
    guard force || live.isEmpty else {
      throw InferenceError(
        .backendUnavailable, "\(live.count) session(s) are active; pass --force to revoke them")
    }
    for session in live { revoke(session, reason: "gateway-shutdown") }
    audit.record("gateway_shutdown")
  }

  public func stop() {
    let first = stopped.withLock { stopped -> Bool in
      defer { stopped = true }
      return !stopped
    }
    guard first else { return }
    ticker.withLock { $0?.cancel() }
    onExit()
  }

  public func inspect(_ instance: ControlProtocol.InstanceKey?) -> JSONObject {
    let now = ContinuousClock.now
    let live = sessions.withLock { Array($0.values) }
      .filter { instance == nil || $0.instance == instance }
      .sorted { $0.id < $1.id }
    let sessionList: [JSON] = live.map { session in
      let (phase, socket, transport, deadline) = session.state.withLock {
        ($0.phase, $0.socketPath, $0.transport, $0.deadline)
      }
      return .object(
        JSONObject([
          "session_id": .string(session.id), "state": .string(phase.name),
          "instance": .object(
            JSONObject([
              "data_root": .string(session.instance.dataRoot),
              "name": .string(session.instance.name),
            ])),
          "socket": socket.map { .string(String($0.split(separator: "/").last ?? "")) } ?? .null,
          "nonce": .string(session.nonce),
          "policy_digest": .string(session.policyDigest),
          "aliases": .array(session.grants.keys.sorted().map(JSON.string)),
          "apis": .array(session.apis.map(\.rawValue).sorted().map(JSON.string)),
          "transport_pid": transport.map { .int(Int64($0.pid)) } ?? .null,
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
  arc4random_buf(&buffer, bytes)
  return ControlProtocol.hex(buffer)
}

/// Binds one session's Unix socket in the relay directory and keeps it for
/// the session's lifetime (§22). The instance's sandbox owner relays guest
/// connections to it over vsock; nothing listens on TCP.
enum SessionListener {
  static func bind(gateway: Gateway, session: GatewaySession, path: String, group: EventLoopGroup)
    -> EventLoopFuture<Channel>
  {
    ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: Int32(SessionLimits.connections))
      .childChannelOption(ChannelOptions.autoRead, value: true)
      .childChannelOption(
        ChannelOptions.recvAllocator, value: FixedSizeRecvByteBufferAllocator(capacity: 16 * 1024)
      )
      .childChannelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
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
            RequestHandler(gateway: gateway, session: session, wireBudget: wireBudget),
          ])
        }
      }
      .bind(unixDomainSocketPath: path, cleanupExistingSocketFile: true)
  }
}
