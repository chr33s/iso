import Darwin
import Foundation
import IsoInferenceCore
import IsoProxyCore
import Synchronization

/// The broker's session workers (§5.1). The broker parses no guest bytes:
/// each registered session gets its own `iso-inference --worker` process,
/// which the host launches under a profile that admits only that session's
/// socket, its backend ports and this broker's worker socket. A worker is
/// expected with a one-time key and attaches when it presents it; the
/// broker then serves its link for that one session only.
package final class WorkerRegistry: Sendable {
  struct Entry {
    let key: [UInt8]
    /// Sent once, in the worker's configuration, then dropped.
    var registration: ControlProtocol.Registration?
    var capability: Secret?
    var link: WorkerLink?
    var ready = false
    var revoked = false
  }

  private let entries = Mutex<[String: Entry]>([:])

  /// How long activation waits for the session's worker to attach and answer.
  package let attachTimeout: Duration

  package init(attachTimeout: Duration = .seconds(10)) {
    self.attachTimeout = attachTimeout
  }

  /// A fresh key for `session`'s worker, which the host passes it on stdin.
  func expect(
    _ session: String, registration: ControlProtocol.Registration, capability: Secret
  ) -> Secret {
    let key = randomHex(32)
    entries.withLock {
      $0[session] = Entry(
        key: Array(key.utf8), registration: registration, capability: capability)
    }
    return Secret(key)
  }

  /// Attaches `link` when `key` is the session's (compared in constant
  /// time), no worker is attached and the session is not revoked; returns
  /// what to configure it with, once.
  func attach(_ link: WorkerLink, key: String) -> (ControlProtocol.Registration, Secret)? {
    entries.withLock { entries in
      guard var entry = entries[link.session], entry.link == nil, !entry.revoked,
        let registration = entry.registration, let capability = entry.capability
      else { return nil }
      let presented = Array(key.utf8)
      guard presented.count == entry.key.count,
        zip(presented, entry.key).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0
      else { return nil }
      entry.link = link
      entry.registration = nil
      entry.capability = nil
      entries[link.session] = entry
      return (registration, capability)
    }
  }

  func markReady(_ link: WorkerLink) {
    entries.withLock { entries in
      guard entries[link.session]?.link === link else { return }
      entries[link.session]?.ready = true
    }
  }

  /// The session's link once its worker bound the socket, waiting up to
  /// `attachTimeout`.
  func readyLink(_ session: String) -> WorkerLink? {
    let deadline = ContinuousClock.now + attachTimeout
    while ContinuousClock.now < deadline {
      let (link, gone) = entries.withLock { entries -> (WorkerLink?, Bool) in
        guard let entry = entries[session], !entry.revoked else { return (nil, true) }
        return (entry.ready ? entry.link : nil, false)
      }
      if let link { return link }
      if gone { return nil }
      usleep(20_000)
    }
    return nil
  }

  /// Revocation tells the worker; its link stays open while the worker
  /// settles the work it holds, and closes when it exits.
  func revoke(_ session: String, reason: String) {
    let link = entries.withLock { entries -> WorkerLink? in
      entries[session]?.revoked = true
      entries[session]?.registration = nil
      entries[session]?.capability = nil
      return entries[session]?.link
    }
    link?.send(.revoke(reason: reason))
  }

  /// Forgets the session when `link` (or no link) is the one recorded.
  func remove(_ session: String, link: WorkerLink?) {
    entries.withLock { entries in
      guard entries[session]?.link === link else { return }
      entries[session] = nil
    }
  }

  func info(_ session: String) -> (state: String, pid: pid_t?) {
    entries.withLock { entries in
      guard let entry = entries[session] else { return ("none", nil) }
      guard let link = entry.link else { return ("pending", nil) }
      return (entry.ready ? "ready" : "connected", link.pid)
    }
  }
}

/// The broker's end of one worker's link: it serves the worker's requests
/// for its own session only, and admits only tickets it issued to it.
final class WorkerLink: Sendable {
  struct Held {
    let backend: BackendID
    var journaled = false
  }

  struct State {
    var permits: [UInt64: Scheduler.Permit] = [:]
    var nextPermit: UInt64 = 1
    /// Tickets issued to this worker and not yet settled.
    var tickets: [UInt64: Held] = [:]
    var nextRequest: UInt64 = 1
    var activations: [UInt64: Result<Void, InferenceError>] = [:]
  }

