import Foundation

/// The bounded, versioned message channel between the controller and the
/// confined data-plane child (spec section 3). Frames are canonical JSON
/// Lines on the child's stdin/stdout; both sides parse with `StrictJSON` and
/// refuse unknown fields. The child can only *ask*: every object access,
/// upload commit and job event is re-validated and authorized by the
/// controller against its own allocation registry.
package enum DataPlaneWire {
  package static let version = "iso-ci.dataplane/v1"
  /// Registration carries the job message; everything else is small.
  package static let maxFrameBytes = 4 << 20
  package static let limits = JSONLimits(
    maxBytes: maxFrameBytes, maxDepth: 64, maxKeys: 65_536, maxArrayElements: 16_384)
  /// Files exchanged through the child's staging directory are named by 32
  /// lowercase hex characters, in `in/` (child → controller) or `out/`.
  package static func isFileName(_ name: String) -> Bool {
    name.utf8.count == 32 && Array(name.utf8).allSatisfy(isLowerHex)
  }
}

/// What the child needs to serve one allocation. It never contains a host
/// credential; the runner key is a public key and the iso bearer is a hash.
package struct DataPlaneGrant: Sendable, Equatable {
  package let allocation: AllocationID
  package let attempt: JobAttemptID
  /// The runner OAuth client id (random per allocation).
  package let clientID: String
  package let runnerPublicKeyDER: [UInt8]
  package let isoVerifier: Digest
  package let guestHost: GuestEndpointHost
  package let guestPort: UInt16
  package let planID: String
  package let jobID: String
  /// The job message with the access-token placeholder.
  package let jobMessage: JSONValue
  /// Absolute expiry of every token minted for this allocation.
  package let expiresAt: Int64
  package let trafficBytes: UInt64
  package let uploadBytes: UInt64
  package let logBytes: UInt64

  package init(
    allocation: AllocationID, attempt: JobAttemptID, clientID: String, runnerPublicKeyDER: [UInt8],
    isoVerifier: Digest, guestHost: GuestEndpointHost = .loopback, guestPort: UInt16,
    planID: String, jobID: String, jobMessage: JSONValue,
    expiresAt: Int64, trafficBytes: UInt64, uploadBytes: UInt64, logBytes: UInt64
  ) {
    self.allocation = allocation
    self.attempt = attempt
    self.clientID = clientID
    self.runnerPublicKeyDER = runnerPublicKeyDER
    self.isoVerifier = isoVerifier
    self.guestHost = guestHost
    self.guestPort = guestPort
    self.planID = planID
    self.jobID = jobID
    self.jobMessage = jobMessage
    self.expiresAt = expiresAt
    self.trafficBytes = trafficBytes
    self.uploadBytes = uploadBytes
    self.logBytes = logBytes
  }

  package var json: JSONValue {
    [
      "allocation": .string(allocation.rawValue), "attempt": .string(attempt.rawValue),
      "client_id": .string(clientID),
      "runner_public_key": .string(Data(runnerPublicKeyDER).base64EncodedString()),
      "iso_verifier": .string(isoVerifier.rawValue), "guest_host": .string(guestHost.rawValue),
      "guest_port": .integer(Int64(guestPort)),
      "plan_id": .string(planID), "job_id": .string(jobID), "job_message": jobMessage,
      "expires_at": .integer(expiresAt), "traffic_bytes": .integer(Int64(trafficBytes)),
      "upload_bytes": .integer(Int64(uploadBytes)), "log_bytes": .integer(Int64(logBytes)),
    ]
  }

  package init(json value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "grant")
    allocation = try r.parsed("allocation") { try AllocationID($0) }
    attempt = try r.parsed("attempt") { try JobAttemptID($0) }
    clientID = try r.string("client_id")
    guard isCanonicalUUID(clientID) else { throw CIError.invalid("invalid grant.client_id") }
    guard let key = Data(base64Encoded: try r.string("runner_public_key")),
      (64...2_048).contains(key.count)
    else { throw CIError.invalid("invalid grant.runner_public_key") }
    runnerPublicKeyDER = Array(key)
    isoVerifier = try r.parsed("iso_verifier") { try Digest($0) }
    guestHost = try r.enumeration("guest_host", as: GuestEndpointHost.self)
    let port = try r.unsigned("guest_port")
    guard (1...65_535).contains(port) else { throw CIError.invalid("invalid grant.guest_port") }
    guestPort = UInt16(port)
    planID = try r.string("plan_id")
    jobID = try r.string("job_id")
    guard isCanonicalUUID(planID), isCanonicalUUID(jobID) else {
      throw CIError.invalid("invalid grant identifiers")
    }
    jobMessage = try r.required("job_message")
    guard case .object = jobMessage else {
      throw CIError.invalid("grant.job_message must be an object")
    }
    expiresAt = try r.int("expires_at")
    trafficBytes = try r.unsigned("traffic_bytes")
    uploadBytes = try r.unsigned("upload_bytes")
    logBytes = try r.unsigned("log_bytes")
    try r.finish()
  }
}

