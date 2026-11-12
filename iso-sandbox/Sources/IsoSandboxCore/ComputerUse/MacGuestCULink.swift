import Darwin
import Foundation
import IsoMacProtocol
import Virtualization

/// The host side of guest-driven computer use, on vsock 7802
/// (docs/design/guest-driven-computer-use.md §5). Registered only for
/// sandboxes created with it. Every request line is tainted: it is parsed
/// into a closed request, admitted against per-sandbox rate limits, and
/// answered by `handle`, which runs the same frame and action paths as host
/// callers. Any guest process may connect: the whole guest is one principal.
package final class MacGuestCULink: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
  private let handle: @Sendable (GuestCURequest) async -> GuestCUResponse
  private let log: @Sendable (String) -> Void
  private let lock = NSLock()
  private var connections = 0
  private var limits: GuestCULimits
  private var rejections = RejectionBudget()
  private var tally: MacGuestCUCounters

  package init(
    frameRate: Int, log: @escaping @Sendable (String) -> Void,
    handle: @escaping @Sendable (GuestCURequest) async -> GuestCUResponse
  ) {
    self.handle = handle
    self.log = log
    limits = GuestCULimits(frameRate: frameRate, now: Date())
    tally = MacGuestCUCounters(frameRate: frameRate)
  }

  /// This boot's counts so far (metadata only, for the host's audit).
  package var counters: MacGuestCUCounters { lock.withLock { tally } }

  package func listener(
    _ listener: VZVirtioSocketListener, shouldAcceptNewConnection conn: VZVirtioSocketConnection,
    from device: VZVirtioSocketDevice
  ) -> Bool {
    accept(fd: dup(conn.fileDescriptor), retaining: conn)
  }

  package var connectionCount: Int { lock.withLock { connections } }

  /// Takes ownership of `fd` and serves it on its own thread; false (and
  /// `fd` closed) when the connection cap is reached.
  @discardableResult
  package func accept(fd: Int32, retaining object: AnyObject?) -> Bool {
    let admitted: Bool = lock.withLock {
      guard connections < GuestCUProtocol.maxConnections else { return false }
      connections += 1
      return true
    }
    guard admitted else {
      reject("too many connections")
      close(fd)
      return false
    }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    nonisolated(unsafe) let object = object
    Thread.detachNewThread { [self] in
      withExtendedLifetime(object) { serve(fd) }
      close(fd)
      lock.withLock { connections -= 1 }
    }
    return true
  }

  private func serve(_ fd: Int32) {
    var reader = LineReader(fd: fd, limit: GuestCUProtocol.maxRequest)
    while case .line(let line) = reader.next() {
      let response = respond(to: line)
      let sent = BoundedWrite.all(
        fd, Array(response.encodedLine()),
        deadline: ContinuousClock.now + .seconds(GuestCUProtocol.writeDeadline))
      // A guest that stops reading loses the connection, not the owner.
      guard sent else { return }
    }
  }

  /// One request line to its response.
  package func respond(to line: [UInt8], now: Date = Date()) -> GuestCUResponse {
    let (op, response) = answer(line, now: now)
    lock.withLock { tally.count(op, response) }
    return response
  }

  private func answer(_ line: [UInt8], now: Date) -> (GuestCURequest.Op?, GuestCUResponse) {
    guard lock.withLock({ limits.admitLine(at: now) }) else {
      return (nil, .refused("rate limited", .rateLimited, beforeInput: true))
    }
    let request: GuestCURequest
    switch GuestCURequest.parse(line) {
    case .success(let r): request = r
    case .failure(let why):
      reject("malformed request: \(why.kind)")
      return (nil, .refused("malformed request", .invalidAction, beforeInput: true))
    }
    let admitted = lock.withLock { limits.admit(request, at: now) }
    guard admitted else {
      return (request.op, .refused("rate limited", .rateLimited, beforeInput: true))
    }
    let box = ResponseBox()
    let done = DispatchSemaphore(value: 0)
    let handle = handle
    Task {
      box.value = await handle(request)
      done.signal()
    }
    done.wait()
    let response = box.value ?? .refused("no response", nil)
    lock.withLock { limits.settle(request, response) }
    return (request.op, response)
  }

  /// Logs a rejection, within the budget.
  private func reject(_ why: String) {
    let (emit, suppressed) = lock.withLock { rejections.admit() }
    if suppressed > 0 { log("guest computer use rejections: \(suppressed) more not logged") }
    if emit { log("guest computer use rejected: \(GuestText.printable(why))") }
  }
}

