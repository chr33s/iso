import Foundation

/// The client-supported subset of `iso.host/v1` (spec section 4). iso-ci
/// speaks the host protocol itself: it does not add a parallel execution
/// service or rename host operations, and it sends a new field or method
/// only after the host advertised the capability that defines it.
package enum HostProtocol {
  package static let v1 = "iso.host/v1"
}

/// Host methods this client uses. `host.capabilities` and `run.retain` are
/// the workload-neutral extensions added for the companion; every other
/// method is part of the baseline protocol.
package enum HostMethod: String, Sendable, CaseIterable {
  case hello
  case hostCapabilities = "host.capabilities"
  case vmInspect = "vm.inspect"
  case operationGet = "operation.get"
  case accessOpen = "access.open"
  case accessRenew = "access.renew"
  case accessClose = "access.close"
  case runCreate = "run.create"
  case runInspect = "run.inspect"
  case runComplete = "run.complete"
  case runRetain = "run.retain"
  case runResultsDiscard = "run.results.discard"
  case artifactRead = "artifact.read"

  package var isDurableMutation: Bool {
    switch self {
    case .runCreate, .runComplete, .runRetain, .runResultsDiscard: true
    default: false
    }
  }
}

/// The capability names a host advertises through `host.capabilities`.
package enum HostCapabilityName: String, Sendable, CaseIterable {
  /// The brokered execution handoff (spec section 2).
  case netHandoff1 = "net-handoff-1"
  /// Host-owned live and stopped-disk run retention (`run.retain`).
  case runRetention1 = "run-retention-1"
}

package enum EgressMode: String, Sendable, Codable, CaseIterable {
  case open
  case none
  case filtered
}

/// The full identity of one host VM; mutations and access echo every field.
package struct QualifiedInstance: Hashable, Sendable, Codable {
  package let hostID: HostID
  package let ownerID: OwnerID
  package let instanceID: InstanceID
  package let runtimeID: String
  package let guestOS: String

  package init(
    hostID: HostID, ownerID: OwnerID, instanceID: InstanceID, runtimeID: String, guestOS: String
  ) {
    self.hostID = hostID
    self.ownerID = ownerID
    self.instanceID = instanceID
    self.runtimeID = runtimeID
    self.guestOS = guestOS
  }

  package var wire: JSONValue {
    [
      "host_id": .string(hostID.rawValue), "owner_id": .string(ownerID.rawValue),
      "instance_id": .string(instanceID.rawValue), "runtime_id": .string(runtimeID),
      "guest_os": .string(guestOS),
    ]
  }

  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "instance")
    hostID = try r.parsed("host_id", as: HostID.self)
    ownerID = try r.parsed("owner_id", as: OwnerID.self)
    instanceID = try r.parsed("instance_id", as: InstanceID.self)
    runtimeID = try r.string("runtime_id")
    guard (1...48).contains(runtimeID.utf8.count),
      runtimeID.unicodeScalars.allSatisfy({
        ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
      })
    else { throw CIError.invalid("invalid instance.runtime_id") }
    guestOS = try r.string("guest_os")
    try r.finish()
  }
}

