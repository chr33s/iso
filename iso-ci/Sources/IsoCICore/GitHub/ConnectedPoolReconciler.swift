import Foundation

package struct ReconcileReport: Sendable, Equatable {
  package var pool: Name
  package var created: [AllocationID] = []
  package var retired: [AllocationID] = []
  package var released: [AllocationID] = []
  package var retained: [AllocationID] = []
  package var uncertain: [AllocationID] = []
  package var errors: [String] = []
  /// Why no capacity was added this pass, when none was.
  package var admissionPaused: String?
  package var live = 0
  package var idle = 0
  package var deficit = 0

  package init(pool: Name) { self.pool = pool }

  mutating func error(_ error: CIError, _ context: String) {
    errors.append("\(context): \(error.code.rawValue): \(error.message)")
  }
}

/// Operator pool controls (spec section 8). They only change desired state;
/// the reconciler carries it out.
package enum PoolControl {
  package static func pause(_ pool: Name, store: ControllerStore) throws(CIError) {
    try set(pool, .paused, reason: "paused by operator", store: store)
  }

  /// Stop replenishment and retire idle capacity; assigned work finishes
  /// within its existing bounds.
  package static func drain(_ pool: Name, store: ControllerStore) throws(CIError) {
    try set(pool, .draining, reason: "draining by operator", store: store)
  }

  /// Offboard owned resources: like drain, then release retained VMs and
  /// record pending cleanup until verified. Credentials stay unless removed
  /// explicitly.
  package static func remove(_ pool: Name, store: ControllerStore) throws(CIError) {
    try set(pool, .removing, reason: "offboarding requested", store: store)
  }

  package static func abort(_ allocation: AllocationID, store: ControllerStore) throws(CIError) {
    try store.update(allocation) {
      $0.desired = .stop
      $0.note("abort requested by operator")
    }
    try store.event("allocation:\(allocation)", "allocation.abort", "abort requested")
  }

  package static func set(_ pool: Name, _ state: PoolState, reason: String?, store: ControllerStore)
    throws(CIError)
  {
    var record =
      try store.poolStatus(pool)
      ?? PoolStatusRecord(
        name: pool, state: state, reason: reason, configDigest: nil, at: store.now)
    record.state = state
    record.reason = reason
    record.updatedAt = store.now
    try store.save(record)
    try store.event(
      "pool:\(pool)", "pool.state", "\(state.rawValue)\(reason.map { ": " + $0 } ?? "")")
  }
}

