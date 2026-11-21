import Foundation
import os

/// The children `ProcessRunner` is running, so a signal that terminates iso
/// also reaches them. Ctrl-C reaches only the foreground group, so without this
/// a signal terminating iso would orphan its own-group children (a `pull` tar
/// pipe would keep writing into the host directory). Attached children share
/// iso's group for the terminal, but a signal sent to iso's pid alone (`kill`)
/// still misses them, and an orphaned workload `ssh` would outlive its
/// supervisor. Startup handlers forward the signal to every live child, then
/// terminate iso; `Shutdown.install()` supersedes them for its scope.
package enum ChildGroups {
  static let capacity = 256

  /// How a registered child is signalled.
  enum Kind {
    /// Its own process group: the whole group (`kill(-pgid)`).
    case group
    /// Attached to iso's group: the process alone (`kill(pid)`).
    case attached
  }

  /// One fixed table of pids. The signal handler reads it without locking (a
  /// `Mutex` is not async-signal-safe), so it stays raw memory.
  struct Table {
    let slots: UnsafeMutablePointer<Int32>

    static func allocate() -> Table {
      let slots = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
      slots.initialize(repeating: 0, count: capacity)
      return Table(slots: slots)
    }
  }

  nonisolated(unsafe) static let slots: Table = .allocate()
  nonisolated(unsafe) static let attached: Table = .allocate()
  nonisolated(unsafe) static var lock = os_unfair_lock()

  static func table(_ kind: Kind) -> Table {
    switch kind {
    case .group: slots
    case .attached: attached
    }
  }

  static func register(_ pid: pid_t, _ kind: Kind = .group) {
    let table = table(kind)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    for index in 0..<capacity where table.slots[index] == 0 {
      table.slots[index] = pid
      return
    }
  }

  static func unregister(_ pid: pid_t, _ kind: Kind = .group) {
    let table = table(kind)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    for index in 0..<capacity where table.slots[index] == pid { table.slots[index] = 0 }
  }

  static func live(_ kind: Kind) -> [pid_t] {
    let table = table(kind)
    os_unfair_lock_lock(&lock)
    defer { os_unfair_lock_unlock(&lock) }
    return (0..<capacity).map { table.slots[$0] }.filter { $0 > 0 }
  }

  static var live: [pid_t] { live(.group) }

  /// Async-signal-safe: plain loads and kill(2) only.
  static func forward(_ signalNumber: Int32, groups: Table, attached: Table) {
    for index in 0..<capacity {
      let group = groups.slots[index]
      if group > 0 { kill(-group, signalNumber) }
      let process = attached.slots[index]
      if process > 0 { kill(process, signalNumber) }
    }
  }

  /// SIGINT, SIGTERM and SIGHUP: send SIGTERM to every live child, then
  /// terminate with the default action.
  package static func installTerminationHandlers() {
    // Both tables are lazily initialized globals (swift_once, malloc): touch
    // them now so the handler never runs an initializer in signal context.
    _ = slots
    _ = attached
    let handler: @convention(c) (Int32) -> Void = { signalNumber in
      ChildGroups.forward(SIGTERM, groups: ChildGroups.slots, attached: ChildGroups.attached)
      signal(signalNumber, SIG_DFL)
      raise(signalNumber)
    }
    for signalNumber in [SIGINT, SIGTERM, SIGHUP] { signal(signalNumber, handler) }
  }
}
