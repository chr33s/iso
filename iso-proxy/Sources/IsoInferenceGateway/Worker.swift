import Darwin
import Dispatch
import Foundation
import IsoInferenceCore
import IsoProxyCore
import NIOCore
import Synchronization

/// One session's worker process (§5.1). It binds the session's socket,
/// parses that VM's requests and talks to its backends, under a profile that
/// admits nothing else; another VM's requests, capability and credentials
/// never enter it. The broker's scheduler admits its work over the link,
/// which also carries its audit records, so it writes no file of its own.
package final class SessionWorker: RequestServices, AdmissionService, AuditService,
  JournalService, Sendable
{
  struct State {
    var nextRequest: UInt64 = 1
    var waiters: [UInt64: DispatchSemaphore] = [:]
    var answers: [UInt64: WorkerProtocol.Down] = [:]
    /// Admitted work by ticket, until it settles.
    var works: [UInt64: Scheduler.Work] = [:]
    /// Events for a ticket that arrived before its admission's answer.
    var early: [UInt64: [WorkerProtocol.Down]] = [:]
    var draining = false
  }

  package let session: GatewaySession
  package let timing: GatewayTiming
  package let buffers: ByteBudget
  package let sharedConnections = SlotPool(SessionLimits.sharedConnections)
  package let normalizers = NormalizerPool(threads: 2)
  let liveHandlers = Atomic<Int>(0)
  let policies: [BackendID: BackendPolicy]
  private let link: Int32
  private let writes = Mutex(())
  private let state = Mutex(State())
  static let answerTimeout: DispatchTimeInterval = .seconds(5)

  private init(
    session: GatewaySession, link: Int32, timing: GatewayTiming, requestBufferBytes: Int
  ) {
    self.session = session
    self.link = link
    self.timing = timing
    buffers = ByteBudget(requestBufferBytes)
    policies = Dictionary(
      session.grants.values.map { ($0.backend.id, $0.backend) }, uniquingKeysWith: { a, _ in a })
  }

  /// Connects to the broker, presents the session's key, takes its
  /// configuration and binds the session socket at `socketPath`, whose file
  /// name must be the registration's.
  package static func start(
    broker: String, socketPath: String, sessionID: String, key: String, group: EventLoopGroup,
    timing: GatewayTiming = .standard
  ) throws -> SessionWorker {
    let fd = try connectUnix(broker)
    setTimeouts(fd, seconds: ControlServer.ioTimeoutSeconds)
    writeAll(fd, ControlProtocol.frame(WorkerProtocol.encode(.hello(session: sessionID, key: key))))
    guard let body = readFrame(fd),
      case .config(let config)? = try? WorkerProtocol.decodeDown(ControlProtocol.parseFrame(body)),
      config.sessionID == sessionID,
      socketPath.split(separator: "/").last.map(String.init) == config.registration.socket
    else {
      close(fd)
      throw GatewayError.startup("the broker refused the worker or sent no configuration")
    }
    setTimeouts(fd, seconds: 0)
    let capability: Capability
    do { capability = try Capability(config.capability.expose()) } catch {
      close(fd)
      throw GatewayError.startup("the configuration's capability is malformed")
    }
    let session = GatewaySession(
      id: config.sessionID, registration: config.registration, capability: capability,
      registered: ContinuousClock.now,
      failures: FailureWindow(limit: SessionLimits.authFailuresPerMinute))
    let worker = SessionWorker(
      session: session, link: fd, timing: timing, requestBufferBytes: config.requestBufferBytes)
    BoundSocket.removeStale(socketPath)
    let listener: Channel
    do {
      listener = try SessionListener.bind(
        host: worker, session: session, path: socketPath, group: group
      ).wait()
    } catch {
      close(fd)
      throw GatewayError.startup("cannot bind the session socket")
    }
    // The C path is borrowed for the call only.
    guard unsafe chmod(socketPath, 0o600) == 0, let socket = BoundSocket(path: socketPath) else {
      listener.close(promise: nil)
      close(fd)
      throw GatewayError.startup("cannot restrict the session socket")
    }
    session.state.withLock {
      $0.listener = listener
      $0.socket = socket
    }
    worker.send(.ready)
    return worker
  }

  /// Serves the broker's messages until the link closes: when the broker
  /// goes away the session ends (fail-closed), and after a revocation the
  /// worker closes the link once its requests settle.
  package func run() {
    while let body = readFrame(link) {
      guard let message = try? WorkerProtocol.decodeDown(ControlProtocol.parseFrame(body)) else {
        break
      }
      handle(message)
    }
    revokeLocally("broker-closed", tell: false)
    close(link)
  }

  private func handle(_ message: WorkerProtocol.Down) {
    switch message {
    case .permitted(let id, _), .admitted(let id, _, _), .refused(let id, _),
      .withdrawn(let id, _):
      let waiter = state.withLock { state -> DispatchSemaphore? in
        guard let waiter = state.waiters.removeValue(forKey: id) else { return nil }
        state.answers[id] = message
        return waiter
      }
      waiter?.signal()
    case .dispatch(let ticket), .cancel(let ticket, _):
      let work = state.withLock { state -> Scheduler.Work? in
        guard let work = state.works[ticket] else {
          state.early[ticket, default: []].append(message)
          return nil
        }
        return work
      }
      if let work { deliver(message, to: work) }
    case .activate(let id, let transport, let deadline):
      do {
        try session.bindTransport(transport, deadlineSeconds: deadline) { [weak self] pid in
          self?.transportExited(pid)
        }
        send(.activated(id: id, error: nil))
      } catch {
        send(.activated(id: id, error: error))
      }
    case .revoke(let reason): revokeLocally(reason, tell: false)
    case .config: break
    }
  }

  private func deliver(_ event: WorkerProtocol.Down, to work: Scheduler.Work) {
    switch event {
    case .dispatch(let ticket): work.dispatch(Scheduler.Ticket(id: ticket))
    case .cancel(let ticket, let reason): work.cancel(Scheduler.Ticket(id: ticket), reason)
    default: break
    }
  }

  private func transportExited(_ pid: pid_t) {
    record("transport_exited", ["pid": .int(Int64(pid))])
    revokeLocally("transport-exited", tell: true)
  }

  /// Closes the listener and every connection; the broker cancels the work
  /// it admitted, and once the handlers settle the link closes.
  func revokeLocally(_ reason: String, tell: Bool) {
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
    for watch in watches { watch.cancel() }
    listener?.close(promise: nil)
    socket?.removeIfUnchanged()
    for channel in channels { channel.close(promise: nil) }
    if tell { send(.revoked(reason: reason)) }
    let first = state.withLock { state -> Bool in
      defer { state.draining = true }
      return !state.draining
    }
    guard first else { return }
    // Bounded: a generation's deadline, its cancellation grace and the
    // close deadline.
    let limit = ContinuousClock.now + timing.generation + timing.cancellationGrace + timing.close
    let fd = link
    let live = { [weak self] in self?.liveHandlers.load(ordering: .relaxed) ?? 0 }
    Thread {
      while live() > 0, ContinuousClock.now < limit { usleep(50_000) }
      shutdown(fd, SHUT_RDWR)
    }.start()
  }

  func send(_ message: WorkerProtocol.Up) {
    let frame = ControlProtocol.frame(WorkerProtocol.encode(message))
    writes.withLock { _ in writeAll(link, frame) }
  }

  /// A request to the broker and its answer, or nil after the timeout.
  private func call(_ make: (UInt64) -> WorkerProtocol.Up) -> WorkerProtocol.Down? {
    let waiter = DispatchSemaphore(value: 0)
    let id = state.withLock { state -> UInt64 in
      let id = state.nextRequest
      state.nextRequest += 1
      state.waiters[id] = waiter
      return id
    }
    send(make(id))
    guard waiter.wait(timeout: .now() + Self.answerTimeout) == .success else {
      state.withLock { _ = $0.waiters.removeValue(forKey: id) }
      return nil
    }
    return state.withLock { $0.answers.removeValue(forKey: id) }
  }

  private static let unanswered = InferenceError(
    .backendUnavailable, "the inference broker did not answer")

  // MARK: RequestServices

  package var admission: any AdmissionService { self }
  package var journalService: any JournalService { self }
  package var auditService: any AuditService { self }
  package func handlerCount(_ delta: Int) { liveHandlers.add(delta, ordering: .relaxed) }
  package func backendPolicy(_ id: BackendID) -> BackendPolicy? { policies[id] }

  // MARK: AdmissionService

  package func permit(session name: String) throws(InferenceError) -> Scheduler.Permit {
    switch call({ .permit(id: $0) }) {
    case .permitted(_, let permit)?: return Scheduler.Permit(session: name, remote: permit)
    case .refused(_, let error)?: throw error
    default: throw Self.unanswered
    }
  }

  package func admit(_ work: Scheduler.Work, permit: Scheduler.Permit) throws(InferenceError)
    -> Scheduler.Admission
  {
    let answer = call {
      .admit(id: $0, permit: permit.remote, backend: work.backend, outputTokens: work.outputTokens)
    }
    switch answer {
    case .admitted(_, let ticket, let queued)?:
      let early = state.withLock { state -> [WorkerProtocol.Down] in
        state.works[ticket] = work
        return state.early.removeValue(forKey: ticket) ?? []
      }
      for event in early { deliver(event, to: work) }
      let admitted = Scheduler.Ticket(id: ticket)
      return queued ? .queued(admitted) : .dispatched(admitted)
    case .refused(_, let error)?: throw error
    default: throw Self.unanswered
    }
  }

  @discardableResult
  package func withdraw(_ ticket: Scheduler.Ticket) -> Bool {
    guard case .withdrawn(_, let value)? = call({ .withdraw(id: $0, ticket: ticket.id) }) else {
      return false
    }
    if value { forget(ticket) }
    return value
  }

  package func finish(_ ticket: Scheduler.Ticket, outputTokens: Int?) {
    forget(ticket)
    send(.finish(ticket: ticket.id, outputTokens: outputTokens))
  }

  package func markUncertain(_ ticket: Scheduler.Ticket) {
    forget(ticket)
    send(.uncertain(ticket: ticket.id))
  }

  package func quarantine(_ backend: BackendID, _ reason: Scheduler.QuarantineReason) {
    guard reason == .qualificationFailure else { return }
    send(.qualificationFailure(backend: backend))
  }

  private func forget(_ ticket: Scheduler.Ticket) {
    state.withLock { state in
      state.works[ticket.id] = nil
      state.early[ticket.id] = nil
    }
  }

  // MARK: AuditService

  /// The broker adds the session, and accepts only an allowed event's
  /// allowed fields (``WorkerProtocol/auditEvents``).
  package func record(_ event: String, _ fields: KeyValuePairs<String, JSON>) {
    guard let allowed = WorkerProtocol.auditEvents[event] else { return }
    var object = JSONObject()
    for (key, value) in fields where allowed.contains(key) { object[key] = value }
    send(.audit(event: event, fields: object))
  }

  package func rejected(session: String, code: InferenceErrorCode) {
    send(.rejected(code: code))
  }

  // MARK: JournalService

  /// The broker journals the work it dispatches and settles (§9.2).
  package func dispatched(_ backend: BackendID) throws {}
  package func settled(_ backend: BackendID) {}
}
