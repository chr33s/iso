import Darwin
import Foundation
import Synchronization

package enum SupervisionPhase: String, Sendable, Codable, CaseIterable {
  case starting
  case provisioning
  case registering
  /// Started; the supervisor holds the VM's access session while the
  /// controller runs the steady-state lifecycle.
  case holding
  case finished
  case failed

  /// Phases in which only the supervisor may act on the allocation.
  package var ownsStartup: Bool {
    self == .starting || self == .provisioning || self == .registering
  }
}

/// `<allocation-id>.state.json`, replaced atomically by the supervisor.
package struct SupervisorState: Sendable, Equatable, Codable {
  package var allocation: AllocationID
  package var pool: Name
  /// The pool digest the controller launched under; the supervisor refuses
  /// to act on a configuration that no longer matches it.
  package var poolDigest: Digest
  package var phase: SupervisionPhase
  package var pid: Int32?
  package var runnerID: Int64?
  package var detail: String?
  package var updatedAt: EpochSeconds

  package init(
    allocation: AllocationID, pool: Name, poolDigest: Digest, phase: SupervisionPhase,
    updatedAt: EpochSeconds
  ) {
    self.allocation = allocation
    self.pool = pool
    self.poolDigest = poolDigest
    self.phase = phase
    self.updatedAt = updatedAt
  }
}

package enum SupervisorStatus: Sendable, Equatable {
  case unsupervised
  case live(SupervisorState?)

  package var ownsStartup: Bool {
    if case .live(let state) = self { return state?.phase.ownsStartup ?? true }
    return false
  }

  package var isLive: Bool { if case .live = self { true } else { false } }
}

package protocol SupervisorDirectory: Sendable {
  func status(_ allocation: AllocationID) -> SupervisorStatus
}

package protocol AllocationLauncher: Sendable {
  func launch(_ allocation: AllocationID, pool: Name, poolDigest: Digest) throws(CIError)
}

package struct AllocationFiles: Sendable, Equatable {
  package let directory: String

  package init(directory: String) { self.directory = directory }

  package func lock(_ id: AllocationID) -> String { "\(directory)/\(id.rawValue).lock" }
  package func state(_ id: AllocationID) -> String { "\(directory)/\(id.rawValue).state.json" }

  package func readState(_ id: AllocationID) -> SupervisorState? {
    guard let bytes = try? PrivateFiles.read(state(id), limit: 16 << 10) else { return nil }
    return try? ControllerStore.decode(SupervisorState.self, String(decoding: bytes, as: UTF8.self))
  }

  package func writeState(_ value: SupervisorState) throws(CIError) {
    try PrivateFiles.write(
      Array(try ControllerStore.encode(value).utf8), to: state(value.allocation))
  }

  /// Opens (creating 0600) a lock file without following a symlink.
  package func openLock(_ id: AllocationID, create: Bool) -> Int32? {
    let fd = open(lock(id), O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0o600)
    guard fd >= 0 else { return nil }
    var status = stat()
    guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
      status.st_uid == getuid()
    else {
      close(fd)
      return nil
    }
    return fd
  }

  package func lockedAllocations() -> [AllocationID] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return names.sorted().compactMap { name in
      guard name.hasSuffix(".lock") else { return nil }
      return try? AllocationID(String(name.dropLast(5)))
    }
  }
}

/// The result of the controller's startup scan.
package struct SupervisorAdoption: Sendable, Equatable {
  package var live: [AllocationID: SupervisorState?] = [:]
  package var ended: [AllocationID: SupervisorState?] = [:]

  package init() {}
}

