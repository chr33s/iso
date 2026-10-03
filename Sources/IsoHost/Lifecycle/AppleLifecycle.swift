import Foundation
import IsoConfiguration
import IsoCore

/// Lifecycle mutations of the Apple backend. Each takes the per-instance
/// lock, journals its runtime calls where an interruption could leave the
/// runtime and host records disagreeing, and verifies the runtime's report
/// rather than trusting a call's exit status.
extension AppleBackend {
  func sleep(_ duration: Duration) {
    let (seconds, attoseconds) = duration.components
    Thread.sleep(forTimeInterval: Double(seconds) + Double(attoseconds) / 1e18)
  }

  func expected(_ sidecar: MachineSidecar, _ runtime: SandboxRuntime) -> IsolationGate.Expected {
    .init(
      sandbox: sidecar.machineID, owner: sidecar.ownerID, runtimeRoot: runtime.root,
      resources: sidecar.resources, egress: config.egress)
  }

  // MARK: Boot

  func bootLogTail(_ runtime: SandboxRuntime, _ name: MachineName) -> String {
    if let tail = try? runtime.logTail(name), !tail.trimmingUnicodeWhitespace().isEmpty {
      return "\nLast console log lines:\n\(sanitizeForDisplay(tail))"
    }
    return "\n(Console log unavailable; try `iso logs`.) [\(name)]"
  }

  func boot(_ runtime: SandboxRuntime, _ name: MachineName, expiresAt: Date?) throws {
    do { try runtime.start(name, expiresAt: expiresAt) } catch {
      throw RuntimeError.bootTimeout(
        "sandbox \(name) failed to boot: \(error)\(bootLogTail(runtime, name))")
    }
  }

  /// Poll until the owner reports a running configuration, then run the
  /// isolation gate once (a gate failure is final, never retried).
  func waitReady(
    _ runtime: SandboxRuntime, _ expected: IsolationGate.Expected,
    until deadline: ContinuousClock.Instant
  )
    throws -> IsolationGate.Ready
  {
    let name = expected.sandbox
    while true {
      try Shutdown.check()
      let inspection = try runtime.inspect(name)
      switch inspection.status {
      case .running where inspection.effective != nil:
        return try IsolationGate.verifyEffective(inspection, expected)
      case .stopped, .crashed:
        throw RuntimeError.bootTimeout(
          "sandbox \(name) \(inspection.status.rawValue) during boot\(bootLogTail(runtime, name))")
      default:
        guard ContinuousClock.now < deadline else {
          throw RuntimeError.bootTimeout(
            "sandbox \(name) did not report a running configuration in time\(bootLogTail(runtime, name))"
          )
        }
        sleep(.milliseconds(250))
      }
    }
  }

  /// The guest's host key over the runtime channel, from the same boot the
  /// gate approved.
  func readHostKey(
    _ runtime: SandboxRuntime, _ ready: IsolationGate.Ready, until deadline: ContinuousClock.Instant
  )
    throws -> HostPublicKey
  {
    let name = ready.sandbox
    while true {
      try Shutdown.check()
      let output = try runtime.exec(
        name, timeout: runtime.settings.probeTimeout.seconds,
        ["/bin/cat", "/etc/ssh/ssh_host_ed25519_key.pub"],
        limit: SandboxRuntime.pubkeyLimit)
      var attempt: any Error
      if output.termination == .exited(0) {
        switch Result(catching: { () throws -> HostPublicKey in
          guard let text = String(validating: output.stdout, as: UTF8.self) else {
            throw HostError("runtime output is not valid UTF-8")
          }
          return try HostPublicKey(parsing: text)
        }) {
        case .success(let key):
          guard try runtime.inspect(name).live?.pid == ready.ownerPID else {
            throw RuntimeError.identityConflict(
              "sandbox \(name) restarted while its host key was read")
          }
          return key
        case .failure(let error):
          attempt = error
        }
      } else {
        attempt = HostError(sanitizeForDisplay(String(decoding: output.stderr, as: UTF8.self)))
      }
      guard ContinuousClock.now < deadline else {
        throw RuntimeError.bootTimeout(
          "sandbox \(name) did not produce a valid SSH host key in time: \(oneLine(attempt))")
      }
      sleep(.milliseconds(500))
    }
  }

