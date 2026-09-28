import CoopConfiguration
import CoopCore
import CryptoKit
import Foundation

// Staged workspace return (selective-hardening spec §5). Nothing reaches the
// destination until `StageApplier` applies a reviewed manifest, and the stage
// tree is guest-authored: every name, link target, mode and size read from it
// is untrusted.

/// A staged object, as the guest left it.
public enum StageObject: Sendable, Equatable, Codable {
  case file(size: UInt64, sha256: String, mode: UInt16)
  case directory
  case symlink(target: String)

  var kindName: String {
    switch self {
    case .file: "file"
    case .directory: "directory"
    case .symlink: "symlink"
    }
  }
}

/// What the destination held at a path when the stage was built. Applying
/// requires it to be unchanged.
public enum DestinationObject: Sendable, Equatable, Codable {
  case absent
  case file(size: UInt64, sha256: String, mode: UInt16)
  case directory
  case symlink(target: String)
  /// A FIFO, socket or device: never replaced.
  case other

  var kindName: String {
    switch self {
    case .absent: "absent"
    case .file: "file"
    case .directory: "directory"
    case .symlink: "symlink"
    case .other: "special file"
    }
  }
}

public enum StageOperation: String, Sendable, Codable {
  case add
  case modify
  case typeChange = "type-change"
}

public struct StageChange: Sendable, Equatable, Codable {
  /// Relative, `/`-separated, validated UTF-8 without control characters.
  public let path: String
  public let operation: StageOperation
  public let new: StageObject
  public let old: DestinationObject
}

public struct StageManifest: Sendable, Equatable, Codable {
  public static let currentVersion = 1

  public let version: Int
  public let id: String
  public let instance: String
  public let destination: String
  public let createdAt: String
  public let excludeGit: Bool
  /// Staged entries and regular-file bytes, including unchanged ones.
  public let stagedEntries: UInt64
  public let stagedBytes: UInt64
  /// Sorted by path, so every parent precedes its children.
  public let changes: [StageChange]
  /// Reasons the stage cannot be applied. Empty for an applicable stage.
  public let issues: [String]

  public var applicable: Bool { issues.isEmpty }

  enum CodingKeys: String, CodingKey {
    case version, id, instance, destination
    case excludeGit = "exclude_git"
    case issues, changes
    case createdAt = "created_at"
    case stagedEntries = "staged_entries"
    case stagedBytes = "staged_bytes"
  }
}

/// A stage budget was exceeded; the stage is discarded.
public struct StageBudgetExceeded: Error, CustomStringConvertible {
  public let description: String
}

/// Watches a stage tree while a transfer fills it, so a guest cannot fill the
/// host volume before `StageBuilder` enforces the budgets. Passed as a
/// process `isCancelled` poll; measures at most twice a second, by allocated
/// bytes so sparse files count for what they cost on the host.
final class StageGrowthGuard: @unchecked Sendable {
  private let lock = NSLock()
  private let tree: String
  private let limits: StageLimits
  private var lastCheck = ContinuousClock.now - .seconds(1)
  private var breach: String?

  init(tree: String, limits: StageLimits) {
    self.tree = tree
    self.limits = limits
  }

  /// Why the transfer was stopped, once it has been.
  var breachDescription: String? { lock.withLock { breach } }

  func shouldCancel() -> Bool {
    lock.withLock {
      if breach != nil { return true }
      let now = ContinuousClock.now
      guard now - lastCheck >= .milliseconds(500) else { return false }
      lastCheck = now
      breach = measure()
      return breach != nil
    }
  }

  static let blockSlack: UInt64 = 4096

  private func measure() -> String? {
    guard let walker = FileManager.default.enumerator(atPath: tree) else { return nil }
    var entries: UInt64 = 0
    var bytes: UInt64 = 0
    for case let relative as String in walker {
      entries += 1
      if entries > limits.maxFiles {
        return "Stage exceeds workspace.pull.max_files (\(limits.maxFiles) entries)"
      }
      var info = stat()
      if lstat(tree + "/" + relative, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
        bytes += UInt64(info.st_blocks) * 512
        // The builder budgets logical sizes; allocation rounds each file up
        // to a block, so allow that much before calling it a breach.
        if bytes > limits.maxBytes.bytes + entries * Self.blockSlack {
          return "Stage exceeds workspace.pull.max_bytes (\(limits.maxBytes))"
        }
      }
    }
    return nil
  }
}

