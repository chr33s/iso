import Foundation
import Security
import Testing

@testable import IsoCICore

@Suite struct DataPlaneProtocolTests {
  static func fixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.resourceURL?.appending(path: "Fixtures/dataplane/\(name)"))
    return try StrictJSON.parse(
      Array(try Data(contentsOf: url)), limits: JSONLimits(maxBytes: 1 << 20))
  }

  static func substitute(_ value: JSONValue, _ variables: [String: String]) -> JSONValue {
    switch value {
    case .string(var text):
      for (name, replacement) in variables {
        text = text.replacingOccurrences(of: "${\(name)}", with: replacement)
      }
      return .string(text)
    case .array(let items): return .array(items.map { substitute($0, variables) })
    case .object(let members): return .object(members.mapValues { substitute($0, variables) })
    default: return value
    }
  }

  // MARK: Fixture replay

  @Test func replaysTheRunnerJobLifecycleFixture() async throws {
    let harness = try await DPHarness()
    let (allocation, registration, runner) = try await harness.register()
    let fixture = try Self.fixture("runner-v2.338.0-job-lifecycle.json")
    #expect(fixture["runner_version"] == "2.338.0")
    let identity = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    var variables = [
      "PLAN_ID": identity.planID.uuidString.lowercased(),
      "JOB_ID": identity.jobID.uuidString.lowercased(),
    ]
    let assertion = DPHarness.assertion(
      key: runner.key, clientID: runner.clientID, audience: runner.audience,
      now: Int64(harness.clock.now()))
    let form =
      "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=\(assertion)"
    let oauth = await harness.request("POST", "/_apis/oauth2/token", body: Array(form.utf8))
    #expect(oauth.status == 200)
    #expect(oauth.json?["token_type"] == "Bearer")
    let runnerToken = try #require(oauth.json?["access_token"]?.stringValue)
    var jobToken: String?
    for step in try #require(fixture["steps"]?.arrayValue) {
      let step = Self.substitute(step, variables)
      let name = step["name"]?.stringValue ?? "?"
      let bearer: String? =
        switch step["auth"]?.stringValue {
        case "runner": runnerToken
        case "job": jobToken
        default: nil
        }
      var headers: [String: String] = [:]
      if case .object(let members)? = step["headers"] {
        for (key, value) in members { headers[key] = value.stringValue }
      }
      let path = try #require(step["path"]?.stringValue)
      let response = await harness.request(
        try #require(step["method"]?.stringValue),
        path.hasPrefix("http") ? DPHarness.target(path) : path,
        bearer: bearer, json: step["body"],
        body: step["raw_body"]?.stringValue.map { Array($0.utf8) }, headers: headers)
      let expect = try #require(step["expect"])
      #expect(Int64(response.status) == expect["status"]?.intValue, "\(name)")
      if case .object(let equals)? = expect["equals"] {
        for (key, value) in equals { #expect(response.json?[key] == value, "\(name): \(key)") }
      }
      for key in expect["keys"]?.arrayValue ?? [] {
        #expect(response.json?[key.stringValue ?? ""] != nil, "\(name): \(key)")
      }
      if case .object(let captures)? = step["capture"] {
        for (variable, field) in captures {
          variables[variable] = response.json?[field.stringValue ?? ""]?.stringValue
        }
      }
      if case .object(let captures)? = step["capture_url"] {
        for (variable, field) in captures {
          variables[variable] = response.json?[field.stringValue ?? ""]?.stringValue
        }
      }
      if name == "acquire job" {
        jobToken =
          response.json?["resources"]?["endpoints"]?.arrayValue?.first?["authorization"]?[
            "parameters"]?["AccessToken"]?.stringValue
      }
    }
    // The completion reached the controller once, with the reported outputs.
    let completion = await dpNextNotice(harness.broker) {
      if case .completed = $0.event { return true }
      return false
    }
    guard case .completed(let result)? = completion?.event else {
      Issue.record("no completion")
      return
    }
    #expect(completion?.allocation == allocation)
    #expect(result.conclusion == "succeeded")
    #expect(result.outputs == ["version": "1.2.3"])
    #expect(result.steps.first?.conclusion == "success")
    #expect(completion?.logs.count == 1)
    #expect(completion?.logs.first?.kind == .job)
  }

  // MARK: OAuth client assertion

  /// A used assertion id stays refused for as long as the assertion could
  /// verify, however many others follow; the set is bounded by refusing new
  /// ids, and ids are forgotten only once their window has closed.
  @Test func usedAssertionsStayRefusedUntilTheyExpire() async throws {
    var settings = DataPlaneService.Settings.fast
    settings.maxAssertionsPerWindow = 4
    let harness = try await DPHarness(settings: settings)
    let (_, _, runner) = try await harness.register()
    func token(_ assertion: String) async -> Int {
      let form =
        "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=\(assertion)"
      return await harness.request("POST", "/_apis/oauth2/token", body: Array(form.utf8)).status
    }
    func fresh() -> String {
      DPHarness.assertion(
        key: runner.key, clientID: runner.clientID, audience: runner.audience,
        now: Int64(harness.clock.now()))
    }
    let first = fresh()
    #expect(await token(first) == 200)
    for _ in 0..<3 { #expect(await token(fresh()) == 200) }
    // Full: a new id is refused rather than evicting a live one.
    #expect(await token(fresh()) == 429)
    #expect(await token(first) == 401)
    // Past the first window (lifetime 300 plus skew), ids are pruned.
    harness.clock.advance(EpochSeconds(300 + ClientAssertionVerifier.clockSkew + 1))
    #expect(await token(fresh()) == 200)
  }

  /// A flood of bad client assertions gets the endpoint-wide 429.
  @Test func oauthRefusalsCountAgainstTheAnonymousBudget() async throws {
    let harness = try await DPHarness()
    _ = try await harness.register()
    let form =
      "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=a.b.c"
    var statuses: [Int] = []
    for _ in 0..<(DataPlaneService.Settings().maxAnonymousPerSecond + 1) {
      statuses.append(
        await harness.request("POST", "/_apis/oauth2/token", body: Array(form.utf8)).status)
    }
    #expect(statuses.dropLast().allSatisfy { $0 == 401 })
    #expect(statuses.last == 429)
  }

  @Test func oauthRequiresAFreshAssertionSignedByTheAllocationKey() async throws {
    let harness = try await DPHarness()
    let (_, _, runner) = try await harness.register()
    let (_, _, other) = try await harness.register()
    let now = Int64(harness.clock.now())
    func token(_ assertion: String) async -> Int {
      let form =
        "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=\(assertion)"
      return await harness.request("POST", "/_apis/oauth2/token", body: Array(form.utf8)).status
    }
    let good = DPHarness.assertion(
      key: runner.key, clientID: runner.clientID, audience: runner.audience, now: now)
    #expect(await token(good) == 200)
    // Replay of the same jti.
    #expect(await token(good) == 401)
    // Expired.
    #expect(
      await token(
        DPHarness.assertion(
          key: runner.key, clientID: runner.clientID, audience: runner.audience, now: now - 4_000))
        == 401)
    // Overlong lifetime.
    #expect(
      await token(
        DPHarness.assertion(
          key: runner.key, clientID: runner.clientID, audience: runner.audience, now: now,
          lifetime: 86_400)) == 401)
    // Wrong audience.
    #expect(
      await token(
        DPHarness.assertion(
          key: runner.key, clientID: runner.clientID, audience: "http://x/", now: now))
        == 401)
    // Another allocation's key presenting this allocation's client id.
    #expect(
      await token(
        DPHarness.assertion(
          key: other.key, clientID: runner.clientID, audience: runner.audience, now: now))
        == 401)
    // A random key.
    let (stranger, _) = try RunnerKeyPair.generateKey()
    #expect(
      await token(
        DPHarness.assertion(
          key: stranger, clientID: runner.clientID, audience: runner.audience, now: now))
        == 401)
  }

  @Test func runnerTokenCannotReachJobRoutesAndJobTokenIsScoped() async throws {
    let harness = try await DPHarness()
    let (_, registrationA, runnerA) = try await harness.register()
    let (_, registrationB, runnerB) = try await harness.register()
    let (runnerTokenA, jobTokenA, _) = try await harness.acquire(runnerA)
    let (_, jobTokenB, _) = try await harness.acquire(runnerB)
    let idA = JobMessageBuilder.Identity(attempt: registrationA.attempt, run: registrationA.run)
    let idB = JobMessageBuilder.Identity(attempt: registrationB.attempt, run: registrationB.run)
    let renewA: JSONValue = [
      "planId": .string(idA.planID.uuidString.lowercased()),
      "jobId": .string(idA.jobID.uuidString.lowercased()),
    ]
    #expect(
      await harness.request("POST", "/run/renewjob", bearer: jobTokenA, json: renewA).status == 200)
    // The runner token is not a job token.
    #expect(
      await harness.request("POST", "/run/renewjob", bearer: runnerTokenA, json: renewA).status
        == 401)
    // B's job token cannot touch A's job (C-T11: no cross-attempt control access).
    #expect(
      await harness.request("POST", "/run/renewjob", bearer: jobTokenB, json: renewA).status == 404)
    let completeA: JSONValue = [
      "planId": .string(idA.planID.uuidString.lowercased()),
      "jobId": .string(idA.jobID.uuidString.lowercased()),
      "conclusion": "failed",
    ]
    #expect(
      await harness.request("POST", "/run/completejob", bearer: jobTokenB, json: completeA).status
        == 404)
    // Results routes refuse foreign backend ids.
    let foreign: JSONValue = [
      "workflow_run_backend_id": .string(idA.planID.uuidString.lowercased()),
      "workflow_job_run_backend_id": .string(idA.jobID.uuidString.lowercased()),
    ]
    #expect(
      await harness.request(
        "POST", "/twirp/results.services.receiver.Receiver/GetJobLogsSignedBlobURL",
        bearer: jobTokenB, json: foreign
      ).status == 403)
    _ = idB
    // A forged token is refused.
    #expect(
      await harness.request("POST", "/run/renewjob", bearer: jobTokenA + "x", json: renewA).status
        == 401)
  }

  @Test func cancellationIsDeliveredAsJobCancelAfterAcquire() async throws {
    let harness = try await DPHarness()
    let (allocation, _, runner) = try await harness.register()
    let assertion = DPHarness.assertion(
      key: runner.key, clientID: runner.clientID, audience: runner.audience,
      now: Int64(harness.clock.now()))
    let form =
      "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=\(assertion)"
    let token = try #require(
      await harness.request("POST", "/_apis/oauth2/token", body: Array(form.utf8)).json?[
        "access_token"]?.stringValue)
    let session = try #require(
      await harness.request("POST", "/broker/session", bearer: token, json: ["agent": [:]]).json?[
        "sessionId"]?
        .stringValue)
    let first = await harness.request("GET", "/broker/message?sessionId=\(session)", bearer: token)
    #expect(first.json?["messageType"] == "RunnerJobRequest")
    let reference = try StrictJSON.parse(
      try #require(first.json?["body"]?.stringValue), limits: .guestRequest)
    let jobID = try #require(reference["runner_request_id"]?.stringValue)
    #expect(
      await harness.request(
        "POST", "/run/acquirejob", bearer: token, json: ["jobMessageId": .string(jobID)]
      ).status
        == 200)
    // Nothing more to deliver: the long poll ends empty.
    #expect(
      await harness.request("GET", "/broker/message?sessionId=\(session)", bearer: token).status
        == 202)
    await harness.broker.cancel(allocation)
    let cancel = await harness.request("GET", "/broker/message?sessionId=\(session)", bearer: token)
    #expect(cancel.json?["messageType"] == "JobCancel")
    let body = try StrictJSON.parse(
      try #require(cancel.json?["body"]?.stringValue), limits: .guestRequest)
    #expect(body["jobId"]?.stringValue == jobID)
    // Delivered once.
    #expect(
      await harness.request("GET", "/broker/message?sessionId=\(session)", bearer: token).status
        == 202)
    // A wrong session id never receives messages.
    #expect(
      await harness.request("GET", "/broker/message?sessionId=\(UUID().uuidString)", bearer: token)
        .status == 404)
  }

  // MARK: Actions and snapshot routes

  @Test func approvedActionsResolveAndUnapprovedDoNot() async throws {
    let harness = try await DPHarness()
    let archive = try harness.store.importBytes(Array("tarball-bytes".utf8), kind: .actionArchive)
    let commit = String(repeating: "c", count: 40)
    let action = ResolvedAction(
      nameWithOwner: "actions/cache", ref: "v4", commit: commit, archiveDigest: archive)
    let (_, registration, runner) = try await harness.register(actions: [action])
    let (_, jobToken, _) = try await harness.acquire(runner)
    let id = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    let path =
      "/actions/build/\(id.planID.uuidString.lowercased())/jobs/\(id.jobID.uuidString.lowercased())/runnerresolve/actions"
    let resolved = await harness.request(
      "POST", path, bearer: jobToken,
      json: ["actions": [["action": "actions/cache", "version": "v4", "path": ""]]])
    #expect(resolved.status == 200)
    let info = try #require(resolved.json?["actions"]?["actions/cache@v4"])
    #expect(info["resolved_sha"] == .string(commit))
    let url = try #require(info["tar_url"]?.stringValue)
    let token = try #require(info["authentication"]?["token"]?.stringValue)
    let basic = "Basic " + Data("x-access-token:\(token)".utf8).base64EncodedString()
    let download = await harness.request(
      "GET", DPHarness.target(url), headers: ["Authorization": basic])
    #expect(download.status == 200)
    guard case .file(let file, _, let length) = download.body else {
      Issue.record("expected a file body")
      return
    }
    #expect(length == 13)
    #expect(try PrivateFiles.read(file, limit: 100) == Array("tarball-bytes".utf8))
    PrivateFiles.remove(file)
    // Another commit of the same action is not served.
    let wrong = DPHarness.target(url).replacingOccurrences(
      of: commit, with: String(repeating: "d", count: 40))
    #expect(await harness.request("GET", wrong, headers: ["Authorization": basic]).status == 404)
    // An unapproved action is a resolution error (422), never a download.
    let refused = await harness.request(
      "POST", path, bearer: jobToken,
      json: ["actions": [["action": "evil/action", "version": "v1", "path": ""]]])
    #expect(refused.status == 422)
    #expect(refused.json?["errors"]?["evil/action@v1"] != nil)
    // The job token is not the archive token.
    #expect(
      await harness.request(
        "GET", DPHarness.target(url),
        headers: [
          "Authorization": "Basic " + Data("x-access-token:\(jobToken)".utf8).base64EncodedString()
        ]
      ).status == 401)
  }

  @Test func snapshotRouteServesOnlyTheGrantedSnapshot() async throws {
    let harness = try await DPHarness()
    let snapshot = try harness.store.importBytes(Array("snapshot-A".utf8), kind: .snapshot)
    let other = try harness.store.importBytes(Array("snapshot-B".utf8), kind: .snapshot)
    let (_, _, runnerA) = try await harness.register(snapshot: snapshot)
    let (_, _, runnerB) = try await harness.register(snapshot: other)
    let ok = await harness.request(
      "GET", "/_iso/snapshot/\(snapshot.rawValue)", bearer: runnerA.config.isoToken)
    #expect(ok.status == 200)
    if case .file(let path, _, _) = ok.body {
      #expect(try PrivateFiles.read(path, limit: 64) == Array("snapshot-A".utf8))
      PrivateFiles.remove(path)
    }
    // Digest knowledge alone never authorizes (B's digest with A's token).
    #expect(
      await harness.request(
        "GET", "/_iso/snapshot/\(other.rawValue)", bearer: runnerA.config.isoToken
      ).status == 403)
    #expect(
      await harness.request("GET", "/_iso/snapshot/\(snapshot.rawValue)", bearer: "nope").status
        == 401)
    let b = await harness.request(
      "GET", "/_iso/snapshot/\(other.rawValue)", bearer: runnerB.config.isoToken)
    #expect(b.status == 200)
    if case .file(let path, _, _) = b.body { PrivateFiles.remove(path) }
  }

  // MARK: Job message

  @Test func jobMessageCarriesTheRunnersTokenFormats() throws {
    let (plan, job) = DPHarness.plan()
    let attempt = JobAttemptID.generate()
    let run = PreflightRunID.generate()
    let snapshot = Digest(hashing: "snap")
    let message = try JobMessageBuilder.build(
      plan: plan, job: job, attempt: attempt, run: run,
      contexts: JobMessageBuilder.Contexts(
        repository: "octo/demo", sha: String(repeating: "a", count: 40), ref: "refs/heads/main",
        runID: 1),
      endpoint: JobMessageBuilder.Endpoint(guestPort: 41_000), secrets: ["NPM_TOKEN": "s3cr3t"],
      syntheticScripts: DPScripts(), snapshot: snapshot)
    #expect(message["messageType"] == "RunnerJobRequest")
    let steps = try #require(message["steps"]?.arrayValue)
    #expect(steps.count == 4)
    // Synthetic steps are visible script steps with the scoped endpoint env.
    #expect(steps[0]["reference"]?["type"] == "script")
    #expect(steps[0]["displayNameToken"] == "iso-ci checkout (snapshot base commit)")
    // POSIX sh, so synthetic steps also run in minimal (busybox) containers.
    #expect(
      steps[0]["inputs"]?["map"]?.arrayValue?.contains([
        "Key": "shell", "Value": "sh -e {0}",
      ]) == true)
    let overlayEnv = try #require(steps[1]["environment"]?["map"]?.arrayValue)
    #expect(
      overlayEnv.contains([
        "Key": "ISO_CI_TOKEN", "Value": ["type": 3, "expr": "secrets.ISO_CI_TOKEN"],
      ]))
    #expect(overlayEnv.contains(["Key": "ISO_CI_SNAPSHOT", "Value": .string(snapshot.rawValue)]))
    // Script step: inputs mapping with a basic-expression token.
    #expect(
      steps[2]["inputs"]
        == [
          "type": 2,
          "map": [["Key": "script", "Value": ["type": 3, "expr": "format('echo {0}', env.CI)"]]],
        ])
    #expect(steps[2]["timeoutInMinutes"] == 5)
    #expect(steps[2]["contextName"] == "v")
    // Repository action reference.
    #expect(
      steps[3]["reference"]
        == [
          "type": "repository", "name": "actions/cache", "ref": "v4", "repositoryType": "GitHub",
          "path": "",
        ])
    // Secrets are secret variables; the GitHub token is a masked local placeholder.
    #expect(message["variables"]?["NPM_TOKEN"] == ["value": "s3cr3t", "isSecret": true])
    #expect(message["variables"]?["system.github.token"]?["isSecret"] == true)
    // Context data uses the pipeline-context-data form.
    #expect(message["contextData"]?["github"]?["t"] == 2)
    // No OIDC: no GenerateIdTokenUrl anywhere in the endpoint data.
    let data = try #require(message["resources"]?["endpoints"]?.arrayValue?.first?["data"])
    #expect(data["GenerateIdTokenUrl"] == nil)
    #expect(data["CacheServerUrl"] == "http://127.0.0.1:41000/cache/")
    #expect(
      message["jobOutputs"] == [
        "type": 2,
        "map": [["Key": "version", "Value": ["type": 3, "expr": "steps.v.outputs.version"]]],
      ])
    #expect(
      message["environmentVariables"] == [["type": 2, "map": [["Key": "CI", "Value": "true"]]]])
    #expect(
      message["defaults"] == [
        [
          "type": 2,
          "map": [
            ["Key": "run", "Value": ["type": 2, "map": [["Key": "shell", "Value": "bash"]]]]
          ],
        ]
      ])
    // Reserved secret names are refused.
    #expect(throws: CIError.self) {
      try JobMessageBuilder.build(
        plan: plan, job: job, attempt: attempt, run: run,
        contexts: JobMessageBuilder.Contexts(
          repository: "o/r", sha: "x", ref: "refs/heads/main", runID: 1),
        endpoint: JobMessageBuilder.Endpoint(guestPort: 1), secrets: ["ISO_CI_TOKEN": "x"],
        syntheticScripts: DPScripts(), snapshot: nil)
    }
    // The placeholder is replaced structurally, once.
    let filled = try JobMessageBuilder.withAccessToken(message, token: "tok")
    #expect(
      filled["resources"]?["endpoints"]?.arrayValue?.first?["authorization"]?["parameters"]?[
        "AccessToken"] == "tok")
    #expect(throws: CIError.self) { try JobMessageBuilder.withAccessToken(filled, token: "again") }
  }

  /// Containers reach the endpoint on Docker's gateway, so every URL the job
  /// sees must name it when the image has Docker.
  @Test func endpointURLsNameTheChosenGuestHost() {
    let loopback = JobMessageBuilder.Endpoint(guestPort: 41_000)
    let gateway = JobMessageBuilder.Endpoint(host: .dockerGateway, guestPort: 41_000)
    #expect(loopback.base == "http://127.0.0.1:41000/")
    #expect(gateway.base == "http://172.17.0.1:41000/")
    #expect(gateway.runService == "http://172.17.0.1:41000/run/")
    #expect(gateway.oauth == "http://172.17.0.1:41000/_apis/oauth2/token")
    #expect(gateway.serverURL == loopback.serverURL)
  }

  @Test func templateTokensAndContextDataMatchTheRunnerConverters() {
    #expect(JobMessageBuilder.token(.string("a")) == "a")
    #expect(JobMessageBuilder.token(.bool(true)) == true)
    #expect(JobMessageBuilder.token(.number(3)) == 3)
    #expect(JobMessageBuilder.token(.number(1.5)) == .double(1.5))
    #expect(JobMessageBuilder.token(.null) == .null)
    #expect(JobMessageBuilder.token(.sequence([])) == ["type": 1])
    #expect(JobMessageBuilder.token(.sequence([.string("x")])) == ["type": 1, "seq": ["x"]])
    #expect(JobMessageBuilder.token(.mapping([])) == ["type": 2])
    #expect(
      JobMessageBuilder.contextValue(["b": [1, "x"], "a": true]) == [
        "t": 2, "d": [["k": "a", "v": true], ["k": "b", "v": ["t": 1, "a": [1, "x"]]]],
      ])
  }

  // MARK: Channel schema

  @Test func framesRoundTrip() throws {
    let allocation = AllocationID.generate()
    let grant = DataPlaneGrant(
      allocation: allocation, attempt: .generate(), clientID: UUID().uuidString.lowercased(),
      runnerPublicKeyDER: [UInt8](repeating: 1, count: 270), isoVerifier: Digest(hashing: "x"),
      guestPort: 9,
      planID: UUID().uuidString.lowercased(), jobID: UUID().uuidString.lowercased(),
      jobMessage: ["a": 1],
      expiresAt: 5, trafficBytes: 1, uploadBytes: 2, logBytes: 3)
    let gatewayGrant = DataPlaneGrant(
      allocation: allocation, attempt: .generate(), clientID: UUID().uuidString.lowercased(),
      runnerPublicKeyDER: [UInt8](repeating: 1, count: 270), isoVerifier: Digest(hashing: "x"),
      guestHost: .dockerGateway, guestPort: 9,
      planID: UUID().uuidString.lowercased(), jobID: UUID().uuidString.lowercased(),
      jobMessage: ["a": 1],
      expiresAt: 5, trafficBytes: 1, uploadBytes: 2, logBytes: 3)
    let calls: [DataPlaneCall] = [
      .resolveActions([.init(action: "a/b", version: "v1", path: "")]),
      .openAction(nameWithOwner: "a/b", commit: String(repeating: "f", count: 40)),
      .openSnapshot(Digest(hashing: "s")), .cacheLookup(keys: ["k", "k-"], version: "v"),
      .openCache(handle: randomHex(bytes: 16)), .cacheReserve(key: "k", version: "v"),
      .cacheCommit(cacheID: 3, file: randomHex(bytes: 16), size: 4), .artifactCreate(name: "dist"),
      .artifactFinalize(id: 2, file: randomHex(bytes: 16), size: 9, hash: Digest(hashing: "h")),
      .artifactList(nameFilter: "dist", idFilter: 2), .openArtifact(id: 2),
      .logCommit(
        kind: .step, step: UUID().uuidString.lowercased(), file: randomHex(bytes: 16), lines: 3),
    ]
    var frames: [DataPlaneFrame] = [
      .register(id: 1, grant: grant), .register(id: 2, grant: gatewayGrant),
      .unregister(allocation), .cancel(allocation), .shutdown,
      .ready,
      .reply(id: 4, result: .success(["ok": true])),
      .reply(id: 5, result: .failure(CIError(.unauthorized, "no"))),
      .event(
        allocation: allocation,
        .steps([.init(id: "s", number: 1, name: "n", status: "completed", conclusion: "success")])),
      .event(
        allocation: allocation,
        .completed(
          .init(conclusion: "failed", outputs: ["a": "b"], steps: [], annotations: ["error: x"]))),
    ]
    for (index, call) in calls.enumerated() {
      frames.append(.request(id: Int64(index), allocation: allocation, call: call))
    }
    for frame in frames {
      #expect(try DataPlaneFrame.decode(Array(frame.frame.dropLast())) == frame, "\(frame)")
    }
  }

  @Test func invalidFramesAreRefused() {
    let allocation = AllocationID.generate().rawValue
    let cases: [String] = [
      #"{"v":"iso-ci.dataplane/v0","type":"ready"}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"ready","extra":1}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"bogus"}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"request","id":1,"allocation":"\#(allocation)","call":"open_cache","params":{"handle":"../../etc/passwd"}}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"request","id":1,"allocation":"\#(allocation)","call":"cache_commit","params":{"cache_id":1,"file":"/etc/passwd","size":1}}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"request","id":1,"allocation":"\#(allocation)","call":"artifact_create","params":{"name":"../escape"}}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"request","id":1,"allocation":"\#(allocation)","call":"open_action","params":{"name":"a/b","commit":"HEAD"}}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"request","id":1,"allocation":"\#(allocation)","call":"shell","params":{}}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"event","allocation":"\#(allocation)","event":{"kind":"completed","conclusion":"great","outputs":{},"steps":[],"annotations":[]}}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"request","id":1,"allocation":"not-a-uuid","call":"artifact_list","params":{}}"#,
      #"{"v":"iso-ci.dataplane/v1","type":"ready","v":"iso-ci.dataplane/v1"}"#,
      #"not json"#,
    ]
    for text in cases {
      #expect(throws: CIError.self, "\(text)") { try DataPlaneFrame.decode(Array(text.utf8)) }
    }
  }
}
