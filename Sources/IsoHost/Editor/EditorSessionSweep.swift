import Darwin
import IsoCore

/// Finds and ends every process confined by one sandboxed editor session's
/// profile, including descendants that left the editor's process tree and
/// group (`setsid` after a double fork). A process cannot leave its Seatbelt
/// sandbox, so membership is decided by what the profile alone grants: the
/// session-prefixed Mach name rule of `EditorSandboxPolicy`, which no other
/// profile names, checked with `sandbox_check(3)` for every process of this
/// user.
package enum EditorSessionSweep {
  /// `int sandbox_check(pid_t, const char *operation, int type, ...)`. On
  /// arm64 Darwin a variadic argument is passed on the stack after the eight
  /// argument registers, so the name is the ninth parameter and five
  /// placeholders fill x3–x7.
  typealias NamedCheck =
    @convention(c) (
      pid_t, UnsafePointer<CChar>?, Int32, Int, Int, Int, Int, Int, UnsafePointer<CChar>?
    ) -> Int32
  typealias PlainCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32

  static let filterGlobalName: Int32 = 2
  static let noReport: Int32 = 0x4000_0000

  /// The SPI, or nil where it is missing (sessions then refuse to start).
  static let check: (named: NamedCheck, plain: PlainCheck)? = {
    #if arch(arm64)
      guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else {
        return nil
      }
      return (
        unsafeBitCast(symbol, to: NamedCheck.self), unsafeBitCast(symbol, to: PlainCheck.self)
      )
    #else
      return nil
    #endif
  }()

  package static var available: Bool { check != nil }

  /// Granted only by the profile of the session whose root is `session`.
  static func marker(_ session: String) -> String { session + "/iso-session-marker" }
  /// Refused by that profile, allowed by any profile broad enough to allow
  /// the marker by accident.
  static func antiMarker(_ session: String) -> String { session + ".iso-session-marker" }

  /// Whether `pid` runs sandboxed under the profile of `session`.
  package static func isMember(_ pid: pid_t, session: String) -> Bool {
    guard let check else { return false }
    func allowed(_ name: String) -> Bool {
      name.withCString {
        check.named(pid, "mach-lookup", filterGlobalName | noReport, 0, 0, 0, 0, 0, $0) == 0
      }
    }
    return check.plain(pid, nil, 0) == 1 && allowed(marker(session))
      && !allowed(antiMarker(session))
  }

  /// This user's processes now confined by `session`'s profile.
  package static func members(session: String) -> [pid_t] {
    let size = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
    guard size > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size + 64)
    let filled = proc_listpids(
      UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    return pids.prefix(Int(filled) / MemoryLayout<pid_t>.size).filter {
      $0 > 0 && $0 != getpid() && isMember($0, session: session)
    }
  }

  /// Stops every member until none is left running (a stopped process cannot
  /// fork), confirming each after it stopped so a reused pid is resumed, not
  /// killed; then kills them all. Returns how many were ended.
  @discardableResult
  package static func end(session: String, passes: Int = 64) -> Int {
    guard available else { return 0 }
    var stopped = Set<pid_t>()
    for _ in 0..<passes {
      let fresh = members(session: session).filter { !stopped.contains($0) }
      if fresh.isEmpty { break }
      for pid in fresh where kill(pid, SIGSTOP) == 0 {
        if isMember(pid, session: session) {
          stopped.insert(pid)
        } else {
          kill(pid, SIGCONT)
        }
      }
    }
    for pid in stopped { kill(pid, SIGKILL) }
    return stopped.count
  }
}
