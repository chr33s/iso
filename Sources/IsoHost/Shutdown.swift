import Foundation
import IsoCore
import Synchronization

/// SIGINT/SIGTERM handling for long lifecycle operations: the first signal
/// sets a sticky flag instead of terminating, so an interrupted create or
/// boot can clean up. The flag stays set for the rest of the process.
/// Outside such a scope, `ChildGroups` handlers apply.
public enum Shutdown {
  static let requested = Atomic<Bool>(false)

  /// Install the handlers; returns a guard that restores the previous ones.
  public static func install() -> Guard {
    let handler: @convention(c) (Int32) -> Void = { _ in
      Shutdown.requested.store(true, ordering: .relaxed)
    }
    let previousInterrupt = signal(SIGINT, handler)
    let previousTerminate = signal(SIGTERM, handler)
    return Guard(interrupt: previousInterrupt, terminate: previousTerminate)
  }

  public final class Guard: @unchecked Sendable {
    let interrupt: sig_t?
    let terminate: sig_t?
    init(interrupt: sig_t?, terminate: sig_t?) {
      self.interrupt = interrupt
      self.terminate = terminate
    }
    public func restore() {
      signal(SIGINT, interrupt)
      signal(SIGTERM, terminate)
    }
  }

  public static var isRequested: Bool { requested.load(ordering: .relaxed) }

  public static func check() throws(HostError) {
    if isRequested { throw HostError("Interrupted by signal — cleaning up") }
  }

  /// Test seam.
  static func reset() { requested.store(false, ordering: .relaxed) }
  static func request() { requested.store(true, ordering: .relaxed) }
}
