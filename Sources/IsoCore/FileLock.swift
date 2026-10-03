import Foundation
import Synchronization

package struct HostError: Error, Equatable, Sendable, CustomStringConvertible {
  package let message: String
  package init(_ message: String) { self.message = message }
  package var description: String { message }

  package static func posix(_ action: String, _ path: String, _ code: Int32 = errno) -> HostError {
    HostError("\(action) \(path): \(String(cString: strerror(code)))")
  }
}

/// Exclusive `flock(2)` on a shared lock path serializes host processes.
/// The lock is released by `release()` or when the descriptor is closed.
package final class FileLock: Sendable {
  private let descriptor: Mutex<Int32?>

  /// Blocks until `path` is locked, creating it (mode 0644) if needed.
  package init(path: String) throws(HostError) {
    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      } catch {
        throw HostError("Failed to create directory \(parent)")
      }
    }
    // The lock file carries no content; ownership is attached to its descriptor.
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw .posix("Failed to create lock file", path) }
    while flock(fd, LOCK_EX) != 0 {
      let code = errno
      if code == EINTR { continue }
      close(fd)
      throw .posix("Failed to acquire lock on", path, code)
    }
    descriptor = Mutex(fd)
  }

  /// `.<name>.lock` beside `target`, shared by all writers of that file.
  package static func sibling(of target: String) throws(HostError) -> FileLock {
    let parent = (target as NSString).deletingLastPathComponent
    let name = (target as NSString).lastPathComponent
    let lockName = ".\(name.isEmpty ? "iso" : name).lock"
    return try FileLock(path: parent.isEmpty ? lockName : parent + "/" + lockName)
  }

  package func release() {
    descriptor.withLock { descriptor in
      guard let fd = descriptor else { return }
      descriptor = nil
      close(fd)
    }
  }

  deinit { release() }
}

/// Runs `body` while holding the sibling lock of `target`.
package func withSiblingLock<T>(_ target: String, _ body: () throws -> T) throws -> T {
  let lock = try FileLock.sibling(of: target)
  defer { lock.release() }
  return try body()
}