/// The VM shape for `run.create`. The policy hash is computed exactly as the
/// host recomputes it (canonical JSON of the policy fields, SHA-256).
package struct VMSpec: Sendable, Equatable, Codable {
  package let name: String
  package let image: String
  package let imageDigest: Digest?
  package let cpus: UInt32
  package let memoryMiB: UInt64
  package let diskGiB: UInt64
  package let egress: EgressMode

  package init(
    name: String, image: String, imageDigest: Digest?, cpus: UInt32, memoryMiB: UInt64,
    diskGiB: UInt64, egress: EgressMode
  ) throws(CIError) {
    guard (1...64).contains(name.utf8.count),
      name.unicodeScalars.allSatisfy({ isSafeNameScalar($0) && $0 != "." })
    else { throw CIError.invalid("invalid VM name") }
    guard (1...64).contains(image.utf8.count), !image.hasPrefix("."),
      image.unicodeScalars.allSatisfy(isSafeNameScalar)
    else { throw CIError.invalid("invalid image name") }
    guard (1...64).contains(cpus) else { throw CIError.invalid("cpus must be 1-64") }
    guard (256...(1 << 20)).contains(memoryMiB) else {
      throw CIError.invalid("memory_mib out of range")
    }
    guard (1...4_096).contains(diskGiB) else { throw CIError.invalid("disk_gib out of range") }
    self.name = name
    self.image = image
    self.imageDigest = imageDigest
    self.cpus = cpus
    self.memoryMiB = memoryMiB
    self.diskGiB = diskGiB
    self.egress = egress
  }

  package var policyHash: Digest {
    var members: [String: JSONValue] = [
      "image": .string(image), "cpus": .integer(Int64(cpus)),
      "memory_mib": .integer(Int64(memoryMiB)), "disk_gib": .integer(Int64(diskGiB)),
      "guest_os": "linux", "egress": .string(egress.rawValue),
    ]
    if let imageDigest { members["image_digest"] = .string(imageDigest.rawValue) }
    return Digest(hashing: JSONValue.object(members).canonical)
  }

  package var wire: JSONValue {
    var members: [String: JSONValue] = [
      "name": .string(name), "image": .string(image), "cpus": .integer(Int64(cpus)),
      "memory_mib": .integer(Int64(memoryMiB)), "disk_gib": .integer(Int64(diskGiB)),
      "guest_os": "linux", "egress": .string(egress.rawValue),
      "policy_hash": .string(policyHash.rawValue),
    ]
    if let imageDigest { members["image_digest"] = .string(imageDigest.rawValue) }
    return .object(members)
  }
}

/// Retention requested through `run.retain` (host-owned, finite, budgeted).
package enum RetentionMode: String, Sendable, Codable, CaseIterable {
  /// Keep the VM running for debugging until a host-enforced deadline.
  case live
  /// Keep the stopped disk and staged results until a host-enforced deadline.
  case stopped
}

/// One typed request body. Parameter spellings match the host decoder.
package enum HostRequestBody: Sendable, Equatable {
  case hello(clientBuild: String)
  case hostCapabilities
  case vmInspect(QualifiedInstance)
  case operationGet(HostOperationID)
  case accessOpen(AccessOpenRequest)
  case accessRenew(
    session: SessionID, bearer: String, epoch: DaemonEpoch, boot: BootID, policy: Digest)
  case accessClose(session: SessionID, bearer: String, epoch: DaemonEpoch)
  case runCreate(run: HostRunID, spec: VMSpec, outputLimitBytes: UInt64, ttlSeconds: UInt64)
  case runInspect(HostRunID)
  case runComplete(run: HostRunID, expectedGeneration: UInt64, exitStatus: Int32?)
  case runRetain(run: HostRunID, expectedGeneration: UInt64, mode: RetentionMode, seconds: UInt64)
  case runResultsDiscard(run: HostRunID, expectedGeneration: UInt64)
  case artifactRead(handle: ArtifactHandle, offset: UInt64, length: UInt32)

  package static let maxArtifactChunk: UInt32 = 32 << 10

  package var method: HostMethod {
    switch self {
    case .hello: .hello
    case .hostCapabilities: .hostCapabilities
    case .vmInspect: .vmInspect
    case .operationGet: .operationGet
    case .accessOpen: .accessOpen
    case .accessRenew: .accessRenew
    case .accessClose: .accessClose
    case .runCreate: .runCreate
    case .runInspect: .runInspect
    case .runComplete: .runComplete
    case .runRetain: .runRetain
    case .runResultsDiscard: .runResultsDiscard
    case .artifactRead: .artifactRead
    }
  }

  package var params: JSONValue {
    switch self {
    case .hello(let build):
      return ["protocols": [.string(HostProtocol.v1)], "client_build": .string(build)]
    case .hostCapabilities:
      return [:]
    case .vmInspect(let instance):
      return ["instance": instance.wire]
    case .operationGet(let operation):
      return ["operation_id": .string(operation.rawValue)]
    case .accessOpen(let open):
      return open.wire
    case .accessRenew(let session, let bearer, let epoch, let boot, let policy):
      return [
        "session_id": .string(session.rawValue), "bearer": .string(bearer),
        "expected_epoch": .string(epoch.rawValue), "expected_boot": .string(boot.rawValue),
        "policy_hash": .string(policy.rawValue),
      ]
    case .accessClose(let session, let bearer, let epoch):
      return [
        "session_id": .string(session.rawValue), "bearer": .string(bearer),
        "expected_epoch": .string(epoch.rawValue),
      ]
    case .runCreate(let run, let spec, let output, let ttl):
      return [
        "run_id": .string(run.rawValue), "spec": spec.wire,
        "output_limit_bytes": .integer(Int64(output)), "ttl_seconds": .integer(Int64(ttl)),
      ]
    case .runInspect(let run):
      return ["run_id": .string(run.rawValue)]
    case .runComplete(let run, let generation, let status):
      var members: [String: JSONValue] = [
        "run_id": .string(run.rawValue), "expected_generation": .integer(Int64(generation)),
      ]
      if let status { members["exit_status"] = .integer(Int64(status)) }
      return .object(members)
    case .runRetain(let run, let generation, let mode, let seconds):
      return [
        "run_id": .string(run.rawValue), "expected_generation": .integer(Int64(generation)),
        "mode": .string(mode.rawValue), "seconds": .integer(Int64(seconds)),
      ]
    case .runResultsDiscard(let run, let generation):
      return ["run_id": .string(run.rawValue), "expected_generation": .integer(Int64(generation))]
    case .artifactRead(let handle, let offset, let length):
      return [
        "handle": .string(handle.rawValue), "offset": .integer(Int64(offset)),
        "length": .integer(Int64(length)),
      ]
    }
  }
}

