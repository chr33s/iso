import Foundation
import IsoCore

/// A stage apply that stopped partway (RET-08). Reports what was written,
/// the operation that failed and whether it changed anything; the stage is
/// kept, and a retry needs a fresh review and approval.
package struct StageApplyError: Error, CustomStringConvertible {
  /// What the failed operation left at its path.
  package enum Effect: String, Sendable, Equatable {
    case unchanged
    case changed
    case uncertain
  }

  package let applied: [String]
  package let failed: String
  package let cause: String
  package var effect: Effect = .unchanged
  /// The destination directory this attempt created, if it did.
  package var createdRoot: String? = nil
  package var stageID: String? = nil

  package var description: String {
    var lines = ["Stage apply failed at \(neutralizeControls(failed)): \(cause)"]
    switch effect {
    case .unchanged: break
    case .changed: lines.append("That entry was changed before the failure.")
    case .uncertain: lines.append("That entry's state is uncertain; inspect it.")
    }
    if let createdRoot { lines.append("Created \(neutralizeControls(createdRoot)).") }
    if applied.isEmpty && effect == .unchanged {
      lines.append(createdRoot == nil ? "No changes were applied." : "No files were installed.")
    } else if !applied.isEmpty {
      lines.append("Already applied (\(applied.count)):")
      lines += applied.map { "  \(neutralizeControls($0))" }
    }
    lines.append(
      "The stage\(stageID.map { " \($0)" } ?? "") is kept, but its approval is used; re-stage with `iso diff` to review what remains."
    )
    return lines.joined(separator: "\n")
  }
}

/// Installs a validated manifest: complete preflight before the first
/// mutation, then each change through the verified destination handle,
/// descriptor-relative, never following a link, rechecking the expected
/// old object immediately before each replacement.
struct StageApplier {
  let manifest: StageManifest
  let tree: String

  var destination: ReturnDestination {
    ReturnDestination(path: manifest.destination, binding: manifest.binding)
  }

  /// Refuses an inapplicable stage, or one whose destination, gitfiles or
  /// ancestors changed since it was built. Writes nothing.
  func preflight(_ verified: VerifiedDestination) throws {
    guard manifest.applicable else {
      throw ReturnError(
        manifest.issues.contains { $0.contains(".git") || $0.contains("gitfile") }
          ? .unsupportedLayout : .blockedMetadata, stageID: manifest.id,
        "Stage \(manifest.id) cannot be applied:\n"
          + manifest.issues.map { "  - \(neutralizeControls($0))" }.joined(separator: "\n"))
    }
    let view = StageDestinationView(destination, verified)
    if case .create = manifest.binding {
      guard manifest.changes.allSatisfy({ $0.old == .absent }), manifest.gitfiles.isEmpty else {
        throw ReturnError(.drift, stageID: manifest.id, "Stage \(manifest.id) is inconsistent")
      }
      return
    }
    var drifted: [String] = []
    let changed = Set(manifest.changes.map(\.path))
    var checkedParents = Set<String>()
    for change in manifest.changes {
      if try view.object(change.path) != change.old { drifted.append(change.path) }
      // An unchanged ancestor must still be a real directory; one the stage
      // creates is checked through its own change.
      var ancestor = ""
      for component in change.path.split(separator: "/").dropLast() {
        ancestor += ancestor.isEmpty ? String(component) : "/" + component
        guard !changed.contains(ancestor), checkedParents.insert(ancestor).inserted else {
          continue
        }
        let object = try view.object(ancestor)
        if object != .directory && object != .absent { drifted.append(ancestor) }
      }
    }
    for observation in manifest.gitfiles
    where try view.read(observation.path, limit: 0).sha256 != observation.sha256 {
      drifted.append(observation.path)
    }
    guard drifted.isEmpty else {
      let shown = drifted.prefix(20).map { "  \(neutralizeControls($0))" }.joined(separator: "\n")
      throw ReturnError(
        .drift, stageID: manifest.id,
        "The destination changed since stage \(manifest.id) was reviewed:\n\(shown)\nRe-stage with `iso diff` or `iso pull --review`."
      )
    }
  }

