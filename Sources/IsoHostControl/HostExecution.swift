import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

/// Execution, reconciliation and cancellation of accepted operations
/// (spec 7.3–7.4).
extension HostSupervisor {
  /// Drives one operation to a terminal state or leaves it reconciling; re-entrant across
  /// restarts. A run's child create/start runs only from its parent operation
  /// (`asRunChild`).
  func execute(_ id: HostOperationID, asRunChild: Bool = false) {
    guard let peek = try? store.loadOperation(id), !peek.state.isTerminal else { return }
    let method = HostMethod(rawValue: peek.method)
    if peek.runID != nil, method == .vmCreate || method == .vmStart, !asRunChild { return }
    let claimed = state.withLock { state in state.executing.insert(id).inserted }
    guard claimed else { return }
    defer { _ = state.withLock { state in state.executing.remove(id) } }
    guard let record = try? store.loadOperation(id), !record.state.isTerminal else { return }
    switch HostMethod(rawValue: record.method) {
    case .vmCreate: executeCreate(record)
    case .vmStart: executeStart(record)
    case .vmStop: executeStop(record)
    case .vmDestroy: executeDestroy(record)
    case .runCreate, .runComplete, .runResultsRecover, .runResultsAck, .runResultsDiscard,
      .runRetain:
      executeRun(record)
    case .imageEnsure:
      executeImage(record)
    case .vmResize, .imageCommit, .vmRestore:
      executeMaintenance(record)
    default:
      finish(record, .failed, outcome: "method is not dispatched by this supervisor")
    }
  }

  /// Crosses the first-effect boundary under the admission lock. Returns nil
  /// when cancellation won the race.
  func beginEffect(_ id: HostOperationID, substep: String) -> OperationStore.OperationRecord? {
    state.withLock { _ in
      guard var record = try? store.loadOperation(id), !record.state.isTerminal else { return nil }
      guard !record.cancelRequested else { return nil }
      if record.substep == nil {
        record.substep = substep
      }
      record.state = .running
      try? store.saveOperation(record)
      return record
    }
  }

  func reconcileLater(_ record: OperationStore.OperationRecord, _ reason: String) {
    var updated = record
    updated.state = .reconciling
    updated.outcome = HostControlError.sanitize(reason)
    try? store.saveOperation(updated)
  }

  func finish(
    _ record: OperationStore.OperationRecord, _ state: OperationState, outcome: String?,
    generation: UInt64? = nil, boot: BootID? = nil
  ) {
    var updated = record
    updated.state = state
    updated.outcome = outcome.map { HostControlError.sanitize($0) }
    updated.generation = generation ?? record.generation
    updated.bootID = boot ?? record.bootID
    updated.completedAt = now.seconds
    // The finalize reservation is the space this rewrite uses.
    try? store.consume(.finalize(record.operationID))
    do { try store.saveOperation(updated) } catch {
      diagnostics.warn("Failed to record the outcome of operation \(record.operationID): \(error)")
    }
  }

  /// Persists `substep` immediately before an external call, so a
  /// reconciling retry knows whether that call may have happened.
  @discardableResult
  func markSubstep(_ record: OperationStore.OperationRecord, _ substep: String)
    -> OperationStore.OperationRecord
  {
    var updated = record
    updated.substep = substep
    try? store.saveOperation(updated)
    return updated
  }

  /// Whether this operation's instance commit already happened (a crash
  /// between committing the instance and finishing the operation).
  func alreadyCommitted(
    _ record: OperationStore.OperationRecord, _ instance: OperationStore.InstanceRecord
  ) -> Bool {
    instance.activeOperation != record.operationID
  }

