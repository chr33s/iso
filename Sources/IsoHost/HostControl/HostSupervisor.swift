import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// The host-owned service behind every production host-control request
/// (spec 3, 7, 8.3). It owns accepted operations, their reservations and
/// reconciliation, the volatile access registry and relays. Accepted work
/// runs on its own queue, never on a frontend's process group, so losing a
/// frontend neither signals nor cancels it.
package final class HostSupervisor: Sendable {
  package struct Settings: Sendable {
    package var ledger: OperationStore.Limits = .standard
    package var access: AccessSessions.Limits = .standard
    /// Remote boots must be finite (spec 8.1).
    package var remoteDefaultTTL: UInt64 = 8 * 3_600
    package var remoteMaxTTL: UInt64 = 24 * 3_600
    /// `limits.session_ttl` for local starts without a TTL; nil means none.
    package var localDefaultTTL: UInt64?
    package var dispatch: Dispatch = .background
    package var reconcileInterval: Duration = .seconds(5)
    package var sweepInterval: Duration = .milliseconds(500)

    package init() {}
  }

  /// `manual` leaves accepted work queued until `runPending()`; tests use it
  /// to hold a dispatch on either side of the first-effect boundary.
  package enum Dispatch: Sendable, Equatable {
    case background
    case manual
  }

  struct State: Sendable {
    var executing: Set<HostOperationID> = []
    var stopping = false
    /// Runs whose record a transition or the safety reconciler is changing.
    var runsBusy: Set<RunID> = []
    /// One image operation per image name at a time.
    var imagesBusy: [ImageName: HostOperationID] = [:]
  }

  package let store: OperationStore
  package let installation: OperationStore.InstallationRecord
  package let epoch: DaemonEpoch
  package let sessions: AccessSessions
  package let relays: RelayRegistry
  package let artifacts: ArtifactStore
  package let runs: RunStore
  let native: any NativeHost
  let clock: any HostClock
  let settings: Settings
  let diagnostics: Diagnostics
  let state = Mutex(State())
  private let queue = DispatchQueue(label: "iso.host.supervisor", attributes: .concurrent)

  /// Opens the installation under `root` for `owner`. The caller holds the
  /// service-ownership lock for this supervisor's lifetime.
  package init(
    root: String, owner: OwnerID, native: any NativeHost, clock: any HostClock = SystemHostClock(),
    settings: Settings = Settings(), diagnostics: Diagnostics = Diagnostics(verbosity: 0)
  ) throws(HostError) {
    store = try OperationStore(root: root, limits: settings.ledger)
    installation = try store.installation(owner: owner, now: WireTime(clock.now()))
    epoch = .generate()
    let relays = RelayRegistry()
    self.relays = relays
    sessions = AccessSessions(
      epoch: epoch, clock: clock, limits: settings.access,
      revoked: { ids in relays.close(sessions: ids) })
    artifacts = try ArtifactStore(root: root + "/artifacts", clock: clock)
    runs = try RunStore(root: root + "/runs")
    self.native = native
    self.clock = clock
    self.settings = settings
    self.diagnostics = diagnostics
    // Nonterminal image work from a previous lifetime keeps its image busy.
    var images: [ImageName: HostOperationID] = [:]
    for id in store.operationIDs() {
      guard let record = try? store.loadOperation(id), !record.state.isTerminal,
        record.method == HostMethod.imageEnsure.rawValue,
        let value = try? HostWire.parse(Array(record.params.utf8), limits: HostWire.requestLimits),
        case .imageEnsure(let request)? = try? HostRequestBody(method: .imageEnsure, params: value)
      else { continue }
      images[request.image] = id
    }
    state.withLock { $0.imagesBusy = images }
  }

  var hostID: HostID { installation.hostID }
  var ownerID: OwnerID { installation.ownerID }
  var now: WireTime { WireTime(clock.now()) }

  // MARK: - Lifetime

  /// Startup reconciliation (spec 8.3 steps 4–6) and the periodic loops.
  package func start() {
    repairUnacceptedAdmissions()
    for id in store.operationIDs() {
      guard let record = try? store.loadOperation(id), !record.state.isTerminal else { continue }
      if record.state == .running {
        var reconciling = record
        reconciling.state = .reconciling
        try? store.saveOperation(reconciling)
      }
      dispatch(id)
    }
    for id in runs.runIDs() { reconcileRun(id) }
    guard settings.dispatch == .background else { return }
    // After a worker restart or reboot, commit boots that ended while the
    // service was down before the first request is admitted.
    enforceDeadlines(observe: true)
    let sweep = settings.sweepInterval
    let reconcile = settings.reconcileInterval
    Thread.detachNewThread { [self] in
      var last = ContinuousClock.now
      while !state.withLock({ $0.stopping }) {
        Thread.sleep(forTimeInterval: sweep.seconds)
        sessions.sweep()
        let full = ContinuousClock.now - last >= reconcile
        enforceDeadlines(observe: full)
        if full {
          last = ContinuousClock.now
          reconcileAll()
        }
      }
    }
  }

  package func shutdown() {
    state.withLock { $0.stopping = true }
    relays.closeAll()
  }

  /// Runs queued and nonterminal work synchronously (manual dispatch).
  package func runPending() {
    repairUnacceptedAdmissions()
    for id in store.operationIDs() {
      guard let record = try? store.loadOperation(id), !record.state.isTerminal else { continue }
      execute(id)
    }
    for id in runs.runIDs() { reconcileRun(id) }
  }

  /// The instance's active operation, or nil when that pointer is stale.
  /// Admissions write the instance before the operation (the commit point),
  /// so a crash or failed write between them leaves a pointer to an
  /// operation that was never accepted, and a crash inside a supersede
  /// leaves one to a terminal operation; neither holds anything.
  func liveActiveOperation(_ instance: OperationStore.InstanceRecord) throws(HostControlError)
    -> HostOperationID?
  {
    guard let active = instance.activeOperation, let current = try loadOperation(active),
      !current.state.isTerminal
    else { return nil }
    return active
  }

  /// Clears stale active-operation pointers (see ``liveActiveOperation(_:)``).
  /// A `.creating` instance whose create was never accepted is removed: no
  /// runtime call can have been made, since execution starts only from an
  /// operation. An operation file that cannot be read is not "missing": that
  /// instance is left alone.
  func repairUnacceptedAdmissions() {
    state.withLock { locked in
      repairUnacceptedRuns()
      for id in store.instanceIDs() {
        guard let snapshot = try? store.loadInstance(id), let active = snapshot.activeOperation,
          // Executors commit without this lock; an executing operation's
          // instance is theirs to write.
          !locked.executing.contains(active)
        else { continue }
        let current: OperationStore.OperationRecord?
        do { current = try store.loadOperation(active) } catch { continue }
        if let current {
          // A terminal operation's own commit clears the pointer, except
          // after a superseded one; a live operation is left to execute.
          guard current.state.isTerminal else { continue }
          // Reloaded after the terminal read: executors write the instance
          // before finishing, so this sees any commit the snapshot missed.
          guard var instance = try? store.loadInstance(id), instance.activeOperation == active,
            instance.lifecycle != .creating
          else { continue }
          instance.activeOperation = nil
          try? store.saveInstance(instance)
          try? store.consume(.finalize(active))
        } else {
          // Never accepted: no executor can be writing this instance.
          var instance = snapshot
          if instance.lifecycle == .creating, instance.createdBy == active {
            try? store.removeInstance(id)
            try? store.consume(.destroy(id))
          } else {
            instance.activeOperation = nil
            try? store.saveInstance(instance)
          }
          try? store.consume(.finalize(active))
        }
      }
    }
  }

  /// Removes a `.creating` instance created by `operation` when that
  /// operation was never written. Called under the admission lock.
  private func discardUnacceptedCreate(_ operation: HostOperationID) {
    for id in store.instanceIDs() {
      guard let instance = try? store.loadInstance(id), instance.lifecycle == .creating,
        instance.createdBy == operation, instance.activeOperation == operation
      else { continue }
      try? store.removeInstance(id)
      try? store.consume(.destroy(id))
      try? store.consume(.finalize(operation))
    }
  }

  func reconcileAll() {
    repairUnacceptedAdmissions()
    for id in store.operationIDs() {
      guard let record = try? store.loadOperation(id), !record.state.isTerminal else { continue }
      dispatch(id)
    }
    for id in runs.runIDs() { reconcileRun(id) }
  }

  func dispatch(_ id: HostOperationID) {
    guard settings.dispatch == .background else { return }
    queue.async { [self] in execute(id) }
  }

  // MARK: - Requests

  /// Handles one decoded request from a trusted transport adapter.
  package func handle(_ request: HostRequest, transport: HostTransportKind) -> HostResponse {
    let outcome: Result<JSONValue, HostControlError>
    do {
      outcome = .success(try route(request, transport: transport))
    } catch {
      outcome = .failure(error)
    }
    return HostResponse(
      requestID: request.requestID, hostID: hostID, ownerID: ownerID, epoch: epoch,
      outcome: outcome)
  }

  /// The response for a frame whose request id is known but whose body failed.
  package func failure(_ requestID: RequestID, _ error: HostControlError) -> HostResponse {
    HostResponse(
      requestID: requestID, hostID: hostID, ownerID: ownerID, epoch: epoch,
      outcome: .failure(error))
  }

  private func route(_ request: HostRequest, transport: HostTransportKind) throws(HostControlError)
    -> JSONValue
  {
    if case .hello(let protocols, _) = request.body {
      guard protocols.contains(HostProtocol.v1) else {
        throw HostControlError(.hostProtocolIncompatible, "no common protocol version")
      }
      return hello(transport: transport).wire
    }
    guard request.hostID == hostID else {
      throw HostControlError(.hostIdentityChanged, "request names a different host installation")
    }
    guard request.ownerID == ownerID else {
      throw HostControlError(.ownerMismatch, "request names a different owner")
    }
    guard installation.state == .active || (try? store.loadInstallation()?.state) == .active else {
      throw HostControlError(.migrationRequired, "host-control activation has not completed")
    }
    if let operation = request.operationID {
      return try admit(request, operation: operation, transport: transport).wire
    }
    switch request.body {
    case .vmList(let cursor, let limit):
      return list(cursor: cursor, limit: limit)
    case .vmInspect(let instance):
      return try inspect(instance).wire
    case .operationGet(let id):
      guard let record = try? store.loadOperation(id) else {
        throw HostControlError(
          .operationNotFound, "unknown operation", details: ["operation_id": id.rawValue])
      }
      return record.receipt(disposition: .existing, instance: qualified(record)).wire
    case .operationCancel(let target):
      return try cancel(target).wire
    case .accessOpen(let open):
      return try accessOpen(open).wire
    case .accessRenew(let session, let bearer, let epoch, let boot, let policy):
      let grant = try sessions.renew(
        session: session, bearer: bearer, epoch: epoch, boot: boot, policy: policy)
      // Renewal never outlives the boot it was issued for, nor the worker's
      // filtered-egress proof when the grant depends on it.
      let egressHolds =
        grant.filteredPolicy == nil
        || ((try? native.filteredPolicy(
          grant.instance.instanceID, runtime: grant.instance.runtimeID)) ?? nil)?.bootID
          == grant.bootID
      guard egressHolds, grantStillValid(grant.instance.instanceID, boot: grant.bootID) else {
        _ = try? sessions.close(session: session, bearer: bearer, epoch: epoch)
        throw HostControlError(.sessionExpired, "the VM is stopping or no longer running this boot")
      }
      return grant.wire
    case .accessClose(let session, let bearer, let epoch):
      let binding = try sessions.close(session: session, bearer: bearer, epoch: epoch)
      let instance = binding.instance
      if !sessions.keyInUse(instance: instance.instanceID, key: binding.clientKey) {
        // Hygiene only: revocation already closed the streams.
        queue.async { [self] in
          native.removeClientKey(
            instance.instanceID, runtime: instance.runtimeID, key: binding.clientPublicKey)
        }
      }
      var b = WireBuilder()
      b.set("session_id", session)
      b.set("closed", true)
      return b.value
    case .runInspect(let run):
      return try runs.inspect(run, host: hostID, owner: ownerID).wire
    case .artifactBegin(let kind, let size, let digest):
      return artifactWire(
        try artifacts.begin(owner: ownerID, kind: kind, size: size, digest: digest))
    case .artifactWrite(let handle, let offset, let bytes):
      return artifactWire(
        try artifacts.write(owner: ownerID, handle: handle, offset: offset, bytes: bytes))
    case .artifactCommit(let handle):
      return artifactWire(try artifacts.commit(owner: ownerID, handle: handle))
    case .artifactRead(let handle, let offset, let length):
      let bytes = try artifacts.read(owner: ownerID, handle: handle, offset: offset, length: length)
      var b = WireBuilder()
      b.set("handle", handle)
      b.set("offset", offset)
      b.set("data", Data(bytes).base64EncodedString())
      return b.value
    case .diagnosticsRead(let id, _):
      guard let record = try? store.loadOperation(id) else {
        throw HostControlError(.operationNotFound, "unknown operation")
      }
      var b = WireBuilder()
      b.set("operation_id", id)
      b.set(
        "records",
        .array(
          [record.substep, record.outcome].compactMap { $0 }.map {
            .string(HostControlError.sanitize($0))
          }))
      return b.value
    case .localCapability(let method, _, _):
      throw .unsupported(
        method.rawValue + (transport == .ssh ? " on a remote host" : " through the host service"))
    default:
      throw .invalidRequest("method requires an operation_id")
    }
  }

  /// Identity and the methods dispatched over `transport`.
  package func hello(transport: HostTransportKind) -> HelloResult {
    HelloResult(
      protocolVersion: HostProtocol.v1, hostID: hostID, ownerID: ownerID, epoch: epoch,
      runtime: native.qualification(), methods: Self.methods(for: transport),
      guestOperations: [.linux])
  }

  /// Methods this supervisor actually dispatches: stopped-VM maintenance only
  /// locally; macOS computer use nowhere (macOS guests are not service-managed).
  package static func methods(for transport: HostTransportKind) -> [HostMethod] {
    HostMethod.allCases.filter { method in
      switch method {
      case .macosComputerUseRead, .macosComputerUseInput: false
      case .vmResize, .imageCommit, .vmRestore: transport == .local
      default: true
      }
    }
  }

  // MARK: - Durable admission (spec 7.2)

  private func admit(
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
    // Only the worker's own verified image records satisfy a create.
    let imageReady: Bool
    switch request.body {
    case .vmCreate(let spec), .runCreate(_, let spec, _, _):
      imageReady = native.imageReady(spec.image)
    default: imageReady = true
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
        return try admitRunCreate(
          &record, run: run, spec: spec, outputLimit: output, ttl: ttl, transport: transport,
          qualification: qualification)
      case .runComplete(let run, let generation, _), .runResultsRecover(let run, let generation),
        .runResultsAck(let run, let generation, _, _), .runResultsDiscard(let run, let generation):
        guard !locked.runsBusy.contains(run) else {
          throw HostControlError(.instanceBusy, "the run is being reconciled; retry shortly")
        }
        return try admitRunTransition(&record, run: run, generation: generation, body: request.body)
      default:
        throw .unsupported(method.rawValue)
      }
    }
    if receipt.disposition == .accepted { dispatch(operation) }
    return receipt
  }

  private func admitMaintenance(
    _ record: inout OperationStore.OperationRecord, _ target: QualifiedInstance, generation: UInt64,
    _ change: Maintenance
  ) throws(HostControlError) -> OperationReceipt {
    var instance = try authoritative(target)
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
      // The accepted intent is the commit point; it is written last.
      try store.saveOperation(accepted)
    }
    return record.receipt(disposition: .accepted, instance: instance.qualified)
  }

  /// The native journals underneath converge to the requested postcondition,
  /// so a reconciling pass repeats the change rather than guessing.
  private func executeMaintenance(_ accepted: OperationStore.OperationRecord) {
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

  private func admitImage(
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
  private func executeImage(_ accepted: OperationStore.OperationRecord) {
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
      // The accepted intent is the commit point; it is written last.
      try store.saveOperation(record)
    }
    return record.receipt(disposition: .accepted, instance: instanceRecord.qualified)
  }

  private func admitStart(
    _ record: inout OperationStore.OperationRecord, _ target: QualifiedInstance, generation: UInt64,
    ttl: UInt64?, policy: SHA256Hex, transport: HostTransportKind,
    qualification: RuntimeQualification
  ) throws(HostControlError) -> OperationReceipt {
    var instance = try authoritative(target)
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
      if let ttl, ttl == 0 { throw .invalidRequest("ttl_seconds must be positive") }
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
      // The accepted intent is the commit point; it is written last.
      try store.saveOperation(accepted)
    }
    return record.receipt(disposition: .accepted, instance: instance.qualified)
  }

  /// Commits a runtime-observed stop of a ledger-running instance, as the
  /// deadline sweep does. Called under the admission lock.
  private func commitObservedStop(_ instance: inout OperationStore.InstanceRecord) {
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

  /// Stop and destroy use the reservations made when the instance and its
  /// boot were admitted, so they succeed with the ordinary ledger full.
  /// Called under the admission lock; `executing` is that lock's set.
  private func admitCleanup(
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
      // A destroy supersedes an operation left reconciling (a crashed VM can
      // keep one there indefinitely), unless it is executing right now: an
      // execution claims `executing` under this lock before loading its
      // record, so a later one finds the record terminal. A run's child
      // operation is governed by its run.
      guard kind == .destroy, current.state == .reconciling, !executing.contains(active),
        current.runID == nil
      else { throw busy(active) }
      // Checked before superseding, so a refused destroy changes nothing.
      guard instance.generation == generation else { throw generationConflict(instance) }
      // Written first inside the destroy's own persist below: if that write
      // fails nothing changes, and a crash after it leaves a pointer to a
      // terminal operation, which holds nothing.
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
        // The accepted intent is the commit point; it is written last.
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
  private func unchanged(_ record: OperationStore.OperationRecord, _ target: QualifiedInstance)
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

  // MARK: - Execution and reconciliation (spec 7.3–7.4)

  /// Drives one operation to a terminal state or leaves it reconciling.
  /// Re-entrant across restarts: every step observes before it acts.
  /// A run's child create/start runs only from its parent run operation
  /// (`asRunChild`), so cancelling or failing the parent governs it.
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
    case .runCreate, .runComplete, .runResultsRecover, .runResultsAck, .runResultsDiscard:
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
  private func alreadyCommitted(
    _ record: OperationStore.OperationRecord, _ instance: OperationStore.InstanceRecord
  ) -> Bool {
    instance.activeOperation != record.operationID
  }

  private func executeCreate(_ accepted: OperationStore.OperationRecord) {
    guard let instanceID = accepted.instanceID, let runtime = accepted.runtimeID,
      let instance = try? store.loadInstance(instanceID),
      let spec = decodeSpec(instance.spec)
    else { return finish(accepted, .failed, outcome: "create record is incomplete") }
    if alreadyCommitted(accepted, instance), instance.lifecycle != .creating {
      return finish(accepted, .succeeded, outcome: nil, generation: instance.generation)
    }
    guard var record = beginEffect(accepted.operationID, substep: "creating") else { return }
    // Only a persisted "create_requested" means the runtime may have been asked.
    // "create_failed" records a refused create before any cleanup, so a
    // reconciling pass can only fail it, never commit it as created.
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
        // A retried create never re-allocates. A runtime call interrupted by a
        // crash may still finish, so the identity stays reserved for an
        // explicit destroy rather than being tombstoned now.
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

  private func commitCreated(
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

  private func failCreate(
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

  private func executeStart(_ accepted: OperationStore.OperationRecord) {
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

  private func executeStop(_ accepted: OperationStore.OperationRecord) {
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

  private func executeDestroy(_ accepted: OperationStore.OperationRecord) {
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

  /// Worker-side deadline enforcement in addition to the runtime owner's:
  /// expired boots are stopped without a caller operation or ledger slot,
  /// and a runtime-observed stop is committed.
  /// `observe` also polls non-expired boots for a runtime-side stop; the
  /// sub-second loop passes false so only expired boots reach the runtime.
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

  private func cancel(_ target: HostOperationID) throws(HostControlError) -> OperationReceipt {
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
      return record.receipt(disposition: .existing, instance: qualified(record))
    }
  }

  // MARK: - Reads (spec 7.6)

  package func inspect(_ target: QualifiedInstance) throws(HostControlError) -> VMObservation {
    if let tombstone = try? store.loadTombstone(target.instanceID) {
      try checkIdentity(
        target, hostID: tombstone.hostID, ownerID: tombstone.ownerID,
        runtime: tombstone.runtimeID, guestOS: tombstone.guestOS)
      return VMObservation(
        instance: target, name: tombstone.name, generation: tombstone.terminalGeneration,
        state: .destroyed, bootID: nil, policyHash: nil, expiresAt: nil, observedAt: now,
        activeOperation: nil)
    }
    let instance = try authoritative(target)
    return observation(instance)
  }

  func observation(_ instance: OperationStore.InstanceRecord) -> VMObservation {
    let spec = decodeSpec(instance.spec)
    var state: ObservedState
    var boot = instance.bootID
    switch try? native.observe(instance.instanceID, runtime: instance.runtimeID) {
    case .running(let observed, _, _)?:
      state = .running
      boot = observed
    case .stopped?: state = instance.lifecycle == .creating ? .unknown : .stopped
    case .unhealthy?: state = .unhealthy
    case .absent?: state = instance.lifecycle == .creating ? .unknown : .unhealthy
    case nil: state = .unknown
    }
    // A brokered boot that fails a fresh gate pass, or whose proof names
    // another boot, is not reported as running.
    var network: NetworkProof?
    if state == .running {
      do {
        network = try native.networkProof(instance.instanceID, runtime: instance.runtimeID)
        if let proof = network, proof.bootID != boot {
          state = .unhealthy
          network = nil
        }
      } catch {
        state = .unhealthy
      }
    }
    return VMObservation(
      instance: instance.qualified, name: instance.name, generation: instance.generation,
      state: state, bootID: state == .running ? boot : nil, policyHash: instance.policyHash,
      expiresAt: instance.expiresAt.map(WireTime.init(seconds:)), observedAt: now,
      activeOperation: instance.activeOperation, image: spec?.image, egress: spec?.egress,
      network: network)
  }

  private func list(cursor: InstanceID?, limit: UInt32) -> JSONValue {
    let ids = store.instanceIDs().filter { cursor == nil || $0 > cursor! }
    let page = ids.prefix(Int(limit))
    var items: [JSONValue] = []
    for id in page {
      guard let instance = try? store.loadInstance(id) else { continue }
      items.append(observation(instance).wire)
    }
    var b = WireBuilder()
    b.set("instances", .array(items))
    if ids.count > page.count, let last = page.last { b.set("next_cursor", last) }
    return b.value
  }

  // MARK: - Access (spec 9)

  private func accessOpen(_ request: AccessOpenRequest) throws(HostControlError) -> AccessGrant {
    // Epoch first: a delayed open from an old epoch never creates a session.
    guard request.expectedEpoch == epoch else {
      throw HostControlError(.sessionExpired, "daemon epoch changed")
    }
    let instance = try authoritative(request.instance)
    guard instance.lifecycle == .running, instance.activeOperation == nil else {
      throw HostControlError(.sessionExpired, "the instance is not running")
    }
    guard instance.generation == request.expectedGeneration else {
      throw generationConflict(instance)
    }
    guard instance.policyHash == request.policyHash else {
      throw HostControlError(.sessionIdentityChanged, "policy changed")
    }
    // Fresh native proof: the live boot must be the recorded and expected one.
    let observed: NativeState
    do { observed = try native.observe(instance.instanceID, runtime: instance.runtimeID) } catch {
      throw HostControlError(.hostRuntimeUnqualified, "the VM could not be observed")
    }
    guard case .running(let boot, _, _) = observed, boot == instance.bootID,
      boot == request.expectedBoot
    else { throw HostControlError(.sessionIdentityChanged, "the VM boot changed") }
    let pin: String
    let user: GuestUser
    do {
      pin = try native.guestHostKey(instance.instanceID, runtime: instance.runtimeID)
      user = try native.guestUser(instance.instanceID, runtime: instance.runtimeID)
    } catch {
      throw HostControlError(.guestKeyChanged, "the guest host key is not pinned")
    }
    // Filtered egress: the worker's half of the composite proof, for this boot.
    let filtered: FilteredGrantPolicy?
    if decodeSpec(instance.spec)?.egress == .filtered {
      do {
        filtered = try native.filteredPolicy(instance.instanceID, runtime: instance.runtimeID)
      } catch {
        throw HostControlError(.sessionExpired, "FILTERED_EGRESS_NOT_READY on the host")
      }
      guard let filtered, filtered.bootID == boot else {
        throw HostControlError(
          .sessionIdentityChanged, "the filtered boot policy is not for this boot")
      }
    } else {
      filtered = nil
    }
    let binding = AccessSessions.Binding(
      instance: instance.qualified, bootID: boot, policyHash: request.policyHash,
      generation: instance.generation, client: request.client,
      clientKey: request.clientKey.fingerprint, purpose: request.purpose, guestHostKey: pin,
      guestUser: user, clientPublicKey: request.clientKey, filteredPolicy: filtered)
    let grant = try sessions.open(
      request, binding: binding, vmExpiresAt: instance.expiresAt.map(WireTime.init(seconds:)))
    // Authorizing the session key is idempotent, so a replayed open repeats it safely.
    do {
      try native.authorizeClientKey(
        instance.instanceID, runtime: instance.runtimeID, key: request.clientKey)
    } catch {
      _ = try? sessions.close(session: request.session, bearer: request.bearer, epoch: epoch)
      throw HostControlError(.hostRuntimeUnqualified, "the client key could not be authorized")
    }
    // A stop or destroy admitted while this open ran has already revoked;
    // a grant registered after that must not survive it.
    guard grantStillValid(instance.instanceID, boot: boot) else {
      _ = try? sessions.close(session: request.session, bearer: request.bearer, epoch: epoch)
      throw HostControlError(.sessionExpired, "the VM is stopping or no longer running this boot")
    }
    return grant
  }

  /// Under the admission lock: the instance still runs this boot with no
  /// lifecycle operation in flight.
  func grantStillValid(_ id: InstanceID, boot: BootID) -> Bool {
    state.withLock { _ in
      guard let instance = try? store.loadInstance(id) else { return false }
      return instance.lifecycle == .running && instance.bootID == boot
        && instance.activeOperation == nil
    }
  }

  /// The guest endpoint for an admitted relay, chosen from current proof.
  package func relayEndpoint(_ binding: AccessSessions.Binding) throws(HostControlError)
    -> GuestEndpoint
  {
    guard let instance = try? store.loadInstance(binding.instance.instanceID),
      instance.lifecycle == .running, instance.bootID == binding.bootID
    else { throw HostControlError(.sessionExpired, "the VM is no longer running this boot") }
    do {
      guard
        case .running(let boot, _, _) = try native.observe(
          instance.instanceID, runtime: instance.runtimeID), boot == binding.bootID
      else { throw HostControlError(.sessionIdentityChanged, "the VM boot changed") }
      return try native.guestEndpoint(instance.instanceID, runtime: instance.runtimeID)
    } catch let error as HostControlError {
      throw error
    } catch {
      throw HostControlError(.sessionExpired, "the guest endpoint is unavailable")
    }
  }

  // MARK: - Helpers

  func loadOperation(_ id: HostOperationID) throws(HostControlError)
    -> OperationStore.OperationRecord?
  {
    do { return try store.loadOperation(id) } catch {
      throw HostControlError(.operationUncertain, "operation record is unreadable")
    }
  }

  /// Loads the authoritative record and compares every supplied identity field.
  func authoritative(_ target: QualifiedInstance) throws(HostControlError)
    -> OperationStore.InstanceRecord
  {
    let record: OperationStore.InstanceRecord?
    do { record = try store.loadInstance(target.instanceID) } catch {
      throw HostControlError(.operationUncertain, "instance record is unreadable")
    }
    guard let record else {
      if (try? store.loadTombstone(target.instanceID)) != nil {
        throw destroyed(target.instanceID)
      }
      throw HostControlError(
        .instanceNotFound, "unknown instance", details: ["instance_id": target.instanceID.rawValue])
    }
    try checkIdentity(
      target, hostID: record.hostID, ownerID: record.ownerID, runtime: record.runtimeID,
      guestOS: record.guestOS)
    return record
  }

  private func checkIdentity(
    _ target: QualifiedInstance, hostID: HostID, ownerID: OwnerID, runtime: MachineName,
    guestOS: GuestOS
  ) throws(HostControlError) {
    guard target.hostID == hostID else {
      throw HostControlError(.hostIdentityChanged, "instance belongs to a different host")
    }
    guard target.ownerID == ownerID else {
      throw HostControlError(.ownerMismatch, "instance belongs to a different owner")
    }
    guard target.runtimeID == runtime, target.guestOS == guestOS else {
      throw HostControlError(
        .instanceIncompatible, "instance identity does not match the authoritative record",
        retry: .explicitIdentityResolution)
    }
  }

  func qualified(_ record: OperationStore.OperationRecord) -> QualifiedInstance? {
    guard let id = record.instanceID, let runtime = record.runtimeID else { return nil }
    if let instance = try? store.loadInstance(id) { return instance.qualified }
    if let tombstone = try? store.loadTombstone(id) {
      return QualifiedInstance(
        hostID: hostID, ownerID: ownerID, instanceID: id, runtimeID: runtime,
        guestOS: tombstone.guestOS)
    }
    return nil
  }

  func busy(_ active: HostOperationID) -> HostControlError {
    HostControlError(
      .instanceBusy, "another operation is active on this instance",
      details: ["operation_id": active.rawValue])
  }

  func generationConflict(_ instance: OperationStore.InstanceRecord) -> HostControlError {
    HostControlError(
      .generationConflict, "expected generation is stale",
      details: ["generation": String(instance.generation)])
  }

  func destroyed(_ id: InstanceID) -> HostControlError {
    HostControlError(
      .instanceDestroyed, "instance was destroyed", details: ["instance_id": id.rawValue])
  }

  func decodeSpec(_ params: String) -> VMSpec? {
    guard let value = try? HostWire.parse(Array(params.utf8), limits: HostWire.requestLimits),
      case .vmCreate(let spec)? = try? HostRequestBody(method: .vmCreate, params: value)
    else { return nil }
    return spec
  }

  func persist(_ body: () throws(HostError) -> Void) throws(HostControlError) {
    do { try body() } catch {
      throw HostControlError(.limitExceeded, "host-control state could not be written")
    }
  }

  private func artifactWire(_ record: ArtifactStore.Record) -> JSONValue {
    var b = WireBuilder()
    b.set("handle", record.handle)
    b.set("kind", record.kind.rawValue)
    b.set("size", record.size)
    b.set("written", record.written)
    b.set("digest", record.digest)
    b.set("state", record.state.rawValue)
    b.set("expires_at", record.expiresAt)
    return b.value
  }
}

extension Duration {
  var seconds: TimeInterval {
    let (whole, fraction) = components
    return TimeInterval(whole) + TimeInterval(fraction) / 1e18
  }
}
