import Foundation
import IsoCore

/// A stage apply that stopped partway. `applied` lists the paths already
/// written to the destination; the stage is kept for diagnosis.
public struct StageApplyError: Error, CustomStringConvertible {
  public let applied: [String]
  public let failed: String
  public let cause: String

  public var description: String {
    var lines = ["Stage apply failed at \(neutralizeControls(failed)): \(cause)"]
    if applied.isEmpty {
      lines.append("No changes were applied.")
    } else {
      lines.append("Already applied (\(applied.count)):")
      lines += applied.map { "  \(neutralizeControls($0))" }
    }
    lines.append("The stage is kept; inspect it, then re-stage or discard it.")
    return lines.joined(separator: "\n")
  }
}

/// Applies a reviewed manifest to its destination, descriptor-relative and
/// without following any link in the destination.
struct StageApplier {
  let manifest: StageManifest
  let tree: String

  /// Refuses an inapplicable stage, or one whose destination changed since
  /// it was built. Runs before anything is written.
  func preflight() throws {
    guard manifest.applicable else {
      throw HostError(
        "Stage \(manifest.id) cannot be applied:\n"
          + manifest.issues.map { "  - \(neutralizeControls($0))" }.joined(separator: "\n"))
    }
    var drifted: [String] = []
    let changed = Set(manifest.changes.map(\.path))
    var checkedParents = Set<String>()
    for change in manifest.changes {
      let now = try StageBuilder.destinationObject(manifest.destination, change.path)
      if now != change.old { drifted.append(change.path) }
      // An unchanged ancestor must still be a real directory; one the stage
      // creates or replaces is checked through its own change.
      var ancestor = ""
      for component in change.path.split(separator: "/").dropLast() {
        ancestor += ancestor.isEmpty ? String(component) : "/" + component
        guard !changed.contains(ancestor), checkedParents.insert(ancestor).inserted else {
          continue
        }
        let object = try StageBuilder.destinationObject(manifest.destination, ancestor)
        if object != .directory && object != .absent { drifted.append(ancestor) }
      }
    }
    guard drifted.isEmpty else {
      let shown = drifted.prefix(20).map { "  \(neutralizeControls($0))" }.joined(separator: "\n")
      throw HostError(
        "The destination changed since stage \(manifest.id) was reviewed:\n\(shown)\nRe-stage with `iso diff` or `iso pull --review`."
      )
    }
  }

  /// Applies every change in path order and returns the applied paths.
  func apply() throws -> [String] {
    try preflight()
    let root = open(manifest.destination, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard root >= 0 else { throw HostError.posix("Failed to open", manifest.destination) }
    defer { close(root) }
    let stageRoot = open(tree, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard stageRoot >= 0 else { throw HostError.posix("Failed to open stage", tree) }
    defer { close(stageRoot) }
    var applied: [String] = []
    for change in manifest.changes {
      do {
        try apply(change, destination: root, stage: stageRoot)
      } catch {
        throw StageApplyError(applied: applied, failed: change.path, cause: "\(error)")
      }
      applied.append(change.path)
    }
    return applied
  }

  private func apply(_ change: StageChange, destination root: Int32, stage stageRoot: Int32) throws
  {
    var components = change.path.split(separator: "/").map(String.init)
    let name = components.removeLast()
    let parent = try Self.openDirectory(root, components, label: "destination")
    defer { if parent != root { close(parent) } }
    let stageParent = try Self.openDirectory(stageRoot, components, label: "stage")
    defer { if stageParent != stageRoot { close(stageParent) } }

    // The destination can change between preflight and this write.
    let current = try StageBuilder.object(at: parent, name, path: change.path)
    guard current == change.old else {
      throw HostError("the destination entry changed during apply")
    }
    switch change.new {
    case .directory:
      if change.old != .absent {
        guard unlinkat(parent, name, 0) == 0 else {
          throw HostError.posix("Failed to remove", name)
        }
      }
      guard mkdirat(parent, name, 0o755) == 0 else {
        throw HostError.posix("Failed to create directory", name)
      }
    case .file(_, let digest, let mode):
      let source = openat(stageParent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard source >= 0 else { throw HostError.posix("Failed to open staged", name) }
      defer { close(source) }
      var info = stat()
      guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        throw HostError("staged entry is no longer a regular file")
      }
      let temporary = ".iso-stage-\(randomHex(8))"
      let output = openat(
        parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard output >= 0 else { throw HostError.posix("Failed to create", temporary) }
      var published = false
      defer {
        if !published { unlinkat(parent, temporary, 0) }
      }
      do {
        defer { close(output) }
        let copied = try StageBuilder.sha256(fd: source, path: name, copyingTo: output)
        guard copied == digest else {
          throw HostError("staged content changed since the stage was reviewed")
        }
        guard fchmod(output, mode_t(mode) & 0o777) == 0 else {
          throw HostError.posix("Failed to set permissions on", temporary)
        }
        var times = [info.st_atimespec, info.st_mtimespec]
        futimens(output, &times)
      }
      guard renameat(parent, temporary, parent, name) == 0 else {
        throw HostError.posix("Failed to replace", name)
      }
      published = true
    case .symlink(let target):
      guard
        case .symlink(let staged)? = try? StageBuilder.object(at: stageParent, name, path: name),
        staged == target
      else { throw HostError("staged link changed since the stage was reviewed") }
      let temporary = ".iso-stage-\(randomHex(8))"
      guard symlinkat(target, parent, temporary) == 0 else {
        throw HostError.posix("Failed to create link", temporary)
      }
      guard renameat(parent, temporary, parent, name) == 0 else {
        unlinkat(parent, temporary, 0)
        throw HostError.posix("Failed to replace", name)
      }
    }
  }

  /// Opens `components` below `root` one at a time, refusing links.
  static func openDirectory(_ root: Int32, _ components: [String], label: String) throws -> Int32 {
    var directory = root
    for component in components {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      if directory != root { close(directory) }
      guard next >= 0 else {
        throw HostError.posix("Failed to open \(label) directory", component)
      }
      directory = next
    }
    return directory
  }
}