package struct AccessOpenRequest: Sendable, Equatable {
  package let instance: QualifiedInstance
  package let expectedEpoch: DaemonEpoch
  package let expectedBoot: BootID
  package let expectedGeneration: UInt64
  package let policyHash: Digest
  package let session: SessionID
  package let client: String
  /// `ssh-ed25519 <base64>` (no comment).
  package let clientPublicKey: String
  package let bearer: String

  package init(
    instance: QualifiedInstance, expectedEpoch: DaemonEpoch, expectedBoot: BootID,
    expectedGeneration: UInt64, policyHash: Digest, session: SessionID, client: String,
    clientPublicKey: String, bearer: String
  ) {
    self.instance = instance
    self.expectedEpoch = expectedEpoch
    self.expectedBoot = expectedBoot
    self.expectedGeneration = expectedGeneration
    self.policyHash = policyHash
    self.session = session
    self.client = client
    self.clientPublicKey = clientPublicKey
    self.bearer = bearer
  }

  var wire: JSONValue {
    [
      "instance": instance.wire, "expected_epoch": .string(expectedEpoch.rawValue),
      "expected_boot": .string(expectedBoot.rawValue),
      "expected_generation": .integer(Int64(expectedGeneration)),
      "policy_hash": .string(policyHash.rawValue), "session_id": .string(session.rawValue),
      "client": .string(client), "client_public_key": .string(clientPublicKey),
      "purpose": "ssh", "bearer": .string(bearer),
    ]
  }
}

/// One request envelope. `hostID`/`ownerID` are absent only on `hello`.
package struct HostRequest: Sendable, Equatable {
  package let requestID: RequestID
  package let hostID: HostID?
  package let ownerID: OwnerID?
  package let operationID: HostOperationID?
  package let body: HostRequestBody

  package init(
    requestID: RequestID = .generate(), hostID: HostID?, ownerID: OwnerID?,
    operationID: HostOperationID? = nil, body: HostRequestBody
  ) {
    self.requestID = requestID
    self.hostID = hostID
    self.ownerID = ownerID
    self.operationID = operationID
    self.body = body
  }

  package var wire: JSONValue {
    var members: [String: JSONValue] = [
      "protocol": .string(HostProtocol.v1), "request_id": .string(requestID.rawValue),
      "method": .string(body.method.rawValue), "params": body.params,
    ]
    if let hostID { members["host_id"] = .string(hostID.rawValue) }
    if let ownerID { members["owner_id"] = .string(ownerID.rawValue) }
    if let operationID { members["operation_id"] = .string(operationID.rawValue) }
    return .object(members)
  }

  package var frame: [UInt8] { wire.frame }
}