  /// `sessionTTL` starts a new session window for this boot.
  func bootValidated(
    _ runtime: SandboxRuntime, _ expected: IsolationGate.Expected,
    until deadline: ContinuousClock.Instant, sessionTTL: SessionTTL? = nil
  )
    throws -> (IsolationGate.Ready, HostPublicKey)
  {
    try boot(
      runtime, expected.sandbox,
      expiresAt: sessionTTL.map { Date().addingTimeInterval(TimeInterval($0.seconds)) })
    let ready = try waitReady(runtime, expected, until: deadline)
    return (ready, try readHostKey(runtime, ready, until: deadline))
  }

  func waitForSSH(
    _ instance: Instance, _ ready: IsolationGate.Ready, user: GuestUser,
    until deadline: ContinuousClock.Instant
  )
    throws
  {
    do {
      let target = try SSHTarget.pinned(
        config: config, instance: instance, machine: ready.sandbox, ip: ready.ipv4, user: user)
      try SSHClient(environment: environment).waitUntilReady(
        target, timeout: max(deadline - ContinuousClock.now, .seconds(5)), diagnostics: diagnostics)
    } catch {
      throw ContextError("Guest booted but SSH is not accepting connections", cause: error)
    }
  }

  // MARK: Stop and delete

  func stopAndConfirm(_ runtime: SandboxRuntime, _ name: MachineName) throws {
    let output = try runtime.stop(name)
    let status = try runtime.inspect(name).status
    guard status == .stopped else {
      throw RuntimeError.operationUncertain(
        "sandbox \(name) did not confirm it stopped (now \(status.rawValue); \(sanitizeForDisplay(String(decoding: output.stderr, as: UTF8.self)))); leaving it untouched"
      )
    }
  }

  /// After a failed start: stop, keep the disk.
  func stopAfterFailure(_ runtime: SandboxRuntime, _ name: MachineName) {
    do { try stopAndConfirm(runtime, name) } catch {
      diagnostics.warn("Failed to stop sandbox \(name) after a failed start: \(oneLine(error))")
    }
  }

  func deleteSandbox(_ runtime: SandboxRuntime, _ name: MachineName, owner: OwnerID) throws {
    try runtime.delete(name, owner: owner)
    guard try !runtime.exists(name) else {
      throw RuntimeError.operationUncertain("sandbox \(name) still exists after delete")
    }
  }

  func requireStopped(_ runtime: SandboxRuntime, _ instance: Instance, _ sidecar: MachineSidecar)
    throws
    -> SandboxInspection
  {
    let inspection = try runtime.inspect(sidecar.machineID)
    guard inspection.status == .stopped else {
      throw HostError(
        "Instance '\(instance.name)' is not stopped (sandbox is \(inspection.status.rawValue))")
    }
    return inspection
  }

  // MARK: Create

