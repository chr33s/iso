import Foundation

/// How the broker reaches the endpoint: the confined child through its
/// channel (`DataPlaneSupervisor`), or an in-process `DataPlaneService`
/// (tests only — production admission requires the confined child).
package protocol DataPlaneEndpointLink: Sendable {
  /// Returns the name of the allocation's own endpoint socket inside the
  /// endpoint's socket directory (16 lowercase hex characters).
  func register(_ grant: DataPlaneGrant) async throws(CIError) -> String
  func unregister(_ allocation: AllocationID) async
  func cancel(_ allocation: AllocationID) async
}

extension DataPlaneService: DataPlaneEndpointLink {}

/// Everything the controller decides for one preflight allocation.
package struct DataPlaneRegistration: Sendable {
  package var allocation: AllocationID
  package var attempt: JobAttemptID
  package var run: PreflightRunID
  package var authority: Authority
  package var plan: WorkflowPlan
  package var job: JobPlan
  package var contexts: JobMessageBuilder.Contexts
  /// Mapped workflow secrets explicitly authorized for this run.
  package var secrets: [String: String]
  package var snapshot: Digest?
  package var actions: [ResolvedAction]
  /// Earlier attempts whose artifacts this job may download (its explicit
  /// dependency provenance). Its own attempt is always included.
  package var dependencyAttempts: Set<JobAttemptID>
  package var cacheScope: ObjectStore.CacheScope
  package var limits: LimitsDescriptor
  package var guestHost: GuestEndpointHost
  package var guestPort: UInt16
  package var expiresAt: EpochSeconds
  package var runnerName: String

  package init(
    allocation: AllocationID, attempt: JobAttemptID, run: PreflightRunID, authority: Authority,
    plan: WorkflowPlan, job: JobPlan, contexts: JobMessageBuilder.Contexts,
    secrets: [String: String],
    snapshot: Digest?, actions: [ResolvedAction], dependencyAttempts: Set<JobAttemptID>,
    cacheScope: ObjectStore.CacheScope, limits: LimitsDescriptor,
    guestHost: GuestEndpointHost = .loopback, guestPort: UInt16,
    expiresAt: EpochSeconds, runnerName: String
  ) {
    self.allocation = allocation
    self.attempt = attempt
    self.run = run
    self.authority = authority
    self.plan = plan
    self.job = job
    self.contexts = contexts
    self.secrets = secrets
    self.snapshot = snapshot
    self.actions = actions
    self.dependencyAttempts = dependencyAttempts
    self.cacheScope = cacheScope
    self.limits = limits
    self.guestHost = guestHost
    self.guestPort = guestPort
    self.expiresAt = expiresAt
    self.runnerName = runnerName
  }
}

/// What the guest needs to reach its endpoint. `isoToken` and `jitConfig`
/// are guest-visible allocation credentials: they authenticate only to this
/// allocation's namespace and are never logged or put in host argv.
package struct GuestEndpointConfig: Sendable {
  package let guestPort: UInt16
  /// The allocation's own Unix socket on the host: the guest's reverse
  /// forward (`127.0.0.1:<guestPort>`) must target this path. Requests that
  /// arrive on it are only ever authorized for this allocation.
  package let hostSocket: String
  package let baseURL: String
  package let isoToken: String
  /// The runner's `--jitconfig` value (base64 JSON of `.runner`,
  /// `.credentials` and `.credentials_rsaparams`).
  package let jitConfig: String
  package let runnerName: String
}

/// A stored log segment of one attempt.
package struct DataPlaneLogReference: Sendable, Equatable {
  package let kind: DataPlaneCall.LogKind
  package let step: String?
  package let digest: Digest
  package let lines: UInt64
}

/// An event surfaced to the orchestrator, with the attempt's logs so far.
package struct DataPlaneNotice: Sendable {
  package let allocation: AllocationID
  package let attempt: JobAttemptID
  package let event: DataPlaneEvent
  package let logs: [DataPlaneLogReference]
}

