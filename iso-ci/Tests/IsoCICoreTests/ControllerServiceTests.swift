import Foundation
import Testing

@testable import IsoCICore

/// Controller-level behavior of the preflight and connected-pool services,
/// with fakes (no VM, runner, data-plane child or GitHub).
@Suite struct PreflightServiceTests {
  struct Fixture {
    let root: DataRoot
    let store: ControllerStore
    let service: PreflightService
    let repository: String
  }

  static func git(_ arguments: [String], in directory: String) throws {
    let output = try Subprocess.run(
      .init(
        executable: "/usr/bin/git",
        arguments: [
          "-C", directory, "-c", "user.email=t@example.invalid", "-c", "user.name=t",
          "-c", "commit.gpgsign=false",
        ] + arguments,
        environment: Subprocess.baseEnvironment().merging(["GIT_CONFIG_GLOBAL": "/dev/null"]) { $1 }
      ))
    #expect(output.succeeded)
  }

  static func fixture(workflow: String, approve: Bool = true) throws -> Fixture {
    let base = "/tmp/iso-ci-svc-" + randomHex(bytes: 4)
    let root = DataRoot(path: base + "/root")
    try root.prepare()
    let repository = base + "/repo"
    try FileManager.default.createDirectory(
      atPath: repository + "/.github/workflows", withIntermediateDirectories: true)
    try workflow.write(
      toFile: repository + "/.github/workflows/ci.yml", atomically: true, encoding: .utf8)
    try "x\n".write(toFile: repository + "/a.txt", atomically: true, encoding: .utf8)
    try git(["init", "-q"], in: repository)
    try git(["add", "-A"], in: repository)
    try git(["commit", "-qm", "init"], in: repository)
    try PrivateFiles.write(Array(TestConfig.yaml.utf8), to: root.configuration)
    let database = try Database(path: root.database)
    let store = try ControllerStore(database: database, clock: FixedClock(value: 1_000))
    let objects = try ObjectStore(root: root, database: database)
    let configuration = try TestConfig.configuration()
    if approve {
      for profile in configuration.profiles.keys {
        for (kind, name, digest) in configuration.descriptors(of: profile) {
          try store.save(ApprovalRecord(kind: kind, name: name, digest: digest, approvedAt: 1))
        }
      }
    }
    let harness = try ExecutionTests.harness()
    let path = root.configuration
    let service = PreflightService(
      root: root, store: store, objects: objects, provider: harness.driver,
      executable: "/usr/bin/false",
      loadConfiguration: {
        do throws(CIError) { return .success(try CIConfiguration.load(path: path)) } catch {
          return .failure(error)
        }
      })
    return Fixture(root: root, store: store, service: service, repository: repository)
  }

  static let simple = """
    name: ci
    on: push
    jobs:
      build:
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v4
          - run: echo build
      test:
        needs: build
        runs-on: ubuntu-latest
        steps:
          - run: echo test
    """

  func submit(_ fixture: Fixture, secrets: JSONValue = [:], include: JSONValue = [])
    -> Result<JSONValue, CIError>?
  {
    fixture.service.handle(
      ControlRequest(
        method: "run.submit",
        params: [
          "workflow": ".github/workflows/ci.yml", "repository": .string(fixture.repository),
          "platform": "linux/arm64", "event": "push", "include": include, "exclude": [],
          "secrets": secrets,
          "inputs": [:],
        ]))
  }

  @Test func submitCapturesSnapshotAndRefusesWithoutAnEligibleHost() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    try "dirty\n".write(toFile: fixture.repository + "/a.txt", atomically: true, encoding: .utf8)
    let value = try #require(submit(fixture)).get()
    #expect(value["dirty"] == .bool(true))
    #expect(value["jobs"] == .integer(2))
    let run = try PreflightRunID(try #require(value["run"]?.stringValue))
    fixture.service.reconcile(now: 1_000)
    Thread.sleep(forTimeInterval: 0.5)
    let attempts = try fixture.store.preflightJobs(run: run, as: JobAttemptRecord.self)
    let build = try #require(attempts.first { $0.jobKey == "build" })
    // C-T01: no host can admit the profile (none enabled and qualified), so
    // the job fails explicitly before any allocation; nothing falls back.
    #expect(build.state == .failed)
    #expect(build.reason?.contains("CAPABILITY_MISSING") == true)
    #expect(try fixture.store.openAllocations().isEmpty)
    #expect(attempts.first { $0.jobKey == "test" }?.state == .pending)
  }