  /// A new sandbox for a freshly allocated instance, from its image.
  package func createAndStart(_ instance: Instance, diskGiB explicitDisk: UInt64?) throws {
    _ = try config.validated()
    let runtime = try runtime()
    _ = try runtime.requireQualified()
    let owner = try Owner.load(config)
    let manifest = try ImageManifest.load(config, instance.image)
    try runtime.verifyImage(manifest)
    let diskGiB: UInt64
    if let explicitDisk {
      diskGiB = explicitDisk
    } else if let disk = manifest.disk {
      guard disk.bytes > 0 else { throw HostError("disk size is zero") }
      let gib = disk.bytes / (1 << 30) + (disk.bytes % (1 << 30) == 0 ? 0 : 1)
      guard gib <= UInt64(UInt32.max) else {
        throw ContextError(
          "disk size", cause: HostError("out of range integral type conversion attempted"))
      }
      diskGiB = gib
    } else {
      diskGiB = UInt64(config.vm.templateSize.value)
    }
    let lock = try InstanceStore.lock(instance)
    defer { lock.release() }
    if try MachineSidecar.loadIfPresent(instance) != nil || Journal.loadIfPresent(instance) != nil {
      throw RuntimeError.operationUncertain(
        "instance '\(instance.name)' already has sandbox state; destroy it before recreating")
    }
    let machine = try MachineName.generate(for: owner.id, randomHex: randomHex(8))
    if try runtime.exists(machine) {
      throw RuntimeError.identityConflict("generated name \(machine) is already in use; retry")
    }
    var journal = try Journal.begin(
      instance, owner: owner, op: .create(stage: .reserved), machine: machine)
    do {
      try provisionSandbox(
        instance, runtime: runtime, owner: owner, manifest: manifest, machine: machine,
        diskGiB: diskGiB, journal: &journal)
    } catch {
      if case .create(let stage) = journal.op, stage >= .creatingMachine {
        stopAfterFailure(runtime, machine)
      }
      throw error
    }
    try Journal.complete(instance)
  }

  func provisionSandbox(
    _ instance: Instance, runtime: SandboxRuntime, owner: Owner, manifest: ImageManifest,
    machine: MachineName,
    diskGiB: UInt64, journal: inout Journal
  ) throws {
    let cpus = UInt32(config.vm.vcpuCount)
    let memoryMiB = UInt64(config.vm.memory.mib.value)
    let source: SandboxRuntime.Source =
      manifest.disk.map { .disk($0.name) } ?? .image(manifest.imageRef)
    try NetworkPolicy.save(config, instance)
    try journal.advance(instance, .create(stage: .creatingMachine))
    try runtime.create(
      machine, source: source, cpus: cpus, memoryMiB: memoryMiB, diskGiB: diskGiB, owner: owner.id,
      egress: config.egress)
    try journal.advance(instance, .create(stage: .machineCreated))
    var sidecar = MachineSidecar(
      schemaVersion: StateSchema.version, backend: StateSchema.backend, ownerID: owner.id,
      machineID: machine,
      imageRef: manifest.imageRef, imageDigest: manifest.digest,
      imageManifestID: manifest.manifestID,
      guestUser: manifest.guestUser, requestedCPUs: cpus,
      requestedMemoryBytes: memoryMiB * (1 << 20),
      hostKeyFingerprint: "", lastObservedOwnerPID: nil, lastObservedIP: nil,
      reenrollHostKey: false,
      createdAt: utcTimestamp(), runtimeIdentity: try runtime.requireQualified())
    try IsolationGate.verifyRecord(try runtime.inspect(machine), expected(sidecar, runtime))
    let deadline = ContinuousClock.now + runtime.settings.bootTimeout.duration
    let (ready, key) = try bootValidated(
      runtime, expected(sidecar, runtime), until: deadline, sessionTTL: config.limits.sessionTTL)
    try HostKeyPin.apply(.enroll, instance: instance, machine: machine, key: key)
    try waitForSSH(instance, ready, user: manifest.guestUser, until: deadline)
    sidecar.hostKeyFingerprint = key.fingerprint
    sidecar.lastObservedOwnerPID = ready.ownerPID
    sidecar.lastObservedIP = ready.ipv4
    try sidecar.save(instance)
  }

  // MARK: Start

