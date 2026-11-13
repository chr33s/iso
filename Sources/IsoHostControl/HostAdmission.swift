import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

/// Durable admission (spec 7.2): an accepted operation is recorded before its
/// first effect, and the operation record is the commit point.
extension HostSupervisor {
  func admit(
    _ request: HostRequest, operation: HostOperationID, transport: HostTransportKind
  )
    throws(HostControlError) -> OperationReceipt
  {
    let digest = request.digest
    let method = request.body.method
    // Duplicates are answered before any dynamic check (capability,
    // qualification, generation, lifecycle).
    if let existing = try loadOperation(operation) {
      guard existing.digest == digest, existing.method == method.rawValue else {
        throw HostControlError(
          .operationIDConflict, "operation id was used for a different request",
          details: ["operation_id": operation.rawValue])
      }
      if !existing.state.isTerminal { dispatch(operation) }
      return existing.receipt(disposition: .existing, instance: qualified(existing))
    }
    // Capability refusal precedes any image, resource or secret work.
    if method.isLocalOnly, !Self.methods(for: transport).contains(method) {
      throw .unsupported(
        method.rawValue + (transport == .ssh ? " on a remote host" : " through the host service"))
    }
    let params = String(decoding: HostWire.canonical(request.body.params), as: UTF8.self)
    // Asked before taking the admission lock: it runs the runtime CLI.
    let qualification: RuntimeQualification
    switch request.body {
    case .vmCreate, .vmStart, .runCreate, .imageEnsure: qualification = native.qualification()
    default: qualification = .qualified("not required")
    }
    // Only the worker's own verified image records satisfy a create, and a
    // requested image digest must be the one the worker has under that name.
    let imageReady: Bool
    let imageMatches: Bool
    switch request.body {
    case .vmCreate(let spec), .runCreate(_, let spec, _, _):
      imageReady = native.imageReady(spec.image)
      imageMatches =
        spec.imageDigest.map { requested in
          native.imageDigest(spec.image) == "sha256:" + requested.rawValue
        } ?? true
    default:
      imageReady = true
      imageMatches = true
    }
    let receipt: OperationReceipt = try state.withLock {
      (locked) throws(HostControlError) -> OperationReceipt in
      // Re-check under the admission lock: a concurrent frontend may have won.
      if let raced = try loadOperation(operation) {
        guard raced.digest == digest, raced.method == method.rawValue else {
          throw HostControlError(
            .operationIDConflict, "operation id was used for a different request")
        }
        return raced.receipt(disposition: .existing, instance: qualified(raced))
      }
      // A retry of an attempt whose operation was never written: its
      // half-written create, if any, is discarded before this one allocates.
      discardUnacceptedCreate(operation)
      var record = OperationStore.OperationRecord(
        operationID: operation, method: method.rawValue, digest: digest, params: params,
        transport: transport.rawValue, acceptedAt: now.seconds, state: .accepted, substep: nil,
        cancelRequested: false)
      switch request.body {
      case .vmCreate(let spec):
        guard imageReady else { throw imageNotPrepared(spec.image) }
        guard imageMatches else { throw imageDigestDiffers(spec.image) }
        return try admitCreateLocked(
          &record, spec: spec, transport: transport, qualification: qualification)
      case .maintenance(let instance, let generation, let change):
        return try admitMaintenance(&record, instance, generation: generation, change)
      case .imageEnsure(let image):
        return try admitImage(
          &record, image, transport: transport, qualification: qualification, state: &locked)
      case .vmStart(let instance, let generation, let ttl, let policy):
        return try admitStart(
          &record, instance, generation: generation, ttl: ttl, policy: policy, transport: transport,
          qualification: qualification)
      case .vmStop(let instance, let generation):
        return try admitCleanup(
          &record, instance, generation: generation, kind: .stop, executing: locked.executing)
      case .vmDestroy(let instance, let generation):
        return try admitCleanup(
          &record, instance, generation: generation, kind: .destroy, executing: locked.executing)
      case .runCreate(let run, let spec, let output, let ttl):
        guard imageReady else { throw imageNotPrepared(spec.image) }
        guard imageMatches else { throw imageDigestDiffers(spec.image) }
        return try admitRunCreate(
          &record, run: run, spec: spec, outputLimit: output, ttl: ttl, transport: transport,
          qualification: qualification)
      case .runComplete(let run, let generation, _), .runResultsRecover(let run, let generation),
        .runResultsAck(let run, let generation, _, _), .runResultsDiscard(let run, let generation):
        guard !locked.runsBusy.contains(run) else {
          throw HostControlError(.instanceBusy, "the run is being reconciled; retry shortly")
        }
        return try admitRunTransition(&record, run: run, generation: generation, body: request.body)
      case .runRetain(let run, let generation, let mode, _):
        guard !locked.runsBusy.contains(run) else {
          throw HostControlError(.instanceBusy, "the run is being reconciled; retry shortly")
        }
        return try admitRunRetain(&record, run: run, generation: generation, mode: mode)
      default:
        throw .unsupported(method.rawValue)
      }
    }
    if receipt.disposition == .accepted { dispatch(operation) }
    return receipt
  }

