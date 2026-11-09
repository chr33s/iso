import Foundation
import Synchronization

/// The GitHub-side reads a scale-set listener needs, scoped to its pool's
/// installation; faked in tests.
package protocol ScaleSetAuthority: Sendable {
  /// A fresh Actions service admin connection for `scope`.
  func connect(_ scope: GitHubRunnerScope, now: EpochSeconds) throws(CIError)
    -> ActionsServiceConnection
  func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64
  /// GitHub's workflow run record, which the job policy decides on.
  func runFacts(_ repository: RepositoryName, run: Int64) throws(CIError) -> JobFacts
}

/// `ScaleSetAuthority` over the pool's installation: runner administration
/// for the registration token, Actions read narrowed to the job's repository.
package struct InstallationScaleSetAuthority: ScaleSetAuthority {
  let client: GitHubInstallationClient
  let scaleSets: ScaleSetClient

  package init(client: GitHubInstallationClient, scaleSets: ScaleSetClient) {
    self.client = client
    self.scaleSets = scaleSets
  }

  package func connect(_ scope: GitHubRunnerScope, now: EpochSeconds) throws(CIError)
    -> ActionsServiceConnection
  {
    try scaleSets.connect(
      scope: scope, api: client.api,
      installationToken: try client.token(.runnerAdministration(scope)), now: now)
  }

  package func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64 {
    try InstallationRunnerService(client: client).runnerGroupID(scope)
  }

  package func runFacts(_ repository: RepositoryName, run: Int64) throws(CIError) -> JobFacts {
    try client.api.workflowRun(
      repository: repository, id: run, token: try client.token(.actionsRead(repository)))
  }
}

/// A job GitHub assigned to this scale set that no runner has started.
package struct PendingScaleSetJob: Sendable, Equatable {
  /// `ScaleSetJobMessage.key`.
  package let key: String
  package let requestID: Int64
  package let enqueuedAt: EpochSeconds
  package let repository: String?
  package let runID: Int64?

  package init(
    key: String? = nil, requestID: Int64, enqueuedAt: EpochSeconds, repository: String?,
    runID: Int64?
  ) {
    self.key = key ?? "r\(requestID)"
    self.requestID = requestID
    self.enqueuedAt = enqueuedAt
    self.repository = repository
    self.runID = runID
  }
}

/// What a scale-set pool's reconciler sees of its listener.
package struct ScaleSetDemand: Sendable, Equatable {
  package var scaleSetID: Int64?
  /// Assigned, not yet started, oldest first.
  package var pending: [PendingScaleSetJob] = []
  package var statistics = ScaleSetStatistics()
  package var connected = false
  package var lastError: String?
  package var acquired = 0
  package var rejected = 0
  /// Jobs a runner has started and not completed, seen in this session.
  package var running = 0
  package var elastic = false
  /// Assigned jobs refused by the job policy (non-elastic scale sets).
  package var blocked: [JobRejection] = []

  package init() {}

  /// Waiting jobs: the known ones, or GitHub's count when that is larger
  /// (after a restart the per-job offers are gone; the count is not).
  package var waitingCount: Int { max(pending.count, Int(statistics.waitingJobs)) }

  /// Waiting jobs GitHub counts but this session never saw assigned (for
  /// example, assigned before a restart), so their policy is unknown.
  package var unknownAssigned: Int {
    max(0, Int(statistics.waitingJobs) - pending.count - blocked.count)
  }

  /// Why no runner may start (non-elastic only), or nil. GitHub lets any
  /// runner of a non-elastic scale set take any assigned job, so a runner
  /// started while a refused or unvetted job is assigned could run it.
  package var admissionBlock: String? {
    guard !elastic else { return nil }
    if let first = blocked.first {
      return
        "\(blocked.count) assigned job(s) failed the job policy (\(first.rawValue)); no runner starts while they are assigned"
    }
    if unknownAssigned > 0 {
      return
        "\(unknownAssigned) assigned job(s) were not seen this session; no runner starts until they leave the queue"
    }
    return nil
  }

  /// Runners the scale set needs: one per waiting job and one per running
  /// job (the latter counted against busy runners, so a job's own runner is
  /// not replaced while GitHub reports it assigned but not yet started).
  /// GitHub's counts bound the tracked ones: a job GitHub re-assigns (it
  /// completes the stale assignment and assigns it afresh) never leaves a
  /// tracked entry behind that would start a runner nobody needs.
  package var neededRunners: Int {
    let waiting = elastic ? waitingCount : min(pending.count, Int(statistics.waitingJobs))
    return waiting + min(running, Int(statistics.runningJobs))
  }
}