  // C-T10: an explicit include selects only matching untracked paths.
  @Test func includeSelectsOnlyMatchingUntrackedPaths() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    for name in ["included.txt", "untracked.txt"] {
      try "x\n".write(toFile: fixture.repository + "/" + name, atomically: true, encoding: .utf8)
    }
    let value = try #require(submit(fixture, include: ["included.txt"])).get()
    #expect(value["included_untracked"] == ["included.txt"])
    let plain = try #require(submit(fixture)).get()
    #expect(plain["included_untracked"] == [])
  }

  // C-T09: statically unsupported semantics are refused before allocation.
  @Test func unsupportedWorkflowIsRefusedBeforeAllocation() throws {
    let fixture = try Self.fixture(
      workflow: """
        on: push
        jobs:
          a:
            runs-on: macos-latest
            steps:
              - run: echo hi
          b:
            uses: octo/other/.github/workflows/w.yml@main
        """)
    guard case .failure(let error)? = submit(fixture) else {
      Issue.record("expected a compatibility rejection")
      return
    }
    #expect(error.code == .compatibilityRejected)
    // Every problem is reported; the reusable call only for its `uses:`.
    #expect(error.details.values.contains { $0.contains("jobs.b.uses") })
    #expect(!error.details.values.contains { $0.contains("jobs.b.runs-on") })
    #expect(try fixture.store.openAllocations().isEmpty)
    #expect(try fixture.store.preflightRunIDs(limit: 5).isEmpty)
  }

  @Test func unapprovedDescriptorsRefuseSubmission() throws {
    let fixture = try Self.fixture(workflow: Self.simple, approve: false)
    guard case .failure(let error)? = submit(fixture) else {
      Issue.record("expected an admission refusal")
      return
    }
    #expect(error.code == .admissionRefused)
  }

  @Test func abortSettlesTheRunAndRetryCreatesAFreshAttempt() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    let value = try #require(submit(fixture)).get()
    let run = try PreflightRunID(try #require(value["run"]?.stringValue))
    _ = try #require(
      fixture.service.handle(
        ControlRequest(method: "abort", params: ["target": .string(run.rawValue)]))
    ).get()
    fixture.service.reconcile(now: 1_001)
    let inspected = try #require(
      fixture.service.handle(
        ControlRequest(method: "inspect.preflight", params: ["target": .string(run.rawValue)]))
    )
    .get()
    #expect(inspected["settled"] == .bool(true))
    let attempts = try fixture.store.preflightJobs(run: run, as: JobAttemptRecord.self)
    #expect(attempts.allSatisfy { $0.state == .cancelled })
    let build = try #require(attempts.first { $0.jobKey == "build" })
    let retried = try #require(
      fixture.service.handle(
        ControlRequest(method: "retry", params: ["allocation": .string(build.id.rawValue)]))
    ).get()
    #expect(retried["number"] == .integer(2))
    // The downstream job is re-queued so the run settles on the new result.
    #expect(retried["requeued"] == ["test"])
    let requeued = try fixture.store.preflightJobs(run: run, as: JobAttemptRecord.self)
    #expect(requeued.contains { $0.jobKey == "test" && $0.number == 2 && $0.state == .pending })
    // Retrying the superseded attempt again is refused.
    guard
      case .failure(let error)? = fixture.service.handle(
        ControlRequest(method: "retry", params: ["allocation": .string(build.id.rawValue)]))
    else {
      Issue.record("expected a conflict")
      return
    }
    #expect(error.code == .conflict)
  }

  @Test func secretsAreNeverPersisted() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    let value = try #require(submit(fixture, secrets: ["TOKEN": "s3cr3t-value"])).get()
    let run = try PreflightRunID(try #require(value["run"]?.stringValue))
    let record = try #require(try fixture.store.preflightRun(run, as: PreflightRunRecord.self))
    #expect(record.secretNames == ["TOKEN"])
    let bytes = try #require(try PrivateFiles.read(fixture.root.database, limit: 64 << 20))
    #expect(!String(decoding: bytes, as: UTF8.self).contains("s3cr3t-value"))
    let events = try fixture.store.events(after: 0)
    #expect(
      !events.contains {
        $0.message.contains("s3cr3t") || $0.data.values.contains { $0.contains("s3cr3t") }
      })
  }

  /// The submitted run's repository name comes from the repository's own
  /// config read as data: an include Git would honor is not followed.
  @Test func submitNamesTheRepositoryWithoutRunningGit() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    let config = fixture.repository + "/.git/config"
    try "[remote \"origin\"]\n\turl = https://github.com/octo/inert.git\n".write(
      toFile: fixture.repository + "/.git/included.cfg", atomically: true, encoding: .utf8)
    try
      (try String(contentsOfFile: config, encoding: .utf8)
      + "[remote \"origin\"]\n\turl = git@github.com:octo/named.git\n"
      + "[include]\n\tpath = included.cfg\n")
      .write(toFile: config, atomically: true, encoding: .utf8)
    let value = try #require(submit(fixture)).get()
    let run = try PreflightRunID(try #require(value["run"]?.stringValue))
    let record = try #require(try fixture.store.preflightRun(run, as: PreflightRunRecord.self))
    #expect(record.repository == "octo/named")
  }

  /// Only a clean-tree run without secrets publishes shared cache entries:
  /// the scope a submitted run's job registers is confined otherwise.
  @Test func dirtyOrSecretRunsConfineTheirCaches() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    let configuration = try TestConfig.configuration()
    func confinement(secrets: JSONValue = [:]) throws -> (PreflightRunID, String?) {
      let value = try #require(submit(fixture, secrets: secrets)).get()
      let run = try PreflightRunID(try #require(value["run"]?.stringValue))
      let record = try #require(try fixture.store.preflightRun(run, as: PreflightRunRecord.self))
      let profile = try ResolvedProfile(name: record.profile, configuration: configuration)
      let scope = PreflightService.cacheScope(
        record, run: run, secretsMapped: !record.secretNames.isEmpty, profile: profile,
        host: .local)
      return (run, scope.confinedToRun)
    }
    #expect(try confinement().1 == nil)
    let (secretRun, secretScope) = try confinement(secrets: ["TOKEN": "s"])
    #expect(secretScope == secretRun.rawValue)
    try "dirty\n".write(toFile: fixture.repository + "/a.txt", atomically: true, encoding: .utf8)
    let (dirtyRun, dirtyScope) = try confinement()
    #expect(dirtyScope == dirtyRun.rawValue)
    // A patched revision confines the whole run, even its clean base.
    let clean = InputRevision(
      number: 0, baseCommit: String(repeating: "a", count: 40), snapshot: Digest(hashing: "s"),
      dirty: false, capturedAt: 1, patchedAttempt: nil)
    let patched = InputRevision(
      number: 1, baseCommit: clean.baseCommit, snapshot: Digest(hashing: "p"), dirty: false,
      capturedAt: 2, patchedAttempt: .generate())
    #expect(
      PreflightService.cacheConfinement(
        run: dirtyRun, secretsMapped: false, revisions: [clean, patched]) == dirtyRun.rawValue)
  }

  /// Mapped secret values leave controller memory when the run finishes.
  @Test func mappedSecretsAreDroppedWhenTheRunFinishes() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    let value = try #require(submit(fixture, secrets: ["TOKEN": "s3cr3t-value"])).get()
    let run = try PreflightRunID(try #require(value["run"]?.stringValue))
    #expect(fixture.service.holdsSecrets(run))
    // No eligible host: build fails, test is skipped, and the run settles.
    var settled = false
    for tick in 0..<50 where !settled {
      fixture.service.reconcile(now: 1_000 + EpochSeconds(tick))
      Thread.sleep(forTimeInterval: 0.1)
      settled =
        try fixture.store.preflightRun(run, as: PreflightRunRecord.self)?.state == .finished
    }
    #expect(settled)
    #expect(!fixture.service.holdsSecrets(run))
  }

  /// C-T07: a started runner that never acquires its job (for example, one
  /// that cannot reach the endpoint) fails within the boot allowance instead
  /// of holding its VM until the hard deadline.
  @Test func aRunnerThatNeverAcquiresFailsWithinTheBootAllowance() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    let value = try #require(submit(fixture)).get()
    let run = try PreflightRunID(try #require(value["run"]?.stringValue))
    var build = try #require(
      try fixture.store.preflightJobs(run: run, as: JobAttemptRecord.self).first {
        $0.jobKey == "build"
      })
    let harness = try ExecutionTests.harness()
    var allocation = AllocationRecord(
      id: .generate(), kind: .preflight, controller: try fixture.store.controllerID(),
      host: "local", hostRun: .generate(), operations: HostOperations(create: .generate()),
      provenance: InputProvenance(
        profileDigest: harness.profile.digest, imageReference: harness.profile.image.isoImage,
        imageDigest: nil, expectedRunnerVersion: harness.profile.image.runnerVersion,
        networkPolicyDigest: nil, qualificationDigest: nil, qualificationTuple: [:],
        compatibilityDigest: nil, limitsDigest: nil, platform: "linux/arm64"),
      reservation: harness.profile.limits.reservation, createdAt: 1_000, hardDeadline: 30_000)
    allocation.preflightRun = run
    allocation.jobAttempt = build.id
    allocation.observedRunPhase = .running
    try fixture.store.insert(allocation)
    build.state = .running
    build.allocation = allocation.id
    build.startedAt = 1_000
    try fixture.store.savePreflightJob(attempt: build.id, run: run, jobKey: "build", build)
    let boot = harness.profile.limits.bootSeconds
    fixture.service.reconcile(now: 1_000 + boot - 1)
    #expect(
      try fixture.store.preflightJob(build.id, as: JobAttemptRecord.self)?.state == .running)
    fixture.service.reconcile(now: 1_000 + boot)
    let failed = try #require(try fixture.store.preflightJob(build.id, as: JobAttemptRecord.self))
    #expect(failed.state == .failed)
    #expect(failed.reason == "the runner did not acquire the job within \(boot) s")
    #expect(try fixture.store.allocation(allocation.id)?.execution == .failed)
  }

  @Test func patchNeedsALiveRetainedEnvironment() throws {
    let fixture = try Self.fixture(workflow: Self.simple)
    guard
      case .failure(let error)? = fixture.service.handle(
        ControlRequest(
          method: "patch",
          params: [
            "allocation": .string(AllocationID.generate().rawValue),
            "repository": .string(fixture.repository),
          ]))
    else {
      Issue.record("expected a refusal")
      return
    }
    #expect(error.code == .notFound)
  }
}

