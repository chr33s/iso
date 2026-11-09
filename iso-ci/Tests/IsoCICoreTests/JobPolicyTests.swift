import Foundation
import Testing

@testable import IsoCICore

/// C-T20: the pre-assignment gate refuses before any runner, admission or VM.
@Suite struct JobPolicyTests {
  static let repository = try! RepositoryName("chr33s/iso")

  static func facts(
    event: String = "push", isPrivate: Bool = true, head: Int64? = 1, fork: Bool = false,
    actor: String? = "chr33s", triggering: String? = nil
  ) -> JobFacts {
    JobFacts(
      repository: repository.rawValue, repositoryID: 1, repositoryPrivate: isPrivate, event: event,
      actor: actor, triggeringActor: triggering, headRepositoryID: head,
      headRepositoryIsFork: fork)
  }

  static func code(_ decision: JobPolicyDecision) -> JobRejection? {
    if case .deny(let rejection, _) = decision { return rejection }
    return nil
  }

  @Test func defaultPolicyAdmitsPrivateWriteEvents() {
    for event in JobPolicy.defaultEvents {
      #expect(JobPolicyEvaluator.evaluate(Self.facts(event: event), policy: JobPolicy()) == .allow)
    }
  }

  @Test func forkPullRequestsArePerDefaultRefused() {
    let fork = Self.facts(event: "pull_request", head: 99)
    #expect(Self.code(JobPolicyEvaluator.evaluate(fork, policy: JobPolicy())) == .forkPullRequest)
    // GitHub naming no head repository for a pull request is not trusted.
    let unnamed = Self.facts(event: "pull_request", head: nil)
    #expect(
      Self.code(JobPolicyEvaluator.evaluate(unnamed, policy: JobPolicy())) == .forkPullRequest)
    let flagged = Self.facts(event: "pull_request", head: 1, fork: true)
    #expect(
      Self.code(JobPolicyEvaluator.evaluate(flagged, policy: JobPolicy())) == .forkPullRequest)
    #expect(
      JobPolicyEvaluator.evaluate(fork, policy: JobPolicy(allowForkPRs: true)) == .allow)
  }

  @Test func publicEventAndActorChecks() {
    let open = Self.facts(isPrivate: false)
    #expect(Self.code(JobPolicyEvaluator.evaluate(open, policy: JobPolicy())) == .publicRepository)
    #expect(JobPolicyEvaluator.evaluate(open, policy: JobPolicy(allowPublicRepo: true)) == .allow)
    let comment = Self.facts(event: "issue_comment")
    #expect(Self.code(JobPolicyEvaluator.evaluate(comment, policy: JobPolicy())) == .event)
    let actors = JobPolicy(allowedActors: ["chr33s"])
    #expect(JobPolicyEvaluator.evaluate(Self.facts(actor: "CHR33S"), policy: actors) == .allow)
    #expect(
      Self.code(JobPolicyEvaluator.evaluate(Self.facts(actor: "mallory"), policy: actors)) == .actor
    )
    #expect(
      Self.code(
        JobPolicyEvaluator.evaluate(Self.facts(triggering: "mallory"), policy: actors)) == .actor)
    #expect(
      Self.code(JobPolicyEvaluator.evaluate(Self.facts(actor: nil), policy: actors)) == .actor)
  }

  static func offer(_ repository: String = "chr33s/iso", event: String? = "push")
    -> ScaleSetJobMessage
  {
    ScaleSetJobMessage(
      kind: .available, runnerRequestID: 7, repository: try? RepositoryName(repository),
      workflowRunID: 42, eventName: event)
  }

  @Test func offersOutsideTheScopeOrDisagreeingWithGitHubAreRefused() {
    let scope = GitHubScope.repository(Self.repository)
    let ok: () throws(CIError) -> JobFacts = { Self.facts() }
    #expect(
      JobPolicyEvaluator.evaluate(offer: Self.offer(), scope: scope, policy: JobPolicy(), facts: ok)
        == .allow)
    #expect(
      Self.code(
        JobPolicyEvaluator.evaluate(
          offer: Self.offer("other/repo"), scope: scope, policy: JobPolicy(), facts: ok)) == .scope)
    #expect(
      Self.code(
        JobPolicyEvaluator.evaluate(
          offer: Self.offer(event: "pull_request"), scope: scope, policy: JobPolicy(), facts: ok))
        == .unverifiable)
    let failing: () throws(CIError) -> JobFacts = { throw CIError(.githubUnavailable, "down") }
    #expect(
      Self.code(
        JobPolicyEvaluator.evaluate(
          offer: Self.offer(), scope: scope, policy: JobPolicy(), facts: failing)) == .unverifiable)
    let organization = GitHubScope.organization("chr33s", runnerGroup: "ci")
    #expect(
      JobPolicyEvaluator.evaluate(
        offer: Self.offer(), scope: organization, policy: JobPolicy(), facts: ok) == .allow)
  }

  @Test func runRecordParsing() throws {
    let json = try StrictJSON.parse(
      Array(
        #"{"event":"pull_request","actor":{"login":"a"},"triggering_actor":{"login":"b"},"repository":{"id":1,"full_name":"chr33s/iso","private":true},"head_repository":{"id":2,"fork":true}}"#
          .utf8), limits: .github)
    let facts = try JobFacts(run: json)
    #expect(facts.isFork && facts.actor == "a" && facts.triggeringActor == "b")
    let missing = try StrictJSON.parse(Array(#"{"event":"push"}"#.utf8), limits: .github)
    #expect(throws: CIError.self) { try JobFacts(run: missing) }
  }
}

@Suite struct ScaleSetConfigurationTests {
  static let warmKeys = "    max_live_vms: 2\n    desired_idle_vms: 1\n"

  /// The setup template with the validation pool's capacity keys replaced
  /// by `pool`, and lines added to the validation profile and local host.
  static func yaml(pool: String, profileExtra: String = "", hostExtra: String = "") -> String {
    var text = CIConfiguration.template(repository: "chr33s/iso", host: "local")
    text = text.replacingOccurrences(of: warmKeys, with: pool)
    text = text.replacingOccurrences(
      of: "    limits: operator-approved-ci-limits\n\n  linux-preflight:",
      with: "    limits: operator-approved-ci-limits\n\(profileExtra)\n  linux-preflight:")
    text = text.replacingOccurrences(
      of: "    disk_gib: 256\n", with: "    disk_gib: 256\n\(hostExtra)")
    return text
  }

  static func scaleSetPool(
    policy: [String] = ["allow_fork_prs: false", "allowed_events: [push, pull_request]"]
  ) -> String {
    ([
      "    provisioning_mode: scaleset", "    scaleset:", "      name: iso-arm64-fast",
      "      min_runners: 0", "      max_runners: 4", "      job_policy:",
    ]
      + policy.map { "        " + $0 }).joined(separator: "\n") + "\n"
  }

  @Test func scaleSetPoolsParseWithoutWarmPoolKeys() throws {
    let configuration = try CIConfiguration.parse(Self.yaml(pool: Self.scaleSetPool()))
    let pool = try #require(configuration.pools["validation"])
    #expect(pool.provisioningMode == .scaleSet)
    #expect(pool.maxLiveVMs == 4 && pool.desiredIdleVMs == 0)
    #expect(pool.scaleSet?.jobPolicy.allowedEvents == ["pull_request", "push"])
    #expect(pool.scaleSet?.jobPolicy.allowPublicRepo == false)
    #expect(throws: CIError.self) {
      try CIConfiguration.parse(Self.yaml(pool: Self.scaleSetPool() + "    max_live_vms: 2\n"))
    }
    #expect(throws: CIError.self) {
      try CIConfiguration.parse(
        Self.yaml(pool: Self.warmKeys + "    scaleset: {name: x, min_runners: 0, max_runners: 1}\n")
      )
    }
  }

  /// Public repositories admit only write-gated events and never forks.
  @Test func publicOptInIsBounded() throws {
    #expect(throws: CIError.self) {
      try CIConfiguration.parse(
        Self.yaml(
          pool: Self.scaleSetPool(policy: ["allow_public_repo: true", "allow_fork_prs: true"])))
    }
    #expect(throws: CIError.self) {
      try CIConfiguration.parse(
        Self.yaml(
          pool: Self.scaleSetPool(policy: [
            "allow_public_repo: true", "allowed_events: [issue_comment]",
          ])))
    }
    _ = try CIConfiguration.parse(
      Self.yaml(
        pool: Self.scaleSetPool(policy: [
          "allow_public_repo: true", "allowed_events: [issue_comment]", "allowed_actors: [chr33s]",
        ])))
  }

  /// New fields leave existing descriptor digests unchanged, so existing
  /// approvals stay valid; setting them changes the digest.
  @Test func newFieldsKeepExistingDigests() throws {
    let base = try TestConfig.configuration()
    let profile = try #require(base.profiles["linux-validation"])
    #expect(!(try ControllerStore.encode(profile)).contains("exclusive"))
    let exclusive = try CIConfiguration.parse(
      Self.yaml(pool: Self.warmKeys, profileExtra: "    exclusive_host: true"))
    #expect(exclusive.profiles["linux-validation"]?.isExclusive == true)
    #expect(descriptorDigest(exclusive.profiles["linux-validation"]!) != descriptorDigest(profile))
    let pool = try #require(base.pools["validation"])
    let scaleSet = try #require(
      try CIConfiguration.parse(Self.yaml(pool: Self.scaleSetPool())).pools["validation"])
    #expect(descriptorDigest(pool) != descriptorDigest(scaleSet))
    #expect(!(try ControllerStore.encode(pool)).contains("scaleSet"))
  }

  @Test func hostReservationsAndTracking() throws {
    let configuration = try CIConfiguration.parse(
      Self.yaml(
        pool: Self.warmKeys,
        hostExtra:
          "    owner_reserved_cpus: 2\n    owner_reserved_memory_mib: 4096\n    track_external_macos_vms: true\n"
      ))
    let host = try #require(configuration.hosts["local"])
    #expect(host.ownerReservedCPUs == 2 && host.trackExternalMacOSVMs == true)
    #expect(throws: CIError.self) {
      try CIConfiguration.parse(
        Self.yaml(pool: Self.warmKeys, hostExtra: "    owner_reserved_cpus: 8\n"))
    }
  }

  /// macOS profiles parse (the scheduler models them) but never activate:
  /// CI guests are NIC-less and NET-HANDOFF-1 covers Linux only.
  @Test func macOSProfilesNeverActivate() throws {
    var configuration = try TestConfig.configuration()
    configuration.profiles["linux-validation"]?.platform = "macos/arm64"
    #expect(configuration.profiles["linux-validation"]?.guestOS == .macos)
    let report = PoolActivation.evaluate(
      pool: "validation", configuration: configuration, installation: nil,
      reader: UnreachableReader())
    #expect(report.state == .inactive)
    #expect(report.reasons.contains(PoolActivation.macOSReason))
  }
}