  func admitMaintenance(
    _ record: inout OperationStore.OperationRecord, _ target: QualifiedInstance, generation: UInt64,
    _ change: Maintenance
  ) throws(HostControlError) -> OperationReceipt {
    var instance = try authoritative(target)
    guard instance.runID == nil else { throw .unsupported("maintenance of a run's VM") }
    if let active = try liveActiveOperation(instance) { throw busy(active) }
    guard instance.generation == generation else { throw generationConflict(instance) }
    guard instance.lifecycle == .stopped else {
      throw HostControlError(
        .instanceBusy, "\(change.method.rawValue) needs a stopped instance",
        retry: .refreshObservationThenNewOperation)
    }
    try requireCapacity(2)
    record.instanceID = instance.instanceID
    record.runtimeID = instance.runtimeID
    instance.activeOperation = record.operationID
    let accepted = record
    let updated = instance
    try persist { () throws(HostError) in
      try store.reserve(.finalize(accepted.operationID))
      try store.saveInstance(updated)
      try store.saveOperation(accepted)
    }
    return record.receipt(disposition: .accepted, instance: instance.qualified)
  }

  /// The native journals underneath converge to the requested postcondition,
  /// so a reconciling pass repeats the change rather than guessing.
  func executeMaintenance(_ accepted: OperationStore.OperationRecord) {
    guard let instanceID = accepted.instanceID, let runtime = accepted.runtimeID,
      var instance = try? store.loadInstance(instanceID),
      let value = try? HostWire.parse(Array(accepted.params.utf8), limits: HostWire.requestLimits),
      let method = HostMethod(rawValue: accepted.method),
      case .maintenance(_, _, let change)? = try? HostRequestBody(method: method, params: value)
    else { return finish(accepted, .failed, outcome: "maintenance record is incomplete") }
    if instance.activeOperation != accepted.operationID {
      return finish(accepted, .succeeded, outcome: nil, generation: instance.generation)
    }
    guard let record = beginEffect(accepted.operationID, substep: "maintaining") else { return }
    do {
      try native.maintain(instanceID, runtime: runtime, change)
    } catch {
      switch error {
      case .uncertain(let reason), .unavailable(let reason): return reconcileLater(record, reason)
      case .failed(let reason):
        instance.activeOperation = nil
        try? store.saveInstance(instance)
        return finish(record, .failed, outcome: reason)
      }
    }
    // Resource and image changes change the instance's policy identity.
    if let spec = decodeSpec(instance.spec), let updated = Self.applying(change, to: spec) {
      instance = instance.replacingSpec(
        String(decoding: HostWire.canonical(updated.wire), as: UTF8.self),
        policy: updated.policyHash)
    }
    instance.generation += 1
    instance.activeOperation = nil
    try? store.saveInstance(instance)
    finish(record, .succeeded, outcome: nil, generation: instance.generation)
  }