@Suite struct ConnectedPoolServiceTests {
  static func service(approve: Bool) throws -> (ConnectedPoolService, ControllerStore) {
    let store = try ControllerStore.inMemory(clock: FixedClock(value: 1_000))
    let configuration = try TestConfig.configuration()
    if approve {
      for (kind, name, digest) in configuration.descriptors(of: "linux-validation") {
        try store.save(ApprovalRecord(kind: kind, name: name, digest: digest, approvedAt: 1))
      }
    }
    let harness = try ExecutionTests.harness()
    let service = ConnectedPoolService(
      store: store, provider: harness.driver, loadConfiguration: { .success(configuration) },
      clients: { (_) throws(CIError) -> GitHubInstallationClient in
        throw CIError(.githubUnavailable, "offline in tests")
      },
      api: GitHubAPI(http: ScriptedGitHubHTTP()), credentials: MemoryCredentialStore())
    return (service, store)
  }

  @Test func unapprovedOrUnconnectedPoolsStayInactive() throws {
    let (service, store) = try Self.service(approve: false)
    service.reconcile(now: 1_000)
    let status = try #require(try store.poolStatus("validation"))
    #expect(status.state == .inactive)
    #expect(status.reason?.contains("not approved") == true)
    let (approved, approvedStore) = try Self.service(approve: true)
    approved.reconcile(now: 1_000)
    let second = try #require(try approvedStore.poolStatus("validation"))
    #expect(second.state == .inactive)
    #expect(second.reason?.contains("installation") == true)
  }

