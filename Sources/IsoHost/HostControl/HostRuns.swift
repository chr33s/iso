import Foundation
import IsoConfiguration
import IsoCore

/// Disposable-run admission and execution (spec 12). Child VM work uses the
/// ordinary lifecycle ledger under identities reserved at `run.create`.
extension HostSupervisor {
  func admitRunCreate(
    _ record: inout OperationStore.OperationRecord, run: RunID, spec: VMSpec, outputLimit: UInt64,
    ttl: UInt64, transport: HostTransportKind, qualification: RuntimeQualification
  ) throws(HostControlError) -> OperationReceipt {
    if (try? runs.load(run)) != nil {
      throw HostControlError(
        .instanceBusy, "run id already exists under another operation",
        retry: .explicitIdentityResolution, details: ["run_id": run.rawValue])
    }
    guard outputLimit > 0, outputLimit <= RunStore.maxOutputBytes else {
      throw .invalidRequest("output_limit_bytes must be 1-\(RunStore.maxOutputBytes)")
    }
    let maxTTL = transport == .ssh ? settings.remoteMaxTTL : UInt64.max
    guard ttl > 0, ttl <= maxTTL else { throw .invalidRequest("ttl_seconds is out of range") }
    // One slot per run from creation until verified cleanup (spec 12.3).
    guard runs.slotsInUse() < RunStore.retentionSlots else {
      throw HostControlError(.limitExceeded, "all result-retention slots are in use")
    }
    // Parent + finalize, child create (6), child start (4), run transitions (6).
    try requireCapacity(18)
    let createID = HostOperationID.generate()
    let startID = HostOperationID.generate()
    var child = OperationStore.OperationRecord(
      operationID: createID, method: HostMethod.vmCreate.rawValue,
      digest: HostRequest(
        hostID: hostID, ownerID: ownerID, operationID: createID, body: .vmCreate(spec)
      ).digest,
      params: String(decoding: HostWire.canonical(spec.wire), as: UTF8.self),
      transport: record.transport, acceptedAt: now.seconds, state: .accepted, substep: nil,
      cancelRequested: false)
    child.runID = run
    let created = try admitCreateLocked(
      &child, spec: spec, transport: transport, qualification: qualification)
    let runRecord = RunStore.Record(
      runID: run, createdBy: record.operationID, generation: 1, phase: .reserved,
      outputLimit: outputLimit, ttlSeconds: ttl, createOperation: createID, startOperation: startID,
      instanceID: created.instance?.instanceID, runtimeID: created.instance?.runtimeID,
      startedAt: nil, artifact: nil, artifactDigest: nil, firstStopAt: nil, retentionDeadline: nil,
      recoveryUsed: false, recoveryDeadline: nil, exitStatus: nil, disposition: nil,
      deliveredStage: nil, activeOperation: record.operationID)
    record.runID = run
    record.instanceID = created.instance?.instanceID
    record.runtimeID = created.instance?.runtimeID
    let parent = record
    do {
      try persist { () throws(HostError) in
        try store.reserve(.run(run))
        try store.reserve(.finalize(parent.operationID))
        try runs.save(runRecord)
        // The parent is the commit point; it is written last.
        try store.saveOperation(parent)
      }
    } catch {
      // The child create is never executed without its run; undo it.
      discardUnacceptedRun(run, child: createID, instance: created.instance?.instanceID)
      try? store.consume(.finalize(parent.operationID))
      throw error
    }
    return record.receipt(disposition: .accepted, instance: created.instance)
  }

  /// Removes a run whose creation was never accepted and its child create,
  /// which never executed (a run child executes only from its run).
  func discardUnacceptedRun(_ run: RunID, child: HostOperationID, instance: InstanceID?) {
    try? store.removeOperation(child)
    try? store.consume(.finalize(child))
    if let instance {
      try? store.removeInstance(instance)
      try? store.consume(.destroy(instance))
    }
    try? runs.remove(run)
    try? store.consume(.run(run))
  }