  static func applying(_ change: Maintenance, to spec: VMSpec) -> VMSpec? {
    switch change {
    case .commit: return nil
    case .resize(let cpus, let memory, let disk):
      return try? VMSpec.make(
        name: spec.name, image: spec.image, imageDigest: spec.imageDigest, cpus: cpus ?? spec.cpus,
        memoryMiB: memory ?? spec.memoryMiB, diskGiB: disk ?? spec.diskGiB, guestOS: spec.guestOS,
        egress: spec.egress)
    case .restore(let image):
      return try? VMSpec.make(
        name: spec.name, image: image, imageDigest: nil, cpus: spec.cpus, memoryMiB: spec.memoryMiB,
        diskGiB: spec.diskGiB, guestOS: spec.guestOS, egress: spec.egress)
    }
  }

  func imageNotPrepared(_ image: ImageName) -> HostControlError {
    HostControlError(
      .instanceIncompatible,
      "image '\(image)' is not prepared on this host; run image.ensure there first",
      retry: .refreshObservationThenNewOperation)
  }

  func imageDigestDiffers(_ image: ImageName) -> HostControlError {
    HostControlError(
      .instanceIncompatible,
      "image '\(image)' on this host is not the requested image_digest",
      retry: .refreshObservationThenNewOperation)
  }

  func admitImage(
    _ record: inout OperationStore.OperationRecord, _ request: ImageRequest,
    transport: HostTransportKind, qualification: RuntimeQualification, state: inout State
  ) throws(HostControlError) -> OperationReceipt {
    guard request.guestOS == .linux else {
      throw .unsupported(
        "macOS images" + (transport == .ssh ? " on a remote host" : " through the host service"))
    }
    try requireQualified(qualification)
    if let active = state.imagesBusy[request.image] { throw busy(active) }
    try requireCapacity(2)
    let accepted = record
    try persist { () throws(HostError) in
      try store.reserve(.finalize(accepted.operationID))
      try store.saveOperation(accepted)
    }
    state.imagesBusy[request.image] = record.operationID
    return record.receipt(disposition: .accepted, instance: nil)
  }

  /// Image work holds no lock while it builds; the build is idempotent by
  /// manifest, so reconciliation simply repeats it.
  func executeImage(_ accepted: OperationStore.OperationRecord) {
    guard
      let value = try? HostWire.parse(Array(accepted.params.utf8), limits: HostWire.requestLimits),
      case .imageEnsure(let request)? = try? HostRequestBody(method: .imageEnsure, params: value)
    else { return finish(accepted, .failed, outcome: "image record is incomplete") }
    // The image stays busy until its operation is terminal.
    defer {
      if (try? store.loadOperation(accepted.operationID))?.state.isTerminal ?? true {
        state.withLock { busy in
          if busy.imagesBusy[request.image] == accepted.operationID {
            busy.imagesBusy[request.image] = nil
          }
        }
      }
    }
    guard let record = beginEffect(accepted.operationID, substep: "building") else { return }
    do {
      let identity = try native.ensureImage(request)
      finish(record, .succeeded, outcome: "image \(request.image): \(identity)")
    } catch {
      switch error {
      case .failed(let reason): finish(record, .failed, outcome: reason)
      case .uncertain(let reason), .unavailable(let reason): reconcileLater(record, reason)
      }
    }
  }

  func freeSlots() -> Int { settings.ledger.maxSlots - store.usedSlots() }

  func requireCapacity(_ slots: Int) throws(HostControlError) {
    guard freeSlots() >= slots else {
      throw HostControlError(
        .limitExceeded, "the operation ledger is full; only exact cleanup is admitted")
    }
  }

  func requireQualified(_ qualification: RuntimeQualification) throws(HostControlError) {
    if case .unqualified(let reason) = qualification {
      throw HostControlError(.hostRuntimeUnqualified, reason)
    }
  }

