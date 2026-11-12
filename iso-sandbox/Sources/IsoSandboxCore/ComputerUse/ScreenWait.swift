import Foundation
import IsoMacProtocol

/// One wait for a region of the display to settle
/// (docs/design/computer-use-screen-sync.md §4). A pure state machine fed
/// `(elapsed, latest seq in the region)` after each sample; `run` drives it
/// with injected sampling, sleeping and binding checks, so tests use a fake
/// clock.
package struct ScreenWait: Sendable {
  /// A caller's wait, validated against the display.
  package struct Parameters: Equatable, Sendable {
    package var since: UInt64?
    package var idleMs: Int
    package var timeoutMs: Int
    package var until: GuestCUWaitUntil
    package var region: GuestCURegion?

    /// Refuses `invalid_action` unless every field is in range: durations in
    /// `GuestCUProtocol.Wait`, `region` inside the display with a positive
    /// size, and `since` no later than `current`.
    package static func validated(
      since: UInt64?, idleMs: Int?, timeoutMs: Int?, until: GuestCUWaitUntil?,
      region: GuestCURegion?, width: Int, height: Int, current: UInt64
    ) throws -> Parameters {
      func refuse(_ why: String) -> SandboxError {
        var e = SandboxError(why, refusal: .invalidAction)
        e.beforeInput = true
        return e
      }
      let idle = idleMs ?? GuestCUProtocol.Wait.defaultIdleMs
      guard GuestCUProtocol.Wait.idleMs.contains(idle) else {
        throw refuse(
          "idleMs must be \(GuestCUProtocol.Wait.idleMs.lowerBound)-\(GuestCUProtocol.Wait.idleMs.upperBound)"
        )
      }
      let timeout = timeoutMs ?? GuestCUProtocol.Wait.defaultTimeoutMs
      guard GuestCUProtocol.Wait.timeoutMs.contains(timeout) else {
        throw refuse(
          "timeoutMs must be \(GuestCUProtocol.Wait.timeoutMs.lowerBound)-\(GuestCUProtocol.Wait.timeoutMs.upperBound)"
        )
      }
      if let r = region {
        guard r.width >= 1, r.height >= 1, r.x >= 0, r.y >= 0, r.width <= width,
          r.height <= height, r.x <= width - r.width, r.y <= height - r.height
        else { throw refuse("region must lie inside \(width)×\(height)") }
      }
      if let since, since > current {
        throw refuse("since \(since) is later than the current damageSeq \(current)")
      }
      return Parameters(
        since: since, idleMs: idle, timeoutMs: timeout, until: until ?? .change, region: region)
    }
  }

  /// 30 Hz while a wait runs (§9 records the measurement still owed).
  package static let tickMs = 33

  private let parameters: Parameters
  private var seen: UInt64
  /// When the region last changed after `since`; nil while it has not.
  private var changedAt: Int?

  package init(_ parameters: Parameters, since: UInt64) {
    self.parameters = parameters
    seen = since
  }

  /// One sample's evidence; an outcome ends the wait. `elapsedMs` counts from
  /// the entry sample.
  package mutating func feed(elapsedMs: Int, latest: UInt64) -> GuestCUWaitOutcome? {
    if latest > seen {
      seen = latest
      changedAt = elapsedMs
    }
    // Quiet is counted from the later of entry and the last change.
    if elapsedMs - (changedAt ?? 0) >= parameters.idleMs {
      if changedAt != nil { return .settled }
      if parameters.until == .idle { return .unchanged }
    }
    return elapsedMs >= parameters.timeoutMs ? .timedOut : nil
  }

  /// Feeds `first` (the entry sample), then after each `sleep` re-checks the
  /// binding with `check` (a host hold or a broken session ends the wait
  /// with its refusal) and takes a new sample.
  nonisolated(nonsending) package static func run(
    _ wait: ScreenWait, first: UInt64, elapsedMs: () -> Int,
    sleep: nonisolated(nonsending) () async throws -> Void,
    check: () throws -> Void, sample: () throws -> UInt64
  ) async throws -> GuestCUWaitResult {
    var wait = wait
    var latest = first
    while true {
      let t = elapsedMs()
      if let outcome = wait.feed(elapsedMs: t, latest: latest) {
        return GuestCUWaitResult(outcome: outcome, elapsedMs: t)
      }
      try await sleep()
      try check()
      latest = try sample()
    }
  }
}

/// One wait at a time per sandbox for each origin. The guest link serves
/// two connections, each blocking a thread for its request, and the guest's
/// slot keeps one free for `status`. The host has its own, so a guest that
/// waits in a loop cannot refuse the host's `cu wait`.
package struct CUWaitSlots: Sendable {
  private var held: Set<CUOrigin> = []

  package init() {}

  package mutating func take(_ origin: CUOrigin) throws {
    guard held.insert(origin).inserted else {
      var e = SandboxError("another wait is in progress", refusal: .busy)
      e.beforeInput = true
      throw e
    }
  }

  package mutating func free(_ origin: CUOrigin) { held.remove(origin) }
}
