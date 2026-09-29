import CoopConfiguration
import CoopCore
import Foundation

/// The one persistent-state layer (S-04) for host-owned records under
/// `<data_dir>/backends/apple-container-v1`. Records are versioned JSON,
/// read without following symlinks, written atomically and never widened
/// beyond owner-only. Formats and lock paths are those of the Rust host, so
/// either implementation reopens the other's state. Runtime-owned storage
/// is never touched here.
public enum StateStore {
  /// Largest control file accepted.
  static let maxControlFile = 1 << 20

  /// Read a managed control file without following a symlink at its path.
  /// Nil when the file does not exist.
  public static func readControlFile(_ path: String) throws(HostError) -> [UInt8]? {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd < 0 {
      let code = errno
      if code == ENOENT { return nil }
      throw .posix("Failed to open", path, code)
    }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw HostError("Failed to read \(path): not a regular file")
    }
    return try readBounded(
      fd, path: path, limit: maxControlFile, tooLarge: "\(path) is larger than 1 MiB")
  }

  /// Reads `fd` to end of file, retrying on `EINTR`, and fails once more
  /// than `limit` bytes have arrived.
  static func readBounded(_ fd: Int32, path: String, limit: Int, tooLarge: String) throws(HostError)
    -> [UInt8]
  {
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 64 << 10)
    while true {
      let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw .posix("Failed to read", path)
      }
      if count == 0 { return bytes }
      bytes.append(contentsOf: chunk[0..<count])
      guard bytes.count <= limit else { throw HostError(tooLarge) }
    }
  }

  /// Pretty JSON plus a trailing newline, replaced atomically, owner-only.
  public static func writeControlFile(_ value: some Encodable, to path: String) throws(HostError) {
    try AtomicFile.write(try encode(value, path: path), to: path, mode: .atMost(0o600))
  }

  static func encode(_ value: some Encodable, path: String) throws(HostError) -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    do {
      return Array(try encoder.encode(value)) + [UInt8(ascii: "\n")]
    } catch {
      throw HostError("Failed to serialize \(path)")
    }
  }

  static func decode<T: Decodable>(_ type: T.Type, _ bytes: [UInt8], path: String) throws(HostError)
    -> T
  {
    do {
      return try JSONDecoder().decode(T.self, from: Data(bytes))
    } catch {
      throw HostError("Failed to parse \(path): \(RuntimeProtocol.describe(error))")
    }
  }

  /// Create `path` (and parents) and restrict it to the owner.
  public static func ensurePrivateDirectory(_ path: String) throws(HostError) {
    do {
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    } catch {
      throw HostError("Failed to create \(path)")
    }
    guard chmod(path, 0o700) == 0 else { throw .posix("Failed to restrict", path) }
  }

  static func removeIfPresent(_ path: String) throws(HostError) {
    if unlink(path) != 0 && errno != ENOENT { throw .posix("Failed to remove", path) }
  }
}

/// Header shared by every versioned record.
public enum StateSchema {
  /// Literal backend tag stored in every record.
  public static let backend = "apple-container"
  /// Instance record, journal, and image manifest. Version 1 was the
  /// retired `container machine` backend; its records are refused.
  public static let version: UInt32 = 2
  /// `owner.json`, unchanged since version 1.
  public static let ownerVersion: UInt32 = 1

  struct Header: Decodable {
    let schemaVersion: UInt32
    let backend: String

    enum CodingKeys: String, CodingKey {
      case schemaVersion = "schema_version"
      case backend
    }
  }

  static func check(_ header: Header, path: String, want: UInt32) throws(RuntimeError) {
    guard header.backend == backend else {
      throw .identityConflict(
        "\(path) belongs to backend \(debugQuoted(header.backend)), not \(backend); refusing to use it"
      )
    }
    if header.schemaVersion == 1 && want == version {
      let directory = (path as NSString).deletingLastPathComponent
      throw .identityConflict(
        "\(path) has schema version 1 (the retired `container machine` backend); this build understands \(want). Remove \(directory) by hand, and delete its machine and network with `container machine delete` / `container network delete`"
      )
    }
    guard header.schemaVersion == want else {
      throw .identityConflict(
        "\(path) has schema version \(header.schemaVersion); this build understands \(want)")
    }
  }

