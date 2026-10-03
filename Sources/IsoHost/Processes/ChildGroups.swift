import Foundation
import os

/// Process groups of the children `ProcessRunner` spawns into their own
/// group. A terminal's Ctrl-C reaches only the foreground group, so without
/// this a signal that terminates iso would orphan them (a `pull` tar pipe
/// would keep writing into the host directory). The handlers installed at
/// startup forward the signal to every live group, then let it terminate
/// iso as it would have. `Shutdown.install()` supersedes them for its
/// scope (cleanup runs to completion there) and restores them after.
package enum ChildGroups {
  static let capacity = 256
  nonisolated(unsafe) static let slots: UnsafeMutablePointer<Int32> = {
    let slots = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
    slots.initialize(repeating: 0, count: capacity)
    return slots
  }()
  nonisolated(unsafe) static var lock = os_unfair_lock()

  static func register(_ group: pid_t) {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    for index in 0..<capacity where slots[index] == 0 {
      slots[index] = group
      return
    }
  }

  static func unregister(_ group: pid_t) {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    for index in 0..<capacity where slots[index] == group { slots[index] = 0 }
  }

  static var live: [pid_t] {
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return (0..<capacity).map { slots[$0] }.filter { $0 > 0 }
  }

  /// SIGINT, SIGTERM and SIGHUP: signal every live child group, then
  /// terminate with the default action.
  package static func installTerminationHandlers() {
    let handler: @convention(c) (Int32) -> Void = { signalNumber in
      // Async-signal-safe: plain loads and kill(2) only.
      for index in 0..<ChildGroups.capacity {
        let group = ChildGroups.slots[index]
        if group > 0 { kill(-group, SIGTERM) }
      }
      signal(signalNumber, SIG_DFL)
      raise(signalNumber)
    }
    for signalNumber in [SIGINT, SIGTERM, SIGHUP] { signal(signalNumber, handler) }
  }
}
