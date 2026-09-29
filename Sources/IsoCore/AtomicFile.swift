import Foundation

/// Atomic replacement: write a writer-unique sibling temporary file, fsync,
/// set its mode, then `rename(2)` over the target. On any failure the
/// temporary file is removed and the previous target is left intact.
public enum AtomicFile {
  public enum ModePolicy: Sendable, Equatable {
    /// Keep an existing file's mode; new files get `mode`.
    case preserveExisting(default: mode_t)
    /// Use `mode`, but never widen an existing file: the result is
    /// `existing & mode` (the Rust `atomic_write_with_mode` rule).
    case atMost(mode_t)
  }

  public static func write(_ bytes: [UInt8], to path: String, mode policy: ModePolicy)
    throws(HostError)
  {
    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      } catch {
        throw HostError("Failed to create directory \(parent)")
      }
    }
    // The mode of what the path names (following a symlink, as Rust's
    // `fs::metadata` does): a dotfiles link to a 0600 file must not come
    // back as a link-mode (0755) regular file.
    var existing = stat()
    let exists = stat(path, &existing) == 0
    let permissions: mode_t
    switch policy {
    case .preserveExisting(let fallback):
      permissions = exists ? existing.st_mode & 0o7777 : fallback
    case .atMost(let mode): permissions = exists ? existing.st_mode & 0o777 & mode : mode
    }

    let temporary = temporaryPath(for: path)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw .posix("Failed to write temp file", temporary) }
    var published = false
    defer {
      if !published { unlink(temporary) }
    }
    do {
      defer { close(fd) }
      try writeAll(fd, bytes, temporary)
      guard fchmod(fd, permissions) == 0 else {
        throw HostError.posix("Failed to set permissions on", temporary)
      }
      guard fsync(fd) == 0 else { throw HostError.posix("Failed to sync", temporary) }
    }
    guard rename(temporary, path) == 0 else {
      throw .posix("Failed to rename \(temporary) ->", path)
    }
    published = true
  }

  /// Create `path` only if nothing (not even a dangling symlink) exists there.
  public static func createExclusive(_ bytes: [UInt8], at path: String, mode: mode_t)
    throws(HostError)
  {
    let parent = (path as NSString).deletingLastPathComponent
    if !parent.isEmpty {
      do {
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      } catch {
        throw HostError("Failed to create directory \(parent)")
      }
    }
    let temporary = temporaryPath(for: path)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw .posix("Failed to write temp file", temporary) }
    defer { unlink(temporary) }
    do {
      defer { close(fd) }
      try writeAll(fd, bytes, temporary)
      guard fchmod(fd, mode) == 0 else {
        throw HostError.posix("Failed to set permissions on", temporary)
      }
      guard fsync(fd) == 0 else { throw HostError.posix("Failed to sync", temporary) }
    }
    // link(2) fails with EEXIST for any existing entry, including symlinks.
    guard link(temporary, path) == 0 else {
      let code = errno
      if code == EEXIST { throw HostError("\(path) already exists") }
      throw .posix("Failed to create", path, code)
    }
  }

  private static func writeAll(_ fd: Int32, _ bytes: [UInt8], _ path: String) throws(HostError) {
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if written < 0 {
        if errno == EINTR { continue }
        throw .posix("Failed to write", path)
      }
      offset += written
    }
  }

  package static func temporaryPath(for path: String) -> String {
    let parent = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    var random = UInt64(0)
    arc4random_buf(&random, MemoryLayout<UInt64>.size)
    let file = ".\(name).\(getpid()).\(String(random, radix: 16)).tmp"
    return parent.isEmpty ? file : parent + "/" + file
  }
}
