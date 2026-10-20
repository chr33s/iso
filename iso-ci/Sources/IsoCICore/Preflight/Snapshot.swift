import Darwin
import Foundation

/// What a snapshot capture includes and how it is bounded.
package struct SnapshotOptions: Sendable, Equatable {
  /// Patterns selecting untracked files to include. Nothing untracked is
  /// selected implicitly: no ignore file is read.
  package var include: [String] = []
  /// Extra exclusions on top of (or instead of) the defaults.
  package var exclude: [String] = []
  /// Apply `SnapshotOptions.defaultExcludes` (local credential files).
  package var useDefaultExcludes = true
  /// Repository-relative workflow path whose digest is recorded.
  package var workflowPath: String?
  /// Where the archive is written (a private directory).
  package var outputDirectory: String
  package var maxFiles = 100_000
  package var maxFileBytes: UInt64 = 1 << 30
  package var maxTotalBytes: UInt64 = 4 << 30
  /// Captures retried when the tree changes underneath; then it fails.
  package var maxAttempts = 3

  package init(outputDirectory: String) { self.outputDirectory = outputDirectory }

  /// Local credential material excluded by default. Patterns without `/`
  /// match a file or directory name anywhere; a trailing `/` matches a
  /// directory; patterns with `/` match the repository-relative path.
  package static let defaultExcludes = [
    ".env", ".env.*", "*.pem", "*.key", "*.p12", "*.pfx", "*.keystore", "id_rsa*", "id_dsa*",
    "id_ecdsa*", "id_ed25519*", ".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials",
    ".aws/", ".ssh/", ".gnupg/", ".docker/config.json", ".kube/config", "credentials.json",
  ]

  package var effectiveExcludes: [String] {
    (useDefaultExcludes ? Self.defaultExcludes : []) + exclude
  }
}

package struct SnapshotFile: Sendable, Equatable, Codable {
  package enum Kind: String, Sendable, Codable { case file, symlink }

  package let path: String
  package let kind: Kind
  /// 0o644 or 0o755 for files; 0o777 for symlinks.
  package let mode: Int
  package let size: UInt64
  package let sha256: Digest?
  package let target: String?
}

/// The archived manifest (`manifest.json`). Deterministic: it carries no
/// capture time, so equal trees produce equal archives and digests.
package struct SnapshotManifest: Sendable, Equatable, Codable {
  /// v2: selected content only, without the base-commit bundle or any
  /// original history (CI-01). A v1 reader must refuse it.
  package static let schema = "iso-ci.snapshot/v2"

  /// Whether this build reads `schema`. History-bearing v1 snapshots are
  /// recaptured, never relabeled.
  package static func readable(_ schema: String) -> Bool { schema == Self.schema }

  package let schema: String
  /// The commit the selection was taken from: provenance only. The guest
  /// never receives it; its repository is synthetic.
  package let baseCommit: String
  /// The snapshot differs from the base commit (modified, deleted or
  /// included untracked content). A dirty snapshot never attests that the
  /// unchanged base commit passes.
  package let isDirty: Bool
  package let workflowPath: String?
  package let workflowDigest: Digest?
  package let files: [SnapshotFile]
  /// Always empty in v2: there is no base checkout to delete from.
  package let deletions: [String]
  package let excludePatterns: [String]
  /// Paths left out by an exclusion; the guest receives no version of them.
  package let excludedPaths: [String]
  package let includedUntracked: [String]

  package func reference(digest: Digest) -> SnapshotReference {
    SnapshotReference(baseCommit: baseCommit, digest: digest, isDirty: isDirty)
  }
}

package struct SnapshotCaptureResult: Sendable, Equatable {
  package let archivePath: String
  package let manifest: SnapshotManifest
  package let digest: Digest
  package let size: UInt64
  package let capturedAt: EpochSeconds
  package let attempts: Int

  package var reference: SnapshotReference { manifest.reference(digest: digest) }
}