  let fd: Int32
  let session: String
  let pid: pid_t
  private let gateway: Gateway
  private let writes = Mutex(())
  private let state = Mutex(State())

  init(fd: Int32, session: String, pid: pid_t, gateway: Gateway) {
    self.fd = fd
    self.session = session
    self.pid = pid
    self.gateway = gateway
  }

  func send(_ message: WorkerProtocol.Down) {
    let frame = ControlProtocol.frame(WorkerProtocol.encode(message))
    writes.withLock { _ in writeAll(fd, frame) }
  }

  /// Reads the worker's messages until it closes the link or breaks the
  /// protocol, then settles what the worker still held.
  func serve() {
    while let body = readFrame(fd) {
      let message: WorkerProtocol.Up
      do { message = try WorkerProtocol.decodeUp(ControlProtocol.parseFrame(body)) } catch {
        break
      }
      guard handle(message) else { break }
    }
    shutdown(fd, SHUT_RDWR)
    close(fd)
    gateway.workerExited(self, holding: heldTickets())
  }

  func heldTickets() -> [(Scheduler.Ticket, BackendID)] {
    state.withLock { state in
      state.tickets.map { (Scheduler.Ticket(id: $0.key), $0.value.backend) }
    }
  }

  /// One message; false ends the link (a protocol violation).
  private func handle(_ message: WorkerProtocol.Up) -> Bool {
    let scheduler = gateway.scheduler
    switch message {
    case .hello: return false
    case .ready: gateway.workers?.markReady(self)
    case .permit(let id):
      do {
        let permit = try scheduler.permit(session: session)
        let number = state.withLock { state -> UInt64 in
          let number = state.nextPermit
          state.nextPermit += 1
          state.permits[number] = permit
          return number
        }
        send(.permitted(id: id, permit: number))
      } catch {
        send(.refused(id: id, error: error))
      }
    case .admit(let id, let number, let backend, let outputTokens):
      admit(id: id, permit: number, backend: backend, outputTokens: outputTokens)
    case .withdraw(let id, let ticket):
      let held = state.withLock { $0.tickets[ticket] != nil }
      let withdrawn = held && scheduler.withdraw(Scheduler.Ticket(id: ticket))
      if withdrawn { _ = state.withLock { $0.tickets.removeValue(forKey: ticket) } }
      send(.withdrawn(id: id, value: withdrawn))
    case .finish(let ticket, let outputTokens):
      guard let held = state.withLock({ $0.tickets.removeValue(forKey: ticket) }) else {
        return true
      }
      scheduler.finish(Scheduler.Ticket(id: ticket), outputTokens: outputTokens)
      if held.journaled { gateway.journal.settled(held.backend) }
    case .uncertain(let ticket):
      // The slot stays held and the journal keeps the work outstanding.
      guard state.withLock({ $0.tickets.removeValue(forKey: ticket) }) != nil else { return true }
      scheduler.markUncertain(Scheduler.Ticket(id: ticket))
    case .qualificationFailure(let backend):
      guard grants(backend) != nil else { return false }
      scheduler.quarantine(backend, .qualificationFailure)
    case .audit(let event, let fields):
      var object = fields
      object["session"] = .string(session)
      gateway.audit.record(event, object: object)
    case .rejected(let code):
      gateway.audit.rejected(session: session, code: code)
    case .activated(let id, let error):
      state.withLock { $0.activations[id] = error.map { .failure($0) } ?? .success(()) }
    case .revoked(let reason):
      gateway.revokeFromWorker(session, reason: reason)
    }
    return true
  }

  /// The policy of `backend` when one of this session's grants names it.
  private func grants(_ backend: BackendID) -> BackendPolicy? {
    guard let session = gateway.sessions.withLock({ $0[session] }),
      session.grants.values.contains(where: { $0.backend.id == backend })
    else { return nil }
    return gateway.backendPolicy(backend)
  }