  /// Boot a stopped instance, finishing an interrupted resource change or
  /// restore first. The host key must match its pin (or, after `restore`,
  /// is re-enrolled).
  package func startExisting(_ instance: Instance) throws {
    _ = try config.validated()
    try NetworkPolicy.enforce(instance, config: config)
    let runtime = try runtime()
    let identity = try runtime.requireQualified()
    let lock = try InstanceStore.lock(instance)
    defer { lock.release() }
    try recoverJournal(runtime, instance)
    var sidecar = try ownedSidecar(instance)
    let inspection = try runtime.inspect(sidecar.machineID)
    switch inspection.status {
    case .stopped, .crashed: break
    case .running: throw HostError("Instance '\(instance.name)' is already running")
    case .booting:
      throw RuntimeError.operationUncertain(
        "sandbox \(sidecar.machineID) is booting; wait for it to settle")
    }
    try IsolationGate.verifyRecord(inspection, expected(sidecar, runtime))
    let deadline = ContinuousClock.now + runtime.settings.bootTimeout.duration
    let trust: HostKeyTrust = sidecar.reenrollHostKey ? .reenrollAfterRestore : .requirePin
    let ready: IsolationGate.Ready
    do {
      let (booted, key) = try bootValidated(
        runtime, expected(sidecar, runtime), until: deadline, sessionTTL: config.limits.sessionTTL)
      ready = booted
      try HostKeyPin.apply(trust, instance: instance, machine: sidecar.machineID, key: key)
      if case .reenrollAfterRestore = trust {
        diagnostics.log(
          .info,
          "Pinned the new host key of '\(instance.name)' after its disk was restored (\(key.fingerprint))"
        )
        sidecar.reenrollHostKey = false
        sidecar.hostKeyFingerprint = key.fingerprint
        try sidecar.save(instance)
      }
      try waitForSSH(instance, ready, user: sidecar.guestUser, until: deadline)
    } catch {
      stopAfterFailure(runtime, sidecar.machineID)
      throw error
    }
    sidecar.lastObservedOwnerPID = ready.ownerPID
    sidecar.lastObservedIP = ready.ipv4
    sidecar.runtimeIdentity = identity
    try sidecar.save(instance)
  }

  /// Reconcile an interrupted resource change or restore from the runtime's
  /// record. Inspects only; never mutates the runtime. Create and destroy
  /// journals are left for `destroy`.
  func recoverJournal(_ runtime: SandboxRuntime, _ instance: Instance) throws {
    guard let journal = try Journal.loadIfPresent(instance) else { return }
    switch journal.op {
    case .create, .destroy: return
    case .setResources, .restoreDisk: break
    }
    let owner = try Owner.load(config)
    var sidecar = try MachineSidecar.load(instance)
    try sidecar.checkOwner(owner)
    guard journal.machineID == sidecar.machineID else {
      throw RuntimeError.identityConflict(
        "journal names \(journal.machineID), but the instance records \(sidecar.machineID)")
    }
    let inspection = try runtime.inspect(sidecar.machineID)
    guard inspection.status == .stopped else {
      throw RuntimeError.operationUncertain(
        "an interrupted \(journal.op.describe) of '\(instance.name)' cannot be reconciled while the sandbox is \(inspection.status.rawValue)"
      )
    }
    let record = inspection.record
    switch journal.op {
    case .setResources(let operation, _):
      let applied = record.lastOperation == operation
      let resources = Resources(cpus: record.cpus, memoryBytes: record.memoryBytes)
      diagnostics.warn(
        "Reconciling an interrupted resource change of '\(instance.name)' (\(applied ? "the change applied" : "the change did not apply")): runtime reports \(resources)"
      )
      sidecar.requestedCPUs = record.cpus
      sidecar.requestedMemoryBytes = record.memoryBytes
    case .restoreDisk(let operation, let prior):
      let applied = record.diskGeneration > prior && record.lastOperation == operation
      diagnostics.warn(
        "Reconciling an interrupted restore of '\(instance.name)': \(applied ? "the disk was replaced" : "the disk was not replaced by this restore")"
      )
      if applied {
        sidecar.imageRef = record.imageReference
        sidecar.imageDigest = record.imageDigest
        sidecar.reenrollHostKey = true
      }
    default: break
    }
    try sidecar.save(instance)
    try Journal.complete(instance)
  }

  // MARK: Stop

  package func stop(_ running: Running) throws {
    let runtime = try runtime()
    let lock = try InstanceStore.lock(running.instance)
    defer { lock.release() }
    let sidecar = try ownedSidecar(running.instance)
    try stopAndConfirm(runtime, sidecar.machineID)
  }

