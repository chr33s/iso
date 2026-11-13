import Darwin
import Foundation

/// A companion process as iso observed it once it was running: its PID, the
/// kernel's record of when it started, and its executable. A reused PID has
/// another start time, so only the process iso started matches; neither its
/// command line nor its name is consulted.
struct ProcessIdentity: Codable, Equatable, Sendable {
  let schemaVersion: UInt32
  let pid: Int32
  let startSeconds: UInt64
  let startMicroseconds: UInt64
  let executable: String

  init(pid: Int32, startSeconds: UInt64, startMicroseconds: UInt64, executable: String) {
    schemaVersion = 1
    self.pid = pid
    self.startSeconds = startSeconds
    self.startMicroseconds = startMicroseconds
    self.executable = executable
  }

  static func observe(_ pid: Int32) -> ProcessIdentity? {
    guard let start = startTime(pid), let executable = executablePath(pid) else { return nil }
    return ProcessIdentity(
      pid: pid, startSeconds: start.seconds, startMicroseconds: start.microseconds,
      executable: executable)
  }

  static func startTime(_ pid: Int32) -> (seconds: UInt64, microseconds: UInt64)? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = proc_pidinfo(
      pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard size == MemoryLayout<proc_bsdinfo>.size else { return nil }
    return (info.pbi_start_tvsec, info.pbi_start_tvusec)
  }

  static func executablePath(_ pid: Int32) -> String? {
    var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
    return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  static func path(forPIDFile pidPath: String) -> String {
    (pidPath.hasSuffix(".pid") ? String(pidPath.dropLast(4)) : pidPath) + ".identity.json"
  }

  func save(forPIDFile pidPath: String) throws {
    try StateStore.writeControlFile(self, to: Self.path(forPIDFile: pidPath))
  }

  static func load(forPIDFile pidPath: String) -> ProcessIdentity? {
    let path = path(forPIDFile: pidPath)
    guard let bytes = try? StateStore.readControlFile(path) ?? nil,
      let identity = try? StateStore.decode(ProcessIdentity.self, bytes, path: path),
      identity.schemaVersion == 1, identity.pid > 0
    else { return nil }
    return identity
  }

  var isAlive: Bool {
    guard let start = Self.startTime(pid) else { return false }
    return matches(start: start, executable: Self.executablePath(pid))
  }

  /// PID plus start time identify the process (a reused PID has another start
  /// time); the image path must also match while the kernel reports one. It
  /// reports none once the path no longer exists (uninstall, or `iso update`
  /// renaming over it), so an unknown path does not disown the process.
  func matches(start: (seconds: UInt64, microseconds: UInt64), executable current: String?)
    -> Bool
  {
    start.seconds == startSeconds && start.microseconds == startMicroseconds
      && (current.map { $0 == executable } ?? true)
  }
}