  private func admit(id: UInt64, permit number: UInt64, backend: BackendID, outputTokens: Int) {
    guard let permit = state.withLock({ $0.permits.removeValue(forKey: number) }) else {
      return send(.refused(id: id, error: InferenceError(.requestInvalid, "unknown permit")))
    }
    guard let policy = grants(backend) else {
      return send(
        .refused(id: id, error: InferenceError(.policyDenied, "the backend is not granted")))
    }
    let scheduler = gateway.scheduler
    let journal = gateway.journal
    let work = Scheduler.Work(
      session: session, backend: backend, backendMaxActive: policy.maxActive,
      outputTokens: outputTokens,
      dispatch: { [weak self] ticket in
        guard let self else { return }
        do { try journal.dispatched(backend) } catch {
          scheduler.finish(ticket, outputTokens: 0)
          self.state.withLock { _ = $0.tickets.removeValue(forKey: ticket.id) }
          return self.send(.cancel(ticket: ticket.id, reason: .shutdown))
        }
        self.state.withLock { state in
          var held = state.tickets[ticket.id] ?? Held(backend: backend)
          held.journaled = true
          state.tickets[ticket.id] = held
        }
        self.send(.dispatch(ticket: ticket.id))
      },
      cancel: { [weak self] ticket, reason in
        self?.send(.cancel(ticket: ticket.id, reason: reason))
      })
    do {
      let admission = try scheduler.admit(work, permit: permit)
      let (ticket, queued) =
        switch admission {
        case .dispatched(let ticket): (ticket, false)
        case .queued(let ticket): (ticket, true)
        }
      state.withLock { state in
        if state.tickets[ticket.id] == nil { state.tickets[ticket.id] = Held(backend: backend) }
      }
      send(.admitted(id: id, ticket: ticket.id, queued: queued))
    } catch {
      send(.refused(id: id, error: error))
    }
  }

  /// Asks the worker to bind its transport; waits for its answer.
  func activate(_ binding: TransportBinding, deadlineSeconds: Int64?, timeout: Duration)
    throws(InferenceError)
  {
    let id = state.withLock { state -> UInt64 in
      let id = state.nextRequest
      state.nextRequest += 1
      return id
    }
    send(.activate(id: id, transport: binding, deadlineSeconds: deadlineSeconds))
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let result = state.withLock({ $0.activations.removeValue(forKey: id) }) {
        return try result.get()
      }
      usleep(10_000)
    }
    throw InferenceError(.backendUnavailable, "the session worker did not answer the activation")
  }
}

/// The broker's owner-only worker socket: a worker says `hello` with its
/// session and key within five seconds, or is closed.
package final class WorkerServer: Sendable {
  private let path: String
  private let gateway: Gateway
  private let listener: Int32
  private let closed = Mutex(false)

  package init(path: String, gateway: Gateway) throws {
    self.path = path
    self.gateway = gateway
    listener = try bindUnixListener(path, backlog: 32)
  }

  package func run() {
    while !closed.withLock({ $0 }) {
      let fd = accept(listener, nil, nil)
      guard fd >= 0 else {
        if closed.withLock({ $0 }) || ControlServer.classify(errno) == .fatal { return }
        usleep(10_000)
        continue
      }
      Thread { self.attach(fd) }.start()
    }
  }

  package func stop() {
    closed.withLock { $0 = true }
    shutdown(listener, SHUT_RDWR)
    close(listener)
    unsafe unlink(path)
  }

  private func attach(_ fd: Int32) {
    var one: Int32 = 1
    // setsockopt borrows one local value for the call.
    unsafe setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    setTimeouts(fd, seconds: ControlServer.ioTimeoutSeconds)
    guard let peer = unixPeer(fd), peer.uid == getuid(), let workers = gateway.workers,
      let body = readFrame(fd),
      case .hello(let session, let key)? = try? WorkerProtocol.decodeUp(
        ControlProtocol.parseFrame(body)),
      gateway.sessions.withLock({ $0[session] }) != nil
    else {
      close(fd)
      return
    }
    let link = WorkerLink(fd: fd, session: session, pid: peer.pid, gateway: gateway)
    guard let (registration, capability) = workers.attach(link, key: key) else {
      close(fd)
      return
    }
    // The link lives as long as the worker: no read deadline from here on.
    setTimeouts(fd, seconds: 0)
    link.send(
      .config(
        WorkerProtocol.Config(
          sessionID: session, epoch: gateway.epoch, registration: registration,
          capability: capability,
          requestBufferBytes: min(
            SessionLimits.requestBufferBytesPerSession,
            gateway.scheduler.limits.maxRequestBufferBytes))
      ))
    link.serve()
  }
}
