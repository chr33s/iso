import Foundation
import IsoCore
import Synchronization

// Destination authority, receive leases and apply-attempt records for the
// validated workspace return (security-hardening spec RET-02, RET-03,
// RET-08). Every return mode shares these.

/// A refused or incomplete return, with the stage it concerns. The CLI
/// exits nonzero on every kind, including a direct pull held for authority.
package struct ReturnError: Error, CustomStringConvertible, Equatable {
  package enum Kind: String, Sendable, Equatable {
    /// The destination's Git layout or volume semantics are unsupported.
    case unsupportedLayout = "unsupported_layout"
    /// The plan has structural issues (links, metadata, objects).
    case blockedMetadata = "blocked_metadata"
    /// The destination or stage changed since review.
    case drift
    /// Replacements need `--apply --stage-id` or `--force`.
    case missingOverwriteAuthority = "missing_overwrite_authority"
    /// Sensitive paths need named `--approve-sensitive` grants.
    case missingSensitiveGrant = "missing_sensitive_grant"
    /// A receiver may still be writing.
    case busyWriter = "busy_writer"
    /// The destination overlaps iso control state.
    case overlap
    /// The stage's single apply attempt was already used.
    case consumed
    /// No such stage, or not the selected one.
    case wrongStage = "wrong_stage"
  }

  package let kind: Kind
  package let stageID: String?
  package let message: String

  package init(_ kind: Kind, stageID: String?, _ message: String) {
    self.kind = kind
    self.stageID = stageID
    self.message = message
  }

  package var description: String { message }
}

/// Owner-only directories for return control state: created one level at
/// a time, never through a symlink, and checked to be this user's.
enum ReturnState {
  static func ensurePrivateDirectory(_ path: String) throws(HostError) {
    if mkdir(path, 0o700) != 0 && errno != EEXIST { throw .posix("Failed to create", path) }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid()
    else { throw HostError("\(path) is not a directory this user owns") }
    if info.st_mode & 0o777 != 0o700 {
      guard chmod(path, 0o700) == 0 else { throw .posix("Failed to restrict", path) }
    }
  }
}

/// An owned open descriptor, closed when the last reference goes.
final class Descriptor: Sendable {
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }
  deinit { close(fd) }
}

/// The receive lease (RET-03): an exclusive `flock` on a file outside the
/// receive tree, whose descriptor every local writer inherits. The lock
/// lives as long as any process holding that open file, so it outlasts a
/// killed CLI; the tree is quiescent only once a fresh descriptor can take
/// it.
enum ReceiveLease {
  enum Probe {
    /// No writer holds the lease; the returned hold keeps it that way.
    case quiescent(Descriptor?)
    case busy
  }

  /// Creates and locks a new lease; the descriptor is close-on-exec until a
  /// spawn explicitly inherits it.
  static func create(_ path: String) throws(HostError) -> Int32 {
    let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw .posix("Failed to create", path) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd)
      throw .posix("Failed to lock", path)
    }
    return fd
  }

  /// Whether a writer may still hold `path`. A missing lease is quiescent
  /// only when no tree was created after it would have been (the lease is
  /// always created first).
  static func probe(_ path: String, treeExists: Bool) throws(HostError) -> Probe {
    let fd = open(path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else {
      if errno == ENOENT { return treeExists ? .busy : .quiescent(nil) }
      throw .posix("Failed to open", path)
    }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
      close(fd)
      throw HostError("\(path) is not a lease file this user owns")
    }
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      if code == EINTR { continue }
      close(fd)
      if code == EWOULDBLOCK { return .busy }
      throw .posix("Failed to lock", path, code)
    }
    return .quiescent(Descriptor(fd))
  }

  /// Polls until the lease is free, at most `timeout`.
  static func await(_ path: String, timeout: Duration) throws(HostError) -> Descriptor? {
    let deadline = ContinuousClock.now + timeout
    while true {
      switch try probe(path, treeExists: true) {
      case .quiescent(let hold): return hold
      case .busy:
        guard ContinuousClock.now < deadline else { return nil }
        usleep(50_000)
      }
    }
  }
}

/// One receive into `incoming/<id>/tree`, under the stage lock. Created
/// lease first, then the tree; nothing else is written in the attempt
/// directory until it is validated.
final class ReceiveAttempt {
  let id: String
  let directory: String
  private var lease: Int32