/// An error the host returned, kept typed for retry decisions.
package struct HostReplyError: Sendable, Equatable {
  package let code: String
  package let message: String
  package let retry: String
  package let details: [String: String]

  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "error")
    code = try r.string("code")
    message = CIError.bounded(try r.string("message"))
    retry = try r.optionalString("retry") ?? "unsupported"
    var details: [String: String] = [:]
    if let raw = r.optional("details"), case .object(let members) = raw {
      for (key, value) in members { details[key] = value.stringValue.map(CIError.bounded) }
    }
    self.details = details
    r.ignore("details")
    try r.finish()
  }

  package var ciError: CIError {
    let mapped: CIError.Code =
      switch code {
      case "HOST_UNREACHABLE": .hostUnreachable
      case "HOST_IDENTITY_CHANGED", "OWNER_MISMATCH": .hostIdentityChanged
      case "OPERATION_UNCERTAIN": .operationUncertain
      case "UNSUPPORTED_CAPABILITY", "HOST_PROTOCOL_INCOMPATIBLE": .unsupported
      case "LIMIT_EXCEEDED": .budgetExceeded
      case "INSTANCE_NOT_FOUND", "OPERATION_NOT_FOUND", "RESULTS_UNAVAILABLE": .notFound
      case "GENERATION_CONFLICT", "INSTANCE_BUSY", "OPERATION_ID_CONFLICT": .conflict
      default: .hostRefused
      }
    var details = self.details
    details["host_code"] = code
    details["retry"] = retry
    return CIError(mapped, message, details: details)
  }
}

package struct HostResponse: Sendable, Equatable {
  package let requestID: RequestID
  package let hostID: HostID
  package let ownerID: OwnerID
  package let epoch: DaemonEpoch
  package let outcome: Result<JSONValue, HostReplyErrorBox>

  package static func decode(frame: [UInt8]) throws(CIError) -> HostResponse {
    let value = try StrictJSON.parse(frame, limits: .hostReply)
    var r = try ObjectReader(value, field: "")
    guard try r.string("protocol") == HostProtocol.v1 else {
      throw CIError(.unsupported, "host replied with another protocol version")
    }
    let requestID = try r.parsed("request_id", as: RequestID.self)
    let hostID = try r.parsed("host_id", as: HostID.self)
    let ownerID = try r.parsed("owner_id", as: OwnerID.self)
    let epoch = try r.parsed("daemon_epoch", as: DaemonEpoch.self)
    let result = r.optional("result")
    let error = r.optional("error")
    try r.finish()
    let outcome: Result<JSONValue, HostReplyErrorBox>
    switch (result, error) {
    case (let result?, nil): outcome = .success(result)
    case (nil, let error?): outcome = .failure(HostReplyErrorBox(try HostReplyError(wire: error)))
    default: throw CIError.invalid("host reply must carry exactly one of result or error")
    }
    return HostResponse(
      requestID: requestID, hostID: hostID, ownerID: ownerID, epoch: epoch, outcome: outcome)
  }
}

package struct HostReplyErrorBox: Error, Sendable, Equatable {
  package let error: HostReplyError
  package init(_ error: HostReplyError) { self.error = error }
}

// MARK: - Results