  /// Check the header before decoding the rest, so a record from another
  /// schema fails with its own explanation rather than a field error.
  static func decode<T: Decodable>(
    _ type: T.Type, _ bytes: [UInt8], path: String, want: UInt32 = version
  )
    throws -> T
  {
    try check(StateStore.decode(Header.self, bytes, path: path), path: path, want: want)
    return try StateStore.decode(T.self, bytes, path: path)
  }
}

// MARK: - Owner

/// `owner.json`: the installation's identity, embedded in runtime names.
public struct Owner: Sendable, Equatable, Codable {
  public let schemaVersion: UInt32
  public let backend: String
  public let ownerID: OwnerID

  public var id: OwnerID { ownerID }

  public static func path(_ config: CoopConfig) -> String {
    config.stateRoot.appending("owner.json").path
  }

  /// Load the installation's owner record, refusing a foreign backend's.
  public static func load(_ config: CoopConfig) throws -> Owner {
    let path = path(config)
    guard let bytes = try StateStore.readControlFile(path) else {
      throw HostError(
        "No Apple sandbox backend state at \(config.stateRoot). Run `coop setup` first.")
    }
    return try StateSchema.decode(Owner.self, bytes, path: path, want: StateSchema.ownerVersion)
  }

  /// Load when present; nil for an installation that has never run setup.
  public static func loadIfPresent(_ config: CoopConfig) throws -> Owner? {
    guard try StateStore.readControlFile(path(config)) != nil else { return nil }
    return try load(config)
  }

  enum CodingKeys: String, CodingKey {
    case backend
    case schemaVersion = "schema_version"
    case ownerID = "owner_id"
  }
}

// MARK: - Machine record

/// `apple-machine.json`, written once creation has completed.
public struct MachineSidecar: Sendable, Equatable, Codable {
  public var schemaVersion: UInt32
  public var backend: String
  public var ownerID: OwnerID
  /// `coop-sandbox` id; its vmnet network is internal to the sandbox.
  public var machineID: MachineName
  public var imageRef: String
  public var imageDigest: String
  public var imageManifestID: String
  public var guestUser: GuestUser
  public var requestedCPUs: UInt32
  public var requestedMemoryBytes: UInt64
  public var hostKeyFingerprint: String
  public var lastObservedOwnerPID: Int32?
  public var lastObservedIP: IPv4Address?
  /// Set once coop itself replaced the disk (`restore`).
  public var reenrollHostKey: Bool
  public var createdAt: String
  public var runtimeIdentity: String

  public static func path(_ instance: Instance) -> String {
    instance.directory + "/apple-machine.json"
  }

  public static func loadIfPresent(_ instance: Instance) throws -> MachineSidecar? {
    let path = path(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    return try StateSchema.decode(MachineSidecar.self, bytes, path: path)
  }

  /// Refuse a record that is not this installation's, or whose runtime name
  /// was not generated for it.
  public func checkOwner(_ owner: Owner) throws(RuntimeError) {
    guard ownerID == owner.id, machineID.belongs(to: owner.id) else {
      throw .identityConflict("machine \(machineID) is not owned by this installation")
    }
  }

  public var resources: Resources {
    Resources(cpus: requestedCPUs, memoryBytes: requestedMemoryBytes)
  }

  enum CodingKeys: String, CodingKey {
    case backend
    case schemaVersion = "schema_version"
    case ownerID = "owner_id"
    case machineID = "machine_id"
    case imageRef = "image_ref"
    case imageDigest = "image_digest"
    case imageManifestID = "image_manifest_id"
    case guestUser = "guest_user"
    case requestedCPUs = "requested_cpus"
    case requestedMemoryBytes = "requested_memory_bytes"
    case hostKeyFingerprint = "host_key_fingerprint"
    case lastObservedOwnerPID = "last_observed_owner_pid"
    case lastObservedIP = "last_observed_ip"
    case reenrollHostKey = "reenroll_host_key"
    case createdAt = "created_at"
    case runtimeIdentity = "runtime_identity"
  }

  /// Optional fields are written as `null`, as serde does, not omitted.
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(schemaVersion, forKey: .schemaVersion)
    try c.encode(backend, forKey: .backend)
    try c.encode(ownerID, forKey: .ownerID)
    try c.encode(machineID, forKey: .machineID)
    try c.encode(imageRef, forKey: .imageRef)
    try c.encode(imageDigest, forKey: .imageDigest)
    try c.encode(imageManifestID, forKey: .imageManifestID)
    try c.encode(guestUser, forKey: .guestUser)
    try c.encode(requestedCPUs, forKey: .requestedCPUs)
    try c.encode(requestedMemoryBytes, forKey: .requestedMemoryBytes)
    try c.encode(hostKeyFingerprint, forKey: .hostKeyFingerprint)
    try c.encode(lastObservedOwnerPID, forKey: .lastObservedOwnerPID)
    try c.encode(lastObservedIP, forKey: .lastObservedIP)
    try c.encode(reenrollHostKey, forKey: .reenrollHostKey)
    try c.encode(createdAt, forKey: .createdAt)
    try c.encode(runtimeIdentity, forKey: .runtimeIdentity)
  }
}