  var tree: String { directory + "/tree" }
  var leasePath: String { directory + "/lease" }
  /// The lease descriptor every writer must inherit.
  var writerDescriptor: Int32 { lease }

  /// Reclaims a provably finished earlier attempt (refusing while one may
  /// still write: at most one incoming tree is kept), then starts a fresh
  /// one with an unpredictable ID.
  init(_ location: StageLocation) throws {
    try location.ensureLayout()
    try location.reclaimIncoming()
    id = randomHex(StageLocation.idLength / 2)
    directory = location.incomingDirectory + "/" + id
    guard mkdir(directory, 0o700) == 0 else { throw HostError.posix("Failed to create", directory) }
    lease = try ReceiveLease.create(directory + "/lease")
    guard mkdir(directory + "/tree", 0o700) == 0 else {
      throw HostError.posix("Failed to create", directory + "/tree")
    }
  }

  deinit { if lease >= 0 { close(lease) } }

  /// Drops this process's own hold, then waits until no writer holds the
  /// lease. Nil while one may still write.
  func awaitQuiescence(timeout: Duration = .seconds(10)) throws(HostError) -> Descriptor? {
    if lease >= 0 {
      close(lease)
      lease = -1
    }
    return try ReceiveLease.await(leasePath, timeout: timeout)
  }

  /// The attempt directory must still hold exactly what iso created: a
  /// receiver write outside its tree is caught here, before inventory.
  func checkLayout() throws {
    let entries = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
    guard entries == ["lease", "tree"] else {
      throw HostError(
        "The incoming stage \(id) holds unexpected entries outside its tree; it was not accepted")
    }
    var info = stat()
    guard lstat(tree, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
      throw HostError("The incoming stage \(id) tree was replaced; it was not accepted")
    }
  }

  /// Removes the attempt if no writer can remain; otherwise leaves it for a
  /// later reclaim. Never deletes a tree a writer may still use.
  func abandon() {
    guard let hold = try? awaitQuiescence(timeout: .seconds(2)) else { return }
    _ = hold
    try? StageLocation.removeTree(directory)
  }
}

