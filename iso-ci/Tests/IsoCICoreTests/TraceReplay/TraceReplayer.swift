import Foundation
import Synchronization
import Testing

@testable import IsoCICore

/// External use the trace sets with `lease_acquired` / `lease_released`.
final class TraceExternalUsage: ExternalUsageProbe {
  let leases = Mutex<[String: VMLease]>([:])

  func usage(host: Name, budget: HostBudget?, own: Set<String>) -> ExternalUsage {
    guard host.rawValue == HostCapacity.localHost else { return .none }
    return HostCapacity.usage(of: Array(leases.withLock { $0.values }), excluding: own)
  }
}

/// Supervisor processes as the controller sees them: launched allocations
/// stay owned by their (simulated) supervisor across controller restarts
/// until the trace lets it finish startup and, later, exit.
final class TraceSupervision: AllocationLauncher, SupervisorDirectory {
  let phases = Mutex<[AllocationID: SupervisionPhase]>([:])

  func launch(_ allocation: AllocationID, pool: Name, poolDigest: Digest) throws(CIError) {
    phases.withLock { $0[allocation] = .registering }
  }

  func status(_ allocation: AllocationID) -> SupervisorStatus {
    guard let phase = phases.withLock({ $0[allocation] }) else { return .unsupervised }
    return .live(
      SupervisorState(
        allocation: allocation, pool: "trace", poolDigest: Digest(hashing: "trace"), phase: phase,
        updatedAt: 0))
  }
}

/// A scale-set pool's feed: the real listener (policy gate, acquisition,
/// assignment tracking) over the scripted Actions service; runner
/// registration goes to the fake REST runners so the reconciler can verify it.
final class TraceFeed: ScaleSetFeed {
  let listener: ScaleSetListener
  let service: FakeActionsService
  let authority: FakeScaleSetAuthority
  let runners: GitHubFakeRunners

  init(
    listener: ScaleSetListener, service: FakeActionsService, authority: FakeScaleSetAuthority,
    runners: GitHubFakeRunners
  ) {
    self.listener = listener
    self.service = service
    self.authority = authority
    self.runners = runners
  }

  func demand() -> ScaleSetDemand { listener.demand() }

  func generateJIT(name: String, workFolder: String) throws(CIError) -> GitHubJITConfig {
    try runners.generateJIT(
      scope: .repository(try RepositoryName("chr33s/iso")), name: name, runnerGroupID: 1,
      labels: [], workFolder: workFolder)
  }

  func stop() {}

  /// Returns the request ids acquired.
  @discardableResult
  func drain() -> [Int64] {
    while listener.step(), service.state.withLock({ !$0.queue.isEmpty }) {}
    let acquired = service.state.withLock { state -> [Int64] in
      defer { state.acquired = [] }
      return state.acquired.flatMap { $0 }
    }
    guard !acquired.isEmpty else { return [] }
    service.enqueue(acquired.map { FakeActionsService.job("JobAssigned", request: $0) })
    while listener.step(), service.state.withLock({ !$0.queue.isEmpty }) {}
    return acquired
  }
}

/// Replays a JSONL protocol trace against the real scheduler, scale-set
/// listener, job policy and pool reconcilers, with a virtual clock, fake
/// hosts (`GitHubFakeProvider`) and fake GitHub runners. Lines sharing a
/// tick are applied together, then controller rounds run until the state
/// settles, then that tick's `expect` lines are checked.
final class TraceReplayer {
  static let repository = try! RepositoryName("chr33s/iso")

  let clock = TestClock()
  let store: ControllerStore
  let provider: GitHubFakeProvider
  let runners = GitHubFakeRunners()
  let external = TraceExternalUsage()
  let controller: ControllerID
  var configuration: CIConfiguration
  var supervision: TraceSupervision?
  var feeds: [Name: TraceFeed] = [:]
  var modes: [Name: HostMode] = [:]
  var demandSince: [Name: EpochSeconds] = [:]
  /// Trace job id ↔ scale-set runner request id.
  var requests: [String: (pool: Name, id: Int64)] = [:]
  var jobAllocations: [String: AllocationID] = [:]
  var placed: [String] = []
  var lastDecision = CapacityDecision()
  var nextRequest: Int64 = 1
  /// GitHub's side: jobs assigned to each scale set and not yet started.
  /// It survives controller restarts (the listener's view does not).
  var githubQueue: [Name: [Int64]] = [:]
  let trace: ProtocolTrace?