/// A sandbox's CPU count and memory.
public struct Resources: Sendable, Equatable, Codable, CustomStringConvertible {
  public let cpus: UInt32
  public let memoryBytes: UInt64
  public var description: String { "\(cpus) vCPUs / \(memoryBytes / (1 << 20)) MiB" }

  enum CodingKeys: String, CodingKey {
    case cpus
    case memoryBytes = "memory_bytes"
  }
}

// MARK: - Journal

public enum CreateStage: String, Sendable, Codable, Comparable {
  case reserved
  case creatingMachine = "creating-machine"
  case machineCreated = "machine-created"
  static let order: [CreateStage] = [.reserved, .creatingMachine, .machineCreated]
  public static func < (a: Self, b: Self) -> Bool {
    order.firstIndex(of: a)! < order.firstIndex(of: b)!
  }
}

public enum DestroyStage: String, Sendable, Codable, Comparable {
  case reserved
  case deletingMachine = "deleting-machine"
  case machineDeleted = "machine-deleted"
  static let order: [DestroyStage] = [.reserved, .deletingMachine, .machineDeleted]
  public static func < (a: Self, b: Self) -> Bool {
    order.firstIndex(of: a)! < order.firstIndex(of: b)!
  }
}

/// A journaled operation with exactly what reconciling it needs
/// (serde `tag = "kind"`, kebab-case).
public enum JournalOp: Sendable, Equatable, Codable {
  case create(stage: CreateStage)
  case setResources(operation: OperationID, prior: Resources)
  case restoreDisk(operation: OperationID, priorGeneration: UInt64)
  case destroy(stage: DestroyStage)

  enum CodingKeys: String, CodingKey {
    case kind, stage, operation, prior
    case priorGeneration = "prior_generation"
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(String.self, forKey: .kind) {
    case "create": self = .create(stage: try c.decode(CreateStage.self, forKey: .stage))
    case "set-resources":
      self = .setResources(
        operation: try c.decode(OperationID.self, forKey: .operation),
        prior: try c.decode(Resources.self, forKey: .prior))
    case "restore-disk":
      self = .restoreDisk(
        operation: try c.decode(OperationID.self, forKey: .operation),
        priorGeneration: try c.decode(UInt64.self, forKey: .priorGeneration))
    case "destroy": self = .destroy(stage: try c.decode(DestroyStage.self, forKey: .stage))
    case let other:
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: c.codingPath + [CodingKeys.kind], debugDescription: "unknown kind \(other)"))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .create(let stage):
      try c.encode("create", forKey: .kind)
      try c.encode(stage, forKey: .stage)
    case .setResources(let operation, let prior):
      try c.encode("set-resources", forKey: .kind)
      try c.encode(operation, forKey: .operation)
      try c.encode(prior, forKey: .prior)
    case .restoreDisk(let operation, let generation):
      try c.encode("restore-disk", forKey: .kind)
      try c.encode(operation, forKey: .operation)
      try c.encode(generation, forKey: .priorGeneration)
    case .destroy(let stage):
      try c.encode("destroy", forKey: .kind)
      try c.encode(stage, forKey: .stage)
    }
  }

  public var describe: String {
    switch self {
    case .create: "create"
    case .setResources: "resource change"
    case .restoreDisk: "restore"
    case .destroy: "destroy"
    }
  }

  /// The one command that reconciles it.
  public func recoveryHint(_ name: InstanceName) -> String {
    switch self {
    case .setResources, .restoreDisk: "run `coop start \(name)` to finish it"
    case .create: "run `coop destroy \(name)` to remove what it created, then `coop up` again"
    case .destroy: "run `coop destroy \(name)` to finish it"
    }
  }
}

