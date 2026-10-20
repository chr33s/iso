import Foundation
import Testing

@testable import IsoCICore

/// Cache, artifact, log, budget and signed-URL behavior of the data plane
/// (C-T11, C-T12, C-T16).
@Suite struct DataPlaneStorageTests {
  static let cacheBase = "/cache/_apis/artifactcache/"

  /// Reserves, uploads in chunks and commits one cache entry.
  static func save(_ harness: DPHarness, token: String, key: String, version: String, data: String)
    async -> Int
  {
    let reserve = await harness.request(
      "POST", cacheBase + "caches", bearer: token,
      json: ["key": .string(key), "version": .string(version)])
    guard reserve.status == 201, let id = reserve.json?["cacheId"]?.intValue else {
      return reserve.status
    }
    let bytes = Array(data.utf8)
    let middle = bytes.count / 2
    for (start, chunk) in [(0, Array(bytes[..<middle])), (middle, Array(bytes[middle...]))]
    where !chunk.isEmpty {
      let status = await harness.request(
        "PATCH", cacheBase + "caches/\(id)", bearer: token, body: chunk,
        headers: ["Content-Range": "bytes \(start)-\(start + chunk.count - 1)/*"]
      ).status
      guard status == 204 else { return status }
    }
    return await harness.request(
      "POST", cacheBase + "caches/\(id)", bearer: token,
      json: ["size": .integer(Int64(bytes.count))]
    ).status
  }

  static func restore(_ harness: DPHarness, token: String, keys: String, version: String)
    async throws -> String?
  {
    let lookup = await harness.request(
      "GET",
      cacheBase
        + "cache?keys=\(keys.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)&version=\(version)",
      bearer: token)
    if lookup.status == 204 { return nil }
    #expect(lookup.status == 200)
    let url = try #require(lookup.json?["archiveLocation"]?.stringValue)
    let download = await harness.request("GET", DPHarness.target(url))
    guard case .file(let path, _, _) = download.body else { return "status \(download.status)" }
    defer { PrivateFiles.remove(path) }
    return String(decoding: try PrivateFiles.read(path, limit: 1 << 20) ?? [], as: UTF8.self)
  }

