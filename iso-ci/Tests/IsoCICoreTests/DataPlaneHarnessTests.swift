import Foundation
import Security
import Synchronization
import Testing

@testable import IsoCICore

/// Shared harness for the data-plane tests: an in-memory object store, the
/// broker, and the endpoint service linked in-process (the confined child
/// path is covered separately).

struct DPScripts: SyntheticStepScripts {
  func script(for kind: StepKind, snapshot: Digest?) -> String? {
    switch kind {
    case .syntheticCheckout: "echo checkout"
    case .snapshotOverlay: "echo overlay \(snapshot?.rawValue ?? "")"
    default: nil
    }
  }
}

struct DPRunner {
  let config: GuestEndpointConfig
  let clientID: String
  let audience: String
  let key: SecKey
  let files: [String: JSONValue]
}

final class DPHarness: Sendable {
  let root: String
  let clock: TestClock
  let store: ObjectStore
  let broker: DataPlaneBroker
  let service: DataPlaneService
  let childStaging: String

  init(settings: DataPlaneService.Settings = .fast) async throws {
    root = scratchDirectory("dp")
    try PrivateFiles.ensureDirectory(root)
    clock = TestClock(1_900_000_000)
    store = try ObjectStore(
      database: try Database(path: ":memory:"), objects: root + "/objects",
      staging: root + "/staging",
      clock: clock)
    childStaging = root + "/child"
    broker = DataPlaneBroker(store: store, childStaging: childStaging, scripts: DPScripts())
    service = try DataPlaneService(
      backend: broker, staging: childStaging, clock: clock, settings: settings)
    try await broker.attach(service)
  }

  deinit { PrivateFiles.removeTree(root) }

  static let limits = LimitsDescriptor(
    cpus: 2, memoryMiB: 2_048, diskGiB: 16, bootSeconds: 60, idleSeconds: 60, jobSeconds: 600,
    hardDeadlineSeconds: 900, stopGraceSeconds: 10, exportGraceSeconds: 10, outputBytes: 1 << 20,
    logBytes: 64 << 10, trafficBytes: 64 << 20, liveRetentionSeconds: 60,
    stoppedRetentionSeconds: 60)

  static func scope(_ repository: String = "octo/demo", authority: String = "validation")
    -> ObjectStore.CacheScope
  {
    ObjectStore.CacheScope(
      repository: repository, authority: authority, platform: "linux/arm64", imageDigest: "img",
      toolchain: "tc", inputDigest: "lock", confinedToRun: nil)
  }

  static func plan(steps: [StepPlan] = DPHarness.defaultSteps, needs: [String] = []) -> (
    WorkflowPlan, JobPlan
  ) {
    let job = JobPlan(
      key: "build", jobID: "build", displayName: "build", needs: needs, needsJobIDs: needs,
      condition: "success()", runsOn: ["ubuntu-latest"], platform: "linux/arm64", matrix: nil,
      strategy: StrategyContext(failFast: true, jobIndex: 0, jobTotal: 1, maxParallel: 1),
      env: [TemplateEntry(key: "CI", value: .string("true"))],
      defaults: RunDefaults(shell: "bash", workingDirectory: nil),
      timeoutMinutes: 10, continueOnError: false, container: nil, services: [:], steps: steps,
      outputs: [TemplateEntry(key: "version", value: .expression("steps.v.outputs.version"))],
      secretNames: [])
    let plan = WorkflowPlan(
      name: "CI", workflowPath: ".github/workflows/ci.yml", workflowDigest: Digest(hashing: "wf"),
      event: "push", eventPayload: ["ref": "refs/heads/main"], env: [],
      defaults: RunDefaults(shell: nil, workingDirectory: nil),
      jobs: [job], manifestID: "local-actions/v1", manifestDigest: Digest(hashing: "m"),
      actions: [],
      platformMappings: ["ubuntu-latest": "linux/arm64"])
    return (plan, job)
  }