/// Per-boot counts of guest computer use: no pixels, coordinates or text.
package struct MacGuestCUCounters: Codable, Equatable, Sendable {
  package var frameRate: Int
  package var sessions = 0
  package var frames = 0
  package var actions = 0
  package var statusRequests = 0
  /// Waits that ran to an outcome, and how many ended in each.
  package var waits = 0
  package var waitOutcomes: [String: Int] = [:]
  /// Guest sessions a host hold ended; filled in by the owner.
  package var preemptions = 0
  /// Refused requests by refusal code (`other` when there is none).
  package var refusals: [String: Int] = [:]

  package init(frameRate: Int) { self.frameRate = frameRate }

  enum CodingKeys: String, CodingKey {
    case frameRate, sessions, frames, actions, statusRequests, waits, waitOutcomes, preemptions
    case refusals
  }

  /// An owner from before `wait` reports no wait counts.
  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    frameRate = try c.decode(Int.self, forKey: .frameRate)
    sessions = try c.decode(Int.self, forKey: .sessions)
    frames = try c.decode(Int.self, forKey: .frames)
    actions = try c.decode(Int.self, forKey: .actions)
    statusRequests = try c.decode(Int.self, forKey: .statusRequests)
    waits = try c.decodeIfPresent(Int.self, forKey: .waits) ?? 0
    waitOutcomes = try c.decodeIfPresent([String: Int].self, forKey: .waitOutcomes) ?? [:]
    preemptions = try c.decode(Int.self, forKey: .preemptions)
    refusals = try c.decode([String: Int].self, forKey: .refusals)
  }

  mutating func count(_ op: GuestCURequest.Op?, _ r: GuestCUResponse) {
    guard r.ok else {
      refusals[r.refusal?.rawValue ?? "other", default: 0] += 1
      return
    }
    switch op {
    case .session: sessions += 1
    case .frame: frames += 1
    case .act: actions += 1
    case .status: statusRequests += 1
    case .wait:
      waits += 1
      if let outcome = r.wait?.outcome { waitOutcomes[outcome.rawValue, default: 0] += 1 }
    case nil: break
    }
  }
}

private final class ResponseBox: @unchecked Sendable {
  var value: GuestCUResponse?
}

extension MacGuestCULink {
  /// Runs a parsed guest request against the owner's screen, as the guest.
  @MainActor
  package static func serve(_ request: GuestCURequest, screen: VMScreen) async -> GuestCUResponse {
    do {
      switch request.op {
      case .session:
        let (id, _) = try screen.newGuestSession()
        var r = GuestCUResponse(ok: true)
        r.session = id
        return r
      case .frame:
        let f = try screen.frame(session: request.session, origin: .guest)
        var r = GuestCUResponse(ok: true)
        r.frame = GuestCUFrame(
          frameId: f.id, width: screen.width, height: screen.height, png: f.png)
        r.damageSeq = f.damageSeq
        return r
      case .act:
        guard let action = request.action, let converted = try? hostAction(action) else {
          return .refused("invalid action", .invalidAction, beforeInput: true)
        }
        var r = GuestCUResponse(ok: true)
        (r.submitted, r.damageSeq) = try await screen.act(
          session: request.session, request: converted, basedOnFrame: request.basedOnFrame,
          origin: .guest)
        return r
      case .status:
        var r = GuestCUResponse(ok: true)
        (r.controller, r.holdRemainingSeconds) = screen.controlState
        r.damageSeq = screen.damageSeq
        return r
      case .wait:
        var r = GuestCUResponse(ok: true)
        (r.wait, r.damageSeq) = try await screen.wait(
          session: request.session, request.wait, origin: .guest)
        return r
      }
    } catch let e as SandboxError {
      return .refused(
        e.description, e.refusal, beforeInput: request.op == .act ? e.beforeInput : nil)
    } catch {
      return .refused("\(error)", nil)
    }
  }

  /// The guest's action in the runtime's form: the same field names, so a
  /// round trip through JSON; unknown buttons or modifiers fail here.
  static func hostAction(_ a: GuestCUAction) throws -> CUActionRequest {
    try JSONDecoder().decode(CUActionRequest.self, from: JSONEncoder().encode(a))
  }
}