/// `<instance>/stage/`: `tree/` holds the transferred files, `manifest.json`
/// describes them.
public struct StageLocation: Sendable {
  public let root: String

  public init(_ instance: Instance) { root = instance.directory + "/stage" }
  init(root: String) { self.root = root }

  public var tree: String { root + "/tree" }
  public var manifestPath: String { root + "/manifest.json" }

  public var exists: Bool { FileManager.default.fileExists(atPath: root) }

  /// Serializes prepare, build, apply, discard and destroy of one instance's
  /// stage across coop processes. The lock file lives beside `stage/`, so
  /// removing the stage never removes it.
  public func lock() throws(HostError) -> FileLock {
    try FileLock(path: (root as NSString).deletingLastPathComponent + "/.stage.lock")
  }

  /// Removes the stage. Guest-authored directory modes may deny the owner
  /// access, so each directory is opened up before removal.
  public func remove() throws(HostError) {
    var info = stat()
    guard lstat(root, &info) == 0 else {
      if errno == ENOENT { return }
      throw .posix("Failed to inspect", root)
    }
    Self.grantOwnerAccess(root)
    do {
      try FileManager.default.removeItem(atPath: root)
    } catch {
      throw HostError("Failed to remove stage \(root): \(error.localizedDescription)")
    }
  }

  /// Adds owner rwx to every directory below `path` (never following links).
  static func grantOwnerAccess(_ path: String) {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return }
    chmod(path, (info.st_mode & 0o7777) | 0o700)
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
    for entry in entries { grantOwnerAccess(path + "/" + entry) }
  }

  /// A fresh, empty, owner-only stage.
  public func prepare() throws(HostError) {
    try remove()
    try StateStore.ensurePrivateDirectory(root)
    try StateStore.ensurePrivateDirectory(tree)
  }

  static let maxManifest = 256 << 20

  public func loadManifest() throws(HostError) -> StageManifest {
    let fd = open(manifestPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      if errno == ENOENT {
        throw HostError("No staged pull. Create one with `coop diff` or `coop pull --review`.")
      }
      throw .posix("Failed to open", manifestPath)
    }
    defer { close(fd) }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while true {
      let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw .posix("Failed to read", manifestPath)
      }
      if count == 0 { break }
      bytes.append(contentsOf: chunk[0..<count])
      guard bytes.count <= Self.maxManifest else { throw HostError("\(manifestPath) is too large") }
    }
    let manifest = try StateStore.decode(StageManifest.self, bytes, path: manifestPath)
    guard manifest.version == StageManifest.currentVersion else {
      throw HostError(
        "Unsupported stage manifest version \(manifest.version); discard and re-stage")
    }
    return manifest
  }

  func saveManifest(_ manifest: StageManifest) throws(HostError) {
    try AtomicFile.write(
      try StateStore.encode(manifest, path: manifestPath), to: manifestPath, mode: .atMost(0o600))
  }
}

/// Builds a manifest by comparing a stage tree with the destination.
struct StageBuilder {
  let tree: String
  let destination: String
  let limits: StageLimits

  private(set) var entries: UInt64 = 0
  private(set) var bytes: UInt64 = 0
  private(set) var changes: [StageChange] = []
  private(set) var issues: [String] = []
  /// Staged links, checked for chains once the whole tree is known.
  private(set) var links: [(path: String, target: String)] = []

  static let maxIssues = 50

  init(tree: String, destination: String, limits: StageLimits) {
    self.tree = tree
    self.destination = destination
    self.limits = limits
  }

