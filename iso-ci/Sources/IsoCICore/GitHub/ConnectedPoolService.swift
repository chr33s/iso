import Foundation
import Synchronization

/// The controller service for GitHub-connected pools: per pass it validates
/// configuration and approvals, evaluates GitHub-side authority, and runs
/// each pool's ready-capacity reconciler. Invalid or partial configuration,
/// unapproved descriptors and unverifiable authority leave a pool inactive.
package final class ConnectedPoolService: ControllerService {
  /// How long a GitHub-side authority evaluation is reused. A loosened
  /// control (a runner group that starts admitting public repositories, a
  /// widened permission) deactivates the pool, and retires its idle
  /// runners, within this window.
  package static let activationInterval: EpochSeconds = 60

  package let name = "pools"
  private let store: ControllerStore
  private let provider: any EnvironmentProvider
  private let loadConfiguration: @Sendable () -> Result<CIConfiguration, CIError>
  private let clients: @Sendable (InstallationRecord) throws(CIError) -> GitHubInstallationClient
  private let state = Mutex<State>(State())
  private let api: GitHubAPI
  private let credentials: any CredentialStore
  private let board: SchedulerBoard
  private let external: any ExternalUsageProbe
  private let feeds: ScaleSetFeedFactory?
  private let supervision: AllocationSupervision?
  private let trace: ProtocolTrace?

  package typealias ScaleSetFeedFactory =
    @Sendable (Name, PoolConfiguration, InstallationRecord) throws(CIError) -> any ScaleSetFeed

  /// Supervisor processes: the launcher for new allocations, the directory
  /// that says which allocations a live supervisor owns, and the startup
  /// scan (nil runs allocation startup inline in the pass).
  package struct AllocationSupervision: Sendable {
    package let launcher: any AllocationLauncher
    package let directory: any SupervisorDirectory
    package let adopt: @Sendable () -> SupervisorAdoption

    package init(
      launcher: any AllocationLauncher, directory: any SupervisorDirectory,
      adopt: @escaping @Sendable () -> SupervisorAdoption
    ) {
      self.launcher = launcher
      self.directory = directory
      self.adopt = adopt
    }

    package init(_ supervisors: AllocationSupervisors) {
      self.init(launcher: supervisors, directory: supervisors, adopt: { supervisors.adopt() })
    }
  }

  private struct State {
    var reports: [Name: ReconcileReport] = [:]
    var activation: [Name: (at: EpochSeconds, key: String, report: PoolActivationReport)] = [:]
    var resumedSessions: Set<AllocationID> = []
    var feeds: [Name: any ScaleSetFeed] = [:]
    /// The pool digest each listener was built from; a change (policy,
    /// scope, scale set) replaces the listener.
    var feedDigests: [Name: Digest] = [:]
    var demandSince: [Name: EpochSeconds] = [:]
    var modes: [Name: HostMode] = [:]
    var adopted = false
  }

  package init(
    store: ControllerStore, provider: any EnvironmentProvider,
    loadConfiguration: @escaping @Sendable () -> Result<CIConfiguration, CIError>,
    clients: @escaping @Sendable (InstallationRecord) throws(CIError) -> GitHubInstallationClient,
    api: GitHubAPI = GitHubAPI(http: URLSessionGitHubHTTP()),
    credentials: any CredentialStore = KeychainCredentialStore(),
    board: SchedulerBoard = SchedulerBoard(),
    external: any ExternalUsageProbe = NoExternalUsage(),
    feeds: ScaleSetFeedFactory? = nil, supervision: AllocationSupervision? = nil,
    trace: ProtocolTrace? = nil
  ) {
    self.board = board
    self.external = external
    self.feeds = feeds
    self.supervision = supervision
    self.trace = trace
    self.api = api
    self.credentials = credentials
    self.store = store
    self.provider = provider
    self.loadConfiguration = loadConfiguration
    self.clients = clients
  }

  /// Production wiring: the App key in the protected credential store, the
  /// GitHub REST API over URLSession.
  package static func installationClients(
    store: ControllerStore, credentials: any CredentialStore
  ) -> @Sendable (InstallationRecord) throws(CIError) -> GitHubInstallationClient {
    let api = GitHubAPI(http: URLSessionGitHubHTTP())
    let auths = Mutex<[Int64: GitHubAppAuth]>([:])
    return { (installation) throws(CIError) -> GitHubInstallationClient in
      guard let app = try store.app(installation.appID) else {
        throw CIError(.unauthorized, "GitHub App \(installation.appID) is not connected")
      }
      let auth = auths.withLock { cache -> GitHubAppAuth in
        if let existing = cache[app.appID] { return existing }
        let created = GitHubAppAuth(app: app, credentials: credentials, api: api)
        cache[app.appID] = created
        return created
      }
      return GitHubInstallationClient(
        api: api, auth: auth, installationID: installation.installationID)
    }
  }

  // MARK: Reconciliation

  package func reconcile(now: EpochSeconds) {
    trace?.advance()
    adoptSupervisors()
    // Owned VMs and registrations are offboarded even when the current
    // configuration is invalid or no longer names the pool: the last valid
    // configuration still describes how to reach and release them.
    let loaded = loadConfiguration()
    let lastGood = try? store.meta(Self.lastConfigurationKey).flatMap {
      try? ControllerStore.decode(CIConfiguration.self, $0)
    }
    var effective: CIConfiguration
    var current: CIConfiguration?
    switch loaded {
    case .success(let configuration):
      current = configuration
      effective = configuration
      try? store.setMeta(Self.lastConfigurationKey, try? ControllerStore.encode(configuration))
    case .failure(let error):
      for pool in (try? store.poolStatuses()) ?? [] where Self.isAutomatic(pool.state) {
        try? PoolControl.set(
          pool.name, .inactive, reason: "configuration invalid: \(error.message)", store: store)
      }
      guard let lastGood else { return }
      effective = lastGood
    }
    guard let controller = try? store.controllerID() else { return }
    var prepared: [(Name, ConnectedPoolReconciler, ConnectedPoolReconciler.PreparedPass)] = []
    for status in (try? store.poolStatuses()) ?? [] where status.state != .removed {
      guard current != nil, current?.pools[status.name] == nil else { continue }
      guard let previous = lastGood?.pools[status.name],
        let profile = lastGood?.profiles[previous.profile]
      else {
        try? PoolControl.set(
          status.name, .inactive,
          reason:
            "no longer configured and no earlier configuration to offboard it with; restore it, then `iso-ci pool remove`",
          store: store)
        continue
      }
      effective.pools[status.name] = previous
      effective.profiles[previous.profile] = profile
      for (kind, name, _) in lastGood?.descriptors(of: previous.profile) ?? [] {
        switch kind {
        case .image: effective.images[name] = effective.images[name] ?? lastGood?.images[name]
        case .networkPolicy:
          effective.networkPolicies[name] =
            effective.networkPolicies[name] ?? lastGood?.networkPolicies[name]
        case .compatibility:
          effective.compatibility[name] =
            effective.compatibility[name] ?? lastGood?.compatibility[name]
        case .limits: effective.limits[name] = effective.limits[name] ?? lastGood?.limits[name]
        case .profile, .host: break
        }
      }
      for host in previous.hosts where effective.hosts[host] == nil {
        effective.hosts[host] = lastGood?.hosts[host]
      }
      if status.state != .removing {
        try? PoolControl.set(status.name, .removing, reason: "no longer configured", store: store)
      }
    }
    for (poolName, pool) in effective.pools.sorted(by: { $0.key < $1.key }) {
      let status = try? store.poolStatus(poolName)
      if status?.state == .removed {
        finishCredentialRemoval(poolName)
        continue
      }
      var gate: String?
      if let current, current.pools[poolName] != nil {
        gate = activationGate(poolName, pool, configuration: current, now: now)
        if let status, Self.isAutomatic(status.state) || status.state == .inactive {
          // A scale set's demand source is GitHub's queue, so min_runners 0
          // is scale-to-zero, not a pause.
          let paused = pool.desiredIdleVMs == 0 && pool.scaleSet == nil
          let target: PoolState = gate == nil ? (paused ? .paused : .active) : .inactive
          let reason = gate ?? (paused ? "desired_idle_vms is 0 (no demand source)" : nil)
          if status.state != target || status.reason != reason {
            try? PoolControl.set(poolName, target, reason: reason, store: store)
          }
        } else if status == nil {
          try? PoolControl.set(
            poolName, gate == nil ? .active : .inactive, reason: gate, store: store)
        }
      }
      resumeSessions(pool: poolName)
      // Without GitHub access the reconciler still observes, stops and
      // releases owned VMs; registrations wait for access to return.
      let runners: any RunnerService
      if let installation = try? store.installation(pool.installation) {
        do { runners = InstallationRunnerService(client: try clients(installation)) } catch {
          runners = OfflineRunnerService(reason: error.message)
        }
      } else {
        runners = OfflineRunnerService(reason: "installation \(pool.installation) is not connected")
      }
      let feed = scaleSetFeed(
        poolName, pool,
        wanted: gate == nil && current?.pools[poolName] != nil
          && (try? store.poolStatus(poolName))?.state == .active)
      let reconciler = ConnectedPoolReconciler(
        pool: poolName, store: store, configuration: effective, provider: provider,
        runners: feed.map { ScaleSetRunnerService(base: runners, feed: $0) } ?? runners,
        controller: controller, gate: gate, scaleSetDemand: feed?.demand(),
        launcher: supervision?.launcher,
        supervisors: supervision?.directory ?? InlineSupervision(), trace: trace)
      let since = state.withLock { $0.demandSince[poolName] } ?? now
      let pass = reconciler.prepare(since: since)
      state.withLock {
        if pass.requests.isEmpty {
          $0.demandSince[poolName] = nil
        } else if $0.demandSince[poolName] == nil {
          $0.demandSince[poolName] = now
        }
      }
      prepared.append((poolName, reconciler, pass))
    }
    stopFeeds(except: Set(effective.pools.keys))
    let decision = schedule(prepared.flatMap { $0.2.requests }, configuration: effective, now: now)
    for (poolName, reconciler, var pass) in prepared {
      let mine = Set(pass.requests.map(\.id))
      let grants = decision.placements.filter { mine.contains($0.request) }.map(\.host)
      reconciler.admit(&pass, grants: grants, retire: decision.retire)
      let report = reconciler.finish(&pass)
      state.withLock { $0.reports[poolName] = report }
      if (try? store.poolStatus(poolName))?.state == .removed { finishCredentialRemoval(poolName) }
    }
  }

  // MARK: Scheduling

  /// One queue across every pool: the requests of all pools are ordered by
  /// age and placed with room reservation, exclusive drains and the
  /// macOS VM ceiling; the outcome is published for preflight placement.
  private func schedule(
    _ requests: [ScheduleRequest], configuration: CIConfiguration, now: EpochSeconds
  )
    -> CapacityDecision
  {
    let (hosts, external) = Self.schedulerHosts(
      configuration: configuration, store: store, external: self.external, now: now)
    let previous = state.withLock { $0.modes }
    let decision = Scheduler.schedule(requests: requests, hosts: hosts, previous: previous)
    state.withLock { $0.modes = decision.modes }
    var snapshot = SchedulerBoard.Snapshot()
    snapshot.modes = decision.modes
    snapshot.reservations = decision.reservations
    snapshot.external = external
    snapshot.waiting = decision.waiting
    snapshot.queue = requests.sorted(by: ScheduleRequest.precedes)
    board.publish(snapshot)
    for (host, mode) in decision.modes where mode != (previous[host] ?? .normal) {
      _ = try? store.event("host:\(host)", "host.mode", mode.label)
    }
    Self.record(decision, requests: requests, trace: trace)
    return decision
  }

  package static func record(
    _ decision: CapacityDecision, requests: [ScheduleRequest], trace: ProtocolTrace?
  ) {
    guard let trace, !requests.isEmpty || !decision.retire.isEmpty else { return }
    trace.record(
      "schedule",
      fields: [
        "placements": .array(
          decision.placements.map {
            ["job_id": .string($0.request), "host": .string($0.host.rawValue)]
          }),
        "waiting": .object(decision.waiting.mapValues { .string($0.code) }),
        "retire": .array(decision.retire.map { .string($0.rawValue) }),
        "modes": .object(
          Dictionary(
            uniqueKeysWithValues: decision.modes.map { ($0.key.rawValue, .string($0.value.label)) })
        ),
      ])
  }

  /// What the scheduler sees of every host a pool or preflight may use:
  /// eligibility, effective capacity (owner reservation and external use
  /// subtracted) and the CI allocations holding resources there.
  package static func schedulerHosts(
    configuration: CIConfiguration, store: ControllerStore, external probe: any ExternalUsageProbe,
    now: EpochSeconds
  ) -> (hosts: [SchedulerHost], external: [Name: ExternalUsage]) {
    var names = Set(configuration.pools.values.flatMap(\.hosts))
    names.formUnion(configuration.preflight?.hosts ?? [])
    var hosts: [SchedulerHost] = []
    var external: [Name: ExternalUsage] = [:]
    for name in names.sorted() {
      guard let budget = configuration.hosts[name] else { continue }
      let open = ((try? store.openAllocations(host: name)) ?? []).filter(\.holdsResources)
      let usage = probe.usage(
        host: name, budget: budget, own: Set(open.compactMap { $0.instance?.runtimeID }))
      external[name] = usage
      var ineligible: String?
      var slots: UInt64 = 0
      switch (try? HostPlacement.eligibility(name, store: store, now: now))
        ?? .refused(PlacementRefusal(host: name, reason: "host record unreadable"))
      {
      case .eligible(let snapshot): slots = snapshot.retentionSlots
      case .refused(let refusal): ineligible = refusal.reason
      }
      hosts.append(
        SchedulerHost(
          name: name, capacity: HostCapacity(budget: budget, external: usage), slots: slots,
          allocations: open.map { scheduled($0, configuration) }, ineligible: ineligible))
    }
    return (hosts, external)
  }

  static func scheduled(_ allocation: AllocationRecord, _ configuration: CIConfiguration)
    -> ScheduledAllocation
  {
    let profileName =
      allocation.pool.flatMap { configuration.pools[$0]?.profile }
      ?? (allocation.kind == .preflight ? configuration.preflight?.profile : nil)
    let profile = profileName.flatMap { configuration.profiles[$0] }
    let guest: GuestOS =
      allocation.instance.map { $0.guestOS == GuestOS.macos.rawValue ? .macos : .linux }
      ?? profile?.guestOS ?? .linux
    let idle =
      allocation.kind == .connected && allocation.desired == .active && allocation.job == nil
      && allocation.readyAt != nil && allocation.execution == .pending
      && allocation.runnerExitStatus == nil && allocation.registration == .registered
    return ScheduledAllocation(
      id: allocation.id, reservation: allocation.reservation,
      exclusive: profile?.isExclusive ?? false, guestOS: guest, idle: idle)
  }

  // MARK: Scale sets

  /// The pool's running listener when it should have one; starts or stops
  /// it as the pool's activation changes.
  private func scaleSetFeed(_ name: Name, _ pool: PoolConfiguration, wanted: Bool)
    -> (any ScaleSetFeed)?
  {
    guard pool.scaleSet != nil, let feeds else { return nil }
    if !wanted {
      state.withLock { $0.feeds.removeValue(forKey: name) }?.stop()
      return nil
    }
    let digest = descriptorDigest(pool)
    let (existing, stale) = state.withLock { state -> ((any ScaleSetFeed)?, (any ScaleSetFeed)?) in
      guard let feed = state.feeds[name] else { return (nil, nil) }
      if state.feedDigests[name] == digest { return (feed, nil) }
      state.feeds[name] = nil
      state.feedDigests[name] = nil
      return (nil, feed)
    }
    stale?.stop()
    if let existing { return existing }
    guard let installation = try? store.installation(pool.installation) else { return nil }
    do {
      let feed = try feeds(name, pool, installation)
      state.withLock {
        $0.feeds[name] = feed
        $0.feedDigests[name] = digest
      }
      return feed
    } catch {
      _ = try? store.event(
        "pool:\(name)", "scaleset.error", "listener not started: \(error.message)",
        data: ["code": error.code.rawValue])
      return nil
    }
  }

  private func stopFeeds(except pools: Set<Name>) {
    let stale = state.withLock { state -> [any ScaleSetFeed] in
      let names = state.feeds.keys.filter { !pools.contains($0) }
      return names.compactMap { state.feeds.removeValue(forKey: $0) }
    }
    for feed in stale { feed.stop() }
  }

  package func stopListeners() { stopFeeds(except: []) }

  package func shutdown() { stopListeners() }

  // MARK: Supervisors

  /// Re-adopts live supervisors once, then each pass clears the files of
  /// supervisors that have exited. A supervisor that died while it owned
  /// startup hands the allocation back to the normal lifecycle, which
  /// resolves any lost JIT reply by name.
  private func adoptSupervisors() {
    guard let supervision else { return }
    let first = state.withLock { state -> Bool in
      defer { state.adopted = true }
      return !state.adopted
    }
    let adoption = supervision.adopt()
    if first {
      for (id, state) in adoption.live.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
        _ = try? store.event(
          "allocation:\(id)", "supervisor.readopted",
          "live supervisor re-adopted (\(state?.phase.rawValue ?? "unknown phase"))")
        trace?.record(
          "supervisor_readopted",
          fields: [
            "allocation": .string(id.rawValue),
            "phase": .string(state?.phase.rawValue ?? "unknown"),
          ])
      }
    }
    for (id, state) in adoption.ended.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
      let phase = state?.phase ?? .failed
      guard phase.ownsStartup || phase == .failed else { continue }
      _ = try? store.event(
        "allocation:\(id)", "supervisor.lost",
        "supervisor ended during \(phase.rawValue); the controller takes over")
      // Nothing proven ready is ever bootstrapped by guesswork: an
      // allocation that never became ready is released (its persisted
      // create intent resolves any VM a lost reply left behind). A ready
      // one continues in the normal lifecycle, which resolves a lost JIT
      // reply by name.
      _ = try? store.update(id) {
        guard $0.readyAt == nil, $0.desired == .active else { return }
        $0.desired = .release
        if $0.execution == .pending { $0.execution = .cancelled }
        $0.note("supervisor ended before the VM was ready")
      }
    }
  }

  static let lastConfigurationKey = "connected.last_configuration"
  static func credentialRemovalKey(_ pool: Name) -> String {
    "connected.remove_credentials." + pool.rawValue
  }

  /// Credential removal requested with `pool remove` runs only after the
  /// pool's owned registrations and VMs are offboarded.
  private func finishCredentialRemoval(_ pool: Name) {
    guard (try? store.meta(Self.credentialRemovalKey(pool))) != nil else { return }
    do {
      _ = try removePoolCredentials(pool)
      try store.setMeta(Self.credentialRemovalKey(pool), nil)
    } catch {
      _ = try? store.event(
        "pool:\(pool)", "pool.credentials_pending", "credential removal pending: \(error.message)")
    }
  }

  /// Operator-chosen states (paused, draining, removing) are never
  /// overridden by automatic activation.
  private static func isAutomatic(_ state: PoolState) -> Bool { state == .active }

  private func activationGate(
    _ name: Name, _ pool: PoolConfiguration, configuration: CIConfiguration, now: EpochSeconds
  ) -> String? {
    for (kind, descriptor, digest) in configuration.descriptors(of: pool.profile)
      + configuration.hostDescriptors(pool.hosts)
    {
      guard let approval = try? store.approval(kind, descriptor), approval.digest == digest else {
        return
          "\(kind.rawValue) \(descriptor) is not approved at its current digest (run `iso-ci setup --approve`)"
      }
    }
    guard let installation = try? store.installation(pool.installation) else {
      return "installation \(pool.installation) is not connected (run `iso-ci setup`)"
    }
    let key = Self.activationKey(name, configuration)
    if let cached = state.withLock({ $0.activation[name] }), cached.key == key,
      now < cached.at + Self.activationInterval
    {
      return cached.report.state == .active ? nil : cached.report.reasons.joined(separator: "; ")
    }
    let report: PoolActivationReport
    do {
      let client = try clients(installation)
      report = PoolActivation.evaluate(
        pool: name, configuration: configuration, installation: installation,
        reader: APIAuthorityReader(client: client))
    } catch {
      return "GitHub authority could not be evaluated: \(error.message)"
    }
    state.withLock { $0.activation[name] = (now, key, report) }
    return report.state == .active ? nil : report.reasons.joined(separator: "; ")
  }

  /// What a cached activation depends on locally: the pool's own
  /// descriptors and every pool's scope and labels (routing exclusivity). A
  /// configuration edit that changes either is evaluated on the next pass,
  /// not after the cache interval.
  static func activationKey(_ name: Name, _ configuration: CIConfiguration) -> String {
    let routing = configuration.pools.sorted { $0.key < $1.key }.map { entry in
      let labels = entry.value.labels.map(\.normalized).sorted().joined(separator: ",")
      return "\(entry.key)|\(GitHubRunnerScope(entry.value.scope))|\(labels)"
    }
    return ([configuration.poolDigest(name)?.rawValue ?? "-"] + routing).joined(separator: "\n")
  }

  /// After a controller restart, live allocations get their controller-held
  /// session back so the host does not stop them for lack of a lease.
  private func resumeSessions(pool: Name) {
    for allocation in (try? store.openAllocations(pool: pool)) ?? []
    where allocation.readyAt != nil && allocation.observedRunPhase == .running
      && allocation.desired != .retainLive && allocation.vmCleanup != .verified
      && supervision?.directory.status(allocation.id).isLive != true
    {
      let first = state.withLock { $0.resumedSessions.insert(allocation.id).inserted }
      guard first else { continue }
      do { try provider.holdSession(allocation.id, forwards: []) } catch {
        state.withLock { _ = $0.resumedSessions.remove(allocation.id) }
      }
    }
  }

  // MARK: Control

  package func handle(_ request: ControlRequest) -> Result<JSONValue, CIError>? {
    guard owns(request.method) || request.method == "abort" else { return nil }
    do throws(CIError) {
      switch request.method {
      case "pool.pause", "pool.drain", "pool.resume", "pool.remove":
        var r = try ObjectReader(request.params, field: "params")
        let pool = try r.parsed("pool", as: Name.self)
        let abort = try r.optionalBool("abort") ?? false
        let removeCredentials = try r.optionalBool("remove_credentials") ?? false
        try r.finish()
        let configured = (try? loadConfiguration().get())?.pools[pool] != nil
        let recorded = try store.poolStatus(pool) != nil
        guard configured || recorded else {
          throw CIError(.notFound, "unknown pool \(pool)")
        }
        switch request.method {
        case "pool.pause": try PoolControl.pause(pool, store: store)
        case "pool.drain":
          try PoolControl.drain(pool, store: store)
          if abort {
            for allocation in try store.openAllocations(pool: pool) {
              try PoolControl.abort(allocation.id, store: store)
            }
          }
        case "pool.resume":
          try PoolControl.set(pool, .active, reason: nil, store: store)
          state.withLock { _ = $0.activation.removeValue(forKey: pool) }
        default:
          try PoolControl.remove(pool, store: store)
          if removeCredentials {
            // Deferred until offboarding completes, so GitHub access remains
            // available to delete this pool's exact registrations first.
            try store.setMeta(Self.credentialRemovalKey(pool), "requested")
          }
        }
        let open = try store.openAllocations(pool: pool)
        return .success([
          "pool": .string(pool.rawValue),
          "state": .string((try store.poolStatus(pool))?.state.rawValue ?? "unknown"),
          "open_allocations": .integer(Int64(open.count)),
          "pending_cleanup": .array(open.filter { !$0.isSettled }.map { .string($0.id.rawValue) }),
        ])
      case "abort":
        var r = try ObjectReader(request.params, field: "params")
        let target = try r.string("target")
        try r.finish()
        guard let id = try? AllocationID(target), let allocation = try store.allocation(id),
          allocation.kind == .connected
        else { return nil }
        try PoolControl.abort(id, store: store)
        return .success(["allocation": .string(id.rawValue), "desired": "stop"])
      case "registration.resolve":
        var r = try ObjectReader(request.params, field: "params")
        let id = try r.parsed("allocation", as: AllocationID.self)
        let runner = try r.optionalInt("runner_id")
        try r.finish()
        guard let allocation = try store.allocation(id), let pool = allocation.pool,
          case .success(let configuration) = loadConfiguration(),
          let poolConfig = configuration.pools[pool],
          let installation = try store.installation(poolConfig.installation)
        else { throw CIError(.notFound, "unknown connected allocation") }
        let reconciler = ConnectedPoolReconciler(
          pool: pool, store: store, configuration: configuration, provider: provider,
          runners: InstallationRunnerService(client: try clients(installation)),
          controller: try store.controllerID())
        try reconciler.superviseRegistration(id, runnerID: runner)
        return .success(["allocation": .string(id.rawValue), "resolved": true])
      case "smoke.verify":
        var r = try ObjectReader(request.params, field: "params")
        let first = try r.parsed("first", as: AllocationID.self)
        let second = try r.parsed("second", as: AllocationID.self)
        try r.finish()
        guard let a = try store.allocation(first), let b = try store.allocation(second) else {
          throw CIError(.notFound, "unknown allocation")
        }
        try SmokeVerification.verify(.init(a), .init(b))
        return .success(["verified": true])
      case "github.app.complete":
        var r = try ObjectReader(request.params, field: "params")
        let code = try r.string("code")
        try r.finish()
        guard (1...200).contains(code.utf8.count), code.unicodeScalars.allSatisfy(isSafeNameScalar)
        else {
          throw CIError.invalid("invalid manifest code")
        }
        let app = try ManifestFlow.complete(
          code: code, api: api, credentials: credentials, store: store)
        return .success(appSummary(app))
      case "github.app.connect":
        var r = try ObjectReader(request.params, field: "params")
        let appID = try r.int("app_id")
        let pem = try r.string("private_key_pem")
        try r.finish()
        let app = try ManifestFlow.connectExistingApp(
          appID: appID, privateKeyPEM: RedactedSecret(pem), api: api, credentials: credentials,
          store: store)
        return .success(appSummary(app))
      case "github.installation.find":
        var r = try ObjectReader(request.params, field: "params")
        let appID = try r.int("app_id")
        let repository = try r.parsed("repository", as: RepositoryName.self)
        try r.finish()
        guard let app = try store.app(appID) else {
          throw CIError(.notFound, "GitHub App \(appID) is not connected")
        }
        let info = try ManifestFlow.findInstallation(
          repository: repository, app: app, api: api, credentials: credentials)
        return .success([
          "installation_id": .integer(info.id), "account": .string(info.account),
          "repository_selection": .string(info.repositorySelection),
        ])
      case "github.installation.verify":
        var r = try ObjectReader(request.params, field: "params")
        let name = try r.parsed("name", as: Name.self)
        let installationID = try r.int("installation_id")
        let appID = try r.int("app_id")
        let account = try r.optionalString("account")
        var scopes: Set<ManifestFlow.ScopeKind> = []
        for raw in try r.strings("scopes") {
          guard let kind = ManifestFlow.ScopeKind(rawValue: raw) else {
            throw CIError.invalid("scopes must be repository or organization")
          }
          scopes.insert(kind)
        }
        try r.finish()
        guard let app = try store.app(appID) else {
          throw CIError(.notFound, "GitHub App \(appID) is not connected")
        }
        let record = try ManifestFlow.verifyInstallation(
          name: name, installationID: installationID, app: app, api: api, credentials: credentials,
          store: store, expectedAccount: account, scopes: scopes)
        state.withLock { $0.activation.removeAll() }
        return .success(jsonValue(record))
      case "inspect.pools":
        var r = try ObjectReader(request.params, field: "params")
        let target = try r.string("target")
        try r.finish()
        guard let pool = try? Name(target), let status = try store.poolStatus(pool) else {
          throw CIError(.notFound, "unknown pool")
        }
        return .success(["pool": jsonValue(status), "status": poolStatus(pool, status)])
      default:
        return nil
      }
    } catch {
      return .failure(error)
    }
  }

  /// The service answers only its own methods.
  package func owns(_ method: String) -> Bool {
    [
      "pool.pause", "pool.drain", "pool.resume", "pool.remove", "registration.resolve",
      "smoke.verify", "inspect.pools", "github.app.complete", "github.app.connect",
      "github.installation.find", "github.installation.verify",
    ].contains(method)
  }

  private func appSummary(_ app: GitHubAppRecord) -> JSONValue {
    [
      "app_id": .integer(app.appID), "slug": .string(app.slug), "owner": .string(app.owner),
      "install_url": .string(ManifestFlow.installURL(slug: app.slug)),
    ]
  }

  private func removePoolCredentials(_ pool: Name) throws(CIError) -> JSONValue {
    let current = try? loadConfiguration().get()
    let lastGood = try? store.meta(Self.lastConfigurationKey).flatMap {
      try? ControllerStore.decode(CIConfiguration.self, $0)
    }
    guard let poolConfig = current?.pools[pool] ?? lastGood?.pools[pool] else {
      throw CIError(.notFound, "pool \(pool) has no recorded configuration")
    }
    let others =
      (current ?? lastGood)?.pools.filter {
        $0.key != pool && $0.value.installation == poolConfig.installation
      } ?? [:]
    guard others.isEmpty else {
      throw CIError(
        .conflict, "installation \(poolConfig.installation) is still used by other pools")
    }
    guard let installation = try store.installation(poolConfig.installation) else {
      return ["pool": .string(pool.rawValue), "credentials_removed": false]
    }
    let stillUsed = try store.installations().contains {
      $0.name != installation.name && $0.appID == installation.appID
    }
    // Keychain first: a locked keychain leaves everything in place and is
    // reported, rather than dropping the record and orphaning the key.
    var removedKey = false
    if !stillUsed, let app = try store.app(installation.appID) {
      try ManifestFlow.removeCredentials(app: app, credentials: credentials)
      try store.removeApp(app.appID)
      removedKey = true
    }
    try store.removeInstallation(installation.name)
    try store.event("pool:\(pool)", "pool.credentials_removed", "CI-only credentials removed")
    // The GitHub App and its installation are not deleted on GitHub: they
    // may be operator-owned. Uninstalling them is a separate operator step.
    return [
      "pool": .string(pool.rawValue), "credentials_removed": true,
      "app_key_removed": .bool(removedKey),
      "note":
        "the GitHub App and installation still exist on GitHub; remove them there if no longer needed",
    ]
  }

  private func poolStatus(_ name: Name, _ status: PoolStatusRecord) -> JSONValue {
    let report = state.withLock { $0.reports[name] }
    let activation = state.withLock { $0.activation[name] }
    return [
      "state": .string(status.state.rawValue),
      "reason": status.reason.map(JSONValue.string) ?? .null,
      "live": .integer(Int64(report?.live ?? 0)), "idle": .integer(Int64(report?.idle ?? 0)),
      "deficit": .integer(Int64(report?.deficit ?? 0)),
      "admission_paused": report?.admissionPaused.map(JSONValue.string) ?? .null,
      "errors": .array((report?.errors ?? []).prefix(5).map { .string($0) }),
      "guarantees": .array(
        (activation?.report.guarantees ?? []).map {
          [
            "name": .string($0.name), "status": .string($0.status.rawValue),
            "detail": .string($0.detail),
          ]
        }),
    ]
  }

  package func status() -> JSONValue {
    var out: [String: JSONValue] = [:]
    for status in (try? store.poolStatuses()) ?? [] {
      out[status.name.rawValue] = poolStatus(status.name, status)
    }
    return .object(out)
  }
}
