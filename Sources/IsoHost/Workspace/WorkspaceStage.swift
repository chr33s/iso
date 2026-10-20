import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

// Validated workspace return (security-hardening spec §5). Every return
// mode receives into a fresh host-owned incoming stage, validates it into a
// manifest, and installs only through `StageApplier`. The stage tree is
// guest-authored: every name, link target, mode and size read from it is
// untrusted, and no receiver ever writes the destination.

/// A staged object, as the guest left it.
package enum StageObject: Sendable, Equatable, Codable {
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
package enum DestinationObject: Sendable, Equatable, Codable {
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

package enum StageOperation: String, Sendable, Codable {
  case add
  case modify
  case typeChange = "type-change"
}

package struct StageChange: Sendable, Equatable, Codable {
  /// Relative, `/`-separated, validated UTF-8 without control characters.
  package let path: String
  package let operation: StageOperation
  package let new: StageObject
  package let old: DestinationObject
  /// Why applying this entry needs a named `--approve-sensitive` grant
  /// (RET-11); nil for an ordinary entry.
  package var sensitive: String? = nil

  /// Whether applying it replaces something the host already has.
  package var replaces: Bool { operation != .add }
}

/// Where a stage installs: an existing directory bound by its identity, or
/// a directory that must stay absent until an authorized apply creates it
/// under the bound parent.
package enum DestinationBinding: Sendable, Equatable, Codable {
  case existing(identity: String)
  case create(parentIdentity: String, name: String)
}

/// A standard gitfile (`gitdir: …`) the destination already has, observed
/// natively and rechecked before apply.
package struct GitfileObservation: Sendable, Equatable, Codable {
  package let path: String
  package let sha256: String
}

/// The return-policy version a manifest was validated under. Version 2 is
/// the structural contract plus RET-11 named grants for known
/// execution-sensitive paths; it is the only one this build produces or
/// accepts. A compatibility identifier, not a user-selectable mode.
package enum ReturnPolicyVersion: Int, Sendable, Codable {
  case sensitiveGrants = 2
}

package struct StageManifest: Sendable, Equatable, Codable {
  package static let currentVersion = 2

  package let version: Int
  package let id: String
  package let returnPolicy: ReturnPolicyVersion
  package let instance: String
  package let destination: String
  package let binding: DestinationBinding
  package let createdAt: String
  /// Received entries and regular-file bytes, including unchanged and
  /// excluded ones.
  package let stagedEntries: UInt64
  package let stagedBytes: UInt64
  /// Sorted by path, so every parent precedes its children.
  package let changes: [StageChange]
  /// Protected entries (raw `.git` administration) that were received but
  /// are never installed: a bounded sample and the full count.
  package let excluded: [String]
  package let excludedCount: UInt64
  package let gitfiles: [GitfileObservation]
  /// Reasons the stage cannot be applied. Empty for an applicable stage.
  package let issues: [String]
  /// The boot and policy this stage was built under, when a policy governs
  /// `workspace.pull.apply`. Absent in stages built without one.
  package var policy: StagePolicyBinding? = nil

  package var applicable: Bool { issues.isEmpty }
  package var sensitivePaths: [String] {
    changes.compactMap { $0.sensitive == nil ? nil : $0.path }
  }

  enum CodingKeys: String, CodingKey {
    case version, id, instance, destination, binding, policy, excluded, gitfiles, issues, changes
    case returnPolicy = "return_policy"
    case createdAt = "created_at"
    case stagedEntries = "staged_entries"
    case stagedBytes = "staged_bytes"
    case excludedCount = "excluded_count"
  }
}

/// A stage budget was exceeded; the stage is discarded.
package struct StageBudgetExceeded: Error, CustomStringConvertible {
  package let description: String
}

/// Watches an incoming tree while a transfer fills it, so a guest cannot
/// fill the host volume long before `StageBuilder` enforces the budgets.
/// Passed as a process `isCancelled` poll; measures at most twice a second,
/// by allocated bytes so sparse files count for what they cost on the host.
/// A sampling monitor: it can overshoot by what arrives between samples and
/// is not a hard disk quota. An inspection failure stops the transfer.
final class StageGrowthGuard: Sendable {
  private struct State: Sendable {
    var lastCheck = ContinuousClock.now - .seconds(1)
    var breach: String?
  }

  private let state = Mutex(State())
  private let tree: String
  private let limits: StageLimits

  init(tree: String, limits: StageLimits) {
    self.tree = tree
    self.limits = limits
  }

  /// Why the transfer was stopped, once it has been.
  var breachDescription: String? { state.withLock { $0.breach } }

  func shouldCancel() -> Bool {
    state.withLock { state in
      if state.breach != nil { return true }
      let now = ContinuousClock.now
      guard now - state.lastCheck >= .milliseconds(500) else { return false }
      state.lastCheck = now
      state.breach = measure()
      return state.breach != nil
    }
  }

  static let blockSlack: UInt64 = 4096

  private func measure() -> String? {
    guard let walker = FileManager.default.enumerator(atPath: tree) else {
      return "Failed to inspect the incoming stage while it was received"
    }
    var entries: UInt64 = 0
    var bytes: UInt64 = 0
    for case let relative as String in walker {
      entries += 1
      if entries > limits.maxFiles {
        return "Stage exceeds workspace.pull.max_files (\(limits.maxFiles) entries)"
      }
      var info = stat()
      guard lstat(tree + "/" + relative, &info) == 0 else {
        // A receiver renames its temporary files into place as it goes.
        if errno == ENOENT { continue }
        return "Failed to inspect the incoming stage while it was received"
      }
      if info.st_mode & S_IFMT == S_IFREG {
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

/// `<instance>/returns/`, owner-only: `selected.json` names the one
/// selected completed stage (`stages/<id>/{tree,manifest.json,lease}`);
/// a receive in progress lives in `incoming/<id>/{tree,lease}`; apply
/// attempts are recorded in `attempts/`. Only `tree/` is ever handed to a
/// receiver. The lock file sits beside the root, so removing the stage
/// state never removes it.
package struct StageLocation: Sendable {
  package let root: String
  /// The single-slot `stage/` directory of earlier builds: never applied,
  /// kept until discarded.
  let legacyRoot: String?

  package init(_ instance: Instance) {
    root = instance.directory + "/returns"
    legacyRoot = instance.directory + "/stage"
  }

  init(root: String) {
    self.root = root
    legacyRoot = nil
  }

  var stagesDirectory: String { root + "/stages" }
  var incomingDirectory: String { root + "/incoming" }
  var attemptsDirectory: String { root + "/attempts" }
  var selectedPointer: String { root + "/selected.json" }

  func stage(_ id: String) -> CompletedStage {
    CompletedStage(id: id, directory: stagesDirectory + "/" + id)
  }

  /// Whether anything is retained: a selected stage, an incoming receive,
  /// or a legacy stage.
  package var exists: Bool {
    var info = stat()
    if lstat(root, &info) == 0 {
      if (try? selectedID()) != nil { return true }
      if let entries = try? FileManager.default.contentsOfDirectory(atPath: incomingDirectory),
        !entries.isEmpty
      {
        return true
      }
      if let entries = try? FileManager.default.contentsOfDirectory(atPath: stagesDirectory),
        !entries.isEmpty
      {
        return true
      }
    }
    return legacyExists
  }

  var legacyExists: Bool {
    guard let legacyRoot else { return false }
    var info = stat()
    return lstat(legacyRoot, &info) == 0
  }

  /// Serializes receive, apply, discard and destroy of one instance's
  /// stages across iso processes.
  package func lock() throws(HostError) -> FileLock {
    try FileLock(path: (root as NSString).deletingLastPathComponent + "/.stage.lock")
  }

  /// Runs `body` under the stage lock.
  func locked<T>(_ body: () throws(HostError) -> T) throws(HostError) -> T {
    let lock = try lock()
    defer { lock.release() }
    return try body()
  }

  /// The owner-only root and its fixed subdirectories, each checked to be a
  /// real directory this user owns.
  func ensureLayout() throws(HostError) {
    for directory in [root, stagesDirectory, incomingDirectory, attemptsDirectory] {
      try ReturnState.ensurePrivateDirectory(directory)
    }
  }

  static let idLength = 16

  /// Stage IDs are generated lowercase hex; anything else never names a
  /// path.
  static func validID(_ id: String) -> Bool {
    id.utf8.count == idLength
      && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  struct Selected: Codable, Equatable {
    var schema = 1
    let id: String
  }

  /// The selected completed stage's ID, nil when there is none.
  package func selectedID() throws(HostError) -> String? {
    guard let bytes = try StateStore.readControlFile(selectedPointer) else { return nil }
    let selected = try StateStore.decode(Selected.self, bytes, path: selectedPointer)
    guard selected.schema == 1, Self.validID(selected.id) else {
      throw HostError("\(selectedPointer) does not name a valid stage")
    }
    return selected.id
  }

  func select(_ id: String) throws(HostError) {
    try StateStore.writeControlFile(Selected(id: id), to: selectedPointer)
  }

  func clearSelection() throws(HostError) {
    try StateStore.removeIfPresent(selectedPointer)
  }

  /// The selected stage with its manifest bounded-parsed and validated.
  package func loadSelected() throws(HostError) -> SelectedStage {
    guard let id = try selectedID() else {
      if legacyExists {
        throw HostError(
          "The retained stage was built by an earlier iso and cannot be applied; re-stage with `iso diff` (the old copy stays until `iso pull --discard`)"
        )
      }
      throw HostError("No staged pull. Create one with `iso diff` or `iso pull --review`.")
    }
    let stage = stage(id)
    let manifest = try stage.loadManifest()
    guard manifest.id == id else {
      throw HostError("The selected stage's manifest names another stage; re-stage")
    }
    return SelectedStage(stage: stage, manifest: manifest)
  }

  /// `loadSelected` under the stage lock.
  package func loadSelectedLocked() throws(HostError) -> SelectedStage {
    try locked { () throws(HostError) in try loadSelected() }
  }

  /// The pending receive, if any. Only one is ever kept per instance.
  func incomingAttempts() throws(HostError) -> [String] {
    let entries: [String]
    do {
      entries = try FileManager.default.contentsOfDirectory(atPath: incomingDirectory)
    } catch {
      var info = stat()
      if lstat(incomingDirectory, &info) != 0 && errno == ENOENT { return [] }
      throw HostError("Failed to list \(incomingDirectory)")
    }
    return entries.sorted()
  }

  /// Removes every incoming tree whose writers are provably gone; throws
  /// `ReturnError.busyWriter` while any writer may remain.
  func reclaimIncoming() throws {
    for name in try incomingAttempts() {
      let directory = incomingDirectory + "/" + name
      guard Self.validID(name) else {
        throw HostError("Unexpected entry \(neutralizeControls(directory)); remove it by hand")
      }
      switch try ReceiveLease.probe(
        directory + "/lease", treeExists: Self.entryExists(directory + "/tree"))
      {
      case .quiescent(let hold):
        try Self.removeTree(directory)
        _ = hold
      case .busy:
        throw ReturnError(
          .busyWriter, stageID: name,
          "A previous receive for this instance may still be writing \(neutralizeControls(directory)); wait for it to finish, then retry"
        )
      }
    }
  }

  /// Removes everything retained: every stage, incoming tree and attempt
  /// record, and a legacy stage. Refuses while a receiver may still write.
  package func remove() throws {
    var info = stat()
    if lstat(root, &info) == 0 {
      try reclaimIncoming()
      try Self.removeTree(root)
    } else if errno != ENOENT {
      throw HostError.posix("Failed to inspect", root)
    }
    if let legacyRoot { try Self.removeTree(legacyRoot) }
  }

  /// Discards the selected stage (and a legacy one); returns whether
  /// anything was discarded. A live receive is never deleted.
  func discard() throws -> Bool {
    let existed = exists
    try remove()
    return existed
  }

  /// Promotes a validated, quiescent incoming attempt to the selected
  /// stage, then removes the stage it replaces and that stage's attempt
  /// record.
  func promote(_ attempt: ReceiveAttempt, manifest: StageManifest) throws(HostError) {
    try saveManifest(manifest, at: attempt.directory + "/manifest.json")
    let previous = try selectedID()
    let target = stage(attempt.id).directory
    guard rename(attempt.directory, target) == 0 else {
      throw .posix("Failed to promote stage", attempt.directory)
    }
    try select(attempt.id)
    if let previous, previous != attempt.id {
      try Self.removeTree(stage(previous).directory)
      try ApplyAttemptRecord.remove(self, stageID: previous)
    }
  }

  static let maxManifest = 256 << 20

  func saveManifest(_ manifest: StageManifest, at path: String) throws(HostError) {
    try AtomicFile.write(
      try StateStore.encode(manifest, path: path), to: path, mode: .atMost(0o600))
  }

  static func entryExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  /// Removes `path` and everything below it. Guest-authored directory modes
  /// may deny the owner access, so each directory is opened up first.
  static func removeTree(_ path: String) throws(HostError) {
    var info = stat()
    guard lstat(path, &info) == 0 else {
      if errno == ENOENT { return }
      throw .posix("Failed to inspect", path)
    }
    grantOwnerAccess(path)
    do {
      try FileManager.default.removeItem(atPath: path)
    } catch {
      throw HostError("Failed to remove \(path): \(error.localizedDescription)")
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
}

/// One completed stage directory.
package struct CompletedStage: Sendable {
  package let id: String
  let directory: String

  package var tree: String { directory + "/tree" }
  var manifestPath: String { directory + "/manifest.json" }
  var leasePath: String { directory + "/lease" }

  /// Bounded-parses and validates the manifest; only a validated manifest
  /// reaches review or apply.
  func loadManifest() throws(HostError) -> StageManifest {
    let fd = open(manifestPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw .posix("Failed to open", manifestPath) }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid()
    else { throw HostError("\(manifestPath) is not a regular file this user owns") }
    let bytes = try StateStore.readBounded(
      fd, path: manifestPath, limit: StageLocation.maxManifest,
      tooLarge: "\(manifestPath) is too large")
    struct Version: Decodable { let version: Int }
    let version = try StateStore.decode(Version.self, bytes, path: manifestPath)
    guard version.version == StageManifest.currentVersion else {
      throw HostError(
        "Unsupported stage manifest version \(version.version); discard and re-stage")
    }
    let manifest = try StateStore.decode(StageManifest.self, bytes, path: manifestPath)
    try StageManifestValidator.validate(manifest)
    return manifest
  }
}

/// The selected stage and its validated manifest.
package struct SelectedStage: Sendable {
  package let stage: CompletedStage
  package let manifest: StageManifest
}

/// Cross-field checks a decoded manifest must pass before it is trusted:
/// Codable decoding and an empty `issues` array prove nothing on their own.
enum StageManifestValidator {
  static let maxChanges = 10_000_000
  static let maxPathBytes = 4096

  static func validate(_ manifest: StageManifest) throws(HostError) {
    func fail(_ reason: String) -> HostError {
      HostError("Stage manifest \(manifest.id) is invalid (\(reason)); discard and re-stage")
    }
    guard StageLocation.validID(manifest.id) else { throw fail("bad stage id") }
    guard manifest.destination.hasPrefix("/"), !manifest.destination.utf8.contains(0) else {
      throw fail("destination is not absolute")
    }
    guard manifest.changes.count <= maxChanges, manifest.issues.count <= StageBuilder.maxIssues + 1,
      manifest.excluded.count <= StageBuilder.maxExcludedSample,
      UInt64(manifest.excluded.count) <= manifest.excludedCount
    else { throw fail("too many entries") }
    if case .create(_, let name) = manifest.binding {
      guard StageBuilder.validName(Array(name.utf8)) == name, name != ".", name != ".." else {
        throw fail("bad destination name")
      }
    }
    var previous: String? = nil
    for change in manifest.changes {
      let path = change.path
      guard validPath(path) else { throw fail("bad path") }
      if let previous, !previous.utf8.lexicographicallyPrecedes(path.utf8) {
        throw fail("paths are duplicated or out of order")
      }
      previous = path
      guard !ProtectedPaths.isReserved(path) else { throw fail("reserved path") }
      let consistent =
        switch (change.operation, change.old, change.new) {
        case (.add, .absent, _): true
        case (.modify, .file, .file), (.modify, .symlink, .symlink): true
        case (.typeChange, .file, .symlink), (.typeChange, .symlink, .file): true
        default: false
        }
      guard consistent else { throw fail("operation does not match its objects") }
      if case .file(_, let digest, let mode) = change.new {
        guard validDigest(digest), mode & ~0o755 == 0 else { throw fail("bad file object") }
      }
      if case .symlink(let target) = change.new {
        guard StageBuilder.staysInside(link: path, target: target) else {
          throw fail("link escapes the workspace")
        }
      }
      guard change.sensitive == SensitivePaths.classify(path, new: change.new) else {
        throw fail("sensitive-path classification does not match")
      }
    }
    for observation in manifest.gitfiles {
      guard validPath(observation.path), validDigest(observation.sha256) else {
        throw fail("bad gitfile observation")
      }
    }
  }

  static func validPath(_ path: String) -> Bool {
    guard !path.isEmpty, path.utf8.count <= maxPathBytes, !path.hasPrefix("/") else { return false }
    for component in path.split(separator: "/", omittingEmptySubsequences: false) {
      guard !component.isEmpty, component != ".", component != "..",
        StageBuilder.validName(Array(component.utf8)) != nil
      else { return false }
    }
    return true
  }

  static func validDigest(_ digest: String) -> Bool {
    digest.utf8.count == 64
      && digest.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }
}

/// Raw Git administration (RET-05): `.git` at any component, any object
/// type, including the spellings APFS resolves to it.
enum ProtectedPaths {
  /// Code points HFS+/APFS ignore in names, which Git also treats as
  /// equivalent (`is_hfs_dotgit`).
  static let ignorable: Set<UInt32> = Set(
    [0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0xFEFF]
      + Array(0x206A...0x206F))

  /// A name folded the way a case-insensitive APFS volume compares it.
  static func folded(_ name: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in name.unicodeScalars where !ignorable.contains(scalar.value) {
      scalars.append(scalar)
    }
    return String(scalars).precomposedStringWithCanonicalMapping.lowercased()
  }

  static func isReservedName(_ name: String) -> Bool { folded(name) == ".git" }

  static func isReserved(_ path: String) -> Bool {
    path.split(separator: "/").contains { isReservedName(String($0)) }
  }
}

/// Known execution-sensitive paths (RET-11), versioned with the return
/// policy. Intentionally incomplete: an existing host tool can still run an
/// ordinarily named file, and approved source stays untrusted.
enum SensitivePaths {
  static func classify(_ path: String) -> String? {
    let components = path.split(separator: "/").map { ProtectedPaths.folded(String($0)) }
    if components.contains(".husky") { return "git hook runs on the host" }
    if components.last == ".envrc" { return "direnv runs .envrc on the host" }
    if components.suffix(2) == [".vscode", "tasks.json"] {
      return "editor task can run host commands"
    }
    return nil
  }

  /// A link is also sensitive when its target resolves, lexically from its
  /// directory, to a sensitive path.
  static func classify(_ path: String, new: StageObject) -> String? {
    if let reason = classify(path) { return reason }
    guard case .symlink(let target) = new,
      let resolved = StageBuilder.resolve(link: path, target: target)
    else { return nil }
    return classify(resolved).map { "link to a path where \($0)" }
  }
}

/// Builds a manifest by comparing a stage tree with the bound destination.
struct StageBuilder {
  let tree: String
  let destination: StageDestinationView
  let limits: StageLimits

  private(set) var entries: UInt64 = 0
  private(set) var bytes: UInt64 = 0
  private(set) var changes: [StageChange] = []
  private(set) var issues: [String] = []
  private(set) var excluded: [String] = []
  private(set) var excludedCount: UInt64 = 0
  /// Staged objects by path, for final-tree link checks.
  private(set) var staged: [String: StageObject] = [:]
  private var stagedFolded: Set<String> = []
  /// Staged links, checked for chains once the whole tree is known.
  private(set) var links: [(path: String, target: String)] = []

  static let maxIssues = 50
  static let maxExcludedSample = 50

  init(tree: String, destination: StageDestinationView, limits: StageLimits) {
    self.tree = tree
    self.destination = destination
    self.limits = limits
  }

  /// A builder against an existing destination directory path (tests).
  init(tree: String, destination path: String, limits: StageLimits) throws {
    self.init(tree: tree, destination: try StageDestinationView(existing: path), limits: limits)
  }

  mutating func build(
    id: String, instance: String, policy: StagePolicyBinding? = nil, now: Date = Date()
  ) throws -> StageManifest {
    let root = open(tree, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard root >= 0 else { throw HostError.posix("Failed to open stage", tree) }
    defer { close(root) }
    try walk(root, prefix: "")
    try checkLinks()
    let gitfiles = try observeGitAdministration()
    changes.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    return StageManifest(
      version: StageManifest.currentVersion, id: id, returnPolicy: .sensitiveGrants,
      instance: instance, destination: destination.path, binding: destination.binding,
      createdAt: ISO8601DateFormatter().string(from: now), stagedEntries: entries,
      stagedBytes: bytes, changes: changes, excluded: excluded, excludedCount: excludedCount,
      gitfiles: gitfiles, issues: issues, policy: policy)
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

  private mutating func count(_ path: String) throws {
    entries += 1
    guard entries <= limits.maxFiles else {
      throw StageBudgetExceeded(
        description: "Stage exceeds workspace.pull.max_files (\(limits.maxFiles) entries)")
    }
  }

  private mutating func countBytes(_ size: UInt64, _ path: String) throws {
    guard size <= limits.maxFileBytes.bytes else {
      throw StageBudgetExceeded(
        description:
          "\(path) (\(size) bytes) exceeds workspace.pull.max_file_bytes (\(limits.maxFileBytes))")
    }
    bytes += size
    guard bytes <= limits.maxBytes.bytes else {
      throw StageBudgetExceeded(
        description: "Stage exceeds workspace.pull.max_bytes (\(limits.maxBytes))")
    }
  }

  private mutating func walk(_ directory: Int32, prefix: String, depth: Int = 0) throws {
    var siblings: [String: String] = [:]
    for name in try Self.names(directory, path: prefix.isEmpty ? tree : tree + "/" + prefix) {
      let shown = String(decoding: name.map { $0 < 0x20 || $0 == 0x7F ? 0x3F : $0 }, as: UTF8.self)
      guard let text = Self.validName(name) else {
        try count(prefix + shown)
        issue("\(prefix)\(shown): unsupported file name (not UTF-8, or has control characters)")
        continue
      }
      let path = prefix + text
      try count(path)
      var info = stat()
      guard fstatat(directory, text, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw HostError.posix("Failed to inspect staged", path)
      }
      if ProtectedPaths.isReservedName(text) {
        try exclude(directory, text, path: path, info: info, depth: depth)
        continue
      }
      let key = destination.fold(text)
      if let other = siblings[key] {
        issue("\(path): collides with \(prefix)\(other) on the destination volume")
        continue
      }
      siblings[key] = text
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
        let size = UInt64(info.st_size)
        try countBytes(size, path)
        guard info.st_nlink == 1 else {
          issue("\(path): hard links are not supported")
          continue
        }
        // Only permission bits the installer grants: no setuid, setgid,
        // sticky or group/other write from the guest.
        let mode = UInt16(info.st_mode & 0o755)
        if info.st_mode & 0o400 == 0 {
          fchmodat(directory, text, (info.st_mode & 0o7777) | 0o400, 0)
        }
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

  /// A protected entry is counted against the budgets but never installed
  /// or compared; a bounded sample is shown at review.
  private mutating func exclude(
    _ directory: Int32, _ name: String, path: String, info: stat, depth: Int
  ) throws {
    excludedCount += 1
    if excluded.count < Self.maxExcludedSample { excluded.append(path) }
    switch info.st_mode & S_IFMT {
    case S_IFREG: try countBytes(UInt64(info.st_size), path)
    case S_IFDIR:
      fchmodat(directory, name, (info.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW)
      guard depth < Self.maxDepth else { return }
      let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard child >= 0 else { throw HostError.posix("Failed to open staged", path) }
      defer { close(child) }
      try account(child, path: path, depth: depth + 1)
    default: break
    }
  }

  private mutating func account(_ directory: Int32, path: String, depth: Int) throws {
    for name in try Self.names(directory, path: tree + "/" + path) {
      let text = String(decoding: name, as: UTF8.self)
      try count(path + "/" + text)
      var info = stat()
      guard
        fstatat(directory, String(decoding: name, as: UTF8.self), &info, AT_SYMLINK_NOFOLLOW) == 0
      else { continue }
      switch info.st_mode & S_IFMT {
      case S_IFREG: try countBytes(UInt64(info.st_size), path + "/" + text)
      case S_IFDIR where depth < Self.maxDepth:
        fchmodat(directory, text, (info.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW)
        let child = openat(directory, text, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard child >= 0 else { continue }
        defer { close(child) }
        try account(child, path: path + "/" + text, depth: depth + 1)
      default: break
      }
    }
  }

  private mutating func record(_ path: String, _ new: StageObject) throws {
    staged[path] = new
    stagedFolded.insert(destination.foldPath(path))
    let old = try destination.object(path)
    if old != .absent, let spelling = try destination.spellingMismatch(path) {
      issue("\(path): differs only in case or normalization from the host's \(spelling)")
      return
    }
    let operation: StageOperation
    switch (old, new) {
    case (.absent, _): operation = .add
    case (.directory, .directory): return
    // Staged modes carry only the bits the installer grants (0o755), so a
    // host file's group/other write bits are not a change.
    case (.file(_, let a, let m), .file(_, let b, let n)) where a == b && m & 0o755 == n: return
    case (.symlink(let a), .symlink(let b)) where a == b: return
    case (.file, .file), (.symlink, .symlink): operation = .modify
    case (.directory, _):
      issue("\(path): would replace a host directory with a \(new.kindName); resolve it by hand")
      return
    case (.other, _):
      issue("\(path): the host has a special file here")
      return
    case (_, .directory):
      issue("\(path): would replace a host \(old.kindName) with a directory; resolve it by hand")
      return
    default: operation = .typeChange
    }
    changes.append(
      StageChange(
        path: path, operation: operation, new: new, old: old,
        sensitive: SensitivePaths.classify(path, new: new)))
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

  /// Every component of every link target, the final one included, is
  /// resolved against the planned final tree (staged objects over the
  /// preserved destination). The kernel resolves `s/..` through `s`, so a
  /// component that is itself a link could escape lexical containment; a
  /// final component that is a link makes a chain. Both, and targets into
  /// protected administration, make the stage inapplicable.
  mutating func checkLinks() throws {
    for (path, target) in links {
      var stack = path.split(separator: "/").map(String.init)
      _ = stack.popLast()
      for component in target.split(separator: "/").map(String.init) {
        if component == "." { continue }
        if component == ".." {
          // Unreachable after `staysInside`, but never trap on guest input.
          guard stack.popLast() != nil else {
            issue("\(path): symlink points outside the workspace")
            break
          }
          continue
        }
        if ProtectedPaths.isReservedName(component) {
          issue("\(path): symlink points into git administration")
          break
        }
        stack.append(component)
        let through = stack.joined(separator: "/")
        if try finalObjectIsLink(through) {
          issue("\(path): symlink target passes through another symlink (\(through))")
          break
        }
      }
    }
  }

  /// Whether `path` is a link in the planned final tree.
  private func finalObjectIsLink(_ path: String) throws -> Bool {
    if let object = staged[path] {
      if case .symlink = object { return true }
      return false
    }
    if stagedFolded.contains(destination.foldPath(path)) { return linkFolded(path) }
    if case .symlink = try destination.object(path) { return true }
    return false
  }

  private func linkFolded(_ path: String) -> Bool {
    let key = destination.foldPath(path)
    return staged.contains { destination.foldPath($0.key) == key && $0.value.kindName == "symlink" }
  }

  /// The lexical resolution of `target` from `link`'s directory, nil when it
  /// climbs above the root.
  static func resolve(link path: String, target: String) -> String? {
    var stack = path.split(separator: "/").map(String.init)
    _ = stack.popLast()
    for component in target.split(separator: "/").map(String.init) {
      switch component {
      case ".": continue
      case "..": guard stack.popLast() != nil else { return nil }
      default: stack.append(component)
      }
    }
    return stack.isEmpty ? nil : stack.joined(separator: "/")
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

  /// The destination's existing `.git` entries in its root and every
  /// existing directory the plan touches: directories are protected as
  /// they are; a standard gitfile pointing outside the returned tree, or
  /// beneath a protected `.git`, is observed for revalidation; anything
  /// else makes the destination inapplicable in this release.
  mutating func observeGitAdministration() throws -> [GitfileObservation] {
    var directories: Set<String> = [""]
    for change in changes {
      var ancestor = ""
      for component in change.path.split(separator: "/").dropLast() {
        ancestor += ancestor.isEmpty ? String(component) : "/" + component
        directories.insert(ancestor)
      }
    }
    var observations: [GitfileObservation] = []
    for directory in directories.sorted() {
      guard case .directory = try destination.object(directory.isEmpty ? "." : directory) else {
        continue
      }
      let path = directory.isEmpty ? ".git" : directory + "/.git"
      for entry in try destination.reservedEntries(in: directory) {
        let entryPath = directory.isEmpty ? entry : directory + "/" + entry
        switch try destination.object(entryPath) {
        case .absent, .directory: continue
        case .symlink:
          issue("\(entryPath): the destination has a .git symlink, which is not supported")
        case .other:
          issue("\(entryPath): the destination has a special file named .git")
        case .file:
          guard entry == ".git" else {
            issue("\(entryPath): an alias of .git in the destination is not supported")
            continue
          }
          let (bytes, digest) = try destination.read(path, limit: 4096)
          guard let bytes, let target = Gitfile.parse(bytes) else {
            issue("\(path): unsupported or unreadable gitfile")
            continue
          }
          if Gitfile.administersInside(target, gitfile: path, destination: destination.path) {
            issue(
              "\(path): its git directory is inside the destination outside .git, which is not supported"
            )
            continue
          }
          observations.append(GitfileObservation(path: path, sha256: digest))
        }
      }
    }
    return observations
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
    return hex(hasher.finalize())
  }

  static func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
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

  /// The destination object at `path` below the directory `root`, resolved
  /// component by component without following links. A parent that is not
  /// a directory means the path does not exist yet (the parent is itself a
  /// change).
  static func destinationObject(root: Int32, _ path: String, label: String) throws
    -> DestinationObject
  {
    var components = path.split(separator: "/").map(String.init)
    guard let last = components.popLast() else { return .directory }
    var directory = dup(root)
    guard directory >= 0 else { throw HostError.posix("Failed to open", label) }
    defer { close(directory) }
    for component in components {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard next >= 0 else {
        if [ENOENT, ENOTDIR, ELOOP].contains(errno) { return .absent }
        throw HostError.posix("Failed to open", label + "/" + path)
      }
      close(directory)
      directory = next
    }
    return try object(at: directory, last, path: label + "/" + path)
  }

  static func object(at directory: Int32, _ name: String, path: String) throws
    -> DestinationObject
  {
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT || errno == ENOTDIR { return .absent }
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

/// The supported gitfile form: one `gitdir: PATH` line, read natively
/// without Git or configuration discovery.
enum Gitfile {
  static func parse(_ bytes: [UInt8]) -> String? {
    guard !bytes.contains(0), var text = String(validating: bytes, as: UTF8.self) else {
      return nil
    }
    if text.hasSuffix("\n") { text.removeLast() }
    if text.hasSuffix("\r") { text.removeLast() }
    guard text.hasPrefix("gitdir: "), !text.contains("\n"), !text.contains("\r") else { return nil }
    let target = String(text.dropFirst("gitdir: ".count))
    guard !target.isEmpty, !target.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
      return nil
    }
    return target
  }

  /// Whether `target` (from the gitfile at the relative `gitfile`) names a
  /// git directory inside the destination but outside any `.git` subtree:
  /// a custom in-destination administration target.
  static func administersInside(_ target: String, gitfile: String, destination: String) -> Bool {
    var relative: [String]
    if target.hasPrefix("/") {
      let resolved = canonicalPath(target) ?? (target as NSString).standardizingPath
      guard resolved == destination || resolved.hasPrefix(destination + "/") else { return false }
      relative = resolved.dropFirst(destination.count).split(separator: "/").map(String.init)
    } else {
      var stack = gitfile.split(separator: "/").map(String.init)
      _ = stack.popLast()
      for component in target.split(separator: "/").map(String.init) {
        switch component {
        case ".": continue
        case "..":
          // Climbing above the root leaves the returned tree.
          guard stack.popLast() != nil else { return false }
        default: stack.append(component)
        }
      }
      relative = stack
    }
    return !relative.dropLast().contains(where: ProtectedPaths.isReservedName)
      && !(relative.last.map(ProtectedPaths.isReservedName) ?? false)
  }
}