  /// Run admissions that a crash left half-written: a run whose parent
  /// operation is missing, or a never-started run child with no run record.
  /// Called under the admission lock.
  func repairUnacceptedRuns() {
    for id in runs.runIDs() {
      guard let run = try? runs.load(id), run.phase == .reserved,
        let parent = run.activeOperation, parent == run.createdBy
      else { continue }
      let missing: Bool
      do { missing = try store.loadOperation(parent) == nil } catch { continue }
      guard missing else { continue }
      discardUnacceptedRun(id, child: run.createOperation, instance: run.instanceID)
      try? store.consume(.finalize(parent))
    }
    for id in store.operationIDs() {
      guard let child = try? store.loadOperation(id), let run = child.runID,
        child.method == HostMethod.vmCreate.rawValue, child.state == .accepted,
        child.substep == nil, let instance = child.instanceID,
        (try? store.loadInstance(instance))?.lifecycle == .creating
      else { continue }
      let missing: Bool
      do { missing = try runs.load(run) == nil } catch { continue }
      guard missing else { continue }
      discardUnacceptedRun(run, child: id, instance: child.instanceID)
    }
  }

  func admitRunTransition(
    _ record: inout OperationStore.OperationRecord, run id: RunID, generation: UInt64,
    body: HostRequestBody
  ) throws(HostControlError) -> OperationReceipt {
    guard var run = try? runs.load(id) else {
      throw HostControlError(.resultsUnavailable, "unknown run", details: ["run_id": id.rawValue])
    }
    if let active = run.activeOperation { throw busy(active) }
    guard run.generation == generation else {
      throw HostControlError(
        .generationConflict, "expected run generation is stale",
        details: ["generation": String(run.generation)])
    }
    switch body {
    case .runComplete(_, _, let status):
      guard run.phase == .running else { throw wrongPhase(run) }
      run.exitStatus = status
    case .runResultsRecover:
      guard run.phase == .stoppedDiskPendingExport else { throw wrongPhase(run) }
      guard !run.recoveryUsed else {
        throw HostControlError(.resultsUnavailable, "this run's one recovery boot was already used")
      }
      guard let instanceID = run.instanceID, let instance = try? store.loadInstance(instanceID),
        let spec = decodeSpec(instance.spec)
      else { throw HostControlError(.resultsUnavailable, "the run's VM is gone") }
      guard spec.egress.requiresHostOnlyNetwork else {
        throw .unsupported("result recovery for a run with open egress")
      }
      guard let retention = run.retentionDeadline else { throw wrongPhase(run) }
      let deadline = min(now.seconds + RunStore.recoveryTTLSeconds, retention)
      guard deadline > now.seconds + 30 else {
        throw HostControlError(.resultsUnavailable, "too little retention time remains to recover")
      }
      // The allowance and its deadline are durable before any boot.
      run.recoveryUsed = true
      run.recoveryDeadline = deadline
      run.phase = .recovering
      run.generation += 1
    case .runResultsAck(_, _, let digest, let stage):
      guard run.phase == .resultsPending else { throw wrongPhase(run) }
      guard run.artifactDigest == digest else {
        throw .invalidRequest("acknowledged digest does not match the retained results")
      }
      run.deliveredStage = stage
    case .runResultsDiscard:
      switch run.phase {
      case .resultsPending, .stoppedDiskPendingExport, .failedWithResources: break
      default: throw wrongPhase(run)
      }
    default:
      throw .invalidRequest("not a run transition")
    }
    record.runID = id
    record.instanceID = run.instanceID
    record.runtimeID = run.runtimeID
    run.activeOperation = record.operationID
    let accepted = record
    let updated = run
    try persist { () throws(HostError) in
      // Transitions draw on the run's own reservation, not ordinary capacity.
      try store.shrink(.run(id), by: 2)
      try store.saveOperation(accepted)
      try runs.save(updated)
    }
    return record.receipt(disposition: .accepted, instance: qualified(record))
  }

  private func wrongPhase(_ run: RunStore.Record) -> HostControlError {
    HostControlError(
      .resultsUnavailable, "run is \(run.phase.rawValue)",
      retry: .refreshObservationThenNewOperation, details: ["run_id": run.runID.rawValue])
  }

  // MARK: - Execution

  func executeRun(_ accepted: OperationStore.OperationRecord) {
    guard let runID = accepted.runID, var run = try? runs.load(runID) else {
      return finish(accepted, .failed, outcome: "run record is missing")
    }
    let method = HostMethod(rawValue: accepted.method)
    guard let record = beginEffect(accepted.operationID, substep: method?.rawValue ?? "run") else {
      return
    }
    switch method {
    case .runCreate:
      driveRunCreation(record, &run)
    case .runComplete:
      run.phase = .exporting
      saveRun(&run, bump: true)
      exportAndStop(&run, recovering: false)
      run.activeOperation = nil
      saveRun(&run, bump: false)
      finish(record, .succeeded, outcome: run.phase.rawValue)
    case .runResultsRecover:
      recover(&run)
      run.activeOperation = nil
      saveRun(&run, bump: false)
      finish(record, .succeeded, outcome: run.phase.rawValue)
    case .runResultsAck, .runResultsDiscard:
      let disposition = method == .runResultsAck ? "delivered" : "discarded"
      if destroyRun(&run, disposition: disposition, by: record.operationID) {
        finish(record, .succeeded, outcome: disposition)
      } else {
        reconcileLater(record, "run resources are not yet verified deleted")
      }
    default:
      finish(record, .failed, outcome: "not a run operation")
    }
  }

