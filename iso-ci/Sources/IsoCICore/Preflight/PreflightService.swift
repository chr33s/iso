import Foundation
import Synchronization

/// Runs an async closure to completion from synchronous controller code.
/// Only called from controller threads, never from the cooperative pool.
package func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
  let box = Mutex<T?>(nil)
  let done = DispatchSemaphore(value: 0)
  Task {
    let value = await body()
    box.withLock { $0 = value }
    done.signal()
  }
  done.wait()
  return box.withLock { $0! }
}

/// Synthetic-step scripts keyed by the snapshot digest the broker passes.
package final class SnapshotScriptRegistry: SyntheticStepScripts {
  private let references = Mutex<[Digest: SnapshotReference]>([:])

  package init() {}

  package func register(_ reference: SnapshotReference) {
    references.withLock { $0[reference.digest] = reference }
  }

  package func script(for kind: StepKind, snapshot: Digest?) -> String? {
    guard let snapshot, let reference = references.withLock({ $0[snapshot] }) else { return nil }
    return OverlayScripts.script(for: kind, snapshot: reference)
  }
}

/// Approved action archives the operator imported (`iso-ci actions import`).
package enum ApprovedActions {
  static func key(_ nameWithOwner: String, _ ref: String) -> String {
    "action:\(nameWithOwner)@\(ref)"
  }

  package static func save(_ action: ResolvedAction, store: ControllerStore) throws(CIError) {
    try store.setMeta(key(action.nameWithOwner, action.ref), try ControllerStore.encode(action))
  }

  package static func load(_ nameWithOwner: String, _ ref: String, store: ControllerStore)
    throws(CIError)
    -> ResolvedAction?
  {
    guard let text = try store.meta(key(nameWithOwner, ref)) else { return nil }
    return try ControllerStore.decode(ResolvedAction.self, text)
  }
}

