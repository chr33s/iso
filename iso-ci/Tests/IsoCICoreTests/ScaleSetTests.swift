import Foundation
import Synchronization
import Testing

@testable import IsoCICore

/// A fake GitHub side for one scale-set pool: runs whose facts the policy
/// reads, and a fixed Actions service connection.
final class FakeScaleSetAuthority: ScaleSetAuthority {
  let runs = Mutex<[Int64: JobFacts]>([:])
  let connects = Mutex(0)

  func connect(_ scope: GitHubRunnerScope, now: EpochSeconds) throws(CIError)
    -> ActionsServiceConnection
  {
    connects.withLock { $0 += 1 }
    return ActionsServiceConnection(
      url: URL(string: "https://pipelines.actions.githubusercontent.com/abc")!,
      token: RedactedSecret("ADMIN-TOKEN"), expiresAt: now + 3_600)
  }

  func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64 { 1 }

  func runFacts(_ repository: RepositoryName, run: Int64) throws(CIError) -> JobFacts {
    guard let facts = runs.withLock({ $0[run] }) else { throw CIError(.notFound, "no run") }
    return facts
  }
}

/// A scripted Actions service: scale set lookup/creation, one session, a
/// message queue the test fills, acquisition and JIT registration.
final class FakeActionsService: Sendable {
  struct State {
    var scaleSetExists = false
    /// Whether the App may create an elastic scale set (Administer).
    var elasticAllowed = true
    var elastic = false
    /// Each queued message's body and the statistics GitHub reports with it.
    var queue: [(body: String, statistics: JSONValue)] = []
    var assigned: Set<String> = []
    var running: Set<String> = []
    var acquired: [[Int64]] = []
    var deleted: [Int64] = []
    var expireNextPoll = false
    var refreshed = 0
    var nextMessageID: Int64 = 1
    var jit: [String] = []
  }

  let http = ScriptedGitHubHTTP()
  let state = Mutex(State())
  static let queueURL = "https://broker.actions.githubusercontent.com/message/q1"