/// A destination checked against the control roots and bound by identity
/// (RET-02). Never constructed from guest data.
package struct ReturnDestination: Sendable, Equatable {
  /// Canonical and absolute.
  package let path: String
  package let binding: DestinationBinding

  /// Resolves `requested` once (deliberate host symlinks are followed
  /// here, and only here), then binds it: an existing directory by
  /// identity, or an absent final component below an existing parent.
  /// Refuses a destination inside git administration or overlapping any of
  /// `controlRoots`, in either direction; `--force` cannot override this.
  package static func resolve(_ requested: String, controlRoots: [String]) throws
    -> ReturnDestination
  {
    let absolute =
      requested.hasPrefix("/")
      ? requested : FileManager.default.currentDirectoryPath + "/" + requested
    let standardized = (absolute as NSString).standardizingPath
    let destination: ReturnDestination
    if let canonical = canonicalPath(standardized) {
      let fd = Darwin.open(canonical, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard fd >= 0 else { throw HostError.posix("Failed to open destination", canonical) }
      defer { close(fd) }
      guard let identity = Self.identity(fd) else {
        throw HostError("\(canonical) is not a directory")
      }
      destination = ReturnDestination(path: canonical, binding: .existing(identity: identity))
    } else {
      let parent = (standardized as NSString).deletingLastPathComponent
      let name = (standardized as NSString).lastPathComponent
      guard let canonicalParent = canonicalPath(parent) else {
        throw HostError(
          "The destination's parent \(neutralizeControls(parent)) does not exist; create it first")
      }
      guard StageBuilder.validName(Array(name.utf8)) == name, name != ".", name != ".." else {
        throw HostError("Unsupported destination name \(neutralizeControls(name))")
      }
      let fd = Darwin.open(canonicalParent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard fd >= 0, let identity = Self.identity(fd) else {
        if fd >= 0 { close(fd) }
        throw HostError.posix("Failed to open", canonicalParent)
      }
      close(fd)
      destination = ReturnDestination(
        path: (canonicalParent == "/" ? "" : canonicalParent) + "/" + name,
        binding: .create(parentIdentity: identity, name: name))
    }
    if destination.path.split(separator: "/").contains(where: {
      ProtectedPaths.isReservedName(String($0))
    }) {
      throw ReturnError(
        .unsupportedLayout, stageID: nil,
        "The destination \(neutralizeControls(destination.path)) is inside git administration")
    }
    try destination.checkDisjoint(from: controlRoots)
    return destination
  }

  /// No control root may be the destination, an ancestor of it, or below
  /// it. Compares directory identities up each ancestry, not strings.
  func checkDisjoint(from controlRoots: [String]) throws {
    let anchor = try open()
    let anchorFD: Int32
    switch anchor {
    case .existing(let root): anchorFD = root.fd
    case .absent(let parent, _): anchorFD = parent.fd
    }
    let ancestry = Self.ancestry(anchorFD)
    let ownIdentity: String? = if case .existing(let identity) = binding { identity } else { nil }
    for root in controlRoots {
      let fd = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      guard fd >= 0 else { continue }
      defer { close(fd) }
      guard let identity = Self.identity(fd) else { continue }
      let below = ownIdentity.map { Self.ancestry(fd).contains($0) } ?? false
      if ancestry.contains(identity) || below {
        throw ReturnError(
          .overlap, stageID: nil,
          "The destination \(neutralizeControls(path)) overlaps iso control state (\(neutralizeControls(root))); return into a disjoint workspace or export directory"
        )
      }
    }
  }

  /// Opens the bound destination by walking its canonical components
  /// without following links, and checks the bound identity. Any swapped
  /// component is drift.
  func open() throws -> VerifiedDestination {
    var components = path.split(separator: "/").map(String.init)
    let last: String?
    if case .create(_, let name) = binding {
      guard components.popLast() == name else {
        throw ReturnError(.drift, stageID: nil, "The destination binding does not match its path")
      }
      last = name
    } else {
      last = nil
    }
    var directory = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw HostError.posix("Failed to open", "/") }
    for component in components {
      let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      close(directory)
      guard next >= 0 else {
        throw ReturnError(
          .drift, stageID: nil,
          "The destination \(neutralizeControls(path)) changed since it was bound (\(neutralizeControls(component)))"
        )
      }
      directory = next
    }
    let handle = Descriptor(directory)
    switch binding {
    case .existing(let identity):
      guard Self.identity(handle.fd) == identity else {
        throw ReturnError(
          .drift, stageID: nil,
          "The destination \(neutralizeControls(path)) was replaced since review")
      }
      return .existing(handle)
    case .create(let parentIdentity, _):
      guard Self.identity(handle.fd) == parentIdentity, let last else {
        throw ReturnError(
          .drift, stageID: nil,
          "The destination's parent was replaced since review; re-stage")
      }
      var info = stat()
      guard fstatat(handle.fd, last, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
        throw ReturnError(
          .drift, stageID: nil,
          "\(neutralizeControls(path)) appeared since review; re-stage to compare against it")
      }
      return .absent(parent: handle, name: last)
    }
  }

  /// `device:inode` of an open directory.
  static func identity(_ fd: Int32) -> String? {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    return "\(info.st_dev):\(info.st_ino)"
  }

  /// Identities from `fd` up to the filesystem root, inclusive.
  static func ancestry(_ fd: Int32) -> Set<String> {
    var found = Set<String>()
    var current = dup(fd)
    while current >= 0, let identity = identity(current), found.insert(identity).inserted {
      let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
      close(current)
      current = parent
    }
    if current >= 0 { close(current) }
    return found
  }
}

/// A destination opened for one operation.
enum VerifiedDestination {
  case existing(Descriptor)
  /// Must still be absent; an authorized apply creates it.
  case absent(parent: Descriptor, name: String)
}

/// The destination as review and the builder see it: descriptor-relative,
/// never following a link, and empty while it does not exist yet.
struct StageDestinationView {
  let path: String
  let binding: DestinationBinding
  private let root: Descriptor?
  let caseSensitive: Bool

  init(_ destination: ReturnDestination, _ verified: VerifiedDestination) {
    path = destination.path
    binding = destination.binding
    switch verified {
    case .existing(let root):
      self.root = root
      caseSensitive = fpathconf(root.fd, _PC_CASE_SENSITIVE) == 1
    case .absent(let parent, _):
      root = nil
      caseSensitive = fpathconf(parent.fd, _PC_CASE_SENSITIVE) == 1
    }
  }

  /// An existing directory, bound as it is now (tests and fixtures).
  init(existing path: String) throws {
    let canonical = canonicalPath(path) ?? path
    let destination = try ReturnDestination.resolve(canonical, controlRoots: [])
    self.init(destination, try destination.open())
  }

  /// A name as the destination volume compares it: always normalization-
  /// insensitive on APFS, and case-insensitive unless the volume says not.
  func fold(_ name: String) -> String {
    caseSensitive
      ? name.precomposedStringWithCanonicalMapping : ProtectedPaths.folded(name)
  }

  func foldPath(_ path: String) -> String {
    path.split(separator: "/").map { fold(String($0)) }.joined(separator: "/")
  }

  func object(_ path: String) throws -> DestinationObject {
    guard let root else { return path == "." ? .absent : .absent }
    if path == "." { return .directory }
    return try StageBuilder.destinationObject(root: root.fd, path, label: self.path)
  }

  /// Opens the directory `relative` (empty: the root) without following
  /// links; nil when it does not exist as a directory.
  func openDirectory(_ relative: String) -> Descriptor? {
    guard let root else { return nil }
    var directory = dup(root.fd)
    for component in relative.split(separator: "/") {
      let next = openat(
        directory, String(component), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      close(directory)
      guard next >= 0 else { return nil }
      directory = next
    }
    return directory >= 0 ? Descriptor(directory) : nil
  }

  /// The host's own spelling of `path`'s last component when it differs
  /// from the staged one but names the same entry on this volume.
  func spellingMismatch(_ path: String) throws -> String? {
    var components = path.split(separator: "/").map(String.init)
    guard let name = components.popLast(),
      let parent = openDirectory(components.joined(separator: "/"))
    else { return nil }
    let names = try StageBuilder.names(parent.fd, path: self.path)
    if names.contains(Array(name.utf8)) { return nil }
    let key = fold(name)
    for raw in names {
      let other = String(decoding: raw, as: UTF8.self)
      if fold(other) == key { return neutralizeControls(other) }
    }
    return nil
  }

  /// Entries of `directory` that APFS or Git would treat as `.git`.
  func reservedEntries(in directory: String) throws -> [String] {
    guard let handle = openDirectory(directory) else { return [] }
    return try StageBuilder.names(handle.fd, path: self.path).compactMap {
      guard let name = String(validating: $0, as: UTF8.self), ProtectedPaths.isReservedName(name)
      else { return nil }
      return name
    }
  }

  /// At most `limit` bytes of the regular file `relative` and the SHA-256
  /// of its whole content; nil bytes when larger or not a regular file.
  func read(_ relative: String, limit: Int) throws -> (bytes: [UInt8]?, sha256: String) {
    var components = relative.split(separator: "/").map(String.init)
    guard let name = components.popLast(),
      let parent = openDirectory(components.joined(separator: "/"))
    else { return (nil, "") }
    let fd = openat(parent.fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return (nil, "") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return (nil, "") }
    let digest = try StageBuilder.sha256(fd: fd, path: self.path + "/" + relative)
    guard info.st_size <= limit, lseek(fd, 0, SEEK_SET) == 0 else { return (nil, digest) }
    let bytes = try StateStore.readBounded(
      fd, path: self.path + "/" + relative, limit: limit, tooLarge: "\(relative) grew while read")
    return (bytes.count <= limit ? bytes : nil, digest)
  }
}

/// The per-user lock every cooperating iso apply takes, so applies into
/// nested or overlapping destinations, across instances and data roots,
/// never interleave. Applies run one at a time per user.
enum ReturnApplyLock {
  static func acquire() throws(HostError) -> FileLock {
    guard let entry = getpwuid(geteuid()),
      let home = String(validatingCString: entry.pointee.pw_dir)
    else { throw HostError("Failed to find this user's home directory for the apply lock") }
    let base = home + "/.iso"
    if mkdir(base, 0o700) != 0 && errno != EEXIST { throw .posix("Failed to create", base) }
    try ReturnState.ensurePrivateDirectory(base + "/locks")
    return try FileLock(path: base + "/locks/return-apply.lock")
  }
}

/// The durable record of one apply attempt (RET-08), created exclusively
/// before the first destination mutation: its existence consumes the
/// stage's authorization, and its log lets a later run classify effects.
/// It records what happened, never authority that could be replayed.
struct ApplyAttemptRecord: Codable, Equatable {
  var schema = 1
  let stageID: String
  let attemptID: String
  let planDigest: String
  let destination: String
  let binding: DestinationBinding
  /// Authority this attempt carried: replacements, and the exact named
  /// sensitive paths.
  let replace: Bool
  let sensitive: [String]
  /// The governed-policy receipt consumed for it, if any.
  let receipt: String?
  let beganAt: String

  enum CodingKeys: String, CodingKey {
    case schema, destination, binding, replace, sensitive, receipt
    case stageID = "stage_id"
    case attemptID = "attempt_id"
    case planDigest = "plan_digest"
    case beganAt = "began_at"
  }

  static func path(_ location: StageLocation, stageID: String) -> String {
    location.attemptsDirectory + "/\(stageID).json"
  }

  static func logPath(_ location: StageLocation, stageID: String) -> String {
    location.attemptsDirectory + "/\(stageID).log"
  }

  /// Creates the record; refuses when the stage was already attempted.
  func begin(_ location: StageLocation) throws -> ApplyProgressLog {
    try location.ensureLayout()
    let path = Self.path(location, stageID: stageID)
    var info = stat()
    if lstat(path, &info) == 0 {
      throw ReturnError(
        .consumed, stageID: stageID,
        "Stage \(stageID) was already applied once (an attempt began); re-stage with `iso diff` to review what remains"
      )
    }
    try AtomicFile.createExclusive(try StateStore.encode(self, path: path), at: path, mode: 0o600)
    return try ApplyProgressLog(Self.logPath(location, stageID: stageID))
  }

  static func load(_ location: StageLocation, stageID: String) throws(HostError)
    -> ApplyAttemptRecord?
  {
    let path = path(location, stageID: stageID)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    return try StateStore.decode(ApplyAttemptRecord.self, bytes, path: path)
  }

  static func remove(_ location: StageLocation, stageID: String) throws(HostError) {
    try StateStore.removeIfPresent(path(location, stageID: stageID))
    try StateStore.removeIfPresent(logPath(location, stageID: stageID))
  }

  /// What the log says happened: the indexes started and finished, whether
  /// the root was created, and the recorded outcome.
  static func progress(_ location: StageLocation, stageID: String) -> ApplyProgress {
    var progress = ApplyProgress()
    guard let bytes = try? StateStore.readControlFile(logPath(location, stageID: stageID)) else {
      return progress
    }
    for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
      switch (parts.first, parts.count > 1 ? Int(parts[1]) : nil) {
      case ("intent", let index?): progress.started.insert(index)
      case ("done", let index?): progress.finished.insert(index)
      case ("created", _): progress.createdRoot = true
      case ("outcome", _): progress.outcome = parts.count > 1 ? parts[1] : nil
      default: continue
      }
    }
    return progress
  }
}

struct ApplyProgress: Equatable {
  var started: Set<Int> = []
  var finished: Set<Int> = []
  var createdRoot = false
  var outcome: String?
}

/// Append-only progress for one attempt: `intent N` before change N is
/// written, `done N` after, `created` after a safe-create, and a final
/// `outcome`.
final class ApplyProgressLog {
  private let fd: Int32

  init(_ path: String) throws(HostError) {
    fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw .posix("Failed to create", path) }
  }

  deinit { close(fd) }

  func append(_ line: String) throws(HostError) {
    try AtomicFile.writeAll(fd, Array((line + "\n").utf8), "apply progress")
    guard fsync(fd) == 0 else { throw .posix("Failed to sync", "apply progress") }
  }
}

