import Foundation
import Security
import Synchronization

@testable import IsoCICore

/// A settable clock for deterministic reconciliation tests.

/// Generates a 2048-bit RSA key and returns it as a PKCS#1 PEM plus the
/// public key for verification.
func makeGitHubTestRSAKey() throws -> (pem: String, publicKey: SecKey) {
  let attributes: [String: Any] = [
    kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
  ]
  var error: Unmanaged<CFError>?
  guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
    let data = SecKeyCopyExternalRepresentation(key, &error) as Data?,
    let publicKey = SecKeyCopyPublicKey(key)
  else { throw CIError(.internalError, "test key generation failed") }
  let body = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
  return ("-----BEGIN RSA PRIVATE KEY-----\n\(body)\n-----END RSA PRIVATE KEY-----\n", publicKey)
}

/// The test App and its credentials.
struct GitHubTestApp {
  let record: GitHubAppRecord
  let credentials: MemoryCredentialStore
  let publicKey: SecKey

  static func make(clientID: String? = "Iv1.test") throws -> GitHubTestApp {
    let key = try makeGitHubTestRSAKey()
    let credentials = MemoryCredentialStore()
    let record = GitHubAppRecord(
      appID: 42, slug: "iso-ci-test", owner: "octo", clientID: clientID, htmlURL: nil,
      credentialReference: "github-app-42", createdAt: 0)
    try credentials.store(
      Array(key.pem.utf8),
      reference: CredentialKind.appPrivateKey.reference(record.credentialReference))
    return GitHubTestApp(record: record, credentials: credentials, publicKey: key.publicKey)
  }
}

/// In-memory GitHub runner service with scripted failures.
final class GitHubFakeRunners: RunnerService {
  struct State {
    var runners: [Int64: GitHubRunnerInfo] = [:]
    var nextID: Int64 = 100
    var jobs: [GitHubJobInfo] = []
    var jobDetails: [Int64: GitHubJobInfo] = [:]
    var jitCalls: [(name: String, labels: [String])] = []
    var deleted: [Int64] = []
    var jitFailure: CIError?
    /// When set, the JIT call registers the runner and then fails as if
    /// the reply was lost.
    var loseNextJITReply = false
    var lookupFailure: CIError?
    var reportedLabels: [String]?
    var groupID: Int64 = 1
    /// The service host GitHub assigns in the JIT configuration.
    var serviceHost = "broker.actions.githubusercontent.com"
  }

