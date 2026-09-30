import Darwin
import IsoInferenceCore

/// The kernel's view of a process: command name, owner and start time. A
/// PID plus start time names one process even after the PID is reused.
public struct ProcessIdentity: Sendable, Equatable {
  public let command: String
  public let uid: uid_t
  public let start: ProcessStart

  public static func of(_ pid: pid_t) -> ProcessIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let command = withUnsafeBytes(of: info.pbi_comm) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return ProcessIdentity(
      command: command, uid: info.pbi_uid,
      start: ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec))
  }
}