  func admitCreateLocked(
    _ record: inout OperationStore.OperationRecord, spec: VMSpec, transport: HostTransportKind,
    qualification: RuntimeQualification
  ) throws(HostControlError) -> OperationReceipt {
    guard spec.guestOS == .linux else {
      throw .unsupported(
        "macOS guests" + (transport == .ssh ? " on a remote host" : " through the host service"))
    }
    guard spec.policyHash == spec.computedPolicyHash else {
      throw .invalidRequest("policy_hash does not match the requested shape")
    }
    try requireQualified(qualification)
    // Operation, finalize, instance record, destroy reservation (3).
    try requireCapacity(6)
    let instance = InstanceID.generate()
    let runtime: MachineName
    do { runtime = try MachineName.generate(for: ownerID, randomHex: randomHex(8)) } catch {
      throw .invalidRequest("could not reserve a runtime name")
    }
    record.instanceID = instance
    record.runtimeID = runtime
    let instanceRecord = OperationStore.InstanceRecord(
      hostID: hostID, ownerID: ownerID, instanceID: instance, runtimeID: runtime,
      guestOS: spec.guestOS, name: spec.name, spec: record.params, createdBy: record.operationID,
      generation: 0, lifecycle: .creating, bootID: nil, policyHash: spec.policyHash,
      expiresAt: nil, activeOperation: record.operationID, lastObservedAt: nil, runID: record.runID)
    try persist { () throws(HostError) in
      try store.reserve(.destroy(instance))
      try store.reserve(.finalize(record.operationID))
      try store.saveInstance(instanceRecord)
      try store.saveOperation(record)
    }
    return record.receipt(disposition: .accepted, instance: instanceRecord.qualified)
  }

  func admitStart(
    _ record: inout OperationStore.OperationRecord, _ target: QualifiedInstance, generation: UInt64,
    ttl: UInt64?, policy: SHA256Hex, transport: HostTransportKind,
    qualification: RuntimeQualification
  ) throws(HostControlError) -> OperationReceipt {
    var instance = try authoritative(target)
    // A run's VM boots only through its run's transitions (spec 12.2): its
    // one recovery boot cannot be bought again with a plain start.
    guard instance.runID == nil else { throw .unsupported("starting a run's VM directly") }
    if let active = try liveActiveOperation(instance) {
      throw busy(active)
    }
    guard instance.generation == generation else { throw generationConflict(instance) }
    // A boot that ended outside this service (a worker reboot, a crashed
    // owner) is committed as stopped before the sweep gets to it.
    if instance.lifecycle == .running { commitObservedStop(&instance) }
    switch instance.lifecycle {
    case .running: throw HostControlError(.instanceAlreadyRunning, "instance is already running")
    case .creating: throw busy(instance.createdBy)
    case .destroyed: throw destroyed(instance.instanceID)
    case .stopped: break
    }
    guard instance.policyHash == policy else {
      throw HostControlError(.instanceIncompatible, "policy_hash does not match the instance")
    }
    try requireQualified(qualification)
    let seconds: UInt64?
    switch transport {
    case .ssh:
      let requested = ttl ?? settings.remoteDefaultTTL
      guard requested > 0, requested <= settings.remoteMaxTTL else {
        throw .invalidRequest("ttl_seconds must be 1-\(settings.remoteMaxTTL) on a remote host")
      }
      seconds = requested
    case .local:
      if let ttl, ttl == 0 || ttl > settings.localMaxTTL {
        throw .invalidRequest("ttl_seconds must be 1-\(settings.localMaxTTL)")
      }
      // Without a request TTL the configured session_ttl still bounds the
      // boot; record it so leases are capped by the same deadline.
      seconds = ttl ?? settings.localDefaultTTL
    }
    let needsStop = !store.hasReservation(.stop(instance.instanceID))
    try requireCapacity(2 + (needsStop ? 2 : 0))
    record.instanceID = instance.instanceID
    record.runtimeID = instance.runtimeID
    // The deadline is computed once and persisted before boot; retries reuse it.
    record.deadline = seconds.map { now.adding(seconds: $0).seconds }
    instance.activeOperation = record.operationID
    let accepted = record
    let updated = instance
    try persist { () throws(HostError) in
      try store.reserve(.stop(updated.instanceID))
      try store.reserve(.finalize(accepted.operationID))
      try store.saveInstance(updated)
      try store.saveOperation(accepted)
    }
    return record.receipt(disposition: .accepted, instance: instance.qualified)
  }

