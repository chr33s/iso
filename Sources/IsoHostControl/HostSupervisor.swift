import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Synchronization

/// The host-owned service behind every production host-control request (spec 3, 7, 8.3):
/// operations, reservations, reconciliation, access registry and relays. Work runs on its own
/// queue so losing a frontend neither signals nor cancels it.
package final class HostSupervisor: Sendable {
  package struct Settings: Sendable {
    package var ledger: OperationStore.Limits = .standard
    package var access: AccessSessions.Limits = .standard
    package var remoteDefaultTTL: UInt64 = 8 * 3_600
    package var remoteMaxTTL: UInt64 = 24 * 3_600
    /// Local boots may be long-lived, but their deadline must stay a date
    /// the runtime can represent (about 136 years).
    package var localMaxTTL: UInt64 = UInt64(UInt32.max)
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
    // Lease expiry has its own thread: the deadline loop makes blocking runtime calls that
    // must not hold a lapsed lease's relays open.
    Thread.detachNewThread { [self] in
      while !state.withLock({ $0.stopping }) {
        Thread.sleep(forTimeInterval: sweep.seconds)
        sessions.sweep()
      }
    }
    Thread.detachNewThread { [self] in
      var last = ContinuousClock.now
      while !state.withLock({ $0.stopping }) {
        Thread.sleep(forTimeInterval: sweep.seconds)
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

  package func runPending() {
    repairUnacceptedAdmissions()
    for id in store.operationIDs() {
      guard let record = try? store.loadOperation(id), !record.state.isTerminal else { continue }
      execute(id)
    }
    for id in runs.runIDs() { reconcileRun(id) }
  }

  /// The instance's active operation, or nil when the pointer is stale: admissions write
  /// the instance before the operation, so a crash can leave a pointer to a never-accepted
  /// or terminal operation, which holds nothing.
  func liveActiveOperation(_ instance: OperationStore.InstanceRecord) throws(HostControlError)
    -> HostOperationID?
  {
    guard let active = instance.activeOperation, let current = try loadOperation(active),
      !current.state.isTerminal
    else { return nil }
    return active
  }

  /// Clears stale active-operation pointers. A `.creating` instance whose create was never
  /// accepted is removed (no runtime call can have been made). An unreadable operation file
  /// is not "missing": that instance is left alone.
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
  func discardUnacceptedCreate(_ operation: HostOperationID) {
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

  package func failure(_ requestID: RequestID, _ error: HostControlError) -> HostResponse {
    HostResponse(
      requestID: requestID, hostID: hostID, ownerID: ownerID, epoch: epoch,
      outcome: .failure(error))
  }

  func route(_ request: HostRequest, transport: HostTransportKind) throws(HostControlError)
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
    case .hostCapabilities:
      return capabilities(transport: transport).wire
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

  // MARK: - Helpers

  func loadOperation(_ id: HostOperationID) throws(HostControlError)
    -> OperationStore.OperationRecord?
  {
    do { return try store.loadOperation(id) } catch {
      throw HostControlError(.operationUncertain, "operation record is unreadable")
    }
  }

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

  func checkIdentity(
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

  func artifactWire(_ record: ArtifactStore.Record) -> JSONValue {
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
