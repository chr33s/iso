import Synchronization
import Testing

@testable import IsoInferenceCore

/// A manually advanced clock for deterministic rate and window tests.
final class TestClock: Sendable {
  private let offset = Mutex<Duration>(.zero)
  let base = ContinuousClock.now
  func advance(_ duration: Duration) { offset.withLock { $0 += duration } }
  var now: ContinuousClock.Instant { base + offset.withLock { $0 } }
}

final class Log: Sendable {
  private let entries = Mutex<[String]>([])
  func add(_ entry: String) { entries.withLock { $0.append(entry) } }
  var all: [String] { entries.withLock { $0 } }
}

private func work(
  _ session: String, _ label: String, backend: UInt16 = 1, maxActive: Int = 1, tokens: Int = 100,
  log: Log
) -> Scheduler.Work {
  Scheduler.Work(
    session: session, backend: BackendID(port: backend), backendMaxActive: maxActive,
    outputTokens: tokens, dispatch: { log.add("run \(label)") },
    cancel: { reason in log.add("cancel \(label) \(reason)") })
}

private func makeScheduler(_ clock: TestClock, active: Int = 2, queued: Int = 32) -> Scheduler {
  Scheduler(
    limits: GlobalLimits(
      maxActiveRequests: active, maxQueuedRequests: queued, maxRequestBufferBytes: 1 << 20),
    now: { clock.now })
}

@Test func backendConcurrencyAndFairQueueing() throws {
  let clock = TestClock()
  let log = Log()
  let scheduler = makeScheduler(clock)
  for session in ["a", "b"] { scheduler.addSession(session) }
  guard case .dispatched(let first) = try scheduler.admit(work("a", "a1", log: log)) else {
    Issue.record("first request should run")
    return
  }
  // One active request per backend: the rest queue.
  #expect(try scheduler.admit(work("a", "a2", log: log)) != .dispatched(first))
  _ = try scheduler.admit(work("a", "a3", log: log))
  _ = try scheduler.admit(work("b", "b1", log: log))
  #expect(log.all == ["run a1"])
  scheduler.finish(first, outputTokens: 10)
  // Round-robin: b's first request runs before a's second.
  #expect(log.all.last == "run b1")
}

@Test func sharedActiveLimitSpansBackends() throws {
  let clock = TestClock()
  let log = Log()
  let scheduler = makeScheduler(clock, active: 1)
  scheduler.addSession("a")
  _ = try scheduler.admit(work("a", "x", backend: 1, log: log))
  #expect(try scheduler.admit(work("a", "y", backend: 2, log: log)) == .queued(.init(id: 2)))
  #expect(log.all == ["run x"])
}

@Test func queueBoundsRateAndTokenAllowance() throws {
  let clock = TestClock()
  let log = Log()
  let scheduler = makeScheduler(clock, queued: 32)
  scheduler.addSession("a")
  _ = try scheduler.admit(work("a", "0", log: log))
  // Burst of 8 requests: the ninth is rate limited.
  for index in 1..<SessionLimits.requestBurst {
    _ = try scheduler.admit(work("a", "\(index)", log: log))
  }
  do {
    _ = try scheduler.admit(work("a", "over", log: log))
    Issue.record("rate limit not enforced")
  } catch {
    #expect(error.code == .capacity)
  }
  // Refill over time: one more fits the per-session queue (8), then it is full.
  clock.advance(.seconds(10))
  _ = try scheduler.admit(work("a", "eighth", log: log))
  do {
    _ = try scheduler.admit(work("a", "queued", log: log))
    Issue.record("session queue not bounded")
  } catch {
    #expect(error.code == .capacity)
  }

  let allowance = makeScheduler(clock)
  allowance.addSession("b")
  _ = try allowance.admit(work("b", "big", backend: 1, maxActive: 4, tokens: 30_000, log: log))
  do {
    _ = try allowance.admit(work("b", "more", backend: 1, maxActive: 4, tokens: 4_000, log: log))
    Issue.record("token allowance not enforced")
  } catch {
    #expect(error.code == .capacity)
  }
  clock.advance(.seconds(61))
  _ = try allowance.admit(work("b", "later", backend: 1, maxActive: 4, tokens: 4_000, log: log))
}