/// The controller side of the data plane. It owns allocation registration
/// and every authorization decision: the endpoint (and the confined child
/// it runs in) can only ask. Uploaded bytes are *copied* out of the child's
/// staging directory into controller-private uploads before hashing, so a
/// compromised child cannot alter an object after it was verified, and
/// exports are APFS clones, never hard links to stored objects.
package actor DataPlaneBroker: DataPlaneBackend {
  package static let maxLogSegments = 1_024
  package static let maxCacheReservations = 32
  package static let maxArtifacts = 64

  struct Entry {
    let registration: DataPlaneRegistration
    var cacheHandles: [String: (digest: Digest, size: UInt64)] = [:]
    var reservations: [Int64: (reservation: String, upload: ObjectStore.Upload)] = [:]
    var artifacts: Set<Int64> = []
    var logs: [DataPlaneLogReference] = []
    var completed = false
    var reservationsMade = 0
    /// Bytes committed to the object store for this attempt: caches and
    /// artifacts against `outputBytes`, logs against `logBytes`.
    var outputStored: UInt64 = 0
    var logStored: UInt64 = 0
  }

  private let store: ObjectStore
  private let childStaging: String
  private let scripts: any SyntheticStepScripts
  private var link: (any DataPlaneEndpointLink)?
  private var socketDirectory: String?
  private var directories: StagingDirectories?
  private var entries: [AllocationID: Entry] = [:]
  private var nextCacheID: Int64 = 1
  private let continuation: AsyncStream<DataPlaneNotice>.Continuation
  /// Job progress and completions, in arrival order.
  package nonisolated let notices: AsyncStream<DataPlaneNotice>

  package init(store: ObjectStore, childStaging: String, scripts: any SyntheticStepScripts) {
    self.store = store
    self.childStaging = childStaging
    self.scripts = scripts
    (notices, continuation) = AsyncStream.makeStream(
      of: DataPlaneNotice.self, bufferingPolicy: .bufferingNewest(4_096))
  }

  /// Connects the endpoint. `socketDirectory` is where the confined child
  /// binds one socket per allocation (nil for the in-process endpoint used
  /// by tests). Prepares the staging descriptors if the supervisor has not.
  package func attach(_ link: any DataPlaneEndpointLink, socketDirectory: String? = nil)
    throws(CIError)
  {
    try prepareStaging()
    self.link = link
    self.socketDirectory = socketDirectory
  }

  /// `[0-9a-f]{16}`: the only socket names the controller accepts.
  package static func isSocketName(_ name: String) -> Bool {
    name.utf8.count == 16 && Array(name.utf8).allSatisfy(isLowerHex)
  }

  /// The host path of an allocation's socket, verified to be a Unix socket
  /// owned by this user (not a symlink) in the controller-created directory.
  private func hostSocket(_ name: String) throws(CIError) -> String {
    guard let socketDirectory else { return name }
    guard Self.isSocketName(name) else { throw CIError.invalid("invalid endpoint socket name") }
    let path = socketDirectory + "/" + name
    var status = stat()
    guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFSOCK,
      status.st_uid == getuid()
    else { throw CIError(.confinementUnavailable, "the allocation's endpoint socket is invalid") }
    return path
  }

  // MARK: Registration

  package func register(_ registration: DataPlaneRegistration) async throws(CIError)
    -> GuestEndpointConfig
  {
    guard let link else {
      throw CIError(.confinementUnavailable, "the preflight endpoint is not running")
    }
    guard entries[registration.allocation] == nil else {
      throw CIError(.conflict, "allocation is already registered with the endpoint")
    }
    let subject = registration.attempt.rawValue
    if let snapshot = registration.snapshot {
      try store.grant(subject: subject, kind: .snapshot, digest: snapshot)
    }
    for action in registration.actions {
      try store.grant(subject: subject, kind: .actionArchive, digest: action.archiveDigest)
    }
    let endpoint = JobMessageBuilder.Endpoint(
      host: registration.guestHost, guestPort: registration.guestPort)
    let message = try JobMessageBuilder.build(
      plan: registration.plan, job: registration.job, attempt: registration.attempt,
      run: registration.run,
      contexts: registration.contexts, endpoint: endpoint,
      secrets: registration.secrets,
      syntheticScripts: scripts, snapshot: registration.snapshot)
    let iso = IsoBearer.generate()
    // The ISO token reaches synthetic steps as a masked secret variable.
    let withIso = try Self.addSecretVariable(message, name: "ISO_CI_TOKEN", value: iso.value)
    let keys = try RunnerKeyPair.generate()
    let clientID = UUID().uuidString.lowercased()
    let identity = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    let grant = DataPlaneGrant(
      allocation: registration.allocation, attempt: registration.attempt, clientID: clientID,
      runnerPublicKeyDER: keys.publicKeyDER, isoVerifier: iso.verifier,
      guestHost: registration.guestHost, guestPort: registration.guestPort,
      planID: identity.planID.uuidString.lowercased(),
      jobID: identity.jobID.uuidString.lowercased(),
      jobMessage: withIso, expiresAt: Int64(registration.expiresAt),
      trafficBytes: registration.limits.trafficBytes, uploadBytes: registration.limits.outputBytes,
      logBytes: registration.limits.logBytes)
    entries[registration.allocation] = Entry(registration: registration)
    let socket: String
    do { socket = try hostSocket(try await link.register(grant)) } catch {
      entries[registration.allocation] = nil
      await link.unregister(registration.allocation)
      throw error
    }
    let jit = PreflightRunnerConfig(
      runnerName: registration.runnerName, endpoint: endpoint, clientID: clientID, keys: keys)
    return GuestEndpointConfig(
      guestPort: registration.guestPort, hostSocket: socket, baseURL: endpoint.base,
      isoToken: iso.value,
      jitConfig: jit.encoded, runnerName: registration.runnerName)
  }

  static func addSecretVariable(_ message: JSONValue, name: String, value: String) throws(CIError)
    -> JSONValue
  {
    guard case .object(var members) = message, case .object(var variables)? = members["variables"]
    else {
      throw CIError.invalid("job message has no variables")
    }
    variables[name] = ["value": .string(value), "isSecret": true]
    members["variables"] = .object(variables)
    return .object(members)
  }

  package func unregister(_ allocation: AllocationID) async {
    guard let entry = entries.removeValue(forKey: allocation) else { return }
    for reserved in entry.reservations.values {
      try? store.cacheAbort(reservation: reserved.reservation)
    }
    try? store.revokeAll(subject: entry.registration.attempt.rawValue)
    await link?.unregister(allocation)
  }

  package func cancel(_ allocation: AllocationID) async { await link?.cancel(allocation) }

  package func logs(_ allocation: AllocationID) -> [DataPlaneLogReference] {
    entries[allocation]?.logs ?? []
  }

  // MARK: Backend (requests from the endpoint)

  package func event(_ allocation: AllocationID, _ event: DataPlaneEvent) async {
    guard var entry = entries[allocation] else { return }
    if case .completed = event {
      // One completion per attempt; a repeated report is not a new result.
      guard !entry.completed else { return }
      entry.completed = true
      entries[allocation] = entry
    }
    continuation.yield(
      DataPlaneNotice(
        allocation: allocation, attempt: entry.registration.attempt, event: event, logs: entry.logs)
    )
  }

  package func call(_ allocation: AllocationID, _ call: DataPlaneCall) async throws(CIError)
    -> JSONValue
  {
    guard var entry = entries[allocation] else {
      throw CIError(.unauthorized, "allocation is not registered")
    }
    let registration = entry.registration
    let subject = registration.attempt.rawValue
    defer { entries[allocation] = entry }
    switch call {
    case .resolveActions(let requests):
      var resolved: [JSONValue] = []
      for request in requests {
        guard
          let action = registration.actions.first(where: {
            $0.nameWithOwner.lowercased() == request.action.lowercased()
              && $0.ref == request.version
          })
        else {
          throw CIError(
            .unauthorized, "\(request.action)@\(request.version) is not approved for this job")
        }
        resolved.append([
          "action": .string(request.action), "version": .string(request.version),
          "name": .string(action.nameWithOwner), "commit": .string(action.commit),
        ])
      }
      return ["actions": .array(resolved)]

    case .openAction(let name, let commit):
      guard
        let action = registration.actions.first(where: {
          $0.nameWithOwner.lowercased() == name.lowercased() && $0.commit == commit
        })
      else { throw CIError(.unauthorized, "action archive is not approved for this job") }
      return try export(subject: subject, kind: .actionArchive, digest: action.archiveDigest)

    case .openSnapshot(let digest):
      guard registration.snapshot == digest else {
        throw CIError(.unauthorized, "snapshot is not granted to this attempt")
      }
      return try export(subject: subject, kind: .snapshot, digest: digest)

    case .cacheLookup(let keys, let version):
      guard
        let hit = try store.cacheLookup(
          scope: registration.cacheScope, keys: keys, version: version)
      else {
        return .null
      }
      // Lookup within the attempt's own scope is the authorization to read
      // this shared immutable entry; the grant is recorded per attempt.
      try store.grant(subject: subject, kind: .cache, digest: hit.digest)
      let handle = randomHex(bytes: 16)
      entry.cacheHandles[handle] = (hit.digest, hit.size)
      return [
        "key": .string(hit.key), "version": .string(hit.version), "handle": .string(handle),
        "size": .integer(Int64(hit.size)), "created_at": .integer(Int64(hit.createdAt)),
      ]

    case .openCache(let handle):
      guard let hit = entry.cacheHandles[handle] else {
        throw CIError(.unauthorized, "unknown cache handle")
      }
      return try export(subject: subject, kind: .cache, digest: hit.digest)

    case .cacheReserve(let key, let version):
      guard entry.reservationsMade < Self.maxCacheReservations else {
        throw CIError(.budgetExceeded, "this attempt reserved too many cache entries")
      }
      guard
        let reserved = try store.cacheReserve(
          scope: registration.cacheScope, key: key, version: version, subject: subject,
          limit: registration.limits.outputBytes)
      else { throw CIError(.conflict, "cache entry already exists or is being written") }
      let id = nextCacheID
      nextCacheID += 1
      entry.reservations[id] = reserved
      entry.reservationsMade += 1
      return ["cache_id": .integer(id)]

    case .cacheCommit(let id, let file, let size):
      guard let reserved = entry.reservations.removeValue(forKey: id) else {
        throw CIError(.unauthorized, "unknown cache reservation")
      }
      do {
        let copied = try copyIn(
          file, into: reserved.upload, size: size,
          remaining: outputRemaining(entry))
        _ = try store.cacheCommit(
          reservation: reserved.reservation, subject: subject, expectedSize: size)
        entry.outputStored += copied
      } catch {
        try? store.cacheAbort(reservation: reserved.reservation)
        throw error
      }
      return ["ok": true]

    case .artifactCreate(let name):
      guard entry.artifacts.count < Self.maxArtifacts else {
        throw CIError(.budgetExceeded, "this attempt created too many artifacts")
      }
      let created = try store.artifactCreate(
        run: registration.run.rawValue, attempt: subject, name: name,
        authority: registration.authority.rawValue, limit: registration.limits.outputBytes)
      entry.artifacts.insert(created.entry.id)
      return ["id": .integer(created.entry.id)]

    case .artifactFinalize(let id, let file, let size, let hash):
      guard entry.artifacts.contains(id) else {
        throw CIError(.unauthorized, "artifact belongs to another attempt")
      }
      let upload = try store.artifactUpload(id: id, attempt: subject)
      let copied = try copyIn(file, into: upload, size: size, remaining: outputRemaining(entry))
      let finalized = try store.artifactFinalize(
        id: id, attempt: subject, expectedSize: size, expectedDigest: hash)
      entry.outputStored += copied
      return ["id": .integer(finalized.id)]

    case .artifactList(let nameFilter, let idFilter):
      var items: [JSONValue] = []
      for artifact in try store.artifacts(run: registration.run.rawValue, name: nameFilter)
      where (idFilter == nil || artifact.id == idFilter) && visible(artifact, to: registration) {
        var item: [String: JSONValue] = [
          "id": .integer(artifact.id), "name": .string(artifact.name),
          "size": .integer(Int64(artifact.size)),
          "created_at": .integer(Int64(artifact.createdAt)),
        ]
        if let digest = artifact.digest { item["digest"] = .string(digest.rawValue) }
        items.append(.object(item))
      }
      return ["artifacts": .array(items)]

    case .openArtifact(let id):
      guard let artifact = try store.artifact(id: id), artifact.run == registration.run.rawValue,
        artifact.finalized, let digest = artifact.digest, visible(artifact, to: registration)
      else { throw CIError(.unauthorized, "artifact is not available to this attempt") }
      try store.grant(subject: subject, kind: .artifact, digest: digest)
      return try export(subject: subject, kind: .artifact, digest: digest)

    case .logCommit(let kind, let step, let file, let lines):
      guard entry.logs.count < Self.maxLogSegments else {
        throw CIError(.budgetExceeded, "too many log segments")
      }
      let upload = try store.beginUpload(
        kind: .log, subject: subject, limit: max(registration.limits.logBytes, 1))
      do {
        let copied = try copyIn(
          file, into: upload, size: nil,
          remaining: registration.limits.logBytes
            - min(entry.logStored, registration.limits.logBytes))
        let published = try store.commit(upload)
        entry.logStored += copied
        entry.logs.append(
          DataPlaneLogReference(kind: kind, step: step, digest: published.digest, lines: lines))
        try store.grant(subject: subject, kind: .log, digest: published.digest)
      } catch {
        store.abort(upload)
        throw error
      }
      return ["ok": true]
    }
  }

  /// Output bytes (caches and artifacts) this attempt may still commit.
  func outputRemaining(_ entry: Entry) -> UInt64 {
    let limit = entry.registration.limits.outputBytes
    return limit - min(entry.outputStored, limit)
  }

  /// Artifacts of the same run produced by this attempt or one in its
  /// explicit dependency provenance, with a matching authority class. A
  /// privileged attempt never consumes a validation-produced artifact.
  func visible(_ artifact: ObjectStore.ArtifactEntry, to registration: DataPlaneRegistration)
    -> Bool
  {
    guard artifact.run == registration.run.rawValue, artifact.finalized,
      artifact.authority == registration.authority.rawValue
    else { return false }
    guard let producer = try? JobAttemptID(artifact.attempt) else { return false }
    return producer == registration.attempt || registration.dependencyAttempts.contains(producer)
  }

  // MARK: Files

  /// Opens the child's `in/` and `out/` directories once, before the child
  /// runs, and keeps descriptors to them. Every later access is relative to
  /// these descriptors (`openat`/`unlinkat`/`fclonefileat` with
  /// `O_NOFOLLOW`), so the child cannot redirect the unconfined controller
  /// by swapping a directory or entry for a symlink.
  package func prepareStaging() throws(CIError) {
    guard directories == nil else { return }
    directories = try StagingDirectories(root: childStaging)
  }

  private func staged() throws(CIError) -> StagingDirectories {
    guard let directories else {
      throw CIError(.confinementUnavailable, "the endpoint staging directories are not prepared")
    }
    return directories
  }

  /// Copies a staged child file into a controller-private upload, then
  /// removes the child file. The child cannot touch the copy afterwards.
  /// Returns the bytes copied.
  @discardableResult
  private func copyIn(
    _ name: String, into upload: ObjectStore.Upload, size: UInt64?, remaining: UInt64
  ) throws(CIError) -> UInt64 {
    guard DataPlaneWire.isFileName(name) else { throw CIError.invalid("invalid staged file name") }
    let directory = try staged().input
    defer { unlinkat(directory, name, 0) }
    let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw CIError.invalid("staged upload is missing or not a regular file") }
    defer { close(fd) }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG, status.st_uid == getuid(),
      status.st_nlink == 1, UInt64(status.st_size) <= upload.limit
    else { throw CIError(.budgetExceeded, "staged upload is invalid or too large") }
    guard UInt64(status.st_size) <= remaining else {
      throw CIError(.budgetExceeded, "the attempt's storage budget is exhausted")
    }
    if let size, UInt64(status.st_size) != size {
      throw CIError.invalid("staged upload size mismatch")
    }
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    var offset: UInt64 = 0
    while true {
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw CIError.storage("cannot read a staged upload")
      }
      if count == 0 { break }
      // The child may still be writing: bound by the budget, not st_size.
      guard offset + UInt64(count) <= min(upload.limit, remaining) else {
        throw CIError(.budgetExceeded, "upload too large")
      }
      try store.write(upload, offset: offset, bytes: Array(buffer[0..<count]))
      offset += UInt64(count)
    }
    if let size, offset != size { throw CIError.invalid("staged upload size mismatch") }
    return offset
  }

  /// Exposes an authorized object to the child as a copy-on-write clone
  /// created relative to the `out/` descriptor (never through a path the
  /// child can change).
  private func export(subject: String, kind: ObjectStore.Kind, digest: Digest) throws(CIError)
    -> JSONValue
  {
    let source = try store.authorizedPath(subject: subject, kind: kind, digest: digest)
    let directory = try staged().output
    let sourceFD = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard sourceFD >= 0 else { throw CIError.storage("cannot open an object") }
    defer { close(sourceFD) }
    var status = stat()
    guard fstat(sourceFD, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw CIError.storage("cannot open an object")
    }
    let name = randomHex(bytes: 16)
    if fclonefileat(sourceFD, directory, name, UInt32(CLONE_NOFOLLOW)) != 0 {
      let target = openat(
        directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o400)
      guard target >= 0 else { throw CIError.storage("cannot expose an object to the endpoint") }
      defer { close(target) }
      guard fcopyfile(sourceFD, target, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
        unlinkat(directory, name, 0)
        throw CIError.storage("cannot expose an object to the endpoint")
      }
    }
    return ["file": .string(name), "size": .integer(Int64(status.st_size))]
  }
}

/// Descriptors of the child's `in/` and `out/` directories, opened with
/// `O_DIRECTORY | O_NOFOLLOW` and verified to be directories owned by this
/// user that are not group- or other-writable.
package final class StagingDirectories: Sendable {
  package let input: Int32
  package let output: Int32

  package init(root: String) throws(CIError) {
    try PrivateFiles.ensureDirectory(root)
    try PrivateFiles.ensureDirectory(root + "/in")
    try PrivateFiles.ensureDirectory(root + "/out")
    let rootFD = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard rootFD >= 0 else { throw CIError.storage("cannot open the endpoint staging directory") }
    defer { close(rootFD) }
    input = try Self.directory(rootFD, "in")
    do throws(CIError) { output = try Self.directory(rootFD, "out") } catch {
      close(input)
      throw error
    }
  }

  private static func directory(_ parent: Int32, _ name: String) throws(CIError) -> Int32 {
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw CIError.storage("cannot open the endpoint \(name)/ directory") }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == getuid(),
      status.st_mode & 0o022 == 0
    else {
      close(fd)
      throw CIError.storage("the endpoint \(name)/ directory is not private")
    }
    return fd
  }

  deinit {
    close(input)
    close(output)
  }
}
