import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore

// Outbound selected-content snapshots (security-hardening spec INPUT-01).
// Every transfer into the guest — first copy, push, mount sync — sends one
// immutable host-owned snapshot built from an explicit selection, never the
// whole directory and never original Git history.

/// The tracked paths of a Git working tree, read from its index file as
/// inert data: no Git process, no repository configuration, hooks, filters
/// or helpers. Forms it cannot read safely are refused with a pointer to
/// explicit path selection.
enum GitIndexInventory {
  static let maxIndexBytes = 256 << 20
  static let maxEntries = 1_000_000

  struct Unsupported: Error, CustomStringConvertible {
    let description: String
  }

  /// The index of the worktree at `root`, nil when `root` is not one.
  static func indexPath(_ root: String) throws -> String? {
    let dotGit = root + "/.git"
    var info = stat()
    guard lstat(dotGit, &info) == 0 else { return nil }
    switch info.st_mode & S_IFMT {
    case S_IFDIR: return dotGit + "/index"
    case S_IFREG:
      let fd = open(dotGit, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw HostError.posix("Failed to open", dotGit) }
      defer { close(fd) }
      let bytes = try StateStore.readBounded(
        fd, path: dotGit, limit: 4096, tooLarge: "gitfile too large")
      guard let target = Gitfile.parse(bytes) else {
        throw Unsupported(description: "\(dotGit) is not a standard gitfile")
      }
      let gitdir = target.hasPrefix("/") ? target : root + "/" + target
      return (gitdir as NSString).standardizingPath + "/index"
    default:
      throw Unsupported(description: "\(dotGit) is a link or special file")
    }
  }

  /// Tracked paths, sorted. Throws `Unsupported` for conflicts, sparse or
  /// skip-worktree entries, submodules, unknown versions and any index whose
  /// SHA-1 trailer does not verify (including SHA-256 repositories).
  static func trackedPaths(_ root: String) throws -> [String]? {
    guard let path = try indexPath(root) else { return nil }
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      if errno == ENOENT { return [] }
      throw HostError.posix("Failed to open", path)
    }
    defer { close(fd) }
    let bytes = try StateStore.readBounded(
      fd, path: path, limit: maxIndexBytes, tooLarge: "\(path) is too large")
    return try parse(bytes)
  }

  static func parse(_ bytes: [UInt8]) throws -> [String] {
    func unsupported(_ why: String) -> Unsupported {
      Unsupported(description: "the Git index cannot be read inertly (\(why))")
    }
    guard bytes.count >= 32, Array(bytes[0..<4]) == Array("DIRC".utf8) else {
      throw unsupported("not an index file")
    }
    let body = bytes[0..<(bytes.count - 20)]
    guard Array(Insecure.SHA1.hash(data: body)) == Array(bytes[(bytes.count - 20)...]) else {
      throw unsupported("checksum mismatch or a non-SHA-1 repository")
    }
    func u32(_ at: Int) throws -> Int {
      guard at + 4 <= body.count else { throw unsupported("truncated") }
      return Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8
        | Int(bytes[at + 3])
    }
    func u16(_ at: Int) throws -> Int {
      guard at + 2 <= body.count else { throw unsupported("truncated") }
      return Int(bytes[at]) << 8 | Int(bytes[at + 1])
    }
    let version = try u32(4)
    guard [2, 3, 4].contains(version) else { throw unsupported("version \(version)") }
    let count = try u32(8)
    guard count <= maxEntries else { throw unsupported("too many entries") }
    var offset = 12
    var previous: [UInt8] = []
    var paths: [String] = []
    for _ in 0..<count {
      let start = offset
      let mode = try u32(start + 24)
      offset = start + 40 + 20
      let flags = try u16(offset)
      offset += 2
      guard (flags >> 12) & 0x3 == 0 else { throw unsupported("unmerged entries") }
      if flags & 0x4000 != 0 {
        guard version >= 3 else { throw unsupported("extended flags in version 2") }
        let extended = try u16(offset)
        offset += 2
        guard extended & 0x4000 == 0 else { throw unsupported("skip-worktree (sparse) entries") }
      }
      var name: [UInt8]
      if version == 4 {
        // Git's offset varint: big-endian 7-bit groups, each continuation
        // adding one (`decode_varint`).
        var strip = 0
        var byte: UInt8
        var first = true
        repeat {
          guard offset < body.count, strip < 1 << 24 else { throw unsupported("bad path prefix") }
          byte = bytes[offset]
          offset += 1
          strip = (first ? 0 : (strip + 1) << 7) + Int(byte & 0x7F)
          first = false
        } while byte & 0x80 != 0
        guard strip <= previous.count else { throw unsupported("bad path prefix") }
        name = Array(previous.prefix(previous.count - strip))
        guard let end = body[offset...].firstIndex(of: 0) else { throw unsupported("truncated") }
        name += bytes[offset..<end]
        offset = end + 1
      } else {
        guard let end = body[offset...].firstIndex(of: 0) else { throw unsupported("truncated") }
        name = Array(bytes[offset..<end])
        let length = end - start + 1
        offset = start + ((length + 7) / 8) * 8
      }
      previous = name
      switch mode & 0o170000 {
      case 0o100000, 0o120000: break
      case 0o160000: throw unsupported("submodules")
      case 0o040000: throw unsupported("a sparse index")
      default: throw unsupported("an unknown entry type")
      }
      guard let text = String(validating: name, as: UTF8.self),
        WorkspaceInputConfig.validSelector(text), text != "."
      else { throw unsupported("an unsupported path name") }
      paths.append(text)
    }
    return paths
  }
}