package struct HelloResult: Sendable, Equatable {
  package let hostID: HostID
  package let ownerID: OwnerID
  package let epoch: DaemonEpoch
  package let methods: Set<String>
  package let runtimeQualified: Bool
  package let runtimeDetail: String

  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "hello")
    guard try r.string("protocol") == HostProtocol.v1 else {
      throw CIError(.unsupported, "host selected an unsupported protocol")
    }
    hostID = try r.parsed("host_id", as: HostID.self)
    ownerID = try r.parsed("owner_id", as: OwnerID.self)
    epoch = try r.parsed("daemon_epoch", as: DaemonEpoch.self)
    var runtime = try r.object("runtime")
    runtimeQualified = try runtime.string("status") == "qualified"
    runtimeDetail = CIError.bounded(try runtime.string("detail"))
    methods = Set(try r.strings("methods"))
    r.ignore("guest_os")
    try r.finish()
  }
}

/// A brokered boot policy the host applies to `run.create` VMs.
package struct RunNetworkPolicy: Sendable, Equatable, Codable {
  package let digest: Digest
  package let publicEgressHosts: [String]?
  package let providerGrants: [String]
  package let localServices: [String]
  package let channelPolicy: Digest

  /// No provider, developer-local-service or private-network grant.
  package var isGrantFree: Bool { providerGrants.isEmpty && localServices.isEmpty }
}

/// `host.capabilities`: what the host can do now, and the evidence for it.
package struct HostCapabilities: Sendable, Equatable {
  package enum QualificationStatus: String, Sendable, Codable {
    case qualified, missing, mismatch, expired
  }

  package struct Qualification: Sendable, Equatable, Codable {
    package let status: QualificationStatus
    package let reason: String?
    package let manifestDigest: Digest?
    package let tuple: [String: String]
    package let tests: [String: String]
    package let expiresAt: EpochSeconds?
  }

  package let advertised: Set<String>
  package let transport: String?
  package let fallbackForbidden: Bool
  /// Keyed by egress mode (`none`, `filtered`).
  package let runPolicies: [EgressMode: RunNetworkPolicy]
  package let qualification: Qualification?
  package let retentionModes: Set<RetentionMode>
  package let maxLiveRetentionSeconds: UInt64
  package let maxStoppedRetentionSeconds: UInt64
  package let retentionSlots: UInt64
  package let maxOutputBytes: UInt64
  package let maxTTLSeconds: UInt64

  package func has(_ capability: HostCapabilityName) -> Bool {
    advertised.contains(capability.rawValue)
  }

  /// Additive members from a newer host are ignored, never trusted.
  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "capabilities")
    advertised = Set(try r.strings("capabilities"))
    var transport: String?
    var fallbackForbidden = false
    var policies: [EgressMode: RunNetworkPolicy] = [:]
    if let raw = r.optional("network_handoff") {
      var handoff = try ObjectReader(raw, field: "network_handoff")
      transport = try handoff.string("transport")
      fallbackForbidden = try handoff.string("fallback") == "forbidden"
      if let rawPolicies = handoff.optional("run_policies") {
        guard case .object(let members) = rawPolicies else {
          throw CIError.invalid("network_handoff.run_policies must be an object")
        }
        for (key, policyValue) in members {
          guard let mode = EgressMode(rawValue: key) else { continue }
          var p = try ObjectReader(policyValue, field: "run_policies.\(key)")
          let digest = try p.parsed("digest", as: Digest.self)
          var hosts: [String]?
          if let egress = p.optional("public_egress") {
            var e = try ObjectReader(egress, field: "public_egress")
            hosts = try e.strings("allowed_hosts")
            e.ignore("profile", "policy_hash")
          }
          let providers = try p.strings("provider_grants")
          var services: [String] = []
          for service in try p.array("local_services") {
            if let name = service["name"]?.stringValue {
              services.append(name)
            } else {
              services.append("unnamed")
            }
          }
          let channel = try p.parsed("channel_policy", as: Digest.self)
          policies[mode] = RunNetworkPolicy(
            digest: digest, publicEgressHosts: hosts, providerGrants: providers,
            localServices: services, channelPolicy: channel)
        }
      }
      handoff.ignore("id", "version")
    }
    self.transport = transport
    self.fallbackForbidden = fallbackForbidden
    runPolicies = policies
    if let raw = r.optional("qualification") {
      var q = try ObjectReader(raw, field: "qualification")
      guard let status = QualificationStatus(rawValue: try q.string("status")) else {
        throw CIError.invalid("unknown qualification.status")
      }
      let reason = try q.optionalString("reason").map(CIError.bounded)
      let digest = try q.optionalParsed("manifest_digest", as: Digest.self)
      var tuple: [String: String] = [:]
      if let raw = q.optional("tuple"), case .object(let members) = raw {
        for (key, value) in members { tuple[key] = value.stringValue.map(CIError.bounded) }
      }
      var tests: [String: String] = [:]
      if let raw = q.optional("tests"), case .object(let members) = raw {
        for (key, value) in members { tests[key] = value.stringValue.map(CIError.bounded) }
      }
      let expires = try q.optionalUnsigned("expires_at")
      q.ignore("schema", "recorded_at")
      qualification = Qualification(
        status: status, reason: reason, manifestDigest: digest, tuple: tuple, tests: tests,
        expiresAt: expires)
    } else {
      qualification = nil
    }
    var modes: Set<RetentionMode> = []
    var maxLive: UInt64 = 0
    var maxStopped: UInt64 = 0
    if let raw = r.optional("run_retention") {
      var retention = try ObjectReader(raw, field: "run_retention")
      for mode in try retention.strings("modes") {
        if let parsed = RetentionMode(rawValue: mode) { modes.insert(parsed) }
      }
      maxLive = try retention.optionalUnsigned("max_live_seconds") ?? 0
      maxStopped = try retention.optionalUnsigned("max_stopped_seconds") ?? 0
    }
    retentionModes = modes
    maxLiveRetentionSeconds = maxLive
    maxStoppedRetentionSeconds = maxStopped
    var slots: UInt64 = 0
    var output: UInt64 = 0
    var ttl: UInt64 = 0
    if let raw = r.optional("limits") {
      var limits = try ObjectReader(raw, field: "limits")
      slots = try limits.optionalUnsigned("retention_slots") ?? 0
      output = try limits.optionalUnsigned("max_output_bytes") ?? 0
      ttl = try limits.optionalUnsigned("max_ttl_seconds") ?? 0
    }
    retentionSlots = slots
    maxOutputBytes = output
    maxTTLSeconds = ttl
  }

  package init(
    advertised: Set<String>, transport: String?, fallbackForbidden: Bool,
    runPolicies: [EgressMode: RunNetworkPolicy], qualification: Qualification?,
    retentionModes: Set<RetentionMode>, maxLiveRetentionSeconds: UInt64,
    maxStoppedRetentionSeconds: UInt64, retentionSlots: UInt64, maxOutputBytes: UInt64,
    maxTTLSeconds: UInt64
  ) {
    self.advertised = advertised
    self.transport = transport
    self.fallbackForbidden = fallbackForbidden
    self.runPolicies = runPolicies
    self.qualification = qualification
    self.retentionModes = retentionModes
    self.maxLiveRetentionSeconds = maxLiveRetentionSeconds
    self.maxStoppedRetentionSeconds = maxStoppedRetentionSeconds
    self.retentionSlots = retentionSlots
    self.maxOutputBytes = maxOutputBytes
    self.maxTTLSeconds = maxTTLSeconds
  }
}