  /// C-T15: a pool added with the same scope and labels must not leave an
  /// active pool on a cached activation for the cache interval.
  @Test func activationIsReevaluatedWhenRoutingChanges() throws {
    let configuration = try TestConfig.configuration()
    let key = ConnectedPoolService.activationKey("validation", configuration)
    #expect(ConnectedPoolService.activationKey("validation", configuration) == key)
    var clashing = configuration
    clashing.pools["shadow"] = configuration.pools["validation"]
    #expect(ConnectedPoolService.activationKey("validation", clashing) != key)
  }

  @Test func operatorStatesAreNotOverriddenByActivation() throws {
    let (service, store) = try Self.service(approve: true)
    service.reconcile(now: 1_000)
    _ = try #require(
      service.handle(ControlRequest(method: "pool.pause", params: ["pool": "validation"]))
    ).get()
    service.reconcile(now: 1_001)
    #expect(try store.poolStatus("validation")?.state == .paused)
    guard
      case .failure(let error)? = service.handle(
        ControlRequest(method: "pool.pause", params: ["pool": "nope"]))
    else {
      Issue.record("expected not found")
      return
    }
    #expect(error.code == .notFound)
    #expect(service.handle(ControlRequest(method: "run.submit", params: [:])) == nil)
  }

  @Test func abortOnlyClaimsConnectedAllocations() throws {
    let (service, _) = try Self.service(approve: true)
    #expect(
      service.handle(
        ControlRequest(
          method: "abort", params: ["target": .string(AllocationID.generate().rawValue)])) == nil)
  }
}

/// Stored runner logs are guest-authored: printed text keeps line structure
/// but never carries terminal control sequences.
@Suite struct JobLogTextTests {
  @Test func controlCharactersOtherThanNewlineAndTabAreRemoved() {
    let raw = Array("ok\tstep\n\u{1B}]52;c;Zm9v\u{07}\u{1B}[2Jdone\r\n".utf8)
    #expect(PreflightService.printable(raw) == "ok\tstep\n]52;c;Zm9v[2Jdone\n")
  }
}