/// The host tools that receive guest bytes (RET-04): fixed absolute paths,
/// a deliberately constructed environment, and a qualification check of
/// each tool's ownership and family before any receive. A tool that fails
/// is refused, never substituted from `PATH`.
struct InboundReceivers: Sendable {
  let tar: String
  let rsync: String
  let ssh: String
  /// Whether each tool and its directories must be root-owned and not
  /// writable by others. Only test doubles turn it off.
  let requireSystemOwnership: Bool
  /// How the tar receiver runs. Only script test doubles run unconfined.
  let confinement: ReceiverConfinement

  /// The tar receiver under Seatbelt: writes beneath its receive tree only.
  /// The rsync receiver is not confined: it must start `ssh`, and on the
  /// brokered transport the runtime's connector through `/bin/sh`.
  enum ReceiverConfinement: Sendable, Equatable {
    case seatbelt(sandboxExec: String)
    case none
  }

  init(
    tar: String, rsync: String, ssh: String, requireSystemOwnership: Bool,
    confinement: ReceiverConfinement = .seatbelt(sandboxExec: "/usr/bin/sandbox-exec")
  ) {
    self.tar = tar
    self.rsync = rsync
    self.ssh = ssh
    self.requireSystemOwnership = requireSystemOwnership
    self.confinement = confinement
  }