package enum ObservedState: String, Sendable, Codable {
  case running, stopped, unhealthy, unknown, destroyed
}

/// The gate-approved network proof of a running brokered boot.
package struct NetworkProof: Sendable, Equatable, Codable {
  package let bootID: BootID
  package let networkPolicy: Digest
  package let channelPolicy: Digest

  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "network")
    guard try r.string("transport") == "brokered" else {
      throw CIError(.capabilityMissing, "the VM is not on the brokered transport")
    }
    bootID = try r.parsed("boot_id", as: BootID.self)
    guard try r.unsigned("external_nic_count") == 0 else {
      throw CIError(.admissionRefused, "the VM reports an external network device")
    }
    networkPolicy = try r.parsed("network_policy_digest", as: Digest.self)
    channelPolicy = try r.parsed("channel_policy_digest", as: Digest.self)
    try r.finish()
  }

  package init(bootID: BootID, networkPolicy: Digest, channelPolicy: Digest) {
    self.bootID = bootID
    self.networkPolicy = networkPolicy
    self.channelPolicy = channelPolicy
  }
}

package struct VMObservation: Sendable, Equatable {
  package let instance: QualifiedInstance
  package let generation: UInt64
  package let state: ObservedState
  package let bootID: BootID?
  package let policyHash: Digest?
  package let expiresAt: EpochSeconds?
  package let observedAt: EpochSeconds
  package let image: String?
  package let egress: EgressMode?
  package let network: NetworkProof?

  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "observation")
    instance = try QualifiedInstance(wire: try r.required("instance"))
    r.ignore("name", "active_operation")
    generation = try r.unsigned("generation")
    state = try r.enumeration("state", as: ObservedState.self)
    bootID = try r.optionalParsed("boot_id", as: BootID.self)
    policyHash = try r.optionalParsed("policy_hash", as: Digest.self)
    expiresAt = try r.optionalUnsigned("expires_at")
    observedAt = try r.unsigned("observed_at")
    image = try r.optionalString("image")
    egress = try r.optionalString("egress").flatMap(EgressMode.init(rawValue:))
    network = try r.optional("network").map { (raw) throws(CIError) in try NetworkProof(wire: raw) }
    try r.finish()
  }

  package init(
    instance: QualifiedInstance, generation: UInt64, state: ObservedState, bootID: BootID?,
    policyHash: Digest?, expiresAt: EpochSeconds?, observedAt: EpochSeconds, image: String?,
    egress: EgressMode?, network: NetworkProof?
  ) {
    self.instance = instance
    self.generation = generation
    self.state = state
    self.bootID = bootID
    self.policyHash = policyHash
    self.expiresAt = expiresAt
    self.observedAt = observedAt
    self.image = image
    self.egress = egress
    self.network = network
  }
}