/// `local-secret-names/1`: the fixed table of credential-looking names an
/// outbound snapshot omits even when tracked. A convenience, not content
/// scanning: selected source can still hold secrets.
enum LocalSecretNames {
  static let version = "local-secret-names/1"

  /// Why `path` is omitted, nil when it is not a secret name.
  static func match(_ path: String) -> String? {
    let components = path.split(separator: "/").map { ProtectedPaths.folded(String($0)) }
    guard let last = components.last else { return nil }
    for directory in [".aws", ".ssh", ".gnupg"]
    where components.dropLast().contains(directory)
      || last == directory
    {
      return "\(directory)/"
    }
    for (parent, name) in [(".docker", "config.json"), (".kube", "config")]
    where components.count >= 2 && components.suffix(2) == [parent, name] {
      return "\(parent)/\(name)"
    }
    let exact = [
      ".env", ".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", "credentials.json",
    ]
    if exact.contains(last) { return last }
    if last.hasPrefix(".env.") { return ".env.*" }
    for suffix in [".pem", ".key", ".p12", ".pfx", ".keystore"] where last.hasSuffix(suffix) {
      return "*" + suffix
    }
    for prefix in ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"] where last.hasPrefix(prefix) {
      return prefix + "*"
    }
    return nil
  }
}

/// One operation's shared outbound budget, across every root it sends.
package final class InputBudget {
  let limits: WorkspaceInputConfig.Limits
  private(set) var entries: UInt64 = 0
  private(set) var bytes: UInt64 = 0

  package init(_ limits: WorkspaceInputConfig.Limits) { self.limits = limits }

  /// Undoes a capture that is about to be retried.
  func rewind(entries: UInt64, bytes: UInt64) {
    self.entries = entries
    self.bytes = bytes
  }

  func count(_ path: String, size: UInt64) throws {
    guard size <= limits.maxFileBytes else {
      throw HostError(
        "\(neutralizeControls(path)) (\(size) bytes) exceeds workspace.input.limits.max_file_bytes (\(limits.maxFileBytes))"
      )
    }
    entries += 1
    bytes += size
    guard entries <= limits.maxEntries else {
      throw HostError(
        "The selection exceeds workspace.input.limits.max_entries (\(limits.maxEntries))")
    }
    guard bytes <= limits.maxTotalBytes else {
      throw HostError(
        "The selection exceeds workspace.input.limits.max_total_bytes (\(limits.maxTotalBytes))")
    }
  }
}

/// What a snapshot selected and left out, for display (names only).
package struct InputReport: Equatable {
  var selected = 0
  var bytes: UInt64 = 0
  var secrets: [String] = []
  var excluded: [String] = []
  var links: [String] = []
  var unsupported: [String] = []
  /// Tracked files deleted on the host; outbound removal is not
  /// implemented, so the guest keeps its copies.
  var deletedTracked: [String] = []
}

/// An immutable copy of one root's selected entries in private host state.
final class InputSnapshot {
  let id: String
  let directory: String
  let report: InputReport
  var tree: String { directory + "/tree" }

  private init(id: String, directory: String, report: InputReport) {
    self.id = id
    self.directory = directory
    self.report = report
  }

  func remove() { try? StageLocation.removeTree(directory) }

