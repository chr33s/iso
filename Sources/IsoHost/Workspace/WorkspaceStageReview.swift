import Foundation
import IsoCore

/// Renders a stage for review: a summary, one line per change, then text
/// diffs. Every guest-derived string passes through `neutralizeControls`,
/// and nothing here runs a subprocess (no Git, pager, diff or editor).
/// Content is read descriptor-relative without following links and must
/// match the manifest's hashes; a mismatch marks the view stale.
package struct StageReview {
  package let manifest: StageManifest
  let tree: String

  package init(_ selected: SelectedStage) {
    manifest = selected.manifest
    tree = selected.stage.tree
  }

  package init(manifest: StageManifest, tree: String) {
    self.manifest = manifest
    self.tree = tree
  }

  static let textLimit: UInt64 = 256 << 10
  static let lineLimit = 400
  static let maxDiffLines = 10_000

  /// Paths whose contents can make host tools run commands. Raw `.git`
  /// administration is never installed; the rest need named grants.
  static func conspicuous(_ path: String) -> String? {
    if ProtectedPaths.isReserved(path) { return "git administration is never installed" }
    return SensitivePaths.classify(path)
  }

  package func summary(instance: String) -> [String] {
    let counts = Dictionary(grouping: manifest.changes, by: \.operation).mapValues(\.count)
    var delta: Int64 = 0
    for change in manifest.changes {
      if case .file(let size, _, _) = change.new { delta += Int64(size) }
      if case .file(let size, _, _) = change.old { delta -= Int64(size) }
    }
    let create = if case .create = manifest.binding { " (will be created)" } else { "" }
    var lines = [
      "Stage \(manifest.id) of '\(instance)' -> \(neutralizeControls(manifest.destination))\(create)",
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
      if let note = change.sensitive { line += "  ! withheld: \(note)" }
      lines.append(line)
    }
    if manifest.excludedCount > 0 {
      lines.append(
        "  \(manifest.excludedCount) git administration entries were received but are never installed"
      )
    }
    if !manifest.applicable {
      lines.append("This stage cannot be applied:")
      lines += manifest.issues.map { "  - \(neutralizeControls($0))" }
    } else if !manifest.sensitivePaths.isEmpty {
      lines.append(
        "Withheld until named: \(manifest.sensitivePaths.count) execution-sensitive path(s) apply only with --approve-sensitive for each."
      )
    }
    return lines
  }

  /// The exact command that applies this stage, naming every sensitive
  /// path it needs.
  package func applyCommand(instance: String) -> String {
    (["iso pull \(instance) --apply --stage-id \(manifest.id)"]
      + manifest.sensitivePaths.map { "--approve-sensitive \(shellEscape($0))" })
      .joined(separator: " ")
  }

  /// Unified-style diffs for small UTF-8 text files.
  /// With `markOmitted`, every changed file whose diff is not shown gets an
  /// explicit line saying so, so an approval never covers content silently.
  /// `stale` is set when content no longer matches the manifest.
  package func textDiffs(markOmitted: Bool = false) -> [String] {
    var stale = false
    return textDiffs(markOmitted: markOmitted, stale: &stale)
  }

  package func textDiffs(markOmitted: Bool, stale: inout Bool) -> [String] {
    var lines: [String] = []
    let destinationView: StageDestinationView? =
      (try? ReturnDestination(path: manifest.destination, binding: manifest.binding).open())
      .map {
        StageDestinationView(
          ReturnDestination(path: manifest.destination, binding: manifest.binding), $0)
      }
    let stageRoot = open(tree, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    defer { if stageRoot >= 0 { close(stageRoot) } }
    if destinationView == nil || stageRoot < 0 { stale = true }
    for change in manifest.changes {
      guard case .file(let newSize, let newDigest, _) = change.new else { continue }
      let shown = neutralizeControls(change.path)
      let omitted =
        "(diff omitted for \(shown): binary, not UTF-8, or larger than \(Self.textLimit >> 10) KiB)"
      guard newSize <= Self.textLimit else {
        if markOmitted { lines.append(omitted) }
        continue
      }
      let old: [String]
      switch change.old {
      case .absent: old = []
      case .file(let size, let oldDigest, _) where size <= Self.textLimit:
        guard let view = destinationView,
          let read = try? view.read(change.path, limit: Int(Self.textLimit))
        else {
          stale = true
          continue
        }
        guard read.sha256 == oldDigest else {
          stale = true
          continue
        }
        guard let text = read.bytes.flatMap(Self.lines) else {
          if markOmitted { lines.append(omitted) }
          continue
        }
        old = text
      default:
        if markOmitted { lines.append(omitted) }
        continue
      }
      guard stageRoot >= 0,
        let read = Self.read(stageRoot, change.path, limit: Int(Self.textLimit))
      else {
        stale = true
        continue
      }
      guard read.sha256 == newDigest else {
        stale = true
        continue
      }
      guard let new = read.bytes.flatMap(Self.lines) else {
        if markOmitted { lines.append(omitted) }
        continue
      }
      lines.append("--- a/\(shown)")
      lines.append("+++ b/\(shown)")
      lines += Self.hunks(old: old, new: new)
    }
    if stale {
      lines.append(
        "(this review is stale: the destination or stage changed while it was read; re-stage before applying)"
      )
    }
    return lines
  }

  /// Bytes (when at most `limit`) and the SHA-256 of `relative` below
  /// `root`, read without following links.
  static func read(_ root: Int32, _ relative: String, limit: Int) -> (
    bytes: [UInt8]?, sha256: String
  )? {
    var components = relative.split(separator: "/").map(String.init)
    guard let name = components.popLast(),
      let parent = try? StageApplier.openDirectory(root, components, label: "stage")
    else { return nil }
    defer { if parent != root { close(parent) } }
    let fd = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      let digest = try? StageBuilder.sha256(fd: fd, path: relative)
    else { return nil }
    guard info.st_size <= limit, lseek(fd, 0, SEEK_SET) == 0,
      let bytes = try? StateStore.readBounded(fd, path: relative, limit: limit, tooLarge: "")
    else { return (nil, digest) }
    return (bytes, digest)
  }

  /// Lines of UTF-8 text without NUL bytes.
  static func lines(_ bytes: [UInt8]) -> [String]? {
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
