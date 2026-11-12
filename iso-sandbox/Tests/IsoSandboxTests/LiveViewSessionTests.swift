import Foundation
import IsoMacProtocol
import Testing

@testable import IsoSandboxCore

// docs/design/computer-use-live-view.md: what a session does with its
// viewers' messages, against a display that records what reaches it.

@MainActor
private final class FakeScreen: LiveViewScreen {
  let width = 64
  let height = 64
  var isActing = false
  private(set) var holds = 0
  private(set) var implicitReleases = 0
  private(set) var sent: [LiveViewInput] = []
  private(set) var typed = 0
  /// Whether typing asks `proceed` before each key, as the display does.
  var asksToProceed = true
  /// Whether typing stops when its task is cancelled, as the display does.
  var honoursCancellation = true

  func hold(_ kind: CUControl.Hold, seconds: TimeInterval) { holds += 1 }
  func releaseImplicitHold() { implicitReleases += 1 }
  func viewerSend(_ input: LiveViewInput, held: LiveViewHeld) throws { sent.append(input) }

  func viewerType(_ text: String, proceed: () throws -> Void) async throws {
    for _ in text {
      if asksToProceed { try proceed() }
      typed += 1
      if honoursCancellation {
        try await Task.sleep(for: .milliseconds(2))
      } else {
        try? await Task.sleep(for: .milliseconds(2))
      }
    }
  }

  func streamFrame(
    _ body: (UnsafeRawPointer, _ bytesPerRow: Int, _ damageSeq: UInt64) throws -> Void
  ) throws {
    throw SandboxError("no frame in this test")
  }
}

@MainActor
private func session(_ screen: FakeScreen) throws -> LiveViewSession {
  let session = LiveViewSession(screen: screen) { _ in }
  _ = try session.start()
  return session
}

private let paste = String(repeating: "a", count: LiveView.maxPaste)
private let keyDown = LiveViewInput.key(keyCode: 0, down: true)

/// Lets a started paste type for a while.
private func settle(_ milliseconds: Int = 60) async {
  try? await Task.sleep(for: .milliseconds(milliseconds))
}

@MainActor @Test func onlyTheViewerInControlReachesTheDisplay() async throws {
  let screen = FakeScreen()
  let live = try session(screen)
  defer { live.stop() }
  live.joined(1)
  live.joined(2)
  // View only: dropped without an answer, and no hold is taken.
  #expect(await live.handle(1, .input(keyDown)) == nil)
  #expect(screen.sent.isEmpty && screen.holds == 0)
  #expect(await live.handle(1, .take) == nil)
  #expect(await live.handle(2, .take)?.contains("another viewer has control") == true)
  #expect(await live.handle(2, .input(keyDown)) == nil)
  #expect(screen.sent.isEmpty)
  #expect(await live.handle(1, .input(keyDown)) == nil)
  #expect(screen.sent == [keyDown])
  // A host action in progress holds a press back, never a release.
  screen.isActing = true
  #expect(await live.handle(1, .input(.move(CUPoint(x: 1, y: 1))))?.contains("busy") == true)
  #expect(await live.handle(1, .input(.key(keyCode: 0, down: false))) == nil)
  #expect(screen.sent == [keyDown, .key(keyCode: 0, down: false)])
  #expect(live.counters.takeovers == 1 && live.counters.viewers == 2)
  #expect(live.counters.inputEvents == 2)
}

@MainActor @Test func aDisconnectReleasesWhatTheViewerHeldDown() async throws {
  let screen = FakeScreen()
  let live = try session(screen)
  defer { live.stop() }
  live.joined(1)
  _ = await live.handle(1, .take)
  _ = await live.handle(1, .input(keyDown))
  live.left(1)
  #expect(screen.sent == [keyDown, .key(keyCode: 0, down: false)])
  // The next viewer may take control at once.
  live.joined(2)
  #expect(await live.handle(2, .take) == nil)
}

@MainActor @Test func aPasteIsTypedApartFromItsViewersLaterMessages() async throws {
  let screen = FakeScreen()
  let live = try session(screen)
  defer { live.stop() }
  live.joined(1)
  _ = await live.handle(1, .take)
  // The message returns before the text is typed.
  #expect(await live.handle(1, .text(paste)) == nil)
  #expect(screen.typed < paste.count)
  await settle()
  #expect(screen.typed > 0 && screen.typed < paste.count)
  // One paste at a time, and other input still goes through meanwhile.
  #expect(await live.handle(1, .text("b"))?.contains("busy") == true)
  #expect(await live.handle(1, .input(keyDown)) == nil)
  #expect(screen.sent == [keyDown])
}

/// What ends a paste early: each must, with a display that only asks to
/// proceed and with one that only stops when cancelled.
@MainActor
private func pasteEnds(
  asksToProceed: Bool, honoursCancellation: Bool,
  by end: @MainActor (LiveViewSession) async -> Void
) async throws -> Bool {
  let screen = FakeScreen()
  screen.asksToProceed = asksToProceed
  screen.honoursCancellation = honoursCancellation
  let live = try session(screen)
  defer { live.stop() }
  live.joined(1)
  _ = await live.handle(1, .take)
  _ = await live.handle(1, .text(paste))
  await settle()
  guard screen.typed > 0, screen.typed < paste.count else { return false }
  await end(live)
  // The key in flight may land; nothing after it.
  let stoppedAt = screen.typed
  await settle()
  return screen.typed <= stoppedAt + 1 && screen.typed < paste.count
}

@MainActor @Test func aPasteEndsWhenItsViewerGivesUpControl() async throws {
  for (asks, cancels) in [(true, false), (false, true)] {
    #expect(
      try await pasteEnds(asksToProceed: asks, honoursCancellation: cancels) {
        _ = await $0.handle(1, .release)
      })
    #expect(try await pasteEnds(asksToProceed: asks, honoursCancellation: cancels) { $0.left(1) })
    #expect(try await pasteEnds(asksToProceed: asks, honoursCancellation: cancels) { $0.stop() })
  }
}

@MainActor @Test func anotherViewersReleaseOrDepartureLeavesAPasteRunning() async throws {
  let screen = FakeScreen()
  let live = try session(screen)
  defer { live.stop() }
  live.joined(1)
  live.joined(2)
  _ = await live.handle(1, .take)
  _ = await live.handle(1, .text(paste))
  await settle()
  let before = screen.typed
  _ = await live.handle(2, .release)
  live.left(2)
  // Long enough for several keys on a loaded machine.
  await settle(300)
  #expect(screen.typed > before + 1)
}

@MainActor @Test func aStoppedStreamCountsNoLateViewerAndStartsAgainClean() async throws {
  let screen = FakeScreen()
  let live = try session(screen)
  live.joined(1)
  _ = await live.handle(1, .take)
  _ = await live.handle(1, .input(keyDown))
  live.stop()
  #expect(!live.listening)
  // What the viewer held is let go as the stream ends.
  #expect(screen.sent == [keyDown, .key(keyCode: 0, down: false)])
  // A viewer that authenticated as the stream stopped is not counted.
  live.joined(2)
  #expect(live.counters.viewers == 1)
  // A new stream has no controller left over from the last.
  _ = try live.start()
  defer { live.stop() }
  live.joined(3)
  #expect(await live.handle(3, .take) == nil)
  #expect(live.counters.streams == 2 && live.counters.takeovers == 2)
}