  init() {
    http.on { [self] request in
      let path = request.url.path
      switch (request.method, path) {
      case (.get, "/abc/_apis/runtime/runnerscalesets"):
        let (exists, elastic) = state.withLock { ($0.scaleSetExists, $0.elastic) }
        return Self.json(
          exists
            ? #"{"count":1,"value":[{"id":9,"name":"iso-fast","runnerGroupId":1,"runnerSetting":{"isElastic":\#(elastic)}}]}"#
            : #"{"count":0,"value":[]}"#)
      case (.post, "/abc/_apis/runtime/runnerscalesets"):
        // GitHub refuses `isElastic` without Administer permission (403).
        let body = (try? StrictJSON.parse(request.body ?? [], limits: .github)) ?? .null
        let elastic = body["runnerSetting"]?["isElastic"]?.boolValue == true
        if elastic && !state.withLock({ $0.elasticAllowed }) {
          return GitHubHTTPResponse(status: 403)
        }
        state.withLock {
          $0.scaleSetExists = true
          $0.elastic = elastic
        }
        return Self.json(
          #"{"id":9,"name":"iso-fast","runnerGroupId":1,"runnerSetting":{"isElastic":\#(elastic)}}"#
        )
      case (.post, "/abc/_apis/runtime/runnerscalesets/9/sessions"),
        (.patch, "/abc/_apis/runtime/runnerscalesets/9/sessions/s1"):
        if request.method == .patch { state.withLock { $0.refreshed += 1 } }
        return Self.json(
          #"{"sessionId":"s1","messageQueueUrl":"\#(Self.queueURL)","messageQueueAccessToken":"QUEUE-TOKEN","statistics":{"totalAssignedJobs":0}}"#
        )
      case (.get, "/message/q1"):
        let next: GitHubHTTPResponse = state.withLock { state in
          if state.expireNextPoll {
            state.expireNextPoll = false
            return GitHubHTTPResponse(status: 401)
          }
          guard !state.queue.isEmpty else { return GitHubHTTPResponse(status: 202) }
          let (body, statistics) = state.queue.removeFirst()
          let id = state.nextMessageID
          state.nextMessageID += 1
          let message: JSONValue = [
            "messageId": .integer(id), "messageType": "RunnerScaleSetJobMessages",
            "body": .string(body), "statistics": statistics,
          ]
          return GitHubHTTPResponse(status: 200, body: message.canonical)
        }
        return next
      case (.post, "/abc/_apis/runtime/runnerscalesets/9/acquirejobs"):
        let ids =
          (try? StrictJSON.parse(request.body ?? [], limits: .github))?.arrayValue?.compactMap(
            \.intValue) ?? []
        state.withLock { $0.acquired.append(ids) }
        return Self.json(
          JSONValue.object([
            "count": .integer(Int64(ids.count)), "value": .array(ids.map { .integer($0) }),
          ])
          .canonicalString)
      case (.post, "/abc/_apis/runtime/runnerscalesets/9/generatejitconfig"):
        let name =
          (try? StrictJSON.parse(request.body ?? [], limits: .github))?["name"]?.stringValue ?? ""
        state.withLock { $0.jit.append(name) }
        return Self.json(
          #"{"runner":{"id":501,"name":"\#(name)"},"encodedJITConfig":"\#(GitHubFakeRunners.encodedJIT(id: 501))"}"#
        )
      default:
        if request.method == .delete, path.hasPrefix("/message/q1/") {
          state.withLock { $0.deleted.append(Int64(path.split(separator: "/").last ?? "") ?? -1) }
          return GitHubHTTPResponse(status: 204)
        }
        return nil
      }
    }
  }

  static func json(_ text: String) -> GitHubHTTPResponse {
    GitHubHTTPResponse(status: 200, body: Array(text.utf8))
  }

  /// Queues one message; its statistics count assigned and running jobs
  /// after the batch, as GitHub's do.
  func enqueue(_ jobs: [JSONValue], statistics override: JSONValue? = nil) {
    state.withLock { state in
      for job in jobs {
        let key =
          (job["runnerRequestId"]?.intValue).flatMap { $0 != 0 ? "r\($0)" : nil }
          ?? "j\(job["jobId"]?.stringValue ?? "0")"
        switch job["messageType"]?.stringValue {
        case "JobAssigned": state.assigned.insert(key)
        case "JobStarted": state.running.insert(key)
        case "JobCompleted":
          state.assigned.remove(key)
          state.running.remove(key)
        default: break
        }
      }
      let statistics: JSONValue = [
        "totalAssignedJobs": .integer(Int64(state.assigned.count)),
        "totalRunningJobs": .integer(Int64(state.running.count)),
      ]
      state.queue.append((JSONValue.array(jobs).canonicalString, override ?? statistics))
    }
  }

  static func job(
    _ kind: String, request: Int64, run: Int64 = 42, event: String = "push",
    repository: String = "iso", queueTime: String = "2026-11-09T10:00:00.000Z"
  ) -> JSONValue {
    [
      "messageType": .string(kind), "runnerRequestId": .integer(request), "ownerName": "chr33s",
      "repositoryName": .string(repository), "workflowRunId": .integer(run),
      "eventName": .string(event), "queueTime": .string(queueTime),
    ]
  }
}

@Suite struct ScaleSetTests {
  static func pool() throws -> PoolConfiguration {
    var pool = try #require(try TestConfig.configuration().pools["validation"])
    pool.scope = .repository(try RepositoryName("chr33s/iso"))
    pool.scaleSet = ScaleSetConfiguration(
      name: "iso-fast", minRunners: 0, maxRunners: 4, jobPolicy: JobPolicy())
    return pool
  }

  static func listener(_ service: FakeActionsService, _ authority: FakeScaleSetAuthority)
    throws -> (ScaleSetListener, ControllerStore)
  {
    let store = try ControllerStore.inMemory(clock: FixedClock(value: 1_800_000_000))
    let listener = try ScaleSetListener(
      pool: "validation", configuration: try Self.pool(), authority: authority,
      client: ScaleSetClient(http: service.http), store: store, owner: "iso-ci-test",
      clock: FixedClock(value: 1_800_000_000))
    return (listener, store)
  }

