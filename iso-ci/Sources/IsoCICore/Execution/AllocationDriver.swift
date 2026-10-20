import Foundation
import Synchronization

/// Resolves pinned host clients. Hosts are iso aliases (`local` or an iso
/// enrollment); enabling one pins its host/owner identity on first contact.
/// Tailnet nodes are never discovered or authorized automatically.
package final class HostDirectory: Sendable {
  package let store: ControllerStore
  private let makeTransport: @Sendable (Name) -> any HostTransport

  package init(
    store: ControllerStore, makeTransport: @escaping @Sendable (Name) -> any HostTransport
  ) {
    self.store = store
    self.makeTransport = makeTransport
  }

  package convenience init(store: ControllerStore, iso: String, isoConfig: String? = nil) {
    self.init(store: store) { alias in
      IsoBridgeTransport(iso: iso, isoConfig: isoConfig, alias: alias)
    }
  }

  /// First contact: pins the identity the host reports. Re-enabling an
  /// existing host requires the same identity.
  @discardableResult
  package func enable(_ alias: Name) throws(CIError) -> HostRecord {
    let (hello, epoch) = try HostClient(
      alias: alias, transport: makeTransport(alias), expected: nil
    ).hello()
    var record = try store.host(alias) ?? HostRecord(alias: alias, at: store.now)
    if let pinned = record.hostID, pinned != hello.hostID || record.ownerID != hello.ownerID {
      throw CIError(
        .hostIdentityChanged,
        "host \(alias) now reports a different installation; disable and re-enable it explicitly after verifying"
      )
    }
    record.hostID = hello.hostID
    record.ownerID = hello.ownerID
    record.state = .enabled
    record.reason = nil
    record.observedAt = store.now
    let client = HostClient(
      alias: alias, transport: makeTransport(alias), expected: (hello.hostID, hello.ownerID))
    if hello.methods.contains(HostMethod.hostCapabilities.rawValue) {
      record.capabilities = HostCapabilitiesSnapshot(try client.capabilities(), epoch: epoch)
    }
    try store.save(record)
    try store.event(
      "host:\(alias)", "host.enabled", "enabled host \(alias)",
      data: ["host_id": hello.hostID.rawValue])
    return record
  }

  /// Re-reads the advertised capabilities of an enabled host so placement
  /// sees evidence recorded (or withdrawn) after `enable`. Identity is
  /// checked by the pinned client; an unreachable host keeps its snapshot
  /// and is handled by admission.
  package func refreshCapabilities(_ alias: Name) throws(CIError) {
    guard var record = try store.host(alias), record.state == .enabled else { return }
    let client = try client(alias)
    let (hello, epoch) = try client.hello()
    guard hello.methods.contains(HostMethod.hostCapabilities.rawValue) else {
      record.capabilities = nil
      record.observedAt = store.now
      try store.save(record)
      return
    }
    let refreshed = HostCapabilitiesSnapshot(try client.capabilities(), epoch: epoch)
    if refreshed != record.capabilities {
      try store.event(
        "host:\(alias)", "host.capabilities_changed",
        "host \(alias) capabilities changed (qualification \(refreshed.qualificationStatus ?? "none"))"
      )
    }
    record.capabilities = refreshed
    record.observedAt = store.now
    try store.save(record)
  }

  package func client(_ alias: Name) throws(CIError) -> HostClient {
    guard let record = try store.host(alias), let host = record.hostID, let owner = record.ownerID
    else {
      throw CIError(
        .notFound, "host \(alias) is not enabled for CI; run `iso-ci setup --host \(alias)`")
    }
    return HostClient(alias: alias, transport: makeTransport(alias), expected: (host, owner))
  }
}