  /// Snapshots `root` under `input` into a fresh owner-only directory below
  /// `stateDirectory`. A source that changes while it is copied is
  /// re-captured, at most three times in all, then refused.
  static func capture(
    root: String, input: WorkspaceInputConfig, budget: InputBudget, stateDirectory: String,
    wholeRoot: Bool = false
  ) throws -> InputSnapshot {
    guard let canonical = canonicalPath(root) else {
      throw HostError("\(neutralizeControls(root)) does not exist")
    }
    try ReturnState.ensurePrivateDirectory(stateDirectory)
    var lastError: (any Error)? = nil
    for _ in 0..<3 {
      let id = randomHex(8)
      let directory = stateDirectory + "/" + id
      guard mkdir(directory, 0o700) == 0 else {
        throw HostError.posix("Failed to create", directory)
      }
      let entriesBefore = budget.entries
      let bytesBefore = budget.bytes
      do {
        var builder = Builder(
          root: canonical, input: input, budget: budget, wholeRoot: wholeRoot,
          tree: directory + "/tree")
        let report = try builder.build()
        return InputSnapshot(id: id, directory: directory, report: report)
      } catch let race as SourceChanged {
        try? StageLocation.removeTree(directory)
        budget.rewind(entries: entriesBefore, bytes: bytesBefore)
        lastError = race
      } catch {
        try? StageLocation.removeTree(directory)
        throw error
      }
    }
    throw HostError(
      "The workspace kept changing while it was captured (\(lastError.map { "\($0)" } ?? "")); retry when it is idle"
    )
  }

  struct SourceChanged: Error, CustomStringConvertible {
    let path: String
    var description: String { "\(neutralizeControls(path)) changed while copied" }
  }

  private struct Builder {
    let root: String
    let input: WorkspaceInputConfig
    let budget: InputBudget
    let wholeRoot: Bool
    let tree: String
    var report = InputReport()
    var selected: [String: Kind] = [:]

    enum Kind { case file, directory, link }

    init(
      root: String, input: WorkspaceInputConfig, budget: InputBudget, wholeRoot: Bool, tree: String
    ) {
      self.root = root
      self.input = input
      self.budget = budget
      self.wholeRoot = wholeRoot
      self.tree = tree
    }

    mutating func build() throws -> InputReport {
      var candidates: [String] = []
      if wholeRoot {
        candidates += try expand(".")
      } else {
        switch input.mode {
        case .tracked:
          let tracked: [String]
          do {
            guard let paths = try GitIndexInventory.trackedPaths(root) else {
              throw HostError(
                "\(neutralizeControls(root)) is not a Git working tree; select what to send with workspace.input.mode \"paths\" (for everything: {\"path\": \".\", \"recursive\": true})"
              )
            }
            tracked = paths
          } catch let unsupported as GitIndexInventory.Unsupported {
            throw HostError(
              "\(unsupported.description) in \(neutralizeControls(root)); select what to send with workspace.input.mode \"paths\""
            )
          }
          for path in tracked {
            var info = stat()
            if lstat(root + "/" + path, &info) != 0 && errno == ENOENT {
              report.deletedTracked.append(path)
            } else {
              candidates.append(path)
            }
          }
          for selector in input.paths {
            candidates += selector.recursive ? try expand(selector.path) : [selector.path]
          }
        case .paths:
          for selector in input.paths {
            candidates += selector.recursive ? try expand(selector.path) : [selector.path]
          }
        }
      }
      var unique = Set<String>()
      var accepted: [String] = []
      for path in candidates where unique.insert(path).inserted {
        if let reason = omission(path) {
          record(path, reason)
          continue
        }
        accepted.append(path)
      }
      // Parents first; a directory's entries follow it.
      accepted.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
      guard mkdir(tree, 0o700) == 0 else { throw HostError.posix("Failed to create", tree) }
      for path in accepted { try copy(path) }
      try checkLinks()
      return report
    }

    /// Why `path` is not sent, nil to send it.
    func omission(_ path: String) -> String? {
      if ProtectedPaths.isReserved(path) { return "git" }
      if input.exclude.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
        return "excluded"
      }
      if LocalSecretNames.match(path) != nil, !input.secretAllow.contains(path) { return "secret" }
      return nil
    }

    mutating func record(_ path: String, _ reason: String) {
      switch reason {
      case "secret": report.secrets.append(path)
      case "git": break
      case "link": report.links.append(path)
      case "unsupported": report.unsupported.append(path)
      default: report.excluded.append(path)
      }
    }

