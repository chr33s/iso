import Darwin
import IsoInferenceCore

/// The kernel's view of a process: command name, owner and start time. A
/// PID plus start time names one process even after the PID is reused.
package struct ProcessIdentity: Sendable, Equatable {
  package let command: String
  package let uid: uid_t
  package let start: ProcessStart

  package init(command: String, uid: uid_t, start: ProcessStart) {
    self.command = command
    self.uid = uid
    self.start = start
  }

  package static func of(_ pid: pid_t) -> ProcessIdentity? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    // proc_pidinfo writes at most `size` bytes into the one record borrowed here.
    guard unsafe proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    // pbi_comm is a fixed-size inline array of the record; read up to its NUL.
    let command = withUnsafeBytes(of: info.pbi_comm) { raw in
      unsafe String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return ProcessIdentity(
      command: command, uid: info.pbi_uid,
      start: ProcessStart(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec))
  }

  /// The kernel's path of the executable `pid` runs (`proc_pidpath`).
  package static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    // proc_pidpath writes at most `buffer.count` bytes into the buffer borrowed here.
    let length = buffer.withUnsafeMutableBytes { raw in
      unsafe proc_pidpath(pid, raw.baseAddress, UInt32(raw.count))
    }
    guard length > 0 else { return nil }
    return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
  }
}
