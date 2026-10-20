import Foundation

/// Private-file helpers for the controller data root. Every path written
/// here is derived from validated identifiers, never from guest bytes.
package enum PrivateFiles {
  /// Creates `path` (and parents) as directories owned by this user with
  /// mode 0700; refuses an existing non-directory, symlink, or a directory
  /// owned by another user or accessible to group/other.
  package static func ensureDirectory(_ path: String) throws(CIError) {
    var status = stat()
    if lstat(path, &status) != 0 {
      guard errno == ENOENT else { throw CIError.storage("cannot inspect \(path)") }
      let parent = (path as NSString).deletingLastPathComponent
      if !parent.isEmpty && parent != path && parent != "/" {
        var parentStatus = stat()
        if lstat(parent, &parentStatus) != 0 { try ensureDirectory(parent) }
      }
      guard mkdir(path, 0o700) == 0 || errno == EEXIST else {
        throw CIError.storage("cannot create \(path)")
      }
      guard lstat(path, &status) == 0 else { throw CIError.storage("cannot inspect \(path)") }
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
      throw CIError.storage("\(path) is not a directory")
    }
    guard status.st_uid == getuid() else {
      throw CIError.storage("\(path) is not owned by this user")
    }
    if status.st_mode & 0o077 != 0 {
      guard chmod(path, 0o700) == 0 else { throw CIError.storage("cannot restrict \(path)") }
    }
  }

  /// Atomically replaces `path` with `bytes` (temp file + fsync + rename),
  /// mode 0600 unless `mode` says otherwise.
  package static func write(_ bytes: [UInt8], to path: String, mode: mode_t = 0o600)
    throws(CIError)
  {
    let directory = (path as NSString).deletingLastPathComponent
    let temporary = directory + "/.tmp-" + randomHex(bytes: 8)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
    guard fd >= 0 else { throw CIError.storage("cannot write \(path)") }
    var ok = true
    var offset = 0
    bytes.withUnsafeBytes { raw in
      while offset < raw.count {
        let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          ok = false
          return
        }
        offset += written
      }
    }
    if ok { ok = fsync(fd) == 0 }
    close(fd)
    guard ok, rename(temporary, path) == 0 else {
      unlink(temporary)
      throw CIError.storage("cannot write \(path)")
    }
  }

  /// Reads a regular file owned by this user, refusing symlinks and files
  /// larger than `limit`.
  package static func read(_ path: String, limit: Int) throws(CIError) -> [UInt8]? {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw CIError.storage("cannot open \(path)")
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == getuid()
    else { throw CIError.storage("\(path) is not a private regular file") }
    guard status.st_size <= off_t(limit) else { throw CIError.storage("\(path) is too large") }
    var out = [UInt8](repeating: 0, count: Int(status.st_size))
    var offset = 0
    while offset < out.count {
      let count = out.withUnsafeMutableBytes {
        Darwin.read(fd, $0.baseAddress! + offset, $0.count - offset)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw CIError.storage("cannot read \(path)")
      }
      if count == 0 { break }
      offset += count
    }
    return Array(out.prefix(offset))
  }

  package static func remove(_ path: String) {
    unlink(path)
  }

  /// Removes a directory tree created by iso-ci; never follows symlinks.
  package static func removeTree(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
  }
}

/// An exclusive advisory lock on one file, held for the controller's life.
/// One controller ownership lock prevents concurrent writers (spec section 5).
package final class OwnershipLock: @unchecked Sendable {
  private var fd: Int32

  private init(fd: Int32) { self.fd = fd }

  /// Returns nil when another process holds the lock.
  package static func attempt(path: String) throws(CIError) -> OwnershipLock? {
    let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CIError.storage("cannot open the ownership lock") }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      if errno == EWOULDBLOCK { return nil }
      throw CIError.storage("cannot take the ownership lock")
    }
    let pid = Array("\(getpid())\n".utf8)
    ftruncate(fd, 0)
    _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
    return OwnershipLock(fd: fd)
  }

  package func release() {
    guard fd >= 0 else { return }
    flock(fd, LOCK_UN)
    close(fd)
    fd = -1
  }

  deinit { release() }
}

/// The operator data root layout (default `~/.iso-ci`).
package struct DataRoot: Sendable, Equatable {
  package let path: String

  package init(path: String) { self.path = path }

  package static func `default`(environment: [String: String]) -> DataRoot {
    if let explicit = environment["ISO_CI_HOME"], explicit.hasPrefix("/") {
      return DataRoot(path: explicit)
    }
    return DataRoot(path: NSHomeDirectory() + "/.iso-ci")
  }

  package var configuration: String { path + "/config.yaml" }
  package var database: String { path + "/controller.sqlite" }
  package var lock: String { path + "/controller.lock" }
  package var objects: String { path + "/objects" }
  package var staging: String { path + "/staging" }
  package var keys: String { path + "/keys" }
  package var sessions: String { path + "/sessions" }
  package var logs: String { path + "/logs" }

  /// Control sockets need a short path: a per-user temporary directory
  /// with a bounded name derived from the data root.
  package var runtimeDirectory: String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
    let base: String
    if length > 0, length <= buffer.count {
      base = String(
        decoding: buffer.prefix(length - 1).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    } else {
      base = "/tmp/"
    }
    let tag = Digest(hashing: path).short
    return (base.hasSuffix("/") ? base : base + "/") + "iso-ci-" + tag
  }

  package var controlSocket: String { runtimeDirectory + "/control.sock" }
  package var dataPlaneSocket: String { runtimeDirectory + "/dp.sock" }

  package func prepare() throws(CIError) {
    for directory in [path, objects, staging, keys, sessions, logs, runtimeDirectory] {
      try PrivateFiles.ensureDirectory(directory)
    }
  }
}
