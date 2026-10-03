import Containerization
import Dispatch
import Foundation
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
  let status = try await runGuestProcess(process, timeout: nil)
  #expect(status.exitCode == 7)
  #expect(await process.events == [.start, .wait(nil), .delete])
}

@Test(arguments: [false, true])
func guestExecCleansPartialStartupAndPreservesTheStartError(cleanupFails: Bool) async {
  let process = TestGuestProcess(.startFailure, cleanupFails: cleanupFails)
  do {
    _ = try await runGuestProcess(process, timeout: 2)
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
    _ = try await runGuestProcess(process, timeout: 2)
    Issue.record("timed-out process was accepted")
  } catch {
    #expect(error as? TestGuestProcess.Failure == .timeout)
  }
  #expect(await process.events == [.start, .wait(2), .kill(Signal.kill.rawValue), .delete])
}

@Test(arguments: [false, true])
func guestExecShieldsCleanupAfterCancellation(duringStart: Bool) async {
  let process = TestGuestProcess(duringStart ? .cancelledDuringStart : .cancelledDuringWait)
  let result = await Task { try await runGuestProcess(process, timeout: 2) }.result
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