  /// C-T19/C-T20: the scale set is created on first use; a fork pull request
  /// is refused before acquisition with an audit event, a private push is
  /// acquired, and only GitHub's assignment creates demand.
  @Test func forkOffersAreRefusedAndOnlyAllowedJobsAreAcquired() throws {
    let service = FakeActionsService()
    let authority = FakeScaleSetAuthority()
    authority.runs.withLock {
      $0[42] = JobPolicyTests.facts()
      $0[43] = JobPolicyTests.facts(event: "pull_request", head: 77)
    }
    let (listener, store) = try Self.listener(service, authority)
    #expect(listener.step())
    #expect(service.state.withLock { $0.scaleSetExists })
    #expect(listener.demand().connected && listener.demand().pending.isEmpty)
    service.enqueue([
      FakeActionsService.job("JobAvailable", request: 1, run: 42),
      FakeActionsService.job("JobAvailable", request: 2, run: 43, event: "pull_request"),
    ])
    #expect(listener.step())
    #expect(service.state.withLock { $0.acquired } == [[1]])
    #expect(service.state.withLock { $0.deleted } == [1])
    #expect(listener.demand().rejected == 1 && listener.demand().pending.isEmpty)
    let events = try store.events(after: 0, subject: "pool:validation")
    let rejection = try #require(events.first { $0.kind == "job.rejected" })
    #expect(rejection.data["code"] == JobRejection.forkPullRequest.rawValue)
    // Assignment creates demand, dated by GitHub's queue time; start ends it.
    service.enqueue([FakeActionsService.job("JobAssigned", request: 1)])
    #expect(listener.step())
    let pending = listener.demand().pending
    #expect(pending.map(\.requestID) == [1])
    #expect(listener.demand().elastic && listener.demand().neededRunners == 1)
    #expect(pending.first?.enqueuedAt == 1_794_218_400)
    service.enqueue([FakeActionsService.job("JobStarted", request: 1)])
    #expect(listener.step())
    #expect(listener.demand().pending.isEmpty)
  }

  /// Without Administer, GitHub assigns jobs to a non-elastic scale set
  /// directly (no offer, `runnerRequestId` 0): the gate runs on assignment,
  /// and a refused or unvetted assigned job stops every new runner.
  @Test func nonElasticScaleSetsGateAssignedJobsAndBlockRunners() throws {
    let service = FakeActionsService()
    service.state.withLock { $0.elasticAllowed = false }
    let authority = FakeScaleSetAuthority()
    authority.runs.withLock {
      $0[42] = JobPolicyTests.facts()
      $0[43] = JobPolicyTests.facts(event: "pull_request", head: 77)
    }
    let (listener, store) = try Self.listener(service, authority)
    #expect(listener.step())
    #expect(!listener.demand().elastic)
    func message(_ kind: String, _ job: String, run: Int64, event: String = "push") -> JSONValue {
      guard
        case .object(var fields) = FakeActionsService.job(kind, request: 0, run: run, event: event)
      else { return .null }
      fields["jobId"] = .string(job)
      return .object(fields)
    }
    service.enqueue([message("JobAssigned", "a", run: 42)])
    #expect(listener.step())
    #expect(listener.demand().pending.map(\.key) == ["ja"])
    #expect(listener.demand().admissionBlock == nil)
    service.enqueue([message("JobAssigned", "b", run: 43, event: "pull_request")])
    #expect(listener.step())
    #expect(listener.demand().blocked == [.forkPullRequest])
    #expect(listener.demand().admissionBlock?.contains("JOB_REJECTED_FORK_PR") == true)
    #expect(service.state.withLock { $0.acquired.isEmpty })
    #expect(try store.events(after: 0).contains { $0.kind == "job.rejected" })
    // The refused job leaving the queue lifts the block.
    service.enqueue([message("JobCompleted", "b", run: 43, event: "pull_request")])
    #expect(listener.step())
    #expect(listener.demand().admissionBlock == nil)
  }

  /// GitHub re-assigns a job by completing the stale assignment and
  /// assigning it again; a tracked entry GitHub no longer counts never
  /// starts a runner.
  @Test func staleTrackedJobsDoNotStartRunners() throws {
    let service = FakeActionsService()
    service.state.withLock { $0.elasticAllowed = false }
    let authority = FakeScaleSetAuthority()
    authority.runs.withLock { $0[42] = JobPolicyTests.facts() }
    let (listener, _) = try Self.listener(service, authority)
    #expect(listener.step())
    func message(_ kind: String, _ job: String) -> JSONValue {
      guard case .object(var fields) = FakeActionsService.job(kind, request: 0, run: 42) else {
        return .null
      }
      fields["jobId"] = .string(job)
      return .object(fields)
    }
    service.enqueue([message("JobAssigned", "old")])
    #expect(listener.step())
    #expect(listener.demand().neededRunners == 1)
    // GitHub completes the stale assignment under another id, then assigns
    // and runs the job: only one runner is ever needed.
    service.enqueue(
      [message("JobCompleted", "other"), message("JobAssigned", "new")],
      statistics: ["totalAssignedJobs": 1, "totalRunningJobs": 0])
    #expect(listener.step())
    #expect(listener.demand().neededRunners == 1)
    service.enqueue(
      [message("JobStarted", "new")], statistics: ["totalAssignedJobs": 1, "totalRunningJobs": 1])
    #expect(listener.step())
    service.enqueue(
      [message("JobCompleted", "new")], statistics: ["totalAssignedJobs": 0, "totalRunningJobs": 0])
    #expect(listener.step())
    #expect(listener.demand().neededRunners == 0)
    #expect(listener.demand().pending.isEmpty)
  }