  private func driveRunCreation(
    _ record: OperationStore.OperationRecord, _ run: inout RunStore.Record
  ) {
    run.phase = .creating
    saveRun(&run, bump: false)
    execute(run.createOperation, asRunChild: true)
    guard let create = try? store.loadOperation(run.createOperation) else {
      return reconcileLater(record, "child create record is missing")
    }
    switch create.state {
    case .succeeded: break
    case .failed, .cancelled:
      let remaining = run.instanceID.flatMap { try? store.loadInstance($0) } != nil
      run.phase = remaining ? .failedWithResources : .destroyed
      // Leftover resources get the same fixed retention as results, so an
      // absent client cannot hold the slot forever.
      if remaining { startRetention(&run) }
      run.disposition = "create_failed"
      run.activeOperation = nil
      if !remaining { releaseRunSlot(&run) }
      saveRun(&run, bump: true)
      return finish(record, .failed, outcome: create.outcome ?? "child create failed")
    default:
      return reconcileLater(record, "child create is reconciling")
    }
    if (try? store.loadOperation(run.startOperation)) == nil {
      guard let instanceID = run.instanceID, let instance = try? store.loadInstance(instanceID),
        let policy = instance.policyHash
      else { return reconcileLater(record, "child instance record is missing") }
      let body = HostRequestBody.vmStart(
        instance.qualified, expectedGeneration: instance.generation, ttlSeconds: run.ttlSeconds,
        policy: policy)
      var start = OperationStore.OperationRecord(
        operationID: run.startOperation, method: HostMethod.vmStart.rawValue,
        digest: HostRequest(
          hostID: hostID, ownerID: ownerID, operationID: run.startOperation, body: body
        ).digest,
        params: String(decoding: HostWire.canonical(body.params), as: UTF8.self),
        transport: record.transport, acceptedAt: now.seconds, state: .accepted, substep: nil,
        cancelRequested: false)
      start.runID = run.runID
      start.instanceID = instanceID
      start.runtimeID = instance.runtimeID
      start.deadline = now.adding(seconds: run.ttlSeconds).seconds
      var updated = instance
      updated.activeOperation = start.operationID
      updated.runID = run.runID
      let accepted = start
      do {
        try store.reserve(.stop(instanceID))
        try store.reserve(.finalize(accepted.operationID))
        try store.saveOperation(accepted)
        try store.saveInstance(updated)
      } catch {
        return reconcileLater(record, "child start could not be recorded")
      }
    }
    execute(run.startOperation, asRunChild: true)
    guard let start = try? store.loadOperation(run.startOperation) else {
      return reconcileLater(record, "child start record is missing")
    }
    switch start.state {
    case .succeeded:
      run.phase = .running
      run.startedAt = now.seconds
      run.activeOperation = nil
      saveRun(&run, bump: true)
      finish(record, .succeeded, outcome: "running")
    case .failed, .cancelled:
      run.phase = .failedWithResources
      startRetention(&run)
      run.disposition = "start_failed"
      run.activeOperation = nil
      saveRun(&run, bump: true)
      finish(record, .failed, outcome: start.outcome ?? "child start failed")
    default:
      reconcileLater(record, "child start is reconciling")
    }
  }

  /// Captures results from the running guest, then stops and verifies.
  /// Publishes `results_pending` only for a committed artifact plus a
  /// verified stop; otherwise `stopped_disk_pending_export`.
  private func exportAndStop(_ run: inout RunStore.Record, recovering: Bool) {
    guard let instanceID = run.instanceID, let runtime = run.runtimeID else { return }
    var committed = false
    let instance = try? store.loadInstance(instanceID)
    let expired = instance?.expiresAt.map { now.seconds >= $0 } ?? false
    let recoveryExpired = recovering && (run.recoveryDeadline.map { now.seconds >= $0 } ?? true)
    if !expired && !recoveryExpired,
      let bytes = try? native.exportResults(instanceID, runtime: runtime, limit: run.outputLimit),
      (try? ArchiveValidator.validate(bytes: bytes)) != nil
    {
      committed = commitResults(&run, bytes)
    }
    guard stopRunVM(&run) else { return }
    if committed {
      run.phase = .resultsPending
    } else {
      run.phase = .stoppedDiskPendingExport
      if recovering { run.disposition = "export_failed" }
    }
    saveRun(&run, bump: true)
  }