/// Host-side capture of an immutable selected tree from the operator's own
/// git working directory. The index, HEAD and refs are parsed as inert
/// data; no Git process, configuration, hook, filter or fsmonitor runs.
package enum SnapshotCapture {
  package static func capture(repository: String, options: SnapshotOptions) throws(CIError)
    -> SnapshotCaptureResult
  {
    var lastError = CIError(.conflict, "the working tree changed during capture")
    for attempt in 1...max(1, options.maxAttempts) {
      do {
        return try captureOnce(repository: repository, options: options, attempt: attempt)
      } catch let error as ConcurrentChange {
        lastError = CIError(.conflict, "the working tree changed during capture (\(error.path))")
        continue
      } catch let error as CIError {
        throw error
      } catch {
        throw CIError(.internalError, "snapshot capture failed")
      }
    }
    throw CIError(
      lastError.code, "\(lastError.message); retried \(options.maxAttempts) times")
  }

  struct ConcurrentChange: Error { let path: String }

  struct Observed: Equatable {
    let size: Int64
    let mtimeSeconds: Int
    let mtimeNanos: Int
    let ctimeSeconds: Int
    let ctimeNanos: Int
    let inode: UInt64

    init(_ status: stat) {
      size = status.st_size
      mtimeSeconds = status.st_mtimespec.tv_sec
      mtimeNanos = status.st_mtimespec.tv_nsec
      ctimeSeconds = status.st_ctimespec.tv_sec
      ctimeNanos = status.st_ctimespec.tv_nsec
      inode = status.st_ino
    }
  }

  /// Untracked regular files and links matching an explicit `include`
  /// pattern, found by walking the tree (never `.git`). No ignore file is
  /// read, so nothing untracked is selected implicitly.
  static func untrackedMatching(root: String, tracked: Set<String>, options: SnapshotOptions)
    throws(CIError) -> [String]
  {
    var found: [String] = []
    var pending = [""]
    var visited = 0
    while let relative = pending.popLast() {
      let directory = relative.isEmpty ? root : root + "/" + relative
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        continue
      }
      for name in names where name != ".git" {
        visited += 1
        guard visited <= options.maxFiles * 10 else {
          throw CIError(.budgetExceeded, "the working tree is too large to search for includes")
        }
        let path = relative.isEmpty ? name : relative + "/" + name
        var status = stat()
        guard lstat(root + "/" + path, &status) == 0 else { continue }
        if status.st_mode & S_IFMT == S_IFDIR {
          pending.append(path)
        } else if !tracked.contains(path), matchesInclude(path, patterns: options.include) {
          found.append(path)
        }
      }
    }
    return found
  }

  /// Whether a tracked file is missing or its size or modification time
  /// differs from what the index recorded.
  static func indexDisagrees(_ entries: [GitIndex.Entry], root: String) -> Bool {
    entries.contains { entry in
      var status = stat()
      guard lstat(root + "/" + entry.path, &status) == 0 else { return true }
      return UInt32(truncatingIfNeeded: status.st_size) != entry.size
        || UInt32(truncatingIfNeeded: status.st_mtimespec.tv_sec) != entry.mtimeSeconds
        || UInt32(truncatingIfNeeded: status.st_mtimespec.tv_nsec) != entry.mtimeNanos
    }
  }

  /// Whether the index was written after HEAD last moved (staged changes).
  static func indexNewerThanHead(_ layout: GitIndex.Layout) -> Bool {
    var index = stat()
    guard lstat(layout.gitDirectory + "/index", &index) == 0 else { return false }
    var newest = 0
    for path in [layout.gitDirectory + "/HEAD", layout.gitDirectory + "/logs/HEAD"] {
      var status = stat()
      if lstat(path, &status) == 0 { newest = max(newest, status.st_mtimespec.tv_sec) }
    }
    return index.st_mtimespec.tv_sec > newest
  }

  static func nulSeparated(_ bytes: [UInt8]) -> [String] {
    bytes.split(separator: 0, omittingEmptySubsequences: true).map {
      String(decoding: $0, as: UTF8.self)
    }
  }

  static func validPath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && path.utf8.count <= 4_096
      && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
        $0.isEmpty || $0 == "." || $0 == ".."
      })
      && !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0 == "\\" || $0.value == 0x7F })
      && path.split(separator: "/").first != ".git"
  }

  /// Whether `path` matches any exclusion pattern.
  package static func excluded(_ path: String, patterns: [String]) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    for pattern in patterns {
      if pattern.hasSuffix("/") {
        let name = String(pattern.dropLast())
        if name.contains("/") {
          if path.hasPrefix(name + "/") { return true }
        } else if components.dropLast().contains(where: { fnmatch(name, $0, 0) == 0 }) {
          return true
        }
      } else if pattern.contains("/") {
        if fnmatch(pattern, path, FNM_PATHNAME) == 0 || path.hasSuffix("/" + pattern) {
          return true
        }
      } else if components.contains(where: { fnmatch(pattern, $0, 0) == 0 }) {
        return true
      }
    }
    return false
  }

  static func matchesInclude(_ path: String, patterns: [String]) -> Bool {
    patterns.contains { fnmatch($0, path, FNM_PATHNAME) == 0 || fnmatch($0, path, 0) == 0 }
  }

  /// Normalizes a relative symlink target against the link's directory;
  /// nil when it is absolute, escapes the tree or enters `.git`.
  static func containedTarget(link: String, target: String) -> String? {
    guard !target.isEmpty, !target.hasPrefix("/") else { return nil }
    var parts = link.split(separator: "/").dropLast().map(String.init)
    for component in target.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".": continue
      case "..":
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
      default: parts.append(String(component))
      }
    }
    if parts.first == ".git" { return nil }
    return parts.joined(separator: "/")
  }

  static func captureOnce(repository: String, options: SnapshotOptions, attempt: Int) throws
    -> SnapshotCaptureResult
  {
    // The index, HEAD and refs are read as data: no Git process runs on the
    // operator's repository (CI-01).
    let layout = try GitIndex.layout(containing: repository)
    let root = layout.root
    let head = try GitIndex.head(layout)
    let indexEntries = try GitIndex.entries(layout)
    let indexPaths = indexEntries.map(\.path)
    let untracked =
      options.include.isEmpty
      ? [] : try untrackedMatching(root: root, tracked: Set(indexPaths), options: options)
    let patterns = options.effectiveExcludes
    var candidates: [String] = []
    var excludedPaths: [String] = []
    var includedUntracked: [String] = []
    let tracked = Set(indexPaths)
    for path in Set(indexPaths + untracked).sorted(by: {
      Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8))
    }) {
      guard validPath(path) else {
        throw CIError(
          .compatibilityRejected,
          "unsupported path in the working tree (control characters, backslash or '..')")
      }
      if excluded(path, patterns: patterns) {
        excludedPaths.append(path)
        continue
      }
      candidates.append(path)
      if !tracked.contains(path) { includedUntracked.append(path) }
    }
    guard candidates.count <= options.maxFiles else {
      throw CIError(.budgetExceeded, "the snapshot has more than \(options.maxFiles) files")
    }
    try PrivateFiles.ensureDirectory(options.outputDirectory)
    let archivePath = options.outputDirectory + "/snapshot-" + randomHex(bytes: 8) + ".tar"
    var writer = try TarWriter(path: archivePath)
    var completed = false
    defer {
      writer.close()
      if !completed { unlink(archivePath) }
    }
    var files: [SnapshotFile] = []
    var observed: [String: Observed] = [:]
    var total: UInt64 = 0
    for path in candidates {
      let full = root + "/" + path
      var status = stat()
      guard lstat(full, &status) == 0 else {
        if errno == ENOENT { continue }  // deleted in the working tree
        throw CIError.storage("cannot inspect \(path)")
      }
      switch status.st_mode & S_IFMT {
      case S_IFREG:
        let size = UInt64(status.st_size)
        guard size <= options.maxFileBytes else {
          throw CIError(.budgetExceeded, "\(path) exceeds the per-file snapshot limit")
        }
        total += size
        guard total <= options.maxTotalBytes else {
          throw CIError(.budgetExceeded, "the snapshot exceeds its total size limit")
        }
        let mode = status.st_mode & 0o111 != 0 ? 0o755 : 0o644
        let digest = try writer.addFile(
          name: "tree/" + path, mode: mode, source: full, expectedSize: size,
          expected: Observed(status))
        files.append(
          SnapshotFile(path: path, kind: .file, mode: mode, size: size, sha256: digest, target: nil)
        )
        observed[path] = Observed(status)
      case S_IFLNK:
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(full, &buffer, Int(PATH_MAX))
        guard count >= 0 else { throw CIError.storage("cannot read link \(path)") }
        let target = String(
          decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard containedTarget(link: path, target: target) != nil,
          !target.unicodeScalars.contains(where: { $0.value < 0x20 })
        else {
          throw CIError(
            .compatibilityRejected,
            "symlink \(path) is absolute or points outside the working tree; it is not permitted in a snapshot"
          )
        }
        try writer.addSymlink(name: "tree/" + path, target: target)
        files.append(
          SnapshotFile(
            path: path, kind: .symlink, mode: 0o777, size: 0, sha256: nil, target: target))
        observed[path] = Observed(status)
      case S_IFDIR:
        throw CIError(
          .compatibilityRejected, "\(path) is a directory in the index (nested repository?)")
      default:
        throw CIError(.compatibilityRejected, "\(path) is not a regular file or symlink")
      }
    }
    // v2 snapshots carry no base checkout, so nothing is deleted from one.
    let deletions: [String] = []
    // Conservatively dirty: an included untracked file, a tracked file whose
    // size or time differs from the index (or that is gone), or an index
    // written after HEAD (staged changes). A false "dirty" only withholds
    // the clean-tree label.
    let dirty =
      !includedUntracked.isEmpty || indexDisagrees(indexEntries, root: root)
      || indexNewerThanHead(layout)
    // Concurrent-modification checks: every captured path, HEAD and the index.
    for (path, before) in observed {
      var status = stat()
      guard lstat(root + "/" + path, &status) == 0, Observed(status) == before else {
        throw ConcurrentChange(path: path)
      }
    }
    guard try GitIndex.head(layout) == head else { throw ConcurrentChange(path: "HEAD") }
    let workflowDigest = options.workflowPath.flatMap { workflow in
      files.first { $0.path == workflow && $0.kind == .file }?.sha256
    }
    // Verification lists the overlay step consumes.
    let regular = files.filter { $0.kind == .file }
    let sums = regular.map { "\($0.sha256?.rawValue ?? "")  \($0.path)\n" }.joined()
    try writer.addData(name: "checks/sha256sums", mode: 0o644, bytes: Array(sums.utf8))
    try writer.addData(
      name: "checks/executables", mode: 0o644,
      bytes: nulList(regular.filter { $0.mode == 0o755 }.map(\.path)))
    try writer.addData(
      name: "checks/regular", mode: 0o644,
      bytes: nulList(regular.filter { $0.mode == 0o644 }.map(\.path)))
    try writer.addData(
      name: "checks/symlinks", mode: 0o644,
      bytes: nulList(files.filter { $0.kind == .symlink }.flatMap { [$0.path, $0.target ?? ""] }))
    try writer.addData(name: "checks/deletions", mode: 0o644, bytes: nulList(deletions))
    let manifest = SnapshotManifest(
      schema: SnapshotManifest.schema, baseCommit: head, isDirty: dirty,
      workflowPath: options.workflowPath, workflowDigest: workflowDigest, files: files,
      deletions: deletions, excludePatterns: patterns, excludedPaths: excludedPaths,
      includedUntracked: includedUntracked)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let manifestBytes: Data
    do { manifestBytes = try encoder.encode(manifest) } catch {
      throw CIError(.internalError, "cannot encode the snapshot manifest")
    }
    try writer.addData(name: "manifest.json", mode: 0o644, bytes: Array(manifestBytes))
    let (digest, size) = try writer.finish()
    completed = true
    return SnapshotCaptureResult(
      archivePath: archivePath, manifest: manifest, digest: digest, size: size,
      capturedAt: SystemClock().now(), attempts: attempt)
  }

  static func nulList(_ items: [String]) -> [UInt8] {
    items.flatMap { Array($0.utf8) + [0] }
  }
}