  @Test func publicRepositoriesNeedAnElasticScaleSet() throws {
    let service = FakeActionsService()
    service.state.withLock { $0.elasticAllowed = false }
    let store = try ControllerStore.inMemory(clock: FixedClock(value: 1_800_000_000))
    var pool = try Self.pool()
    pool.scaleSet?.jobPolicy.allowPublicRepo = true
    let listener = try ScaleSetListener(
      pool: "validation", configuration: pool, authority: FakeScaleSetAuthority(),
      client: ScaleSetClient(http: service.http), store: store, owner: "iso-ci-test",
      clock: FixedClock(value: 1_800_000_000))
    #expect(!listener.step())
    #expect(listener.demand().lastError?.contains("elastic") == true)
    #expect(!listener.demand().connected)
  }

  @Test func expiredQueueTokenRefreshesTheSession() throws {
    let service = FakeActionsService()
    let (listener, _) = try Self.listener(service, FakeScaleSetAuthority())
    #expect(listener.step())
    service.state.withLock { $0.expireNextPoll = true }
    #expect(listener.step())
    #expect(service.state.withLock { $0.refreshed } == 1)
  }

  @Test func jitRegistrationOpensNoSecondSession() throws {
    let service = FakeActionsService()
    let (listener, _) = try Self.listener(service, FakeScaleSetAuthority())
    // Registration never creates the scale set; the controller's listener does.
    #expect(throws: CIError.self) {
      try listener.generateJIT(name: "iso-ci-x", workFolder: "_work")
    }
    #expect(!service.state.withLock { $0.scaleSetExists })
    service.state.withLock { $0.scaleSetExists = true }
    let jit = try listener.generateJIT(name: "iso-ci-x", workFolder: "_work")
    #expect(jit.runner.id == 501 && jit.runner.name == "iso-ci-x")
    #expect(
      !service.http.requests.contains { $0.url.path.hasSuffix("/sessions") && $0.method == .post })
  }

  @Test func tokensOnlyTravelToActionsServiceHosts() {
    #expect(ActionsService.validatedURL("https://pipelines.actions.githubusercontent.com/x") != nil)
    for bad in [
      "http://pipelines.actions.githubusercontent.com/x", "https://evil.example/x",
      "https://actions.githubusercontent.com.evil.example/x",
      "https://user:pw@broker.actions.githubusercontent.com/x",
      "https://broker.actions.githubusercontent.com:8443/x",
    ] {
      #expect(ActionsService.validatedURL(bad) == nil)
    }
  }

  @Test func messageParsingIsBounded() throws {
    let body = JSONValue.array([
      FakeActionsService.job("JobCompleted", request: 3), ["messageType": "Unknown"],
    ]).canonicalString
    let message = try ScaleSetMessage(
      json: [
        "messageId": 5, "messageType": "RunnerScaleSetJobMessages", "body": .string(body),
        "statistics": ["totalAssignedJobs": 3, "totalRunningJobs": 1],
      ])
    #expect(message.jobs.map(\.kind) == [.completed])
    #expect(message.statistics.waitingJobs == 2)
  }
}

/// C-T24 mechanics with real processes: the lock passes to the supervisor,
/// a restarted controller finds it held, and its release is observed.
@Suite(.serialized) struct AllocationSupervisorTests {
  static func supervisors(_ directory: String, script: String = "sleep 30")
    -> AllocationSupervisors
  {
    AllocationSupervisors(directory: directory, logDirectory: directory + "/logs") { _ in
      ("/bin/sh", ["-c", script])
    }
  }

