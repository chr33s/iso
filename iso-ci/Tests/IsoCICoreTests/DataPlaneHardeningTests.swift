import Foundation
import Testing

@testable import IsoCICore

/// Regression tests for the data-plane security review: symlink
/// redirection of the controller (P2-1), disk-fill amplification (P2-3),
/// cross-allocation starvation (P3-5), controller flood (P3-16), and
/// revocation on unregister.
@Suite struct DataPlaneHardeningTests {
  /// Writes a file into the child's `in/` directory as the child would.
  static func stage(_ harness: DPHarness, _ bytes: [UInt8]) throws -> String {
    let name = randomHex(bytes: 16)
    try PrivateFiles.write(bytes, to: harness.childStaging + "/in/" + name)
    return name
  }

  // MARK: P2-1 symlinks

  @Test func swappedStagingDirectoriesNeverRedirectTheController() async throws {
    let harness = try await DPHarness()
    let snapshot = try harness.store.importBytes(Array("snapshot".utf8), kind: .snapshot)
    let (allocation, registration, _) = try await harness.register(snapshot: snapshot)
    // A controller-private directory with a 32-hex-named file in it.
    let victim = harness.root + "/victim"
    try PrivateFiles.ensureDirectory(victim)
    let secretName = randomHex(bytes: 16)
    try PrivateFiles.write(Array("controller secret".utf8), to: victim + "/" + secretName)
    let child = harness.childStaging
    // The child swaps in/ and out/ for symlinks into the victim directory.
    #expect(rename(child + "/in", child + "/in.orig") == 0)
    #expect(rename(child + "/out", child + "/out.orig") == 0)
    #expect(symlink(victim, child + "/in") == 0)
    #expect(symlink(victim, child + "/out") == 0)
    // Reading "in/<name>" must not read (or delete) the victim file.
    await #expect(throws: CIError.self) {
      try await harness.broker.call(
        allocation, .logCommit(kind: .job, step: nil, file: secretName, lines: 1))
    }
    #expect(
      try PrivateFiles.read(victim + "/" + secretName, limit: 64) == Array("controller secret".utf8)
    )
    #expect(await harness.broker.logs(allocation).isEmpty)
    // Exports land in the directory opened before the swap, never in victim/.
    let before = try FileManager.default.contentsOfDirectory(atPath: victim)
    let exported = try await harness.broker.call(allocation, .openSnapshot(snapshot))
    let name = try #require(exported["file"]?.stringValue)
    #expect(try FileManager.default.contentsOfDirectory(atPath: victim) == before)
    #expect(try PrivateFiles.read(child + "/out.orig/" + name, limit: 64) == Array("snapshot".utf8))
    // A symlinked entry inside the real in/ is refused, and the target survives.
    let link = randomHex(bytes: 16)
    #expect(symlink(victim + "/" + secretName, child + "/in.orig/" + link) == 0)
    await #expect(throws: CIError.self) {
      try await harness.broker.call(
        allocation, .logCommit(kind: .job, step: nil, file: link, lines: 1))
    }
    #expect(try PrivateFiles.read(victim + "/" + secretName, limit: 64) != nil)
    _ = registration
  }

  @Test func stagingDirectoriesMustBePrivateDirectories() throws {
    let root = scratchDirectory("dp-staging")
    defer { PrivateFiles.removeTree(root) }
    try PrivateFiles.ensureDirectory(root)
    // `in` is a symlink to a directory: refused before any child runs.
    try PrivateFiles.ensureDirectory(root + "/elsewhere")
    #expect(symlink(root + "/elsewhere", root + "/in") == 0)
    #expect(throws: CIError.self) { try StagingDirectories(root: root) }
  }

  // MARK: P2-3 amplification

  @Test func sparseCacheWritesAreChargedAndHolesCannotBeCommitted() async throws {
    let harness = try await DPHarness()
    let (_, _, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    let base = DataPlaneStorageTests.cacheBase
    let limit = DPHarness.limits.outputBytes
    let first = await harness.request(
      "POST", base + "caches", bearer: token, json: ["key": "a", "version": "v"])
    let firstID = try #require(first.json?["cacheId"]?.intValue)
    // One byte at the end of the budget charges the whole high-water mark.
    #expect(
      await harness.request(
        "PATCH", base + "caches/\(firstID)", bearer: token, body: [1],
        headers: ["Content-Range": "bytes \(limit - 1)-\(limit - 1)/*"]
      ).status == 204)
    // A hole cannot be committed.
    #expect(
      await harness.request(
        "POST", base + "caches/\(firstID)", bearer: token, json: ["size": .integer(Int64(limit))]
      )
      .status == 400)
    // The budget is spent: another reservation's sparse write is refused.
    let second = await harness.request(
      "POST", base + "caches", bearer: token, json: ["key": "b", "version": "v"])
    let secondID = try #require(second.json?["cacheId"]?.intValue)
    #expect(
      await harness.request(
        "PATCH", base + "caches/\(secondID)", bearer: token, body: [1],
        headers: ["Content-Range": "bytes 10-10/*"]
      ).status == 413)
  }

  @Test func outOfOrderChunksStillCommitWhenContiguous() async throws {
    let harness = try await DPHarness()
    let (_, _, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    let base = DataPlaneStorageTests.cacheBase
    let reserve = await harness.request(
      "POST", base + "caches", bearer: token, json: ["key": "k", "version": "v"])
    let id = try #require(reserve.json?["cacheId"]?.intValue)
    // Parallel toolkit uploads may arrive out of order.
    for (range, data) in [("bytes 5-9/*", "WORLD"), ("bytes 0-4/*", "HELLO")] {
      #expect(
        await harness.request(
          "PATCH", base + "caches/\(id)", bearer: token, body: Array(data.utf8),
          headers: ["Content-Range": range]
        ).status == 204)
    }
    #expect(
      await harness.request("POST", base + "caches/\(id)", bearer: token, json: ["size": 10]).status
        == 204)
    #expect(
      try await DataPlaneStorageTests.restore(harness, token: token, keys: "k", version: "v")
        == "HELLOWORLD")
  }

  @Test func blockListsCannotRepeatABlock() async throws {
    let harness = try await DPHarness()
    let (_, registration, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    let id = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    let created = await harness.request(
      "POST", "/twirp/github.actions.results.api.v1.ArtifactService/CreateArtifact", bearer: token,
      json: [
        "workflow_run_backend_id": .string(id.planID.uuidString.lowercased()),
        "workflow_job_run_backend_id": .string(id.jobID.uuidString.lowercased()), "name": "amp",
        "version": 7,
      ])
    let target = DPHarness.target(try #require(created.json?["signed_upload_url"]?.stringValue))
    let block = Data("b0".utf8).base64EncodedString()
    #expect(
      await harness.request(
        "PUT",
        target
          + "&comp=block&blockid=\(block.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)",
        body: [UInt8](repeating: 7, count: 1_000)
      ).status == 201)
    let repeated = String(repeating: "<Latest>\(block)</Latest>", count: 1_000)
    let list = "<?xml version=\"1.0\" encoding=\"utf-8\"?><BlockList>\(repeated)</BlockList>"
    #expect(
      await harness.request("PUT", target + "&comp=blocklist", body: Array(list.utf8)).status == 400
    )
  }

  @Test func brokerChargesCommittedBytesAgainstPerAttemptBudgets() async throws {
    let harness = try await DPHarness()
    var limits = DPHarness.limits
    limits.outputBytes = 100
    limits.logBytes = 50
    let (allocation, _, _) = try await harness.register(limits: limits)
    // Logs: bytes, not segment count, are bounded.
    _ = try await harness.broker.call(
      allocation,
      .logCommit(
        kind: .job, step: nil, file: try Self.stage(harness, [UInt8](repeating: 1, count: 40)),
        lines: 1))
    await #expect(throws: CIError.self) {
      try await harness.broker.call(
        allocation,
        .logCommit(
          kind: .job, step: nil, file: try Self.stage(harness, [UInt8](repeating: 2, count: 20)),
          lines: 1))
    }
    // Outputs: artifacts and caches share the output budget.
    let first = try #require(
      try await harness.broker.call(allocation, .artifactCreate(name: "one"))["id"]?.intValue)
    _ = try await harness.broker.call(
      allocation,
      .artifactFinalize(
        id: first, file: try Self.stage(harness, [UInt8](repeating: 3, count: 80)), size: 80,
        hash: nil))
    let reserved = try #require(
      try await harness.broker.call(allocation, .cacheReserve(key: "k", version: "v"))["cache_id"]?
        .intValue)
    await #expect(throws: CIError.self) {
      try await harness.broker.call(
        allocation,
        .cacheCommit(
          cacheID: reserved, file: try Self.stage(harness, [UInt8](repeating: 4, count: 30)),
          size: 30))
    }
  }

  @Test func brokerCapsReservationsAndArtifactsPerAttempt() async throws {
    let harness = try await DPHarness()
    let (allocation, _, _) = try await harness.register()
    for index in 0..<DataPlaneBroker.maxCacheReservations {
      _ = try await harness.broker.call(allocation, .cacheReserve(key: "k\(index)", version: "v"))
    }
    await #expect(throws: CIError.self) {
      try await harness.broker.call(allocation, .cacheReserve(key: "one-more", version: "v"))
    }
    for index in 0..<DataPlaneBroker.maxArtifacts {
      _ = try await harness.broker.call(allocation, .artifactCreate(name: "a\(index)"))
    }
    await #expect(throws: CIError.self) {
      try await harness.broker.call(allocation, .artifactCreate(name: "one-more"))
    }
  }

  @Test func endpointCapsStagedBlobsAndReservations() async throws {
    var settings = DataPlaneService.Settings.fast
    settings.maxBlobsPerAllocation = 2
    settings.maxCacheReservations = 1
    let harness = try await DPHarness(settings: settings)
    let (_, registration, runner) = try await harness.register()
    let (_, token, _) = try await harness.acquire(runner)
    let id = JobMessageBuilder.Identity(attempt: registration.attempt, run: registration.run)
    var statuses: [Int] = []
    for _ in 0..<3 {
      let step = UUID().uuidString.lowercased()
      let url = await harness.request(
        "POST", "/twirp/results.services.receiver.Receiver/GetStepLogsSignedBlobURL", bearer: token,
        json: [
          "workflow_run_backend_id": .string(id.planID.uuidString.lowercased()),
          "workflow_job_run_backend_id": .string(id.jobID.uuidString.lowercased()),
          "step_backend_id": .string(step),
        ])
      let target = DPHarness.target(try #require(url.json?["logs_url"]?.stringValue))
      statuses.append(await harness.request("PUT", target, body: []).status)
    }
    #expect(statuses == [201, 201, 429])
    let base = DataPlaneStorageTests.cacheBase
    #expect(
      await harness.request(
        "POST", base + "caches", bearer: token, json: ["key": "a", "version": "v"]
      ).status == 201)
    #expect(
      await harness.request(
        "POST", base + "caches", bearer: token, json: ["key": "b", "version": "v"]
      ).status == 429)
  }

  // MARK: P3-5 per-allocation sockets

  @Test func credentialsOnlyWorkOnTheirOwnAllocationSocket() async throws {
    let harness = try await DPHarness()
    let snapshot = try harness.store.importBytes(Array("snap".utf8), kind: .snapshot)
    let (allocationA, registrationA, runnerA) = try await harness.register(snapshot: snapshot)
    let (allocationB, _, runnerB) = try await harness.register(snapshot: snapshot)
    let (_, jobTokenA, _) = try await harness.acquire(runnerA)
    _ = runnerB
    func on(
      _ bound: AllocationID, _ method: String, _ target: String, bearer: String? = nil,
      body: [UInt8] = []
    )
      async -> Int
    {
      var request = DataPlaneRequest(
        method: method, target: target,
        headers: bearer.map { ["Authorization": "Bearer " + $0] } ?? [:], body: body)
      request.boundAllocation = bound
      return await harness.service.handle(request).status
    }
    let idA = JobMessageBuilder.Identity(attempt: registrationA.attempt, run: registrationA.run)
    let renew = JSONValue.object([
      "planId": .string(idA.planID.uuidString.lowercased()),
      "jobId": .string(idA.jobID.uuidString.lowercased()),
    ]).canonical
    #expect(await on(allocationA, "POST", "/run/renewjob", bearer: jobTokenA, body: renew) == 200)
    // A's job token on B's socket.
    #expect(await on(allocationB, "POST", "/run/renewjob", bearer: jobTokenA, body: renew) == 403)
    // A's iso token on B's socket.
    #expect(
      await on(
        allocationB, "GET", "/_iso/snapshot/\(snapshot.rawValue)", bearer: runnerA.config.isoToken)
        == 401)
    // A's OAuth assertion on B's socket.
    let assertion = DPHarness.assertion(
      key: runnerA.key, clientID: runnerA.clientID, audience: runnerA.audience,
      now: Int64(harness.clock.now()))
    let form =
      "grant_type=client_credentials&client_assertion_type=urn%3Aietf%3Aparams%3Aoauth%3Aclient-assertion-type%3Ajwt-bearer&client_assertion=\(assertion)"
    #expect(await on(allocationB, "POST", "/_apis/oauth2/token", body: Array(form.utf8)) == 401)
  }

  @Test func socketsCapConnectionsAndCloseSilentClients() async throws {
    let harness = try await DPHarness()
    let (allocation, _, _) = try await harness.register()
    let path = DataPlaneProcessTests.shortSocketPath()
    var limits = DataPlaneHTTPServer.Limits()
    limits.maxConnections = 2
    limits.headerTimeout = .milliseconds(300)
    let server = try await DataPlaneHTTPServer.start(
      socketPath: path, service: harness.service, allocation: allocation, limits: limits)
    defer { unlink(path) }
    let first = try DataPlaneProcessTests.UnixHTTPClient(path: path)
    let second = try DataPlaneProcessTests.UnixHTTPClient(path: path)
    try await Task.sleep(for: .milliseconds(50))
    // The third connection is closed at once.
    let third = try DataPlaneProcessTests.UnixHTTPClient(path: path)
    #expect(third.fill() == false)
    // Silent clients are closed after the header deadline.
    #expect(first.fill() == false)
    #expect(second.fill() == false)
    // Capacity is available again afterwards.
    let fourth = try DataPlaneProcessTests.UnixHTTPClient(path: path)
    fourth.send("GET", "/nothing")
    #expect(fourth.receive()?.0 == 404)
    await server.close()
  }

  // MARK: P3-16 controller flood

  @Test func inFlightCounterRefusesBeyondItsLimit() {
    let counter = InFlightCounter()
    for _ in 0..<3 { #expect(counter.acquire(limit: 3)) }
    #expect(!counter.acquire(limit: 3))
    counter.release()
    #expect(counter.acquire(limit: 3))
  }

  // MARK: Unregister

  @Test func unregisterRevokesGrantsAndRefusesLateCalls() async throws {
    let harness = try await DPHarness()
    let snapshot = try harness.store.importBytes(Array("snap".utf8), kind: .snapshot)
    let (allocation, registration, _) = try await harness.register(snapshot: snapshot)
    #expect(
      try harness.store.isGranted(
        subject: registration.attempt.rawValue, kind: .snapshot, digest: snapshot))
    await harness.broker.unregister(allocation)
    #expect(
      !(try harness.store.isGranted(
        subject: registration.attempt.rawValue, kind: .snapshot, digest: snapshot)))
    for call: DataPlaneCall in [
      .openSnapshot(snapshot), .cacheReserve(key: "k", version: "v"), .artifactCreate(name: "x"),
      .logCommit(kind: .job, step: nil, file: try Self.stage(harness, [1]), lines: 1),
    ] {
      await #expect(throws: CIError.self) { try await harness.broker.call(allocation, call) }
    }
    // A late completion produces no notice.
    await harness.broker.event(
      allocation,
      .completed(.init(conclusion: "succeeded", outputs: [:], steps: [], annotations: [])))
    let notice = await withTaskGroup(of: DataPlaneNotice?.self) { group in
      group.addTask { await dpNextNotice(harness.broker) { $0.allocation == allocation } }
      group.addTask {
        try? await Task.sleep(for: .milliseconds(200))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    #expect(notice == nil)
  }
}
