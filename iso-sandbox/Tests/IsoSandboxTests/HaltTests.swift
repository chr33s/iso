import Containerization
import Foundation
import Testing

@testable import IsoSandboxCore

/// Records the signals it is asked to deliver; `wedged` never returns, as a
/// guest agent a root guest has stopped answering would not.
private final class FakeContainer: HaltableContainer, @unchecked Sendable {
  private let lock = NSLock()
  private var signals: [Int32] = []
  let wedged: Bool
  init(wedged: Bool) { self.wedged = wedged }

  var received: [Int32] { lock.withLock { signals } }

  func kill(_ signal: Signal) async throws {
    lock.withLock { signals.append(signal.rawValue) }
    if wedged { try await Task.sleep(for: .seconds(3600)) }
  }
}

private final class ExitFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  func fire() { lock.withLock { count += 1 } }
  var fired: Int { lock.withLock { count } }
}

/// Polls `condition` until it holds or `timeout` passes; the halt sequence
/// runs on unstructured tasks, so a loaded host delays it unpredictably.
private func eventually(
  timeout: Duration = .seconds(10), _ condition: () async -> Bool
) async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try await Task.sleep(for: .milliseconds(10))
  }
  return await condition()
}

@Test func aWedgedGuestAgentEndsTheOwnerAfterTheGracePeriods() async throws {
  let container = FakeContainer(wedged: true)
  let exit = ExitFlag()
  let lifecycle = Lifecycle(
    container: container, haltGrace: .milliseconds(100), killGrace: .milliseconds(100)
  ) { exit.fire() }
  await lifecycle.requestHalt()
  await lifecycle.requestHalt()  // only the first request starts the sequence
  #expect(try await eventually { exit.fired > 0 })
  try await Task.sleep(for: .milliseconds(200))
  #expect(exit.fired == 1)
  // The halt request, then the forced kill.
  #expect(container.received == [Owner.systemdHalt.rawValue, Signal.kill.rawValue])
}

@Test func aGuestThatStopsInTimeIsNotForced() async throws {
  let container = FakeContainer(wedged: false)
  let exit = ExitFlag()
  let lifecycle = Lifecycle(
    container: container, haltGrace: .milliseconds(200), killGrace: .milliseconds(100)
  ) { exit.fire() }
  await lifecycle.requestHalt()
  await lifecycle.markStopped()
  try await Task.sleep(for: .milliseconds(700))
  #expect(exit.fired == 0)
  #expect(container.received == [Owner.systemdHalt.rawValue])
}

@Test func aGuestThatStopsAfterTheForcedKillIsNotForcedEither() async throws {
  let container = FakeContainer(wedged: false)
  let exit = ExitFlag()
  let lifecycle = Lifecycle(
    container: container, haltGrace: .milliseconds(100), killGrace: .seconds(2)
  ) { exit.fire() }
  await lifecycle.requestHalt()
  #expect(try await eventually { container.received.count == 2 })
  await lifecycle.markStopped()
  try await Task.sleep(for: .milliseconds(2500))
  #expect(exit.fired == 0)
  #expect(container.received == [Owner.systemdHalt.rawValue, Signal.kill.rawValue])
}