/// The interface a scale-set pool's reconciler and controller use.
package protocol ScaleSetFeed: Sendable {
  func demand() -> ScaleSetDemand
  /// A scale-set JIT runner configuration (not idempotent; a lost reply is
  /// resolved by runner name).
  func generateJIT(name: String, workFolder: String) throws(CIError) -> GitHubJITConfig
  func stop()
}

/// One scale-set pool's message session: registers (or finds) the scale
/// set, keeps a session, long-polls it, gates each offered job through the
/// pool's job policy, acquires only the jobs that pass, and tracks the
/// assigned jobs that still need a runner. It never creates a VM or a
/// runner itself; the pool reconciler does, through the scheduler.
package final class ScaleSetListener: ScaleSetFeed {
  package let pool: Name
  let configuration: PoolConfiguration
  let scaleSet: ScaleSetConfiguration
  let authority: any ScaleSetAuthority
  let client: ScaleSetClient
  let store: ControllerStore
  let owner: String
  let clock: any CIClock
  let trace: ProtocolTrace?
  private let state = Mutex(State())
  private let loop = Mutex<Thread?>(nil)
  /// Serializes connection, scale-set and session setup across the poll
  /// thread and JIT callers, so the scale set is created at most once.
  private let setup = NSLock()
  /// Deliveries of one message that failed to process; past the bound the
  /// message is deleted, so one bad message never blocks the queue.
  package static let maxMessageAttempts = 5

  private struct State {
    var connection: ActionsServiceConnection?
    var scaleSet: ScaleSetInfo?
    var session: ScaleSetSession?
    var lastMessageID: Int64 = 0
    var pending: [String: PendingScaleSetJob] = [:]
    var running: Set<String> = []
    var blocked: [String: JobRejection] = [:]
    var statistics = ScaleSetStatistics()
    var lastError: String?
    var acquired = 0
    var rejected = 0
    var stopping = false
    var failedMessage: (id: Int64, attempts: Int)?
    var sessions = 0
  }

  package init(
    pool: Name, configuration: PoolConfiguration, authority: any ScaleSetAuthority,
    client: ScaleSetClient, store: ControllerStore, owner: String,
    clock: any CIClock = SystemClock(), trace: ProtocolTrace? = nil
  ) throws(CIError) {
    guard let scaleSet = configuration.scaleSet else {
      throw CIError.config("pool \(pool) is not a scale set")
    }
    self.pool = pool
    self.configuration = configuration
    self.scaleSet = scaleSet
    self.authority = authority
    self.client = client
    self.store = store
    self.owner = owner
    self.clock = clock
    self.trace = trace
  }

  var scope: GitHubRunnerScope { GitHubRunnerScope(configuration.scope) }

  package func demand() -> ScaleSetDemand {
    state.withLock { state in
      var demand = ScaleSetDemand()
      demand.scaleSetID = state.scaleSet?.id
      demand.pending = state.pending.values.sorted {
        $0.enqueuedAt != $1.enqueuedAt ? $0.enqueuedAt < $1.enqueuedAt : $0.requestID < $1.requestID
      }
      demand.statistics = state.statistics
      demand.connected = state.session != nil
      demand.lastError = state.lastError
      demand.acquired = state.acquired
      demand.rejected = state.rejected
      demand.running = state.running.count
      demand.elastic = state.scaleSet?.elastic ?? false
      demand.blocked = state.blocked.keys.sorted().compactMap { state.blocked[$0] }
      return demand
    }
  }

  // MARK: Session

  /// One cycle: establish what is missing, then one long poll. Never
  /// throws; returns false after a failure so the loop can back off.
  @discardableResult
  package func step() -> Bool {
    do throws(CIError) {
      let (connection, info, established) = try establish(session: true)
      guard let session = established else { return false }
      let lastID = state.withLock { $0.lastMessageID }
      let message: ScaleSetMessage?
      do {
        message = try client.poll(
          session: session, lastMessageID: lastID, maxCapacity: scaleSet.maxRunners)
      } catch {
        guard error.code == .unauthorized else { throw error }
        let refreshed = try client.refreshSession(
          scaleSet: info.id, session: session.id, connection: connection)
        state.withLock { $0.session = refreshed }
        return true
      }
      // A listener stopped (or replaced after a policy change) while its
      // poll was in flight leaves the message for its successor.
      if let message, !state.withLock({ $0.stopping }) {
        do { try process(message, scaleSet: info.id, connection: connection) } catch {
          let attempts = state.withLock { state -> Int in
            let count =
              state.failedMessage?.id == message.id ? (state.failedMessage?.attempts ?? 0) + 1 : 1
            state.failedMessage = (message.id, count)
            return count
          }
          guard attempts >= Self.maxMessageAttempts else { throw error }
          _ = try? store.event(
            "pool:\(pool)", "scaleset.message_dropped",
            "message \(message.id) dropped after \(attempts) failed attempts: \(error.message)")
        }
        try client.deleteMessage(message.id, session: session)
        state.withLock { $0.lastMessageID = max($0.lastMessageID, message.id) }
      }
      state.withLock { $0.lastError = nil }
      return true
    } catch {
      state.withLock { state in
        state.lastError = "\(error.code.rawValue): \(error.message)"
        // Credentials may have expired with the failure; start over.
        if error.code == .unauthorized {
          state.connection = nil
          state.session = nil
        }
      }
      _ = try? store.event(
        "pool:\(pool)", "scaleset.error", CIError.bounded(error.message),
        data: ["code": error.code.rawValue])
      return false
    }
  }

  /// The admin connection and scale set, and the message session when
  /// `session` is true (registering a runner needs no session, and a second
  /// session would contend with the controller's).
  private func establish(session wantSession: Bool) throws(CIError) -> (
    ActionsServiceConnection, ScaleSetInfo, ScaleSetSession?
  ) {
    setup.lock()
    defer { setup.unlock() }
    let now = clock.now()
    var current = state.withLock { ($0.connection, $0.scaleSet, $0.session) }
    if current.0 == nil || now >= current.0!.expiresAt {
      let connection = try authority.connect(scope, now: now)
      state.withLock { $0.connection = connection }
      current.0 = connection
    }
    let connection = current.0!
    if current.1 == nil {
      let groupID = try authority.runnerGroupID(configuration.scope)
      let found = try client.scaleSet(
        named: scaleSet.name, groupID: groupID, connection: connection)
      let info: ScaleSetInfo
      if let found {
        info = found
      } else if !wantSession {
        // Registration callers (supervisors) never create the scale set;
        // the controller's listener does, once.
        throw CIError(.githubUnavailable, "scale set \(scaleSet.name) is not registered yet")
      } else {
        let labels = configuration.labels.map(\.rawValue)
        do {
          info = try client.createScaleSet(
            named: scaleSet.name, groupID: groupID, labels: labels, elastic: true,
            connection: connection)
        } catch {
          guard error.code == .githubRefused else { throw error }
          info = try client.createScaleSet(
            named: scaleSet.name, groupID: groupID, labels: labels, elastic: false,
            connection: connection)
        }
        _ = try? store.event(
          "pool:\(pool)", "scaleset.created",
          "scale set \(scaleSet.name) registered (\(info.elastic ? "elastic" : "non-elastic: GitHub assigns jobs directly"))",
          data: ["scale_set_id": String(info.id), "elastic": String(info.elastic)])
      }
      // Without acquisition there is no way to keep a public repository's
      // jobs off a runner before GitHub assigns them.
      if !info.elastic && scaleSet.jobPolicy.allowPublicRepo {
        throw CIError(
          .capabilityMissing,
          "allow_public_repo needs an elastic scale set (GitHub requires Administer permission to create one); scale set \(scaleSet.name) is non-elastic"
        )
      }
      state.withLock { $0.scaleSet = info }
      current.1 = info
    }
    let info = current.1!
    if wantSession && current.2 == nil {
      guard !state.withLock({ $0.stopping }) else {
        throw CIError(.conflict, "the listener is stopping")
      }
      // A fresh owner name per session: one left behind by an expired token
      // never blocks the next.
      let number = state.withLock { state -> Int in
        state.sessions += 1
        return state.sessions
      }
      let session = try client.createSession(
        scaleSet: info.id, owner: "\(owner)-\(number)", connection: connection)
      state.withLock {
        $0.session = session
        $0.statistics = session.statistics
      }
      current.2 = session
      trace?.record(
        "scaleset_session", pool: pool,
        fields: [
          "scale_set_id": .integer(info.id), "statistics": statisticsJSON(session.statistics),
        ])
    }
    return (connection, info, current.2)
  }

  // MARK: Messages

  private func process(
    _ message: ScaleSetMessage, scaleSet id: Int64, connection: ActionsServiceConnection
  ) throws(CIError) {
    state.withLock { $0.statistics = message.statistics }
    var allowed: [Int64] = []
    // One run record per workflow run per batch: a large matrix of refused
    // jobs costs one REST read, not one per job.
    var facts: [String: Result<JobFacts, CIError>] = [:]
    for job in message.jobs {
      trace?.record(
        "scaleset_message", pool: pool,
        fields: [
          "message_id": .integer(message.id), "kind": .string(job.kind.rawValue),
          "request_id": .integer(job.runnerRequestID),
          "repository": job.repository.map { .string($0.rawValue) } ?? .null,
          "event": job.eventName.map(JSONValue.string) ?? .null, "job": .string(job.key),
          "run": job.workflowRunID.map { .integer($0) } ?? .null,
          "statistics": statisticsJSON(message.statistics),
        ])
      let elastic = state.withLock { $0.scaleSet?.elastic ?? false }
      switch job.kind {
      case .available:
        // Only elastic scale sets are offered jobs; the gate runs before
        // acquisition, so a refused job never reaches this scale set.
        switch gate(job, cache: &facts) {
        case .allow: allowed.append(job.runnerRequestID)
        case .deny(let rejection, let reason): reject(job, rejection, reason)
        }
      case .assigned:
        // A non-elastic scale set is assigned jobs without an offer: gate
        // them here. A refused job blocks every new runner while assigned.
        if !elastic, case .deny(let rejection, let reason) = gate(job, cache: &facts) {
          state.withLock { $0.blocked[job.key] = rejection }
          reject(job, rejection, reason)
          continue
        }
        let now = clock.now()
        state.withLock {
          $0.pending[job.key] = PendingScaleSetJob(
            key: job.key, requestID: job.runnerRequestID,
            enqueuedAt: min(job.queueTime ?? now, now), repository: job.repository?.rawValue,
            runID: job.workflowRunID)
        }
      case .started:
        state.withLock {
          $0.pending.removeValue(forKey: job.key)
          $0.running.insert(job.key)
        }
      case .completed:
        state.withLock {
          $0.pending.removeValue(forKey: job.key)
          $0.running.remove(job.key)
          $0.blocked.removeValue(forKey: job.key)
        }
      }
    }
    // Nothing assigned at all: any tracked job is stale.
    if message.statistics.assignedJobs == 0 {
      state.withLock { state in
        state.pending.removeAll()
        state.running.removeAll()
        state.blocked.removeAll()
      }
    }
    guard !allowed.isEmpty else { return }
    let granted = try client.acquireJobs(allowed, scaleSet: id, connection: connection)
    state.withLock { $0.acquired += granted.count }
    trace?.record(
      "scaleset_acquired", pool: pool, fields: ["request_ids": .array(granted.map { .integer($0) })]
    )
    _ = try? store.event(
      "pool:\(pool)", "job.acquired",
      "acquired \(granted.count) of \(allowed.count) offered job(s)",
      data: ["request_ids": granted.map(String.init).joined(separator: ",")])
  }

  /// The pre-assignment gate: GitHub's own run record, the pool's scope
  /// and its job policy. A refused job stays queued for other runners.
  package func gate(
    _ job: ScaleSetJobMessage, cache: inout [String: Result<JobFacts, CIError>]
  ) -> JobPolicyDecision {
    var cached = cache
    defer { cache = cached }
    return JobPolicyEvaluator.evaluate(
      offer: job, scope: configuration.scope, policy: scaleSet.jobPolicy
    ) { () throws(CIError) -> JobFacts in
      guard let repository = job.repository, let run = job.workflowRunID else {
        throw CIError(.githubUnavailable, "the offer names no workflow run")
      }
      let key = "\(repository.rawValue.lowercased())#\(run)"
      if cached[key] == nil {
        do throws(CIError) {
          cached[key] = .success(try authority.runFacts(repository, run: run))
        } catch {
          cached[key] = .failure(error)
        }
      }
      return try cached[key]!.get()
    }
  }

  private func reject(_ job: ScaleSetJobMessage, _ rejection: JobRejection, _ reason: String) {
    state.withLock { $0.rejected += 1 }
    trace?.record(
      "job_rejected", pool: pool,
      fields: ["request_id": .integer(job.runnerRequestID), "code": .string(rejection.rawValue)])
    _ = try? store.event(
      "pool:\(pool)", "job.rejected", "\(rejection.rawValue): \(reason)",
      data: [
        "code": rejection.rawValue, "request_id": String(job.runnerRequestID), "job": job.key,
        "repository": job.repository?.rawValue ?? "",
        "run": job.workflowRunID.map(String.init) ?? "",
        "event": job.eventName ?? "",
      ])
  }

  // MARK: Runners

  package func generateJIT(name: String, workFolder: String) throws(CIError) -> GitHubJITConfig {
    let (connection, info, _) = try establish(session: false)
    return try client.generateJIT(
      scaleSet: info.id, name: name, workFolder: workFolder, connection: connection)
  }

  // MARK: Loop

  /// Polls on a background thread until `stop()`.
  package func start() {
    loop.withLock { thread in
      guard thread == nil else { return }
      let created = Thread { [self] in
        var failures = 0
        while !state.withLock({ $0.stopping }) {
          if step() {
            failures = 0
          } else {
            failures += 1
            Thread.sleep(forTimeInterval: min(60, Double(1 << min(failures, 6))))
          }
        }
        deleteSession()
      }
      created.name = "iso-ci scaleset \(pool)"
      created.start()
      thread = created
    }
  }

  /// Ends the loop after its current poll; the session is deleted now and
  /// again when the loop exits (it may have created one meanwhile).
  package func stop() {
    state.withLock { $0.stopping = true }
    deleteSession()
  }

  private func deleteSession() {
    let (session, info, connection) = state.withLock { state in
      defer { state.session = nil }
      return (state.session, state.scaleSet, state.connection)
    }
    if let session, let info, let connection {
      try? client.deleteSession(scaleSet: info.id, session: session.id, connection: connection)
    }
  }

}