  /// A JIT configuration shaped like GitHub's: a base64 JSON map of base64
  /// runner files, carrying a unique secret marker.
  static func encodedJIT(id: Int64, serviceHost: String = "broker.actions.githubusercontent.com")
    -> String
  {
    func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }
    let runner =
      #"{"AgentId":\#(id),"ServerUrl":"https://\#(serviceHost)/","GitHubUrl":"https://github.com/octo/demo","Marker":"JIT-SECRET-\#(id)"}"#
    let credentials =
      #"{"Scheme":"OAuth","Data":{"authorizationUrl":"https://\#(serviceHost)/_apis/oauth2/token"}}"#
    return b64(
      #"{".runner":"\#(b64(runner))",".credentials":"\#(b64(credentials))",".credentials_rsaparams":"\#(b64("{}"))"}"#
    )
  }

  let state = Mutex(State())

  func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64 {
    state.withLock { $0.groupID }
  }

  func generateJIT(
    scope: GitHubRunnerScope, name: String, runnerGroupID: Int64, labels: [String],
    workFolder: String
  ) throws(CIError) -> GitHubJITConfig {
    let outcome: Result<GitHubJITConfig, CIError> = state.withLock { state in
      state.jitCalls.append((name, labels))
      if let failure = state.jitFailure { return .failure(failure) }
      let id = state.nextID
      state.nextID += 1
      let runner = GitHubRunnerInfo(
        id: id, name: name, status: "online", busy: false, labels: state.reportedLabels ?? labels,
        runnerGroupID: runnerGroupID)
      state.runners[id] = runner
      if state.loseNextJITReply {
        state.loseNextJITReply = false
        return .failure(
          CIError(.githubUnavailable, "connection reset", details: ["uncertain": "true"]))
      }
      return .success(
        GitHubJITConfig(
          runner: runner,
          encoded: RedactedSecret(Self.encodedJIT(id: id, serviceHost: state.serviceHost))))
    }
    return try outcome.get()
  }

  func runners(scope: GitHubRunnerScope, named name: String) throws(CIError) -> [GitHubRunnerInfo] {
    let outcome: Result<[GitHubRunnerInfo], CIError> = state.withLock { state in
      if let failure = state.lookupFailure { return .failure(failure) }
      return .success(state.runners.values.filter { $0.name == name })
    }
    return try outcome.get()
  }

  func runner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> GitHubRunnerInfo? {
    let outcome: Result<GitHubRunnerInfo?, CIError> = state.withLock { state in
      if let failure = state.lookupFailure { return .failure(failure) }
      return .success(state.runners[id])
    }
    return try outcome.get()
  }

  func deleteRunner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> Bool {
    state.withLock { state in
      state.deleted.append(id)
      return state.runners.removeValue(forKey: id) != nil
    }
  }

  func activeJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo] {
    let outcome: Result<[GitHubJobInfo], CIError> = state.withLock { state in
      if let failure = state.lookupFailure { return .failure(failure) }
      return .success(state.jobs)
    }
    return try outcome.get()
  }

  func completedJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo] {
    let outcome: Result<[GitHubJobInfo], CIError> = state.withLock { state in
      if let failure = state.lookupFailure { return .failure(failure) }
      return .success(state.jobDetails.values.filter { $0.status == "completed" })
    }
    return try outcome.get()
  }

  func job(repository: RepositoryName, id: Int64) throws(CIError) -> GitHubJobInfo {
    guard let job = state.withLock({ $0.jobDetails[id] ?? $0.jobs.first { $0.id == id } }) else {
      throw CIError(.notFound, "no job")
    }
    return job
  }

  /// GitHub assigns `job` to the runner named `runnerName` and marks it busy.
  func assign(jobID: Int64, toRunnerNamed runnerName: String, repository: RepositoryName) {
    state.withLock { state in
      guard let runner = state.runners.values.first(where: { $0.name == runnerName }) else {
        return
      }
      state.runners[runner.id] = GitHubRunnerInfo(
        id: runner.id, name: runner.name, status: "online", busy: true, labels: runner.labels,
        runnerGroupID: runner.runnerGroupID)
      state.jobs.append(
        GitHubJobInfo(
          id: jobID, runID: 7_000 + jobID, runAttempt: 1, repository: repository, name: "smoke",
          status: "in_progress", conclusion: nil, runnerID: runner.id, runnerName: runner.name,
          labels: runner.labels, htmlURL: nil))
    }
  }

  /// The job completes and GitHub removes the ephemeral runner.
  func complete(jobID: Int64, conclusion: String) {
    state.withLock { state in
      guard let index = state.jobs.firstIndex(where: { $0.id == jobID }) else { return }
      let job = state.jobs.remove(at: index)
      state.jobDetails[jobID] = GitHubJobInfo(
        id: job.id, runID: job.runID, runAttempt: job.runAttempt, repository: job.repository,
        name: job.name, status: "completed", conclusion: conclusion, runnerID: job.runnerID,
        runnerName: job.runnerName, labels: job.labels, htmlURL: job.htmlURL)
      if let runnerID = job.runnerID { state.runners.removeValue(forKey: runnerID) }
    }
  }

  func addForeignRunner(name: String) {
    state.withLock { state in
      let id = state.nextID
      state.nextID += 1
      state.runners[id] = GitHubRunnerInfo(
        id: id, name: name, status: "online", busy: false, labels: ["self-hosted"], runnerGroupID: 1
      )
    }
  }
}

/// An `EnvironmentProvider` that mutates allocation records the way the real
/// driver does, without hosts.
final class GitHubFakeProvider: EnvironmentProvider {
  struct Call: Equatable {
    let name: String
    let allocation: AllocationID?
  }

  struct State {
    var calls: [Call] = []
    var commands: [(allocation: AllocationID, command: GuestCommand)] = []
    var runnerStatus: [AllocationID: String] = [:]
    var runnerVersion = "2.338.0"
    var downHosts: Set<Name> = []
    var bootstrapExit: Int32 = 0
    var admitFailure: CIError?
    var refusingHosts: Set<Name> = []
  }

  let store: ControllerStore
  let state = Mutex(State())
  /// Runs on every guest command, outside the state lock (to interleave
  /// operator actions with a pass).
  let onExecute = Mutex<(@Sendable () -> Void)?>(nil)

  init(store: ControllerStore) { self.store = store }

  var calls: [Call] { state.withLock { $0.calls } }
  func calls(_ name: String) -> [Call] { calls.filter { $0.name == name } }

  private func record(_ name: String, _ id: AllocationID?) {
    state.withLock { $0.calls.append(Call(name: name, allocation: id)) }
  }

  func admit(host: Name, profile: ResolvedProfile) throws(CIError) -> Admission {
    record("admit", nil)
    if let failure = state.withLock({ $0.admitFailure }) { throw failure }
    if state.withLock({ $0.refusingHosts.contains(host) }) {
      throw CIError(.admissionRefused, "host \(host) refuses admission")
    }
    return Admission(
      host: host, hostID: .generate(), ownerID: try OwnerID(String(repeating: "a", count: 32)),
      epoch: .generate(), expectedNetworkPolicy: Digest(hashing: "policy"),
      qualificationDigest: Digest(hashing: "evidence"),
      qualificationTuple: ["transport": "brokered"],
      qualificationExpiresAt: nil, retentionModes: [.live, .stopped])
  }

