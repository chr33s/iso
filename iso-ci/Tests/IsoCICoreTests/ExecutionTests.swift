import Foundation
import Testing

@testable import IsoCICore

@Suite struct ExecutionTests {
  static let reviewedHosts =
    [
      "github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com",
      "*.actions.githubusercontent.com", "ghcr.io", "pkg-containers.githubusercontent.com",
    ] + (0..<20).map { "productionresultssa\($0).blob.core.windows.net" }

  // A host wildcard covers exact required names below it; a required
  // wildcard must be on the host verbatim; nothing covers the suffix itself.
  @Test func hostRulesCoverRequiredEndpointsExplicitly() throws {
    func rule(_ raw: String) throws -> HostRule { try #require(HostRule(raw)) }
    let host = try ["*.actions.githubusercontent.com", "github.com"].map(rule)
    #expect(try rule("broker.actions.githubusercontent.com").isCovered(by: host))
    #expect(try rule("*.actions.githubusercontent.com").isCovered(by: host))
    #expect(try !rule("actions.githubusercontent.com").isCovered(by: host))
    #expect(try !rule("evilactions.githubusercontent.com").isCovered(by: host))
    #expect(
      try !rule("*.actions.githubusercontent.com").isCovered(
        by: [rule("broker.actions.githubusercontent.com")]))
    // The same names base iso's ExactHostname refuses: single labels,
    // all-numeric aliases, uppercase, and short or nested wildcards.
    for bad in [
      "*.com", "*.github.io", "*.githubusercontent.com", "*", "*.*.example.com", "localhost",
      "127.0.0.1", "GitHub.com", "",
    ] {
      #expect(HostRule(bad) == nil, "\(bad)")
    }
    let encoded = try JSONEncoder().encode([rule("*.actions.githubusercontent.com")])
    #expect(String(decoding: encoded, as: UTF8.self) == #"["*.actions.githubusercontent.com"]"#)
  }

  struct Harness {
    let host: FakeHost
    let store: ControllerStore
    let driver: AllocationDriver
    let profile: ResolvedProfile
    let configuration: CIConfiguration
  }

  static func harness(
    _ host: FakeHost = FakeHost(
      capabilities: FakeHost.qualifiedCapabilities(allowed: reviewedHosts))
  )
    throws -> Harness
  {
    let store = try ControllerStore.inMemory(clock: FixedClock(value: 1_000))
    let directory = HostDirectory(store: store) { _ in host }
    try directory.enable("local")
    let root = DataRoot(path: scratchDirectory("tests"))
    let driver = AllocationDriver(
      store: store, hosts: directory, root: root, iso: "/usr/bin/false",
      relayExecutable: "/usr/bin/false",
      objects: nil)
    let configuration = try TestConfig.configuration()
    let profile = try ResolvedProfile(name: "linux-validation", configuration: configuration)
    return Harness(
      host: host, store: store, driver: driver, profile: profile, configuration: configuration)
  }

  static func allocation(_ harness: Harness) throws -> AllocationRecord {
    let controller = try harness.store.controllerID()
    let record = AllocationRecord(
      id: .generate(), kind: .connected, controller: controller, host: "local",
      hostRun: .generate(),
      operations: HostOperations(create: .generate()),
      provenance: InputProvenance(
        profileDigest: harness.profile.digest, imageReference: harness.profile.image.isoImage,
        imageDigest: nil, expectedRunnerVersion: harness.profile.image.runnerVersion,
        networkPolicyDigest: nil, qualificationDigest: nil, qualificationTuple: [:],
        compatibilityDigest: nil, limitsDigest: nil, platform: "linux/arm64"),
      reservation: harness.profile.limits.reservation, createdAt: 1_000, hardDeadline: 30_000)
    try harness.store.insert(record)
    return record
  }