  /// Stop without proving the guest is reachable (the state probe failed).
  package func stopUnproven(_ instance: Instance) throws {
    let owner = try Owner.load(config)
    let sidecar = try MachineSidecar.load(instance)
    try sidecar.checkOwner(owner)
    let runtime = try runtime()
    let lock = try InstanceStore.lock(instance)
    defer { lock.release() }
    if try runtime.inspect(sidecar.machineID).status != .stopped {
      try stopAndConfirm(runtime, sidecar.machineID)
    }
    diagnostics.log(.info, "Instance '\(instance.name)' stopped")
  }

  // MARK: Destroy

  package func destroyInstance(_ instance: Instance) throws {
    var status = stat()
    guard lstat(instance.directory, &status) == 0 else { return }
    let lock = try InstanceStore.lock(instance)
    defer { lock.release() }
    // Guest-authored modes in a stage can deny removal; fail before the
    // machine is deleted, not after.
    let stage = StageLocation(instance)
    let stageLock = try stage.lock()
    defer { stageLock.release() }
    try stage.remove()
    let sidecar = try MachineSidecar.loadIfPresent(instance)
    var journal = try Journal.loadIfPresent(instance)
    let ids =
      journal.map { ($0.ownerID, $0.machineID) } ?? sidecar.map { ($0.ownerID, $0.machineID) }
    if let (ownerID, machine) = ids {
      let owner = try Owner.load(config)
      guard ownerID == owner.id, machine.belongs(to: owner.id) else {
        throw RuntimeError.identityConflict(
          "instance '\(instance.name)' records sandbox \(machine), which this installation does not own; leaving it untouched"
        )
      }
      let runtime = try runtime()
      // `list`, not `inspect`: inspect refuses an unreadable staged update.
      if let listed = try runtime.listed(machine) {
        if listed != .stopped { try stopAndConfirm(runtime, machine) }
        if journal == nil {
          journal = try Journal.begin(
            instance, owner: owner, op: .destroy(stage: .reserved), machine: machine)
        }
        try journal!.advance(instance, .destroy(stage: .deletingMachine))
        try deleteSandbox(runtime, machine, owner: owner.id)
        try journal!.advance(instance, .destroy(stage: .machineDeleted))
      }
      runtime.reconcileBestEffort(diagnostics: diagnostics)
    }
    do { try FileManager.default.removeItem(atPath: instance.directory) } catch {
      throw ContextError("Failed to remove \(instance.directory)", cause: error)
    }
  }

  /// `destroy --all`: every image's runtime content, best effort.
  package func destroyShared() {
    guard let images = try? ImageStore.list(config) else { return }
    for image in images {
      do { try destroyImage(image.name) } catch {
        diagnostics.warn("Failed to remove image '\(image.name)': \(oneLine(error))")
      }
    }
  }

  // MARK: Images

  package func destroyImage(_ image: ImageName) throws {
    let directory = config.imagesDirectory.appending(image.rawValue).path
    var status = stat()
    guard lstat(directory, &status) == 0 else { throw HostError("Image '\(image)' does not exist") }
    if let manifest = ImageManifest.loadLenient(config, image, diagnostics: diagnostics),
      let owner = try? Owner.load(config)
    {
      do {
        releaseManifest(try runtime(), owner: owner, manifest: manifest, except: image)
      } catch {
        diagnostics.warn(
          "Could not delete image \(manifest.imageRef) from the runtime: \(oneLine(error))")
      }
    }
    do { try FileManager.default.removeItem(atPath: directory) } catch {
      throw ContextError("Failed to remove image dir \(directory)", cause: error)
    }
    diagnostics.log(.info, "Removed image '\(image)'")
  }