  @Test func lockTravelsToTheChildAndSurvivesTheController() throws {
    let directory = scratchDirectory("supervisors")
    let id = AllocationID.generate()
    let first = Self.supervisors(directory)
    try first.launch(id, pool: "validation", poolDigest: Digest(hashing: "pool"))
    guard case .live(let state) = first.status(id) else {
      Issue.record("expected a live supervisor")
      return
    }
    #expect(state?.phase == .starting && state?.pool == "validation")
    // A second launch for the same allocation is refused.
    #expect(throws: CIError.self) {
      try first.launch(id, pool: "validation", poolDigest: Digest(hashing: "pool"))
    }
    // A restarted controller (a new instance) re-adopts the live lock.
    let restarted = Self.supervisors(directory)
    let adoption = restarted.adopt()
    #expect(adoption.live.keys.contains(id) && adoption.ended.isEmpty)
    #expect(restarted.status(id).ownsStartup)
    // The supervisor exits: the kernel releases the lock.
    let pid = try #require(Self.childPID(holding: first.files.lock(id)))
    kill(pid, SIGKILL)
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
    #expect(restarted.status(id) == .unsupervised)
    let ended = restarted.adopt()
    #expect(ended.ended.keys.contains(id))
    #expect(access(first.files.lock(id), F_OK) != 0)
  }

  /// Only the lock descriptor (plus stdio) reaches the supervisor.
  @Test func onlyTheLockDescriptorIsInherited() throws {
    let directory = scratchDirectory("supervisors-fds")
    let out = directory + "/fds"
    let supervisors = Self.supervisors(
      directory,
      script:
        "for fd in 3 4 5 6 7 8 9; do [ -e /dev/fd/$fd ] && echo $fd; done > \(out).tmp; mv \(out).tmp \(out)"
    )
    let id = AllocationID.generate()
    try supervisors.launch(id, pool: "validation", poolDigest: Digest(hashing: "pool"))
    for _ in 0..<500 {
      if access(out, F_OK) == 0 { break }
      usleep(10_000)
    }
    let listed = try String(contentsOfFile: out, encoding: .utf8)
    #expect(listed.split(separator: "\n") == ["3"])
  }

  /// A descriptor that already has its target number is inherited too
  /// (dup2 onto itself would keep close-on-exec).
  @Test func aDescriptorAlreadyAtItsTargetIsInherited() throws {
    let directory = scratchDirectory("inherit-same")
    try PrivateFiles.ensureDirectory(directory)
    let out = directory + "/fds"
    let source = open(directory + "/held", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    defer { close(source) }
    let high = fcntl(source, F_DUPFD_CLOEXEC, 200)
    #expect(high >= 200)
    defer { close(high) }
    let devnull = open("/dev/null", O_RDWR | O_CLOEXEC)
    defer { close(devnull) }
    let pid = try Subprocess.spawn(
      "/bin/sh", ["-c", "[ -e /dev/fd/\(high) ] && echo yes > \(out) || echo no > \(out)"], [:],
      stdin: devnull, stdout: devnull, stderr: devnull, inherit: [(high, high)])
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)
    #expect(try String(contentsOfFile: out, encoding: .utf8) == "yes\n")
  }

  @Test func reporterRequiresTheAllocationsOwnLock() throws {
    let directory = scratchDirectory("reporter")
    try PrivateFiles.ensureDirectory(directory)
    let files = AllocationFiles(directory: directory)
    let id = AllocationID.generate()
    try files.writeState(
      SupervisorState(
        allocation: id, pool: "validation", poolDigest: Digest(hashing: "p"), phase: .starting,
        updatedAt: 1))
    let fd = try #require(files.openLock(id, create: true))
    defer { close(fd) }
    let reporter = try SupervisorReporter(
      files: files, allocation: id, lockFD: fd, clock: FixedClock(value: 2))
    reporter.report(.registering, runnerID: 77)
    #expect(files.readState(id)?.phase == .registering && files.readState(id)?.runnerID == 77)
    // Another descriptor on the same file cannot claim it while held.
    let other = try #require(files.openLock(id, create: false))
    defer { close(other) }
    #expect(throws: CIError.self) {
      try SupervisorReporter(
        files: files, allocation: id, lockFD: other, clock: FixedClock(value: 2))
    }
    // A descriptor for a different file is refused.
    let stranger = open("/dev/null", O_RDONLY)
    defer { close(stranger) }
    #expect(throws: CIError.self) {
      try SupervisorReporter(
        files: files, allocation: id, lockFD: stranger, clock: FixedClock(value: 2))
    }
  }

  /// The pid of the process holding `path` open (lsof is part of macOS).
  static func childPID(holding path: String) -> pid_t? {
    let output = try? Subprocess.run(
      .init(
        executable: "/usr/sbin/lsof", arguments: ["-t", path], environment: [:],
        timeout: .seconds(10)))
    return output.flatMap {
      pid_t(String(decoding: $0.stdout, as: UTF8.self).split(separator: "\n").first ?? "")
    }
  }
}