  func executeCreate(_ accepted: OperationStore.OperationRecord) {
    guard let instanceID = accepted.instanceID, let runtime = accepted.runtimeID,
      let instance = try? store.loadInstance(instanceID),
      let spec = decodeSpec(instance.spec)
    else { return finish(accepted, .failed, outcome: "create record is incomplete") }
    if alreadyCommitted(accepted, instance), instance.lifecycle != .creating {
      return finish(accepted, .succeeded, outcome: nil, generation: instance.generation)
    }
    guard var record = beginEffect(accepted.operationID, substep: "creating") else { return }
    // Only a persisted "create_requested" means the runtime may have been asked;
    // "create_failed" can only be failed, never committed.
    let requested = record.substep == "create_requested" || record.substep == "create_failed"
    do {
      var observed = try native.observe(instanceID, runtime: runtime)
      var createError: NativeFailure? =
        record.substep == "create_failed" ? .failed("an earlier create attempt failed") : nil
      if observed == .absent && !requested {
        record = markSubstep(record, "create_requested")
        do { try native.create(instanceID, runtime: runtime, spec: spec, owner: ownerID) } catch {
          if case .uncertain(let reason) = error { return reconcileLater(record, reason) }
          if case .unavailable(let reason) = error {
            // Nothing was attempted: the next pass may ask again.
            return reconcileLater(markSubstep(record, "creating"), reason)
          }
          createError = error
          record = markSubstep(record, "create_failed")
        }
        observed = try native.observe(instanceID, runtime: runtime)
      }
      switch observed {
      case .absent:
        if let createError {
          return failCreate(
            record, instance, "create failed with no runtime object: \(createError)")
        }
        // A retried create never re-allocates; an interrupted runtime call may still
        // finish, so the identity stays reserved for an explicit destroy.
        var retained = instance
        retained.activeOperation = nil
        try? store.saveInstance(retained)
        return finish(
          record, .failed,
          outcome:
            "no runtime object was observed for the reserved identity; destroy it to release it")
      case .running:
        // Never leave a created VM running, whatever the create reported.
        try native.stop(instanceID, runtime: runtime)
        guard try native.observe(instanceID, runtime: runtime) == .stopped else {
          return reconcileLater(record, "created VM did not stop")
        }
        fallthrough
      case .stopped:
        if let createError {
          commitCreated(
            record, instance,
            outcome: "create failed; the partial VM remains for destroy: \(createError)",
            state: .failed)
        } else {
          commitCreated(record, instance, outcome: nil, state: .succeeded)
        }
      case .unhealthy(let reason):
        // Stopped and committed as failed, so the partial VM can be destroyed.
        try native.stop(instanceID, runtime: runtime)
        guard try native.observe(instanceID, runtime: runtime) == .stopped else {
          return reconcileLater(record, "an unhealthy created VM is not yet stopped: \(reason)")
        }
        commitCreated(
          record, instance,
          outcome: "create failed; the unhealthy VM (\(reason)) remains for destroy",
          state: .failed)
      }
    } catch {
      reconcileLater(record, "\(error)")
    }
  }

  func commitCreated(
    _ record: OperationStore.OperationRecord, _ instance: OperationStore.InstanceRecord,
    outcome: String?, state: OperationState
  ) {
    var updated = instance
    updated.lifecycle = .stopped
    updated.generation = 1
    updated.activeOperation = nil
    updated.lastObservedAt = now.seconds
    try? store.saveInstance(updated)
    finish(record, state, outcome: outcome, generation: 1)
  }

  func failCreate(
    _ record: OperationStore.OperationRecord, _ instance: OperationStore.InstanceRecord,
    _ outcome: String
  ) {
    let tombstone = OperationStore.Tombstone(
      hostID: hostID, ownerID: ownerID, instanceID: instance.instanceID,
      runtimeID: instance.runtimeID, guestOS: instance.guestOS, name: instance.name,
      terminalGeneration: instance.generation, destroyedBy: record.operationID,
      destroyedAt: now.seconds, createdBy: instance.createdBy, disposition: "create_failed")
    try? store.consume(.destroy(instance.instanceID))
    try? store.saveTombstone(tombstone)
    try? store.removeInstance(instance.instanceID)
    finish(record, .failed, outcome: outcome, generation: instance.generation)
  }

