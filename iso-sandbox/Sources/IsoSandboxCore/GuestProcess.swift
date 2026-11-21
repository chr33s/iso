import Containerization
import Synchronization

/// The guest process operations whose lifetime is owned by one exec request.
protocol GuestProcess: Sendable {
  func start() async throws
  func wait(timeoutInSeconds: Int64?) async throws -> ExitStatus
  func kill(_ signal: Signal) async throws
  func delete() async throws
}

extension LinuxProcess: GuestProcess {}

/// How long an `exec` waits for its guest process.
/// With ``GuestAgentDeadline`` on its other guest-agent calls, every exec is bounded (default
/// `defaultSeconds`, cap `maxSeconds`, plus that deadline per call), so none holds a control
/// connection forever.
package struct ExecTimeout: Sendable, Equatable {
  package static let defaultSeconds: Int64 = 600
  package static let maxSeconds: Int64 = 86_400
  package static let `default` = ExecTimeout(checked: defaultSeconds)

  package let seconds: Int64

  private init(checked seconds: Int64) { self.seconds = seconds }

  /// `requested` nil is the default; anything outside 1...`maxSeconds` is
  /// refused rather than clamped, so a caller never gets a different bound
  /// than it asked for.
  package init(requested: Int64?) throws(SandboxError) {
    guard let requested else {
      self = .default
      return
    }
    guard (1...Self.maxSeconds).contains(requested) else {
      throw SandboxError("exec timeout must be 1...\(Self.maxSeconds) seconds; got \(requested)")
    }
    seconds = requested
  }
}

/// Why a guest-agent call of an exec did not complete.
package enum GuestAgentFailure: Error, Equatable, CustomStringConvertible {
  /// No answer within the deadline; the call may still complete in the guest.
  case timedOut(call: String, seconds: Int64)
  /// This many earlier calls are unanswered past their deadlines, so this one was not made.
  case unresponsive(unanswered: Int)

  package var description: String {
    switch self {
    case .timedOut(let call, let seconds):
      "the guest agent did not answer \(call) within \(seconds) s; it may still run in the guest"
    case .unresponsive(let n):
      "the guest agent has \(n) calls unanswered past their deadline; no new call is made"
    }
  }
}

/// Host-side deadlines for the guest-agent calls of an exec other than its wait (create, start,
/// kill, delete). The agent client enforces the wait's own deadline (``ExecTimeout``).
/// A root guest can wedge its agent. Past a call's deadline the exec stops waiting and the call
/// runs on unobserved; at most `limit` such calls are outstanding, and past that none is made.
package final class GuestAgentDeadline: Sendable {
  package static let defaultSeconds: Int64 = 30
  package static let defaultLimit = 16
  /// The owner's: one guest agent per owner process.
  package static let shared = GuestAgentDeadline()

  package let seconds: Int64
  package let limit: Int
  private let deadline: Duration
  private let unanswered = Mutex(0)

  /// `deadline` overrides `seconds` for tests.
  package init(
    seconds: Int64 = defaultSeconds, limit: Int = defaultLimit, deadline: Duration? = nil
  ) {
    self.seconds = seconds
    self.limit = limit
    self.deadline = deadline ?? .seconds(seconds)
  }

  /// Calls past their deadline that have not returned.
  package var outstanding: Int { unanswered.withLock { $0 } }

  /// `body`'s result, or ``GuestAgentFailure/timedOut(call:seconds:)`` once the deadline passes.
  /// Cancellation reaches `body` as if it were called directly. `late` gets a result that arrives
  /// after the deadline, which no caller is waiting for any more.
  package func call<T: Sendable>(
    _ name: String, late: @escaping @Sendable (T) async -> Void = { _ in },
    _ body: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let refused = unanswered.withLock { $0 < limit ? nil : $0 }
    if let refused { throw GuestAgentFailure.unresponsive(unanswered: refused) }
    let race = AgentCallRace<T>()
    let timedOut = GuestAgentFailure.timedOut(call: name, seconds: seconds)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        race.begin(
          continuation, deadline: deadline, timedOut: timedOut, owner: self, late: late, body)
      }
    } onCancel: {
      race.cancel()
    }
  }

  fileprivate func abandon() { unanswered.withLock { $0 += 1 } }
  fileprivate func returned() { unanswered.withLock { $0 -= 1 } }
}

/// One call against its deadline: whichever ends first resumes the caller, exactly once.
private final class AgentCallRace<T: Sendable>: Sendable {
  private struct State {
    var continuation: CheckedContinuation<T, any Error>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    var cancelled = false
    var settled = false
    var abandoned = false
  }

  private let state = Mutex(State())

  func begin(
    _ continuation: CheckedContinuation<T, any Error>, deadline: Duration,
    timedOut: GuestAgentFailure, owner: GuestAgentDeadline,
    late: @escaping @Sendable (T) async -> Void, _ body: @escaping @Sendable () async throws -> T
  ) {
    state.withLock { $0.continuation = continuation }
    let work = Task {
      let result: Result<T, any Error>
      do { result = .success(try await body()) } catch { result = .failure(error) }
      await self.finish(result, owner: owner, late: late)
    }
    let timer = Task {
      try? await Task.sleep(for: deadline)
      guard !Task.isCancelled else { return }
      self.expire(timedOut, owner: owner)
    }
    let cancelNow = state.withLock { s -> Bool in
      s.work = work
      s.timer = timer
      return s.cancelled
    }
    if cancelNow { work.cancel() }
  }

  func cancel() {
    let work = state.withLock { s -> Task<Void, Never>? in
      s.cancelled = true
      return s.work
    }
    work?.cancel()
  }

  private func finish(
    _ result: Result<T, any Error>, owner: GuestAgentDeadline,
    late: @Sendable (T) async -> Void
  ) async {
    let (continuation, timer, abandoned) = state.withLock {
      s -> (CheckedContinuation<T, any Error>?, Task<Void, Never>?, Bool) in
      guard !s.settled else { return (nil, nil, s.abandoned) }
      s.settled = true
      defer { s.continuation = nil }
      return (s.continuation, s.timer, false)
    }
    timer?.cancel()
    if let continuation {
      continuation.resume(with: result)
      return
    }
    guard abandoned else { return }
    if case .success(let value) = result { await late(value) }
    owner.returned()
  }

  private func expire(_ failure: GuestAgentFailure, owner: GuestAgentDeadline) {
    let continuation = state.withLock { s -> CheckedContinuation<T, any Error>? in
      guard !s.settled else { return nil }
      s.settled = true
      s.abandoned = true
      // Counted before the call can return, so `finish` never uncounts it first.
      owner.abandon()
      defer { s.continuation = nil }
      return s.continuation
    }
    continuation?.resume(throwing: failure)
  }
}

func runGuestProcess(
  _ process: some GuestProcess, timeout: ExecTimeout, agent: GuestAgentDeadline = .shared
) async throws -> ExitStatus {
  var exited = false
  defer {
    // Teardown must reach the guest even when this exec request was cancelled.
    await withTaskCancellationShield {
      if !exited { try? await agent.call("kill") { try await process.kill(.kill) } }
      try? await agent.call("delete") { try await process.delete() }
    }
  }
  try await agent.call("start") { try await process.start() }
  let status = try await process.wait(timeoutInSeconds: timeout.seconds)
  exited = true
  return status
}