struct UnreachableReader: AuthorityReader {
  func installation(_ id: Int64) throws(CIError) -> GitHubInstallationInfo {
    throw CIError(.githubUnavailable, "offline")
  }
  func installationRepositories() throws(CIError) -> (
    repositories: [GitHubRepositoryInfo], truncated: Bool
  ) { throw CIError(.githubUnavailable, "offline") }
  func repository(_ repository: RepositoryName) throws(CIError) -> GitHubRepositoryInfo {
    throw CIError(.githubUnavailable, "offline")
  }
  func runnerGroups(org: String) throws(CIError) -> [GitHubRunnerGroupInfo] {
    throw CIError(.githubUnavailable, "offline")
  }
  func policy(_ path: String, of repository: RepositoryName) throws(CIError) -> JSONValue? { nil }
}

/// Spec section 4.1: the new fields are covered by `iso-ci setup --approve`.
@Suite struct SharedHostApprovalTests {
  @Test func schemaVersionsAreAccepted() throws {
    let v2 = CIConfiguration.template(repository: "chr33s/iso", host: "local")
    #expect(v2.hasPrefix("schema: iso-ci/v2"))
    _ = try CIConfiguration.parse(v2)
    _ = try CIConfiguration.parse(
      v2.replacingOccurrences(of: "schema: iso-ci/v2", with: "schema: iso-ci/v1"))
    _ = try CIConfiguration.parse(
      v2.replacingOccurrences(of: "schema: iso-ci/v2", with: "schema_version: 2"))
    _ = try CIConfiguration.parse(
      v2.replacingOccurrences(of: "schema: iso-ci/v2", with: "schema: iso-ci/v2\nschema_version: 2")
    )
    for bad in [
      "schema: iso-ci/v3", "schema_version: 3", "schema: iso-ci/v1\nschema_version: 2", "",
    ] {
      #expect(throws: CIError.self) {
        try CIConfiguration.parse(v2.replacingOccurrences(of: "schema: iso-ci/v2", with: bad))
      }
    }
  }

  @Test func hostBudgetsWithSharedHostFieldsNeedApproval() throws {
    var configuration = try TestConfig.configuration()
    #expect(configuration.hostDescriptors(["local"]).isEmpty)
    configuration.hosts["local"]?.ownerReservedCPUs = 2
    let rows = configuration.hostDescriptors(["local"])
    #expect(rows.map(\.0) == [.host] && rows.map(\.1) == ["local"])
    let store = try ControllerStore.inMemory(clock: FixedClock(value: 1_000))
    for (kind, name, digest) in configuration.descriptors(of: "linux-validation") {
      try store.save(ApprovalRecord(kind: kind, name: name, digest: digest, approvedAt: 1))
    }
    let harness = try ExecutionTests.harness()
    let frozen = configuration
    let service = ConnectedPoolService(
      store: store, provider: harness.driver, loadConfiguration: { .success(frozen) },
      clients: { (_) throws(CIError) -> GitHubInstallationClient in
        throw CIError(.githubUnavailable, "offline in tests")
      },
      api: GitHubAPI(http: ScriptedGitHubHTTP()), credentials: MemoryCredentialStore())
    service.reconcile(now: 1_000)
    #expect(
      try store.poolStatus("validation")?.reason?.contains("host local is not approved") == true)
    try store.save(ApprovalRecord(kind: .host, name: "local", digest: rows[0].2, approvedAt: 2))
    service.reconcile(now: 1_001)
    // Approved: the gate moves on to the (unconnected) installation.
    #expect(try store.poolStatus("validation")?.reason?.contains("installation") == true)
  }
}