  // C-T01: the qualified handoff and current admission are required; no NIC fallback.
  @Test func admissionFailsClosedWithoutNetHandoff() throws {
    for capabilities in [
      FakeHost.qualifiedCapabilities(advertise: false, allowed: Self.reviewedHosts),
      FakeHost.qualifiedCapabilities(status: "missing", allowed: Self.reviewedHosts),
      FakeHost.qualifiedCapabilities(allowed: Self.reviewedHosts, expiresAt: 10),
      FakeHost.qualifiedCapabilities(providers: ["anthropic"], allowed: Self.reviewedHosts),
      FakeHost.qualifiedCapabilities(allowed: ["github.com"]),
      // Evidence for another image (or another digest) does not qualify this one.
      FakeHost.qualifiedCapabilities(
        allowed: Self.reviewedHosts, image: "default@sha256:" + String(repeating: "0", count: 64)),
      FakeHost.qualifiedCapabilities(
        allowed: Self.reviewedHosts, image: "ci-runner@sha256:" + String(repeating: "1", count: 64)),
    ] {
      let harness = try Self.harness(FakeHost(capabilities: capabilities))
      #expect(throws: CIError.self) {
        _ = try harness.driver.admit(host: "local", profile: harness.profile)
      }
    }
    let harness = try Self.harness()
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    #expect(admission.expectedNetworkPolicy.rawValue == FakeHost.grantFreePolicy)
  }

  /// C-T14: each worker builds its own qualified image, so a descriptor may
  /// name another approved digest for a host; admission and `run.create` on
  /// that host use exactly it, and the default digest no longer qualifies it.
  @Test func aHostDigestQualifiesThatHostsOwnImageBuild() throws {
    let other = try Digest(prefixed: "sha256:" + String(repeating: "2", count: 64))
    let image = "ci-runner@sha256:" + String(repeating: "2", count: 64)
    let harness = try Self.harness(
      FakeHost(
        capabilities: FakeHost.qualifiedCapabilities(allowed: Self.reviewedHosts, image: image)))
    var configuration = harness.configuration
    let base = try #require(configuration.images["approved-linux-arm64-runner"])
    configuration.images["approved-linux-arm64-runner"]?.hostDigests = ["local": other]
    #expect(
      configuration.images["approved-linux-arm64-runner"]?.digestOfDescriptor
        != base.digestOfDescriptor)
    #expect(throws: CIError.self) {
      _ = try harness.driver.admit(host: "local", profile: harness.profile)
    }
    let profile = try ResolvedProfile(name: "linux-validation", configuration: configuration)
    #expect(profile.image.digest(on: "local") == other)
    #expect(profile.image.digest(on: "elsewhere") == base.digest)
    _ = try harness.driver.admit(host: "local", profile: profile)
    var unknown = configuration
    unknown.images["approved-linux-arm64-runner"]?.hostDigests = ["nowhere": other]
    #expect(throws: CIError.self) { try unknown.validateReferences() }
  }

  @Test func provisionsAndVerifiesTheLiveProof() throws {
    let harness = try Self.harness()
    let record = try Self.allocation(harness)
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    let after = try #require(try harness.store.allocation(record.id))
    #expect(after.readyAt != nil)
    #expect(after.networkProof?.networkPolicy == admission.expectedNetworkPolicy)
    #expect(after.provenance.qualificationDigest == admission.qualificationDigest)
    // Idempotent: a second call does not create another VM.
    try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    #expect(harness.host.state.withLock { $0.creates } == 1)
  }

  @Test func mismatchedProofIsRefusedAndMarkedForRelease() throws {
    let harness = try Self.harness()
    harness.host.state.withLock { $0.proofPolicy = String(repeating: "9", count: 64) }
    let record = try Self.allocation(harness)
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    #expect(throws: CIError.self) {
      try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    }
    #expect(try harness.store.allocation(record.id)?.desired == .release)
  }

  // C-T08: a lost create reply never duplicates resources.
  @Test func lostCreateReplyIsResolvedWithTheSameIdentity() throws {
    let harness = try Self.harness()
    let record = try Self.allocation(harness)
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    harness.host.state.withLock { _ = $0.dropReplies.insert("run.create") }
    #expect(throws: CIError.self) {
      try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    }
    let uncertain = try #require(try harness.store.allocation(record.id))
    #expect(uncertain.uncertainty != nil)
    #expect(uncertain.holdsResources)
    #expect(try harness.store.intent(record.operations.create.rawValue)?.status == .uncertain)
    harness.host.state.withLock { _ = $0.dropReplies.remove("run.create") }
    try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    #expect(harness.host.state.withLock { $0.creates } == 1)
    #expect(try harness.store.allocation(record.id)?.readyAt != nil)
  }

  @Test func neverSentCreateResolvesWithoutResources() throws {
    let harness = try Self.harness()
    let record = try Self.allocation(harness)
    try harness.driver.observe(record.id)
    let after = try #require(try harness.store.allocation(record.id))
    #expect(after.vmCleanup == .verified)
    #expect(!after.holdsResources)
  }

  // Regression: unavailable-worker cleanup debt.
  @Test func unreachableWorkerKeepsCleanupDebtAndBudget() throws {
    let harness = try Self.harness()
    let record = try Self.allocation(harness)
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    harness.host.state.withLock { $0.unreachable = true }
    #expect(throws: CIError.self) { try harness.driver.release(record.id) }
    let after = try #require(try harness.store.allocation(record.id))
    #expect(after.vmCleanup == .debt)
    #expect(after.holdsResources)
    #expect(HostLoad.of([after]).vms == 1)
    harness.host.state.withLock { $0.unreachable = false }
    try harness.driver.release(record.id)
    #expect(try harness.store.allocation(record.id)?.vmCleanup == .verified)
  }

  // Regression: an unreachable host after the discard is cleanup debt, never
  // an invented verified deletion.
  @Test func unverifiedDiscardStaysCleanupDebt() throws {
    let harness = try Self.harness()
    let record = try Self.allocation(harness)
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    try harness.driver.complete(record.id, exitStatus: 0)
    harness.host.state.withLock { $0.unreachableAfterDiscard = true }
    try harness.driver.release(record.id)
    let after = try #require(try harness.store.allocation(record.id))
    #expect(after.vmCleanup == .debt)
    #expect(after.holdsResources)
  }

  @Test func liveRetentionThenVerifiedRelease() throws {
    let harness = try Self.harness()
    let record = try Self.allocation(harness)
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    try harness.driver.retain(record.id, mode: .live, seconds: 600)
    var after = try #require(try harness.store.allocation(record.id))
    #expect(after.desired == .retainLive)
    #expect(after.retentionUntil == 5_000)
    try harness.driver.release(record.id)
    after = try #require(try harness.store.allocation(record.id))
    #expect(after.vmCleanup == .verified)
  }

  @Test func completeRecordsExportSeparatelyFromExecution() throws {
    let harness = try Self.harness()
    let record = try Self.allocation(harness)
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    // Only an operator request (`iso-ci results`) asks for results.
    #expect(try harness.driver.results(record.id, saveInto: nil)["export"] == "requested")
    #expect(try harness.store.allocation(record.id)?.export == .requested)
    try harness.driver.complete(record.id, exitStatus: 0)
    let after = try #require(try harness.store.allocation(record.id))
    #expect(after.export == .failed)
    #expect(after.execution == .pending)
    #expect(after.observedRunPhase == .stoppedDiskPendingExport)
  }

  /// Connected runners never request results: completing their run is not a
  /// failed export.
  @Test func completeWithoutARequestedExportStaysNotRequested() throws {
    let harness = try Self.harness()
    let record = try Self.allocation(harness)
    let admission = try harness.driver.admit(host: "local", profile: harness.profile)
    try harness.driver.provision(record.id, profile: harness.profile, admission: admission)
    try harness.driver.complete(record.id, exitStatus: 0)
    let after = try #require(try harness.store.allocation(record.id))
    #expect(after.export == .notRequested)
    #expect(after.observedRunPhase == .stoppedDiskPendingExport)
  }

  @Test func placementRespectsBudgetsAndQualification() throws {
    let harness = try Self.harness()
    var configuration = harness.configuration
    configuration.hosts["local"] = HostBudget(maxVMs: 1, cpus: 8, memoryMiB: 16_384, diskGiB: 256)
    let first = try HostPlacement.select(
      candidates: ["local", "other"], profile: harness.profile, configuration: configuration,
      store: harness.store, fairnessKey: "pool", now: 1_000)
    #expect(first.choice == "local")
    #expect(first.refusals.contains { $0.host == "other" })
    _ = try Self.allocation(harness)
    let second = try HostPlacement.select(
      candidates: ["local"], profile: harness.profile, configuration: configuration,
      store: harness.store,
      fairnessKey: "pool", now: 1_000)
    #expect(second.choice == nil)
  }

  // Evidence recorded after `enable` reaches placement once the snapshot
  // is refreshed; withdrawn evidence leaves placement again.
  @Test func capabilityRefreshUpdatesPlacementEligibility() throws {
    let host = FakeHost(
      capabilities: FakeHost.qualifiedCapabilities(advertise: false, status: "missing"))
    let harness = try Self.harness(host)
    let select = { () throws -> Name? in
      try HostPlacement.select(
        candidates: ["local"], profile: harness.profile, configuration: harness.configuration,
        store: harness.store, fairnessKey: "pool", now: 1_000
      ).choice
    }
    #expect(try select() == nil)
    host.state.withLock {
      $0.capabilities = FakeHost.qualifiedCapabilities(allowed: Self.reviewedHosts)
    }
    try harness.driver.hosts.refreshCapabilities("local")
    #expect(try select() == "local")
    #expect(try harness.store.events(after: 0).contains { $0.kind == "host.capabilities_changed" })
    host.state.withLock {
      $0.capabilities = FakeHost.qualifiedCapabilities(advertise: false, status: "missing")
    }
    try harness.driver.hosts.refreshCapabilities("local")
    #expect(try select() == nil)
  }

  @Test func hostIdentityChangeIsRefused() throws {
    let host = FakeHost(capabilities: FakeHost.qualifiedCapabilities(allowed: Self.reviewedHosts))
    let store = try ControllerStore.inMemory()
    try HostDirectory(store: store) { _ in host }.enable("local")
    let other = FakeHost()
    #expect(throws: CIError.self) { try HostDirectory(store: store) { _ in other }.enable("local") }
    let client = try HostDirectory(store: store) { _ in other }.client("local")
    #expect(throws: CIError.self) { _ = try client.hello() }
  }

  @Test func shellQuoting() {
    #expect(shellQuote("abc") == "abc")
    #expect(shellQuote("a b") == "'a b'")
    #expect(shellQuote("it's") == "'it'\\''s'")
    #expect(GuestCommand(["echo", "$HOME"]).rendered == "echo '$HOME'")
  }
}

@Suite struct WireValidationTests {
  // Regression: unapplied `T.init` once resolved to the non-validating
  // initializer, so malformed identifiers were accepted from the wire.
  @Test func hostRepliesRefuseMalformedIdentifiers() {
    let hello: JSONValue = [
      "protocol": "iso.host/v1", "host_id": "not-a-uuid",
      "owner_id": .string(String(repeating: "a", count: 32)),
      "daemon_epoch": "00000000-0000-4000-8000-000000000000",
      "runtime": ["status": "qualified", "detail": "x"],
      "methods": [], "guest_os": [],
    ]
    #expect(throws: CIError.self) { _ = try HelloResult(wire: hello) }
    var proof: [String: JSONValue] = [
      "transport": "brokered", "boot_id": "boot 1", "external_nic_count": 0,
      "network_policy_digest": .string(String(repeating: "1", count: 64)),
      "channel_policy_digest": .string(String(repeating: "2", count: 64)),
    ]
    #expect(throws: CIError.self) { _ = try NetworkProof(wire: .object(proof)) }
    proof["boot_id"] = "boot-1"
    proof["network_policy_digest"] = "deadbeef"
    #expect(throws: CIError.self) { _ = try NetworkProof(wire: .object(proof)) }
  }
}