/// Per-allocation supervisor processes, decoupled from the controller by an
/// inherited `flock`. The controller takes `flock(LOCK_EX|LOCK_NB)` on
/// `<id>.lock`, passes that one descriptor (as fd 3, the only descriptor
/// besides stdio without close-on-exec) to `iso-ci internal-supervise`
/// in a new session, and closes its own copy. The lock is then held by the
/// supervisor alone and released by the kernel when it exits, however it
/// exits, so `EWOULDBLOCK` on the lock always means a live supervisor. A
/// restarted controller re-adopts live allocations instead of guessing.
package final class AllocationSupervisors: SupervisorDirectory, AllocationLauncher {
  package static let lockDescriptor: Int32 = 3

  package let files: AllocationFiles
  let command: @Sendable (AllocationID) -> (executable: String, arguments: [String])
  let logDirectory: String
  let clock: any CIClock

  /// `command` builds the supervisor invocation; it receives fd 3 locked.
  package init(
    directory: String, logDirectory: String, clock: any CIClock = SystemClock(),
    command: @escaping @Sendable (AllocationID) -> (executable: String, arguments: [String])
  ) {
    files = AllocationFiles(directory: directory)
    self.logDirectory = logDirectory
    self.clock = clock
    self.command = command
  }

  /// Production wiring: the running executable's hidden subcommand. The
  /// supervisor reads the recorded iso executable and config from the
  /// controller database, like the controller.
  package static func standard(root: DataRoot, executable: String) -> AllocationSupervisors {
    AllocationSupervisors(directory: root.allocations, logDirectory: root.logs) { id in
      (
        executable,
        ["internal-supervise", "--root", root.path, "--allocation", id.rawValue, "--lock-fd", "3"]
      )
    }
  }

  package func launch(_ id: AllocationID, pool: Name, poolDigest: Digest) throws(CIError) {
    try PrivateFiles.ensureDirectory(files.directory)
    try PrivateFiles.ensureDirectory(logDirectory)
    guard let fd = files.openLock(id, create: true) else {
      throw CIError.storage("cannot create the supervisor lock for \(id)")
    }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      throw CIError(.conflict, "allocation \(id) already has a supervisor")
    }
    try files.writeState(
      SupervisorState(
        allocation: id, pool: pool, poolDigest: poolDigest, phase: .starting,
        updatedAt: clock.now()))
    let log = open(
      "\(logDirectory)/supervisor-\(id.rawValue).log",
      O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
    let devnull = open("/dev/null", O_RDONLY | O_CLOEXEC)
    defer {
      if log >= 0 { close(log) }
      if devnull >= 0 { close(devnull) }
    }
    let invocation = command(id)
    // On failure the deferred close unlocks; the caller releases the
    // VM-less allocation itself.
    _ = try Subprocess.spawn(
      invocation.executable, invocation.arguments, Subprocess.baseEnvironment(),
      stdin: devnull, stdout: log >= 0 ? log : devnull, stderr: log >= 0 ? log : devnull,
      group: .session, inherit: [(fd, Self.lockDescriptor)])
    // The child holds the same open file description, so closing ours
    // (deferred) leaves the lock with the child alone.
  }

  package func status(_ id: AllocationID) -> SupervisorStatus {
    guard let fd = files.openLock(id, create: false) else { return .unsupervised }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      _ = flock(fd, LOCK_UN)
      return .unsupervised
    }
    return errno == EWOULDBLOCK ? .live(files.readState(id)) : .unsupervised
  }

  /// The controller's startup scan: every lock is probed once. A free lock
  /// is taken while its files are removed, so the scan never races a
  /// supervisor (ids are never reused).
  package func adopt() -> SupervisorAdoption {
    var out = SupervisorAdoption()
    for id in files.lockedAllocations() {
      guard let fd = files.openLock(id, create: false) else { continue }
      defer { close(fd) }
      let state = files.readState(id)
      if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        if errno == EWOULDBLOCK { out.live[id] = state }
        continue
      }
      out.ended[id] = state
      unlink(files.state(id))
      unlink(files.lock(id))
    }
    return out
  }

  /// Removes the files of a supervisor that has exited, after the
  /// controller has taken over the allocation.
  package func forget(_ id: AllocationID) {
    guard let fd = files.openLock(id, create: false) else { return }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return }
    unlink(files.state(id))
    unlink(files.lock(id))
  }
}

