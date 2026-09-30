import Synchronization

/// Why queued or active work was told to stop.
public enum CancelReason: Sendable, Equatable {
  case sessionRevoked
  case backendQuarantined
  case shutdown
}

/// The one authoritative admission ledger for every session listener
/// (§9.1, INV-07). Admission is atomic across sessions and backends.
/// Active slots are released only by `finish` — completion evidence —
/// never because a client went away; a slot whose evidence never arrives
/// stays held while its backend is quarantined.
public final class Scheduler: Sendable {
  public struct Ticket: Sendable, Hashable, CustomStringConvertible {
    public let id: UInt64
    public var description: String { "request-\(id)" }
  }

  public struct Work: Sendable {
    public let session: String
    public let backend: BackendID
    public let backendMaxActive: Int
    public let outputTokens: Int
    /// Called once, outside the lock, when the work may start upstream.
    public let dispatch: @Sendable () -> Void
    /// Called at most once, outside the lock. Queued work is already
    /// removed; active work keeps its slot until `finish`.
    public let cancel: @Sendable (CancelReason) -> Void

    public init(
      session: String, backend: BackendID, backendMaxActive: Int, outputTokens: Int,
      dispatch: @escaping @Sendable () -> Void, cancel: @escaping @Sendable (CancelReason) -> Void
    ) {
      self.session = session
      self.backend = backend
      self.backendMaxActive = backendMaxActive
      self.outputTokens = outputTokens
      self.dispatch = dispatch
      self.cancel = cancel
    }
  }

  public enum Admission: Sendable, Equatable {
    case dispatched(Ticket)
    case queued(Ticket)
  }

  public enum QuarantineReason: String, Sendable {
    /// Cancellation evidence did not arrive in time; clears itself when
    /// every uncertain request later completes.
    case uncertainCancellation = "uncertain-cancellation"
    /// Unresolved work from a previous gateway process.
    case crashJournal = "crash-journal"
    /// Reported usage exceeded the qualified input bound.
    case qualificationFailure = "qualification-failure"
  }

  public struct BackendStatus: Sendable, Equatable {
    public let id: BackendID
    public let active: Int
    public let queued: Int
    public let uncertain: Int
    public let quarantine: QuarantineReason?
  }

  struct Entry {
    let ticket: Ticket
    let work: Work
    let enqueued: ContinuousClock.Instant
  }

  struct SessionLedger {
    var tokens: Double = Double(SessionLimits.requestBurst)
    var refilled: ContinuousClock.Instant
    /// Generated-token reservations in the rolling minute.
    var reservations: [(ticket: UInt64, at: ContinuousClock.Instant, tokens: Int)] = []
    var queue: [Entry] = []
  }

  struct BackendLedger {
    var active: Set<Ticket> = []
    var uncertain: Set<Ticket> = []
    var quarantine: QuarantineReason?
  }

  struct State {
    var limits: GlobalLimits
    var nextID: UInt64 = 1
    var sessions: [String: SessionLedger] = [:]
    var order: [String] = []
    var cursor = 0
    var backends: [BackendID: BackendLedger] = [:]
    var active: [Ticket: Work] = [:]
    var queuedCount = 0
  }

  private let state: Mutex<State>
  private let now: @Sendable () -> ContinuousClock.Instant

  public init(
    limits: GlobalLimits,
    now: @escaping @Sendable () -> ContinuousClock.Instant = {
      ContinuousClock.now
    }
  ) {
    state = Mutex(State(limits: limits))
    self.now = now
  }

  public var limits: GlobalLimits { state.withLock { $0.limits } }

  public func tighten(_ limits: GlobalLimits) {
    state.withLock { $0.limits = $0.limits.tightened(by: limits) }
  }

  public func addSession(_ session: String) {
    let instant = now()
    state.withLock { state in
      guard state.sessions[session] == nil else { return }
      state.sessions[session] = SessionLedger(refilled: instant)
      state.order.append(session)
    }
  }