  /// Re-hashes the staged tree against the manifest, so the content that
  /// was rendered for review is the content that will be applied. Nothing
  /// is written.
  func verifyStage() throws {
    let stageRoot = open(tree, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard stageRoot >= 0 else { throw HostError.posix("Failed to open stage", tree) }
    defer { close(stageRoot) }
    for change in manifest.changes {
      var components = change.path.split(separator: "/").map(String.init)
      let name = components.removeLast()
      let parent = try Self.openDirectory(stageRoot, components, label: "stage")
      defer { if parent != stageRoot { close(parent) } }
      // Modes come from the manifest at apply time; the builder may have
      // widened the staged copy's owner bits to read it.
      let matches =
        switch (try StageBuilder.object(at: parent, name, path: change.path), change.new) {
        case (.file(let size, let digest, _), .file(let wantSize, let wantDigest, _)):
          size == wantSize && digest == wantDigest
        case (.directory, .directory): true
        case (.symlink(let target), .symlink(let wanted)): target == wanted
        default: false
        }
      guard matches else {
        throw ReturnError(
          .drift, stageID: manifest.id,
          "staged content changed since stage \(manifest.id) was built (\(neutralizeControls(change.path))); re-stage with `iso pull --review`"
        )
      }
    }
  }

  /// Applies every change in path order and returns the applied paths.
  /// `log` records progress for recovery; a safe-create of an absent
  /// destination is the first recorded mutation.
  func apply(_ verified: VerifiedDestination, log: ApplyProgressLog? = nil) throws -> [String] {
    try preflight(verified)
    let root: Descriptor
    var created: String? = nil
    switch verified {
    case .existing(let handle): root = handle
    case .absent(let parent, let name):
      guard mkdirat(parent.fd, name, 0o755) == 0 else {
        throw StageApplyError(
          applied: [], failed: ".",
          cause: "Failed to create \(name): \(String(cString: strerror(errno)))",
          stageID: manifest.id)
      }
      created = manifest.destination
      let fd = openat(parent.fd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else {
        throw StageApplyError(
          applied: [], failed: ".", cause: "the created destination could not be reopened",
          effect: .changed, createdRoot: created, stageID: manifest.id)
      }
      root = Descriptor(fd)
      try? log?.append("created \(ReturnDestination.identity(fd) ?? "?")")
    }
    let stageRoot = open(tree, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard stageRoot >= 0 else { throw HostError.posix("Failed to open stage", tree) }
    defer { close(stageRoot) }
    var applied: [String] = []
    for (index, change) in manifest.changes.enumerated() {
      do {
        try log?.append("intent \(index)")
        try apply(change, destination: root.fd, stage: stageRoot)
        try log?.append("done \(index)")
      } catch {
        throw StageApplyError(
          applied: applied, failed: change.path, cause: "\(error)",
          effect: Self.effect(of: change, root: root.fd), createdRoot: created,
          stageID: manifest.id)
      }
      applied.append(change.path)
    }
    return applied
  }

  /// What a failed change left behind: its old object, its new one, or
  /// something else.
  static func effect(of change: StageChange, root: Int32) -> StageApplyError.Effect {
    guard let now = try? StageBuilder.destinationObject(root: root, change.path, label: "") else {
      return .uncertain
    }
    if now == change.old { return .unchanged }
    switch (now, change.new) {
    case (.file(let size, let digest, _), .file(let wantSize, let wantDigest, _))
    where size == wantSize && digest == wantDigest:
      return .changed
    case (.directory, .directory): return .changed
    case (.symlink(let target), .symlink(let wanted)) where target == wanted: return .changed
    default: return .uncertain
    }
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
    func unchanged() throws {
      guard try StageBuilder.object(at: parent, name, path: change.path) == change.old else {
        throw HostError("the destination entry changed during apply")
      }
    }
    try unchanged()
    switch change.new {
    case .directory:
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
        // Only the documented permission bits; never owner, ACLs, flags or
        // extended attributes from the guest.
        guard fchmod(output, mode_t(mode) & 0o755) == 0 else {
          throw HostError.posix("Failed to set permissions on", temporary)
        }
        var times = [info.st_atimespec, info.st_mtimespec]
        futimens(output, &times)
      }
      // A host edit during the copy must not be overwritten.
      try unchanged()
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
      do { try unchanged() } catch {
        unlinkat(parent, temporary, 0)
        throw error
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

extension StageApplier {
  /// Opens the bound destination and applies, for callers that already
  /// hold the authorization (tests and internal paths).
  func apply() throws -> [String] { try apply(try destination.open()) }
}