  func executeStart(_ accepted: OperationStore.OperationRecord) {
    guard let instanceID = accepted.instanceID, let runtime = accepted.runtimeID,
      var instance = try? store.loadInstance(instanceID)
    else { return finish(accepted, .failed, outcome: "start record is incomplete") }
    if alreadyCommitted(accepted, instance) {
      return finish(
        accepted, .succeeded, outcome: nil, generation: instance.generation, boot: instance.bootID)
    }
    guard var record = beginEffect(accepted.operationID, substep: "starting") else { return }
    // "boot_failed" records a refused boot before any cleanup, so a
    // reconciling pass can only stop and fail it, never hand it out.
    let firstAttempt = record.substep != "boot_requested" && record.substep != "boot_failed"
    let deadline = record.deadline.map { WireTime(seconds: $0) }
    if let deadline, now >= deadline, firstAttempt {
      instance.activeOperation = nil
      try? store.saveInstance(instance)
      return finish(record, .failed, outcome: "the boot deadline passed before the VM started")
    }
    do {
      var startError: NativeFailure? =
        record.substep == "boot_failed" ? .failed("an earlier start attempt failed") : nil
      if firstAttempt {
        record = markSubstep(record, "boot_requested")
        do { try native.start(instanceID, runtime: runtime, expiresAt: deadline?.date) } catch {
          if case .unavailable(let reason) = error {
            return reconcileLater(markSubstep(record, "starting"), reason)
          }
          startError = error
          record = markSubstep(record, "boot_failed")
        }
      }
      // A reconciling start observes; it never boots a second time.
      switch try native.observe(instanceID, runtime: runtime) {
      case .running(let boot, _, _):
        if let startError {
          // A boot that failed isolation or pin checks is never handed out.
          try native.stop(instanceID, runtime: runtime)
          guard try native.observe(instanceID, runtime: runtime) == .stopped else {
            return reconcileLater(record, "a failed boot is not yet verified stopped")
          }
          instance.activeOperation = nil
          try? store.saveInstance(instance)
          return finish(record, .failed, outcome: "start failed: \(startError)")
        }
        instance.lifecycle = .running
        instance.bootID = boot
        instance.expiresAt = record.deadline
        instance.generation += 1
        instance.activeOperation = nil
        instance.lastObservedAt = now.seconds
        try? store.saveInstance(instance)
        finish(record, .succeeded, outcome: nil, generation: instance.generation, boot: boot)
      case .stopped:
        instance.activeOperation = nil
        try? store.saveInstance(instance)
        finish(
          record, .failed,
          outcome: startError.map { "start failed: \($0)" }
            ?? "the boot was not observed; the instance is stopped",
          generation: instance.generation)
      case .absent:
        instance.activeOperation = nil
        try? store.saveInstance(instance)
        finish(record, .failed, outcome: "the runtime object is missing")
      case .unhealthy(let reason):
        // A crashed or unidentified boot is a failed start, never awaited.
        try native.stop(instanceID, runtime: runtime)
        guard try native.observe(instanceID, runtime: runtime) == .stopped else {
          return reconcileLater(record, "an unhealthy boot is not yet verified stopped: \(reason)")
        }
        instance.activeOperation = nil
        try? store.saveInstance(instance)
        finish(record, .failed, outcome: "start failed: the boot was unhealthy (\(reason))")
      }
    } catch {
      reconcileLater(record, "\(error)")
    }
  }

  func executeStop(_ accepted: OperationStore.OperationRecord) {
    guard let instanceID = accepted.instanceID, let runtime = accepted.runtimeID,
      var instance = try? store.loadInstance(instanceID)
    else { return finish(accepted, .failed, outcome: "stop record is incomplete") }
    if alreadyCommitted(accepted, instance) {
      return finish(accepted, .succeeded, outcome: nil, generation: instance.generation)
    }
    // Access is revoked first; closing streams is not the stop criterion.
    sessions.revoke(instance: instanceID)
    guard let record = beginEffect(accepted.operationID, substep: "stopping") else { return }
    do {
      if try native.observe(instanceID, runtime: runtime) != .stopped {
        try native.stop(instanceID, runtime: runtime)
      }
      switch try native.observe(instanceID, runtime: runtime) {
      case .stopped, .absent:
        instance.lifecycle = .stopped
        instance.bootID = nil
        instance.expiresAt = nil
        instance.generation += 1
        instance.activeOperation = nil
        instance.lastObservedAt = now.seconds
        try? store.saveInstance(instance)
        finish(record, .succeeded, outcome: nil, generation: instance.generation)
      case .running, .unhealthy:
        reconcileLater(record, "the VM is not yet verified stopped")
      }
    } catch {
      reconcileLater(record, "\(error)")
    }
  }

  func executeDestroy(_ accepted: OperationStore.OperationRecord) {
    guard let instanceID = accepted.instanceID,
      let instance = try? store.loadInstance(instanceID)
    else {
      // Already removed: a reconciling retry after the tombstone committed.
      if let id = accepted.instanceID, let tombstone = try? store.loadTombstone(id) {
        return finish(accepted, .succeeded, outcome: nil, generation: tombstone.terminalGeneration)
      }
      return finish(accepted, .failed, outcome: "destroy record is incomplete")
    }
    sessions.revoke(instance: instanceID)
    guard let record = beginEffect(accepted.operationID, substep: "destroying") else { return }
    guard destroyNow(instance, by: record.operationID) else {
      return reconcileLater(record, "the runtime object is not yet verified deleted")
    }
    finish(record, .succeeded, outcome: nil, generation: instance.generation + 1)
  }

