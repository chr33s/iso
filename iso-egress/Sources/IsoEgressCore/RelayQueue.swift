import Synchronization

/// Bytes held for one tunnel direction, and the shared ceiling across tunnels.
package struct RelayRoom: Equatable, Sendable {
  package var pending: Int
  package let perDirection: Int
  package let aggregateAvailable: Int

  /// How many more bytes this direction may read. Zero means stop reading.
  package var allowed: Int {
    max(0, min(perDirection - pending, aggregateAvailable))
  }
}

package final class RelayBudget: Sendable {
  package static let shared = RelayBudget(cap: EgressBudgets.relayAggregate)
  private let used = Mutex(0)
  package let cap: Int

  package init(cap: Int) { self.cap = cap }

  package var available: Int {
    used.withLock { max(0, cap - $0) }
  }

  package func reserve(_ requested: Int) -> Int {
    used.withLock { used in
      let take = min(max(0, requested), max(0, cap - used))
      used += take
      return take
    }
  }

  package func release(_ count: Int) {
    used.withLock { $0 = max(0, $0 - count) }
  }
}