/// `operation.json` — present only while a journaled mutation is pending.
public struct Journal: Sendable, Equatable, Codable {
  public let schemaVersion: UInt32
  public let backend: String
  public let ownerID: OwnerID
  public let machineID: MachineName
  public var op: JournalOp

  public static func path(_ instance: Instance) -> String { instance.directory + "/operation.json" }

  /// Written before each runtime call of a journaled mutation.
  public static func begin(_ instance: Instance, owner: Owner, op: JournalOp, machine: MachineName)
    throws -> Journal
  {
    let journal = Journal(
      schemaVersion: StateSchema.version, backend: StateSchema.backend, ownerID: owner.id,
      machineID: machine, op: op)
    try StateStore.writeControlFile(journal, to: path(instance))
    return journal
  }

  public mutating func advance(_ instance: Instance, _ op: JournalOp) throws {
    self.op = op
    try StateStore.writeControlFile(self, to: Self.path(instance))
  }

  public static func complete(_ instance: Instance) throws {
    do { try StateStore.removeIfPresent(path(instance)) } catch {
      throw ContextError("Failed to clear operation journal", cause: error)
    }
  }

  public static func loadIfPresent(_ instance: Instance) throws -> Journal? {
    let path = path(instance)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    try StateSchema.check(
      StateStore.decode(StateSchema.Header.self, bytes, path: path), path: path,
      want: StateSchema.version)
    do {
      return try JSONDecoder().decode(Journal.self, from: Data(bytes))
    } catch {
      throw HostError(
        "Failed to parse \(path) (a journal from an older build is not supported: check the sandbox with `coop-sandbox inspect`, then remove the file by hand)"
      )
    }
  }

  enum CodingKeys: String, CodingKey {
    case backend, op
    case schemaVersion = "schema_version"
    case ownerID = "owner_id"
    case machineID = "machine_id"
  }
}

// MARK: - Instances

/// One instance directory: `<state root>/instances/<name>/instance.json`.
public struct Instance: Sendable, Equatable {
  public let name: InstanceName
  public let index: InstanceIndex
  public let directory: String
  /// Golden image this instance was created from.
  public let image: ImageName

  struct Meta: Codable {
    let name: InstanceName
    let index: InstanceIndex
    let image: ImageName?
  }

  public var knownHostsPath: String { directory + "/known_hosts" }
  public var workspaceStatePath: String { directory + "/workspace.json" }
  public var forwardsStatePath: String { directory + "/forwards.json" }
  public var guestEnvironmentStatePath: String { directory + "/guest_env.json" }
  public var modelStatePath: String { directory + "/model.json" }
  public var proxyStatePath: String { directory + "/proxy.json" }
  public var devcontainerStatePath: String { directory + "/devcontainer_state.json" }

  static func load(directory: String) throws -> Instance {
    let path = directory + "/instance.json"
    guard let bytes = try StateStore.readControlFile(path) else {
      throw HostError("Failed to read \(path): No such file or directory")
    }
    let meta = try StateStore.decode(Meta.self, bytes, path: path)
    return Instance(
      name: meta.name, index: meta.index, directory: directory, image: meta.image ?? .default)
  }
}