/// A request from the endpoint to the controller on behalf of one
/// allocation. Every parameter is validated on decode.
package enum DataPlaneCall: Sendable, Equatable {
  case resolveActions([ActionRequest])
  /// Export an approved action archive (by its resolved commit).
  case openAction(nameWithOwner: String, commit: String)
  /// Export the snapshot granted to this attempt.
  case openSnapshot(Digest)
  case cacheLookup(keys: [String], version: String)
  /// Export a cache entry returned by a previous lookup.
  case openCache(handle: String)
  case cacheReserve(key: String, version: String)
  /// Commit a reserved cache entry from a staged child file.
  case cacheCommit(cacheID: Int64, file: String, size: UInt64)
  case artifactCreate(name: String)
  case artifactFinalize(id: Int64, file: String, size: UInt64, hash: Digest?)
  case artifactList(nameFilter: String?, idFilter: Int64?)
  /// Export a finalized artifact of this run by id (after authorization).
  case openArtifact(id: Int64)
  case logCommit(kind: LogKind, step: String?, file: String, lines: UInt64)

  package struct ActionRequest: Sendable, Equatable, Hashable {
    package let action: String
    package let version: String
    package let path: String

    package init(action: String, version: String, path: String) {
      self.action = action
      self.version = version
      self.path = path
    }
  }

  package enum LogKind: String, Sendable, CaseIterable {
    case step, job, summary, diagnostic
  }

  package var name: String {
    switch self {
    case .resolveActions: "resolve_actions"
    case .openAction: "open_action"
    case .openSnapshot: "open_snapshot"
    case .cacheLookup: "cache_lookup"
    case .openCache: "open_cache"
    case .cacheReserve: "cache_reserve"
    case .cacheCommit: "cache_commit"
    case .artifactCreate: "artifact_create"
    case .artifactFinalize: "artifact_finalize"
    case .artifactList: "artifact_list"
    case .openArtifact: "open_artifact"
    case .logCommit: "log_commit"
    }
  }

  package var params: JSONValue {
    switch self {
    case .resolveActions(let actions):
      return [
        "actions": .array(
          actions.map {
            [
              "action": .string($0.action), "version": .string($0.version),
              "path": .string($0.path),
            ]
          })
      ]
    case .openAction(let name, let commit):
      return ["name": .string(name), "commit": .string(commit)]
    case .openSnapshot(let digest): return ["digest": .string(digest.rawValue)]
    case .cacheLookup(let keys, let version):
      return ["keys": .array(keys.map(JSONValue.string)), "version": .string(version)]
    case .openCache(let handle): return ["handle": .string(handle)]
    case .cacheReserve(let key, let version):
      return ["key": .string(key), "version": .string(version)]
    case .cacheCommit(let id, let file, let size):
      return ["cache_id": .integer(id), "file": .string(file), "size": .integer(Int64(size))]
    case .artifactCreate(let name): return ["name": .string(name)]
    case .artifactFinalize(let id, let file, let size, let hash):
      var members: [String: JSONValue] = [
        "id": .integer(id), "file": .string(file), "size": .integer(Int64(size)),
      ]
      if let hash { members["hash"] = .string(hash.rawValue) }
      return .object(members)
    case .artifactList(let name, let id):
      var members: [String: JSONValue] = [:]
      if let name { members["name"] = .string(name) }
      if let id { members["id"] = .integer(id) }
      return .object(members)
    case .openArtifact(let id): return ["id": .integer(id)]
    case .logCommit(let kind, let step, let file, let lines):
      var members: [String: JSONValue] = [
        "kind": .string(kind.rawValue), "file": .string(file), "lines": .integer(Int64(lines)),
      ]
      if let step { members["step"] = .string(step) }
      return .object(members)
    }
  }

  package init(name: String, params: JSONValue) throws(CIError) {
    var r = try ObjectReader(params, field: "params")
    func file(_ r: inout ObjectReader) throws(CIError) -> String {
      let value = try r.string("file")
      guard DataPlaneWire.isFileName(value) else { throw CIError.invalid("invalid params.file") }
      return value
    }
    switch name {
    case "resolve_actions":
      let items = try r.array("actions")
      guard (1...64).contains(items.count) else {
        throw CIError.invalid("1-64 actions per request")
      }
      var actions: [ActionRequest] = []
      for item in items {
        var a = try ObjectReader(item, field: "action")
        let action = try a.string("action")
        let version = try a.string("version")
        let path = try a.string("path")
        try a.finish()
        guard (1...200).contains(action.utf8.count), (1...200).contains(version.utf8.count),
          path.utf8.count <= 512
        else { throw CIError.invalid("invalid action reference") }
        actions.append(ActionRequest(action: action, version: version, path: path))
      }
      self = .resolveActions(actions)
    case "open_action":
      let name = try r.string("name")
      let commit = try r.string("commit")
      guard (1...200).contains(name.utf8.count), commit.utf8.count == 40,
        Array(commit.utf8).allSatisfy(isLowerHex)
      else { throw CIError.invalid("invalid action archive request") }
      self = .openAction(nameWithOwner: name, commit: commit)
    case "open_snapshot":
      self = .openSnapshot(try r.parsed("digest") { try Digest($0) })
    case "cache_lookup":
      let keys = try r.strings("keys")
      guard (1...(ObjectStore.maxRestoreKeys + 1)).contains(keys.count),
        keys.allSatisfy(ObjectStore.validCacheKey)
      else { throw CIError.invalid("invalid cache keys") }
      let version = try r.string("version")
      guard (1...512).contains(version.utf8.count) else {
        throw CIError.invalid("invalid cache version")
      }
      self = .cacheLookup(keys: keys, version: version)
    case "open_cache":
      let handle = try r.string("handle")
      guard DataPlaneWire.isFileName(handle) else { throw CIError.invalid("invalid cache handle") }
      self = .openCache(handle: handle)
    case "cache_reserve":
      let key = try r.string("key")
      let version = try r.string("version")
      guard ObjectStore.validCacheKey(key), (1...512).contains(version.utf8.count) else {
        throw CIError.invalid("invalid cache key or version")
      }
      self = .cacheReserve(key: key, version: version)
    case "cache_commit":
      let id = try r.int("cache_id")
      guard id > 0 else { throw CIError.invalid("invalid cache id") }
      self = .cacheCommit(cacheID: id, file: try file(&r), size: try r.unsigned("size"))
    case "artifact_create":
      let name = try r.string("name")
      guard ObjectStore.validArtifactName(name) else {
        throw CIError.invalid("invalid artifact name")
      }
      self = .artifactCreate(name: name)
    case "artifact_finalize":
      let id = try r.int("id")
      guard id > 0 else { throw CIError.invalid("invalid artifact id") }
      self = .artifactFinalize(
        id: id, file: try file(&r), size: try r.unsigned("size"),
        hash: try r.optionalParsed("hash") { try Digest($0) })
    case "artifact_list":
      let name = try r.optionalString("name")
      if let name, !ObjectStore.validArtifactName(name) {
        throw CIError.invalid("invalid artifact name")
      }
      self = .artifactList(nameFilter: name, idFilter: try r.optionalInt("id"))
    case "open_artifact":
      let id = try r.int("id")
      guard id > 0 else { throw CIError.invalid("invalid artifact id") }
      self = .openArtifact(id: id)
    case "log_commit":
      guard let kind = LogKind(rawValue: try r.string("kind")) else {
        throw CIError.invalid("invalid log kind")
      }
      let step = try r.optionalString("step")
      if let step, !isCanonicalUUID(step) { throw CIError.invalid("invalid log step") }
      self = .logCommit(kind: kind, step: step, file: try file(&r), lines: try r.unsigned("lines"))
    default:
      throw CIError.invalid("unknown data-plane call")
    }
    try r.finish()
  }
}

