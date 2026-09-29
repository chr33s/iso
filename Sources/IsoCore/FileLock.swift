import Foundation

public struct HostError: Error, Equatable, Sendable, CustomStringConvertible {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var description: String { message }

  package static func posix(_ action: String, _ path: String, _ code: Int32 = errno) -> HostError {
    HostError("\(action) \(path): \(String(cString: strerror(code)))")
  }
}

/// Exclusive `flock(2)` on a lock file, compatible with the Rust host's
/// locks: both implementations lock the same path with `LOCK_EX`, so a Swift
/// and a Rust process serialize against each other during the port. The
/// lock is released by `release()` or when the descriptor is closed.
public final class FileLock: @unchecked Sendable {
  private var descriptor: Int32

  /// Blocks until `path` is locked, creating it (mode 0644) if needed.
  public init(path: String) throws(HostError) {
    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      } catch {
        throw HostError("Failed to create directory \(parent)")
      }
    }
    // O_TRUNC matches Rust's `File::create`; the file carries no content.
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
    guard fd >= 0 else { throw .posix("Failed to create lock file", path) }
    while flock(fd, LOCK_EX) != 0 {
      let code = errno
      if code == EINTR { continue }
      close(fd)
      throw .posix("Failed to acquire lock on", path, code)
    }
    descriptor = fd
  }

  /// `.<name>.lock` beside `target` — the Rust `fs_util::lock_sibling` path.
  public static func sibling(of target: String) throws(HostError) -> FileLock {
    let parent = (target as NSString).deletingLastPathComponent
    let name = (target as NSString).lastPathComponent
    let lockName = ".\(name.isEmpty ? "iso" : name).lock"
    return try FileLock(path: parent.isEmpty ? lockName : parent + "/" + lockName)
  }

  public func release() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }

  deinit { release() }
}

/// Runs `body` while holding the sibling lock of `target`.
public func withSiblingLock<T>(_ target: String, _ body: () throws -> T) throws -> T {
  let lock = try FileLock.sibling(of: target)
  defer { lock.release() }
  return try body()
}