func statisticsJSON(_ statistics: ScaleSetStatistics) -> JSONValue {
  [
    "available": .integer(statistics.availableJobs), "acquired": .integer(statistics.acquiredJobs),
    "assigned": .integer(statistics.assignedJobs), "running": .integer(statistics.runningJobs),
    "registered_runners": .integer(statistics.registeredRunners),
    "busy_runners": .integer(statistics.busyRunners),
    "idle_runners": .integer(statistics.idleRunners),
  ]
}

/// A pool's REST runner service with JIT registration through its scale
/// set; listing, lookup by name and deletion stay on the REST API, where
/// scale-set runners appear like any other.
package struct ScaleSetRunnerService: RunnerService {
  let base: any RunnerService
  let feed: any ScaleSetFeed

  package init(base: any RunnerService, feed: any ScaleSetFeed) {
    self.base = base
    self.feed = feed
  }

  package func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64 {
    try base.runnerGroupID(scope)
  }

  package func generateJIT(
    scope: GitHubRunnerScope, name: String, runnerGroupID: Int64, labels: [String],
    workFolder: String
  ) throws(CIError) -> GitHubJITConfig {
    try feed.generateJIT(name: name, workFolder: workFolder)
  }

  package func runners(scope: GitHubRunnerScope, named name: String) throws(CIError)
    -> [GitHubRunnerInfo]
  { try base.runners(scope: scope, named: name) }

  package func runner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> GitHubRunnerInfo? {
    try base.runner(scope: scope, id: id)
  }

  package func deleteRunner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> Bool {
    try base.deleteRunner(scope: scope, id: id)
  }

  package func activeJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo] {
    try base.activeJobs(scope: scope)
  }

  package func completedJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo] {
    try base.completedJobs(scope: scope)
  }

  package func job(repository: RepositoryName, id: Int64) throws(CIError) -> GitHubJobInfo {
    try base.job(repository: repository, id: id)
  }
}