/// Job progress the endpoint reports. Values are bounded on decode.
package enum DataPlaneEvent: Sendable, Equatable {
  case sessionCreated
  case jobAcquired
  case steps([StepStatus])
  case completed(JobResult)
  case sessionClosed

  package struct StepStatus: Sendable, Equatable {
    package let id: String
    package let number: Int64
    package let name: String
    /// `pending`, `in_progress`, `completed` or `unknown`.
    package let status: String
    /// `success`, `failure`, `cancelled`, `skipped` or nil.
    package let conclusion: String?

    package init(id: String, number: Int64, name: String, status: String, conclusion: String?) {
      self.id = id
      self.number = number
      self.name = name
      self.status = status
      self.conclusion = conclusion
    }
  }

  /// The runner's reported job result. A succeeded runner process is not
  /// the job's conclusion; only this report is.
  package struct JobResult: Sendable, Equatable {
    package let conclusion: String
    package let outputs: [String: String]
    package let steps: [StepStatus]
    package let annotations: [String]

    package init(
      conclusion: String, outputs: [String: String], steps: [StepStatus], annotations: [String]
    ) {
      self.conclusion = conclusion
      self.outputs = outputs
      self.steps = steps
      self.annotations = annotations
    }
  }

  package static let maxSteps = 1_000
  package static let maxOutputs = 256
  package static let maxOutputBytes = 1 << 20
  package static let maxAnnotations = 100
  package static let conclusions: Set<String> = [
    "succeeded", "succeeded_with_issues", "failed", "canceled", "skipped", "abandoned",
  ]

  package var json: JSONValue {
    switch self {
    case .sessionCreated: return ["kind": "session_created"]
    case .jobAcquired: return ["kind": "job_acquired"]
    case .sessionClosed: return ["kind": "session_closed"]
    case .steps(let steps): return ["kind": "steps", "steps": .array(steps.map(Self.stepJSON))]
    case .completed(let result):
      return [
        "kind": "completed", "conclusion": .string(result.conclusion),
        "outputs": .object(result.outputs.mapValues(JSONValue.string)),
        "steps": .array(result.steps.map(Self.stepJSON)),
        "annotations": .array(result.annotations.map(JSONValue.string)),
      ]
    }
  }

  static func stepJSON(_ step: StepStatus) -> JSONValue {
    var members: [String: JSONValue] = [
      "id": .string(step.id), "number": .integer(step.number), "name": .string(step.name),
      "status": .string(step.status),
    ]
    if let conclusion = step.conclusion { members["conclusion"] = .string(conclusion) }
    return .object(members)
  }

  static func step(_ value: JSONValue) throws(CIError) -> StepStatus {
    var r = try ObjectReader(value, field: "step")
    let id = try r.string("id")
    let number = try r.int("number")
    let name = CIError.bounded(String(try r.string("name").prefix(512)))
    let status = try r.string("status")
    let conclusion = try r.optionalString("conclusion")
    try r.finish()
    guard id.utf8.count <= 64, ["pending", "in_progress", "completed", "unknown"].contains(status),
      conclusion.map({ ["success", "failure", "cancelled", "skipped"].contains($0) }) ?? true
    else { throw CIError.invalid("invalid step status") }
    return StepStatus(id: id, number: number, name: name, status: status, conclusion: conclusion)
  }

  package init(json value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "event")
    switch try r.string("kind") {
    case "session_created": self = .sessionCreated
    case "job_acquired": self = .jobAcquired
    case "session_closed": self = .sessionClosed
    case "steps":
      let items = try r.array("steps")
      guard items.count <= Self.maxSteps else { throw CIError.invalid("too many steps") }
      var steps: [StepStatus] = []
      for item in items { steps.append(try Self.step(item)) }
      self = .steps(steps)
    case "completed":
      let conclusion = try r.string("conclusion")
      guard Self.conclusions.contains(conclusion) else {
        throw CIError.invalid("invalid conclusion")
      }
      guard case .object(let rawOutputs) = try r.required("outputs"),
        rawOutputs.count <= Self.maxOutputs
      else { throw CIError.invalid("invalid outputs") }
      var outputs: [String: String] = [:]
      var bytes = 0
      for (key, value) in rawOutputs {
        guard let text = value.stringValue, (1...200).contains(key.utf8.count) else {
          throw CIError.invalid("invalid output")
        }
        bytes += key.utf8.count + text.utf8.count
        outputs[key] = text
      }
      guard bytes <= Self.maxOutputBytes else { throw CIError.invalid("outputs are too large") }
      let items = try r.array("steps")
      guard items.count <= Self.maxSteps else { throw CIError.invalid("too many steps") }
      var steps: [StepStatus] = []
      for item in items { steps.append(try Self.step(item)) }
      let annotations = try r.strings("annotations")
      guard annotations.count <= Self.maxAnnotations else {
        throw CIError.invalid("too many annotations")
      }
      self = .completed(
        JobResult(
          conclusion: conclusion, outputs: outputs, steps: steps,
          annotations: annotations.map { CIError.bounded(String($0.prefix(1_024))) }))
    default:
      throw CIError.invalid("unknown event")
    }
    try r.finish()
  }
}