  init(trace: ProtocolTrace? = nil) throws {
    store = try ControllerStore.inMemory(clock: clock)
    provider = GitHubFakeProvider(store: store)
    controller = try store.controllerID()
    configuration = try TestConfig.configuration()
    self.trace = trace
  }

  struct Line {
    let tick: Int64
    let type: String
    let json: JSONValue
  }

  static func lines(_ text: String) throws -> [Line] {
    try text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .map { raw in
        let json = try StrictJSON.parse(Array(raw.utf8), limits: .github)
        return Line(
          tick: json["tick"]?.intValue ?? 0, type: json["type"]?.stringValue ?? "", json: json)
      }
  }

  func replay(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let lines = try Self.lines(text)
    for tick in Array(Set(lines.map(\.tick))).sorted() {
      let group = lines.filter { $0.tick == tick }
      placed = []
      for line in group where line.type != "expect" { try apply(line) }
      settle()
      for line in group where line.type == "expect" {
        check(line.json, tick: tick, sourceLocation: sourceLocation)
      }
      clock.advance(60)
    }
  }

  // MARK: Events

  func apply(_ line: Line) throws {
    let json = line.json
    switch line.type {
    case "config_loaded": try load(json)
    case "scaleset_message": try message(json)
    case "vm_exited": exited(json)
    case "lease_acquired":
      let sandbox = json["sandbox"]?.stringValue ?? "interactive"
      external.leases.withLock {
        $0[sandbox] = VMLease(
          sandbox: sandbox,
          guestOS: GuestOS(rawValue: json["guest_os"]?.stringValue ?? "linux") ?? .linux,
          cpus: UInt32(json["cpus"]?.intValue ?? 2),
          memoryMiB: UInt64(json["memory_mib"]?.intValue ?? 4_096))
      }
    case "lease_released":
      _ = external.leases.withLock { $0.removeValue(forKey: json["sandbox"]?.stringValue ?? "") }
    case "controller_restart":
      // In-memory controller state is lost; supervisors and the database
      // survive. Listeners open new sessions.
      modes = [:]
      demandSince = [:]
      for (name, _) in feeds { feeds[name] = try makeFeed(name) }
      trace?.record("controller_restart")
    case "supervisor_complete":
      guard let supervision else { return }
      for (id, phase) in supervision.phases.withLock({ $0 }) where phase.ownsStartup {
        guard let pool = try store.allocation(id)?.pool else { continue }
        _ = reconciler(pool).startAllocation(id, reporter: nil)
        let ready = try store.allocation(id)?.readyAt != nil
        supervision.phases.withLock { $0[id] = ready ? .holding : nil }
      }
    case "supervisor_exit":
      supervision?.phases.withLock { $0 = $0.filter { $0.value.ownsStartup } }
    default:
      Issue.record("unknown trace line type \(line.type)")
    }
  }