/// The preflight graph/session manager (spec sections 3, 9): compiles a
/// workflow against a working-tree snapshot, runs each job attempt in its
/// own clean VM through the official runner and the confined data plane,
/// and supports inspection, debug, patch, abort and fresh whole-job retry.
package final class PreflightService: ControllerService, @unchecked Sendable {
  package static let guestPort: UInt16 = 47_311

  package let name = "preflight"
  private let root: DataRoot
  private let store: ControllerStore
  private let objects: ObjectStore
  private let provider: any EnvironmentProvider
  private let executable: String
  private let loadConfiguration: @Sendable () -> Result<CIConfiguration, CIError>
  private let scripts = SnapshotScriptRegistry()
  private let broker: DataPlaneBroker
  private let state = Mutex<State>(State())

  private struct State {
    var supervisor: DataPlaneSupervisor?
    var confinementFailure: CIError?
    /// Mapped secret values, per run, in controller memory only.
    var secrets: [PreflightRunID: [String: String]] = [:]
    var launching: Set<JobAttemptID> = []
    /// Allocations a `finish` is currently stopping or retaining.
    var finishing: Set<AllocationID> = []
    var consuming = false
  }

  package init(
    root: DataRoot, store: ControllerStore, objects: ObjectStore, provider: any EnvironmentProvider,
    executable: String,
    loadConfiguration: @escaping @Sendable () -> Result<CIConfiguration, CIError>
  ) {
    self.root = root
    self.store = store
    self.objects = objects
    self.provider = provider
    self.executable = executable
    self.loadConfiguration = loadConfiguration
    broker = DataPlaneBroker(
      store: objects, childStaging: root.staging + "/dataplane", scripts: scripts)
  }

  /// Whether mapped secret values for `run` are still in controller memory.
  func holdsSecrets(_ run: PreflightRunID) -> Bool {
    state.withLock { $0.secrets[run] != nil }
  }

  // MARK: Data plane

  /// Starts the confined child once; failure to establish confinement
  /// refuses preflight admission (no unconfined fallback).
  private func dataPlane() throws(CIError) {
    if state.withLock({ $0.supervisor?.isRunning ?? false }) { return }
    let paths = DataPlaneSupervisor.Paths(
      executable: executable, socket: root.dataPlaneSocket, staging: root.staging + "/dataplane",
      probe: root.keys + "/confinement-probe")
    try PrivateFiles.ensureDirectory(paths.staging)
    if access(paths.probe, F_OK) != 0 {
      try PrivateFiles.write(Array("probe\n".utf8), to: paths.probe)
    }
    let broker = self.broker
    let result: Result<DataPlaneSupervisor, CIError> = blocking {
      do throws(CIError) {
        return .success(try await DataPlaneSupervisor.launch(paths: paths, broker: broker))
      } catch {
        return .failure(error)
      }
    }
    switch result {
    case .success(let supervisor):
      state.withLock {
        $0.supervisor = supervisor
        $0.confinementFailure = nil
      }
      startConsuming()
    case .failure(let error):
      state.withLock { $0.confinementFailure = error }
      throw error
    }
  }

  private func startConsuming() {
    let first = state.withLock { state -> Bool in
      guard !state.consuming else { return false }
      state.consuming = true
      return true
    }
    guard first else { return }
    let notices = broker.notices
    Thread.detachNewThread { [self] in
      blocking {
        for await notice in notices { self.handle(notice) }
      }
    }
  }

  // MARK: Submission

  private func submit(_ params: JSONValue) throws(CIError) -> JSONValue {
    var r = try ObjectReader(params, field: "params")
    let workflow = try r.string("workflow")
    let repositoryPath = try r.string("repository")
    let platform = try r.string("platform")
    let event = try r.optionalString("event") ?? "push"
    let include = try r.strings("include")
    let exclude = try r.strings("exclude")
    let host = try r.optionalParsed("host", as: Name.self)
    var secrets: [String: String] = [:]
    if let raw = r.optional("secrets"), case .object(let members) = raw {
      for (key, value) in members {
        guard JobMessageBuilder.isSecretName(key), let text = value.stringValue else {
          throw CIError.invalid("invalid secret mapping")
        }
        secrets[key] = text
      }
    }
    var inputs: [String: String] = [:]
    if let raw = r.optional("inputs"), case .object(let members) = raw {
      for (key, value) in members { inputs[key] = value.stringValue ?? "" }
    }
    try r.finish()
    guard platform == "linux/arm64" else {
      throw CIError(.compatibilityRejected, "only linux/arm64 preflight is supported")
    }
    let configuration = try loadConfiguration().get()
    guard let preflight = configuration.preflight else {
      throw CIError.config("no preflight section is configured")
    }
    let profile = try ResolvedProfile(name: preflight.profile, configuration: configuration)
    for (kind, name, digest) in configuration.descriptors(of: preflight.profile) {
      guard try store.approval(kind, name)?.digest == digest else {
        throw CIError(
          .admissionRefused, "\(kind.rawValue) \(name) is not approved at its current digest")
      }
    }
    guard let manifestID = profile.compatibility.manifest else {
      throw CIError.config("preflight compatibility has no manifest")
    }
    let manifest = try CompatibilityManifest.builtin(manifestID)
    if let host, !preflight.hosts.contains(host) {
      throw CIError(.admissionRefused, "host \(host) is not configured for preflight")
    }
    guard repositoryPath.hasPrefix("/") else {
      throw CIError.invalid("repository must be an absolute path")
    }
    let workflowPath =
      workflow.hasPrefix(repositoryPath + "/")
      ? String(workflow.dropFirst(repositoryPath.count + 1)) : workflow
    guard !workflowPath.hasPrefix("/"), !workflowPath.split(separator: "/").contains("..") else {
      throw CIError.invalid("the workflow must be inside the repository")
    }
    // Capture the immutable snapshot before compiling against it.
    var options = SnapshotOptions(outputDirectory: root.staging + "/snapshots")
    // Only untracked paths matching an explicit include are captured.
    options.include = include
    options.exclude = exclude
    options.workflowPath = workflowPath
    try PrivateFiles.ensureDirectory(options.outputDirectory)
    let capture = try SnapshotCapture.capture(repository: repositoryPath, options: options)
    defer { PrivateFiles.remove(capture.archivePath) }
    let imported = try objects.importFile(capture.archivePath, kind: .snapshot)
    guard imported.digest == capture.digest else {
      throw CIError(.internalError, "snapshot changed while importing")
    }
    let reference = capture.reference
    scripts.register(reference)
    guard let source = try PrivateFiles.read(repositoryPath + "/" + workflowPath, limit: 1 << 20)
    else {
      throw CIError(.notFound, "workflow \(workflowPath) does not exist")
    }
    let repository = Self.repositoryName(repositoryPath)
    let github: JSONValue = [
      "repository": .string(repository), "sha": .string(reference.baseCommit),
      "ref": "refs/heads/iso-ci-preflight", "event_name": .string(event),
      "workflow": .string(workflowPath), "actor": "iso-ci",
    ]
    let plan = try WorkflowCompiler.compile(
      source: Data(source), path: workflowPath, event: event, eventPayload: [:], manifest: manifest,
      platformMap: preflight.platformMap, inputs: inputs.mapValues { .string($0) }, github: github,
      snapshot: reference)
    for action in plan.actions {
      guard case .repository(_, _, _, let ref) = action, let name = action.nameWithOwner else {
        continue
      }
      if name == "actions/checkout" { continue }
      guard try ApprovedActions.load(name, ref, store: store) != nil else {
        throw CIError(
          .compatibilityRejected,
          "action \(action.displayName) has no approved archive; run `iso-ci actions import \(action.displayName)`"
        )
      }
    }
    let id = PreflightRunID.generate()
    let revision = InputRevision(
      number: 0, baseCommit: reference.baseCommit, snapshot: reference.digest,
      dirty: reference.isDirty,
      capturedAt: capture.capturedAt, patchedAttempt: nil)
    let record = PreflightRunRecord(
      id: id, repositoryPath: repositoryPath, repository: repository, plan: plan,
      revision: revision,
      createdAt: store.now, pinnedHost: host, profile: preflight.profile, inputs: inputs,
      secretNames: secrets.keys.sorted(), retainOnFailure: .live)
    try store.db.transaction { () throws(CIError) in
      try store.savePreflightRun(id, createdAt: record.createdAt, record)
      for job in plan.jobs {
        let attempt = JobAttemptRecord(
          id: .generate(), run: id, jobKey: job.key, number: 1, inputRevision: 0)
        try store.savePreflightJob(attempt: attempt.id, run: id, jobKey: job.key, attempt)
      }
    }
    try objects.grant(subject: "run:\(id)", kind: .snapshot, digest: reference.digest)
    state.withLock { $0.secrets[id] = secrets }
    try store.event(
      "run:\(id)", "run.submitted",
      "\(plan.jobs.count) job(s) from \(workflowPath); snapshot sha256:\(reference.digest.short)\(reference.isDirty ? " (includes uncommitted changes)" : "")",
      data: ["base_commit": reference.baseCommit, "plan": plan.digest.short])
    return [
      "run": .string(id.rawValue), "jobs": .integer(Int64(plan.jobs.count)),
      "snapshot": .string(reference.digest.rawValue), "base_commit": .string(reference.baseCommit),
      "dirty": .bool(reference.isDirty), "plan": .string(plan.digest.rawValue),
      "included_untracked": .array(capture.manifest.includedUntracked.map(JSONValue.string)),
      "excluded": .array(capture.excludedPaths.map(JSONValue.string)),
    ]
  }

  /// `OWNER/REPOSITORY` from the origin remote, else `local/<directory>`.
  /// The repository's own config is parsed as data (`GitIndex.originURL`):
  /// no Git process runs and no include, system or global config applies.
  static func repositoryName(_ path: String) -> String {
    if let layout = try? GitIndex.layout(containing: path),
      let origin = try? GitIndex.originURL(layout)
    {
      var url = origin
      if url.hasSuffix(".git") { url.removeLast(4) }
      let parts = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).suffix(2).map(String.init)
      if parts.count == 2, let name = try? RepositoryName(parts[0] + "/" + parts[1]) {
        return name.rawValue
      }
    }
    let base = (path as NSString).lastPathComponent
    return "local/" + (base.isEmpty ? "repository" : base)
  }

  // MARK: Records

  private func run(_ id: PreflightRunID) throws(CIError) -> PreflightRunRecord {
    guard let record = try store.preflightRun(id, as: PreflightRunRecord.self) else {
      throw CIError(.notFound, "unknown preflight run \(id)")
    }
    return record
  }

  /// Total bytes of one attempt's stored runner logs returned at once.
  package static let jobLogLimit = 4 << 20

  /// The stored runner logs of one job attempt (the latest unless
  /// `attempt` is given), as text with control characters other than
  /// newline and tab removed: the bytes are guest-authored.
  private func jobLogs(_ params: JSONValue) throws(CIError) -> JSONValue {
    var r = try ObjectReader(params, field: "params")
    let run = try r.parsed("run", as: PreflightRunID.self)
    let job = try r.string("job")
    let number = try r.optionalInt("attempt")
    try r.finish()
    guard try store.preflightRun(run, as: PreflightRunRecord.self) != nil else {
      throw CIError(.notFound, "unknown run \(run)")
    }
    let candidates = try attempts(run).filter { $0.jobKey == job }
    let chosen =
      number.map { n in candidates.first { Int64($0.number) == n } }
      ?? candidates.max { $0.number < $1.number }
    guard let attempt = chosen else {
      throw CIError(.notFound, "no attempt of job \(job) in run \(run)")
    }
    var remaining = Self.jobLogLimit
    var truncated = false
    var segments: [JSONValue] = []
    for digest in attempt.logObjects {
      guard remaining > 0 else {
        truncated = true
        break
      }
      guard try objects.exists(kind: .log, digest: digest) else { continue }
      let bytes = try Self.readPrefix(objects.path(digest), limit: remaining)
      if bytes.count == remaining { truncated = true }
      remaining -= bytes.count
      segments.append(.string(Self.printable(bytes)))
    }
    return [
      "run": .string(run.rawValue), "job": .string(job), "attempt": .integer(Int64(attempt.number)),
      "logs": .array(segments), "truncated": .bool(truncated),
    ]
  }

  static func readPrefix(_ path: String, limit: Int) throws(CIError) -> [UInt8] {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      throw CIError.storage("cannot read a stored log")
    }
    defer { try? handle.close() }
    return Array((try? handle.read(upToCount: limit)) ?? Data())
  }

  /// Guest-authored text for an operator terminal: no escape sequences.
  static func printable(_ bytes: [UInt8]) -> String {
    String(decoding: bytes, as: UTF8.self).unicodeScalars.reduce(into: "") { out, scalar in
      if scalar == "\n" || scalar == "\t" || !(scalar.properties.generalCategory == .control) {
        out.unicodeScalars.append(scalar)
      }
    }
  }

  private func attempts(_ id: PreflightRunID) throws(CIError) -> [JobAttemptRecord] {
    try store.preflightJobs(run: id, as: JobAttemptRecord.self)
  }

  /// The latest attempt per job key.
  private func latest(_ attempts: [JobAttemptRecord]) -> [String: JobAttemptRecord] {
    var out: [String: JobAttemptRecord] = [:]
    for attempt in attempts where (out[attempt.jobKey]?.number ?? 0) < attempt.number {
      out[attempt.jobKey] = attempt
    }
    return out
  }

  private func save(_ attempt: JobAttemptRecord) throws(CIError) {
    try store.savePreflightJob(
      attempt: attempt.id, run: attempt.run, jobKey: attempt.jobKey, attempt)
  }

  private func updateAttempt(_ id: JobAttemptID, _ change: (inout JobAttemptRecord) -> Void)
    throws(CIError)
    -> JobAttemptRecord
  {
    try store.db.transaction { () throws(CIError) -> JobAttemptRecord in
      guard var attempt = try store.preflightJob(id, as: JobAttemptRecord.self) else {
        throw CIError(.notFound, "unknown attempt \(id)")
      }
      change(&attempt)
      try save(attempt)
      return attempt
    }
  }

  private static func jobState(_ state: JobAttemptState) -> JobState {
    switch state {
    case .pending, .provisioning: .pending
    case .running: .running
    case .succeeded: .succeeded
    case .failed, .interrupted: .failed
    case .cancelled: .cancelled
    case .skipped: .skipped
    }
  }

  private func outcomes(_ latest: [String: JobAttemptRecord]) -> [String: JobOutcome] {
    latest.mapValues { JobOutcome(state: Self.jobState($0.state), outputs: $0.outputs) }
  }

  // MARK: Reconciliation

  package static let reservationLifetime: EpochSeconds = 6 * 3_600

  package func reconcile(now: EpochSeconds) {
    if let ids = try? store.preflightRunIDs(limit: 200) {
      for id in ids {
        guard let record = try? run(id), record.state == .running || record.state == .aborting
        else { continue }
        tick(record, now: now)
      }
    }
    sweep(now: now)
    // A reservation whose uploader vanished must not block its key forever.
    try? objects.cacheExpireReservations(
      before: now > Self.reservationLifetime ? now - Self.reservationLifetime : 0)
  }

  /// Every preflight allocation has an owner until it settles: once its
  /// attempt is over, retained environments are released when their window
  /// ends and anything else is released (with cleanup retried as debt).
  private func sweep(now: EpochSeconds) {
    for allocation in (try? store.openAllocations()) ?? [] where allocation.kind == .preflight {
      if state.withLock({ $0.finishing.contains(allocation.id) }) { continue }
      if let attempt = allocation.jobAttempt {
        if state.withLock({ $0.launching.contains(attempt) }) { continue }
        if let record = try? store.preflightJob(attempt, as: JobAttemptRecord.self),
          !record.state.isTerminal
        {
          continue
        }
      }
      switch allocation.desired {
      case .retainLive, .retainStopped:
        try? provider.observe(allocation.id)
        let current = (try? store.allocation(allocation.id)) ?? allocation
        let windowOver = current.retentionUntil.map { $0 <= now } ?? false
        let liveGone = allocation.desired == .retainLive && current.observedRunPhase != .running
        guard windowOver || liveGone || current.hardDeadline <= now else { continue }
        finish(allocation: allocation.id, failed: false, retain: .disabled)
      default:
        finish(allocation: allocation.id, failed: false, retain: .disabled)
      }
    }
  }

  private func tick(_ record: PreflightRunRecord, now: EpochSeconds) {
    guard let all = try? attempts(record.id) else { return }
    var current = latest(all)
    // Lost environments: a running attempt whose VM is gone is interrupted.
    for attempt in current.values where attempt.state == .running || attempt.state == .provisioning
    {
      if state.withLock({ $0.launching.contains(attempt.id) }) { continue }
      guard let allocation = attempt.allocation else {
        // Provisioning without a recorded VM and no live launch (a
        // controller restart): nothing was allocated, so queue it again.
        if attempt.state == .provisioning,
          let updated = try? updateAttempt(
            attempt.id,
            {
              if $0.state == .provisioning, $0.allocation == nil { $0.state = .pending }
            })
        {
          current[updated.jobKey] = updated
        }
        continue
      }
      guard let alloc = try? store.allocation(allocation) else { continue }
      if attempt.state == .running, attempt.acquiredAt == nil, let started = attempt.startedAt,
        now >= started + bootAllowance(record)
      {
        failUnacquired(attempt, allocation: allocation, run: record, now: now)
        if let updated = try? store.preflightJob(attempt.id, as: JobAttemptRecord.self) {
          current[updated.jobKey] = updated
        }
        continue
      }
      try? provider.observe(allocation)
      let refreshed = (try? store.allocation(allocation)) ?? alloc
      // A launch that died with the controller cannot resume its bootstrap.
      let orphaned = attempt.state == .provisioning
      let ended =
        refreshed.observedRunPhase != .running || refreshed.vmCleanup == .verified
        || alloc.hardDeadline <= now
      guard orphaned || ended else { continue }
      let reason =
        orphaned
        ? "the launch was interrupted (controller restart) before the runner started"
        : "the environment ended before a job result (phase \(refreshed.observedRunPhase?.rawValue ?? "unknown"))"
      guard
        let updated = try? updateAttempt(
          attempt.id,
          {
            // Never overwrite a result that arrived meanwhile.
            guard !$0.state.isTerminal else { return }
            $0.state = .interrupted
            $0.reason = reason
            $0.finishedAt = now
          })
      else { continue }
      current[updated.jobKey] = updated
      guard updated.state == .interrupted else { continue }
      _ = try? store.update(allocation) { $0.execution = .interrupted }
      finish(allocation: allocation, failed: false, retain: .disabled)
    }
    if record.state == .aborting {
      // Abort: cancel everything unfinished and launch nothing new.
      for attempt in current.values where !attempt.state.isTerminal {
        mark(attempt, .cancelled, "run aborted by operator")
        if let allocation = attempt.allocation { stop(allocation) }
      }
      if let refreshed = try? attempts(record.id) { current = latest(refreshed) }
    }
    let graph = JobGraph(plan: record.plan)
    // The graph counts running jobs itself: pass the configured total.
    let limit = Int(((try? loadConfiguration().get())?.preflight?.maxParallelJobs) ?? 1)
    let decision = graph.schedule(
      outcomes: outcomes(current), runCancelled: record.state == .aborting,
      base: ExpressionContexts(github: ["repository": .string(record.repository)]), limit: limit)
    for transition in decision.skip { mark(current[transition.key], .skipped, transition.reason) }
    for transition in decision.fail { mark(current[transition.key], .failed, transition.reason) }
    for transition in decision.cancel {
      guard let attempt = current[transition.key] else { continue }
      mark(attempt, .cancelled, transition.reason)
      if let allocation = attempt.allocation, attempt.state == .running { stop(allocation) }
    }
    for key in decision.ready {
      guard let attempt = current[key], attempt.state == .pending else { continue }
      let started = state.withLock { $0.launching.insert(attempt.id).inserted }
      guard started else { continue }
      _ = try? updateAttempt(attempt.id) {
        $0.state = .provisioning
        $0.startedAt = now
      }
      Thread.detachNewThread { [self] in
        defer { _ = state.withLock { $0.launching.remove(attempt.id) } }
        launch(record.id, attempt.id)
      }
    }
    // Settle the run once every job has a terminal outcome.
    guard let refreshed = try? attempts(record.id) else { return }
    let conclusion = graph.conclusion(outcomes: outcomes(latest(refreshed)))
    if conclusion != .inProgress, latest(refreshed).values.allSatisfy({ $0.state.isTerminal }) {
      var updated = record
      updated.state = record.state == .aborting ? .aborted : .finished
      updated.conclusion = conclusion.rawValue
      updated.finishedAt = now
      try? store.savePreflightRun(record.id, createdAt: record.createdAt, updated)
      // Mapped secrets never outlive the run; a later retry asks for a
      // resubmission instead (`registerEndpoint`).
      state.withLock { _ = $0.secrets.removeValue(forKey: record.id) }
      _ = try? store.event(
        "run:\(record.id)", "run.finished",
        "run \(conclusion.rawValue)\(record.baseRevision.dirty ? " (with uncommitted changes; not evidence for the base commit)" : "")"
      )
    }
  }

  private func mark(_ attempt: JobAttemptRecord?, _ to: JobAttemptState, _ reason: String) {
    guard let attempt, !attempt.state.isTerminal else { return }
    _ = try? updateAttempt(attempt.id) {
      $0.state = to
      $0.reason = reason
      $0.finishedAt = store.now
    }
    _ = try? store.event("run:\(attempt.run)", "job.\(to.rawValue)", "\(attempt.jobKey): \(reason)")
  }

  // MARK: Launch

  private func launch(_ runID: PreflightRunID, _ attemptID: JobAttemptID) {
    do throws(CIError) {
      try launchThrowing(runID, attemptID)
    } catch {
      // The job can finish (and its VM be released) before the start
      // command returns; a launch error never rewrites a recorded outcome.
      var recorded = false
      guard
        let updated = try? updateAttempt(
          attemptID,
          {
            guard !$0.state.isTerminal else { return }
            recorded = true
            $0.state =
              error.code == .compatibilityRejected || error.code == .admissionRefused
                || error.code == .capabilityMissing || error.code == .qualificationMissing
                || error.code == .confinementUnavailable ? .failed : .interrupted
            $0.reason = "\(error.code.rawValue): \(error.message)"
            $0.finishedAt = store.now
          }), recorded
      else { return }
      _ = try? store.event(
        "run:\(runID)", "job.launch_failed", "\(error.code.rawValue): \(error.message)")
      if let allocation = updated.allocation {
        finish(allocation: allocation, failed: false, retain: .disabled)
      }
    }
  }

  private func launchThrowing(_ runID: PreflightRunID, _ attemptID: JobAttemptID) throws(CIError) {
    let record = try run(runID)
    guard let attempt = try store.preflightJob(attemptID, as: JobAttemptRecord.self),
      let job = record.plan.job(attempt.jobKey)
    else { throw CIError(.notFound, "unknown attempt") }
    let configuration = try loadConfiguration().get()
    guard let preflight = configuration.preflight else {
      throw CIError.config("preflight is not configured")
    }
    let profile = try ResolvedProfile(name: record.profile, configuration: configuration)
    let revision = record.revisions[attempt.inputRevision]
    let reference = SnapshotReference(
      baseCommit: revision.baseCommit, digest: revision.snapshot, isDirty: revision.dirty)
    scripts.register(reference)
    // Placement, admission and a fresh clean VM.
    let candidates = record.pinnedHost.map { [$0] } ?? preflight.hosts
    let placement = try HostPlacement.select(
      candidates: candidates, profile: profile, configuration: configuration, store: store,
      fairnessKey: "preflight", now: store.now)
    if placement.choice == nil, !placement.refusals.isEmpty,
      placement.refusals.allSatisfy({ !$0.capacity })
    {
      // No candidate can ever admit this profile as configured: fail
      // explicitly instead of waiting (no fallback to another transport).
      throw CIError(
        .capabilityMissing,
        "no eligible host: \(placement.refusals.map { "\($0.host) \($0.reason)" }.joined(separator: ", "))"
      )
    }
    guard let host = placement.choice else {
      // No capacity now: back to pending; the next pass retries.
      _ = try updateAttempt(attemptID) {
        $0.state = .pending
        $0.reason =
          "waiting for capacity: \(placement.refusals.map { "\($0.host) \($0.reason)" }.joined(separator: ", "))"
      }
      return
    }
    try dataPlane()
    let admission = try provider.admit(host: host, profile: profile)
    var provenance = InputProvenance(
      profileDigest: profile.digest, imageReference: profile.image.isoImage,
      imageDigest: profile.image.digest(on: host),
      expectedRunnerVersion: profile.image.runnerVersion, networkPolicyDigest: nil,
      qualificationDigest: nil,
      qualificationTuple: [:], compatibilityDigest: profile.compatibility.digestOfDescriptor,
      limitsDigest: profile.limits.digestOfDescriptor, platform: profile.profile.platform)
    provenance.baseCommit = revision.baseCommit
    provenance.snapshotDigest = revision.snapshot
    provenance.workflowDigest = record.plan.workflowDigest
    provenance.actionsDigest = descriptorDigest(record.plan.actions)
    provenance.patchRevision = revision.number
    let current = latest(try attempts(runID))
    var dependencies: [JobAttemptID] = []
    var mixed = false
    for key in job.needs {
      guard let dependency = current[key] else { continue }
      dependencies.append(dependency.id)
      if dependency.inputRevision != attempt.inputRevision || !dependency.patchRevisions.isEmpty {
        mixed = true
      }
    }
    provenance.dependencyAttempts = dependencies.map(\.rawValue)
    let allocation = AllocationRecord(
      id: .generate(), kind: .preflight, controller: try store.controllerID(), host: host,
      hostRun: .generate(), operations: HostOperations(create: .generate()), provenance: provenance,
      reservation: profile.limits.reservation, createdAt: store.now,
      hardDeadline: store.now + profile.limits.hardDeadlineSeconds)
    var placed = allocation
    placed.completionGraceSeconds =
      profile.limits.stopGraceSeconds + profile.limits.exportGraceSeconds
    placed.preflightRun = runID
    placed.jobAttempt = attemptID
    try store.insert(placed)
    _ = try updateAttempt(attemptID) {
      $0.allocation = placed.id
      $0.dependencyAttempts = dependencies
      $0.mixedInputs = mixed
      $0.reason = nil
    }
    try store.event(
      "run:\(runID)", "job.provisioning", "\(job.key) on \(host) (allocation \(placed.id.short))",
      data: ["allocation": placed.id.rawValue])
    try provider.provision(placed.id, profile: profile, admission: admission)
    let endpoint = try registerEndpoint(
      record, runID: runID, attempt: attempt, job: job, allocation: placed, profile: profile,
      revision: revision, dependencies: dependencies, current: current)
    try provider.holdSession(
      placed.id,
      forwards: [ServiceForward(guestPort: endpoint.guestPort, hostSocket: endpoint.hostSocket)])
    try startRunner(placed.id, profile: profile, endpoint: endpoint)
    try store.update(placed.id) { $0.execution = .running }
    let now = try updateAttempt(attemptID) { if !$0.state.isTerminal { $0.state = .running } }
    guard now.state == .running else {
      // A job can complete before its start command returns; completion
      // then owns cleanup. Cancelled while launching: stop the runner's VM.
      guard now.state == .cancelled else { return }
      let broker = self.broker
      let id = placed.id
      blocking { await broker.cancel(id) }
      finish(allocation: id, failed: false, retain: .disabled)
      return
    }
    try store.event("run:\(runID)", "job.running", "\(job.key) runner started on \(host)")
  }

  /// Registers one attempt's job with the data plane: its contexts, approved
  /// actions, mapped secrets and cache scope, and the guest-side endpoint.
  private func registerEndpoint(
    _ record: PreflightRunRecord, runID: PreflightRunID, attempt: JobAttemptRecord, job: JobPlan,
    allocation: AllocationRecord, profile: ResolvedProfile, revision: InputRevision,
    dependencies: [JobAttemptID], current: [String: JobAttemptRecord]
  ) throws(CIError) -> GuestEndpointConfig {
    let needs = graph(record).needsContext(for: job.key, outcomes: outcomes(current))
    var needMap: [String: JobMessageBuilder.Contexts.Need] = [:]
    for (id, value) in needs.objectValue ?? [:] {
      var outputs: [String: String] = [:]
      for (name, output) in value["outputs"]?.objectValue ?? [:] {
        outputs[name] = output.stringValue ?? ""
      }
      needMap[id] = .init(result: value["result"]?.stringValue ?? "success", outputs: outputs)
    }
    var actions: [ResolvedAction] = []
    for action in record.plan.actions {
      guard case .repository(_, _, _, let ref) = action, let name = action.nameWithOwner,
        let approved = try ApprovedActions.load(name, ref, store: store)
      else { continue }
      try objects.grant(
        subject: "attempt:\(attempt.id)", kind: .actionArchive, digest: approved.archiveDigest)
      actions.append(approved)
    }
    let secrets = state.withLock { $0.secrets[runID] ?? [:] }
    if !record.secretNames.isEmpty && secrets.isEmpty {
      throw CIError(
        .unauthorized, "this run's mapped secrets are no longer in controller memory; resubmit it")
    }
    let contexts = JobMessageBuilder.Contexts(
      repository: record.repository, sha: revision.baseCommit, ref: "refs/heads/iso-ci-preflight",
      runID: Int64(
        bitPattern: UInt64(Digest(hashing: runID.rawValue).rawValue.prefix(12), radix: 16) ?? 1),
      runAttempt: Int64(attempt.number), needs: needMap,
      inputs: record.inputs.isEmpty ? nil : .object(record.inputs.mapValues { .string($0) }))
    let scope = Self.cacheScope(
      record, run: runID, secretsMapped: !secrets.isEmpty, profile: profile,
      host: allocation.host)
    let registration = DataPlaneRegistration(
      allocation: allocation.id, attempt: attempt.id, run: runID,
      authority: profile.profile.authority,
      plan: record.plan, job: job, contexts: contexts, secrets: secrets,
      snapshot: revision.snapshot,
      actions: actions, dependencyAttempts: Set(dependencies), cacheScope: scope,
      limits: profile.limits,
      guestHost: profile.image.docker ? .dockerGateway : .loopback,
      guestPort: Self.guestPort, expiresAt: allocation.hardDeadline,
      runnerName: "iso-ci-pf-\(attempt.id.short)")
    let broker = self.broker
    let registered: Result<GuestEndpointConfig, CIError> = blocking {
      do throws(CIError) { return .success(try await broker.register(registration)) } catch {
        return .failure(error)
      }
    }
    return try registered.get()
  }

  /// The cache partition a job of `record` registers with the data plane.
  static func cacheScope(
    _ record: PreflightRunRecord, run: PreflightRunID, secretsMapped: Bool,
    profile: ResolvedProfile, host: Name
  ) -> ObjectStore.CacheScope {
    ObjectStore.CacheScope(
      repository: record.repository, authority: profile.profile.authority.rawValue,
      platform: profile.profile.platform,
      imageDigest: profile.image.digest(on: host).rawValue,
      toolchain: profile.image.runnerVersion, inputDigest: record.plan.workflowDigest.rawValue,
      confinedToRun: cacheConfinement(
        run: run, secretsMapped: secretsMapped, revisions: record.revisions))
  }

  /// The run a job's cache entries are confined to, or nil for the shared
  /// partition. Only a run whose every input revision is a clean tree, with
  /// no mapped secrets, publishes shared entries: a key saved from
  /// uncommitted or patched content, or with secrets in scope, is never
  /// restored by a later run of the clean base.
  static func cacheConfinement(
    run: PreflightRunID, secretsMapped: Bool, revisions: [InputRevision]
  ) -> String? {
    let clean = revisions.allSatisfy { !$0.dirty && $0.patchedAttempt == nil }
    return secretsMapped || !clean ? run.rawValue : nil
  }

  /// Starts the official runner once the image's runner version matches;
  /// the JIT material reaches the guest on stdin only, never argv or logs.
  private func startRunner(
    _ allocation: AllocationID, profile: ResolvedProfile, endpoint: GuestEndpointConfig
  ) throws(CIError) {
    let version = RunnerBootstrap.parseVersion(
      try provider.execute(
        allocation, RunnerBootstrap.version(runnerDirectory: profile.image.runnerDirectory)))
    guard version == profile.image.runnerVersion else {
      throw CIError(
        .guestFailed,
        "runner version \(version ?? "missing") differs from the approved \(profile.image.runnerVersion)"
      )
    }
    let started = try provider.execute(
      allocation,
      RunnerBootstrap.start(
        runnerDirectory: profile.image.runnerDirectory,
        jit: RedactedSecret(endpoint.jitConfig),
        mode: .preflight(docker: profile.image.docker, guestPort: Self.guestPort)))
    guard started.succeeded else {
      throw CIError(.guestFailed, RunnerBootstrap.StartFailure.describe(started.exitStatus))
    }
  }

  private func graph(_ record: PreflightRunRecord) -> JobGraph { JobGraph(plan: record.plan) }

  /// The profile's boot allowance: how long a started runner may take to
  /// acquire its job.
  private func bootAllowance(_ record: PreflightRunRecord) -> EpochSeconds {
    let config = try? loadConfiguration().get()
    let limits = config.flatMap { $0.limits[$0.profiles[record.profile]?.limits ?? "x"] }
    return limits?.bootSeconds ?? 600
  }

  /// A runner that never acquired its job (for example, one that cannot
  /// reach the endpoint) fails the attempt; the VM is kept for debug like
  /// any failed attempt when the run retains failures.
  private func failUnacquired(
    _ attempt: JobAttemptRecord, allocation: AllocationID, run record: PreflightRunRecord,
    now: EpochSeconds
  ) {
    let reason = "the runner did not acquire the job within \(bootAllowance(record)) s"
    guard
      let updated = try? updateAttempt(
        attempt.id,
        {
          guard !$0.state.isTerminal, $0.acquiredAt == nil else { return }
          $0.state = .failed
          $0.reason = reason
          $0.finishedAt = now
        }),
      updated.state == .failed, updated.reason == reason
    else { return }
    _ = try? store.update(allocation) {
      $0.execution = .failed
      $0.finishedAt = now
      $0.note(reason)
    }
    _ = try? store.event(
      "run:\(record.id)", "job.failed", "\(attempt.jobKey) \(reason)",
      data: ["allocation": allocation.rawValue])
    let claimed = state.withLock { $0.finishing.insert(allocation).inserted }
    guard claimed else { return }
    let retain = record.retainOnFailure
    Thread.detachNewThread { [self] in
      finish(allocation: allocation, failed: true, retain: retain, claimed: true)
    }
  }

  // MARK: Completion

  private func handle(_ notice: DataPlaneNotice) {
    switch notice.event {
    case .jobAcquired:
      _ = try? updateAttempt(notice.attempt) { $0.acquiredAt = $0.acquiredAt ?? store.now }
      _ = try? store.event(
        "allocation:\(notice.allocation)", "job.acquired", "runner acquired the job")
    case .steps(let steps):
      for step in steps where step.status == "completed" {
        _ = try? store.event(
          "allocation:\(notice.allocation)", "step.completed",
          "\(step.name): \(step.conclusion ?? "unknown")")
      }
    case .completed(let result):
      complete(notice, result)
    case .sessionCreated, .sessionClosed:
      break
    }
  }

  /// Cancels the runner's job, then stops the VM and revokes the
  /// allocation's endpoint access and object grants.
  private func stop(_ allocation: AllocationID) {
    let broker = self.broker
    blocking { await broker.cancel(allocation) }
    Thread.detachNewThread { [self] in
      finish(allocation: allocation, failed: false, retain: .disabled)
    }
  }

  private func complete(_ notice: DataPlaneNotice, _ result: DataPlaneEvent.JobResult) {
    // A result for an attempt that already ended (aborted, cancelled by the
    // graph, interrupted) is ignored: the guest cannot rewrite it.
    if let existing = try? store.preflightJob(notice.attempt, as: JobAttemptRecord.self),
      existing.state.isTerminal
    {
      _ = try? store.event(
        "allocation:\(notice.allocation)", "job.late_result_ignored",
        "ignored a \(result.conclusion) report for an attempt that is already \(existing.state.rawValue)"
      )
      let broker = self.broker
      let allocation = notice.allocation
      blocking { await broker.unregister(allocation) }
      return
    }
    let state: JobAttemptState =
      switch result.conclusion {
      case "success", "succeeded": .succeeded
      case "cancelled", "canceled": .cancelled
      default: .failed
      }
    guard
      let attempt = try? updateAttempt(
        notice.attempt,
        {
          $0.state = state
          $0.outputs = result.outputs
          $0.steps = result.steps.map {
            StepOutcome(
              name: $0.name, conclusion: $0.conclusion ?? $0.status,
              synthetic: $0.name.hasPrefix("iso-ci"))
          }
          $0.logObjects = notice.logs.map(\.digest)
          $0.finishedAt = store.now
        })
    else { return }
    _ = try? store.update(notice.allocation) {
      $0.execution = state == .succeeded ? .succeeded : state == .cancelled ? .cancelled : .failed
      $0.finishedAt = store.now
    }
    _ = try? store.event(
      "run:\(attempt.run)", "job.\(state.rawValue)", "\(attempt.jobKey) \(result.conclusion)",
      data: ["allocation": notice.allocation.rawValue])
    let broker = self.broker
    let allocation = notice.allocation
    blocking { await broker.unregister(allocation) }
    let retain = (try? run(attempt.run))?.retainOnFailure ?? .disabled
    // Claim the allocation now so a concurrent sweep cannot release a
    // failed environment before it is retained.
    let claimed = self.state.withLock { $0.finishing.insert(allocation).inserted }
    guard claimed else { return }
    Thread.detachNewThread { [self] in
      finish(allocation: allocation, failed: state == .failed, retain: retain, claimed: true)
    }
  }

  /// Stops the VM after a job: a failed attempt is kept live (finite,
  /// host-owned) for debug and patch when configured; otherwise results are
  /// staged and the VM is destroyed with verified cleanup.
  private func finish(
    allocation: AllocationID, failed: Bool, retain: FailureRetention, claimed: Bool = false
  ) {
    let first = state.withLock { $0.finishing.insert(allocation).inserted }
    guard first || claimed else { return }
    defer { _ = state.withLock { $0.finishing.remove(allocation) } }
    let broker = self.broker
    blocking { await broker.unregister(allocation) }
    guard let record = try? store.allocation(allocation) else { return }
    let limits = (try? loadConfiguration().get()).flatMap { config in
      record.preflightRun.flatMap { (try? run($0))?.profile }.flatMap {
        config.limits[config.profiles[$0]?.limits ?? "x"]
      }
    }
    do {
      if failed, retain == .live, let limits {
        try provider.retain(allocation, mode: .live, seconds: limits.liveRetentionSeconds)
        if let attempt = record.jobAttempt {
          let until = try store.allocation(allocation)?.retentionUntil
          _ = try updateAttempt(attempt) { $0.retainedUntil = until }
        }
        return
      }
      if record.observedRunPhase == .running { try provider.complete(allocation, exitStatus: nil) }
      try provider.release(allocation)
    } catch {
      // Unfinished cleanup stays visible and budgeted; later passes retry.
      _ = try? store.update(allocation) {
        if $0.vmCleanup != .verified { $0.vmCleanup = .debt }
        $0.note("finish failed: \(error.code.rawValue): \(error.message)")
      }
      _ = try? store.event(
        "allocation:\(allocation)", "allocation.finish_failed",
        "\(error.code.rawValue): \(error.message)")
    }
  }

  // MARK: Control

  package func handle(_ request: ControlRequest) -> Result<JSONValue, CIError>? {
    do throws(CIError) {
      switch request.method {
      case "run.submit":
        return .success(try submit(request.params))
      case "retry":
        return .success(try retry(request.params))
      case "patch":
        return .success(try patch(request.params))
      case "abort":
        var r = try ObjectReader(request.params, field: "params")
        let target = try r.string("target")
        try r.finish()
        if let id = try? PreflightRunID(target),
          var record = try store.preflightRun(id, as: PreflightRunRecord.self)
        {
          guard record.state == .running else {
            throw CIError(.conflict, "run is \(record.state.rawValue)")
          }
          record.state = .aborting
          try store.savePreflightRun(id, createdAt: record.createdAt, record)
          try store.event("run:\(id)", "run.abort", "abort requested")
          return .success(["run": .string(id.rawValue), "state": "aborting"])
        }
        guard let id = try? AllocationID(target), let allocation = try store.allocation(id),
          allocation.kind == .preflight, let attempt = allocation.jobAttempt
        else { return nil }
        try store.update(id) { $0.note("abort requested by operator") }
        mark(
          try store.preflightJob(attempt, as: JobAttemptRecord.self), .cancelled,
          "aborted by operator")
        stop(id)
        return .success(["allocation": .string(id.rawValue), "state": "cancelled"])
      case "job.logs":
        return .success(try jobLogs(request.params))
      case "inspect.preflight":
        var r = try ObjectReader(request.params, field: "params")
        let target = try r.string("target")
        try r.finish()
        guard let id = try? PreflightRunID(target),
          let record = try store.preflightRun(id, as: PreflightRunRecord.self)
        else { return nil }
        let jobs = try attempts(id)
        return .success([
          "run": jsonValue(record), "attempts": .array(jobs.map { jsonValue($0) }),
          "settled": .bool(record.state == .finished || record.state == .aborted),
          "note": record.baseRevision.dirty
            ? "includes uncommitted changes: a success is not evidence that the base commit passes"
            : .null,
        ])
      default:
        return nil
      }
    } catch {
      return .failure(error)
    }
  }

  /// A fresh whole-job attempt in a clean VM. Dependency outputs stay bound
  /// to their original attempts; changed inputs are reported as mixed.
  private func retry(_ params: JSONValue) throws(CIError) -> JSONValue {
    var r = try ObjectReader(params, field: "params")
    let target = try r.string("allocation")
    try r.finish()
    let previous: JobAttemptRecord
    if let id = try? AllocationID(target), let allocation = try store.allocation(id),
      let attempt = allocation.jobAttempt,
      let record = try store.preflightJob(attempt, as: JobAttemptRecord.self)
    {
      previous = record
    } else if let id = try? JobAttemptID(target),
      let record = try store.preflightJob(id, as: JobAttemptRecord.self)
    {
      previous = record
    } else if let allocation = try? AllocationID(target),
      let record = try store.allocation(allocation), record.kind == .connected
    {
      throw CIError(
        .unsupported,
        "a connected job's replay is a separate local preflight run (`iso-ci run`); it never rewrites the GitHub check"
      )
    } else {
      throw CIError(.notFound, "unknown preflight allocation or attempt")
    }
    guard previous.state.isTerminal else {
      throw CIError(.conflict, "the attempt is still \(previous.state.rawValue)")
    }
    var record = try run(previous.run)
    let latestRevision = record.revisions.count - 1
    let current = latest(try attempts(record.id))
    guard current[previous.jobKey]?.id == previous.id else {
      throw CIError(.conflict, "a newer attempt of this job exists")
    }
    var attempt = JobAttemptRecord(
      id: .generate(), run: record.id, jobKey: previous.jobKey, number: previous.number + 1,
      inputRevision: latestRevision)
    var note: JSONValue = .null
    let dependencyRevisions = (record.plan.job(previous.jobKey)?.needs ?? []).compactMap {
      current[$0]?.inputRevision
    }
    if dependencyRevisions.contains(where: { $0 != latestRevision }) {
      attempt.mixedInputs = true
      note =
        "dependency outputs come from an earlier input revision; this result has mixed-input provenance, not one clean run"
    }
    try save(attempt)
    // Downstream jobs saw the old result: retry them too, so the run does
    // not settle on a stale skip.
    var reopened: [String] = []
    for key in graph(record).dependents(of: previous.jobKey) {
      guard let downstream = current[key], downstream.state.isTerminal else { continue }
      try save(
        JobAttemptRecord(
          id: .generate(), run: record.id, jobKey: key, number: downstream.number + 1,
          inputRevision: latestRevision))
      reopened.append(key)
    }
    if record.state != .running {
      record.state = .running
      record.conclusion = nil
      record.finishedAt = nil
      try store.savePreflightRun(record.id, createdAt: record.createdAt, record)
    }
    try store.event(
      "run:\(record.id)", "job.retry",
      "\(attempt.jobKey) attempt \(attempt.number) (fresh VM, whole job)"
        + (reopened.isEmpty ? "" : "; re-queued dependents: \(reopened.joined(separator: ", "))"))
    return [
      "attempt": .string(attempt.id.rawValue), "number": .integer(Int64(attempt.number)),
      "allocation": .null, "provenance_note": note,
      "requeued": .array(reopened.map(JSONValue.string)),
    ]
  }

  /// Transfers a new validated snapshot into a retained, non-running
  /// environment and records it as a new input revision.
  private func patch(_ params: JSONValue) throws(CIError) -> JSONValue {
    var r = try ObjectReader(params, field: "params")
    let id = try r.parsed("allocation", as: AllocationID.self)
    let repository = try r.string("repository")
    try r.finish()
    guard let allocation = try store.allocation(id), allocation.kind == .preflight,
      let attemptID = allocation.jobAttempt, let runID = allocation.preflightRun
    else { throw CIError(.notFound, "not a preflight allocation") }
    guard allocation.desired == .retainLive, allocation.observedRunPhase == .running else {
      throw CIError(
        .conflict, "patch needs a live-retained environment (phase \(allocation.phase))")
    }
    guard let attempt = try store.preflightJob(attemptID, as: JobAttemptRecord.self),
      attempt.state.isTerminal
    else {
      throw CIError(.conflict, "patch needs a finished (non-running) attempt")
    }
    var record = try run(runID)
    guard
      (repository as NSString).standardizingPath
        == (record.repositoryPath as NSString).standardizingPath
    else {
      throw CIError.invalid("patch must come from the run's repository \(record.repositoryPath)")
    }
    var options = SnapshotOptions(outputDirectory: root.staging + "/snapshots")
    options.workflowPath = record.plan.workflowPath
    let capture = try SnapshotCapture.capture(repository: repository, options: options)
    defer { PrivateFiles.remove(capture.archivePath) }
    let imported = try objects.importFile(capture.archivePath, kind: .snapshot, limit: 512 << 20)
    let bytes = try PrivateFiles.read(objects.path(imported.digest), limit: 512 << 20) ?? []
    let reference = capture.reference
    guard let job = record.plan.job(attempt.jobKey) else { throw CIError(.notFound, "unknown job") }
    let path =
      job.steps.compactMap { step -> String? in
        if case .snapshotOverlay(let path) = step.kind { return path }
        return nil
      }.first ?? "."
    guard
      let overlay = OverlayScripts.script(for: .snapshotOverlay(path: path), snapshot: reference)
    else {
      throw CIError(.internalError, "no overlay script")
    }
    let repoName = record.repository.split(separator: "/").last.map(String.init) ?? "repository"
    let workspace = "/opt/actions-runner/_work/\(repoName)/\(repoName)"
    let script = """
      export RUNNER_TEMP="$(mktemp -d)"
      export GITHUB_WORKSPACE=\(shellQuote(workspace))
      mkdir -p "$RUNNER_TEMP/iso-ci-snapshot-\(reference.digest.rawValue)"
      cat > "$RUNNER_TEMP/iso-ci-snapshot-\(reference.digest.rawValue)/snapshot.tar"
      \(overlay)
      """
    let result = try provider.execute(
      id,
      GuestCommand(
        ["bash", "-c", script], stdin: bytes, timeoutSeconds: 900, outputLimit: 64 << 10))
    guard result.succeeded else {
      throw CIError(
        .guestFailed,
        "the patch overlay failed: \(CIError.bounded(String(result.stdoutText.suffix(300))))")
    }
    let revision = InputRevision(
      number: record.revisions.count, baseCommit: reference.baseCommit, snapshot: reference.digest,
      dirty: reference.isDirty, capturedAt: capture.capturedAt, patchedAttempt: attemptID)
    record.revisions.append(revision)
    try store.savePreflightRun(runID, createdAt: record.createdAt, record)
    _ = try updateAttempt(attemptID) { $0.patchRevisions.append(revision.number) }
    try store.update(id) { $0.provenance.patchRevision = revision.number }
    try store.event(
      "run:\(runID)", "job.patched",
      "revision \(revision.number) (sha256:\(reference.digest.short)) applied to the retained workspace of \(attempt.jobKey); rerun with `iso-ci retry --from-start` for a clean result"
    )
    return [
      "revision": .integer(Int64(revision.number)), "snapshot": .string(reference.digest.rawValue),
    ]
  }

  package func status() -> JSONValue {
    let ids = (try? store.preflightRunIDs(limit: 20)) ?? []
    var runs: [String: JSONValue] = [:]
    for id in ids {
      guard let record = try? run(id) else { continue }
      runs[id.rawValue] = [
        "state": .string(record.state.rawValue),
        "conclusion": record.conclusion.map(JSONValue.string) ?? .null,
        "workflow": .string(record.plan.workflowPath),
        "jobs": .integer(Int64(record.plan.jobs.count)),
      ]
    }
    let failure = state.withLock { $0.confinementFailure }
    return [
      "confinement": failure.map { .string("unavailable: \($0.message)") }
        ?? .string(
          state.withLock { $0.supervisor?.isRunning ?? false } ? "running" : "not started"),
      "runs": .object(runs),
    ]
  }
}

extension Subprocess.Output {
  var stdoutTextTrimmed: String {
    String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
