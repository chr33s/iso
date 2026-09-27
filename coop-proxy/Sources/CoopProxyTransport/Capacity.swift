import NIOConcurrencyHelpers

/// Shared across event loops. A lease owns one slot until explicitly released
/// or destroyed; response headers alone never release a request lease.
public final class Capacity: Sendable {
  private let available: NIOLockedValueBox<Int>
  public init(_ count: Int) { available = NIOLockedValueBox(count) }

  func acquire() -> Lease? {
    let acquired = available.withLockedValue { slots in
      guard slots > 0 else { return false }
      slots -= 1
      return true
    }
    return acquired ? Lease(capacity: self) : nil
  }

  final class Lease: Sendable {
    private let owner: NIOLockedValueBox<Capacity?>
    init(capacity: Capacity) { owner = NIOLockedValueBox(capacity) }
    func release() {
      let capacity = owner.withLockedValue { owner in
        defer { owner = nil }
        return owner
      }
      capacity?.available.withLockedValue { $0 += 1 }
    }
    deinit { release() }
  }
}