  /// Delete a manifest's owned runtime content unless another saved
  /// manifest still references it. Any doubt keeps the content.
  func releaseManifest(
    _ runtime: SandboxRuntime, owner: Owner, manifest: ImageManifest, except: ImageName?
  ) {
    var references = Set<String>()
    var disks = Set<String>()
    do {
      for image in try ImageStore.list(config) where image.name != except {
        do {
          if let other = try ImageManifest.loadIfPresent(config, image.name) {
            references.insert(other.imageRef)
            if let disk = other.disk { disks.insert(disk.name.rawValue) }
          }
        } catch {
          diagnostics.warn(
            "Keeping image content: manifest for '\(image.name)' is unreadable: \(oneLine(error))")
          return
        }
      }
    } catch {
      diagnostics.warn("Keeping image content: cannot list images: \(oneLine(error))")
      return
    }
    if let disk = manifest.disk, disk.name.belongs(to: owner.id),
      !disks.contains(disk.name.rawValue)
    {
      runtime.deleteDiskBestEffort(disk.name.rawValue, diagnostics: diagnostics)
    }
    if manifest.imageRef.hasPrefix(BuildContext.ownedRepository(owner.id)),
      !references.contains(manifest.imageRef)
    {
      runtime.deleteImageBestEffort(manifest.imageRef, diagnostics: diagnostics)
    }
  }

  /// A manifest exists and the runtime still holds what it names.
  package func imageIsBuilt(_ image: ImageName) -> Bool {
    guard let manifest = try? ImageManifest.loadIfPresent(config, image),
      let runtime = try? runtime()
    else {
      return false
    }
    return (try? runtime.verifyImage(manifest)) != nil
  }

  // MARK: Resize, commit, restore

  package struct Stopped: Sendable {
    package let instance: Instance
    package let sidecar: MachineSidecar
  }

  package func asStopped(_ instance: Instance) throws -> Stopped {
    let sidecar = try MachineSidecar.load(instance)
    let status = try runtime().inspect(sidecar.machineID).status
    switch status {
    case .stopped: return Stopped(instance: instance, sidecar: sidecar)
    case .running:
      throw HostError(
        "Instance '\(instance.name)' is running — stop it first with `iso stop \(instance.name)`")
    default:
      throw RuntimeError.operationUncertain("sandbox \(sidecar.machineID) is \(status.rawValue)")
    }
  }

  /// `<runtime root>/sandboxes/<machine>/rootfs.ext4`.
  package func diskPath(_ stopped: Stopped) throws -> String {
    IsolationGate.rootfsPath(runtimeRoot: try runtime().root, sandbox: stopped.sidecar.machineID)
  }

  package func currentDiskGiB(_ stopped: Stopped) throws -> UInt64 {
    let path = try diskPath(stopped)
    var status = stat()
    guard stat(path, &status) == 0 else { throw HostError.posix("Failed to stat", path) }
    let gib = UInt64(status.st_size) / (1 << 30)
    guard gib > 0 else { throw HostError("Disk at \(path) is smaller than 1 GiB") }
    return gib
  }

  /// Grow a stopped instance's disk (offline, by the runtime's maintenance
  /// VM). Not journaled: the runtime publishes the grown disk atomically.
  package func resizeDisk(_ stopped: Stopped, toGiB newSize: UInt64) throws {
    let instance = stopped.instance
    let runtime = try runtime()
    _ = try runtime.requireQualified()
    let lock = try InstanceStore.lock(instance)
    defer { lock.release() }
    let sidecar = try ownedSidecar(instance)
    let inspection = try requireStopped(runtime, instance, sidecar)
    let wanted = newSize * (1 << 30)
    if wanted == inspection.record.diskBytes { return }
    guard wanted > inspection.record.diskBytes else {
      throw HostError(
        "Instance '\(instance.name)' has a \(inspection.record.diskBytes / (1 << 30)) GiB disk; shrinking is not supported"
      )
    }
    let operation = try OperationID("iso-" + randomHex(8))
    do {
      try runtime.grow(sidecar.machineID, diskGiB: newSize, operation: operation)
    } catch let growError {
      let after: SandboxInspection
      do { after = try runtime.inspect(sidecar.machineID) } catch {
        throw RuntimeError.operationUncertain(
          "growing sandbox \(sidecar.machineID) reported failure (\(growError)) and its record could not be read (\(error)); check `iso status \(instance.name)`"
        )
      }
      guard after.record.lastOperation == operation else { throw growError }
      throw RuntimeError.operationUncertain(
        "growing sandbox \(sidecar.machineID) reported failure (\(growError)), but the runtime committed it; check `iso status \(instance.name)`"
      )
    }
    let after = try runtime.inspect(sidecar.machineID)
    guard after.record.lastOperation == operation, after.record.diskBytes == wanted else {
      throw RuntimeError.operationUncertain(
        "sandbox \(sidecar.machineID) reports a \(after.record.diskBytes) byte disk (last operation \(after.record.lastOperation?.rawValue ?? "none")) after growing to \(wanted)"
      )
    }
    diagnostics.log(.info, "Grew instance '\(instance.name)' disk to \(newSize) GiB")
  }