  @Test func cacheRoundTripRestoreKeysAndVersions() async throws {
    let harness = try await DPHarness()
    let (_, _, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    // The recorded toolkit sequence (reserve, chunked PATCH, commit).
    let fixture = try DataPlaneProtocolTests.fixture("toolkit-cache-v1.json")
    let reserve = await harness.request(
      "POST", Self.cacheBase + "caches", bearer: token, json: fixture["reserve"])
    #expect(reserve.status == 201)
    let id = try #require(reserve.json?["cacheId"]?.intValue)
    for chunk in try #require(fixture["chunks"]?.arrayValue) {
      let status = await harness.request(
        "PATCH", Self.cacheBase + "caches/\(id)", bearer: token,
        body: Array(try #require(chunk["data"]?.stringValue).utf8),
        headers: [
          "Content-Range": try #require(chunk["range"]?.stringValue),
          "Content-Type": "application/octet-stream",
        ]
      ).status
      #expect(status == 204)
    }
    #expect(
      await harness.request(
        "POST", Self.cacheBase + "caches/\(id)", bearer: token,
        json: fixture["commit"]
      )
      .status == 204)
    #expect(
      try await Self.restore(harness, token: token, keys: "Linux-npm-abc", version: "a1b2")
        == "hello world")
    // Restore-key prefix match.
    #expect(
      try await Self.restore(
        harness, token: token, keys: "Linux-npm-zzz,Linux-npm-", version: "a1b2") == "hello world")
    // The primary key is exact-only.
    #expect(
      try await Self.restore(harness, token: token, keys: "Linux-npm-", version: "a1b2") == nil)
    // Version mismatch is a miss.
    #expect(
      try await Self.restore(harness, token: token, keys: "Linux-npm-abc", version: "other") == nil)
    // First writer wins: the same key/version cannot be overwritten (poisoning).
    #expect(
      await Self.save(harness, token: token, key: "Linux-npm-abc", version: "a1b2", data: "poison")
        == 409)
    #expect(
      try await Self.restore(harness, token: token, keys: "Linux-npm-abc", version: "a1b2")
        == "hello world")
  }

  @Test func incompleteCachePublicationIsNeverVisible() async throws {
    let harness = try await DPHarness()
    let (_, _, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    let reserve = await harness.request(
      "POST", Self.cacheBase + "caches", bearer: token, json: ["key": "half", "version": "v"])
    let id = try #require(reserve.json?["cacheId"]?.intValue)
    #expect(
      await harness.request(
        "PATCH", Self.cacheBase + "caches/\(id)", bearer: token, body: Array("abc".utf8),
        headers: ["Content-Range": "bytes 0-2/*"]
      ).status == 204)
    // Never committed: invisible.
    #expect(try await Self.restore(harness, token: token, keys: "half", version: "v") == nil)
    // A commit whose size does not match the uploaded content is refused.
    #expect(
      await harness.request(
        "POST", Self.cacheBase + "caches/\(id)", bearer: token, json: ["size": 10]
      ).status == 400)
    #expect(try await Self.restore(harness, token: token, keys: "half", version: "v") == nil)
    // A chunk beyond the upload budget is refused.
    let big = await harness.request(
      "POST", Self.cacheBase + "caches", bearer: token, json: ["key": "big", "version": "v"])
    let bigID = try #require(big.json?["cacheId"]?.intValue)
    let limit = DPHarness.limits.outputBytes
    #expect(
      await harness.request(
        "PATCH", Self.cacheBase + "caches/\(bigID)", bearer: token, body: [1],
        headers: ["Content-Range": "bytes \(limit)-\(limit)/*"]
      ).status == 400)
  }

  /// Regression fixture: an allowed shared cache entry versus a denied
  /// private object. Attempt B (same repository/authority/platform/image
  /// scope) can restore the cache A published, while A's private snapshot,
  /// log segments and job control stay unreachable to B.
  @Test func sharedCacheAllowedPrivateObjectsDenied() async throws {
    let harness = try await DPHarness()
    let snapshotA = try harness.store.importBytes(Array("private-A".utf8), kind: .snapshot)
    let (allocationA, registrationA, runnerA) = try await harness.register(snapshot: snapshotA)
    let (_, tokenA, _) = try await harness.acquire(runnerA)
    #expect(
      await Self.save(harness, token: tokenA, key: "shared", version: "v", data: "deps") == 204)
    // A uploads a step log (a private per-attempt object).
    let idA = JobMessageBuilder.Identity(attempt: registrationA.attempt, run: registrationA.run)
    let step = UUID().uuidString.lowercased()
    let ids: JSONValue = [
      "workflow_run_backend_id": .string(idA.planID.uuidString.lowercased()),
      "workflow_job_run_backend_id": .string(idA.jobID.uuidString.lowercased()),
      "step_backend_id": .string(step),
    ]
    let logURL = await harness.request(
      "POST", "/twirp/results.services.receiver.Receiver/GetStepLogsSignedBlobURL", bearer: tokenA,
      json: ids)
    let target = DPHarness.target(try #require(logURL.json?["logs_url"]?.stringValue))
    #expect(await harness.request("PUT", target, body: Array("secret log".utf8)).status == 201)
    var metadata = ids.objectValue ?? [:]
    metadata["line_count"] = 1
    #expect(
      await harness.request(
        "POST", "/twirp/results.services.receiver.Receiver/CreateStepLogsMetadata", bearer: tokenA,
        json: .object(metadata)
      ).status == 200)
    let logs = await harness.broker.logs(allocationA)
    #expect(logs.count == 1)
    let logDigest = try #require(logs.first?.digest)

    let (allocationB, _, runnerB) = try await harness.register()
    let (_, tokenB, _) = try await harness.acquire(runnerB)
    // Allowed: the shared immutable cache entry in the same scope.
    #expect(try await Self.restore(harness, token: tokenB, keys: "shared", version: "v") == "deps")
    // Denied: A's snapshot by digest (through B's iso token) ...
    #expect(
      await harness.request(
        "GET", "/_iso/snapshot/\(snapshotA.rawValue)", bearer: runnerB.config.isoToken
      ).status == 403)
    // ... A's log object, even through the broker directly ...
    await #expect(throws: CIError.self) {
      try await harness.broker.call(allocationB, .openSnapshot(logDigest))
    }
    #expect(
      try harness.store.isGranted(
        subject: registrationA.attempt.rawValue, kind: .log, digest: logDigest))
    // ... A's signed log URL is bound to A (B cannot reuse it with its own id).
    let reused = target.replacingOccurrences(of: allocationA.rawValue, with: allocationB.rawValue)
    #expect(await harness.request("PUT", reused, body: Array("x".utf8)).status == 403)
    // ... and A's job control namespace.
    #expect(
      await harness.request(
        "POST", "/run/completejob", bearer: tokenB,
        json: [
          "planId": .string(idA.planID.uuidString.lowercased()),
          "jobId": .string(idA.jobID.uuidString.lowercased()),
          "conclusion": "succeeded",
        ]
      ).status == 404)
  }

  @Test func cachesAreInvisibleAcrossScopes() async throws {
    let harness = try await DPHarness()
    let (_, _, runnerA) = try await harness.register(scope: DPHarness.scope("octo/demo"))
    let (_, tokenA, _) = try await harness.acquire(runnerA)
    #expect(await Self.save(harness, token: tokenA, key: "k", version: "v", data: "a") == 204)
    // Another repository.
    let (_, _, runnerB) = try await harness.register(scope: DPHarness.scope("octo/other"))
    let (_, tokenB, _) = try await harness.acquire(runnerB)
    #expect(try await Self.restore(harness, token: tokenB, keys: "k", version: "v") == nil)
    // Same repository, privileged authority class.
    let (_, _, runnerC) = try await harness.register(
      scope: DPHarness.scope("octo/demo", authority: "privileged"))
    let (_, tokenC, _) = try await harness.acquire(runnerC)
    #expect(try await Self.restore(harness, token: tokenC, keys: "k", version: "v") == nil)
  }

  // MARK: Artifacts

  /// Uploads an artifact through the recorded toolkit sequence; returns the
  /// finalize status.
  static func upload(
    _ harness: DPHarness, token: String, registration: DataPlaneRegistration, name: String = "dist",
    blocks: [String] = ["PK\u{3}\u{4}first-", "second"]
  ) async throws -> (Int, String) {
    let id = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    let ids = [
      "PLAN_ID": id.planID.uuidString.lowercased(), "JOB_ID": id.jobID.uuidString.lowercased(),
    ]
    let fixture = DataPlaneProtocolTests.substitute(
      try DataPlaneProtocolTests.fixture("toolkit-artifact-v4.json"), ids)
    var create = try #require(fixture["create"]?.objectValue)
    create["name"] = .string(name)
    let created = await harness.request(
      "POST", "/twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact", bearer: token,
      json: .object(create))
    guard created.status == 200, let url = created.json?["signed_upload_url"]?.stringValue else {
      return (created.status, "")
    }
    let target = DPHarness.target(url)
    var listXML = "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>"
    for (index, block) in blocks.enumerated() {
      let blockID = Data("block-\(index)".utf8).base64EncodedString()
      let encoded = blockID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
      let status = await harness.request(
        "PUT", target + "&comp=block&blockid=\(encoded)", body: Array(block.utf8)
      ).status
      guard status == 201 else { return (status, "") }
      listXML += "<Latest>\(blockID)</Latest>"
    }
    listXML += "</BlockList>"
    let committed = await harness.request(
      "PUT", target + "&comp=blocklist", body: Array(listXML.utf8)
    ).status
    guard committed == 201 else { return (committed, "") }
    let content = blocks.joined()
    var finalize = try #require(fixture["finalize"]?.objectValue)
    finalize["name"] = .string(name)
    finalize["size"] = .string(String(content.utf8.count))
    finalize["hash"] = .string("sha256:" + Digest(hashing: content).rawValue)
    let finalized = await harness.request(
      "POST", "/twirp/github.actions.results.api.v1.ArtifactService/FinalizeArtifact",
      bearer: token,
      json: .object(finalize))
    return (finalized.status, content)
  }

  static func download(
    _ harness: DPHarness, token: String, registration: DataPlaneRegistration, name: String
  )
    async throws -> String?
  {
    let id = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    let ids: JSONValue = [
      "workflow_run_backend_id": .string(id.planID.uuidString.lowercased()),
      "workflow_job_run_backend_id": .string(id.jobID.uuidString.lowercased()),
      "name_filter": .string(name),
    ]
    let listed = await harness.request(
      "POST", "/twirp/github.actions.results.api.v1.ArtifactService/ListArtifacts", bearer: token,
      json: ids)
    #expect(listed.status == 200)
    guard (listed.json?["artifacts"]?.arrayValue ?? []).count == 1 else { return nil }
    var signed = ids.objectValue ?? [:]
    signed["name_filter"] = nil
    signed["name"] = .string(name)
    let url = await harness.request(
      "POST", "/twirp/github.actions.results.api.v1.ArtifactService/GetSignedArtifactURL",
      bearer: token,
      json: .object(signed))
    guard let link = url.json?["signed_url"]?.stringValue else { return nil }
    let response = await harness.request("GET", DPHarness.target(link))
    #expect(response.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/zip" })
    guard case .file(let path, _, _) = response.body else { return nil }
    defer { PrivateFiles.remove(path) }
    return String(decoding: try PrivateFiles.read(path, limit: 1 << 20) ?? [], as: UTF8.self)
  }

  @Test func artifactRoundTripWithBlockList() async throws {
    let harness = try await DPHarness()
    let (_, registration, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    let (status, content) = try await Self.upload(harness, token: token, registration: registration)
    #expect(status == 200)
    #expect(
      try await Self.download(harness, token: token, registration: registration, name: "dist")
        == content)
    // Delete is not part of the certified surface.
    #expect(
      await harness.request(
        "POST", "/twirp/github.actions.results.api.v1.ArtifactService/DeleteArtifact",
        bearer: token,
        json: [
          "workflow_run_backend_id": .string(
            JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run).planID
              .uuidString
              .lowercased()), "name": "dist",
        ]
      ).status == 403)
  }

  @Test func artifactNamesBudgetsAndRunScope() async throws {
    let harness = try await DPHarness()
    let run = PreflightRunID.generate()
    let (_, registration, runner) = try await harness.register(run: run)
    let (_, token, _) = try await harness.acquire(runner)
    // Traversal and separators in names are refused.
    for name in ["../escape", "a/b", "/abs", "a\\b", ".."] {
      #expect(
        try await Self.upload(harness, token: token, registration: registration, name: name).0
          == 400)
    }
    // A block beyond the output budget is refused.
    let huge = String(repeating: "x", count: Int(DPHarness.limits.outputBytes) + 1)
    #expect(
      try await Self.upload(
        harness, token: token, registration: registration, name: "huge", blocks: [huge]
      ).0 == 413)
    // Another run never sees this run's artifacts (even with a valid token).
    #expect(try await Self.upload(harness, token: token, registration: registration).0 == 200)
    let (_, other, otherRunner) = try await harness.register()
    let (_, otherToken, _) = try await harness.acquire(otherRunner)
    #expect(
      try await Self.download(harness, token: otherToken, registration: other, name: "dist") == nil)
    // A forged request naming the first run's backend id is refused.
    let foreign = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    #expect(
      await harness.request(
        "POST", "/twirp/github.actions.results.api.v1.ArtifactService/ListArtifacts",
        bearer: otherToken,
        json: [
          "workflow_run_backend_id": .string(foreign.planID.uuidString.lowercased()),
          "workflow_job_run_backend_id": .string(foreign.jobID.uuidString.lowercased()),
        ]
      ).status == 403)
  }

  @Test func crossJobArtifactsNeedDependencyProvenanceAndMatchingAuthority() async throws {
    let harness = try await DPHarness()
    let run = PreflightRunID.generate()
    let producerAttempt = JobAttemptID.generate()
    let (_, producer, producerRunner) = try await harness.register(
      run: run, attempt: producerAttempt)
    let (_, producerToken, _) = try await harness.acquire(producerRunner)
    #expect(try await Self.upload(harness, token: producerToken, registration: producer).0 == 200)
    // Dependent job in the same run with explicit provenance: visible.
    let (_, consumer, consumerRunner) = try await harness.register(
      run: run, dependencies: [producerAttempt])
    let (_, consumerToken, _) = try await harness.acquire(consumerRunner)
    #expect(
      try await Self.download(harness, token: consumerToken, registration: consumer, name: "dist")
        != nil)
    // Same run without that provenance: invisible.
    let (_, stranger, strangerRunner) = try await harness.register(run: run)
    let (_, strangerToken, _) = try await harness.acquire(strangerRunner)
    #expect(
      try await Self.download(harness, token: strangerToken, registration: stranger, name: "dist")
        == nil)
    // A privileged attempt never automatically consumes a validation artifact.
    let (_, privileged, privilegedRunner) = try await harness.register(
      run: run, authority: .privileged, dependencies: [producerAttempt])
    let (_, privilegedToken, _) = try await harness.acquire(privilegedRunner)
    #expect(
      try await Self.download(
        harness, token: privilegedToken, registration: privileged, name: "dist") == nil)
  }

  // MARK: Signed URLs and budgets

  @Test func signedURLsRejectTamperingAndExpiry() async throws {
    let harness = try await DPHarness()
    let (_, registration, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    let id = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    let response = await harness.request(
      "POST", "/twirp/results.services.receiver.Receiver/GetJobLogsSignedBlobURL", bearer: token,
      json: [
        "workflow_run_backend_id": .string(id.planID.uuidString.lowercased()),
        "workflow_job_run_backend_id": .string(id.jobID.uuidString.lowercased()),
      ])
    let target = DPHarness.target(try #require(response.json?["logs_url"]?.stringValue))
    // Tampered signature.
    #expect(
      await harness.request("PUT", target.replacingOccurrences(of: "sig=", with: "sig=A")).status
        == 403)
    // Tampered path (another resource with the same signature).
    #expect(
      await harness.request(
        "PUT", target.replacingOccurrences(of: "/logs/job-job", with: "/logs/step-job")
      ).status == 403)
    // Extended expiry.
    let expires = try #require(
      URLComponents(string: "http://x" + target)?.queryItems?.first { $0.name == "se" }?.value)
    #expect(
      await harness.request(
        "PUT", target.replacingOccurrences(of: "se=\(expires)", with: "se=\(Int64(expires)! + 999)")
      )
      .status == 403)
    // Valid now, expired later.
    #expect(await harness.request("PUT", target, body: Array("x".utf8)).status == 201)
    harness.clock.advance(4_000)
    #expect(await harness.request("PUT", target, body: Array("y".utf8)).status == 403)
  }

  @Test func trafficRateAndFloodBudgetsHold() async throws {
    var settings = DataPlaneService.Settings.fast
    settings.maxRequestsPerMinute = 30
    let harness = try await DPHarness(settings: settings)
    var limits = DPHarness.limits
    limits.trafficBytes = 64 << 10
    let (_, registration, runner) = try await harness.register(limits: limits)
    let (_, token, _) = try await harness.acquire(runner)
    let id = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    let renew: JSONValue = [
      "planId": .string(id.planID.uuidString.lowercased()),
      "jobId": .string(id.jobID.uuidString.lowercased()),
    ]
    // Traffic: a request body that exceeds the remaining budget is refused.
    let big = [UInt8](repeating: 0x20, count: 70 << 10)
    #expect(await harness.request("POST", "/run/renewjob", bearer: token, body: big).status == 429)
    // Rate: the per-minute request budget is enforced per allocation.
    var statuses: [Int] = []
    for _ in 0..<40 {
      statuses.append(
        await harness.request("POST", "/run/renewjob", bearer: token, json: renew).status)
    }
    #expect(statuses.contains(429))
    // Flood of unauthenticated requests is refused endpoint-wide.
    var anonymous: [Int] = []
    for _ in 0..<40 {
      anonymous.append(await harness.request("POST", "/run/renewjob", bearer: "garbage").status)
    }
    #expect(anonymous.contains(429))
    // Logs are bounded by the log budget.
    let (_, registration2, runner2) = try await harness.register()
    let (_, token2, _) = try await harness.acquire(runner2)
    let id2 = JobMessageBuilder.Identity(attempt: registration2.attempt, run: registration2.run)
    let url = await harness.request(
      "POST", "/twirp/results.services.receiver.Receiver/GetJobLogsSignedBlobURL", bearer: token2,
      json: [
        "workflow_run_backend_id": .string(id2.planID.uuidString.lowercased()),
        "workflow_job_run_backend_id": .string(id2.jobID.uuidString.lowercased()),
      ])
    let target = DPHarness.target(try #require(url.json?["logs_url"]?.stringValue))
    #expect(await harness.request("PUT", target, body: []).status == 201)
    let chunk = [UInt8](repeating: 0x61, count: 40 << 10)
    #expect(await harness.request("PUT", target + "&comp=appendblock", body: chunk).status == 201)
    #expect(await harness.request("PUT", target + "&comp=appendblock", body: chunk).status == 413)
  }

  @Test func unregisterRevokesEverything() async throws {
    let harness = try await DPHarness()
    let (allocation, registration, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    await harness.broker.unregister(allocation)
    let id = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    #expect(
      await harness.request(
        "POST", "/run/renewjob", bearer: token,
        json: [
          "planId": .string(id.planID.uuidString.lowercased()),
          "jobId": .string(id.jobID.uuidString.lowercased()),
        ]
      ).status == 401)
    await #expect(throws: CIError.self) {
      try await harness.broker.call(allocation, .artifactList(nameFilter: nil, idFilter: nil))
    }
  }
}
