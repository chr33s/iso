import Foundation

/// How many refusals a peer the owner does not trust (a guest, a loopback client)
/// may put in the owner's log: 20 a minute, so reconnecting or resending cannot
/// grow the log without bound.
/// The first refusal of the next minute reports how many went unlogged.
package struct RejectionBudget: Sendable {
  package static let perMinute = 20
  private var count = 0
  private var windowStart: Date

  package init(now: Date = Date()) { windowStart = now }

  /// Whether to log a refusal at `now`, and how many of the minute before
  /// went unlogged.
  package mutating func admit(at now: Date = Date()) -> (emit: Bool, suppressed: Int) {
    if now.timeIntervalSince(windowStart) > 60 {
      let dropped = max(0, count - Self.perMinute)
      count = 1
      windowStart = now
      return (true, dropped)
    }
    count += 1
    return (count <= Self.perMinute, 0)
  }
}