  private func commitResults(_ run: inout RunStore.Record, _ bytes: [UInt8]) -> Bool {
    let digest = HostWire.sha256(bytes)
    guard
      let record = try? artifacts.create(
        owner: ownerID, kind: .runResult, size: UInt64(bytes.count), digest: digest)
    else { return false }
    var offset = 0
    while offset < bytes.count {
      let end = min(offset + HostRequestBody.maxArtifactChunk, bytes.count)
      guard
        (try? artifacts.write(
          owner: ownerID, handle: record.handle, offset: UInt64(offset),
          bytes: Array(bytes[offset..<end]))) != nil
      else { return false }
      offset = end
    }
    guard (try? artifacts.commit(owner: ownerID, handle: record.handle)) != nil,
      (try? artifacts.retain(owner: ownerID, handle: record.handle, by: run.runID.rawValue)) != nil
    else { return false }
    run.artifact = record.handle
    run.artifactDigest = digest
    return true
  }

  /// Stops through the runtime; records the first verified stop and the
  /// fixed retention deadline that never moves afterwards.
  /// Stops the run's VM. True only once the stop is observed; otherwise the
  /// run stays `.stopping` and the next reconcile pass retries it.
  @discardableResult
  private func stopRunVM(_ run: inout RunStore.Record) -> Bool {
    guard let instanceID = run.instanceID, let runtime = run.runtimeID else { return false }
    run.phase = .stopping
    // A stop that is never verified (a crashed VM refusing it) must not hold
    // the run's retention slot forever: retention also bounds `.stopping`.
    if run.retentionDeadline == nil {
      run.retentionDeadline = now.seconds + RunStore.retentionSeconds
    }
    saveRun(&run, bump: false)
    sessions.revoke(instance: instanceID)
    if (try? native.observe(instanceID, runtime: runtime)) != .stopped {
      try? native.stop(instanceID, runtime: runtime)
    }
    // An absent VM can no longer run, so it counts as stopped.
    let observed = try? native.observe(instanceID, runtime: runtime)
    guard observed == .stopped || observed == .absent else { return false }
    // Re-checked under the admission lock so a concurrent deadline sweep
    // cannot commit the same transition twice.
    state.withLock { _ in
      if var instance = try? store.loadInstance(instanceID), instance.lifecycle != .stopped {
        instance.lifecycle = .stopped
        instance.bootID = nil
        instance.expiresAt = nil
        instance.generation += 1
        try? store.saveInstance(instance)
      }
    }
    if run.firstStopAt == nil {
      run.firstStopAt = now.seconds
      run.retentionDeadline = now.seconds + RunStore.retentionSeconds
    }
    return true
  }

  private func recover(_ run: inout RunStore.Record) {
    guard let instanceID = run.instanceID, let runtime = run.runtimeID,
      let deadline = run.recoveryDeadline
    else { return }
    if (try? native.observe(instanceID, runtime: runtime)) == .stopped {
      do {
        try native.start(instanceID, runtime: runtime, expiresAt: WireTime(seconds: deadline).date)
      } catch {
        run.disposition = "recovery_boot_failed"
        if stopRunVM(&run) { run.phase = .stoppedDiskPendingExport }
        return saveRun(&run, bump: true)
      }
    }
    if var instance = try? store.loadInstance(instanceID),
      case .running(let boot, _, _)? = try? native.observe(instanceID, runtime: runtime)
    {
      instance.lifecycle = .running
      instance.bootID = boot
      instance.expiresAt = deadline
      instance.generation += 1
      try? store.saveInstance(instance)
    }
    exportAndStop(&run, recovering: true)
  }

  /// Deletes the exact owned VM and retained artifact. The client's
  /// completed stage is never a deletion condition and never touched.
  @discardableResult
  func destroyRun(_ run: inout RunStore.Record, disposition: String, by operation: HostOperationID)
    -> Bool
  {
    if let instanceID = run.instanceID, let instance = try? store.loadInstance(instanceID) {
      guard destroyNow(instance, by: operation) else { return false }
    }
    if let artifact = run.artifact {
      try? artifacts.release(owner: ownerID, handle: artifact, by: run.runID.rawValue)
    }
    run.phase = .destroyed
    run.disposition = disposition
    run.activeOperation = nil
    releaseRunSlot(&run)
    saveRun(&run, bump: true)
    return true
  }

