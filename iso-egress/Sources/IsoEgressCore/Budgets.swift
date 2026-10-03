import Darwin
import Foundation

/// Bounds from the filtered-egress spec. These are limits, not measured performance.
package enum EgressBudgets {
  package static let maxHeadBytes = 16 * 1024
  package static let maxHeaders = 64
  package static let maxTargetBytes = 1024
  package static let head = Duration.seconds(5)
  package static let dns = Duration.seconds(5)
  package static let connect = Duration.seconds(10)
  package static let idleTunnel = Duration.seconds(300)
  package static let lease = Duration.seconds(2)
  package static let maxSockets = 128
  package static let maxTunnels = 64
  package static let maxDNS = 16
  package static let relayQueue = 256 * 1024
  package static let relayAggregate = 32 * 1024 * 1024
}

package enum Monotonic {
  package static func now() -> UInt64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return UInt64(time.tv_sec) * 1_000_000_000 &+ UInt64(time.tv_nsec)
  }

  package static func nanoseconds(_ duration: Duration) -> UInt64 {
    let (seconds, attoseconds) = duration.components
    let whole = UInt64(max(0, seconds)) * 1_000_000_000
    let fraction = UInt64(attoseconds / 1_000_000_000)
    return whole &+ fraction
  }

  /// True while `now` is within `limit` nanoseconds after `start`. A backward
  /// step is closed.
  package static func within(_ start: UInt64, now: UInt64, limit: UInt64) -> Bool {
    now >= start && now &- start <= limit
  }
}
