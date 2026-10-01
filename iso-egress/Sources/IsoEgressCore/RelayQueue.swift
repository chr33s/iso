import Foundation

/// Bytes held for one tunnel direction, and the shared ceiling across tunnels.
public struct RelayRoom: Equatable, Sendable {
  public var pending: Int
  public let perDirection: Int
  public let aggregateAvailable: Int

  /// How many more bytes this direction may read. Zero means stop reading.
  public var allowed: Int {
    max(0, min(perDirection - pending, aggregateAvailable))
  }
}

public final class RelayBudget: @unchecked Sendable {
  public static let shared = RelayBudget(cap: EgressBudgets.relayAggregate)
  private let lock = NSLock()
  private var used = 0
  public let cap: Int

  public init(cap: Int) { self.cap = cap }

  public var available: Int {
    lock.lock()
    defer { lock.unlock() }
    return max(0, cap - used)
  }

  public func reserve(_ requested: Int) -> Int {
    lock.lock()
    defer { lock.unlock() }
    let take = min(max(0, requested), max(0, cap - used))
    used += take
    return take
  }

  public func release(_ count: Int) {
    lock.lock()
    used = max(0, used - count)
    lock.unlock()
  }
}