  func load(_ json: JSONValue) throws {
    var config = try TestConfig.configuration()
    config.pools = [:]
    let baseProfile = config.profiles["linux-validation"]!
    let baseLimits = config.limits["operator-approved-ci-limits"]!
    let basePool = try TestConfig.configuration().pools["validation"]!
    for (raw, host) in json["hosts"]?.objectValue ?? [:] {
      let name = try Name(raw)
      config.hosts[name] = HostBudget(
        maxVMs: UInt32(host["max_vms"]?.intValue ?? 4), cpus: UInt32(host["cpus"]?.intValue ?? 8),
        memoryMiB: UInt64(host["memory_mib"]?.intValue ?? 32_768), diskGiB: 4_096,
        ownerReservedCPUs: host["owner_reserved_cpus"]?.intValue.map { UInt32($0) },
        ownerReservedMemoryMiB: host["owner_reserved_memory_mib"]?.intValue.map { UInt64($0) })
      var record = HostRecord(alias: name, at: clock.now())
      record.capabilities = try ControllerStore.decode(
        HostCapabilitiesSnapshot.self,
        #"{"advertised":["net-handoff-1","run-retention-1"],"qualificationStatus":"qualified","qualificationTuple":{},"runPolicyDigests":{},"retentionSlots":0,"maxTTLSeconds":86400}"#
      )
      try store.save(record)
    }
    for (raw, spec) in json["pools"]?.objectValue ?? [:] {
      let name = try Name(raw)
      var limits = baseLimits
      limits.cpus = UInt32(spec["cpus"]?.intValue ?? 2)
      limits.memoryMiB = UInt64(spec["memory_mib"]?.intValue ?? 1_024)
      let limitsName = try Name("\(raw)-limits")
      config.limits[limitsName] = limits
      var profile = baseProfile
      profile.limits = limitsName
      profile.exclusiveHost = spec["exclusive"]?.boolValue == true ? true : nil
      if spec["guest_os"]?.stringValue == "macos" { profile.platform = "macos/arm64" }
      let profileName = try Name("\(raw)-profile")
      config.profiles[profileName] = profile
      var pool = basePool
      pool.profile = profileName
      pool.scope = .repository(Self.repository)
      pool.hosts = try (spec["hosts"]?.arrayValue ?? ["local"]).map {
        try Name($0.stringValue ?? "")
      }
      pool.labels = try ["self-hosted", "linux", "ARM64", raw].map { try RunnerLabel($0) }
      if spec["mode"]?.stringValue == "scaleset" {
        var policy = JobPolicy()
        if let p = spec["job_policy"] {
          policy.allowForkPRs = p["allow_fork_prs"]?.boolValue ?? false
          policy.allowPublicRepo = p["allow_public_repo"]?.boolValue ?? false
          if let events = p["allowed_events"]?.arrayValue {
            policy.allowedEvents = events.compactMap(\.stringValue)
          }
        }
        let maximum = UInt32(spec["max"]?.intValue ?? 4)
        let minimum = UInt32(spec["min"]?.intValue ?? 0)
        pool.scaleSet = ScaleSetConfiguration(
          name: raw, minRunners: minimum, maxRunners: maximum, jobPolicy: policy)
        pool.maxLiveVMs = maximum
        pool.desiredIdleVMs = minimum
      } else {
        pool.maxLiveVMs = UInt32(spec["max"]?.intValue ?? 2)
        pool.desiredIdleVMs = UInt32(spec["desired_idle"]?.intValue ?? 1)
      }
      config.pools[name] = pool
    }
    config.preflight = nil
    configuration = config
    if json["supervised"]?.boolValue == true { supervision = TraceSupervision() }
    for (name, pool) in config.pools {
      try PoolControl.set(name, .active, reason: nil, store: store)
      if pool.scaleSet != nil { feeds[name] = try makeFeed(name) }
    }
  }

  func makeFeed(_ name: Name) throws -> TraceFeed {
    let service = feeds[name]?.service ?? FakeActionsService()
    let authority = feeds[name]?.authority ?? FakeScaleSetAuthority()
    let listener = try ScaleSetListener(
      pool: name, configuration: configuration.pools[name]!, authority: authority,
      client: ScaleSetClient(http: service.http), store: store, owner: "iso-ci-trace",
      clock: clock, trace: trace)
    let feed = TraceFeed(
      listener: listener, service: service, authority: authority, runners: runners)
    feed.drain()
    return feed
  }