  package struct ResourceUpdate: Sendable {
    let operation: OperationID
    let prior: Resources
    let applied: Resources
  }

  package func setMachineResources(
    _ stopped: Stopped, memoryMiB: UInt32?, vcpus: UInt8?, startAfter: Bool
  ) throws {
    let runtime = try runtime()
    _ = try runtime.requireQualified()
    let owner = try Owner.load(config)
    let forward = try updateResources(runtime, stopped.instance, owner: owner, undo: nil) { prior in
      Resources(
        cpus: vcpus.map(UInt32.init) ?? prior.cpus,
        memoryBytes: memoryMiB.map { UInt64($0) * (1 << 20) } ?? prior.memoryBytes)
    }
    guard startAfter else { return }
    do {
      try startExisting(stopped.instance)
    } catch let startError {
      do {
        _ = try updateResources(runtime, stopped.instance, owner: owner, undo: forward) { _ in
          forward.prior
        }
      } catch let rollback {
        throw RuntimeError.operationUncertain(
          "Instance '\(stopped.instance.name)' failed to start with \(forward.applied) (\(oneLine(startError))), and restoring the previous \(forward.prior) did not complete (\(oneLine(rollback))); check `iso status \(stopped.instance.name)` before retrying"
        )
      }
      throw ContextError(
        "Instance failed to start with the new resources; previous \(forward.prior) restored",
        cause: startError)
    }
  }

  func updateResources(
    _ runtime: SandboxRuntime, _ instance: Instance, owner: Owner, undo: ResourceUpdate?,
    target targetFor: (Resources) -> Resources
  ) throws -> ResourceUpdate {
    let lock = try InstanceStore.lock(instance)
    defer { lock.release() }
    try recoverJournal(runtime, instance)
    var sidecar = try ownedSidecar(instance)
    let inspection = try requireStopped(runtime, instance, sidecar)
    let prior = Resources(cpus: inspection.record.cpus, memoryBytes: inspection.record.memoryBytes)
    if let undo {
      guard inspection.record.lastOperation == undo.operation, prior == undo.applied,
        sidecar.resources == undo.applied
      else {
        throw RuntimeError.operationUncertain(
          "sandbox \(sidecar.machineID) changed after the update to \(undo.applied) (now \(prior), last operation \(inspection.record.lastOperation?.rawValue ?? "none")); not rolling back over the newer change"
        )
      }
    }
    let target = targetFor(prior)
    let operation = try OperationID("iso-" + randomHex(8))
    _ = try Journal.begin(
      instance, owner: owner, op: .setResources(operation: operation, prior: prior),
      machine: sidecar.machineID)
    try runtime.setResources(
      sidecar.machineID, cpus: target.cpus, memoryBytes: target.memoryBytes, operation: operation,
      expect: undo?.operation)
    let after = try runtime.inspect(sidecar.machineID)
    let now = Resources(cpus: after.record.cpus, memoryBytes: after.record.memoryBytes)
    guard after.record.lastOperation == operation, now == target else {
      throw RuntimeError.operationUncertain(
        "sandbox \(sidecar.machineID) reports \(now) (last operation \(after.record.lastOperation?.rawValue ?? "none")) after the update to \(target); run `iso start \(instance.name)` to finish it"
      )
    }
    sidecar.requestedCPUs = target.cpus
    sidecar.requestedMemoryBytes = target.memoryBytes
    try sidecar.save(instance)
    try Journal.complete(instance)
    return ResourceUpdate(operation: operation, prior: prior, applied: target)
  }