package enum RunPhase: String, Sendable, Codable, CaseIterable {
  case reserved, creating, running, exporting, stopping
  case resultsPending = "results_pending"
  case stoppedDiskPendingExport = "stopped_disk_pending_export"
  case recovering, destroyed
  case failedWithResources = "failed_with_resources"

  package var holdsResources: Bool { self != .destroyed }
}

package struct RunObservation: Sendable, Equatable {
  package let runID: HostRunID
  package let generation: UInt64
  package let phase: RunPhase
  package let instanceID: InstanceID?
  package let runtimeID: String?
  package let artifact: ArtifactHandle?
  package let artifactDigest: Digest?
  package let retentionDeadline: EpochSeconds?
  package let liveRetentionUntil: EpochSeconds?
  package let disposition: String?

  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "run")
    runID = try r.parsed("run_id", as: HostRunID.self)
    generation = try r.unsigned("generation")
    phase = try r.enumeration("phase", as: RunPhase.self)
    instanceID = try r.optionalParsed("instance_id", as: InstanceID.self)
    runtimeID = try r.optionalString("runtime_id")
    artifact = try r.optionalParsed("artifact", as: ArtifactHandle.self)
    artifactDigest = try r.optionalParsed("artifact_digest", as: Digest.self)
    retentionDeadline = try r.optionalUnsigned("retention_deadline")
    liveRetentionUntil = try r.optionalUnsigned("live_retention_until")
    disposition = try r.optionalString("disposition").map(CIError.bounded)
    r.ignore("recovery_used", "retention_mode")
    try r.finish()
  }

  package init(
    runID: HostRunID, generation: UInt64, phase: RunPhase, instanceID: InstanceID?,
    runtimeID: String?, artifact: ArtifactHandle?, artifactDigest: Digest?,
    retentionDeadline: EpochSeconds?, liveRetentionUntil: EpochSeconds?, disposition: String?
  ) {
    self.runID = runID
    self.generation = generation
    self.phase = phase
    self.instanceID = instanceID
    self.runtimeID = runtimeID
    self.artifact = artifact
    self.artifactDigest = artifactDigest
    self.retentionDeadline = retentionDeadline
    self.liveRetentionUntil = liveRetentionUntil
    self.disposition = disposition
  }
}