/// The baseline's warning for an instance directory that cannot be loaded.
public func warnSkipped(_ path: String, _ error: any Error) {
  Diagnostics(verbosity: 0).warn(
    "Skipping corrupted instance dir \(path) (\(error)). Remove it manually or run `destroy --all`."
  )
}

public enum InstanceStore {
  /// Every loadable instance, sorted by index. A directory whose
  /// `instance.json` is missing or corrupt is reported through `skipped`
  /// and left alone (a crashed start leaves one behind).
  public static func list(_ config: CoopConfig, skipped: (String, any Error) -> Void = warnSkipped)
    throws
    -> [Instance]
  {
    let root = config.instancesDirectory.path
    let entries: [String]
    do {
      entries = try FileManager.default.contentsOfDirectory(atPath: root)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return []
    } catch {
      throw HostError("Failed to read instances directory")
    }
    var instances: [Instance] = []
    for entry in entries.sorted() {
      let directory = root + "/" + entry
      var status = stat()
      guard lstat(directory, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else { continue }
      do {
        instances.append(try Instance.load(directory: directory))
      } catch {
        skipped(directory, error)
      }
    }
    return instances.sorted { $0.index < $1.index }
  }

  /// Resolve by name, or the only instance when no name is given.
  public static func resolve(_ config: CoopConfig, name: InstanceName?) throws -> Instance {
    if let name {
      if let instance = try? Instance.load(
        directory: config.instancesDirectory.appending(name.rawValue).path),
        instance.name == name
      {
        return instance
      }
      let instances = try list(config)
      if let match = instances.first(where: { $0.name == name }) { return match }
      let available =
        instances.isEmpty
        ? "No instances exist."
        : "Available: " + instances.map(\.name.rawValue).joined(separator: ", ")
      throw HostError(
        "No instance named '\(name)'. \(available)\nCreate one with: coop up . --name \(name)")
    }
    let instances = try list(config)
    switch instances.count {
    case 1: return instances[0]
    case 0:
      throw HostError(
        "No instances found.\nCreate one with: coop up\n(Run `coop setup` first if you haven't built an image yet.)"
      )
    default:
      throw HostError(
        "Multiple instances exist. Specify one: "
          + instances.map(\.name.rawValue).joined(separator: ", "))
    }
  }

  /// Serialize mutations of one instance (the Rust `lock_instance` path).
  public static func lock(_ instance: Instance) throws(HostError) -> FileLock {
    try FileLock.sibling(of: MachineSidecar.path(instance))
  }
}

extension MachineSidecar {
  public func save(_ instance: Instance) throws {
    try StateStore.writeControlFile(self, to: Self.path(instance))
  }

  public static func load(_ instance: Instance) throws -> MachineSidecar {
    guard let sidecar = try loadIfPresent(instance) else {
      throw HostError(
        "Instance '\(instance.name)' has no Apple sandbox record at \(path(instance))")
    }
    return sidecar
  }
}

extension Owner {
  /// Only `setup` creates the owner record. A `data_dir` a default (Lima or
  /// Firecracker) build also uses is refused: that build's purge would
  /// delete this backend's ownership records.
  public static func loadOrInit(_ config: CoopConfig) throws -> Owner {
    if try StateStore.readControlFile(path(config)) != nil { return try load(config) }
    let foreign = ["images", "instances", "vm_key", "lima-builder.yaml", "vmlinux", "firecracker"]
    if let name = foreign.first(where: {
      FileManager.default.fileExists(atPath: config.dataDirectory.appending($0).path)
    }) {
      throw RuntimeError.identityConflict(
        "data_dir \(config.dataDirectory) already holds \(name) from a default coop build; refusing to share it. Use a separate data_dir and --config."
      )
    }
    try StateStore.ensurePrivateDirectory(config.stateRoot.path)
    let lock = try FileLock.sibling(of: path(config))
    defer { lock.release() }
    if try StateStore.readControlFile(path(config)) != nil { return try load(config) }
    let owner = Owner(
      schemaVersion: StateSchema.ownerVersion, backend: StateSchema.backend,
      ownerID: try OwnerID(randomHex(16)))
    try StateStore.writeControlFile(owner, to: path(config))
    return owner
  }
}

extension Instance {
  /// `instance.json` in serde's pretty format (field order, `": "`).
  func save() throws {
    let json = OutputJSON.object([
      ("name", .string(name.rawValue)), ("index", .uint(UInt64(index.value))),
      ("image", .string(image.rawValue)),
    ])
    do {
      try AtomicFile.write(
        Array(json.rendered().dropLast().utf8), to: directory + "/instance.json",
        mode: .preserveExisting(default: 0o644))
    } catch {
      throw ContextError("Failed to write instance.json", cause: error)
    }
  }