@Test func disconnectDoesNotFreeActiveCapacity() throws {
  let clock = TestClock()
  let log = Log()
  let scheduler = makeScheduler(clock)
  scheduler.addSession("a")
  guard case .dispatched(let ticket) = try scheduler.admit(work("a", "a1", log: log)) else {
    Issue.record("expected dispatch")
    return
  }
  guard case .queued(let waiting) = try scheduler.admit(work("a", "a2", log: log)) else {
    Issue.record("expected queue")
    return
  }
  // Withdrawing the running ticket does nothing: only evidence frees it.
  #expect(!scheduler.withdraw(ticket))
  #expect(scheduler.withdraw(waiting))
  #expect(scheduler.backendStatus().first?.active == 1)
  scheduler.finish(ticket, outputTokens: nil)
  #expect(scheduler.backendStatus().first?.active == 0)
}

@Test func uncertainCancellationQuarantinesUntilEvidence() throws {
  let clock = TestClock()
  let log = Log()
  let scheduler = makeScheduler(clock)
  scheduler.addSession("a")
  guard case .dispatched(let ticket) = try scheduler.admit(work("a", "a1", log: log)) else {
    Issue.record("expected dispatch")
    return
  }
  _ = try scheduler.admit(work("a", "a2", log: log))
  scheduler.markUncertain(ticket)
  #expect(log.all.contains("cancel a2 backendQuarantined"))
  #expect(scheduler.quarantineReason(BackendID(port: 1)) == .uncertainCancellation)
  do {
    _ = try scheduler.admit(work("a", "a3", log: log))
    Issue.record("quarantined backend admitted work")
  } catch {
    #expect(error.code == .backendQuarantined)
  }
  // Late evidence clears an uncertain-cancellation quarantine.
  scheduler.finish(ticket, outputTokens: 5)
  #expect(scheduler.quarantineReason(BackendID(port: 1)) == nil)
}

@Test func crashQuarantineNeedsRequalification() throws {
  let clock = TestClock()
  let log = Log()
  let scheduler = makeScheduler(clock)
  scheduler.addSession("a")
  scheduler.quarantine(BackendID(port: 1), .crashJournal)
  #expect(throws: InferenceError.self) { try scheduler.admit(work("a", "x", log: log)) }
  try scheduler.requalify(BackendID(port: 1))
  _ = try scheduler.admit(work("a", "x", log: log))
  #expect(throws: InferenceError.self) { try scheduler.requalify(BackendID(port: 1)) }
}

@Test func removingASessionCancelsItsWork() throws {
  let clock = TestClock()
  let log = Log()
  let scheduler = makeScheduler(clock)
  scheduler.addSession("a")
  _ = try scheduler.admit(work("a", "a1", log: log))
  _ = try scheduler.admit(work("a", "a2", log: log))
  scheduler.removeSession("a", reason: .sessionRevoked)
  #expect(log.all.contains("cancel a1 sessionRevoked"))
  #expect(log.all.contains("cancel a2 sessionRevoked"))
  #expect(throws: InferenceError.self) { try scheduler.admit(work("a", "a3", log: log)) }
  // The revoked session's running work still holds its slot.
  #expect(scheduler.backendStatus().first?.active == 1)
}

@Test func byteBudgetAndSlots() {
  let budget = ByteBudget(100)
  let lease = budget.reserve(60)
  #expect(lease != nil && budget.reserve(50) == nil)
  lease?.release()
  lease?.release()
  #expect(budget.free == 100)
  budget.tighten(to: 40)
  #expect(budget.reserve(41) == nil && budget.reserve(40) != nil)
  let pool = SlotPool(1)
  var slot = pool.acquire()
  #expect(slot != nil && pool.acquire() == nil)
  slot = nil
  #expect(pool.acquire() != nil)
}
