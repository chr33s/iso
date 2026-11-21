import Containerization
import Dispatch
import Foundation
import Synchronization
import Testing

@testable import IsoSandboxCore

private actor TestGuestProcess: GuestProcess {
  enum Outcome: Sendable {
    case exited
    case startFailure
    case timeout
    case cancelledDuringStart
    case cancelledDuringWait
  }

  enum Failure: Error, Equatable { case start, timeout, cleanup }
  enum Event: Equatable {
    case start
    case wait(Int64?)
    case kill(Int32)
    case delete
  }

  let outcome: Outcome
  let cleanupFails: Bool
  private(set) var events: [Event] = []

  init(_ outcome: Outcome, cleanupFails: Bool = false) {
    self.outcome = outcome
    self.cleanupFails = cleanupFails
  }

  func start() async throws {
    events.append(.start)
    if outcome == .startFailure { throw Failure.start }
    if outcome == .cancelledDuringStart {
      withUnsafeCurrentTask { $0?.cancel() }
      try Task.checkCancellation()
    }
  }

  func wait(timeoutInSeconds: Int64?) async throws -> Containerization.ExitStatus {
    events.append(.wait(timeoutInSeconds))
    if outcome == .timeout { throw Failure.timeout }
    if outcome == .cancelledDuringWait {
      withUnsafeCurrentTask { $0?.cancel() }
      try Task.checkCancellation()
    }
    return Containerization.ExitStatus(exitCode: 7)
  }

  func kill(_ signal: Signal) async throws {
    try Task.checkCancellation()
    await Task.yield()
    events.append(.kill(signal.rawValue))
    if cleanupFails { throw Failure.cleanup }
  }

  func delete() async throws {
    try Task.checkCancellation()
    await Task.yield()
    events.append(.delete)
    if cleanupFails { throw Failure.cleanup }
  }
}

@Test func guestExecDeletesBeforeReturningWithoutKillingAnExitedProcess() async throws {
  let process = TestGuestProcess(.exited)
  let status = try await runGuestProcess(process, timeout: .default)
  #expect(status.exitCode == 7)
  #expect(await process.events == [.start, .wait(ExecTimeout.defaultSeconds), .delete])
}

@Test(arguments: [false, true])
func guestExecCleansPartialStartupAndPreservesTheStartError(cleanupFails: Bool) async {
  let process = TestGuestProcess(.startFailure, cleanupFails: cleanupFails)
  do {
    _ = try await runGuestProcess(process, timeout: try ExecTimeout(requested: 2))
    Issue.record("failed startup was accepted")
  } catch {
    #expect(error as? TestGuestProcess.Failure == .start)
  }
  #expect(await process.events == [.start, .kill(Signal.kill.rawValue), .delete])
}

@Test(arguments: [false, true])
func guestExecKillsOnTimeoutAndPreservesTheWaitError(cleanupFails: Bool) async {
  let process = TestGuestProcess(.timeout, cleanupFails: cleanupFails)
  do {
    _ = try await runGuestProcess(process, timeout: try ExecTimeout(requested: 2))
    Issue.record("timed-out process was accepted")
  } catch {
    #expect(error as? TestGuestProcess.Failure == .timeout)
  }
  #expect(await process.events == [.start, .wait(2), .kill(Signal.kill.rawValue), .delete])
}

@Test(arguments: [false, true])
func guestExecShieldsCleanupAfterCancellation(duringStart: Bool) async {
  let process = TestGuestProcess(duringStart ? .cancelledDuringStart : .cancelledDuringWait)
  let result = await Task {
    try await runGuestProcess(process, timeout: try ExecTimeout(requested: 2))
  }.result
  guard case .failure(let error) = result else {
    Issue.record("cancelled exec returned success")
    return
  }
  #expect(error is CancellationError)
  let expected: [TestGuestProcess.Event] =
    duringStart
    ? [.start, .kill(Signal.kill.rawValue), .delete]
    : [.start, .wait(2), .kill(Signal.kill.rawValue), .delete]
  #expect(await process.events == expected)
}

@Test func concurrentGuestOutputRemainsCapped() {
  let writer = BufferWriter()
  DispatchQueue.concurrentPerform(iterations: 32) { _ in
    do {
      try writer.write(Data(repeating: 42, count: 512 * 1024))
    } catch {
      Issue.record(error)
    }
  }
  let data = writer.data
  #expect(data.count == BufferWriter.limit)
  #expect(data.allSatisfy { $0 == 42 })
}

@Test func anExecWithoutATimeoutGetsTheDefaultAndNoneExceedsTheMaximum() throws {
  #expect(try ExecTimeout(requested: nil) == .default)
  #expect(ExecTimeout.default.seconds == ExecTimeout.defaultSeconds)
  #expect(try ExecTimeout(requested: 1).seconds == 1)
  #expect(try ExecTimeout(requested: ExecTimeout.maxSeconds).seconds == ExecTimeout.maxSeconds)
  for refused: Int64 in [0, -1, ExecTimeout.maxSeconds + 1, .max] {
    #expect(throws: SandboxError.self) { try ExecTimeout(requested: refused) }
  }
}

// MARK: a wedged guest agent

/// Calls that never return until released, whatever their task's cancellation: a root guest can
/// wedge its agent this way.
private final class Wedge: Sendable {
  private let state = Mutex((released: false, waiting: [CheckedContinuation<Void, Never>]()))

  func hang() async {
    await withCheckedContinuation { c in
      let now = state.withLock { s -> Bool in
        if s.released { return true }
        s.waiting.append(c)
        return false
      }
      if now { c.resume() }
    }
  }