  /// Commits a runtime-observed stop of a ledger-running instance, as the
  /// deadline sweep does. Called under the admission lock.
  func commitObservedStop(_ instance: inout OperationStore.InstanceRecord) {
    guard (try? native.observe(instance.instanceID, runtime: instance.runtimeID)) == .stopped
    else { return }
    var stopped = instance
    stopped.lifecycle = .stopped
    stopped.bootID = nil
    stopped.expiresAt = nil
    stopped.generation += 1
    stopped.lastObservedAt = now.seconds
    guard (try? store.saveInstance(stopped)) != nil else { return }
    sessions.revoke(instance: stopped.instanceID)
    instance = stopped
  }

  enum CleanupKind {
    case stop
    case destroy
  }

  /// Stop and destroy use reservations made at admission, so they succeed with the ordinary
  /// ledger full. Called under the admission lock.
  func admitCleanup(
    _ record: inout OperationStore.OperationRecord, _ target: QualifiedInstance, generation: UInt64,
    kind: CleanupKind, executing: Set<HostOperationID>
  ) throws(HostControlError) -> OperationReceipt {
    if (try? store.loadTombstone(target.instanceID)) != nil, kind == .destroy {
      return try unchanged(record, target)
    }
    var instance = try authoritative(target)
    var superseded: OperationStore.OperationRecord?
    if let active = instance.activeOperation, let current = try loadOperation(active),
      !current.state.isTerminal
    {
      let method = HostMethod(rawValue: current.method)
      let coalesces =
        method == .vmDestroy || (method == .vmStop && kind == .stop)
      if coalesces {
        return current.receipt(disposition: .existingCleanup, instance: instance.qualified)
      }
      // A destroy supersedes an operation left reconciling, unless it is executing now
      // (execution claims `executing` under this lock first). A run's child operation is
      // governed by its run.
      guard kind == .destroy, current.state == .reconciling, !executing.contains(active),
        current.runID == nil
      else { throw busy(active) }
      // Checked before superseding, so a refused destroy changes nothing.
      guard instance.generation == generation else { throw generationConflict(instance) }
      // Written first: if the write fails nothing changes, and a crash after it leaves a
      // pointer to a terminal operation, which holds nothing.
      var failed = current
      failed.state = .failed
      failed.outcome = "superseded by vm.destroy \(record.operationID)"
      failed.completedAt = now.seconds
      superseded = failed
      instance.activeOperation = nil
    }
    guard instance.generation == generation else { throw generationConflict(instance) }
    if kind == .stop {
      switch instance.lifecycle {
      case .stopped: return try unchanged(record, target)
      case .creating: throw busy(instance.createdBy)
      case .destroyed: throw destroyed(instance.instanceID)
      case .running: break
      }
    }
    let reservation: OperationStore.Reservation =
      kind == .stop ? .stop(instance.instanceID) : .destroy(instance.instanceID)
    record.instanceID = instance.instanceID
    record.runtimeID = instance.runtimeID
    instance.activeOperation = record.operationID
    let accepted = record
    let updated = instance
    if store.hasReservation(reservation) {
      try persist { () throws(HostError) in
        if let superseded {
          try store.saveOperation(superseded)
          try store.consume(.finalize(superseded.operationID))
        }
        try store.consume(reservation)
        try store.reserve(.finalize(accepted.operationID))
        try store.saveInstance(updated)
        try store.saveOperation(accepted)
      }
    } else {
      try requireCapacity(2)
      try persist { () throws(HostError) in
        if let superseded {
          try store.saveOperation(superseded)
          try store.consume(.finalize(superseded.operationID))
        }
        try store.reserve(.finalize(accepted.operationID))
        try store.saveInstance(updated)
        try store.saveOperation(accepted)
      }
    }
    return record.receipt(disposition: .accepted, instance: instance.qualified)
  }

  /// An already-satisfied cleanup: a fresh observation, no new receipt.
  func unchanged(_ record: OperationStore.OperationRecord, _ target: QualifiedInstance)
    throws(HostControlError) -> OperationReceipt
  {
    let observation = try inspect(target)
    return OperationReceipt(
      operationID: record.operationID,
      method: HostMethod(rawValue: record.method) ?? .vmStop, state: .succeeded,
      disposition: .unchanged, acceptedAt: now, completedAt: now, instance: target,
      generation: observation.generation, bootID: nil, expiresAt: nil,
      outcome: "already \(observation.state.rawValue)", cancelRequested: false)
  }
}
