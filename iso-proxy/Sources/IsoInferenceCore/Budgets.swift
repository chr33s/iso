import Synchronization

/// A shared byte budget (the gateway request-buffer budget, §9.1). A lease
/// holds its bytes until released or destroyed.
public final class ByteBudget: Sendable {
  private let available: Mutex<Int>
  private let capacity: Mutex<Int>

  public init(_ bytes: Int) {
    available = Mutex(bytes)
    capacity = Mutex(bytes)
  }

  public func reserve(_ bytes: Int) -> Lease? {
    let granted = available.withLock { free -> Bool in
      guard bytes >= 0, bytes <= free else { return false }
      free -= bytes
      return true
    }
    return granted ? Lease(budget: self, bytes: bytes) : nil
  }

  /// Registrations may tighten the budget; outstanding leases stay valid.
  public func tighten(to bytes: Int) {
    let reduction = capacity.withLock { current -> Int in
      guard bytes < current else { return 0 }
      defer { current = bytes }
      return current - bytes
    }
    if reduction > 0 { available.withLock { $0 -= reduction } }
  }

  public var free: Int { available.withLock { $0 } }

  fileprivate func release(_ bytes: Int) { available.withLock { $0 += bytes } }

  public final class Lease: Sendable {
    private let owner: Mutex<(ByteBudget, Int)?>
    init(budget: ByteBudget, bytes: Int) { owner = Mutex((budget, bytes)) }
    public func release() {
      let taken = owner.withLock { value -> (ByteBudget, Int)? in
        defer { value = nil }
        return value
      }
      if let (budget, bytes) = taken { budget.release(bytes) }
    }
    deinit { release() }
  }
}

/// A counted slot pool (connections per session and shared).
public final class SlotPool: Sendable {
  private let available: Mutex<Int>
  public init(_ count: Int) { available = Mutex(count) }

  public func acquire() -> Slot? {
    let granted = available.withLock { free -> Bool in
      guard free > 0 else { return false }
      free -= 1
      return true
    }
    return granted ? Slot(pool: self) : nil
  }

  fileprivate func release() { available.withLock { $0 += 1 } }

  public final class Slot: Sendable {
    private let pool: Mutex<SlotPool?>
    init(pool: SlotPool) { self.pool = Mutex(pool) }
    public func release() {
      let owner = pool.withLock { value -> SlotPool? in
        defer { value = nil }
        return value
      }
      owner?.release()
    }
    deinit { release() }
  }
}

/// Cheap per-listener rejection of repeated authentication failures, so
/// unauthorized traffic cannot allocate unbounded work (§9.1).
public final class FailureWindow: Sendable {
  private let events: Mutex<[ContinuousClock.Instant]>
  private let limit: Int
  private let now: @Sendable () -> ContinuousClock.Instant

  public init(
    limit: Int, now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
  ) {
    events = Mutex([])
    self.limit = limit
    self.now = now
  }

  public func record() {
    let instant = now()
    events.withLock { list in
      list.removeAll { instant - $0 >= .seconds(60) }
      if list.count < limit * 2 { list.append(instant) }
    }
  }

  public var tripped: Bool {
    let instant = now()
    return events.withLock { list in
      list.removeAll { instant - $0 >= .seconds(60) }
      return list.count >= limit
    }
  }
}