  func release() {
    let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
      s.released = true
      defer { s.waiting = [] }
      return s.waiting
    }
    for c in waiting { c.resume() }
  }
}

private actor WedgedGuestProcess: GuestProcess {
  enum Step: Sendable { case start, kill, delete }
  enum Failure: Error { case timeout }

  let wedged: Set<Step>
  let wedge: Wedge
  private(set) var events: [TestGuestProcess.Event] = []

  init(wedged: Set<Step>, wedge: Wedge) {
    self.wedged = wedged
    self.wedge = wedge
  }

  func start() async throws {
    events.append(.start)
    if wedged.contains(.start) { await wedge.hang() }
  }

  func wait(timeoutInSeconds: Int64?) async throws -> Containerization.ExitStatus {
    events.append(.wait(timeoutInSeconds))
    throw Failure.timeout
  }

  func kill(_ signal: Signal) async throws {
    events.append(.kill(signal.rawValue))
    if wedged.contains(.kill) { await wedge.hang() }
  }

  func delete() async throws {
    events.append(.delete)
    if wedged.contains(.delete) { await wedge.hang() }
  }
}

/// `body`'s outcome, or nil when it has not finished within `limit`. The test fails rather than
/// hangs when a deadline under test does not hold: `wedge` is released either way.
private func within<T: Sendable>(
  _ limit: Duration, releasing wedge: Wedge, _ body: @escaping @Sendable () async throws -> T
) async -> Result<T, any Error>? {
  let task = Task { try await body() }
  let done = Mutex(false)
  let watcher = Task {
    _ = await task.result
    done.withLock { $0 = true }
  }
  let end = ContinuousClock.now + limit
  while !done.withLock({ $0 }), ContinuousClock.now < end {
    try? await Task.sleep(for: .milliseconds(10))
  }
  let finished = done.withLock { $0 }
  wedge.release()
  await watcher.value
  return finished ? await task.result : nil
}

private func eventually(_ limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
  let end = ContinuousClock.now + limit
  while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(10)) }
  return condition()
}

@Test func anExecWhoseAgentWedgesTeardownStillReturnsAndFreesItsConnection() async throws {
  let wedge = Wedge()
  let process = WedgedGuestProcess(wedged: [.kill, .delete], wedge: wedge)
  let agent = GuestAgentDeadline(seconds: 1, deadline: .milliseconds(100))
  let outcome = await within(.seconds(5), releasing: wedge) {
    try await runGuestProcess(process, timeout: try ExecTimeout(requested: 2), agent: agent)
  }
  guard let outcome else {
    Issue.record("the exec did not return while the agent was wedged")
    return
  }
  guard case .failure(let error) = outcome else {
    Issue.record("a timed-out exec returned success")
    return
  }
  // The wait's own error, not the teardown's.
  #expect(error is WedgedGuestProcess.Failure)
  #expect(await process.events == [.start, .wait(2), .kill(Signal.kill.rawValue), .delete])
  // Released above: the abandoned calls return and are no longer counted.
  #expect(await eventually { agent.outstanding == 0 })
}

@Test func aWedgedStartTimesOutAndTheProcessIsStillTornDown() async throws {
  let wedge = Wedge()
  let process = WedgedGuestProcess(wedged: [.start], wedge: wedge)
  let agent = GuestAgentDeadline(seconds: 1, deadline: .milliseconds(100))
  let outcome = await within(.seconds(5), releasing: wedge) {
    try await runGuestProcess(process, timeout: try ExecTimeout(requested: 2), agent: agent)
  }
  guard case .failure(let error)? = outcome else {
    Issue.record("a wedged start did not fail within its deadline")
    return
  }
  #expect(error as? GuestAgentFailure == .timedOut(call: "start", seconds: 1))
  #expect(await process.events == [.start, .kill(Signal.kill.rawValue), .delete])
}

@Test func pastTheLimitOfUnansweredCallsNoNewCallIsMade() async throws {
  let wedge = Wedge()
  let agent = GuestAgentDeadline(seconds: 1, limit: 1, deadline: .milliseconds(50))
  let first = await within(.seconds(5), releasing: Wedge()) {
    try await agent.call("start") { await wedge.hang() }
  }
  guard case .failure(let error)? = first else {
    Issue.record("a wedged call did not time out")
    return
  }
  #expect(error as? GuestAgentFailure == .timedOut(call: "start", seconds: 1))
  #expect(agent.outstanding == 1)
  let made = Mutex(false)
  do {
    try await agent.call("kill") { made.withLock { $0 = true } }
    Issue.record("a call was made past the limit")
  } catch {
    #expect(error as? GuestAgentFailure == .unresponsive(unanswered: 1))
  }
  #expect(!made.withLock { $0 })
  wedge.release()
  #expect(await eventually { agent.outstanding == 0 })
  try await agent.call("kill") { made.withLock { $0 = true } }
  #expect(made.withLock { $0 })
}

@Test func aResultThatArrivesAfterTheDeadlineGoesToLate() async throws {
  let wedge = Wedge()
  let agent = GuestAgentDeadline(seconds: 1, deadline: .milliseconds(50))
  let late = Mutex<Int?>(nil)
  let create: @Sendable () async throws -> Int = {
    await wedge.hang()
    return 42
  }
  do {
    _ = try await agent.call("create", late: { value in late.withLock { $0 = value } }, create)
    Issue.record("a wedged call returned before its deadline")
  } catch {
    #expect(error as? GuestAgentFailure == .timedOut(call: "create", seconds: 1))
  }
  #expect(late.withLock { $0 } == nil)
  wedge.release()
  #expect(await eventually { late.withLock { $0 } == 42 })
  #expect(await eventually { agent.outstanding == 0 })
}