/// One frame on the channel.
package enum DataPlaneFrame: Sendable, Equatable {
  // controller → child (`register` is acknowledged with a `reply`)
  case register(id: Int64, grant: DataPlaneGrant)
  case unregister(AllocationID)
  case cancel(AllocationID)
  /// Either direction: the answer to `register` or to a `request`.
  case reply(id: Int64, result: Result<JSONValue, CIError>)
  case shutdown
  // child → controller
  case ready
  case request(id: Int64, allocation: AllocationID, call: DataPlaneCall)
  case event(allocation: AllocationID, DataPlaneEvent)

  package var json: JSONValue {
    var members: [String: JSONValue] = ["v": .string(DataPlaneWire.version)]
    switch self {
    case .register(let id, let grant):
      members["type"] = "register"
      members["id"] = .integer(id)
      members["grant"] = grant.json
    case .unregister(let allocation):
      members["type"] = "unregister"
      members["allocation"] = .string(allocation.rawValue)
    case .cancel(let allocation):
      members["type"] = "cancel"
      members["allocation"] = .string(allocation.rawValue)
    case .reply(let id, let result):
      members["type"] = "reply"
      members["id"] = .integer(id)
      switch result {
      case .success(let value): members["result"] = value
      case .failure(let error): members["error"] = error.json
      }
    case .shutdown:
      members["type"] = "shutdown"
    case .ready:
      members["type"] = "ready"
    case .request(let id, let allocation, let call):
      members["type"] = "request"
      members["id"] = .integer(id)
      members["allocation"] = .string(allocation.rawValue)
      members["call"] = .string(call.name)
      members["params"] = call.params
    case .event(let allocation, let event):
      members["type"] = "event"
      members["allocation"] = .string(allocation.rawValue)
      members["event"] = event.json
    }
    return .object(members)
  }

  package var frame: [UInt8] { json.frame }

  package static func decode(_ bytes: [UInt8]) throws(CIError) -> DataPlaneFrame {
    let value = try StrictJSON.parse(bytes, limits: DataPlaneWire.limits)
    var r = try ObjectReader(value, field: "frame")
    guard try r.string("v") == DataPlaneWire.version else {
      throw CIError(.unsupported, "unsupported data-plane channel version")
    }
    let frame: DataPlaneFrame
    switch try r.string("type") {
    case "register":
      frame = .register(
        id: try r.int("id"), grant: try DataPlaneGrant(json: try r.required("grant")))
    case "unregister": frame = .unregister(try r.parsed("allocation") { try AllocationID($0) })
    case "cancel": frame = .cancel(try r.parsed("allocation") { try AllocationID($0) })
    case "shutdown": frame = .shutdown
    case "ready": frame = .ready
    case "reply":
      let id = try r.int("id")
      if let error = r.optional("error") {
        frame = .reply(id: id, result: .failure(try CIError(json: error)))
      } else {
        frame = .reply(id: id, result: .success(r.optional("result") ?? .null))
      }
    case "request":
      let id = try r.int("id")
      let allocation = try r.parsed("allocation") { try AllocationID($0) }
      let call = try DataPlaneCall(name: try r.string("call"), params: try r.required("params"))
      frame = .request(id: id, allocation: allocation, call: call)
    case "event":
      frame = .event(
        allocation: try r.parsed("allocation") { try AllocationID($0) },
        try DataPlaneEvent(json: try r.required("event")))
    default:
      throw CIError.invalid("unknown data-plane frame")
    }
    try r.finish()
    return frame
  }
}

/// What the endpoint needs from the controller. `DataPlaneBroker` serves it
/// directly (in-process tests) or through the channel (confined child).
package protocol DataPlaneBackend: Sendable {
  func call(_ allocation: AllocationID, _ call: DataPlaneCall) async throws(CIError) -> JSONValue
  func event(_ allocation: AllocationID, _ event: DataPlaneEvent) async
}