/// The concrete `EnvironmentProvider`: one allocation is one disposable
/// `run.create` VM driven through the supported host-client subset. Every
/// host mutation uses an identity persisted before it is sent; a lost reply
/// is resolved by querying or re-sending the same identity, never by
/// inventing a new one.
package final class AllocationDriver: EnvironmentProvider, @unchecked Sendable {
  package let store: ControllerStore
  package let hosts: HostDirectory
  package let root: DataRoot
  package let iso: String
  package let isoConfig: String?
  package let relayExecutable: String
  private let sessions = Mutex<[AllocationID: GuestSession]>([:])
  private let keyCache = Mutex<ClientKey?>(nil)
  private let objects: ObjectStore?

  package init(
    store: ControllerStore, hosts: HostDirectory, root: DataRoot, iso: String,
    isoConfig: String? = nil, relayExecutable: String, objects: ObjectStore?
  ) {
    self.isoConfig = isoConfig
    self.store = store
    self.hosts = hosts
    self.root = root
    self.iso = iso
    self.relayExecutable = relayExecutable
    self.objects = objects
  }

  private func clientKey() throws(CIError) -> ClientKey {
    if let key = keyCache.withLock({ $0 }) { return key }
    let key = try ClientKey.ensure(directory: root.keys)
    keyCache.withLock { $0 = key }
    return key
  }

  // MARK: Admission

  package func admit(host alias: Name, profile: ResolvedProfile) throws(CIError) -> Admission {
    guard var record = try store.host(alias) else {
      throw CIError(.notFound, "host \(alias) is not enabled for CI")
    }
    guard record.state == .enabled else {
      throw CIError(
        .admissionRefused,
        "host \(alias) is \(record.state.rawValue): \(record.reason ?? "no reason recorded")")
    }
    let client = try hosts.client(alias)
    let hello: HelloResult
    let epoch: DaemonEpoch
    do { (hello, epoch) = try client.hello() } catch {
      if error.code == .hostUnreachable { try quarantine(alias, error.message) }
      throw error
    }
    guard hello.runtimeQualified else {
      throw CIError(
        .qualificationMissing, "host \(alias) runtime is not qualified: \(hello.runtimeDetail)")
    }
    guard hello.methods.contains(HostMethod.hostCapabilities.rawValue) else {
      throw CIError(
        .capabilityMissing,
        "host \(alias) does not offer host.capabilities (NET-HANDOFF-1 unavailable)")
    }
    let capabilities = try client.capabilities()
    record.capabilities = HostCapabilitiesSnapshot(capabilities, epoch: epoch)
    record.observedAt = store.now
    try store.save(record)
    return try Self.admission(
      alias: alias, hello: hello, epoch: epoch, capabilities: capabilities, profile: profile,
      now: store.now)
  }

  /// The pure admission decision (spec section 2, fail closed).
  package static func admission(
    alias: Name, hello: HelloResult, epoch: DaemonEpoch, capabilities: HostCapabilities,
    profile: ResolvedProfile, now: EpochSeconds
  ) throws(CIError) -> Admission {
    let qualification = capabilities.qualification
    guard capabilities.has(.netHandoff1) else {
      let detail =
        qualification.map {
          "qualification \($0.status.rawValue)\($0.reason.map { ": " + $0 } ?? "")"
        } ?? "no qualification evidence"
      throw CIError(
        .capabilityMissing,
        "host \(alias) does not advertise NET-HANDOFF-1 (\(detail)); no vmnet or NIC fallback is used"
      )
    }
    guard capabilities.transport == "brokered", capabilities.fallbackForbidden else {
      throw CIError(
        .capabilityMissing,
        "host \(alias) run VMs are not on the brokered transport with fallback forbidden")
    }
    guard let qualification, qualification.status == .qualified,
      let manifest = qualification.manifestDigest
    else {
      throw CIError(
        .qualificationMissing,
        "host \(alias) has no current qualification evidence for NET-HANDOFF-1")
    }
    if let expires = qualification.expiresAt, expires <= now {
      throw CIError(.qualificationMissing, "host \(alias) qualification evidence expired")
    }
    // The evidence names one image; only that exact image is qualified.
    guard let qualified = qualification.tuple["image"],
      qualifiedImage(qualified) == ImageIdentity(profile.image, on: alias)
    else {
      throw CIError(
        .qualificationMissing,
        "host \(alias) evidence qualifies image \(qualification.tuple["image"] ?? "none"), not \(profile.image.isoImage)@sha256:\(profile.image.digest(on: alias).rawValue)"
      )
    }
    guard let policy = capabilities.runPolicies[profile.network.egress] else {
      throw CIError(
        .capabilityMissing,
        "host \(alias) has no brokered run policy for egress \(profile.network.egress.rawValue)")
    }
    guard policy.isGrantFree else {
      throw CIError(
        .admissionRefused,
        "host \(alias) run policy grants providers or local services (\((policy.providerGrants + policy.localServices).joined(separator: ", "))); CI requires none"
      )
    }
    switch profile.network.egress {
    case .filtered:
      // An entry the host advertises but iso-ci cannot parse covers nothing.
      let allowed = (policy.publicEgressHosts ?? []).compactMap(HostRule.init)
      let missing = profile.network.requiredHosts.filter { !$0.isCovered(by: allowed) }
        .map(\.rawValue)
      guard missing.isEmpty else {
        throw CIError(
          .admissionRefused,
          "host \(alias) egress allowlist lacks the reviewed endpoint profile: \(missing.joined(separator: ", "))"
        )
      }
    case .none:
      guard policy.publicEgressHosts == nil else {
        throw CIError(
          .admissionRefused, "host \(alias) run policy for egress none still has public egress")
      }
    case .open:
      throw CIError(.admissionRefused, "open egress is never used by CI")
    }
    let limits = profile.limits
    if capabilities.maxTTLSeconds > 0, limits.hardDeadlineSeconds > capabilities.maxTTLSeconds {
      throw CIError(
        .admissionRefused, "profile hard deadline exceeds host \(alias) maximum VM lifetime")
    }
    if capabilities.maxOutputBytes > 0, limits.outputBytes > capabilities.maxOutputBytes {
      throw CIError(.admissionRefused, "profile output limit exceeds host \(alias) maximum")
    }
    return Admission(
      host: alias, hostID: hello.hostID, ownerID: hello.ownerID, epoch: epoch,
      expectedNetworkPolicy: policy.digest, qualificationDigest: manifest,
      qualificationTuple: qualification.tuple, qualificationExpiresAt: qualification.expiresAt,
      retentionModes: capabilities.has(.runRetention1) ? capabilities.retentionModes : [])
  }

  private func quarantine(_ alias: Name, _ reason: String) throws(CIError) {
    guard var record = try store.host(alias) else { return }
    record.state = .quarantined
    record.reason = reason
    try store.save(record)
    try store.event("host:\(alias)", "host.quarantined", "host \(alias) quarantined: \(reason)")
  }

  // MARK: Intents

  /// Persists an intent before sending; returns the existing record when
  /// the same identity was already persisted (a retry).
  private func intent(
    _ id: String, _ allocation: AllocationID, _ kind: IntentRecord.Kind,
    _ parameters: [String: String]
  ) throws(CIError) -> IntentRecord {
    if let existing = try store.intent(id) { return existing }
    let record = IntentRecord(
      id: id, allocation: allocation, kind: kind, parameters: parameters, at: store.now)
    try store.insert(record)
    return record
  }

  private func mark(
    _ intent: inout IntentRecord, _ status: IntentRecord.Status, _ outcome: String? = nil
  )
    throws(CIError)
  {
    intent.status = status
    intent.updatedAt = store.now
    if status == .sent { intent.attempts += 1 }
    if let outcome { intent.outcome = CIError.bounded(outcome) }
    try store.save(intent)
  }

  /// Sends a durable host mutation under a persisted identity and waits for
  /// its receipt. Lost replies leave the intent `uncertain`.
  private func durable(
    _ allocation: AllocationID, _ kind: IntentRecord.Kind, operation: HostOperationID,
    client: HostClient, body: HostRequestBody, timeout: Duration
  ) throws(CIError) -> OperationReceipt {
    var record = try intent(operation.rawValue, allocation, kind, ["host": client.alias.rawValue])
    if record.status == .confirmed || record.status == .refused {
      return try client.operation(operation)
    }
    try mark(&record, .sent)
    do {
      _ = try client.submit(body, operation: operation)
    } catch {
      switch error.code {
      case .operationUncertain, .hostUnreachable:
        try mark(&record, .uncertain, error.message)
        try store.update(allocation) {
          $0.uncertainty = "\(kind.rawValue) outcome unknown: \(error.message)"
        }
        throw CIError(
          .operationUncertain,
          "\(kind.rawValue) outcome is unknown; it will be resolved with the same identity",
          details: ["operation_id": operation.rawValue])
      default:
        try mark(&record, .refused, error.message)
        throw error
      }
    }
    let receipt = try client.wait(operation, timeout: timeout)
    switch receipt.state {
    case .succeeded: try mark(&record, .confirmed, receipt.outcome)
    case .failed, .cancelled: try mark(&record, .refused, receipt.outcome ?? receipt.state.rawValue)
    default: try mark(&record, .sent, "still \(receipt.state.rawValue)")
    }
    try store.update(allocation) { $0.uncertainty = nil }
    return receipt
  }

  /// The identity for a follow-up mutation: reused while its outcome is
  /// pending or uncertain (so a lost reply never duplicates the effect), and
  /// replaced once the host refused it (the host's own guidance: refresh the
  /// observation, then send a new operation).
  private func operationID(
    _ id: AllocationID, _ slot: WritableKeyPath<HostOperations, HostOperationID?>,
    _ prepare: (inout AllocationRecord) -> Void = { _ in }
  ) throws(CIError) -> HostOperationID {
    let record = try store.allocation(id)
    if let existing = record?.operations[keyPath: slot],
      try store.intent(existing.rawValue)?.status != .refused
    {
      return existing
    }
    let fresh = HostOperationID.generate()
    try store.update(id) {
      $0.operations[keyPath: slot] = fresh
      prepare(&$0)
    }
    return fresh
  }

  // MARK: Provisioning

  package func provision(_ id: AllocationID, profile: ResolvedProfile, admission: Admission)
    throws(CIError)
  {
    guard var record = try store.allocation(id) else {
      throw CIError(.notFound, "unknown allocation \(id)")
    }
    if record.readyAt != nil, record.instance != nil { return }
    let client = try hosts.client(record.host)
    let limits = profile.limits
    let spec = try VMSpec(
      name: "ci-" + id.short, image: profile.image.isoImage,
      imageDigest: profile.image.digest(on: record.host),
      cpus: limits.cpus, memoryMiB: limits.memoryMiB, diskGiB: limits.diskGiB,
      egress: profile.network.egress)
    record = try store.update(id) {
      $0.hostID = admission.hostID
      $0.ownerID = admission.ownerID
      $0.provenance.networkPolicyDigest = admission.expectedNetworkPolicy
      $0.provenance.qualificationDigest = admission.qualificationDigest
      $0.provenance.qualificationTuple = admission.qualificationTuple
      $0.vmCleanup = .pending
    }
    let receipt = try durable(
      id, .hostRunCreate, operation: record.operations.create, client: client,
      body: .runCreate(
        run: record.hostRun, spec: spec, outputLimitBytes: limits.outputBytes,
        ttlSeconds: limits.hardDeadlineSeconds),
      timeout: .seconds(Int64(limits.bootSeconds)))
    let run = try client.inspectRun(record.hostRun)
    try store.update(id) {
      $0.observedRunPhase = run.phase
      $0.runGeneration = run.generation
      $0.lastObservedAt = store.now
    }
    guard receipt.state == .succeeded, run.phase == .running, let instanceID = run.instanceID,
      let runtime = run.runtimeID
    else {
      let reason = receipt.outcome ?? "run is \(run.phase.rawValue)"
      try store.update(id) {
        $0.note("provisioning failed: \(reason)")
        if run.phase == .destroyed { $0.vmCleanup = .verified }
      }
      throw CIError(.hostRefused, "provisioning on \(record.host) failed: \(reason)")
    }
    let instance = QualifiedInstance(
      hostID: admission.hostID, ownerID: admission.ownerID, instanceID: instanceID,
      runtimeID: runtime,
      guestOS: "linux")
    let observation = try client.inspectVM(instance)
    guard observation.state == .running, let boot = observation.bootID,
      let proof = observation.network,
      proof.bootID == boot, proof.networkPolicy == admission.expectedNetworkPolicy
    else {
      try store.update(id) {
        $0.instance = instance
        $0.desired = .release
        $0.note("live brokered proof did not match the admitted policy")
      }
      throw CIError(
        .admissionRefused, "the new VM's brokered proof does not match the admitted network policy")
    }
    try store.update(id) {
      $0.instance = instance
      $0.bootID = boot
      $0.networkProof = proof
      $0.readyAt = store.now
      if let expires = observation.expiresAt { $0.hardDeadline = min($0.hardDeadline, expires) }
    }
    try store.event(
      "allocation:\(id)", "allocation.provisioned", "VM ready on \(record.host)",
      data: [
        "instance": instanceID.rawValue, "boot": boot.rawValue,
        "network_policy": proof.networkPolicy.short,
      ])
  }

  // MARK: Observation

  package func observe(_ id: AllocationID) throws(CIError) {
    guard let record = try store.allocation(id) else {
      throw CIError(.notFound, "unknown allocation \(id)")
    }
    let client = try hosts.client(record.host)
    let run: RunObservation
    do {
      run = try client.inspectRun(record.hostRun)
    } catch {
      if error.code == .notFound, record.instance == nil {
        // The create never reached the host: nothing was allocated.
        try resolveUnsentCreate(record, client: client)
        return
      }
      try store.update(id) {
        $0.uncertainty = "host observation failed: \(error.message)"
        $0.lastObservedAt = store.now
      }
      if error.code == .hostUnreachable { try quarantine(record.host, error.message) }
      throw error
    }
    try store.update(id) {
      $0.observedRunPhase = run.phase
      $0.runGeneration = run.generation
      $0.lastObservedAt = store.now
      $0.retentionUntil =
        run.liveRetentionUntil ?? (run.phase == .running ? nil : run.retentionDeadline)
      if run.phase == .destroyed {
        $0.vmCleanup = .verified
        if $0.execution == .pending || $0.execution == .running || $0.execution == .unknown {
          $0.execution = $0.execution == .pending && $0.readyAt == nil ? .cancelled : .interrupted
        }
      }
      if let intent = try? store.intent($0.operations.create.rawValue), intent.status == .uncertain
      {
        $0.uncertainty = nil
      }
    }
    if let intent = try store.intent(record.operations.create.rawValue), intent.status == .uncertain
    {
      var resolved = intent
      try mark(&resolved, .confirmed, "run observed after an uncertain reply")
    }
  }

  /// The create identity is unknown to the host: if its operation is also
  /// unknown, the request never arrived and nothing holds resources.
  private func resolveUnsentCreate(_ record: AllocationRecord, client: HostClient) throws(CIError) {
    do {
      _ = try client.operation(record.operations.create)
      return
    } catch {
      guard error.code == .notFound else { throw error }
    }
    if var intent = try store.intent(record.operations.create.rawValue) {
      try mark(&intent, .refused, "the host never received the request")
    }
    try store.update(record.id) {
      $0.uncertainty = nil
      $0.vmCleanup = .verified
      if !$0.execution.isTerminal { $0.execution = .cancelled }
    }
  }

  // MARK: Guest access

  private func session(_ id: AllocationID) throws(CIError) -> GuestSession {
    if let live = sessions.withLock({ $0[id] }), live.isLive { return live }
    guard let record = try store.allocation(id), let instance = record.instance else {
      throw CIError(.conflict, "allocation \(id) has no VM")
    }
    let opened = try GuestSession.open(
      client: try hosts.client(record.host), instance: instance,
      expectedPolicy: record.provenance.networkPolicyDigest, key: try clientKey(),
      sessionsDirectory: root.sessions, iso: iso, isoConfig: isoConfig,
      relayExecutable: relayExecutable)
    let replaced = sessions.withLock { sessions -> GuestSession? in
      let old = sessions[id]
      sessions[id] = opened
      return old
    }
    replaced?.close()
    return opened
  }

  package func execute(_ id: AllocationID, _ command: GuestCommand) throws(CIError)
    -> GuestCommandResult
  {
    try session(id).run(command)
  }

  package func holdSession(_ id: AllocationID, forwards: [ServiceForward]) throws(CIError) {
    try session(id).startForwards(forwards)
  }

  package func closeSession(_ id: AllocationID) {
    let session = sessions.withLock { $0.removeValue(forKey: id) }
    session?.close()
  }

  /// An explicitly authorized operator debug session (no new privileged
  /// credentials are acquired; existing guest state may still hold some).
  package func debugSession(_ id: AllocationID) throws(CIError) -> GuestSession {
    guard let record = try store.allocation(id), let instance = record.instance else {
      throw CIError(.conflict, "allocation \(id) has no VM")
    }
    return try GuestSession.open(
      client: try hosts.client(record.host), instance: instance,
      expectedPolicy: record.provenance.networkPolicyDigest, key: try clientKey(),
      sessionsDirectory: root.sessions, iso: iso, isoConfig: isoConfig,
      relayExecutable: relayExecutable)
  }

  // MARK: Retention, completion, release

  package func retain(_ id: AllocationID, mode: RetentionMode, seconds: UInt64) throws(CIError) {
    guard let record = try store.allocation(id) else {
      throw CIError(.notFound, "unknown allocation \(id)")
    }
    let client = try hosts.client(record.host)
    let capabilities = try client.capabilities()
    guard capabilities.has(.runRetention1), capabilities.retentionModes.contains(mode) else {
      throw CIError(
        .capabilityMissing, "host \(record.host) does not offer \(mode.rawValue) retention")
    }
    let run = try client.inspectRun(record.hostRun)
    let operation = try operationID(id, \.retain)
    let receipt = try durable(
      id, .hostRunRetain, operation: operation, client: client,
      body: .runRetain(
        run: record.hostRun, expectedGeneration: run.generation, mode: mode, seconds: seconds),
      timeout: .seconds(120))
    guard receipt.state == .succeeded else {
      throw CIError(
        .hostRefused, "retention was refused: \(receipt.outcome ?? receipt.state.rawValue)")
    }
    // A retained VM's existing grants are revoked by the host.
    closeSession(id)
    let after = try client.inspectRun(record.hostRun)
    try store.update(id) {
      $0.desired = mode == .live ? .retainLive : .retainStopped
      $0.retentionUntil = after.liveRetentionUntil ?? after.retentionDeadline
      $0.runGeneration = after.generation
      $0.observedRunPhase = after.phase
    }
    try store.event(
      "allocation:\(id)", "allocation.retained",
      "\(mode.rawValue) retention until \(after.liveRetentionUntil ?? after.retentionDeadline ?? 0)"
    )
  }

  package func complete(_ id: AllocationID, exitStatus: Int32?) throws(CIError) {
    guard let record = try store.allocation(id) else {
      throw CIError(.notFound, "unknown allocation \(id)")
    }
    let client = try hosts.client(record.host)
    let run = try client.inspectRun(record.hostRun)
    guard run.phase == .running else {
      try observe(id)
      return
    }
    // Export is tracked only once requested; a run that never asked for
    // results keeps `notRequested` whatever the host stages.
    let requested = record.export != .notRequested
    let operation = try operationID(id, \.complete) { if requested { $0.export = .pending } }
    let receipt = try durable(
      id, .hostRunComplete, operation: operation, client: client,
      body: .runComplete(
        run: record.hostRun, expectedGeneration: run.generation, exitStatus: exitStatus),
      timeout: .seconds(Int64(record.completionGraceSeconds ?? 900)))
    closeSession(id)
    let after = try client.inspectRun(record.hostRun)
    var exported: ExportOutcome = after.phase == .resultsPending ? .exported : .failed
    var staged: Digest?
    if receipt.state != .succeeded && after.phase != .resultsPending { exported = .failed }
    if requested, after.phase == .resultsPending, let handle = after.artifact,
      let digest = after.artifactDigest,
      let objects
    {
      do {
        let bytes = try client.readArtifact(handle, digest: digest, limit: 256 << 20)
        let stored = try objects.importBytes(bytes, kind: .result)
        try objects.grant(subject: "allocation:\(id)", kind: .result, digest: stored)
        staged = stored
        try store.event(
          "allocation:\(id)", "allocation.results", "results staged", data: ["digest": stored.short]
        )
      } catch {
        exported = .failed
        try store.update(id) { $0.note("result download failed: \(error.message)") }
      }
    }
    let outcome = requested ? exported : .notRequested
    let digest = staged
    try store.update(id) {
      $0.export = outcome
      if let digest { $0.resultDigest = digest }
      $0.observedRunPhase = after.phase
      $0.runGeneration = after.generation
      $0.retentionUntil = after.retentionDeadline
      $0.finishedAt = $0.finishedAt ?? store.now
    }
  }

  /// `iso-ci results`: asks for an open allocation's results to be staged
  /// when its run completes, or, once staged, copies the archive into
  /// `directory` (an operator-chosen path; the bytes stay an opaque file).
  package func results(_ id: AllocationID, saveInto directory: String?) throws(CIError) -> JSONValue
  {
    guard let record = try store.allocation(id) else {
      throw CIError(.notFound, "unknown allocation \(id)")
    }
    if record.export == .exported, let digest = record.resultDigest {
      guard let directory else {
        return ["export": "exported", "digest": .string(digest.rawValue)]
      }
      guard let objects else { throw CIError(.unsupported, "no object store") }
      let path = try objects.exportCopy(
        subject: "allocation:\(id)", kind: .result, digest: digest, into: directory)
      return ["export": "exported", "digest": .string(digest.rawValue), "path": .string(path)]
    }
    guard record.export == .notRequested else {
      return ["export": .string(record.export.rawValue)]
    }
    guard record.observedRunPhase == .running || record.observedRunPhase == nil,
      record.vmCleanup != .verified
    else {
      throw CIError(.conflict, "allocation \(id.short) has already completed without results")
    }
    try store.update(id) { $0.export = .requested }
    try store.event("allocation:\(id)", "allocation.results_requested", "results requested")
    return ["export": "requested"]
  }

  package func release(_ id: AllocationID) throws(CIError) {
    guard var record = try store.allocation(id) else {
      throw CIError(.notFound, "unknown allocation \(id)")
    }
    closeSession(id)
    if record.instance == nil, record.readyAt == nil {
      // Never provisioned (or the create is unresolved): observe instead.
      do { try observe(id) } catch {
        if error.code != .notFound { throw error }
      }
      record = try store.allocation(id) ?? record
      if record.vmCleanup == .verified { return }
    }
    let client = try hosts.client(record.host)
    var run: RunObservation
    do { run = try client.inspectRun(record.hostRun) } catch {
      if error.code == .notFound {
        try store.update(id) { $0.vmCleanup = .verified }
        return
      }
      try store.update(id) {
        $0.vmCleanup = .debt
        $0.note("cleanup could not be verified: \(error.message)")
      }
      throw error
    }
    if run.phase == .destroyed {
      try store.update(id) { $0.vmCleanup = .verified }
      return
    }
    if run.phase == .running && run.liveRetentionUntil == nil {
      try complete(id, exitStatus: nil)
      run = try client.inspectRun(record.hostRun)
    }
    // A live-retained run past its window is being stopped by the host,
    // which refuses a discard until then; the next pass discards it.
    if run.phase == .running, let until = run.liveRetentionUntil, until <= store.now {
      try store.update(id) {
        $0.observedRunPhase = run.phase
        $0.note("live retention ended; waiting for the host to stop the VM")
      }
      return
    }
    let operation = try operationID(id, \.release)
    let receipt: OperationReceipt
    do {
      receipt = try durable(
        id, .hostRunDiscard, operation: operation, client: client,
        body: .runResultsDiscard(run: record.hostRun, expectedGeneration: run.generation),
        timeout: .seconds(600))
    } catch {
      try store.update(id) {
        $0.vmCleanup = .debt
        $0.note("release not verified: \(error.message)")
      }
      throw error
    }
    // Only a destroyed phase or the host no longer knowing the run counts
    // as verified; an unreachable host after the discard is cleanup debt.
    var after: RunObservation?
    var gone = false
    do { after = try client.inspectRun(record.hostRun) } catch {
      gone = error.code == .notFound
    }
    let verified = receipt.state == .succeeded && (after?.phase == .destroyed || gone)
    try store.update(id) {
      $0.vmCleanup = verified ? .verified : .debt
      $0.observedRunPhase = after?.phase ?? $0.observedRunPhase
      if !verified {
        $0.note("host did not verify deletion: \(receipt.outcome ?? receipt.state.rawValue)")
      }
    }
    try store.event(
      "allocation:\(id)", verified ? "allocation.released" : "allocation.cleanup_debt",
      verified ? "VM destroyed and verified" : "cleanup not verified; still counted against budgets"
    )
  }
}

/// An image name bound to its content digest.
package struct ImageIdentity: Sendable, Equatable {
  package let name: String
  package let digest: Digest

  package init(name: String, digest: Digest) {
    self.name = name
    self.digest = digest
  }

  package init(_ image: ImageDescriptor, on host: Name) {
    self.init(name: image.isoImage, digest: image.digest(on: host))
  }
}

/// Parses the evidence tuple's `name@<digest>` (bare hex or `sha256:` hex).
package func qualifiedImage(_ raw: String) -> ImageIdentity? {
  let parts = raw.split(separator: "@", maxSplits: 1).map(String.init)
  guard parts.count == 2, !parts[0].isEmpty, let digest = try? Digest(prefixed: parts[1]) else {
    return nil
  }
  return ImageIdentity(name: parts[0], digest: digest)
}
