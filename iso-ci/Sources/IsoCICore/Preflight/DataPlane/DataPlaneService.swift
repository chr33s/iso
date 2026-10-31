import Foundation

/// The single scoped preflight endpoint (spec sections 3 and 9).
///
/// Protocol flavour: the official runner's run-service ("V2") flow, chosen
/// because every route is plain REST/twirp (no legacy VSS location service)
/// and the job message is fetched with `acquirejob`. Target runner:
/// v2.338.0 (the approved image pin); read against v2.338.0 and v2.329.0,
/// whose routes and bodies used here differ only in `DELETE /broker/session`
/// gaining a `sessionId` query (accepted with or without). Supported range
/// claimed by reading: v2.329.0–v2.338.0. Not qualified against a running
/// runner binary (see iso-ci/PROVENANCE.md).
///
/// It serves
/// only the protocol surface the `local-actions/v1` manifest certifies for
/// the official runner v2.338.0 (run-service flavour: broker session and
/// message, run-service acquire/renew/complete, results receiver, launch
/// action resolution), the `@actions/cache` v1 REST API, the
/// `@actions/artifact` v2 twirp API with blob uploads, and two iso-ci routes.
///
/// Every request is authorized by its allocation: the runner's OAuth client
/// assertion (RS256 over the allocation's registered key) yields a runner
/// token; acquiring the job yields a job token; both are HS256 tokens only
/// this process can mint. Blob and archive URLs are signed for one
/// allocation, resource and expiry. A request can reach only its own job
/// and control namespace, and objects the controller authorizes for its
/// attempt. No route performs a host operation or returns a credential the
/// allocation was not already given.
package actor DataPlaneService {
  package struct Settings: Sendable {
    package var maxConcurrentPerAllocation = 16
    package var maxRequestsPerMinute = 1_200
    /// Unauthenticated or failed-auth requests across the whole endpoint.
    package var maxAnonymousPerSecond = 20
    package var pollInterval: Duration = .seconds(1)
    package var pollTimeout: Duration = .seconds(30)
    package var urlLifetime: Int64 = 3_600
    package var runnerTokenLifetime: Int64 = 3_600
    package var maxBlocksPerBlob = 50_000
    /// Distinct blobs (logs, artifacts) one allocation may stage.
    package var maxBlobsPerAllocation = 256
    package var maxCacheReservations = 32
    /// Distinct client assertions one allocation may exchange within one
    /// acceptance window (`ClientAssertionVerifier.maxLifetime` plus skew).
    package var maxAssertionsPerWindow = 1_024

    package init() {}
  }

  enum Phase: Sendable { case waiting, delivered, acquired, completed }

  struct BlobUpload {
    var file: String
    var size: UInt64
    var appendable: Bool
    var sealed: Bool
    var blocks: [String: (file: String, size: UInt64)]
  }

  /// A staged cache upload: its high-water mark is charged against the
  /// attempt's upload budget as it grows, and commit requires the received
  /// ranges to cover exactly `[0, size)` (no sparse holes).
  struct CacheUpload {
    var file: String
    var highWater: UInt64 = 0
    var ranges: [(start: UInt64, end: UInt64)] = []

    mutating func record(_ start: UInt64, _ end: UInt64) {
      ranges.append((start, end))
      ranges.sort { $0.start < $1.start }
      var merged: [(start: UInt64, end: UInt64)] = []
      for range in ranges {
        if let last = merged.last, range.start <= last.end + 1 {
          merged[merged.count - 1].end = max(last.end, range.end)
        } else {
          merged.append(range)
        }
      }
      ranges = merged
    }

    func covers(size: UInt64) -> Bool {
      size == 0
        ? ranges.isEmpty : (ranges.count == 1 && ranges[0].start == 0 && ranges[0].end + 1 == size)
    }
  }

  struct Slot {
    let grant: DataPlaneGrant
    let verifier: ClientAssertionVerifier
    /// Accepted assertion ids until their acceptance window closes; an id
    /// is never forgotten while a replay of it could still verify.
    var seenAssertions: [String: Int64] = [:]
    var session: String?
    var phase: Phase = .waiting
    var cancelled = false
    var cancelDelivered = false
    var traffic: UInt64 = 0
    var inflight = 0
    var windowStart: Int64 = 0
    var windowCount = 0
    var logBytes: UInt64 = 0
    var uploadedBytes: UInt64 = 0
    var resolvedActions: [String: String] = [:]
    var cacheUploads: [Int64: CacheUpload] = [:]
    var cacheReservations = 0
    var cacheHandles: Set<String> = []
    var artifactsByName: [String: Int64] = [:]
    var blobs: [String: BlobUpload] = [:]
    var visibleArtifacts: Set<Int64> = []
  }

  private let backend: any DataPlaneBackend
  private let staging: String
  private let clock: any CIClock
  private let tokens: EndpointTokenAuthority
  private let settings: Settings
  private var slots: [AllocationID: Slot] = [:]
  private var clients: [String: AllocationID] = [:]
  private var anonymousWindow: (start: Int64, count: Int) = (0, 0)

  package init(
    backend: any DataPlaneBackend, staging: String, clock: any CIClock = SystemClock(),
    tokens: EndpointTokenAuthority = EndpointTokenAuthority(), settings: Settings = Settings()
  ) throws(CIError) {
    self.backend = backend
    self.staging = staging
    self.clock = clock
    self.tokens = tokens
    self.settings = settings
    try PrivateFiles.ensureDirectory(staging)
    try PrivateFiles.ensureDirectory(staging + "/in")
    try PrivateFiles.ensureDirectory(staging + "/out")
  }

  private var now: Int64 { Int64(clock.now()) }

  // MARK: Registration (controller → endpoint)

  /// The socket name the in-process endpoint reports (it binds none).
  package static let inProcessSocket = "in-process"

  @discardableResult
  package func register(_ grant: DataPlaneGrant) throws(CIError) -> String {
    guard slots[grant.allocation] == nil, clients[grant.clientID] == nil else {
      throw CIError(.conflict, "allocation is already registered")
    }
    let verifier = try ClientAssertionVerifier(
      clientID: grant.clientID,
      audience: JobMessageBuilder.Endpoint(host: grant.guestHost, guestPort: grant.guestPort).oauth,
      publicKeyDER: grant.runnerPublicKeyDER)
    slots[grant.allocation] = Slot(grant: grant, verifier: verifier)
    clients[grant.clientID] = grant.allocation
    return Self.inProcessSocket
  }

  package func unregister(_ allocation: AllocationID) {
    guard let slot = slots.removeValue(forKey: allocation) else { return }
    clients[slot.grant.clientID] = nil
    for upload in slot.cacheUploads.values { PrivateFiles.remove(inPath(upload.file)) }
    for blob in slot.blobs.values {
      PrivateFiles.remove(inPath(blob.file))
      for block in blob.blocks.values { PrivateFiles.remove(inPath(block.file)) }
    }
  }

  /// Delivers a JobCancel message on the next poll (abort, expiry).
  package func cancel(_ allocation: AllocationID) {
    slots[allocation]?.cancelled = true
  }

  // MARK: Dispatch

  package func handle(_ request: DataPlaneRequest) async -> DataPlaneResponse {
    let path = request.path
    if path == "/_apis/oauth2/token", request.method == "POST" { return await oauthToken(request) }
    if path.hasPrefix("/isoci/") { return await signedBlob(request) }
    if path.hasPrefix("/_iso/actions/") { return await actionArchive(request) }
    if path.hasPrefix("/_iso/snapshot/") { return await snapshot(request) }
    if path.hasPrefix("/broker/") {
      return await withRunner(request) { (a, r) async in await self.broker(a, r) }
    }
    if path == "/run/acquirejob" {
      return await withRunner(request) { (a, r) async in await self.acquire(a, r) }
    }
    if path == "/run/renewjob" || path == "/run/completejob" || path.hasPrefix("/twirp/")
      || path.hasPrefix("/cache/_apis/artifactcache/") || path.hasPrefix("/actions/build/")
    {
      return await withJob(request) { (a, r) async in await self.jobRoute(a, r) }
    }
    return anonymousRefusal(404, "not found")
  }

  /// Counts unauthenticated failures against an endpoint-wide budget so a
  /// flood of bad requests cannot starve the allocations.
  private func anonymousRefusal(_ status: Int, _ message: String) -> DataPlaneResponse {
    let second = now
    if anonymousWindow.start != second { anonymousWindow = (second, 0) }
    anonymousWindow.count += 1
    if anonymousWindow.count > settings.maxAnonymousPerSecond {
      return .error(429, "too many unauthorized requests")
    }
    return .error(status, message)
  }

  /// Admission against the allocation's concurrency, rate and traffic budgets.
  private func admit(_ allocation: AllocationID, _ request: DataPlaneRequest) -> DataPlaneResponse?
  {
    guard var slot = slots[allocation] else { return .error(401, "allocation is not registered") }
    if slot.inflight >= settings.maxConcurrentPerAllocation {
      return .error(429, "too many concurrent requests")
    }
    let minute = now / 60
    if slot.windowStart != minute {
      slot.windowStart = minute
      slot.windowCount = 0
    }
    slot.windowCount += 1
    if slot.windowCount > settings.maxRequestsPerMinute {
      slots[allocation] = slot
      return .error(429, "request rate exceeded")
    }
    let incoming = UInt64(request.body.count)
    guard slot.traffic + incoming <= slot.grant.trafficBytes else {
      slots[allocation] = slot
      return .error(429, "traffic budget exhausted")
    }
    slot.traffic += incoming
    slot.inflight += 1
    slots[allocation] = slot
    return nil
  }

  private func finish(_ allocation: AllocationID, _ response: DataPlaneResponse)
    -> DataPlaneResponse
  {
    guard var slot = slots[allocation] else { return response }
    slot.inflight = max(0, slot.inflight - 1)
    let outgoing = response.bodyLength
    if slot.traffic + outgoing > slot.grant.trafficBytes {
      slots[allocation] = slot
      if case .file(let path, _, _) = response.body { PrivateFiles.remove(path) }
      return .error(429, "traffic budget exhausted")
    }
    slot.traffic += outgoing
    slots[allocation] = slot
    return response
  }

  private func authorized(
    _ allocation: AllocationID, _ request: DataPlaneRequest,
    _ body: (AllocationID, DataPlaneRequest) async -> DataPlaneResponse
  ) async -> DataPlaneResponse {
    // A credential is only valid on its own allocation's socket.
    if let bound = request.boundAllocation, bound != allocation {
      return anonymousRefusal(403, "credential belongs to another allocation")
    }
    if let refusal = admit(allocation, request) { return refusal }
    let response = await body(allocation, request)
    return finish(allocation, response)
  }

  private func withRunner(
    _ request: DataPlaneRequest, _ body: (AllocationID, DataPlaneRequest) async -> DataPlaneResponse
  ) async -> DataPlaneResponse {
    guard let token = request.bearer,
      let claims = try? tokens.verify(token, purpose: .runner, now: now),
      slots[claims.allocation] != nil
    else { return anonymousRefusal(401, "unauthorized") }
    return await authorized(claims.allocation, request, body)
  }

  private func withJob(
    _ request: DataPlaneRequest, _ body: (AllocationID, DataPlaneRequest) async -> DataPlaneResponse
  ) async -> DataPlaneResponse {
    guard let token = request.bearer,
      let claims = try? tokens.verify(token, purpose: .job, now: now),
      let slot = slots[claims.allocation], slot.phase == .acquired || slot.phase == .completed
    else { return anonymousRefusal(401, "unauthorized") }
    return await authorized(claims.allocation, request, body)
  }

  // MARK: OAuth

  /// `POST /_apis/oauth2/token` (client-credentials grant with a JWT bearer
  /// client assertion, as `VssOAuthJwtBearerClientCredential` sends it).
  private func oauthToken(_ request: DataPlaneRequest) async -> DataPlaneResponse {
    let refusal = DataPlaneResponse.json(401, ["error": "invalid_client"])
    guard request.body.count <= 32 << 10 else { return anonymousRefusal(413, "request too large") }
    let fields = request.formFields
    guard fields["grant_type"] == "client_credentials",
      fields["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      let assertion = fields["client_assertion"],
      let parts = try? JWTParts(assertion), let issuer = parts.claims["iss"]?.stringValue,
      let allocation = clients[issuer], var slot = slots[allocation],
      request.boundAllocation == nil || request.boundAllocation == allocation
    else { return Self.oauthRefusal(anonymousRefusal(401, "invalid client")) }
    let verified: ClientAssertionVerifier.Verified
    do { verified = try slot.verifier.verify(assertion, now: now) } catch {
      return Self.oauthRefusal(anonymousRefusal(401, "invalid client"))
    }
    let current = now
    slot.seenAssertions = slot.seenAssertions.filter { $0.value >= current }
    guard slot.seenAssertions[verified.id] == nil else { return refusal }
    // Within one window the set is bounded by refusing, never by evicting
    // an id that could still be replayed.
    guard slot.seenAssertions.count < settings.maxAssertionsPerWindow else {
      slots[allocation] = slot
      return .error(429, "too many token requests")
    }
    slot.seenAssertions[verified.id] = verified.acceptedUntil
    slots[allocation] = slot
    let expires = min(now + settings.runnerTokenLifetime, slot.grant.expiresAt)
    guard expires > now else { return refusal }
    let token = tokens.mint(allocation: allocation, purpose: .runner, expiresAt: expires)
    return .json(
      200,
      [
        "access_token": .string(token), "token_type": "Bearer",
        "expires_in": .integer(expires - now),
      ])
  }

  /// The OAuth error body for a refused client, unless the anonymous budget
  /// is exhausted: then its 429 is returned as is.
  static func oauthRefusal(_ budget: DataPlaneResponse) -> DataPlaneResponse {
    budget.status == 429 ? budget : .json(401, ["error": "invalid_client"])
  }

  // MARK: Broker

  private func broker(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    switch (request.method, request.path) {
    case ("POST", "/broker/session"):
      guard let body = try? StrictJSON.parse(request.body, limits: .guestRequest) else {
        return .error(400, "invalid session")
      }
      guard slots[allocation]?.session == nil else {
        return .error(409, "a session already exists")
      }
      let session = UUID().uuidString.lowercased()
      slots[allocation]?.session = session
      await backend.event(allocation, .sessionCreated)
      var agent: JSONValue = ["id": 1, "name": .string("iso-ci-\(allocation.short)")]
      if case .object(let members)? = body["agent"] {
        var echoed: [String: JSONValue] = [:]
        for key in ["id", "name", "version", "osDescription"] where members[key] != nil {
          echoed[key] = members[key]
        }
        agent = .object(echoed)
      }
      return .json(
        200,
        [
          "sessionId": .string(session), "ownerName": "iso-ci", "agent": agent,
          "useFipsEncryption": false, "brokerSession": true,
        ])
    case ("DELETE", "/broker/session"):
      if let requested = request.query["sessionId"],
        requested.lowercased() != slots[allocation]?.session
      {
        return .error(404, "unknown session")
      }
      slots[allocation]?.session = nil
      await backend.event(allocation, .sessionClosed)
      return .empty(200)
    case ("POST", "/broker/acknowledge"):
      return .empty(200)
    case ("GET", "/broker/message"):
      return await message(allocation, request)
    default:
      return .error(404, "not found")
    }
  }

  /// `GET /broker/message`: the one job request for this allocation, a
  /// JobCancel after a cancellation, or an empty long-poll response.
  private func message(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    guard let session = slots[allocation]?.session,
      request.query["sessionId"]?.lowercased() == session
    else { return .error(404, "unknown session") }
    let deadline = ContinuousClock.now + settings.pollTimeout
    while true {
      guard let slot = slots[allocation], slot.session == session else { return .empty(202) }
      if slot.phase == .waiting && !slot.cancelled {
        slots[allocation]?.phase = .delivered
        let reference: JSONValue = [
          "id": .string(slot.grant.jobID), "runner_request_id": .string(slot.grant.jobID),
          "run_service_url": .string(
            JobMessageBuilder.Endpoint(host: slot.grant.guestHost, guestPort: slot.grant.guestPort)
              .runService),
          "billing_owner_id": "", "should_acknowledge": false,
        ]
        return .json(
          200,
          [
            "messageId": 1, "messageType": "RunnerJobRequest",
            "body": .string(reference.canonicalString),
          ])
      }
      if slot.cancelled && !slot.cancelDelivered && slot.phase == .acquired {
        slots[allocation]?.cancelDelivered = true
        let body: JSONValue = ["jobId": .string(slot.grant.jobID), "timeout": "00:05:00"]
        return .json(
          200, ["messageId": 2, "messageType": "JobCancel", "body": .string(body.canonicalString)])
      }
      if ContinuousClock.now >= deadline { return .empty(202) }
      try? await Task.sleep(for: settings.pollInterval)
    }
  }

  // MARK: Run service

  private func acquire(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    guard let slot = slots[allocation],
      let body = try? StrictJSON.parse(request.body, limits: .guestRequest),
      body["jobMessageId"]?.stringValue?.lowercased() == slot.grant.jobID
    else { return .error(404, "job message not found") }
    switch slot.phase {
    case .waiting: return .error(404, "job message not found")
    case .acquired, .completed: return .error(409, "job message already acquired")
    case .delivered: break
    }
    if slot.cancelled { return .error(422, "job was cancelled before it started") }
    let scope =
      "Actions.GenericRead:00000000-0000-0000-0000-000000000000 Actions.Results:\(slot.grant.planID):\(slot.grant.jobID)"
    let token = tokens.mint(
      allocation: allocation, purpose: .job, expiresAt: slot.grant.expiresAt, scope: scope)
    guard let message = try? JobMessageBuilder.withAccessToken(slot.grant.jobMessage, token: token)
    else {
      return .error(422, "job message is unprocessable")
    }
    slots[allocation]?.phase = .acquired
    await backend.event(allocation, .jobAcquired)
    return .json(200, message)
  }

  private func jobRoute(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    let path = request.path
    switch path {
    case "/run/renewjob": return renew(allocation, request)
    case "/run/completejob": return await complete(allocation, request)
    default: break
    }
    if path.hasPrefix("/actions/build/") { return await resolveActions(allocation, request) }
    if path.hasPrefix("/cache/_apis/artifactcache/") { return await cache(allocation, request) }
    if path.hasPrefix("/twirp/results.services.receiver.Receiver/")
      || path
        == "/twirp/github.actions.results.api.v1.WorkflowStepUpdateService/WorkflowStepsUpdate"
    {
      return await results(allocation, request)
    }
    if path.hasPrefix("/twirp/github.actions.results.api.v1.ArtifactService/") {
      return await artifacts(allocation, request)
    }
    return .error(404, "not found")
  }

  private func jobIdentityMatches(_ body: JSONValue?, _ slot: Slot) -> Bool {
    body?["planId"]?.stringValue?.lowercased() == slot.grant.planID
      && body?["jobId"]?.stringValue?.lowercased() == slot.grant.jobID
  }

  private func renew(_ allocation: AllocationID, _ request: DataPlaneRequest) -> DataPlaneResponse {
    guard let slot = slots[allocation] else { return .error(404, "job not found") }
    let body = try? StrictJSON.parse(request.body, limits: .guestRequest)
    guard jobIdentityMatches(body, slot), slot.phase == .acquired else {
      return .error(404, "job not found")
    }
    let locked = Date(timeIntervalSince1970: TimeInterval(min(now + 600, slot.grant.expiresAt)))
    return .json(200, ["lockedUntil": .string(Self.timestamp(locked))])
  }

  private func complete(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    guard let slot = slots[allocation] else { return .error(404, "job not found") }
    guard let body = try? StrictJSON.parse(request.body, limits: .guestRequest),
      jobIdentityMatches(body, slot)
    else { return .error(404, "job not found") }
    if slot.phase == .completed { return .empty(200) }
    guard let result = Self.jobResult(body) else { return .error(400, "invalid completion") }
    slots[allocation]?.phase = .completed
    await backend.event(allocation, .completed(result))
    return .empty(200)
  }

  /// TaskResult as the runner serializes it (string or integer).
  static func conclusion(_ value: JSONValue?) -> String? {
    switch value {
    case .integer(let number)?:
      return [
        0: "succeeded", 1: "succeeded_with_issues", 2: "failed", 3: "canceled", 4: "skipped",
        5: "abandoned",
      ][number]
    case .string(let text)?:
      switch text.lowercased() {
      case "succeeded": return "succeeded"
      case "succeededwithissues", "succeeded_with_issues": return "succeeded_with_issues"
      case "failed": return "failed"
      case "canceled", "cancelled": return "canceled"
      case "skipped": return "skipped"
      case "abandoned": return "abandoned"
      default: return nil
      }
    default: return nil
    }
  }

  static func stepConclusion(_ conclusion: String?) -> String? {
    switch conclusion {
    case "succeeded", "succeeded_with_issues": "success"
    case "failed", "abandoned": "failure"
    case "canceled": "cancelled"
    case "skipped": "skipped"
    default: nil
    }
  }

  static func jobResult(_ body: JSONValue) -> DataPlaneEvent.JobResult? {
    guard let conclusion = conclusion(body["conclusion"]) else { return nil }
    var outputs: [String: String] = [:]
    var bytes = 0
    if case .object(let members)? = body["outputs"] {
      guard members.count <= DataPlaneEvent.maxOutputs else { return nil }
      for (key, value) in members {
        guard (1...200).contains(key.utf8.count),
          let text = value["value"]?.stringValue ?? value.stringValue
        else { return nil }
        bytes += key.utf8.count + text.utf8.count
        outputs[key] = text
      }
    }
    guard bytes <= DataPlaneEvent.maxOutputBytes else { return nil }
    var steps: [DataPlaneEvent.StepStatus] = []
    if case .array(let items)? = body["stepResults"] {
      guard items.count <= DataPlaneEvent.maxSteps else { return nil }
      for item in items {
        let state: String
        switch item["status"] {
        case .integer(0)?, .string("pending")?: state = "pending"
        case .integer(1)?, .string("inProgress")?, .string("in_progress")?: state = "in_progress"
        case .integer(2)?, .string("completed")?: state = "completed"
        default: state = "unknown"
        }
        steps.append(
          DataPlaneEvent.StepStatus(
            id: String((item["external_id"]?.stringValue ?? "").prefix(64)),
            number: item["number"]?.intValue ?? 0,
            name: CIError.bounded(String((item["name"]?.stringValue ?? "").prefix(512))),
            status: state, conclusion: stepConclusion(Self.conclusion(item["conclusion"]))))
      }
    }
    var annotations: [String] = []
    if case .array(let items)? = body["annotations"] {
      for item in items.prefix(DataPlaneEvent.maxAnnotations) {
        let level = item["level"]?.stringValue ?? "notice"
        let message = item["message"]?.stringValue ?? ""
        annotations.append(CIError.bounded(String("\(level): \(message)".prefix(1_024))))
      }
    }
    return DataPlaneEvent.JobResult(
      conclusion: conclusion, outputs: outputs, steps: steps, annotations: annotations)
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  // MARK: Launch (action resolution) and archives

  /// `POST /actions/build/{plan}/jobs/{job}/runnerresolve/actions`.
  private func resolveActions(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    guard let slot = slots[allocation] else { return .error(404, "not found") }
    let segments = request.path.split(separator: "/").map(String.init)
    guard segments.count == 7, segments[2].lowercased() == slot.grant.planID,
      segments[4].lowercased() == slot.grant.jobID, segments[5] == "runnerresolve",
      segments[6] == "actions", request.method == "POST",
      let body = try? StrictJSON.parse(request.body, limits: .guestRequest),
      case .array(let items)? = body["actions"], (1...64).contains(items.count)
    else { return .error(400, "invalid action resolution request") }
    var requests: [DataPlaneCall.ActionRequest] = []
    for item in items {
      guard let action = item["action"]?.stringValue, let version = item["version"]?.stringValue
      else {
        return .error(400, "invalid action reference")
      }
      requests.append(
        DataPlaneCall.ActionRequest(
          action: action, version: version, path: item["path"]?.stringValue ?? ""))
    }
    let reply: JSONValue
    do { reply = try await backend.call(allocation, .resolveActions(requests)) } catch {
      var errors: [String: JSONValue] = [:]
      for request in requests {
        errors["\(request.action)@\(request.version)"] = ["message": .string(error.message)]
      }
      return .json(422, ["errors": .object(errors)])
    }
    guard case .array(let resolved)? = reply["actions"] else {
      return .error(500, "invalid resolution")
    }
    let endpoint = JobMessageBuilder.Endpoint(
      host: slot.grant.guestHost, guestPort: slot.grant.guestPort)
    let expires = slot.grant.expiresAt
    let token = tokens.mint(allocation: allocation, purpose: .actions, expiresAt: expires)
    var actions: [String: JSONValue] = [:]
    for entry in resolved {
      guard let action = entry["action"]?.stringValue, let version = entry["version"]?.stringValue,
        let name = entry["name"]?.stringValue, let commit = entry["commit"]?.stringValue,
        commit.utf8.count == 40, Array(commit.utf8).allSatisfy(isLowerHex)
      else { return .error(500, "invalid resolution") }
      slots[allocation]?.resolvedActions[commit] = name
      let url = endpoint.base + "_iso/actions/\(name)/\(commit).tar.gz"
      actions["\(action)@\(version)"] = [
        "name": .string(name), "resolved_name": .string(name), "resolved_sha": .string(commit),
        "tar_url": .string(url), "zip_url": .string(url), "version": .string(version),
        "authentication": [
          "token": .string(token),
          "expires_at": .string(Self.timestamp(Date(timeIntervalSince1970: TimeInterval(expires)))),
        ],
      ]
    }
    return .json(200, ["actions": .object(actions)])
  }

  /// `GET /_iso/actions/<owner>/<repo>/<commit>.tar.gz` (Basic
  /// `x-access-token:<actions token>`, as the runner's ActionManager sends).
  private func actionArchive(_ request: DataPlaneRequest) async -> DataPlaneResponse {
    guard request.method == "GET", let token = request.basicAccessToken,
      let claims = try? tokens.verify(token, purpose: .actions, now: now),
      let slot = slots[claims.allocation]
    else { return anonymousRefusal(401, "unauthorized") }
    let segments = request.path.split(separator: "/").map(String.init)
    guard segments.count == 5, segments[4].hasSuffix(".tar.gz") else {
      return .error(404, "not found")
    }
    let name = segments[2] + "/" + segments[3]
    let commit = String(segments[4].dropLast(7))
    guard slot.resolvedActions[commit] == name else { return .error(404, "not found") }
    return await authorized(claims.allocation, request) { (allocation, _) async in
      await self.export(
        allocation, .openAction(nameWithOwner: name, commit: commit), type: "application/gzip")
    }
  }

  /// `GET /_iso/snapshot/<digest>` with `Authorization: Bearer $ISO_CI_TOKEN`.
  private func snapshot(_ request: DataPlaneRequest) async -> DataPlaneResponse {
    guard request.method == "GET", let bearer = request.bearer,
      let allocation = slots.first(where: {
        (request.boundAllocation == nil || request.boundAllocation == $0.key)
          && IsoBearer.matches(bearer, verifier: $0.value.grant.isoVerifier)
      })?.key
    else { return anonymousRefusal(401, "unauthorized") }
    guard let digest = try? Digest(String(request.path.dropFirst("/_iso/snapshot/".count))) else {
      return .error(404, "not found")
    }
    return await authorized(allocation, request) { (allocation, _) async in
      await self.export(allocation, .openSnapshot(digest), type: "application/octet-stream")
    }
  }

  /// Asks the controller for an authorized export and serves it.
  private func export(
    _ allocation: AllocationID, _ call: DataPlaneCall, type: String,
    extraHeaders: [(String, String)] = []
  )
    async -> DataPlaneResponse
  {
    do {
      let reply = try await backend.call(allocation, call)
      guard let name = reply["file"]?.stringValue, DataPlaneWire.isFileName(name),
        let size = reply["size"]?.intValue, size >= 0
      else { return .error(500, "invalid export") }
      return DataPlaneResponse(
        status: 200, headers: [("Content-Type", type)] + extraHeaders,
        body: .file(path: outPath(name), offset: 0, length: UInt64(size)))
    } catch {
      return .error(error.code == .unauthorized ? 403 : 404, error.message)
    }
  }

  // MARK: Results receiver (logs, summaries, step updates)

  private func signedURL(_ allocation: AllocationID, _ path: String) -> String {
    guard let slot = slots[allocation] else { return "" }
    let expires = min(now + settings.urlLifetime, slot.grant.expiresAt)
    let signature = tokens.signature(path: path, allocation: allocation, expiresAt: expires)
    return JobMessageBuilder.Endpoint(host: slot.grant.guestHost, guestPort: slot.grant.guestPort)
      .base.dropLast()
      + path + "?a=\(allocation.rawValue)&se=\(expires)&sig=\(signature)"
  }

  private func results(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    guard let slot = slots[allocation], request.method == "POST",
      let body = try? StrictJSON.parse(request.body, limits: .guestRequest)
    else { return .twirp(400, "malformed", "invalid request") }
    let method = String(request.path.split(separator: "/").last ?? "")
    if method == "WorkflowStepsUpdate" {
      var steps: [DataPlaneEvent.StepStatus] = []
      if case .array(let items)? = body["steps"] {
        for item in items.prefix(DataPlaneEvent.maxSteps) {
          let status =
            switch item["status"]?.intValue {
            case 3: "in_progress"
            case 5: "pending"
            case 6: "completed"
            default: "unknown"
            }
          let conclusion: String? =
            switch item["conclusion"]?.intValue {
            case 2: "success"
            case 3: "failure"
            case 4: "cancelled"
            case 7: "skipped"
            default: nil
            }
          steps.append(
            DataPlaneEvent.StepStatus(
              id: String((item["external_id"]?.stringValue ?? "").prefix(64)),
              number: item["number"]?.intValue ?? 0,
              name: CIError.bounded(String((item["name"]?.stringValue ?? "").prefix(512))),
              status: status, conclusion: conclusion))
        }
      }
      await backend.event(allocation, .steps(steps))
      return .json(200, ["ok": true])
    }
    guard body["workflow_run_backend_id"]?.stringValue?.lowercased() == slot.grant.planID,
      body["workflow_job_run_backend_id"]?.stringValue?.lowercased() == slot.grant.jobID
    else { return .twirp(403, "permission_denied", "backend ids do not match this job") }
    let step = body["step_backend_id"]?.stringValue?.lowercased()
    if let step, !isCanonicalUUID(step) { return .twirp(400, "malformed", "invalid step id") }
    let limit = Int64(slot.grant.logBytes)
    switch method {
    case "GetStepLogsSignedBlobURL", "GetJobLogsSignedBlobURL", "GetStepSummarySignedBlobURL",
      "GetJobDiagLogsSignedBlobURL":
      let kind: DataPlaneCall.LogKind =
        switch method {
        case "GetStepLogsSignedBlobURL": .step
        case "GetJobLogsSignedBlobURL": .job
        case "GetStepSummarySignedBlobURL": .summary
        default: .diagnostic
        }
      if kind == .step || kind == .summary, step == nil {
        return .twirp(400, "malformed", "missing step id")
      }
      let url = signedURL(allocation, "/isoci/logs/\(kind.rawValue)-\(step ?? "job")")
      let storage: JSONValue = "BLOB_STORAGE_TYPE_UNSPECIFIED"
      switch kind {
      case .summary:
        return .json(
          200,
          [
            "summary_url": .string(url), "soft_size_limit": .integer(limit),
            "blob_storage_type": storage,
          ])
      case .diagnostic:
        return .json(200, ["diag_logs_url": .string(url), "blob_storage_type": storage])
      default:
        return .json(
          200,
          [
            "logs_url": .string(url), "soft_size_limit": .integer(limit),
            "blob_storage_type": storage,
          ])
      }
    case "CreateStepLogsMetadata", "CreateJobLogsMetadata", "CreateStepSummaryMetadata":
      let kind: DataPlaneCall.LogKind =
        method == "CreateStepLogsMetadata"
        ? .step : method == "CreateJobLogsMetadata" ? .job : .summary
      let key = "logs/\(kind.rawValue)-\(step ?? "job")"
      guard let blob = slots[allocation]?.blobs.removeValue(forKey: key) else {
        return .json(200, ["ok": true])
      }
      let lines = UInt64(max(0, body["line_count"]?.intValue ?? 0))
      do {
        _ = try await backend.call(
          allocation, .logCommit(kind: kind, step: step, file: blob.file, lines: lines))
      } catch {
        PrivateFiles.remove(inPath(blob.file))
        return .twirp(400, "invalid_argument", error.message)
      }
      return .json(200, ["ok": true])
    default:
      return .twirp(404, "bad_route", "unknown method")
    }
  }

  // MARK: Blob storage (signed URLs)

  /// Signed blob routes: `/isoci/logs/<key>`, `/isoci/artifacts/<id>`
  /// (uploads), `/isoci/artifact/<id>.zip` and `/isoci/cache/<handle>`
  /// (downloads). The signature binds the allocation, path and expiry.
  private func signedBlob(_ request: DataPlaneRequest) async -> DataPlaneResponse {
    guard let raw = request.query["a"], let allocation = try? AllocationID(raw),
      let expires = request.query["se"].flatMap({ Int64($0) }),
      let signature = request.query["sig"],
      tokens.verifySignature(
        signature, path: request.path, allocation: allocation, expiresAt: expires, now: now),
      slots[allocation] != nil
    else { return anonymousRefusal(403, "signature is invalid or expired") }
    return await authorized(allocation, request) { (allocation, request) async in
      await self.blob(allocation, request)
    }
  }

  private func blob(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    let segments = request.path.split(separator: "/").map(String.init)
    guard segments.count == 3 else { return .error(404, "not found") }
    let container = segments[1]
    let name = segments[2]
    switch (request.method, container) {
    case ("PUT", "logs"):
      return putBlob(allocation, key: "logs/" + name, request: request, budget: .log)
    case ("PUT", "artifacts"):
      guard let id = Int64(name), slots[allocation]?.artifactsByName.values.contains(id) == true
      else {
        return .error(404, "not found")
      }
      return putBlob(allocation, key: "artifacts/\(id)", request: request, budget: .upload)
    case ("GET", "artifact"):
      guard name.hasSuffix(".zip"), let id = Int64(name.dropLast(4)),
        slots[allocation]?.visibleArtifacts.contains(id) == true
      else { return .error(404, "not found") }
      return ranged(
        await export(
          allocation, .openArtifact(id: id), type: "application/zip",
          extraHeaders: [("Content-Disposition", "attachment; filename=artifact-\(id).zip")]),
        request)
    case ("GET", "cache"):
      guard slots[allocation]?.cacheHandles.contains(name) == true else {
        return .error(404, "not found")
      }
      return ranged(
        await export(allocation, .openCache(handle: name), type: "application/octet-stream"),
        request)
    default:
      return .error(405, "method not allowed")
    }
  }

  /// Applies a single `Range: bytes=a-b` to a file response.
  private func ranged(_ response: DataPlaneResponse, _ request: DataPlaneRequest)
    -> DataPlaneResponse
  {
    guard response.status == 200, case .file(let path, _, let length) = response.body,
      let header = request.headers["range"] ?? request.headers["x-ms-range"],
      header.hasPrefix("bytes=")
    else { return response }
    let spec = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard spec.count == 2, let start = UInt64(spec[0]), start < length else {
      PrivateFiles.remove(path)
      return .error(416, "range not satisfiable")
    }
    let end = spec[1].isEmpty ? length - 1 : min(UInt64(spec[1]) ?? (length - 1), length - 1)
    guard end >= start else {
      PrivateFiles.remove(path)
      return .error(416, "range not satisfiable")
    }
    var result = DataPlaneResponse(
      status: 206,
      headers: response.headers + [("Content-Range", "bytes \(start)-\(end)/\(length)")],
      body: .file(path: path, offset: start, length: end - start + 1))
    result.headers.append(("Accept-Ranges", "bytes"))
    return result
  }

  enum Budget { case log, upload }

  /// Azure-compatible blob writes: whole-blob PUT, append-blob create and
  /// `comp=appendblock`, and block blobs (`comp=block`, `comp=blocklist`).
  private func putBlob(
    _ allocation: AllocationID, key: String, request: DataPlaneRequest, budget: Budget
  )
    -> DataPlaneResponse
  {
    guard var slot = slots[allocation] else { return .error(404, "not found") }
    let limit = budget == .log ? slot.grant.logBytes : slot.grant.uploadBytes
    let incoming = UInt64(request.body.count)
    func charge(_ bytes: UInt64) -> Bool {
      switch budget {
      case .log:
        guard slot.logBytes + bytes <= slot.grant.logBytes else { return false }
        slot.logBytes += bytes
      case .upload:
        guard slot.uploadedBytes + bytes <= slot.grant.uploadBytes else { return false }
        slot.uploadedBytes += bytes
      }
      return true
    }
    let created = DataPlaneResponse(status: 201, headers: [("ETag", "\"\(randomHex(bytes: 8))\"")])
    do {
      switch request.query["comp"] {
      case nil:
        guard slot.blobs[key] != nil || slot.blobs.count < settings.maxBlobsPerAllocation else {
          return .error(429, "too many staged blobs")
        }
        guard incoming <= limit, charge(incoming) else {
          return .error(413, "blob exceeds its budget")
        }
        if let previous = slot.blobs[key] { PrivateFiles.remove(inPath(previous.file)) }
        let file = randomHex(bytes: 16)
        try PrivateFiles.write(request.body, to: inPath(file))
        let appendable =
          request.headers["x-ms-blob-type"] == "AppendBlob" || (budget == .log && incoming == 0)
        slot.blobs[key] = BlobUpload(
          file: file, size: incoming, appendable: appendable, sealed: false, blocks: [:])
      case "appendblock":
        guard var blob = slot.blobs[key], !blob.sealed else {
          return .error(409, "blob is not appendable")
        }
        guard blob.size + incoming <= limit, charge(incoming) else {
          return .error(413, "blob exceeds its budget")
        }
        try Self.append(request.body, to: inPath(blob.file), at: blob.size)
        blob.size += incoming
        if request.query["seal"] == "true"
          || request.headers["x-ms-blob-sealed"]?.lowercased() == "true"
        {
          blob.sealed = true
        }
        slot.blobs[key] = blob
      case "block":
        guard let blockID = request.query["blockid"], (1...128).contains(blockID.utf8.count) else {
          return .error(400, "invalid block id")
        }
        guard slot.blobs[key] != nil || slot.blobs.count < settings.maxBlobsPerAllocation else {
          return .error(429, "too many staged blobs")
        }
        var blob =
          slot.blobs[key]
          ?? BlobUpload(
            file: randomHex(bytes: 16), size: 0, appendable: false, sealed: false, blocks: [:])
        guard blob.blocks.count < settings.maxBlocksPerBlob, incoming <= limit, charge(incoming)
        else {
          return .error(413, "blob exceeds its budget")
        }
        let file = randomHex(bytes: 16)
        try PrivateFiles.write(request.body, to: inPath(file))
        if let previous = blob.blocks[blockID] { PrivateFiles.remove(inPath(previous.file)) }
        blob.blocks[blockID] = (file, incoming)
        slot.blobs[key] = blob
      case "blocklist":
        guard var blob = slot.blobs[key] else { return .error(404, "no staged blocks") }
        // Each staged block may appear once: a list repeating a block id
        // would amplify the staged bytes into a much larger blob.
        guard let ids = Self.blockList(request.body), Set(ids).count == ids.count else {
          return .error(400, "invalid block list")
        }
        var total: UInt64 = 0
        for id in ids {
          guard let block = blob.blocks[id] else {
            return .error(400, "block list names an unknown block")
          }
          total += block.size
        }
        guard total <= limit else { return .error(413, "blob exceeds its budget") }
        let assembled = randomHex(bytes: 16)
        try PrivateFiles.write([], to: inPath(assembled))
        var offset: UInt64 = 0
        for id in ids {
          guard let block = blob.blocks[id],
            let bytes = try PrivateFiles.read(inPath(block.file), limit: Int(block.size))
          else { return .error(400, "block is gone") }
          try Self.append(bytes, to: inPath(assembled), at: offset)
          offset += UInt64(bytes.count)
        }
        for block in blob.blocks.values { PrivateFiles.remove(inPath(block.file)) }
        PrivateFiles.remove(inPath(blob.file))
        blob = BlobUpload(
          file: assembled, size: offset, appendable: false, sealed: true, blocks: [:])
        slot.blobs[key] = blob
      default:
        return .error(400, "unsupported blob operation")
      }
    } catch {
      return .error(500, "cannot stage the upload")
    }
    slots[allocation] = slot
    return created
  }

  static func append(_ bytes: [UInt8], to path: String, at offset: UInt64) throws(CIError) {
    let fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw CIError.storage("cannot open a staged upload") }
    defer { close(fd) }
    var written = 0
    while written < bytes.count {
      let count = bytes.withUnsafeBytes {
        pwrite(fd, $0.baseAddress! + written, $0.count - written, off_t(offset) + off_t(written))
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw CIError.storage("cannot write a staged upload")
      }
      written += count
    }
  }

  /// `<BlockList><Latest|Committed|Uncommitted>id</…>…</BlockList>`, in order.
  static func blockList(_ body: [UInt8]) -> [String]? {
    guard body.count <= 8 << 20, let text = String(validating: body, as: UTF8.self) else {
      return nil
    }
    guard text.contains("<BlockList>") || text.contains("<BlockList ") else { return nil }
    var ids: [String] = []
    var rest = Substring(text)
    while let open = rest.range(of: "<Latest>") ?? rest.range(of: "<Uncommitted>")
      ?? rest.range(of: "<Committed>")
    {
      let tag = String(rest[open].dropFirst().dropLast())
      guard let close = rest.range(of: "</\(tag)>", range: open.upperBound..<rest.endIndex) else {
        return nil
      }
      let id = String(rest[open.upperBound..<close.lowerBound])
      guard (1...128).contains(id.utf8.count) else { return nil }
      ids.append(id)
      rest = rest[close.upperBound...]
      if ids.count > 50_000 { return nil }
    }
    return ids.isEmpty ? nil : ids
  }

  // MARK: Cache v1

  private func cache(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    let resource = String(request.path.dropFirst("/cache/_apis/artifactcache/".count))
    switch (request.method, resource) {
    case ("GET", "cache"):
      guard let joined = request.query["keys"], let version = request.query["version"] else {
        return .error(400, "keys and version are required")
      }
      let keys = joined.split(separator: ",", omittingEmptySubsequences: false).map {
        String($0).trimmingCharacters(in: .whitespaces)
      }
      let reply: JSONValue
      do {
        reply = try await backend.call(allocation, .cacheLookup(keys: keys, version: version))
      } catch {
        return .error(400, error.message)
      }
      guard reply != .null else { return .empty(204) }
      guard let key = reply["key"]?.stringValue, let handle = reply["handle"]?.stringValue,
        DataPlaneWire.isFileName(handle)
      else { return .error(500, "invalid cache entry") }
      slots[allocation]?.cacheHandles.insert(handle)
      let created = reply["created_at"]?.intValue ?? now
      return .json(
        200,
        [
          "cacheKey": .string(key), "scope": "refs/heads/iso-ci", "cacheVersion": .string(version),
          "creationTime": .string(
            Self.timestamp(Date(timeIntervalSince1970: TimeInterval(created)))),
          "archiveLocation": .string(signedURL(allocation, "/isoci/cache/\(handle)")),
        ])
    case ("GET", "caches"):
      return .json(200, ["totalCount": 0, "artifactCaches": []])
    case ("POST", "caches"):
      guard let body = try? StrictJSON.parse(request.body, limits: .guestRequest),
        let key = body["key"]?.stringValue, let version = body["version"]?.stringValue
      else { return .error(400, "invalid reservation") }
      guard (slots[allocation]?.cacheReservations ?? 0) < settings.maxCacheReservations else {
        return .error(429, "too many cache reservations")
      }
      if let size = body["cacheSize"]?.intValue,
        size < 0 || UInt64(size) > (slots[allocation]?.grant.uploadBytes ?? 0)
      {
        return .error(400, "cache size exceeds the upload budget")
      }
      let reply: JSONValue
      do {
        reply = try await backend.call(allocation, .cacheReserve(key: key, version: version))
      } catch {
        return .error(error.code == .conflict ? 409 : 400, error.message)
      }
      guard let id = reply["cache_id"]?.intValue, id > 0 else {
        return .error(409, "cache entry already exists or is being written")
      }
      let file = randomHex(bytes: 16)
      do { try PrivateFiles.write([], to: inPath(file)) } catch {
        return .error(500, "cannot stage the upload")
      }
      slots[allocation]?.cacheUploads[id] = CacheUpload(file: file)
      slots[allocation]?.cacheReservations += 1
      return .json(201, ["cacheId": .integer(id)])
    default:
      guard resource.hasPrefix("caches/"), let id = Int64(resource.dropFirst(7)),
        var upload = slots[allocation]?.cacheUploads[id], var slot = slots[allocation]
      else { return .error(404, "unknown cache reservation") }
      switch request.method {
      case "PATCH":
        guard let range = request.headers["content-range"],
          let (start, end) = Self.contentRange(range),
          end >= start, end - start + 1 == UInt64(request.body.count),
          end < slot.grant.uploadBytes
        else { return .error(400, "invalid content range") }
        // Growth of the high-water mark is charged (sparse writes cannot
        // reserve disk for free).
        let growth = end + 1 > upload.highWater ? end + 1 - upload.highWater : 0
        guard slot.uploadedBytes + growth <= slot.grant.uploadBytes else {
          return .error(413, "upload budget exhausted")
        }
        do { try Self.append(request.body, to: inPath(upload.file), at: start) } catch {
          return .error(500, "cannot stage the upload")
        }
        slot.uploadedBytes += growth
        upload.highWater += growth
        upload.record(start, end)
        slot.cacheUploads[id] = upload
        slots[allocation] = slot
        return .empty(204)
      case "POST":
        guard let body = try? StrictJSON.parse(request.body, limits: .guestRequest),
          let size = body["size"]?.intValue, size >= 0, UInt64(size) == upload.highWater,
          upload.covers(size: UInt64(size))
        else { return .error(400, "size does not match the uploaded content") }
        slots[allocation]?.cacheUploads[id] = nil
        do {
          _ = try await backend.call(
            allocation, .cacheCommit(cacheID: id, file: upload.file, size: UInt64(size)))
        } catch {
          PrivateFiles.remove(inPath(upload.file))
          return .error(400, error.message)
        }
        return .empty(204)
      default:
        return .error(405, "method not allowed")
      }
    }
  }

  /// `bytes start-end/*` (or `/total`).
  static func contentRange(_ header: String) -> (UInt64, UInt64)? {
    guard header.hasPrefix("bytes ") else { return nil }
    let range = header.dropFirst(6).split(separator: "/").first ?? ""
    let parts = range.split(separator: "-")
    guard parts.count == 2, let start = UInt64(parts[0]), let end = UInt64(parts[1]) else {
      return nil
    }
    return (start, end)
  }

  // MARK: Artifacts v4 (twirp)

  private func artifacts(_ allocation: AllocationID, _ request: DataPlaneRequest) async
    -> DataPlaneResponse
  {
    guard let slot = slots[allocation], request.method == "POST",
      let body = try? StrictJSON.parse(request.body, limits: .guestRequest)
    else { return .twirp(400, "malformed", "invalid request") }
    func field(_ snake: String, _ camel: String) -> JSONValue? { body[snake] ?? body[camel] }
    let run = field("workflow_run_backend_id", "workflowRunBackendId")?.stringValue?.lowercased()
    let job = field("workflow_job_run_backend_id", "workflowJobRunBackendId")?.stringValue?
      .lowercased()
    guard run == slot.grant.planID else {
      return .twirp(403, "permission_denied", "artifacts are scoped to this run")
    }
    let method = String(request.path.split(separator: "/").last ?? "")
    switch method {
    case "CreateArtifact":
      guard job == slot.grant.jobID, let name = field("name", "name")?.stringValue else {
        return .twirp(400, "invalid_argument", "invalid artifact request")
      }
      let reply: JSONValue
      do { reply = try await backend.call(allocation, .artifactCreate(name: name)) } catch {
        return .twirp(
          error.code == .conflict ? 409 : 400,
          error.code == .conflict ? "already_exists" : "invalid_argument", error.message)
      }
      guard let id = reply["id"]?.intValue, id > 0 else {
        return .twirp(500, "internal", "invalid reply")
      }
      slots[allocation]?.artifactsByName[name] = id
      return .json(
        200,
        ["ok": true, "signed_upload_url": .string(signedURL(allocation, "/isoci/artifacts/\(id)"))])
    case "FinalizeArtifact":
      guard job == slot.grant.jobID, let name = field("name", "name")?.stringValue,
        let id = slot.artifactsByName[name], let blob = slot.blobs["artifacts/\(id)"],
        blob.sealed || blob.blocks.isEmpty,
        let size = field("size", "size").flatMap({
          $0.intValue ?? $0.stringValue.flatMap { Int64($0) }
        }),
        size >= 0, UInt64(size) == blob.size
      else { return .twirp(400, "invalid_argument", "artifact upload is incomplete") }
      let hash = field("hash", "hash")?.stringValue.flatMap { try? Digest(prefixed: $0) }
      slots[allocation]?.blobs["artifacts/\(id)"] = nil
      do {
        _ = try await backend.call(
          allocation, .artifactFinalize(id: id, file: blob.file, size: UInt64(size), hash: hash))
      } catch {
        PrivateFiles.remove(inPath(blob.file))
        return .twirp(400, "invalid_argument", error.message)
      }
      return .json(200, ["ok": true, "artifact_id": .string(String(id))])
    case "ListArtifacts", "GetSignedArtifactURL":
      let nameFilter: String? =
        method == "GetSignedArtifactURL"
        ? field("name", "name")?.stringValue : field("name_filter", "nameFilter")?.stringValue
      let idFilter = field("id_filter", "idFilter").flatMap {
        $0.intValue ?? $0.stringValue.flatMap { Int64($0) }
      }
      let reply: JSONValue
      do {
        reply = try await backend.call(
          allocation, .artifactList(nameFilter: nameFilter, idFilter: idFilter))
      } catch {
        return .twirp(400, "invalid_argument", error.message)
      }
      guard case .array(let items)? = reply["artifacts"] else {
        return .twirp(500, "internal", "invalid reply")
      }
      var listed: [JSONValue] = []
      for item in items {
        guard let id = item["id"]?.intValue, let name = item["name"]?.stringValue else { continue }
        slots[allocation]?.visibleArtifacts.insert(id)
        var entry: [String: JSONValue] = [
          "workflow_run_backend_id": .string(slot.grant.planID),
          "workflow_job_run_backend_id": .string(item["job"]?.stringValue ?? slot.grant.jobID),
          "database_id": .string(String(id)), "name": .string(name),
          "size": .string(String(item["size"]?.intValue ?? 0)),
          "created_at": .string(
            Self.timestamp(
              Date(timeIntervalSince1970: TimeInterval(item["created_at"]?.intValue ?? now)))),
        ]
        if let digest = item["digest"]?.stringValue {
          entry["digest"] = .string("sha256:" + digest)
        }
        listed.append(.object(entry))
      }
      if method == "ListArtifacts" { return .json(200, ["artifacts": .array(listed)]) }
      guard let first = listed.first, let id = first["database_id"]?.stringValue else {
        return .twirp(404, "not_found", "artifact not found")
      }
      return .json(200, ["signed_url": .string(signedURL(allocation, "/isoci/artifact/\(id).zip"))])
    case "DeleteArtifact", "MigrateArtifact":
      return .twirp(403, "permission_denied", "\(method) is not supported by local preflight")
    default:
      return .twirp(404, "bad_route", "unknown method")
    }
  }

  // MARK: Paths

  private func inPath(_ name: String) -> String { staging + "/in/" + name }
  private func outPath(_ name: String) -> String { staging + "/out/" + name }
}