  /// A new instance record under the instances directory lock: the next
  /// index after the highest (else the lowest free), and the name given,
  /// derived from the workspace basename (`-2`, `-3`… on collision), or the
  /// index.
  public static func allocate(
    _ config: CoopConfig, name: InstanceName?, image: ImageName, workspacePath: String?
  ) throws -> Instance {
    let root = config.instancesDirectory.path
    do {
      try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    } catch {
      throw ContextError("Failed to create directory \(root)", cause: error)
    }
    let lock = try FileLock(path: root + "/.lock")
    defer { lock.release() }
    let instances = try InstanceStore.list(config)
    let used = Set(instances.map(\.index))
    var index: InstanceIndex?
    if let highest = instances.map(\.index.value).max(), highest < InstanceIndex.maximum,
      let next = InstanceIndex(highest + 1), !used.contains(next)
    {
      index = next
    } else {
      index = (0...InstanceIndex.maximum).lazy.compactMap { InstanceIndex($0) }
        .first { !used.contains($0) }
    }
    guard let index else { throw HostError("All 253 instance slots are in use") }
    let resolved: InstanceName
    if let name {
      resolved = name
    } else if let workspacePath {
      let basename = URL(fileURLWithPath: workspacePath).standardized.lastPathComponent
      resolved = try uniqueName(
        sanitizedBasename(basename == "/" ? "workspace" : basename), instances)
    } else {
      resolved = try InstanceName(index.description)
    }
    if instances.contains(where: { $0.name == resolved }) {
      throw HostError("Instance '\(resolved)' already exists")
    }
    let instance = Instance(
      name: resolved, index: index, directory: root + "/" + resolved.rawValue, image: image)
    do {
      // Owner-only: the instance holds its pinned key, guest env snapshot
      // and proxy tokens.
      try FileManager.default.createDirectory(
        atPath: instance.directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch {
      throw ContextError("Failed to create directory \(instance.directory)", cause: error)
    }
    try instance.save()
    return instance
  }

  /// `[A-Za-z0-9_-]` kept, anything else `-`, at most 60 bytes.
  static func sanitizedBasename(_ name: String) -> String {
    var out = ""
    for scalar in name.unicodeScalars {
      let keep =
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
        || ("0"..."9").contains(scalar) || scalar == "-" || scalar == "_"
      out.unicodeScalars.append(keep ? scalar : "-")
    }
    return out.isEmpty ? "workspace" : String(out.prefix(60))
  }

  static func uniqueName(_ base: String, _ instances: [Instance]) throws -> InstanceName {
    let taken = Set(instances.map(\.name.rawValue))
    if !taken.contains(base) { return try InstanceName(base) }
    for n in 2...99 where !taken.contains("\(base)-\(n)") {
      return try InstanceName("\(base)-\(n)")
    }
    throw HostError("Could not find unique instance name for '\(base)'")
  }

  /// `coop restore`: the lineage follows the restored image.
  public func withImage(_ image: ImageName) throws -> Instance {
    let updated = Instance(name: name, index: index, directory: directory, image: image)
    try updated.save()
    return updated
  }
}

/// `n` random bytes from the system CSPRNG, lowercase hex.
public func randomHex(_ count: Int) -> String {
  var bytes = [UInt8](repeating: 0, count: count)
  arc4random_buf(&bytes, count)
  return bytes.map { String(format: "%02x", $0) }.joined()
}

/// `YYYY-MM-DDTHH:MM:SSZ` in UTC.
public func utcTimestamp(_ date: Date = Date()) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.string(from: date)
}
