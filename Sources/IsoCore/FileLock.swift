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

  private init(descriptor fd: Int32) { descriptor = Mutex(fd) }

  /// Locks `path` without waiting; nil when another descriptor holds it.
  /// For process-lifetime ownership, where a second owner must fail fast.
  package static func attempt(path: String) throws(HostError) -> FileLock? {
    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      } catch {
        throw HostError("Failed to create directory \(parent)")
      }
    }
    let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw .posix("Failed to create lock file", path) }
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      if code == EINTR { continue }
      close(fd)
      if code == EWOULDBLOCK { return nil }
      throw .posix("Failed to acquire lock on", path, code)
    }
    return FileLock(descriptor: fd)
  }

  /// Locks an owner-only `path` opened without following a symlink, waiting
  /// at most `timeout`; nil when another holder keeps it that long. For
  /// best-effort writers that must not stall the operation they describe.
  package static func bounded(path: String, timeout: Duration) throws(HostError) -> FileLock? {
    guard let fd = try openRegularFile(path, O_WRONLY | O_CREAT) else {
      throw .posix("Failed to open lock file", path, ENOENT)
    }
    let deadline = ContinuousClock.now + timeout
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      guard code == EINTR || code == EWOULDBLOCK else {
        close(fd)
        throw .posix("Failed to acquire lock on", path, code)
      }
      guard ContinuousClock.now < deadline else {
        close(fd)
        return nil
      }
      usleep(5_000)
    }
    return FileLock(descriptor: fd)
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

/// `open(2)` without following a symlink, refusing anything but a regular
/// file (`O_CLOEXEC` and owner-only creation implied). Nil only when the file
/// is absent and `flags` does not create it.
package func openRegularFile(_ path: String, _ flags: Int32) throws(HostError) -> Int32? {
  let fd = open(path, flags | O_NOFOLLOW | O_CLOEXEC, 0o600)
  if fd < 0 {
    let code = errno
    if code == ENOENT && flags & O_CREAT == 0 { return nil }
    throw .posix("Failed to open", path, code)
  }
  var status = stat()
  guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
    close(fd)
    throw HostError("\(path) is not a regular file")
  }
  return fd
}

/// Runs `body` while holding the sibling lock of `target`.
package func withSiblingLock<T>(_ target: String, _ body: () throws -> T) throws -> T {
  let lock = try FileLock.sibling(of: target)
  defer { lock.release() }
  return try body()
}