  /// Admit work or reject it without side effects on the ledger.
  public func admit(_ work: Work) throws(InferenceError) -> Admission {
    let instant = now()
    let result: Result<(Admission, [Entry]), InferenceError> = state.withLock { state in
      guard var session = state.sessions[work.session] else {
        return .failure(InferenceError(.sessionRevoked, "session is not active"))
      }
      if let reason = state.backends[work.backend]?.quarantine {
        return .failure(
          InferenceError(
            .backendQuarantined, "backend \(work.backend) is quarantined (\(reason.rawValue))"))
      }
      Self.refill(&session, at: instant)
      guard session.tokens >= 1 else {
        return .failure(InferenceError(.capacity, "request rate limit reached"))
      }
      session.reservations.removeAll { instant - $0.at >= .seconds(60) }
      let reserved = session.reservations.reduce(0) { $0 + $1.tokens }
      guard reserved + work.outputTokens <= SessionLimits.generatedTokensPerMinute else {
        return .failure(InferenceError(.capacity, "generated-token allowance exhausted"))
      }
      let ticket = Ticket(id: state.nextID)
      let canRun = Self.hasCapacity(state, work.backend, work.backendMaxActive)
      if !canRun {
        guard session.queue.count < SessionLimits.queuedPerSession else {
          return .failure(InferenceError(.capacity, "session queue is full"))
        }
        guard state.queuedCount < state.limits.maxQueuedRequests else {
          return .failure(InferenceError(.capacity, "gateway queue is full"))
        }
      }
      state.nextID += 1
      session.tokens -= 1
      session.reservations.append((ticket.id, instant, work.outputTokens))
      let entry = Entry(ticket: ticket, work: work, enqueued: instant)
      if canRun {
        state.sessions[work.session] = session
        Self.activate(&state, entry)
        if let index = state.order.firstIndex(of: work.session) {
          state.cursor = (index + 1) % state.order.count
        }
        return .success((.dispatched(ticket), [entry]))
      }
      session.queue.append(entry)
      state.sessions[work.session] = session
      state.queuedCount += 1
      return .success((.queued(ticket), []))
    }
    let (admission, started) = try result.get()
    for entry in started { entry.work.dispatch() }
    return admission
  }

  /// Completion evidence arrived: release the slot and reconcile the
  /// generated-token reservation with reported usage.
  public func finish(_ ticket: Ticket, outputTokens: Int?) {
    let started = state.withLock { state -> [Entry] in
      guard let work = state.active.removeValue(forKey: ticket) else { return [] }
      var backend = state.backends[work.backend] ?? BackendLedger()
      backend.active.remove(ticket)
      backend.uncertain.remove(ticket)
      if backend.uncertain.isEmpty, backend.quarantine == .uncertainCancellation {
        backend.quarantine = nil
      }
      state.backends[work.backend] = backend
      if let outputTokens, var session = state.sessions[work.session],
        let index = session.reservations.firstIndex(where: { $0.ticket == ticket.id })
      {
        session.reservations[index].tokens = min(outputTokens, session.reservations[index].tokens)
        state.sessions[work.session] = session
      }
      return Self.drain(&state)
    }
    for entry in started { entry.work.dispatch() }
  }

  /// Queued work withdrawn (client gone, queue deadline): it never ran, so
  /// its reservations are returned.
  @discardableResult
  public func withdraw(_ ticket: Ticket) -> Bool {
    state.withLock { state in
      for (name, var session) in state.sessions {
        guard let index = session.queue.firstIndex(where: { $0.ticket == ticket }) else {
          continue
        }
        session.queue.remove(at: index)
        session.reservations.removeAll { $0.ticket == ticket.id }
        session.tokens = min(session.tokens + 1, Double(SessionLimits.requestBurst))
        state.sessions[name] = session
        state.queuedCount -= 1
        return true
      }
      return false
    }
  }

  /// Active work whose completion could not be confirmed: its slot stays
  /// held and the backend admits nothing new until evidence arrives or the
  /// host requalifies it.
  public func markUncertain(_ ticket: Ticket) {
    let cancelled = state.withLock { state -> [Entry] in
      guard let work = state.active[ticket] else { return [] }
      var backend = state.backends[work.backend] ?? BackendLedger()
      backend.uncertain.insert(ticket)
      if backend.quarantine == nil { backend.quarantine = .uncertainCancellation }
      state.backends[work.backend] = backend
      return Self.removeQueued(&state) { $0.work.backend == work.backend }
    }
    for entry in cancelled { entry.work.cancel(.backendQuarantined) }
  }

  public func quarantine(_ backend: BackendID, _ reason: QuarantineReason) {
    let cancelled = state.withLock { state -> [Entry] in
      var ledger = state.backends[backend] ?? BackendLedger()
      if ledger.quarantine == nil || reason != .uncertainCancellation {
        ledger.quarantine = reason
      }
      state.backends[backend] = ledger
      return Self.removeQueued(&state) { $0.work.backend == backend }
    }
    for entry in cancelled { entry.work.cancel(.backendQuarantined) }
  }