package enum OperationState: String, Sendable, Codable {
  case accepted, running, reconciling, succeeded, failed, cancelled

  package var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

package struct OperationReceipt: Sendable, Equatable {
  package let operationID: HostOperationID
  package let method: String
  package let state: OperationState
  package let disposition: String
  package let instance: QualifiedInstance?
  package let outcome: String?
  package let completedAt: EpochSeconds?

  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "receipt")
    operationID = try r.parsed("operation_id", as: HostOperationID.self)
    method = try r.string("method")
    state = try r.enumeration("state", as: OperationState.self)
    disposition = try r.string("disposition")
    instance = try r.optional("instance").map { (raw) throws(CIError) in
      try QualifiedInstance(wire: raw)
    }
    outcome = try r.optionalString("outcome").map(CIError.bounded)
    completedAt = try r.optionalUnsigned("completed_at")
    r.ignore(
      "accepted_at", "generation", "boot_id", "expires_at", "cancel_requested", "run_id",
      "substep")
  }

  package init(
    operationID: HostOperationID, method: String, state: OperationState, disposition: String,
    instance: QualifiedInstance?, outcome: String?, completedAt: EpochSeconds?
  ) {
    self.operationID = operationID
    self.method = method
    self.state = state
    self.disposition = disposition
    self.instance = instance
    self.outcome = outcome
    self.completedAt = completedAt
  }
}

package struct AccessGrant: Sendable, Equatable {
  package let session: SessionID
  package let epoch: DaemonEpoch
  package let instance: QualifiedInstance
  package let bootID: BootID
  package let policyHash: Digest
  package let leaseExpiresAt: EpochSeconds
  package let vmExpiresAt: EpochSeconds?
  package let guestHostKey: String
  package let guestUser: String

  package init(wire value: JSONValue) throws(CIError) {
    var r = try ObjectReader(value, field: "grant")
    session = try r.parsed("session_id", as: SessionID.self)
    epoch = try r.parsed("daemon_epoch", as: DaemonEpoch.self)
    instance = try QualifiedInstance(wire: try r.required("instance"))
    bootID = try r.parsed("boot_id", as: BootID.self)
    policyHash = try r.parsed("policy_hash", as: Digest.self)
    leaseExpiresAt = try r.unsigned("lease_expires_at")
    vmExpiresAt = try r.optionalUnsigned("vm_expires_at")
    guestHostKey = try r.string("guest_host_key")
    guard guestHostKey.hasPrefix("ssh-ed25519 "), guestHostKey.utf8.count <= 512,
      !guestHostKey.contains("\n")
    else { throw CIError.invalid("invalid grant.guest_host_key") }
    guestUser = try r.string("guest_user")
    guard (1...32).contains(guestUser.utf8.count),
      guestUser.unicodeScalars.allSatisfy({ isSafeNameScalar($0) && $0 != "." })
    else { throw CIError.invalid("invalid grant.guest_user") }
    r.ignore("generation", "purpose", "issued_at", "filtered_policy")
    try r.finish()
  }

  package init(
    session: SessionID, epoch: DaemonEpoch, instance: QualifiedInstance, bootID: BootID,
    policyHash: Digest, leaseExpiresAt: EpochSeconds, vmExpiresAt: EpochSeconds?,
    guestHostKey: String, guestUser: String
  ) {
    self.session = session
    self.epoch = epoch
    self.instance = instance
    self.bootID = bootID
    self.policyHash = policyHash
    self.leaseExpiresAt = leaseExpiresAt
    self.vmExpiresAt = vmExpiresAt
    self.guestHostKey = guestHostKey
    self.guestUser = guestUser
  }
}

/// The relay preamble: one JSON line selecting a live grant.
package func relayPreamble(session: SessionID, bearer: String, epoch: DaemonEpoch) -> [UInt8] {
  JSONValue.object([
    "protocol": .string(HostProtocol.v1), "session_id": .string(session.rawValue),
    "bearer": .string(bearer), "expected_epoch": .string(epoch.rawValue),
  ]).frame
}