  static let defaultSteps: [StepPlan] = [
    StepPlan(
      contextName: "__actions_checkout", name: nil, kind: .syntheticCheckout(path: "."), env: [],
      condition: "success()", continueOnError: .bool(false), timeoutMinutes: nil, synthetic: true),
    StepPlan(
      contextName: "__overlay", name: nil, kind: .snapshotOverlay(path: "."), env: [],
      condition: "success()", continueOnError: .bool(false), timeoutMinutes: nil, synthetic: true),
    StepPlan(
      contextName: "v", name: .string("Version"),
      kind: .run(
        script: .expression("format('echo {0}', env.CI)"), shell: nil, workingDirectory: nil),
      env: [], condition: "success()", continueOnError: .bool(false), timeoutMinutes: .number(5),
      synthetic: false),
    StepPlan(
      contextName: "__actions_cache", name: nil,
      kind: .uses(
        .repository(owner: "actions", repository: "cache", path: nil, ref: "v4"),
        with: [TemplateEntry(key: "path", value: .string("~/.npm"))]),
      env: [], condition: "success()", continueOnError: .bool(false), timeoutMinutes: nil,
      synthetic: false),
  ]

  /// Registers one allocation and decodes its runner material as the
  /// guest would receive it.
  func register(
    run: PreflightRunID = PreflightRunID.generate(),
    attempt: JobAttemptID = JobAttemptID.generate(),
    authority: Authority = .validation, snapshot: Digest? = nil, actions: [ResolvedAction] = [],
    dependencies: Set<JobAttemptID> = [], scope: ObjectStore.CacheScope = DPHarness.scope(),
    limits: LimitsDescriptor = DPHarness.limits, secrets: [String: String] = [:]
  ) async throws -> (AllocationID, DataPlaneRegistration, DPRunner) {
    let (plan, job) = Self.plan()
    let allocation = AllocationID.generate()
    let registration = DataPlaneRegistration(
      allocation: allocation, attempt: attempt, run: run, authority: authority, plan: plan,
      job: job,
      contexts: JobMessageBuilder.Contexts(
        repository: "octo/demo", sha: String(repeating: "a", count: 40), ref: "refs/heads/main",
        runID: 7),
      secrets: secrets, snapshot: snapshot, actions: actions, dependencyAttempts: dependencies,
      cacheScope: scope,
      limits: limits, guestPort: 41_000, expiresAt: clock.now() + 900,
      runnerName: "iso-ci-\(allocation.short)")
    let config = try await broker.register(registration)
    let jit = try #require(Data(base64Encoded: config.jitConfig))
    let files = try StrictJSON.parse(Array(jit), limits: .guestRequest)
    var decoded: [String: JSONValue] = [:]
    var rsa: [UInt8] = []
    for name in [".runner", ".credentials", ".credentials_rsaparams"] {
      let bytes = try #require(files[name]?.stringValue.flatMap { Data(base64Encoded: $0) })
      if name == ".credentials_rsaparams" { rsa = Array(bytes) }
      decoded[name] = try StrictJSON.parse(Array(bytes), limits: .guestRequest)
    }
    let credentials = try #require(decoded[".credentials"])
    let runner = DPRunner(
      config: config, clientID: try #require(credentials["Data"]?["clientId"]?.stringValue),
      audience: try #require(credentials["Data"]?["authorizationUrl"]?.stringValue),
      key: try RunnerKeyPair.privateKey(fromRunnerJSON: rsa), files: decoded)
    return (allocation, registration, runner)
  }

  /// A client assertion as `VssOAuthJwtBearerAssertion` builds it.
  static func assertion(
    key: SecKey, clientID: String, audience: String, now: Int64, lifetime: Int64 = 300,
    jti: String = UUID().uuidString
  ) -> String {
    let header = Base64URL.encode(JSONValue.object(["alg": "RS256", "typ": "JWT"]).canonical)
    let claims: JSONValue = [
      "iss": .string(clientID), "sub": .string(clientID), "aud": .string(audience),
      "nbf": .integer(now),
      "exp": .integer(now + lifetime), "iat": .integer(now), "jti": .string(jti),
    ]
    let input = header + "." + Base64URL.encode(claims.canonical)
    var error: Unmanaged<CFError>?
    let signature =
      SecKeyCreateSignature(
        key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, &error) as Data?
    return input + "." + Base64URL.encode(Array(signature ?? Data()))
  }