  /// Save a stopped instance's disk (identity stripped by the runtime) as a
  /// reusable image.
  package func commitDisk(_ stopped: Stopped, image: ImageName) throws {
    let instance = stopped.instance
    let runtime = try runtime()
    _ = try runtime.requireQualified()
    let owner = try Owner.load(config)
    let lock = try InstanceStore.lock(instance)
    defer { lock.release() }
    let sidecar = try ownedSidecar(instance)
    let inspection = try requireStopped(runtime, instance, sidecar)
    let disk = try MachineName.generate(for: owner.id, randomHex: randomHex(8))
    let committed: RuntimeDisk
    do {
      committed = try runtime.commit(sidecar.machineID, disk: disk)
    } catch {
      runtime.deleteDiskBestEffort(disk.rawValue, diagnostics: diagnostics)
      throw ContextError(
        "committing '\(instance.name)' failed; its disk was discarded and no image was saved",
        cause: error)
    }
    let previous = ImageManifest.loadLenient(config, image, diagnostics: diagnostics)
    let manifest = ImageManifest(
      schemaVersion: StateSchema.version, backend: StateSchema.backend,
      imageRef: inspection.record.imageReference,
      digest: inspection.record.imageDigest, disk: .init(name: disk, bytes: committed.logicalBytes),
      manifestID: "commit-\(disk)", baseImage: BuildContext.baseImage,
      platform: BuildContext.platform,
      guestUser: sidecar.guestUser, created: utcTimestamp())
    do { try manifest.save(config, image) } catch {
      runtime.deleteDiskBestEffort(disk.rawValue, diagnostics: diagnostics)
      throw error
    }
    if let previous { releaseManifest(runtime, owner: owner, manifest: previous, except: nil) }
  }

  /// Replace a stopped instance's disk with an image's. Journaled; the next
  /// start re-enrolls the host key (the new disk has none).
  package func restoreDisk(_ stopped: Stopped, image: ImageName) throws {
    let instance = stopped.instance
    let runtime = try runtime()
    _ = try runtime.requireQualified()
    let owner = try Owner.load(config)
    let manifest = try ImageManifest.load(config, image)
    try runtime.verifyImage(manifest)
    let lock = try InstanceStore.lock(instance)
    defer { lock.release() }
    try recoverJournal(runtime, instance)
    var sidecar = try ownedSidecar(instance)
    let inspection = try requireStopped(runtime, instance, sidecar)
    guard manifest.guestUser == sidecar.guestUser else {
      throw HostError(
        "Image '\(image)' was built for guest user '\(manifest.guestUser)', but instance '\(instance.name)' uses '\(sidecar.guestUser)'; create a new instance from it instead"
      )
    }
    let operation = try OperationID("iso-" + randomHex(8))
    let prior = inspection.record.diskGeneration
    _ = try Journal.begin(
      instance, owner: owner, op: .restoreDisk(operation: operation, priorGeneration: prior),
      machine: sidecar.machineID)
    let source: SandboxRuntime.Source =
      manifest.disk.map { .disk($0.name) } ?? .image(manifest.imageRef)
    try runtime.restore(sidecar.machineID, source: source, operation: operation)
    let after = try runtime.inspect(sidecar.machineID)
    guard after.record.diskGeneration > prior, after.record.lastOperation == operation else {
      throw RuntimeError.operationUncertain(
        "sandbox \(sidecar.machineID) did not report this restore as its disk; run `iso start \(instance.name)` to finish it"
      )
    }
    sidecar.imageRef = after.record.imageReference
    sidecar.imageDigest = after.record.imageDigest
    sidecar.imageManifestID = manifest.manifestID
    sidecar.reenrollHostKey = true
    try sidecar.save(instance)
    try Journal.complete(instance)
  }
}
