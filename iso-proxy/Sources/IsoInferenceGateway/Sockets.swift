import Darwin

/// A session socket file as it was bound: its path and the file's identity,
/// so a later unlink removes this file and never one bound after it.
struct BoundSocket: Sendable, Equatable {
  let path: String
  let device: dev_t
  let inode: ino_t

  /// The socket file now at `path`; nil when there is none.
  init?(path: String) {
    guard let info = Self.status(path), info.st_mode & S_IFMT == S_IFSOCK else { return nil }
    self.path = path
    device = info.st_dev
    inode = info.st_ino
  }

  /// Unlinks `path` if it still names this socket file.
  func removeIfUnchanged() {
    guard BoundSocket(path: path) == self else { return }
    // The C path is borrowed for the call only.
    unsafe unlink(path)
  }

  /// Unlinks `path` if it is a socket file (and not, say, a directory or a
  /// symlink someone left in its place).
  static func removeStale(_ path: String) {
    guard BoundSocket(path: path) != nil else { return }
    // The C path is borrowed for the call only.
    unsafe unlink(path)
  }

  private static func status(_ path: String) -> stat? {
    var info = stat()
    // lstat writes only the one record borrowed here; the C path is borrowed too.
    guard unsafe lstat(path, &info) == 0 else { return nil }
    return info
  }
}

/// Writes one diagnostic line to standard error. Messages are fixed text
/// and host-assigned values only.
package func diagnostic(_ message: String) {
  let line = Array(("iso-inference: " + message + "\n").utf8)
  // write reads at most count bytes of the borrowed line buffer.
  _ = line.withUnsafeBytes { unsafe write(STDERR_FILENO, $0.baseAddress, $0.count) }
}