  private func startRetention(_ run: inout RunStore.Record) {
    guard run.retentionDeadline == nil else { return }
    run.firstStopAt = run.firstStopAt ?? now.seconds
    run.retentionDeadline = now.seconds + RunStore.retentionSeconds
  }

  private func releaseRunSlot(_ run: inout RunStore.Record) {
    try? store.consume(.run(run.runID))
  }

  /// Stop, delete, verify absence and commit the tombstone.
  func destroyNow(_ instance: OperationStore.InstanceRecord, by operation: HostOperationID) -> Bool
  {
    let id = instance.instanceID
    let runtime = instance.runtimeID
    sessions.revoke(instance: id)
    do {
      switch try native.observe(id, runtime: runtime) {
      case .running: try native.stop(id, runtime: runtime)
      // A crashed VM may refuse a stop; deleting it removes it regardless.
      case .unhealthy: try? native.stop(id, runtime: runtime)
      case .stopped, .absent: break
      }
      try native.delete(id, runtime: runtime, owner: ownerID)
      guard try native.observe(id, runtime: runtime) == .absent else { return false }
      let tombstone = OperationStore.Tombstone(
        hostID: hostID, ownerID: ownerID, instanceID: id, runtimeID: runtime,
        guestOS: instance.guestOS, name: instance.name, terminalGeneration: instance.generation + 1,
        destroyedBy: operation, destroyedAt: now.seconds, createdBy: instance.createdBy,
        disposition: "destroyed")
      try store.consume(.destroy(id))
      try store.saveTombstone(tombstone)
      try store.removeInstance(id)
      try? store.consume(.stop(id))
      return true
    } catch {
      return false
    }
  }

  /// Periodic run safety: controller loss, VM deadline and retention expiry.
  func reconcileRun(_ id: RunID) {
    // Claim the run so no transition is admitted while this pass rewrites it.
    let claimed: RunStore.Record? = state.withLock { state in
      guard let run = try? runs.load(id), run.activeOperation == nil,
        state.runsBusy.insert(id).inserted
      else { return nil }
      return run
    }
    guard var run = claimed else { return }
    defer { _ = state.withLock { $0.runsBusy.remove(id) } }
    switch run.phase {
    case .running:
      guard let instanceID = run.instanceID, let started = run.startedAt else { return }
      let controlled =
        now.seconds < started + RunStore.controllerGraceSeconds
        || sessions.hasLiveSession(instance: instanceID)
      let instance = try? store.loadInstance(instanceID)
      let expired = instance?.expiresAt.map { now.seconds >= $0 } ?? false
      let observed = run.runtimeID.flatMap { try? native.observe(instanceID, runtime: $0) }
      if !controlled || expired || observed == .stopped {
        // Lease or deadline lost: stop now; no implicit stopped-disk export.
        if stopRunVM(&run) {
          run.phase = run.artifact == nil ? .stoppedDiskPendingExport : .resultsPending
          saveRun(&run, bump: true)
        }
      }
    case .stopping:
      if stopRunVM(&run) {
        run.phase = run.artifact == nil ? .stoppedDiskPendingExport : .resultsPending
        saveRun(&run, bump: true)
      } else if let deadline = run.retentionDeadline, now.seconds >= deadline {
        destroyRun(&run, disposition: "retention_expired", by: run.createdBy)
      }
    case .resultsPending, .stoppedDiskPendingExport, .recovering, .failedWithResources:
      let deadline =
        run.retentionDeadline ?? (run.firstStopAt.map { $0 + RunStore.retentionSeconds })
      if let deadline, now.seconds >= deadline {
        destroyRun(&run, disposition: "retention_expired", by: run.createdBy)
      } else if run.phase == .recovering,
        let recovery = run.recoveryDeadline, now.seconds >= recovery
      {
        if stopRunVM(&run) {
          run.phase = .stoppedDiskPendingExport
          run.disposition = "export_failed"
          saveRun(&run, bump: true)
        }
      }
    case .reserved, .creating, .exporting, .destroyed:
      return
    }
  }

  func saveRun(_ run: inout RunStore.Record, bump: Bool) {
    if bump { run.generation += 1 }
    try? runs.save(run)
  }
}