  mutating func build(
    id: String, instance: String, excludeGit: Bool, now: Date = Date()
  ) throws -> StageManifest {
    let root = open(tree, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else { throw HostError.posix("Failed to open stage", tree) }
    defer { close(root) }
    try walk(root, prefix: "")
    try checkLinkChains()
    changes.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    return StageManifest(
      version: StageManifest.currentVersion, id: id, instance: instance,
      destination: destination, createdAt: ISO8601DateFormatter().string(from: now),
      excludeGit: excludeGit, stagedEntries: entries, stagedBytes: bytes, changes: changes,
      issues: issues)
  }

  mutating func issue(_ message: String) {
    if issues.count < Self.maxIssues {
      issues.append(message)
    } else if issues.count == Self.maxIssues {
      issues.append("(further issues omitted)")
    }
  }

  /// One descriptor is open per level; deeper trees would exhaust them.
  static let maxDepth = 64

  private mutating func walk(_ directory: Int32, prefix: String, depth: Int = 0) throws {
    for name in try Self.names(directory, path: prefix.isEmpty ? tree : tree + "/" + prefix) {
      let shown = String(decoding: name.map { $0 < 0x20 || $0 == 0x7F ? 0x3F : $0 }, as: UTF8.self)
      guard let text = Self.validName(name) else {
        issue("\(prefix)\(shown): unsupported file name (not UTF-8, or has control characters)")
        continue
      }
      let path = prefix + text
      entries += 1
      guard entries <= limits.maxFiles else {
        throw StageBudgetExceeded(
          description: "Stage exceeds workspace.pull.max_files (\(limits.maxFiles) entries)")
      }
      var info = stat()
      guard fstatat(directory, text, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw HostError.posix("Failed to inspect staged", path)
      }
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        fchmodat(directory, text, (info.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW)
        try record(path, .directory)
        guard depth < Self.maxDepth else {
          issue("\(path): directories nested deeper than \(Self.maxDepth) levels are not supported")
          continue
        }
        let child = openat(directory, text, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else { throw HostError.posix("Failed to open staged", path) }
        defer { close(child) }
        try walk(child, prefix: path + "/", depth: depth + 1)
      case S_IFREG:
        guard info.st_nlink == 1 else {
          issue("\(path): hard links are not supported")
          continue
        }
        let size = UInt64(info.st_size)
        guard size <= limits.maxFileBytes.bytes else {
          throw StageBudgetExceeded(
            description:
              "\(path) (\(size) bytes) exceeds workspace.pull.max_file_bytes (\(limits.maxFileBytes))"
          )
        }
        bytes += size
        guard bytes <= limits.maxBytes.bytes else {
          throw StageBudgetExceeded(
            description: "Stage exceeds workspace.pull.max_bytes (\(limits.maxBytes))")
        }
        let mode = UInt16(info.st_mode & 0o777)
        if mode & 0o400 == 0 { fchmodat(directory, text, (info.st_mode & 0o7777) | 0o400, 0) }
        let digest = try Self.sha256(at: directory, text, path: path)
        try record(path, .file(size: size, sha256: digest, mode: mode))
      case S_IFLNK:
        let target = try Self.linkTarget(directory, text, path: path)
        guard let target, Self.staysInside(link: path, target: target) else {
          issue("\(path): symlink points outside the workspace or is not UTF-8")
          continue
        }
        links.append((path, target))
        try record(path, .symlink(target: target))
      default:
        issue("\(path): unsupported file type (device, FIFO or socket)")
      }
    }
  }

  private mutating func record(_ path: String, _ new: StageObject) throws {
    let old = try Self.destinationObject(destination, path)
    let operation: StageOperation
    switch (old, new) {
    case (.absent, _): operation = .add
    case (.directory, .directory): return
    case (.file(_, let a, let m), .file(_, let b, let n)) where a == b && m == n: return
    case (.symlink(let a), .symlink(let b)) where a == b: return
    case (.file, .file), (.symlink, .symlink): operation = .modify
    case (.directory, _):
      issue("\(path): would replace a host directory with a \(new.kindName); resolve it by hand")
      return
    case (.other, _):
      issue("\(path): the host has a special file here")
      return
    default: operation = .typeChange
    }
    changes.append(StageChange(path: path, operation: operation, new: new, old: old))
  }

  /// Directory entries other than `.` and `..`, as raw bytes.
  static func names(_ directory: Int32, path: String) throws -> [[UInt8]] {
    let copy = dup(directory)
    guard copy >= 0, let stream = fdopendir(copy) else {
      if copy >= 0 { close(copy) }
      throw HostError.posix("Failed to read directory", path)
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var out: [[UInt8]] = []
    // readdir returns nil both at the end and on error; only errno tells
    // them apart, and a short listing would silently drop guest changes.
    errno = 0
    while let entry = readdir(stream) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
        Array(raw.prefix(Int(entry.pointee.d_namlen)))
      }
      if name != [0x2E] && name != [0x2E, 0x2E] { out.append(name) }
      errno = 0
    }
    guard errno == 0 else { throw HostError.posix("Failed to read directory", path) }
    return out.sorted { $0.lexicographicallyPrecedes($1) }
  }

  static func validName(_ name: [UInt8]) -> String? {
    guard !name.isEmpty, !name.contains(where: { $0 < 0x20 || $0 == 0x7F || $0 == 0x2F }),
      let text = String(validating: name, as: UTF8.self)
    else { return nil }
    return text
  }

  static func linkTarget(_ directory: Int32, _ name: String, path: String) throws -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
    let count = buffer.withUnsafeMutableBytes {
      readlinkat(directory, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
    }
    guard count >= 0 else { throw HostError.posix("Failed to read staged link", path) }
    return String(validating: buffer[0..<count], as: UTF8.self)
  }

  /// Lexical containment holds only if no intermediate component of a
  /// target is itself a link: the kernel resolves `s/..` through `s`, so
  /// `s -> .` plus `x -> s/s/../../..` escapes. An intermediate component
  /// that is a staged link, or a link already in the destination, is refused.
  /// Staged names are compared folded, as APFS resolves `S` and `s` (and NFC
  /// and NFD spellings) to one object.
  mutating func checkLinkChains() throws {
    let staged = Set(links.map { Self.folded($0.path) })
    for (path, target) in links {
      var stack = path.split(separator: "/").map(String.init)
      stack.removeLast()
      let components = target.split(separator: "/").map(String.init)
      for component in components.dropLast() {
        if component == "." { continue }
        if component == ".." {
          stack.removeLast()
          continue
        }
        stack.append(component)
        let through = stack.joined(separator: "/")
        var isLink = staged.contains(Self.folded(through))
        if !isLink, case .symlink = try Self.destinationObject(destination, through) {
          isLink = true
        }
        if isLink {
          issue("\(path): symlink target passes through another symlink (\(through))")
          break
        }
      }
    }
  }

  static func folded(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased()
  }

  /// A relative target that, resolved lexically from the link's directory,
  /// never climbs above the workspace root.
  static func staysInside(link path: String, target: String) -> Bool {
    guard !target.isEmpty, !target.hasPrefix("/"),
      !target.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F })
    else { return false }
    var depth = path.split(separator: "/").count - 1
    for component in target.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".": continue
      case "..":
        depth -= 1
        if depth < 0 { return false }
      default: depth += 1
      }
    }
    return true
  }

  static func sha256(at directory: Int32, _ name: String, path: String) throws -> String {
    let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw HostError.posix("Failed to open", path) }
    defer { close(fd) }
    return try sha256(fd: fd, path: path)
  }

  static func sha256(fd: Int32, path: String, copyingTo output: Int32? = nil) throws -> String {
    var hasher = SHA256()
    var chunk = [UInt8](repeating: 0, count: 256 << 10)
    while true {
      let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw HostError.posix("Failed to read", path)
      }
      if count == 0 { break }
      let slice = chunk[0..<count]
      hasher.update(data: slice)
      if let output { try writeAll(output, Array(slice), path: path) }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func writeAll(_ fd: Int32, _ bytes: [UInt8], path: String) throws {
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      if written < 0 {
        if errno == EINTR { continue }
        throw HostError.posix("Failed to write", path)
      }
      offset += written
    }
  }

  /// The destination object at `path`, resolved component by component
  /// without following links. A parent that is not a directory means the
  /// path does not exist yet (the parent is itself a change).
  static func destinationObject(_ destination: String, _ path: String) throws -> DestinationObject {
    let root = open(destination, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard root >= 0 else {
      if errno == ENOENT { return .absent }
      throw HostError.posix("Failed to open", destination)
    }
    var components = path.split(separator: "/").map(String.init)
    let last = components.removeLast()
    var directory = root
    defer { close(directory) }
    for component in components {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard next >= 0 else {
        if [ENOENT, ENOTDIR, ELOOP].contains(errno) { return .absent }
        throw HostError.posix("Failed to open", destination + "/" + path)
      }
      close(directory)
      directory = next
    }
    return try object(at: directory, last, path: destination + "/" + path)
  }

  static func object(at directory: Int32, _ name: String, path: String) throws
    -> DestinationObject
  {
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return .absent }
      throw HostError.posix("Failed to inspect", path)
    }
    switch info.st_mode & S_IFMT {
    case S_IFDIR: return .directory
    case S_IFREG:
      return .file(
        size: UInt64(info.st_size), sha256: try sha256(at: directory, name, path: path),
        mode: UInt16(info.st_mode & 0o777))
    case S_IFLNK:
      var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
      let count = buffer.withUnsafeMutableBytes {
        readlinkat(directory, name, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
      }
      guard count >= 0 else { throw HostError.posix("Failed to read link", path) }
      return .symlink(target: String(decoding: buffer[0..<count], as: UTF8.self))
    default: return .other
    }
  }
}