    /// Every entry below `path` (itself included), never following a link.
    func expand(_ path: String) throws -> [String] {
      var out: [String] = path == "." ? [] : [path]
      let base = path == "." ? root : root + "/" + path
      var info = stat()
      guard lstat(base, &info) == 0 else {
        throw HostError("workspace.input selects \(neutralizeControls(path)), which does not exist")
      }
      guard info.st_mode & S_IFMT == S_IFDIR else { return out }
      var stack: [(String, Int)] = [(path == "." ? "" : path, 0)]
      while let (relative, depth) = stack.popLast() {
        guard depth < 64 else {
          throw HostError("\(neutralizeControls(relative)) is nested too deeply")
        }
        let directory = relative.isEmpty ? root : root + "/" + relative
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted() } catch
        {
          throw HostError("Failed to read \(neutralizeControls(directory))")
        }
        for name in names {
          let child = relative.isEmpty ? name : relative + "/" + name
          if ProtectedPaths.isReservedName(name) { continue }
          if defaultExcludes.contains(name + "/") { continue }
          out.append(child)
          var childInfo = stat()
          if lstat(root + "/" + child, &childInfo) == 0, childInfo.st_mode & S_IFMT == S_IFDIR {
            stack.append((child, depth + 1))
          }
        }
      }
      return out
    }

    mutating func copy(_ path: String) throws {
      // Ancestors exist in the copy as plain directories. A path under a
      // link (selected or not) or a file is never copied: reading or
      // writing through it would leave the root or the tree.
      var ancestor = ""
      for component in path.split(separator: "/").dropLast() {
        ancestor += ancestor.isEmpty ? String(component) : "/" + component
        if let kind = selected[ancestor] {
          guard kind == .directory else {
            record(path, "link")
            return
          }
        } else {
          var info = stat()
          guard lstat(root + "/" + ancestor, &info) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw SourceChanged(path: ancestor) }
            throw HostError.posix("Failed to inspect", root + "/" + ancestor)
          }
          guard info.st_mode & S_IFMT == S_IFDIR else {
            record(path, "link")
            return
          }
          guard mkdir(tree + "/" + ancestor, 0o755) == 0 || errno == EEXIST else {
            throw HostError.posix("Failed to create", tree + "/" + ancestor)
          }
          selected[ancestor] = .directory
        }
      }
      if selected[path] != nil { return }
      let source = root + "/" + path
      var before = stat()
      guard lstat(source, &before) == 0 else { throw SourceChanged(path: path) }
      switch before.st_mode & S_IFMT {
      case S_IFDIR:
        try budget.count(path, size: 0)
        guard mkdir(tree + "/" + path, 0o755) == 0 || errno == EEXIST else {
          throw HostError.posix("Failed to create", tree + "/" + path)
        }
        selected[path] = .directory
      case S_IFLNK:
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: source),
          StageBuilder.staysInside(link: path, target: target)
        else {
          record(path, "link")
          return
        }
        try budget.count(path, size: 0)
        guard symlink(target, tree + "/" + path) == 0 else {
          throw HostError.posix("Failed to copy link", path)
        }
        selected[path] = .link
      case S_IFREG:
        guard before.st_nlink == 1 else {
          record(path, "unsupported")
          return
        }
        try budget.count(path, size: UInt64(before.st_size))
        let input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard input >= 0 else {
          if errno == ENOENT || errno == ELOOP { throw SourceChanged(path: path) }
          throw HostError.posix("Failed to read", source)
        }
        defer { close(input) }
        let output = open(
          tree + "/" + path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
          mode_t(before.st_mode & 0o755) | 0o600)
        guard output >= 0 else { throw HostError.posix("Failed to create", tree + "/" + path) }
        defer { close(output) }
        _ = try StageBuilder.sha256(fd: input, path: path, copyingTo: output)
        var after = stat()
        guard fstat(input, &after) == 0, after.st_ino == before.st_ino,
          after.st_size == before.st_size,
          after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
          after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
        else { throw SourceChanged(path: path) }
        fchmod(output, mode_t(before.st_mode & 0o755))
        selected[path] = .file
        report.selected += 1
        report.bytes += UInt64(before.st_size)
      default:
        record(path, "unsupported")
      }
    }

    /// A kept link may not pass through or end at another selected link:
    /// the guest kernel would resolve the chain.
    mutating func checkLinks() throws {
      for (path, kind) in selected where kind == .link {
        let target =
          (try? FileManager.default.destinationOfSymbolicLink(atPath: tree + "/" + path)) ?? ""
        var stack = path.split(separator: "/").map(String.init)
        _ = stack.popLast()
        var chained = false
        for component in target.split(separator: "/").map(String.init) {
          switch component {
          case ".": continue
          case "..": _ = stack.popLast()
          default:
            stack.append(component)
            if ProtectedPaths.isReservedName(component)
              || selected[stack.joined(separator: "/")] == .link
            {
              chained = true
            }
          }
          if chained { break }
        }
        if chained {
          unlink(tree + "/" + path)
          selected[path] = nil
          report.links.append(path)
        }
      }
    }
  }
}