  func provision(_ id: AllocationID, profile: ResolvedProfile, admission: Admission) throws(CIError)
  {
    record("provision", id)
    try store.update(id) {
      $0.instance = QualifiedInstance(
        hostID: admission.hostID, ownerID: admission.ownerID, instanceID: .generate(),
        runtimeID: "iso-aaaaaaaa-0000000000000001", guestOS: "linux")
      $0.vmCleanup = .pending
      $0.observedRunPhase = .running
      $0.readyAt = store.now
    }
  }

  func observe(_ id: AllocationID) throws(CIError) {
    record("observe", id)
    guard let allocation = try store.allocation(id) else { return }
    if state.withLock({ $0.downHosts.contains(allocation.host) }) {
      try store.update(id) { $0.uncertainty = "host observation failed: unreachable" }
      throw CIError(.hostUnreachable, "host unreachable")
    }
    if allocation.uncertainty?.hasPrefix("host observation failed") == true {
      try store.update(id) { $0.uncertainty = nil }
    }
  }

  func execute(_ id: AllocationID, _ command: GuestCommand) throws(CIError) -> GuestCommandResult {
    record("execute", id)
    onExecute.withLock { $0 }?()
    return state.withLock { state in
      state.commands.append((id, command))
      if command.argv.contains("iso-ci-version") {
        return GuestCommandResult(
          exitStatus: 0, stdout: Array((state.runnerVersion + "\n").utf8), stderr: [],
          timedOut: false)
      }
      if command.argv.contains("iso-ci-bootstrap") {
        return GuestCommandResult(
          exitStatus: state.bootstrapExit, stdout: [], stderr: [], timedOut: false)
      }
      let status = state.runnerStatus[id] ?? "running"
      return GuestCommandResult(
        exitStatus: 0, stdout: Array((status + "\n").utf8), stderr: [], timedOut: false)
    }
  }

  func holdSession(_ id: AllocationID, forwards: [ServiceForward]) throws(CIError) {
    record("holdSession", id)
  }

  func closeSession(_ id: AllocationID) { record("closeSession", id) }

  func retain(_ id: AllocationID, mode: RetentionMode, seconds: UInt64) throws(CIError) {
    record("retain", id)
    try store.update(id) {
      $0.desired = mode == .live ? .retainLive : .retainStopped
      $0.retentionUntil = store.now + seconds
    }
  }

  func complete(_ id: AllocationID, exitStatus: Int32?) throws(CIError) {
    record("complete", id)
    try store.update(id) {
      $0.export = .exported
      $0.observedRunPhase = .resultsPending
      $0.finishedAt = $0.finishedAt ?? store.now
    }
  }

  func release(_ id: AllocationID) throws(CIError) {
    record("release", id)
    guard let allocation = try store.allocation(id) else { return }
    if state.withLock({ $0.downHosts.contains(allocation.host) }) {
      try store.update(id) { $0.vmCleanup = .debt }
      throw CIError(.hostUnreachable, "host unreachable")
    }
    try store.update(id) {
      $0.vmCleanup = .verified
      $0.observedRunPhase = .destroyed
    }
  }
}

/// Picks the first candidate (placement is tested separately).
struct GitHubFirstHostPlacement: PlacementPolicy {
  func choose(
    candidates: [Name], profile: ResolvedProfile, configuration: CIConfiguration,
    store: ControllerStore, fairnessKey: String, now: EpochSeconds
  ) throws(CIError) -> (choice: Name?, refusals: [PlacementRefusal]) {
    (candidates.first, [])
  }
}

/// A store, configuration, fakes and a reconciler for the `validation` pool.
struct GitHubReconcilerHarness {
  let clock = TestClock()
  let store: ControllerStore
  let configuration: CIConfiguration
  let provider: GitHubFakeProvider
  let runners = GitHubFakeRunners()
  let controller: ControllerID
  let reconciler: ConnectedPoolReconciler
  let repository = try! RepositoryName("octo/app")

  init(
    desiredIdle: UInt32 = 1, maxLive: UInt32 = 2, retention: FailureRetention = .disabled,
    hosts: [Name] = ["local"]
  ) throws {
    store = try ControllerStore.inMemory(clock: clock)
    var configuration = try CIConfiguration.parse(
      CIConfiguration.template(repository: "octo/app", host: "local"))
    configuration.pools["validation"]?.desiredIdleVMs = desiredIdle
    configuration.pools["validation"]?.maxLiveVMs = maxLive
    configuration.pools["validation"]?.retentionOnFailure = retention
    configuration.pools["validation"]?.hosts = hosts
    for host in hosts where configuration.hosts[host] == nil {
      configuration.hosts[host] = configuration.hosts["local"]
    }
    self.configuration = configuration
    provider = GitHubFakeProvider(store: store)
    controller = try store.controllerID()
    reconciler = ConnectedPoolReconciler(
      pool: "validation", store: store, configuration: configuration, provider: provider,
      runners: runners, placement: GitHubFirstHostPlacement(), controller: controller, clock: clock)
    try PoolControl.set("validation", .active, reason: nil, store: store)
  }

  var limits: LimitsDescriptor { configuration.limits["operator-approved-ci-limits"]! }

  func open() throws -> [AllocationRecord] { try store.openAllocations(pool: "validation") }
}