  func message(_ json: JSONValue) throws {
    let pool = try Name(json["pool"]?.stringValue ?? "")
    guard let feed = feeds[pool] else {
      Issue.record("no scale set pool \(pool)")
      return
    }
    let job = json["job_id"]?.stringValue ?? ""
    let request = requests[job]?.id ?? nextRequest
    if requests[job] == nil {
      requests[job] = (pool, request)
      nextRequest += 1
    }
    let run = 10_000 + request
    let event = json["event"]?.stringValue ?? "push"
    feed.authority.runs.withLock {
      $0[run] = JobFacts(
        repository: Self.repository.rawValue, repositoryID: 1,
        repositoryPrivate: json["private"]?.boolValue ?? true, event: event,
        actor: json["actor"]?.stringValue ?? "chr33s",
        headRepositoryID: json["is_fork"]?.boolValue == true ? 2 : 1)
    }
    let formatter = ISO8601DateFormatter()
    let queued = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(clock.now())))
    feed.service.enqueue([
      FakeActionsService.job(
        json["kind"]?.stringValue ?? "JobAvailable", request: request, run: run, event: event,
        queueTime: queued)
    ])
    githubQueue[pool, default: []] += feed.drain()
  }

  func exited(_ json: JSONValue) {
    let job = json["job_id"]?.stringValue ?? ""
    guard let id = jobAllocations[job], let request = requests[job] else {
      Issue.record("job \(job) never ran")
      return
    }
    let code = json["exit_code"]?.intValue ?? 0
    provider.state.withLock { $0.runnerStatus[id] = "exited \(code)" }
    runners.complete(jobID: 1_000 + request.id, conclusion: code == 0 ? "success" : "failure")
    feeds[request.pool]?.service.enqueue([
      FakeActionsService.job("JobCompleted", request: request.id)
    ])
    feeds[request.pool]?.drain()
  }

  // MARK: Controller rounds

  func reconciler(_ pool: Name) -> ConnectedPoolReconciler {
    let feed = feeds[pool]
    return ConnectedPoolReconciler(
      pool: pool, store: store, configuration: configuration, provider: provider,
      runners: feed.map { ScaleSetRunnerService(base: runners, feed: $0) } ?? runners,
      controller: controller, clock: clock, scaleSetDemand: feed?.demand(),
      launcher: supervision, supervisors: supervision ?? InlineSupervision(), trace: trace)
  }

  func round() {
    var prepared: [(Name, ConnectedPoolReconciler, ConnectedPoolReconciler.PreparedPass)] = []
    for name in configuration.pools.keys.sorted() {
      let reconciler = reconciler(name)
      let pass = reconciler.prepare(since: demandSince[name] ?? clock.now())
      if pass.requests.isEmpty {
        demandSince[name] = nil
      } else if demandSince[name] == nil {
        demandSince[name] = clock.now()
      }
      prepared.append((name, reconciler, pass))
    }
    let hosts = ConnectedPoolService.schedulerHosts(
      configuration: configuration, store: store, external: external, now: clock.now()
    ).hosts
    let decision = Scheduler.schedule(
      requests: prepared.flatMap { $0.2.requests }, hosts: hosts, previous: modes)
    modes = decision.modes
    lastDecision = decision
    ConnectedPoolService.record(
      decision, requests: prepared.flatMap { $0.2.requests }, trace: trace)
    placed += decision.placements.map { Self.job($0.request, requests) }
    for (_, reconciler, var pass) in prepared {
      let mine = Set(pass.requests.map(\.id))
      reconciler.admit(
        &pass, grants: decision.placements.filter { mine.contains($0.request) }.map(\.host),
        retire: decision.retire)
      _ = reconciler.finish(&pass)
    }
    markGuests()
    assignJobs()
  }

  /// Rounds until nothing changes (bounded), advancing the clock between.
  func settle() {
    var last = ""
    for _ in 0..<8 {
      round()
      let now = fingerprint()
      if now == last { return }
      last = now
      clock.advance(10)
    }
  }

  func fingerprint() -> String {
    let open = ((try? store.openAllocations()) ?? []).map {
      "\($0.id.rawValue):\($0.phase):\($0.registration.rawValue)"
    }.sorted()
    let pending = feeds.values.map { $0.demand().pending.count }.reduce(0, +)
    return open.joined(separator: ",") + "|\(pending)|\(lastDecision.waiting.count)"
  }

  func markGuests() {
    for allocation in (try? store.openAllocations()) ?? [] {
      guard let pool = allocation.pool, let instance = allocation.instance,
        configuration.profiles[configuration.pools[pool]?.profile ?? "x"]?.guestOS == .macos,
        instance.guestOS != "macos"
      else { continue }
      _ = try? store.update(allocation.id) {
        $0.instance = QualifiedInstance(
          hostID: instance.hostID, ownerID: instance.ownerID, instanceID: instance.instanceID,
          runtimeID: instance.runtimeID, guestOS: "macos")
      }
    }
  }

  /// GitHub gives each assigned job to an idle registered runner of its
  /// scale set, oldest job first.
  func assignJobs() {
    for (pool, feed) in feeds.sorted(by: { $0.key < $1.key }) {
      while let request = githubQueue[pool]?.first {
        let idle = ((try? store.openAllocations(pool: pool)) ?? []).first { allocation in
          allocation.readyAt != nil && allocation.job == nil
            && allocation.registration == .registered && allocation.runnerName != nil
            && !jobAllocations.values.contains(allocation.id)
        }
        guard let idle, let name = idle.runnerName,
          let job = requests.first(where: { $0.value.pool == pool && $0.value.id == request })?.key
        else { break }
        githubQueue[pool]?.removeFirst()
        runners.assign(jobID: 1_000 + request, toRunnerNamed: name, repository: Self.repository)
        jobAllocations[job] = idle.id
        feed.service.enqueue([FakeActionsService.job("JobStarted", request: request)])
        feed.drain()
      }
    }
  }

  static func job(_ request: String, _ requests: [String: (pool: Name, id: Int64)]) -> String {
    let parts = request.split(separator: ":")
    guard parts.count == 3, parts[0] == "job", parts[2].hasPrefix("r"),
      let id = Int64(parts[2].dropFirst())
    else { return request }
    return requests.first { $0.value.pool.rawValue == parts[1] && $0.value.id == id }?.key
      ?? request
  }

  // MARK: Expectations

  func check(_ json: JSONValue, tick: Int64, sourceLocation: SourceLocation) {
    let open = ((try? store.openAllocations()) ?? []).filter(\.holdsResources)
    func expect(_ ok: Bool, _ what: String) {
      if !ok { Issue.record("tick \(tick): \(what)", sourceLocation: sourceLocation) }
    }
    if let vms = json["vms"]?.intValue {
      expect(open.count == vms, "vms \(open.count) != \(vms)")
    }
    if let expected = json["placed"]?.arrayValue?.compactMap(\.stringValue) {
      expect(placed == expected, "placed \(placed) != \(expected)")
    }
    for (job, code) in json["waiting"]?.objectValue ?? [:] {
      let waiting = lastDecision.waiting.first { Self.job($0.key, requests) == job }?.value.code
      expect(
        waiting == code.stringValue,
        "\(job) waiting \(waiting ?? "nil") != \(code.stringValue ?? "")")
    }
    for (host, mode) in json["modes"]?.objectValue ?? [:] {
      let actual = (lastDecision.modes[(try? Name(host)) ?? "x"] ?? .normal).label
      expect(actual == mode.stringValue, "\(host) mode \(actual) != \(mode.stringValue ?? "")")
    }
    let events = (try? store.events(after: 0, limit: 10_000)) ?? []
    if let rejected = json["rejected"]?.objectValue {
      for (job, code) in rejected {
        let request = requests[job].map { String($0.id) }
        let found = events.contains {
          $0.kind == "job.rejected" && $0.data["request_id"] == request
            && $0.data["code"] == code.stringValue
        }
        expect(found, "\(job) not rejected with \(code.stringValue ?? "")")
      }
    }
    let counts: [(String, Int)] = [
      ("admits", provider.calls("admit").count), ("releases", provider.calls("release").count),
      ("jit", runners.state.withLock { $0.jitCalls.count }),
      ("retired", events.filter { $0.kind == "allocation.retired" }.count),
      ("uncertain", open.filter { $0.registration == .uncertain || $0.uncertainty != nil }.count),
      ("supervised", open.filter { supervision?.status($0.id).ownsStartup == true }.count),
      ("ready", open.filter { $0.readyAt != nil }.count),
    ]
    for (key, actual) in counts {
      if let wanted = json[key]?.intValue {
        expect(actual == wanted, "\(key) \(actual) != \(wanted)")
      }
    }
  }
}
