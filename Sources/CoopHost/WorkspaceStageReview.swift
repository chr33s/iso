import CoopCore
import Foundation

/// Renders a stage for review: a summary, one line per change, then text
/// diffs. Every guest-derived string passes through `neutralizeControls`,
/// and nothing here runs a subprocess on staged content.
public struct StageReview {
  public let manifest: StageManifest
  let tree: String

  public init(manifest: StageManifest, location: StageLocation) {
    self.manifest = manifest
    tree = location.tree
  }

  init(manifest: StageManifest, tree: String) {
    self.manifest = manifest
    self.tree = tree
  }

  static let textLimit: UInt64 = 256 << 10
  static let lineLimit = 400
  static let maxDiffLines = 10_000

  /// Paths whose contents can make host tools run commands. Compared
  /// case- and normalization-insensitively, as APFS resolves them.
  static func conspicuous(_ path: String) -> String? {
    let components = path.precomposedStringWithCanonicalMapping.lowercased()
      .split(separator: "/").map(String.init)
    if let git = components.firstIndex(of: ".git") {
      let rest = components[(git + 1)...]
      if rest.contains("hooks") { return "git hook runs on the host" }
      if rest.last == "config" { return "git configuration can run host commands" }
      // A `.git` file redirects the git directory; anything inside one can
      // hold config (fsmonitor, aliases) or hooks that run on the host.
      return "git metadata can run host commands"
    }
    if components.contains(".husky") { return "git hook runs on the host" }
    if components.last == ".envrc" { return "direnv runs .envrc on the host" }
    if components.suffix(2) == [".vscode", "tasks.json"] {
      return "editor task can run host commands"
    }
    return nil
  }

  public func summary(instance: String) -> [String] {
    let counts = Dictionary(grouping: manifest.changes, by: \.operation).mapValues(\.count)
    var delta: Int64 = 0
    for change in manifest.changes {
      if case .file(let size, _, _) = change.new { delta += Int64(size) }
      if case .file(let size, _, _) = change.old { delta -= Int64(size) }
    }
    var lines = [
      "Stage \(manifest.id) of '\(instance)' -> \(neutralizeControls(manifest.destination))",
      "  \(counts[.add] ?? 0) added, \(counts[.modify] ?? 0) modified, \(counts[.typeChange] ?? 0) type changes; \(Self.signedBytes(delta)) (\(manifest.stagedEntries) entries staged)",
    ]
    for change in manifest.changes {
      let marker =
        switch change.operation {
        case .add: "A"
        case .modify: "M"
        case .typeChange: "T"
        }
      var line = "  \(marker) \(neutralizeControls(change.path))"
      switch change.new {
      case .directory: line += "/"
      case .symlink(let target): line += " -> \(neutralizeControls(target))"
      case .file(let size, _, let mode):
        line += " (\(size) B"
        if mode & 0o111 != 0 { line += ", executable" }
        line += ")"
      }
      if change.operation == .typeChange {
        line += " [\(change.old.kindName) -> \(change.new.kindName)]"
      }
      if let note = Self.conspicuous(change.path) { line += "  ! \(note)" }
      lines.append(line)
    }
    if !manifest.applicable {
      lines.append("This stage cannot be applied:")
      lines += manifest.issues.map { "  - \(neutralizeControls($0))" }
    }
    return lines
  }

  /// Unified-style diffs for small UTF-8 text files.
  public func textDiffs() -> [String] {
    var lines: [String] = []
    for change in manifest.changes {
      guard case .file(let newSize, _, _) = change.new, newSize <= Self.textLimit else { continue }
      let old: [String]
      switch change.old {
      case .absent: old = []
      case .file(let size, _, _) where size <= Self.textLimit:
        guard let text = Self.text(at: manifest.destination + "/" + change.path) else { continue }
        old = text
      default: continue
      }
      guard let new = Self.text(at: tree + "/" + change.path) else { continue }
      let shown = neutralizeControls(change.path)
      lines.append("--- a/\(shown)")
      lines.append("+++ b/\(shown)")
      lines += Self.hunks(old: old, new: new)
    }
    return lines
  }

  /// Lines of a UTF-8 file without NUL bytes, read without following links.
  static func text(at path: String) -> [String]? {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while true {
      let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count >= 0 else { return nil }
      if count == 0 { break }
      bytes.append(contentsOf: chunk[0..<count])
      guard bytes.count <= textLimit else { return nil }
    }
    guard !bytes.contains(0), let text = String(validating: bytes, as: UTF8.self) else {
      return nil
    }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  enum Line: Equatable {
    case same(String)
    case removed(String)
    case added(String)
  }

  /// Myers edit script (`CollectionDifference`) rendered as hunks with three
  /// lines of context, capped at `lineLimit` output lines per file.
  static func hunks(old: [String], new: [String], context: Int = 3) -> [String] {
    // Myers is O((N+M)·D): bound the work a guest-authored file can cause.
    guard old.count + new.count <= maxDiffLines else {
      return ["(diff skipped: more than \(maxDiffLines) lines)"]
    }
    let difference = new.difference(from: old)
    var removed = Set<Int>()
    var inserted = Set<Int>()
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removed.insert(offset)
      case .insert(let offset, _, _): inserted.insert(offset)
      }
    }
    var script: [(line: Line, old: Int, new: Int)] = []
    var i = 0
    var j = 0
    while i < old.count || j < new.count {
      if i < old.count && removed.contains(i) {
        script.append((.removed(old[i]), i, j))
        i += 1
      } else if j < new.count && inserted.contains(j) {
        script.append((.added(new[j]), i, j))
        j += 1
      } else {
        script.append((.same(old[i]), i, j))
        i += 1
        j += 1
      }
    }
    let changed = script.indices.filter { if case .same = script[$0].line { false } else { true } }
    guard !changed.isEmpty else { return [] }
    var output: [String] = []
    var start = changed[0]
    var index = 0
    while index < changed.count {
      var end = changed[index]
      while index + 1 < changed.count && changed[index + 1] - end <= 2 * context {
        index += 1
        end = changed[index]
      }
      let lower = max(start - context, 0)
      let upper = min(end + context, script.count - 1)
      output.append("@@ -\(script[lower].old + 1) +\(script[lower].new + 1) @@")
      for entry in script[lower...upper] {
        let text: String
        switch entry.line {
        case .same(let line): text = " " + line
        case .removed(let line): text = "-" + line
        case .added(let line): text = "+" + line
        }
        output.append(neutralizeControls(text))
      }
      index += 1
      if index < changed.count { start = changed[index] }
    }
    if output.count > lineLimit {
      let omitted = output.count - lineLimit
      output = Array(output.prefix(lineLimit)) + ["... \(omitted) more diff lines"]
    }
    return output
  }

  static func signedBytes(_ delta: Int64) -> String {
    delta >= 0 ? "+\(delta) B" : "\(delta) B"
  }
}
