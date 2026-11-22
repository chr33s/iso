import IsoPolicy
import Synchronization

/// A byte budget (the gateway's shared request-buffer budget and each
/// session's share of it, §9.1). A lease holds its bytes until it is
/// released. Release is explicit: a lease that is dropped unreleased keeps
/// its bytes, so a missed release shows up as lost capacity, not as a
/// silent recovery that depends on object lifetimes.
package final class ByteBudget: Sendable {
  private struct State {
    var capacity: Int
    var free: Int
  }
  private let state: Mutex<State>

  package init(_ bytes: Int) { state = Mutex(State(capacity: bytes, free: bytes)) }

  /// Reserve `bytes` from this budget and, when given, from `inner` too:
  /// both or neither.
  package func reserve(_ bytes: Int, alsoFrom inner: ByteBudget? = nil) -> Lease? {
    guard take(bytes) else { return nil }
    guard let inner else { return Lease([(self, bytes)]) }
    guard inner.take(bytes) else {
      give(bytes)
      return nil
    }
    return Lease([(self, bytes), (inner, bytes)])
  }

  /// Registrations may tighten the budget; outstanding leases stay valid.
  package func tighten(to bytes: Int) {
    state.withLock { state in
      guard bytes < state.capacity else { return }
      state.free -= state.capacity - bytes
      state.capacity = bytes
    }
  }

  package var free: Int { state.withLock { $0.free } }
  package var capacity: Int { state.withLock { $0.capacity } }

  private func take(_ bytes: Int) -> Bool {
    state.withLock { state in
      guard bytes >= 0, bytes <= state.free else { return false }
      state.free -= bytes
      return true
    }
  }

  fileprivate func give(_ bytes: Int) { state.withLock { $0.free += bytes } }

  package final class Lease: Sendable {
    private let owners: Mutex<[(ByteBudget, Int)]>
    init(_ owners: [(ByteBudget, Int)]) { self.owners = Mutex(owners) }

    /// Returns the bytes once; later calls do nothing.
    package func release() {
      let taken = owners.withLock { owners in
        defer { owners = [] }
        return owners
      }
      for (budget, bytes) in taken { budget.give(bytes) }
    }
  }
}

/// A counted slot pool (connections per session and shared). Like a
/// `ByteBudget` lease, a slot returns only when released.
package final class SlotPool: Sendable {
  private let free: Mutex<Int>
  package let capacity: Int

  package init(_ count: Int) {
    capacity = count
    free = Mutex(count)
  }

  package func acquire() -> Slot? {
    let granted = free.withLock { free -> Bool in
      guard free > 0 else { return false }
      free -= 1
      return true
    }
    return granted ? Slot(pool: self) : nil
  }

  package var available: Int { free.withLock { $0 } }

  fileprivate func give() { free.withLock { $0 += 1 } }

  package final class Slot: Sendable {
    private let pool: Mutex<SlotPool?>
    init(pool: SlotPool) { self.pool = Mutex(pool) }

    /// Returns the slot once; later calls do nothing.
    package func release() {
      let owner = pool.withLock { value -> SlotPool? in
        defer { value = nil }
        return value
      }
      owner?.give()
    }
  }
}

/// Cheap per-listener rejection of repeated authentication failures, so
/// unauthorized traffic cannot allocate unbounded work (§9.1): IsoPolicy's
/// sliding window over the last minute, on the monotonic clock.
package final class FailureWindow: Sendable {
  private let window: Mutex<SlidingWindow>
  private let now: @Sendable () -> UInt64?

  package init(
    limit: Int,
    now: @escaping @Sendable () -> UInt64? = { SystemMonotonicClock().nanoseconds() }
  ) {
    window = Mutex(SlidingWindow(capacity: limit, windowSeconds: 60))
    self.now = now
  }

  package func record() {
    guard let instant = now() else { return }
    window.withLock { window in
      window.evict(now: instant)
      if !window.isFull { window.admit(instant) }
    }
  }

  /// True once `limit` failures fall within the last minute. An unusable
  /// clock counts as tripped.
  package var tripped: Bool {
    guard let instant = now() else { return true }
    return window.withLock { window in
      window.evict(now: instant)
      return window.isFull
    }
  }
}