  static let system = InboundReceivers(
    tar: "/usr/bin/bsdtar", rsync: "/usr/bin/rsync", ssh: "/usr/bin/ssh",
    requireSystemOwnership: true)

  /// The tar receiver's executable and arguments: `tar <arguments>`, wrapped
  /// in `sandbox-exec` with `SeatbeltProfile.tarReceiver` so that only
  /// `tree` is writable. Both paths are canonical, as Seatbelt matches them.
  func tarCommand(_ arguments: [String], writableTree tree: String) throws -> (String, [String]) {
    guard case .seatbelt(let sandboxExec) = confinement else { return (tar, arguments) }
    guard let receiver = canonicalPath(tar), let root = canonicalPath(tree) else {
      throw HostError("Failed to resolve the tar receiver or its receive tree")
    }
    // bsdtar changes into the tree by the same canonical path the profile
    // allows: a symlink above it (a linked data_dir) is never traversed,
    // since the profile denies reading most symlinks.
    var confined = arguments
    for i in confined.indices.dropLast() where confined[i] == "-C" && confined[i + 1] == tree {
      confined[i + 1] = root
    }
    return (
      sandboxExec,
      [
        "-D", "RECEIVER=\(receiver)", "-D", "TREE=\(root)", "-p", SeatbeltProfile.tarReceiver,
        receiver,
      ] + confined
    )
  }

