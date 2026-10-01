import Darwin
import Foundation

/// Bounds from the filtered-egress spec. These are limits, not measured performance.
public enum EgressBudgets {
  public static let maxHeaders = 64
  public static let maxTargetBytes = 1024
  public static let head = Duration.seconds(5)
  public static let dns = Duration.seconds(5)
  public static let connect = Duration.seconds(10)
  public static let idleTunnel = Duration.seconds(300)
  public static let lease = Duration.seconds(2)
  public static let maxSockets = 128
  public static let maxTunnels = 64
  public static let maxDNS = 16
}

public enum Monotonic {
  public static func now() -> UInt64 {
    var time = timespec()
    clock_gettime(CLOCK_MONOTONIC, &time)
    return UInt64(time.tv_sec) * 1_000_000_000 &+ UInt64(time.tv_nsec)
  }

  public static func nanoseconds(_ duration: Duration) -> UInt64 {
    let (seconds, attoseconds) = duration.components
    let whole = UInt64(max(0, seconds)) * 1_000_000_000
    let fraction = UInt64(attoseconds / 1_000_000_000)
    return whole &+ fraction
  }

  /// True while `now` is within `limit` nanoseconds after `start`. A backward
  /// step is closed.
  public static func within(_ start: UInt64, now: UInt64, limit: UInt64) -> Bool {
    now >= start && now &- start <= limit
  }
}