  func request(
    _ method: String, _ target: String, bearer: String? = nil, json: JSONValue? = nil,
    body: [UInt8]? = nil,
    headers: [String: String] = [:]
  ) async -> DataPlaneResponse {
    var all = headers
    if let bearer { all["Authorization"] = "Bearer " + bearer }
    let payload = body ?? json.map(\.canonical) ?? []
    return await service.handle(
      DataPlaneRequest(method: method, target: target, headers: all, body: payload))
  }

  /// Signs in and acquires the job; returns (runner token, job token, job message).
  func acquire(_ runner: DPRunner) async throws -> (String, String, JSONValue) {
    let assertion = Self.assertion(
      key: runner.key, clientID: runner.clientID, audience: runner.audience, now: Int64(clock.now())
    )
    let form =
      "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=\(assertion)"
    let token = await request("POST", "/_apis/oauth2/token", body: Array(form.utf8))
    #expect(token.status == 200)
    let runnerToken = try #require(token.json?["access_token"]?.stringValue)
    let session = await request(
      "POST", "/broker/session", bearer: runnerToken, json: ["agent": ["id": 1]])
    let sessionID = try #require(session.json?["sessionId"]?.stringValue)
    let message = await request(
      "GET", "/broker/message?sessionId=\(sessionID)", bearer: runnerToken)
    let reference = try StrictJSON.parse(
      try #require(message.json?["body"]?.stringValue), limits: .guestRequest)
    let jobID = try #require(reference["runner_request_id"]?.stringValue)
    let acquired = await request(
      "POST", "/run/acquirejob", bearer: runnerToken, json: ["jobMessageId": .string(jobID)])
    #expect(acquired.status == 200)
    let job = try #require(acquired.json)
    let jobToken = try #require(
      job["resources"]?["endpoints"]?.arrayValue?.first?["authorization"]?["parameters"]?[
        "AccessToken"]?.stringValue)
    return (runnerToken, jobToken, job)
  }

  /// Turns an absolute signed URL into a request target.
  static func target(_ url: String) -> String {
    guard let range = url.range(of: "://") else { return url }
    let rest = url[range.upperBound...]
    return String(rest[(rest.firstIndex(of: "/") ?? rest.endIndex)...])
  }
}

extension DataPlaneService.Settings {
  static var fast: DataPlaneService.Settings {
    var settings = DataPlaneService.Settings()
    settings.pollInterval = .milliseconds(10)
    settings.pollTimeout = .milliseconds(50)
    return settings
  }
}

/// Collects notices for assertions.
func dpNextNotice(_ broker: DataPlaneBroker, where match: (DataPlaneNotice) -> Bool) async
  -> DataPlaneNotice?
{
  for await notice in broker.notices where match(notice) { return notice }
  return nil
}

@Suite struct DataPlaneHarnessTests {
  @Test func runnerMaterialIsSelfConsistent() async throws {
    let harness = try await DPHarness()
    let (_, _, runner) = try await harness.register()
    let settings = try #require(runner.files[".runner"])
    #expect(settings["UseV2Flow"] == .bool(true))
    #expect(settings["ServerUrl"] == settings["ServerUrlV2"])
    #expect(settings["Ephemeral"] == .bool(true))
    #expect(settings["DisableUpdate"] == .bool(true))
    #expect(settings["IsHostedServer"] == .bool(false))
    #expect(runner.audience == "http://127.0.0.1:41000/_apis/oauth2/token")
    let rsa = try #require(runner.files[".credentials_rsaparams"])
    let modulus = try #require(rsa["modulus"]?.stringValue.flatMap { Data(base64Encoded: $0) })
    let d = try #require(rsa["d"]?.stringValue.flatMap { Data(base64Encoded: $0) })
    let p = try #require(rsa["p"]?.stringValue.flatMap { Data(base64Encoded: $0) })
    // .NET RSA.ImportParameters requires these exact lengths.
    #expect(modulus.count == 256)
    #expect(d.count == modulus.count)
    #expect(p.count == modulus.count / 2)
  }
}