  /// Worker-side deadline enforcement beside the runtime owner's: expired boots are stopped
  /// without an operation or ledger slot. `observe` also polls non-expired boots; the sub-
  /// second loop passes false.
  func enforceDeadlines(observe: Bool = true) {
    for id in store.instanceIDs() {
      guard var instance = try? store.loadInstance(id), instance.lifecycle == .running,
        instance.activeOperation == nil
      else { continue }
      let expired = instance.expiresAt.map { now.seconds >= $0 } ?? false
      if expired {
        sessions.revoke(instance: id)
        try? native.stop(id, runtime: instance.runtimeID)
      } else if !observe {
        continue
      }
      guard let observed = try? native.observe(id, runtime: instance.runtimeID) else { continue }
      if observed == .stopped {
        let committed: Bool = state.withLock { _ in
          guard let current = try? store.loadInstance(id), current.activeOperation == nil,
            current.lifecycle == .running
          else { return false }
          instance = current
          instance.lifecycle = .stopped
          instance.bootID = nil
          instance.expiresAt = nil
          instance.generation += 1
          instance.lastObservedAt = now.seconds
          return (try? store.saveInstance(instance)) != nil
        }
        if committed { sessions.revoke(instance: id) }
      }
    }
  }

  // MARK: - Cancellation (spec 7.3)

  func cancel(_ target: HostOperationID) throws(HostControlError) -> OperationReceipt {
    try state.withLock { (state) throws(HostControlError) -> OperationReceipt in
      guard var record = try loadOperation(target) else {
        throw HostControlError(
          .operationNotFound, "unknown operation", details: ["operation_id": target.rawValue])
      }
      if record.state.isTerminal {
        return record.receipt(disposition: .existing, instance: qualified(record))
      }
      let method = HostMethod(rawValue: record.method)
      guard method != .vmStop, method != .vmDestroy, method != .runResultsDiscard,
        method != .runResultsAck
      else { throw .unsupported("cancelling cleanup") }
      guard record.state == .accepted, record.substep == nil, !state.executing.contains(target)
      else {
        throw HostControlError(
          .cancelTooLate, "the operation has started its external effect",
          details: ["operation_id": target.rawValue])
      }
      if record.runID != nil, method == .vmCreate || method == .vmStart {
        throw .unsupported("cancelling a run's child operation; cancel its run.create")
      }
      record.cancelRequested = true
      if let instanceID = record.instanceID, var instance = try? store.loadInstance(instanceID) {
        if method == .vmCreate || method == .runCreate {
          // The run's child create only executes from the parent, which has
          // not started, so neither has it.
          if method == .runCreate, let run = record.runID, let parent = try? runs.load(run),
            var child = try? store.loadOperation(parent.createOperation), !child.state.isTerminal
          {
            child.cancelRequested = true
            child.state = .cancelled
            child.completedAt = now.seconds
            child.outcome = "cancelled with its run"
            try? store.consume(.finalize(child.operationID))
            try? store.saveOperation(child)
          }
          let tombstone = OperationStore.Tombstone(
            hostID: hostID, ownerID: ownerID, instanceID: instanceID, runtimeID: instance.runtimeID,
            guestOS: instance.guestOS, name: instance.name, terminalGeneration: 0,
            destroyedBy: target, destroyedAt: now.seconds, createdBy: instance.createdBy,
            disposition: "cancelled")
          try? store.consume(.destroy(instanceID))
          try? store.saveTombstone(tombstone)
          try? store.removeInstance(instanceID)
        } else {
          instance.activeOperation = nil
          try? store.saveInstance(instance)
        }
      }
      if let run = record.runID, method == .runCreate {
        runs.cancelReserved(run)
        try? store.consume(.run(run))
      }
      record.state = .cancelled
      record.completedAt = now.seconds
      record.outcome = "cancelled before any external effect"
      try? store.consume(.finalize(target))
      do { try store.saveOperation(record) } catch {
        throw HostControlError(.operationUncertain, "cancellation could not be recorded")
      }
      // A cancelled image.ensure never executes, so its release is here.
      state.imagesBusy = state.imagesBusy.filter { $0.value != target }
      return record.receipt(disposition: .existing, instance: qualified(record))
    }
  }
}