  /// Host-side requalification (§9.2). Refused while this gateway still
  /// holds active work on the backend.
  public func requalify(_ backend: BackendID) throws(InferenceError) {
    let result: Result<[Entry], InferenceError> = state.withLock { state in
      var ledger = state.backends[backend] ?? BackendLedger()
      // Uncertain work was abandoned by the gateway; the host operator's
      // drain or restart of the backend is the evidence that ends it.
      guard ledger.active.subtracting(ledger.uncertain).isEmpty else {
        return .failure(
          InferenceError(
            .backendUnavailable, "backend \(backend) still has active requests; retry later"))
      }
      for ticket in ledger.uncertain { state.active[ticket] = nil }
      ledger.active = []
      ledger.quarantine = nil
      ledger.uncertain = []
      state.backends[backend] = ledger
      return .success(Self.drain(&state))
    }
    for entry in try result.get() { entry.work.dispatch() }
  }

  /// Revoke a session: queued work is removed, active work is told to
  /// cancel (and keeps its slot until evidence).
  public func removeSession(_ session: String, reason: CancelReason) {
    let (queued, active) = state.withLock { state -> ([Entry], [Work]) in
      let queued = Self.removeQueued(&state) { $0.work.session == session }
      state.sessions[session] = nil
      state.order.removeAll { $0 == session }
      let active = state.active.values.filter { $0.session == session }
      return (queued, active)
    }
    for entry in queued { entry.work.cancel(reason) }
    for work in active { work.cancel(reason) }
  }

  /// Queued entries older than the queue deadline, withdrawn and returned.
  public func expireQueued(olderThan age: Duration) -> [Ticket] {
    let instant = now()
    return state.withLock { state in
      Self.removeQueued(&state) { instant - $0.enqueued >= age }.map(\.ticket)
    }
  }

  public func backendStatus() -> [BackendStatus] {
    state.withLock { state in
      state.backends.keys.sorted().map { id in
        let ledger = state.backends[id]!
        let queued = state.sessions.values.reduce(0) { total, session in
          total + session.queue.filter { $0.work.backend == id }.count
        }
        return BackendStatus(
          id: id, active: ledger.active.count, queued: queued, uncertain: ledger.uncertain.count,
          quarantine: ledger.quarantine)
      }
    }
  }

  public func quarantineReason(_ backend: BackendID) -> QuarantineReason? {
    state.withLock { $0.backends[backend]?.quarantine }
  }

  public var hasWork: Bool {
    state.withLock { !$0.active.isEmpty || $0.queuedCount > 0 }
  }

  // MARK: Internals (called with the lock held)

  static func refill(_ session: inout SessionLedger, at instant: ContinuousClock.Instant) {
    let elapsed = instant - session.refilled
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let rate = Double(SessionLimits.requestsPerMinute) / 60
    session.tokens = min(Double(SessionLimits.requestBurst), session.tokens + seconds * rate)
    session.refilled = instant
  }

  static func hasCapacity(_ state: State, _ backend: BackendID, _ backendMax: Int) -> Bool {
    guard state.backends[backend]?.quarantine == nil else { return false }
    let backendActive = state.backends[backend]?.active.count ?? 0
    return backendActive < backendMax && state.active.count < state.limits.maxActiveRequests
  }

  static func activate(_ state: inout State, _ entry: Entry) {
    state.active[entry.ticket] = entry.work
    var ledger = state.backends[entry.work.backend] ?? BackendLedger()
    ledger.active.insert(entry.ticket)
    state.backends[entry.work.backend] = ledger
  }

  /// Start queued work round-robin across sessions, FIFO within one.
  static func drain(_ state: inout State) -> [Entry] {
    var started: [Entry] = []
    var progressed = true
    while progressed && state.active.count < state.limits.maxActiveRequests {
      progressed = false
      guard !state.order.isEmpty else { break }
      for step in 0..<state.order.count {
        let index = (state.cursor + step) % state.order.count
        let name = state.order[index]
        guard var session = state.sessions[name],
          let position = session.queue.firstIndex(where: {
            hasCapacity(state, $0.work.backend, $0.work.backendMaxActive)
          })
        else { continue }
        let entry = session.queue.remove(at: position)
        state.sessions[name] = session
        state.queuedCount -= 1
        activate(&state, entry)
        started.append(entry)
        state.cursor = (index + 1) % state.order.count
        progressed = true
        break
      }
    }
    return started
  }

  static func removeQueued(_ state: inout State, where match: (Entry) -> Bool) -> [Entry] {
    var removed: [Entry] = []
    for name in state.sessions.keys {
      var session = state.sessions[name]!
      let matching = session.queue.filter(match)
      guard !matching.isEmpty else { continue }
      session.queue.removeAll(where: match)
      let ids = Set(matching.map(\.ticket.id))
      session.reservations.removeAll { ids.contains($0.ticket) }
      state.sessions[name] = session
      state.queuedCount -= matching.count
      removed += matching
    }
    return removed
  }
}
