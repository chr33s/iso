import Darwin
import Foundation

/// `~/.iso/run/leases/<sandbox>.json` (`iso.vm-lease/v1`): what one running VM
/// uses, written by its owner process and held under an exclusive `flock` until
/// that process exits.
/// Other local tools (iso-ci's scheduler) count live leases toward a Mac's shared CPU, memory and
/// two-macOS-VM ceilings; a lease whose lock is free is stale and ignored.
package enum VMLease {
  package static let schema = "iso.vm-lease/v1"

  /// The invoking user's own home (not `$HOME`, which launchd may not set).
  package static var directory: URL {
    let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } }
    return URL(fileURLWithPath: home ?? NSHomeDirectory(), isDirectory: true)
      .appendingPathComponent(".iso/run/leases", isDirectory: true)
  }

  /// Writes and locks the lease; the returned descriptor must stay open for the
  /// VM's lifetime.
  /// Best effort: the VM runs without one (then not counted) rather than failing to boot.
  package static func hold(
    sandbox: String, guestOS: String, cpus: Int, memoryBytes: UInt64, directory: URL = directory
  ) -> Int32? {
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      return nil
    }
    let path = directory.appendingPathComponent("\(sandbox).json").path
    let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0, ftruncate(fd, 0) == 0 else {
      close(fd)
      return nil
    }
    let body: [String: Any] = [
      "schema": schema, "sandbox": sandbox, "guest_os": guestOS, "cpus": cpus,
      "memory_mib": Int(memoryBytes >> 20), "pid": Int(getpid()),
      "started_at": ISO8601DateFormatter().string(from: Date()),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
      data.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == data.count
    else {
      close(fd)
      return nil
    }
    _ = fsync(fd)
    return fd
  }
}