/// A deterministic ustar/pax writer: fixed mtime, uid/gid 0, empty owner
/// names, pax records for long names; the archive digest streams as it is
/// written.
struct TarWriter {
  private var fd: Int32
  private var hasher = StreamingSHA256()
  private(set) var written: UInt64 = 0

  init(path: String) throws(CIError) {
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CIError.storage("cannot create the snapshot archive") }
  }

  mutating func close() {
    if fd >= 0 { Darwin.close(fd) }
    fd = -1
  }

  private mutating func emit(_ bytes: [UInt8]) throws(CIError) {
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeBytes {
        Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw CIError.storage("cannot write the snapshot archive")
      }
      offset += count
    }
    hasher.update(bytes)
    written += UInt64(bytes.count)
  }

  private mutating func pad(_ size: UInt64) throws(CIError) {
    let remainder = Int(size % 512)
    if remainder != 0 { try emit([UInt8](repeating: 0, count: 512 - remainder)) }
  }

  static func octal(_ value: UInt64, width: Int) -> [UInt8] {
    let text = String(value, radix: 8)
    let padded = String(repeating: "0", count: max(0, width - 1 - text.count)) + text
    return Array(padded.utf8) + [0]
  }

  static func header(name: String, mode: Int, size: UInt64, type: UInt8, link: String) -> [UInt8] {
    var block = [UInt8](repeating: 0, count: 512)
    func put(_ bytes: [UInt8], _ offset: Int, _ length: Int) {
      for (index, byte) in bytes.prefix(length).enumerated() { block[offset + index] = byte }
    }
    put(Array(name.utf8), 0, 100)
    put(octal(UInt64(mode), width: 8), 100, 8)
    put(octal(0, width: 8), 108, 8)
    put(octal(0, width: 8), 116, 8)
    put(octal(size, width: 12), 124, 12)
    put(octal(0, width: 12), 136, 12)
    put([UInt8](repeating: 0x20, count: 8), 148, 8)
    block[156] = type
    put(Array(link.utf8), 157, 100)
    put(Array("ustar".utf8) + [0], 257, 6)
    put(Array("00".utf8), 263, 2)
    let sum = block.reduce(0) { $0 + UInt64($1) }
    put(octal(sum, width: 7) + [0x20], 148, 8)
    return block
  }

  private mutating func entry(name: String, mode: Int, size: UInt64, type: UInt8, link: String = "")
    throws(CIError)
  {
    var records = ""
    if name.utf8.count > 100 { records += Self.paxRecord("path", name) }
    if link.utf8.count > 100 { records += Self.paxRecord("linkpath", link) }
    if !records.isEmpty {
      let data = Array(records.utf8)
      let shortName = "PaxHeader/" + String(Digest(hashing: name).rawValue.prefix(32))
      try emit(
        Self.header(
          name: shortName, mode: 0o644, size: UInt64(data.count), type: UInt8(ascii: "x"), link: "")
      )
      try emit(data)
      try pad(UInt64(data.count))
    }
    let headerName =
      name.utf8.count > 100 ? String(decoding: Array(name.utf8).suffix(99), as: UTF8.self) : name
    let headerLink = link.utf8.count > 100 ? "" : link
    try emit(Self.header(name: headerName, mode: mode, size: size, type: type, link: headerLink))
  }

  static func paxRecord(_ key: String, _ value: String) -> String {
    let body = " \(key)=\(value)\n"
    var length = body.utf8.count + 1
    while String(length).utf8.count + body.utf8.count != length {
      length = String(length).utf8.count + body.utf8.count
    }
    return "\(length)\(body)"
  }

  mutating func addData(name: String, mode: Int, bytes: [UInt8]) throws(CIError) {
    try entry(name: name, mode: mode, size: UInt64(bytes.count), type: UInt8(ascii: "0"))
    try emit(bytes)
    try pad(UInt64(bytes.count))
  }

  mutating func addSymlink(name: String, target: String) throws(CIError) {
    try entry(name: name, mode: 0o777, size: 0, type: UInt8(ascii: "2"), link: target)
  }

  /// Streams `source` into the archive; throws `ConcurrentChange` when its
  /// size or timestamps move while it is read.
  mutating func addFile(
    name: String, mode: Int, source: String, expectedSize: UInt64,
    expected: SnapshotCapture.Observed
  ) throws -> Digest {
    let input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard input >= 0 else { throw SnapshotCapture.ConcurrentChange(path: name) }
    defer { Darwin.close(input) }
    try entry(name: name, mode: mode, size: expectedSize, type: UInt8(ascii: "0"))
    var content = StreamingSHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    var remaining = expectedSize
    while remaining > 0 {
      let want = Int(min(UInt64(buffer.count), remaining))
      let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, want) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw SnapshotCapture.ConcurrentChange(path: name) }
      let chunk = Array(buffer[0..<count])
      content.update(chunk)
      try emit(chunk)
      remaining -= UInt64(count)
    }
    var extra: UInt8 = 0
    var after = stat()
    guard Darwin.read(input, &extra, 1) == 0, fstat(input, &after) == 0,
      SnapshotCapture.Observed(after) == expected
    else { throw SnapshotCapture.ConcurrentChange(path: name) }
    try pad(expectedSize)
    return content.finalize()
  }

  mutating func finish() throws(CIError) -> (Digest, UInt64) {
    try emit([UInt8](repeating: 0, count: 1_024))
    guard fsync(fd) == 0 else { throw CIError.storage("cannot flush the snapshot archive") }
    return (hasher.finalize(), written)
  }
}