/// No supervisor processes: startup runs inline in the controller pass
/// (tests, and allocations started before supervisors existed).
package struct InlineSupervision: SupervisorDirectory {
  package init() {}
  package func status(_ allocation: AllocationID) -> SupervisorStatus { .unsupervised }
}

/// The child side: verifies it holds the inherited lock and records its
/// phases with atomic replaces of the state file.
package final class SupervisorReporter: Sendable {
  package let files: AllocationFiles
  package let allocation: AllocationID
  let clock: any CIClock
  private let current: Mutex<SupervisorState>

  /// Fails unless `lockFD` is an open descriptor for this allocation's lock
  /// file that this process holds exclusively.
  package init(files: AllocationFiles, allocation: AllocationID, lockFD: Int32, clock: any CIClock)
    throws(CIError)
  {
    var held = stat()
    var named = stat()
    guard fstat(lockFD, &held) == 0, lstat(files.lock(allocation), &named) == 0,
      held.st_dev == named.st_dev, held.st_ino == named.st_ino
    else { throw CIError(.conflict, "fd \(lockFD) is not the lock of allocation \(allocation)") }
    // Re-locking one's own open file description succeeds; another
    // holder means this process does not own the allocation.
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      throw CIError(.conflict, "allocation \(allocation)'s lock is held by another process")
    }
    guard var state = files.readState(allocation) else {
      throw CIError(.notFound, "allocation \(allocation) has no supervisor state")
    }
    state.pid = getpid()
    self.files = files
    self.allocation = allocation
    self.clock = clock
    current = Mutex(state)
  }

  package var state: SupervisorState { current.withLock { $0 } }

  package func report(_ phase: SupervisionPhase, runnerID: Int64? = nil, detail: String? = nil) {
    let snapshot = current.withLock { state -> SupervisorState in
      state.phase = phase
      if let runnerID { state.runnerID = runnerID }
      state.detail = detail.map(CIError.bounded)
      state.updatedAt = clock.now()
      return state
    }
    try? files.writeState(snapshot)
  }
}

/// The body of `iso-ci internal-supervise`: start the allocation (JIT
/// registration included), then hold its VM's access session until the
/// controller has stopped, retained or released it. Every outcome is
/// recorded in the allocation record and the state file, so the controller
/// can take over at any point.
package enum SupervisorMain {
  package static func run(
    allocation id: AllocationID, reporter: SupervisorReporter, store: ControllerStore,
    provider: any EnvironmentProvider, configuration: CIConfiguration,
    runners: any RunnerService, controller: ControllerID, pollSeconds: Double = 10,
    sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
  ) -> SupervisionPhase {
    let launched = reporter.state
    guard configuration.poolDigest(launched.pool) == launched.poolDigest else {
      _ = try? store.update(id) {
        $0.desired = .release
        if $0.execution == .pending { $0.execution = .cancelled }
        $0.note("pool configuration changed between scheduling and start")
      }
      reporter.report(.failed, detail: "pool configuration changed since launch")
      return .failed
    }
    let reconciler = ConnectedPoolReconciler(
      pool: launched.pool, store: store, configuration: configuration, provider: provider,
      runners: runners, controller: controller)
    let report = reconciler.startAllocation(id, reporter: reporter)
    for error in report.errors.prefix(8) {
      _ = try? store.event("allocation:\(id)", "supervisor.error", error)
    }
    guard reporter.state.phase == .holding else { return .failed }
    while let record = try? store.allocation(id), holds(record) {
      // Reopens the session if it dropped; a VM that is gone ends the loop
      // through the controller's observations.
      try? provider.holdSession(id, forwards: [])
      sleep(pollSeconds)
    }
    provider.closeSession(id)
    reporter.report(.finished)
    return .finished
  }

  /// Whether the allocation still needs a held session.
  package static func holds(_ record: AllocationRecord) -> Bool {
    (record.desired == .active || record.desired == .drain) && record.vmCleanup != .verified
      && !record.isSettled && record.observedRunPhase.map { $0 == .running } ?? true
  }
}