  /// The qualified macOS families: bsdtar 3 and openrsync.
  static let families = ["tar": "bsdtar 3.", "rsync": "openrsync:"]

  /// A receiver's environment: the minimal transport environment with a
  /// fixed system `PATH`, so a decompressor or helper a tool might start
  /// is never found elsewhere.
  func environment(_ transport: [String: String]) -> [String: String] {
    var environment = transport
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["COPYFILE_DISABLE"] = "1"
    return environment
  }

  private static let qualified = Mutex<Set<String>>([])

  func qualify(_ runner: ProcessRunner) throws {
    let wrapper: [String] =
      switch confinement {
      case .seatbelt(let sandboxExec): [sandboxExec]
      case .none: []
      }
    let key = ([tar, rsync, ssh, String(requireSystemOwnership)] + wrapper).joined(
      separator: "\0")
    if Self.qualified.withLock({ $0.contains(key) }) { return }
    for path in [tar, rsync, ssh] + wrapper {
      guard path.hasPrefix("/") else { throw unqualified(path, "not an absolute path") }
      guard access(path, X_OK) == 0 else { throw unqualified(path, "not executable") }
      if requireSystemOwnership { try Self.checkSystemOwned(path) }
    }
    if requireSystemOwnership {
      for (name, path) in [("tar", tar), ("rsync", rsync)] {
        let output = try? runner.capture(
          .init(
            executable: path, arguments: ["--version"],
            environment: environment(["PATH": "/usr/bin:/bin"]), deadline: .seconds(10)
          ).with(overflow: .drain))
        let first =
          output.map { String(decoding: $0.stdout + $0.stderr, as: UTF8.self) }?
          .split(separator: "\n").first.map(String.init) ?? ""
        guard let family = Self.families[name], first.hasPrefix(family) else {
          throw unqualified(path, "not the qualified \(Self.families[name] ?? name) receiver")
        }
      }
    }
    Self.qualified.withLock { _ = $0.insert(key) }
  }

  private func unqualified(_ path: String, _ reason: String) -> HostError {
    HostError(
      "Refusing to receive the workspace with \(neutralizeControls(path)): \(reason). Workspace returns use only the system tar, rsync and ssh."
    )
  }

  /// The tool and every directory above it are root-owned and writable by
  /// no one else, so no other principal can substitute it.
  static func checkSystemOwned(_ path: String) throws {
    var current = path
    while true {
      var info = stat()
      guard lstat(current, &info) == 0 else { throw HostError.posix("Failed to inspect", current) }
      let kind = info.st_mode & S_IFMT
      guard info.st_uid == 0, info.st_mode & 0o022 == 0, kind == S_IFREG || kind == S_IFDIR
      else {
        throw HostError(
          "Refusing to receive the workspace with \(path): \(current) is not a root-owned, unwritable system path"
        )
      }
      if current == "/" { return }
      current = (current as NSString).deletingLastPathComponent
    }
  }
}