/// One GitHub-connected pool's ready-capacity reconciler (spec section 7).
/// It manages capacity, not job scheduling: GitHub assigns jobs; this keeps
/// fresh single-use runners available and cleans up after them.
package final class ConnectedPoolReconciler: Sendable {
  package static let maxJITAttempts = 3
  package static let maxRegistrationLookups = 5
  /// How long to wait for GitHub to confirm a conclusion before deciding
  /// failure retention from the runner process alone.
  package static let conclusionWaitSeconds: EpochSeconds = 120
  /// Set on a confirmed JIT intent whose registration was deleted again.
  static let removedRunnerParameter = "removed_runner_id"

  package let pool: Name
  let store: ControllerStore
  let configuration: CIConfiguration
  let provider: any EnvironmentProvider
  let runners: any RunnerService
  let placement: any PlacementPolicy
  let controller: ControllerID
  let clock: any CIClock
  /// Why the pool's activation gate refuses it this pass, or nil. A pool in
  /// an operator state (paused) keeps that state, but its idle runners still
  /// retire while the gate refuses it.
  let gate: String?
  /// A scale-set pool's current demand from its listener; nil for a warm
  /// pool, or while the listener is not running.
  let scaleSetDemand: ScaleSetDemand?
  /// Starts a new allocation's work in a supervisor process; nil runs it
  /// inline in this pass.
  let launcher: (any AllocationLauncher)?
  let supervisors: any SupervisorDirectory
  let trace: ProtocolTrace?

  package init(
    pool: Name, store: ControllerStore, configuration: CIConfiguration,
    provider: any EnvironmentProvider, runners: any RunnerService,
    placement: any PlacementPolicy = DefaultPlacementPolicy(), controller: ControllerID,
    clock: any CIClock = SystemClock(), gate: String? = nil,
    scaleSetDemand: ScaleSetDemand? = nil, launcher: (any AllocationLauncher)? = nil,
    supervisors: any SupervisorDirectory = InlineSupervision(), trace: ProtocolTrace? = nil
  ) {
    self.gate = gate
    self.scaleSetDemand = scaleSetDemand
    self.launcher = launcher
    self.supervisors = supervisors
    self.trace = trace
    self.pool = pool
    self.store = store
    self.configuration = configuration
    self.provider = provider
    self.runners = runners
    self.placement = placement
    self.controller = controller
    self.clock = clock
  }

  package static func runnerName(controller: ControllerID, allocation: AllocationID) -> String {
    "iso-ci-\(controller.short)-\(allocation.rawValue)"
  }

  package struct Pass {
    var report: ReconcileReport
    var githubHealthy = true
    var hostsDown: Set<Name> = []
    var refusedHosts: Set<Name> = []
    var jobs: [GitHubJobInfo]?
    var runnerInfo: [AllocationID: GitHubRunnerInfo] = [:]
    var groupID: Int64?
  }

  /// A pass between its maintenance and admission phases: the controller
  /// schedules every pool's `requests` together, then admits the grants.
  package struct PreparedPass {
    package var pass: Pass
    let poolConfig: PoolConfiguration?
    let scope: GitHubRunnerScope?
    let state: PoolState
    /// Missing capacity, oldest first; empty when admission is paused.
    package var requests: [ScheduleRequest] = []
  }

  /// One full pass: refresh, lifecycle, deficit, creation with this pool's
  /// own placement policy. Never throws; every failure is recorded in the
  /// report and the event log.
  @discardableResult
  package func reconcile() -> ReconcileReport {
    var prepared = prepare(since: clock.now())
    if let poolConfig = prepared.poolConfig, let scope = prepared.scope {
      for _ in prepared.requests {
        guard prepared.pass.githubHealthy, prepared.pass.report.uncertain.isEmpty,
          create(poolConfig, scope: scope, host: nil, pass: &prepared.pass)
        else { break }
      }
    }
    return finish(&prepared)
  }

  /// Refresh and lifecycle, then this pool's missing capacity as schedule
  /// requests. `since` dates requests that have no job of their own (warm
  /// runners, scale-set minimum runners).
  package func prepare(since: EpochSeconds) -> PreparedPass {
    var pass = Pass(report: ReconcileReport(pool: pool))
    guard let poolConfig = configuration.pools[pool] else {
      pass.report.admissionPaused = "pool is not configured"
      return PreparedPass(pass: pass, poolConfig: nil, scope: nil, state: .inactive)
    }
    let state = (try? store.poolStatus(pool))?.state ?? .inactive
    let scope = GitHubRunnerScope(poolConfig.scope)
    for allocation in (try? store.openAllocations(pool: pool)) ?? []
    where !supervisorOwns(allocation, poolConfig) {
      refresh(allocation.id, scope: scope, pool: poolConfig, pass: &pass)
    }
    for allocation in (try? store.openAllocations(pool: pool)) ?? []
    where !supervisorOwns(allocation, poolConfig) {
      lifecycle(allocation.id, scope: scope, pool: poolConfig, state: state, pass: &pass)
    }
    var prepared = PreparedPass(pass: pass, poolConfig: poolConfig, scope: scope, state: state)
    prepared.requests = plan(poolConfig, state: state, since: since, pass: &prepared.pass)
    return prepared
  }

  /// Whether a live supervisor owns this allocation's startup. Startup is
  /// bounded: past twice the boot allowance (plus a margin) a supervisor
  /// that still holds the lock is presumed stuck, and the controller's
  /// lifecycle (deadline, release) applies again.
  func supervisorOwns(_ allocation: AllocationRecord, _ pool: PoolConfiguration) -> Bool {
    guard supervisors.status(allocation.id).ownsStartup else { return false }
    let boot =
      configuration.profiles[pool.profile].flatMap { configuration.limits[$0.limits] }?
      .bootSeconds ?? 600
    return clock.now() < allocation.createdAt + boot * 2 + 300
  }

  /// Admits the hosts the scheduler granted (one per request, in queue
  /// order) and retires idle runners it chose to drain a host.
  package func admit(_ prepared: inout PreparedPass, grants: [Name], retire ids: [AllocationID]) {
    guard let poolConfig = prepared.poolConfig, let scope = prepared.scope else { return }
    for id in ids {
      guard let allocation = try? store.allocation(id), allocation.pool == pool,
        allocation.job == nil, allocation.desired == .active, !allocation.isSettled,
        !supervisorOwns(allocation, poolConfig)
      else { continue }
      retire(id, reason: "host draining for an exclusive job", scope: scope, pass: &prepared.pass)
    }
    for host in grants {
      guard prepared.pass.githubHealthy, prepared.pass.report.uncertain.isEmpty,
        create(poolConfig, scope: scope, host: host, pass: &prepared.pass)
      else { break }
    }
  }

  package func finish(_ prepared: inout PreparedPass) -> ReconcileReport {
    if prepared.state == .removing, ((try? store.openAllocations(pool: pool)) ?? []).isEmpty {
      try? PoolControl.set(
        pool, .removed, reason: "offboarded; owned resources released", store: store)
    }
    let report = prepared.pass.report
    if !report.errors.isEmpty {
      _ = try? store.event(
        "pool:\(pool)", "pool.reconcile", "\(report.errors.count) problem(s)",
        data: ["first": report.errors.first ?? ""])
    }
    return report
  }

  // MARK: (1) Refresh

  private func refresh(
    _ id: AllocationID, scope: GitHubRunnerScope, pool: PoolConfiguration, pass: inout Pass
  ) {
    guard let initial = try? store.allocation(id) else { return }
    if pass.hostsDown.contains(initial.host) {
      pass.report.uncertain.append(id)
      return
    }
    if initial.instance != nil || initial.uncertainty != nil || initial.vmCleanup == .pending {
      do { try provider.observe(id) } catch {
        if error.code == .hostUnreachable { pass.hostsDown.insert(initial.host) }
        pass.report.uncertain.append(id)
        pass.report.error(error, "observe \(id.short)")
        return
      }
    }
    guard var allocation = try? store.allocation(id) else { return }
    switch allocation.registration {
    case .uncertain:
      resolveUncertainRegistration(&allocation, scope: scope, pass: &pass)
    case .registered, .assigned:
      guard let runnerID = allocation.runnerID else { break }
      do {
        if let info = try runners.runner(scope: scope, id: runnerID) {
          pass.runnerInfo[id] = info
          if info.name != allocation.runnerName {
            update(id) {
              $0.uncertainty = "GitHub runner \(runnerID) no longer carries the recorded name"
            }
            pass.report.uncertain.append(id)
          }
        } else {
          // Ephemeral JIT runners leave GitHub after their job.
          update(id) { $0.registration = .removed }
        }
      } catch {
        githubFailure(error, "runner \(runnerID)", pass: &pass)
      }
    case .removalPending:
      _ = deleteOwned(id, scope: scope, pass: &pass)
    case .intended:
      // A VM released before any JIT request leaves nothing to deregister;
      // a JIT request already sent (reply lost) must be resolved instead.
      guard allocation.vmCleanup == .verified else { break }
      let jit = ((try? store.intents(allocation: id)) ?? []).filter { $0.kind == .githubJITCreate }
      if jit.contains(where: {
        $0.status == .sent || $0.status == .uncertain
          || ($0.status == .confirmed && $0.parameters[Self.removedRunnerParameter] == nil)
      }) {
        update(id) { $0.registration = .uncertain }
      } else {
        update(id) {
          $0.registration = .removed
          $0.note("released before registration; nothing to deregister")
        }
      }
    case .removed, .notApplicable:
      break
    }
    guard let current = try? store.allocation(id) else { return }
    bindJob(current, pool: pool, pass: &pass)
    observeRunnerProcess(id, pool: pool, pass: &pass)
  }

  /// A JIT request whose reply was lost: find the exact owned registration
  /// in the correct scope before anything else is sent.
  private func resolveUncertainRegistration(
    _ allocation: inout AllocationRecord, scope: GitHubRunnerScope, pass: inout Pass
  ) {
    let id = allocation.id
    guard let name = allocation.runnerName else {
      update(id) { $0.uncertainty = "registration uncertain without a recorded runner name" }
      return
    }
    let intents = ((try? store.intents(allocation: id)) ?? []).filter {
      $0.kind == .githubJITCreate
        && ($0.status == .uncertain || $0.status == .sent || $0.status == .pending)
    }
    let found: [GitHubRunnerInfo]
    do { found = try runners.runners(scope: scope, named: name) } catch {
      githubFailure(error, "registration lookup", pass: &pass)
      var lookups = 0
      for var intent in intents {
        intent.attempts += 1
        intent.updatedAt = clock.now()
        lookups = max(lookups, intent.attempts)
        try? store.save(intent)
      }
      if lookups >= Self.maxRegistrationLookups {
        update(id) {
          $0.uncertainty = "registration ownership unresolved; supervised resolution required"
        }
      }
      pass.report.uncertain.append(id)
      pass.report.error(
        CIError(.registrationUncertain, "runner registration for \(id.short) is unresolved"), "jit")
      return
    }
    switch found.count {
    case 0:
      // GitHub has no such runner: the request had no effect.
      for var intent in intents {
        intent.status = .refused
        intent.outcome = "no registration exists"
        intent.updatedAt = clock.now()
        try? store.save(intent)
      }
      update(id) {
        $0.registration = .intended
        $0.note("lost JIT reply resolved: no registration was created")
      }
    case 1:
      // Ours (exact controller-scoped name), but the JIT material is lost:
      // remove that exact registration; a new one may be requested later.
      let runner = found[0]
      var confirmed: [IntentRecord] = []
      for var intent in intents {
        intent.status = .confirmed
        intent.outcome = "registration \(runner.id) exists; JIT material was lost"
        intent.updatedAt = clock.now()
        try? store.save(intent)
        confirmed.append(intent)
      }
      update(id) {
        $0.runnerID = runner.id
        $0.registration = .removalPending
        $0.note("lost JIT reply resolved: registration \(runner.id) exists and will be removed")
      }
      _ = deleteOwned(id, scope: scope, pass: &pass)
      if (try? store.allocation(id))?.registration == .removed {
        // Record that these registrations are gone, so a release before the
        // next JIT request settles instead of looking uncertain again.
        for var intent in confirmed {
          intent.parameters[Self.removedRunnerParameter] = String(runner.id)
          try? store.save(intent)
        }
        update(id) { $0.registration = .intended }
      }
    default:
      update(id) {
        $0.uncertainty =
          "\(found.count) runners carry this allocation's name; supervised resolution required"
      }
      pass.report.uncertain.append(id)
      pass.report.error(
        CIError(.registrationUncertain, "duplicate registrations for \(id.short)"), "jit")
    }
    allocation = (try? store.allocation(id)) ?? allocation
  }

  /// Binds GitHub job identity only from GitHub's own runner_id/runner_name
  /// observations; refreshes a bound job's status and conclusion.
  private func bindJob(_ allocation: AllocationRecord, pool: PoolConfiguration, pass: inout Pass) {
    let id = allocation.id
    if let job = allocation.job {
      guard job.conclusion == nil, let repository = try? RepositoryName(job.repository) else {
        return
      }
      do {
        let latest = try runners.job(repository: repository, id: job.jobID)
        update(id) { $0.job = latest.reference }
      } catch {
        githubFailure(error, "job \(job.jobID)", pass: &pass)
      }
      return
    }
    guard
      allocation.registration == .registered || allocation.registration == .assigned
        || (allocation.registration == .removed && allocation.runnerID != nil
          && allocation.runnerExitStatus == nil)
    else { return }
    guard pass.githubHealthy else { return }
    if pass.jobs == nil {
      do { pass.jobs = try runners.activeJobs(scope: pool.scope) } catch {
        githubFailure(error, "job correlation", pass: &pass)
        return
      }
    }
    guard
      let job = pass.jobs?.first(where: {
        ($0.runnerID != nil && $0.runnerID == allocation.runnerID)
          || ($0.runnerName != nil && $0.runnerName == allocation.runnerName)
      })
    else { return }
    update(id) {
      $0.job = job.reference
      $0.assignedAt = $0.assignedAt ?? clock.now()
      if $0.registration == .registered { $0.registration = .assigned }
      if $0.execution == .pending { $0.execution = .running }
    }
    _ = try? store.event(
      "allocation:\(id)", "allocation.assigned", "GitHub assigned job \(job.id)",
      data: [
        "repository": job.repository.rawValue, "run": String(job.runID), "job": String(job.id),
      ])
  }

  private func observeRunnerProcess(
    _ id: AllocationID, pool: PoolConfiguration, pass: inout Pass
  ) {
    guard let allocation = try? store.allocation(id), allocation.runnerExitStatus == nil,
      allocation.readyAt != nil, allocation.runnerID != nil, allocation.vmCleanup != .verified,
      allocation.registration != .intended, allocation.registration != .uncertain,
      !pass.hostsDown.contains(allocation.host),
      allocation.desired == .active || allocation.desired == .drain
    else { return }
    let result: GuestCommandResult
    do { result = try provider.execute(id, RunnerBootstrap.status()) } catch {
      // A guest command can fail for guest-controlled reasons (ssh exit 255
      // is the guest's to choose), so it never marks the whole host down;
      // host-control calls (`observe`) decide that.
      pass.report.error(error, "runner status \(id.short)")
      return
    }
    switch RunnerBootstrap.parseStatus(result) {
    case .exited(let status):
      let late = allocation.job == nil ? finishedJob(allocation, pool: pool, pass: &pass) : nil
      update(id) {
        if let late, $0.job == nil {
          $0.job = late.reference
          $0.assignedAt = $0.assignedAt ?? clock.now()
          if $0.registration == .registered { $0.registration = .assigned }
        }
        $0.runnerExitStatus = status
        $0.finishedAt = $0.finishedAt ?? clock.now()
        // A clean exit proves nothing ran when GitHub never showed a job
        // (for example, a job message the runner could not acquire).
        if status != 0 {
          $0.execution = .failed
        } else if $0.job != nil {
          $0.execution = .succeeded
        } else {
          $0.execution = .unknown
          $0.note("runner exited before GitHub reported an assigned job")
        }
        $0.note("runner process exited with status \(status)")
      }
    case .vanished:
      update(id) {
        $0.finishedAt = $0.finishedAt ?? clock.now()
        $0.execution = .interrupted
        $0.note("runner process ended without recording a status")
      }
    case .running, .absent, nil:
      break
    }
  }

  /// A job that started and finished between two passes never appears as
  /// active: look for it once, by the exact runner identity, among the
  /// newest completed runs.
  private func finishedJob(
    _ allocation: AllocationRecord, pool: PoolConfiguration, pass: inout Pass
  ) -> GitHubJobInfo? {
    guard pass.githubHealthy, allocation.runnerID != nil || allocation.runnerName != nil else {
      return nil
    }
    let jobs: [GitHubJobInfo]
    do { jobs = try runners.completedJobs(scope: pool.scope) } catch {
      githubFailure(error, "finished job correlation", pass: &pass)
      return nil
    }
    guard
      let job = jobs.first(where: {
        ($0.runnerID != nil && $0.runnerID == allocation.runnerID)
          || ($0.runnerName != nil && $0.runnerName == allocation.runnerName)
      })
    else { return nil }
    _ = try? store.event(
      "allocation:\(allocation.id)", "allocation.assigned",
      "GitHub reports job \(job.id) finished on this runner",
      data: [
        "repository": job.repository.rawValue, "run": String(job.runID), "job": String(job.id),
      ])
    return job
  }

  // MARK: (2) Lifecycle

  private func lifecycle(
    _ id: AllocationID, scope: GitHubRunnerScope, pool: PoolConfiguration, state: PoolState,
    pass: inout Pass
  ) {
    guard let allocation = try? store.allocation(id), !allocation.isSettled else { return }
    // Unknown is never failed, stopped or reusable: wait for resolution.
    if allocation.uncertainty != nil || allocation.registration == .uncertain
      || pass.hostsDown.contains(allocation.host)
    {
      return
    }
    let now = clock.now()
    let limits = configuration.profiles[pool.profile].flatMap { configuration.limits[$0.limits] }
    let stopGrace = limits?.stopGraceSeconds ?? 60
    let ended =
      allocation.runnerExitStatus != nil || allocation.execution.isTerminal
      || (allocation.job != nil && allocation.registration == .removed)

    switch allocation.desired {
    case .release:
      release(id, pass: &pass)
      return
    case .retainLive, .retainStopped:
      if state == .removing || allocation.retentionUntil.map({ now >= $0 }) ?? true {
        release(id, pass: &pass)
      }
      return
    case .stop:
      if allocation.holdsRegistration, allocation.runnerID != nil {
        _ = deleteOwned(id, scope: scope, pass: &pass, evenIfBusy: true)
      }
      if !allocation.execution.isTerminal && allocation.job != nil {
        update(id) { $0.execution = .interrupted }
      }
      stopAndRelease(id, exitStatus: allocation.runnerExitStatus, pass: &pass)
      return
    case .active, .drain:
      break
    }

    // Hard deadline: retire before the host-enforced stop; never extend it.
    if now + stopGrace >= allocation.hardDeadline {
      let recorded = update(id) {
        $0.desired = .stop
        $0.note("hard deadline reached")
      }
      guard recorded else {
        // Never loop on a store that cannot record the stop.
        pass.report.error(
          CIError.storage("cannot record the deadline stop for \(id.short)"), "deadline")
        return
      }
      if allocation.job != nil && !ended {
        pass.report.error(
          CIError(.timeout, "allocation \(id.short) reached its hard deadline while assigned"),
          "deadline")
      }
      lifecycle(id, scope: scope, pool: pool, state: state, pass: &pass)
      return
    }

    if ended {
      finishEnded(id, scope: scope, pool: pool, state: state, limits: limits, pass: &pass)
      return
    }

    // Provisioned but never bootstrapped (new, or a resolved lost JIT reply).
    if allocation.readyAt != nil && allocation.registration == .intended
      && allocation.desired == .active && state == .active && pass.githubHealthy
    {
      bootstrap(id, scope: scope, pool: pool, pass: &pass)
      return
    }
    if allocation.readyAt == nil {
      // Unfinished here only after a controller restart; a stopped host run
      // never becomes ready, so release it now rather than at the timeout.
      let stopped = allocation.observedRunPhase.map { $0 != .running } ?? false
      if stopped
        || (allocation.instance == nil
          && now >= allocation.createdAt + (limits?.bootSeconds ?? 600) * 2)
      {
        update(id) {
          $0.desired = .release
          $0.note(
            stopped
              ? "provisioning was interrupted and the host run stopped"
              : "provisioning did not complete in time")
        }
        release(id, pass: &pass)
      }
      return
    }

    // Idle retirement (never while GitHub reports the runner busy or a job).
    guard allocation.job == nil else { return }
    let info = pass.runnerInfo[id]
    if info?.busy == true { return }
    var reason: String?
    if allocation.desired == .drain || state == .draining || state == .removing {
      reason = "draining"
    } else if state == .inactive {
      // An inactive pool has lost a required guarantee or its credentials:
      // its idle runners must not take another job from GitHub.
      reason = "pool is inactive"
    } else if let gate {
      reason = "activation refused: \(gate)"
    } else if let retire = allocation.idleRetireAt, now >= retire {
      reason = "idle allowance used"
    } else if let ready = allocation.readyAt, info?.status != "online",
      now >= ready + (limits?.bootSeconds ?? 600)
    {
      reason = "runner did not come online"
    } else if allocation.registration == .removed {
      reason = "registration removed while idle"
    }
    guard let reason else { return }
    retire(id, reason: reason, scope: scope, pass: &pass)
  }

  private func retire(
    _ id: AllocationID, reason: String, scope: GitHubRunnerScope, pass: inout Pass
  ) {
    if let allocation = try? store.allocation(id), allocation.holdsRegistration,
      allocation.runnerID != nil
    {
      switch deleteOwned(id, scope: scope, pass: &pass) {
      case .busy:
        // Assignment race: GitHub gave it a job; let that job run.
        return
      case .failed:
        return
      case .deleted, .gone:
        break
      }
    }
    update(id) {
      $0.desired = .release
      if $0.execution == .pending { $0.execution = .cancelled }
      $0.note("retired: \(reason)")
    }
    pass.report.retired.append(id)
    _ = try? store.event("allocation:\(id)", "allocation.retired", reason)
    stopAndRelease(id, exitStatus: nil, pass: &pass)
  }

  /// The runner ended (or GitHub removed its registration after a job):
  /// never feed another job into this VM.
  private func finishEnded(
    _ id: AllocationID, scope: GitHubRunnerScope, pool: PoolConfiguration, state: PoolState,
    limits: LimitsDescriptor?, pass: inout Pass
  ) {
    guard let allocation = try? store.allocation(id) else { return }
    let now = clock.now()
    if let job = allocation.job, job.conclusion == nil, let finished = allocation.finishedAt,
      now < finished + Self.conclusionWaitSeconds
    {
      return
    }
    // A failed deletion stays `removalPending` and is retried by refresh;
    // the VM is still never given another job.
    if allocation.holdsRegistration, allocation.runnerID != nil {
      _ = deleteOwned(id, scope: scope, pass: &pass, evenIfBusy: true)
    }
    let conclusionFailed = allocation.job?.conclusion.map {
      !["success", "skipped", "neutral"].contains($0)
    }
    let processFailed =
      (allocation.runnerExitStatus ?? 0) != 0 || allocation.execution == .interrupted
    let failed = conclusionFailed ?? processFailed
    if failed, pool.retentionOnFailure != .disabled, state != .removing, let limits {
      let mode: RetentionMode = pool.retentionOnFailure == .live ? .live : .stopped
      let seconds = mode == .live ? limits.liveRetentionSeconds : limits.stoppedRetentionSeconds
      do {
        if mode == .stopped {
          try provider.complete(id, exitStatus: allocation.runnerExitStatus)
        }
        try provider.retain(id, mode: mode, seconds: seconds)
        pass.report.retained.append(id)
        update(id) {
          if $0.retentionUntil == nil { $0.retentionUntil = now + seconds }
        }
        return
      } catch {
        pass.report.error(error, "retain \(id.short)")
      }
    }
    update(id) { $0.desired = .release }
    stopAndRelease(id, exitStatus: allocation.runnerExitStatus, pass: &pass)
  }

  private func stopAndRelease(_ id: AllocationID, exitStatus: Int32?, pass: inout Pass) {
    provider.closeSession(id)
    if let allocation = try? store.allocation(id), allocation.instance != nil,
      allocation.observedRunPhase == .running
    {
      do { try provider.complete(id, exitStatus: exitStatus) } catch {
        pass.report.error(error, "complete \(id.short)")
      }
    }
    release(id, pass: &pass)
  }

  /// iso cleanup is always performed; GitHub deregistration never replaces it.
  private func release(_ id: AllocationID, pass: inout Pass) {
    do {
      try provider.release(id)
      if let after = try? store.allocation(id), after.vmCleanup == .verified {
        pass.report.released.append(id)
      }
    } catch {
      pass.report.error(error, "release \(id.short)")
    }
  }

  private enum DeleteOutcome { case deleted, gone, busy, failed }

  /// Removes exactly the owned registration: recorded id AND recorded name
  /// AND this allocation. Never by name prefix. The intent is persisted
  /// before the request.
  private func deleteOwned(
    _ id: AllocationID, scope: GitHubRunnerScope, pass: inout Pass, evenIfBusy: Bool = false
  ) -> DeleteOutcome {
    guard let allocation = try? store.allocation(id), let runnerID = allocation.runnerID,
      let name = allocation.runnerName
    else { return .gone }
    let deletes = ((try? store.intents(allocation: id)) ?? []).filter {
      $0.kind == .githubRunnerDelete
    }
    let existing = deletes.last { $0.status != .confirmed && $0.status != .refused }
    // A settled (refused) attempt keeps its row; a later attempt gets its own id.
    let attempt = deletes.isEmpty ? "" : "-\(deletes.count)"
    var intent =
      existing
      ?? IntentRecord(
        id: "delete-\(id.rawValue)-\(runnerID)\(attempt)", allocation: id,
        kind: .githubRunnerDelete,
        parameters: ["runner_id": String(runnerID), "runner_name": name], at: clock.now())
    if existing == nil {
      do { try store.insert(intent) } catch {
        pass.report.error(error, "persist delete intent")
        return .failed
      }
    }
    update(id) { $0.registration = .removalPending }
    do {
      guard let info = try runners.runner(scope: scope, id: runnerID) else {
        settleDelete(&intent, id, outcome: "already gone")
        return .gone
      }
      guard info.name == name else {
        update(id) {
          $0.uncertainty = "runner \(runnerID) carries another name; not deleted"
        }
        pass.report.uncertain.append(id)
        return .failed
      }
      if info.busy && !evenIfBusy {
        update(id) { $0.registration = .assigned }
        return .busy
      }
      intent.status = .sent
      intent.attempts += 1
      intent.updatedAt = clock.now()
      try? store.save(intent)
      let removed = try runners.deleteRunner(scope: scope, id: runnerID)
      settleDelete(&intent, id, outcome: removed ? "deleted" : "already gone")
      return removed ? .deleted : .gone
    } catch {
      if error.code == .githubRefused, !evenIfBusy {
        // GitHub refuses to delete a runner that is running a job.
        update(id) { $0.registration = .assigned }
        intent.status = .refused
        intent.outcome = "refused: \(error.message)"
        try? store.save(intent)
        return .busy
      }
      intent.status = .uncertain
      intent.updatedAt = clock.now()
      try? store.save(intent)
      githubFailure(error, "delete runner \(runnerID)", pass: &pass)
      return .failed
    }
  }

  private func settleDelete(_ intent: inout IntentRecord, _ id: AllocationID, outcome: String) {
    intent.status = .confirmed
    intent.outcome = outcome
    intent.updatedAt = clock.now()
    try? store.save(intent)
    update(id) { $0.registration = .removed }
    _ = try? store.event("allocation:\(id)", "registration.removed", outcome)
  }

  // MARK: (3)+(4) Replenishment

  private func plan(
    _ pool: PoolConfiguration, state: PoolState, since: EpochSeconds, pass: inout Pass
  ) -> [ScheduleRequest] {
    let open = (try? store.openAllocations(pool: self.pool)) ?? []
    let live = open.filter { !$0.isSettled }.count
    let idleOrStarting = open.filter {
      $0.desired == .active && $0.job == nil && !$0.execution.isTerminal
        && $0.runnerExitStatus == nil
        && $0.vmCleanup != .verified
    }.count
    pass.report.live = live
    pass.report.idle = idleOrStarting
    // Re-read: a pause or drain may have arrived since this pass started.
    let current = (try? store.poolStatus(self.pool))?.state ?? .inactive
    guard state == .active, current == .active else {
      pass.report.admissionPaused = "pool is \((current == .active ? state : current).rawValue)"
      return []
    }
    var waiting: [PendingScaleSetJob] = []
    let wanted: Int
    if let scaleSet = pool.scaleSet {
      guard let demand = scaleSetDemand, demand.connected else {
        pass.report.admissionPaused =
          "the scale set session is not established"
          + (scaleSetDemand?.lastError.map { ": \($0)" } ?? "")
        return []
      }
      if let block = demand.admissionBlock {
        pass.report.admissionPaused = block
        return []
      }
      // Busy runners serve running jobs; idle and starting ones the waiting.
      let busy = open.filter {
        $0.desired == .active && $0.job != nil && !$0.execution.isTerminal
          && $0.runnerExitStatus == nil && $0.vmCleanup != .verified
      }.count
      waiting = demand.pending
      wanted = max(Int(scaleSet.minRunners), demand.neededRunners) - idleOrStarting - busy
    } else {
      guard pool.desiredIdleVMs > 0 else {
        pass.report.admissionPaused = "desired_idle_vms is 0 (paused, non-replenishing)"
        return []
      }
      wanted = Int(pool.desiredIdleVMs) - idleOrStarting
    }
    guard pass.githubHealthy else {
      pass.report.admissionPaused = "GitHub is unavailable; admission paused this pass"
      return []
    }
    if let unresolved = open.first(where: { $0.uncertainty != nil || $0.registration == .uncertain }
    ) {
      pass.report.admissionPaused = "resolving uncertainty on \(unresolved.id.short) first"
      return []
    }
    let room = Int(pool.maxLiveVMs) - live
    let deficit = max(0, min(wanted, room))
    pass.report.deficit = deficit
    guard deficit > 0,
      let profile = try? ResolvedProfile(name: pool.profile, configuration: configuration)
    else { return [] }
    // Idle and starting runners take the oldest waiting jobs; each further
    // waiting job is one request, dated by GitHub's queue time.
    var requests: [ScheduleRequest] = []
    for job in waiting.dropFirst(idleOrStarting).prefix(deficit) {
      requests.append(
        request(
          id: "job:\(self.pool):\(job.key)", at: job.enqueuedAt, pool, profile))
    }
    for index in requests.count..<deficit {
      let kind = pool.scaleSet == nil ? "warm" : "min"
      requests.append(request(id: "\(kind):\(self.pool):\(index)", at: since, pool, profile))
    }
    return requests
  }

  private func request(
    id: String, at: EpochSeconds, _ pool: PoolConfiguration, _ profile: ResolvedProfile
  ) -> ScheduleRequest {
    ScheduleRequest(
      id: id, enqueuedAt: at, pool: self.pool, candidates: pool.hosts,
      reservation: profile.limits.reservation, exclusive: profile.profile.isExclusive,
      guestOS: profile.profile.guestOS)
  }

  /// Persists the allocation and runner name, admits, provisions, then
  /// bootstraps. Returns false when no more capacity should be tried.
  private func create(
    _ pool: PoolConfiguration, scope: GitHubRunnerScope, host granted: Name?, pass: inout Pass
  ) -> Bool {
    let profile: ResolvedProfile
    do { profile = try ResolvedProfile(name: pool.profile, configuration: configuration) } catch {
      pass.report.error(error, "profile")
      return false
    }
    let now = clock.now()
    // A host that refuses admission is skipped for the rest of the pass, so
    // one unqualified worker never stops the others from serving the pool.
    var placed: (host: Name, admission: Admission)?
    if let granted {
      do { placed = (granted, try provider.admit(host: granted, profile: profile)) } catch {
        pass.report.error(error, "admission on \(granted)")
        pass.refusedHosts.insert(granted)
        return false
      }
    }
    while placed == nil {
      let candidates = pool.hosts.filter { !pass.refusedHosts.contains($0) }
      let choice: (choice: Name?, refusals: [PlacementRefusal])
      do {
        choice = try placement.choose(
          candidates: candidates, profile: profile, configuration: configuration, store: store,
          fairnessKey: self.pool.rawValue, now: now)
      } catch {
        pass.report.error(error, "placement")
        return false
      }
      guard let host = choice.choice else {
        let refused = pass.refusedHosts.sorted().map { "\($0): admission refused" }
        pass.report.admissionPaused =
          "no eligible host: "
          + (choice.refusals.map { "\($0.host): \($0.reason)" } + refused)
          .joined(separator: "; ")
        return false
      }
      do { placed = (host, try provider.admit(host: host, profile: profile)) } catch {
        pass.report.error(error, "admission on \(host)")
        pass.refusedHosts.insert(host)
      }
    }
    guard let (host, admission) = placed else { return false }
    let id = AllocationID.generate()
    var provenance = InputProvenance(
      profileDigest: profile.digest, imageReference: profile.image.isoImage,
      imageDigest: profile.image.digest(on: host),
      expectedRunnerVersion: profile.image.runnerVersion,
      networkPolicyDigest: admission.expectedNetworkPolicy,
      qualificationDigest: admission.qualificationDigest,
      qualificationTuple: admission.qualificationTuple,
      compatibilityDigest: profile.compatibility.digestOfDescriptor,
      limitsDigest: profile.limits.digestOfDescriptor, platform: profile.profile.platform)
    provenance.dependencyAttempts = []
    var record = AllocationRecord(
      id: id, kind: .connected, controller: controller, host: host, hostRun: .generate(),
      operations: HostOperations(create: .generate()), provenance: provenance,
      reservation: profile.limits.reservation, createdAt: now,
      hardDeadline: now + profile.limits.hardDeadlineSeconds)
    record.pool = self.pool
    record.completionGraceSeconds =
      profile.limits.stopGraceSeconds + profile.limits.exportGraceSeconds
    record.runnerName = Self.runnerName(controller: controller, allocation: id)
    record.githubScope = pool.scope.description
    record.labels = pool.labels.map(\.rawValue)
    do {
      try store.insert(record)
      try store.event(
        "allocation:\(id)", "allocation.created", "connected allocation on \(host)",
        data: ["pool": self.pool.rawValue, "runner": record.runnerName ?? ""])
    } catch {
      pass.report.error(error, "persist allocation")
      return false
    }
    pass.report.created.append(id)
    trace?.record(
      "allocation_created", pool: self.pool,
      fields: ["allocation": .string(id.rawValue), "host": .string(host.rawValue)])
    if let launcher, let digest = configuration.poolDigest(self.pool) {
      do { try launcher.launch(id, pool: self.pool, poolDigest: digest) } catch {
        pass.report.error(error, "supervisor \(id.short)")
        update(id) {
          $0.desired = .release
          $0.execution = .cancelled
          $0.note("the allocation supervisor could not start")
        }
        release(id, pass: &pass)
        return false
      }
      return true
    }
    return start(id, profile: profile, admission: admission, scope: scope, pool: pool, pass: &pass)
  }

  /// The supervisor's work: re-admit the recorded host (the admission is
  /// not persisted), refuse if its evidence no longer matches what the
  /// allocation recorded, then provision, hold the session and bootstrap.
  package func startAllocation(_ id: AllocationID, reporter: SupervisorReporter?) -> ReconcileReport
  {
    var pass = Pass(report: ReconcileReport(pool: pool))
    guard let pool = configuration.pools[self.pool], let record = try? store.allocation(id),
      record.pool == self.pool, record.instance == nil, record.readyAt == nil,
      let profile = try? ResolvedProfile(name: pool.profile, configuration: configuration)
    else {
      pass.report.error(CIError(.conflict, "allocation \(id.short) is not startable"), "supervise")
      reporter?.report(.failed, detail: "not startable")
      return pass.report
    }
    let scope = GitHubRunnerScope(pool.scope)
    reporter?.report(.provisioning)
    let admission: Admission
    do { admission = try provider.admit(host: record.host, profile: profile) } catch {
      pass.report.error(error, "admission on \(record.host)")
      update(id) {
        $0.desired = .release
        $0.execution = .cancelled
      }
      release(id, pass: &pass)
      reporter?.report(.failed, detail: error.message)
      return pass.report
    }
    guard admission.expectedNetworkPolicy == record.provenance.networkPolicyDigest,
      admission.qualificationDigest == record.provenance.qualificationDigest
    else {
      update(id) {
        $0.desired = .release
        $0.execution = .cancelled
        $0.note("host evidence changed between scheduling and start")
      }
      release(id, pass: &pass)
      reporter?.report(.failed, detail: "host evidence changed")
      return pass.report
    }
    let started = start(
      id, profile: profile, admission: admission, scope: scope, pool: pool, pass: &pass,
      reporter: reporter)
    let after = try? store.allocation(id)
    reporter?.report(
      started && after?.readyAt != nil && after?.desired == .active ? .holding : .failed,
      runnerID: after?.runnerID, detail: pass.report.errors.first)
    return pass.report
  }

  private func start(
    _ id: AllocationID, profile: ResolvedProfile, admission: Admission, scope: GitHubRunnerScope,
    pool: PoolConfiguration, pass: inout Pass, reporter: SupervisorReporter? = nil
  ) -> Bool {
    do {
      try provider.provision(id, profile: profile, admission: admission)
    } catch {
      pass.report.error(error, "provision \(id.short)")
      if error.code == .operationUncertain {
        pass.report.uncertain.append(id)
      } else {
        update(id) {
          $0.desired = .release
          if $0.execution == .pending { $0.execution = .cancelled }
        }
        release(id, pass: &pass)
      }
      return false
    }
    do { try provider.holdSession(id, forwards: []) } catch {
      pass.report.error(error, "session \(id.short)")
      update(id) { $0.desired = .release }
      release(id, pass: &pass)
      return false
    }
    reporter?.report(.registering)
    bootstrap(id, scope: scope, pool: pool, pass: &pass)
    return true
  }

  /// JIT registration (VM already proven) → guest delivery over stdin →
  /// detached official runner → registration verification.
  private func bootstrap(
    _ id: AllocationID, scope: GitHubRunnerScope, pool: PoolConfiguration, pass: inout Pass
  ) {
    guard let allocation = try? store.allocation(id), let name = allocation.runnerName,
      let profile = try? ResolvedProfile(name: pool.profile, configuration: configuration)
    else { return }
    let previous = ((try? store.intents(allocation: id)) ?? []).filter {
      $0.kind == .githubJITCreate
    }
    guard previous.count < Self.maxJITAttempts else {
      update(id) {
        $0.desired = .release
        $0.note("JIT registration attempts exhausted")
      }
      release(id, pass: &pass)
      return
    }
    guard runnerVersionApproved(id, allocation, profile, pass: &pass),
      let groupID = runnerGroup(pool, pass: &pass),
      let jit = registerJIT(
        id, name: name, attempt: previous.count + 1, groupID: groupID, scope: scope, pool: pool,
        pass: &pass),
      serviceHostsApproved(id, jit, profile, pass: &pass),
      startRunner(id, jit, profile, pass: &pass)
    else { return }
    verifyRegistration(
      id, jit, name: name, groupID: groupID, scope: scope, pool: pool, profile: profile,
      pass: &pass)
  }

  /// Pinned runner version: verifies the image's actual runner before any
  /// bootstrap material is released; a mismatch drains the pool.
  private func runnerVersionApproved(
    _ id: AllocationID, _ allocation: AllocationRecord, _ profile: ResolvedProfile,
    pass: inout Pass
  ) -> Bool {
    guard allocation.actualRunnerVersion == nil else { return true }
    let actual: String?
    do {
      actual = RunnerBootstrap.parseVersion(
        try provider.execute(
          id, RunnerBootstrap.version(runnerDirectory: profile.image.runnerDirectory)))
    } catch {
      pass.report.error(error, "runner version \(id.short)")
      return false
    }
    update(id) { $0.actualRunnerVersion = actual ?? "unknown" }
    guard actual == profile.image.runnerVersion else {
      let reason =
        "runner version \(actual ?? "unknown") differs from the approved \(profile.image.runnerVersion)"
      update(id) {
        $0.desired = .release
        $0.registration = .removed
        $0.note(reason)
      }
      try? PoolControl.set(self.pool, .draining, reason: reason, store: store)
      pass.report.error(CIError(.admissionRefused, reason), "runner version")
      release(id, pass: &pass)
      return false
    }
    return true
  }

  private func runnerGroup(_ pool: PoolConfiguration, pass: inout Pass) -> Int64? {
    if let cached = pass.groupID { return cached }
    do {
      let groupID = try runners.runnerGroupID(pool.scope)
      pass.groupID = groupID
      return groupID
    } catch {
      githubFailure(error, "runner group", pass: &pass)
      return nil
    }
  }

  /// Persists the JIT intent, then registers the runner. A lost reply is
  /// left uncertain (resolved by lookup); a refusal releases the VM.
  private func registerJIT(
    _ id: AllocationID, name: String, attempt: Int, groupID: Int64, scope: GitHubRunnerScope,
    pool: PoolConfiguration, pass: inout Pass
  ) -> GitHubJITConfig? {
    // Persist the intent (and an uncertain registration) before sending, so
    // a crash after sending is resolved by lookup, never by a blind retry.
    var intent = IntentRecord(
      id: "jit-\(id.rawValue)-\(attempt)", allocation: id, kind: .githubJITCreate,
      parameters: ["runner_name": name, "scope": scope.description], at: clock.now())
    do {
      try store.insert(intent)
      intent.status = .sent
      intent.attempts = 1
      try store.save(intent)
      try store.update(id) { $0.registration = .uncertain }
    } catch {
      pass.report.error(error, "persist JIT intent")
      return nil
    }
    let jit: GitHubJITConfig
    do {
      jit = try runners.generateJIT(
        scope: scope, name: name, runnerGroupID: groupID, labels: pool.labels.map(\.rawValue),
        workFolder: "_work")
    } catch {
      if error.details["uncertain"] == "true" || error.code == .githubUnavailable {
        intent.status = .uncertain
        intent.outcome = "reply lost: \(error.code.rawValue)"
        try? store.save(intent)
        pass.report.uncertain.append(id)
        pass.report.error(
          CIError(
            .registrationUncertain, "JIT reply for \(id.short) was lost; reconciling by name"),
          "jit")
        githubFailure(error, "jit", pass: &pass)
      } else {
        intent.status = .refused
        intent.outcome = "refused: \(error.code.rawValue)"
        try? store.save(intent)
        update(id) {
          $0.registration = .removed
          $0.desired = .release
          $0.note("JIT registration refused: \(error.message)")
        }
        pass.report.error(error, "jit")
        release(id, pass: &pass)
      }
      return nil
    }
    intent.status = .confirmed
    intent.outcome = "runner \(jit.runner.id)"
    intent.updatedAt = clock.now()
    try? store.save(intent)
    update(id) {
      $0.runnerID = jit.runner.id
      $0.registration = .registered
    }
    _ = try? store.event(
      "allocation:\(id)", "registration.created", "runner \(jit.runner.id) registered",
      data: ["runner_id": String(jit.runner.id)])
    return jit
  }

  /// GitHub picks some service hosts per account; never start a runner
  /// whose hosts the approved policy does not name (it would only loop
  /// offline). The operator resolves it explicitly; nothing is auto-allowed.
  private func serviceHostsApproved(
    _ id: AllocationID, _ jit: GitHubJITConfig, _ profile: ResolvedProfile, pass: inout Pass
  ) -> Bool {
    let approved = profile.network.requiredHosts
    let assigned = jit.serviceHosts()
    let missing = assigned.map { hosts in
      hosts.filter { host in !approved.contains { $0.matches(host) } }.sorted()
    }
    if missing == nil || missing?.isEmpty == false {
      let detail =
        missing.map {
          "GitHub assigned runner service host(s) \($0.joined(separator: ", ")) that network policy \(profile.profile.networkPolicy) does not approve; add them to its required_hosts and to the iso egress allowlist, re-approve, then `iso-ci pool resume \(self.pool)`"
        } ?? "the JIT configuration's service hosts could not be read; refusing to start the runner"
      update(id) {
        $0.desired = .stop
        $0.note(detail)
      }
      try? PoolControl.set(self.pool, .paused, reason: detail, store: store)
      pass.report.error(CIError(.capabilityMissing, detail), "jit hosts")
      return false
    }
    return true
  }

  private func startRunner(
    _ id: AllocationID, _ jit: GitHubJITConfig, _ profile: ResolvedProfile, pass: inout Pass
  ) -> Bool {
    let started: GuestCommandResult
    do {
      started = try provider.execute(
        id,
        RunnerBootstrap.start(
          runnerDirectory: profile.image.runnerDirectory, jit: jit.encoded,
          mode: .connected(docker: profile.image.docker)))
    } catch {
      pass.report.error(error, "runner start \(id.short)")
      update(id) { $0.desired = .stop }
      return false
    }
    guard started.succeeded else {
      update(id) {
        $0.desired = .stop
        $0.note(
          "runner bootstrap failed: \(RunnerBootstrap.StartFailure.describe(started.exitStatus))")
      }
      pass.report.error(
        CIError(.guestFailed, "runner bootstrap failed for \(id.short)"), "bootstrap")
      return false
    }
    return true
  }

  private func verifyRegistration(
    _ id: AllocationID, _ jit: GitHubJITConfig, name: String, groupID: Int64,
    scope: GitHubRunnerScope, pool: PoolConfiguration, profile: ResolvedProfile,
    pass: inout Pass
  ) {
    do {
      guard let info = try runners.runner(scope: scope, id: jit.runner.id) else {
        update(id) {
          $0.registration = .removed
          $0.desired = .stop
          $0.note("registration vanished right after creation")
        }
        return
      }
      pass.runnerInfo[id] = info
      let labels = pool.labels.map(\.rawValue)
      // A scale set's runners carry its labels and may carry its name.
      let allowed = Set((labels + [pool.scaleSet?.name].compactMap { $0 }).map { $0.lowercased() })
      let labelsDiffer =
        pool.scaleSet == nil
        ? !info.hasExactly(labels) : !info.labels.allSatisfy { allowed.contains($0.lowercased()) }
      var mismatch: String?
      if info.name != name {
        mismatch = "runner name differs"
      } else if !info.labels.isEmpty && labelsDiffer {
        mismatch = "GitHub labels \(info.labels.sorted()) differ from the pool's \(labels.sorted())"
      } else if case .organization = pool.scope, let reported = info.runnerGroupID,
        reported != groupID
      {
        mismatch = "runner group \(reported) is not the configured group \(groupID)"
      }
      if let mismatch {
        update(id) {
          $0.desired = .stop
          $0.note("registration verification failed: \(mismatch)")
        }
        try? PoolControl.set(
          self.pool, .inactive, reason: "registration verification failed: \(mismatch)",
          store: store)
        pass.report.error(CIError(.admissionRefused, mismatch), "verify \(id.short)")
        return
      }
      let limits = profile.limits
      update(id) {
        $0.labels = info.labels.isEmpty ? labels : info.labels
        let ready = $0.readyAt ?? clock.now()
        let allowance =
          $0.hardDeadline > limits.jobSeconds + limits.stopGraceSeconds
          ? $0.hardDeadline - limits.jobSeconds - limits.stopGraceSeconds : ready
        $0.idleRetireAt = min(ready + limits.idleSeconds, allowance)
      }
    } catch {
      githubFailure(error, "verify registration", pass: &pass)
    }
  }

  // MARK: Supervised resolution

  /// The operator's decision for a registration iso-ci could not resolve:
  /// `runnerID: nil` asserts no registration exists; otherwise the exact
  /// runner (whose name must match the recorded one) is deleted.
  package func superviseRegistration(_ id: AllocationID, runnerID: Int64?) throws(CIError) {
    guard let allocation = try store.allocation(id), let pool = configuration.pools[self.pool]
    else {
      throw CIError(.notFound, "unknown allocation \(id)")
    }
    let scope = GitHubRunnerScope(pool.scope)
    if let runnerID {
      guard let info = try runners.runner(scope: scope, id: runnerID) else {
        throw CIError(.notFound, "runner \(runnerID) does not exist")
      }
      guard info.name == allocation.runnerName else {
        throw CIError(.conflict, "runner \(runnerID) is not this allocation's runner")
      }
      try store.update(id) {
        $0.runnerID = runnerID
        $0.uncertainty = nil
        $0.registration = .removalPending
      }
      var pass = Pass(report: ReconcileReport(pool: self.pool))
      switch deleteOwned(id, scope: scope, pass: &pass, evenIfBusy: true) {
      case .deleted, .gone:
        break
      case .busy, .failed:
        throw CIError(
          .operationUncertain,
          "runner \(runnerID) was not deleted (\(pass.report.errors.first ?? "see `iso-ci inspect`")); the registration stays removal-pending and is retried each pass"
        )
      }
    } else {
      try store.update(id) {
        $0.uncertainty = nil
        $0.registration = .removed
        $0.desired = .release
        $0.note("operator resolved: no registration exists")
      }
    }
    try store.event("allocation:\(id)", "registration.supervised", "operator resolved registration")
  }

  // MARK: Helpers

  @discardableResult
  private func update(_ id: AllocationID, _ change: (inout AllocationRecord) -> Void) -> Bool {
    (try? store.update(id) { (record) throws(CIError) in change(&record) }) != nil
  }

  private func githubFailure(_ error: CIError, _ context: String, pass: inout Pass) {
    pass.report.error(error, context)
    switch error.code {
    case .githubUnavailable:
      pass.githubHealthy = false
    case .unauthorized:
      pass.githubHealthy = false
      try? PoolControl.set(
        pool, .inactive, reason: "GitHub credentials were refused (revoked or invalid)",
        store: store)
    default:
      break
    }
  }
}
