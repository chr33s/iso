import Foundation
import IsoConfiguration
import IsoCore

/// Typed results of `iso.host/v1` methods (spec 6.2–6.3, 7.6). Each type
/// encodes to and decodes from its wire form so client and server share one
/// definition.

/// Lifecycle as committed by the host supervisor.
package enum VMLifecycle: String, Sendable, Codable, CaseIterable {
  case creating
  case stopped
  case running
  case destroyed
}

/// Native observation of one owned runtime object.
package enum NativeState: Sendable, Equatable {
  case absent
  case stopped
  case running(boot: BootID, address: String?, expiresAt: WireTime?)
  case unhealthy(String)
}

/// The public state vocabulary: `running`/`stopped`/`unhealthy`/`unknown`
/// keep their `iso.machine/v1` meanings; `destroyed` is a host-control state.
package enum ObservedState: String, Codable, Sendable, CaseIterable {
  case running
  case stopped
  case unhealthy
  case unknown
  case destroyed
}

/// A fresh, reachable snapshot of one instance.
package struct VMObservation: Sendable, Equatable {
  package let instance: QualifiedInstance
  package let name: InstanceName
  package let generation: UInt64
  package let state: ObservedState
  package let bootID: BootID?
  package let policyHash: SHA256Hex?
  package let expiresAt: WireTime?
  package let observedAt: WireTime
  package let activeOperation: HostOperationID?
  /// The worker image the instance was created from (absent once destroyed).
  package let image: ImageName?
  /// The VM's network policy (absent once destroyed).
  package let egress: EgressMode?
  /// The gate-approved network proof of a running brokered boot; absent for
  /// vmnet VMs and whenever the VM is not running.
  package let network: NetworkProof?

  package init(
    instance: QualifiedInstance, name: InstanceName, generation: UInt64, state: ObservedState,
    bootID: BootID?, policyHash: SHA256Hex?, expiresAt: WireTime?, observedAt: WireTime,
    activeOperation: HostOperationID?, image: ImageName? = nil, egress: EgressMode? = nil,
    network: NetworkProof? = nil
  ) {
    self.image = image
    self.egress = egress
    self.network = network
    self.instance = instance
    self.name = name
    self.generation = generation
    self.state = state
    self.bootID = bootID
    self.policyHash = policyHash
    self.expiresAt = expiresAt
    self.observedAt = observedAt
    self.activeOperation = activeOperation
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("instance", instance.wire)
    b.set("name", name)
    b.set("generation", generation)
    b.set("state", state.rawValue)
    b.setIfPresent("boot_id", bootID)
    b.setIfPresent("policy_hash", policyHash)
    b.setIfPresent("expires_at", expiresAt?.seconds)
    b.set("observed_at", observedAt.seconds)
    b.setIfPresent("active_operation", activeOperation)
    b.setIfPresent("image", image)
    if let egress { b.set("egress", egress.rawValue) }
    if let network { b.set("network", network.wire) }
    return b.value
  }

  package init(wire value: JSONValue) throws(HostControlError) {
    var r = try WireObject(value, field: "observation")
    instance = try QualifiedInstance(
      wire: try r.required("instance"), field: "observation.instance")
    name = try r.parsed("name", InstanceName.init)
    generation = try r.unsigned("generation")
    guard let state = ObservedState(rawValue: try r.string("state")) else {
      throw .invalidRequest("invalid observation.state")
    }
    self.state = state
    bootID = try r.optionalParsed("boot_id", BootID.init)
    policyHash = try r.optionalParsed("policy_hash", SHA256Hex.init)
    expiresAt = try r.optionalUnsigned("expires_at", as: UInt64.self).map(WireTime.init(seconds:))
    observedAt = WireTime(seconds: try r.unsigned("observed_at"))
    activeOperation = try r.optionalParsed("active_operation", HostOperationID.init)
    image = try r.optionalParsed("image", ImageName.init)
    if let raw = try r.optionalString("egress") {
      guard let mode = EgressMode(rawValue: raw) else {
        throw .invalidRequest("invalid observation.egress")
      }
      egress = mode
    } else {
      egress = nil
    }
    network = try r.raw("network").map { value throws(HostControlError) in
      try NetworkProof(wire: value)
    }
    try r.finish()
    // A proof is only for the running boot it names.
    if let network, state != .running || network.bootID != bootID {
      throw .invalidRequest("observation.network does not match the running boot")
    }
  }
}

/// Spec 6.2's network fields for a brokered boot, read from a fresh gate pass
/// on the worker. An observation, never a credential: access handoff gates the
/// boot again. Every member is required and the shape is closed, so a client
/// refuses a proof it does not fully understand.
package struct NetworkProof: Sendable, Equatable {
  package static let transport = "brokered"
  package let bootID: BootID
  package let networkPolicy: SHA256Hex
  package let channelPolicy: SHA256Hex

  package init(bootID: BootID, networkPolicy: SHA256Hex, channelPolicy: SHA256Hex) {
    self.bootID = bootID
    self.networkPolicy = networkPolicy
    self.channelPolicy = channelPolicy
  }

  /// The gate admits only a NIC-less boot, so the count is a constant.
  package var externalNICCount: UInt64 { 0 }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("transport", Self.transport)
    b.set("boot_id", bootID)
    b.set("external_nic_count", externalNICCount)
    b.set("network_policy_digest", networkPolicy)
    b.set("channel_policy_digest", channelPolicy)
    return b.value
  }

  package init(wire value: JSONValue) throws(HostControlError) {
    var r = try WireObject(value, field: "observation.network")
    guard try r.string("transport") == Self.transport else {
      throw .invalidRequest("unsupported observation.network.transport")
    }
    bootID = try r.parsed("boot_id", BootID.init)
    guard try r.unsigned("external_nic_count", as: UInt64.self) == 0 else {
      throw .invalidRequest("observation.network reports an external network device")
    }
    networkPolicy = try r.parsed("network_policy_digest", SHA256Hex.init)
    channelPolicy = try r.parsed("channel_policy_digest", SHA256Hex.init)
    try r.finish()
  }
}

/// Reachability of a host, distinct from any VM state (spec 7.6). An
/// unreachable observation carries no precondition or access authority.
package enum HostObservation: Sendable, Equatable {
  case reachable(VMObservation)
  case unreachable(HostControlError, lastKnown: VMObservation?)
}

package enum OperationState: String, Sendable, Codable, CaseIterable {
  case accepted
  case running
  case reconciling
  case succeeded
  case failed
  case cancelled

  package var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled: true
    case .accepted, .running, .reconciling: false
    }
  }
}

/// How an admission was satisfied.
package enum AdmissionDisposition: String, Sendable, Codable {
  /// A new durable operation was accepted.
  case accepted
  /// The operation id already existed with the same request; its record is returned.
  case existing
  /// An exact cleanup was already in flight; its operation is returned.
  case existingCleanup = "existing_cleanup"
  /// The target was already in the requested state; no operation was recorded.
  case unchanged
}

/// A historical operation receipt. It never implies a current observation.
package struct OperationReceipt: Sendable, Equatable {
  package let operationID: HostOperationID
  package let method: HostMethod
  package let state: OperationState
  package let disposition: AdmissionDisposition
  package let acceptedAt: WireTime
  package let completedAt: WireTime?
  package let instance: QualifiedInstance?
  package let generation: UInt64?
  package let bootID: BootID?
  package let expiresAt: WireTime?
  package let outcome: String?
  package let cancelRequested: Bool

  package init(
    operationID: HostOperationID, method: HostMethod, state: OperationState,
    disposition: AdmissionDisposition, acceptedAt: WireTime, completedAt: WireTime?,
    instance: QualifiedInstance?, generation: UInt64?, bootID: BootID?, expiresAt: WireTime?,
    outcome: String?, cancelRequested: Bool
  ) {
    self.operationID = operationID
    self.method = method
    self.state = state
    self.disposition = disposition
    self.acceptedAt = acceptedAt
    self.completedAt = completedAt
    self.instance = instance
    self.generation = generation
    self.bootID = bootID
    self.expiresAt = expiresAt
    self.outcome = outcome
    self.cancelRequested = cancelRequested
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("operation_id", operationID)
    b.set("method", method.rawValue)
    b.set("state", state.rawValue)
    b.set("disposition", disposition.rawValue)
    b.set("accepted_at", acceptedAt.seconds)
    b.setIfPresent("completed_at", completedAt?.seconds)
    if let instance { b.set("instance", instance.wire) }
    b.setIfPresent("generation", generation)
    b.setIfPresent("boot_id", bootID)
    b.setIfPresent("expires_at", expiresAt?.seconds)
    if let outcome { b.set("outcome", outcome) }
    b.set("cancel_requested", cancelRequested)
    b.set("historical", true)
    return b.value
  }

  package init(wire value: JSONValue) throws(HostControlError) {
    var r = try WireObject(value, field: "receipt")
    operationID = try r.parsed("operation_id", HostOperationID.init)
    guard let method = HostMethod(rawValue: try r.string("method")),
      let state = OperationState(rawValue: try r.string("state")),
      let disposition = AdmissionDisposition(rawValue: try r.string("disposition"))
    else { throw .invalidRequest("invalid receipt method, state or disposition") }
    self.method = method
    self.state = state
    self.disposition = disposition
    acceptedAt = WireTime(seconds: try r.unsigned("accepted_at"))
    completedAt = try r.optionalUnsigned("completed_at", as: UInt64.self).map(
      WireTime.init(seconds:))
    if let value = r.raw("instance") {
      instance = try QualifiedInstance(wire: value, field: "receipt.instance")
    } else {
      instance = nil
    }
    generation = try r.optionalUnsigned("generation")
    bootID = try r.optionalParsed("boot_id", BootID.init)
    expiresAt = try r.optionalUnsigned("expires_at", as: UInt64.self).map(WireTime.init(seconds:))
    outcome = try r.optionalString("outcome")
    cancelRequested = try r.bool("cancel_requested")
    guard try r.bool("historical") else { throw .invalidRequest("receipt must be historical") }
    try r.finish()
  }
}

/// `hello` result: identity and explicit capability, not native readiness.
package struct HelloResult: Sendable, Equatable {
  package let protocolVersion: String
  package let hostID: HostID
  package let ownerID: OwnerID
  package let epoch: DaemonEpoch
  package let runtime: RuntimeQualification
  package let methods: [HostMethod]
  package let guestOperations: [GuestOS]

  package init(
    protocolVersion: String, hostID: HostID, ownerID: OwnerID, epoch: DaemonEpoch,
    runtime: RuntimeQualification, methods: [HostMethod], guestOperations: [GuestOS]
  ) {
    self.protocolVersion = protocolVersion
    self.hostID = hostID
    self.ownerID = ownerID
    self.epoch = epoch
    self.runtime = runtime
    self.methods = methods
    self.guestOperations = guestOperations
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("protocol", protocolVersion)
    b.set("host_id", hostID)
    b.set("owner_id", ownerID)
    b.set("daemon_epoch", epoch)
    b.set("runtime", runtime.wire)
    b.set("methods", .array(methods.map { .string($0.rawValue) }))
    b.set("guest_os", .array(guestOperations.map { .string($0.rawValue) }))
    return b.value
  }

  package init(wire value: JSONValue) throws(HostControlError) {
    var r = try WireObject(value, field: "hello")
    protocolVersion = try r.string("protocol")
    hostID = try r.parsed("host_id", HostID.init)
    ownerID = try r.parsed("owner_id", OwnerID.init)
    epoch = try r.parsed("daemon_epoch", DaemonEpoch.init)
    runtime = try RuntimeQualification(wire: try r.required("runtime"))
    // Unknown method names from a newer host are ignored, not trusted.
    var methods: [HostMethod] = []
    for item in try r.array("methods") {
      if let method = HostMethod(rawValue: try WireObject.string(item, field: "hello.methods")) {
        methods.append(method)
      }
    }
    self.methods = methods
    var guests: [GuestOS] = []
    for item in try r.array("guest_os") {
      if let os = GuestOS(rawValue: try WireObject.string(item, field: "hello.guest_os")) {
        guests.append(os)
      }
    }
    guestOperations = guests
    try r.finish()
  }
}

/// Runtime qualification summary reported by hello and host inspect.
package enum RuntimeQualification: Sendable, Equatable {
  case qualified(String)
  case unqualified(String)

  package var wire: JSONValue {
    var b = WireBuilder()
    switch self {
    case .qualified(let version):
      b.set("status", "qualified")
      b.set("detail", version)
    case .unqualified(let reason):
      b.set("status", "unqualified")
      b.set("detail", reason)
    }
    return b.value
  }

  package init(wire value: JSONValue) throws(HostControlError) {
    var r = try WireObject(value, field: "runtime")
    let status = try r.string("status")
    let detail = HostControlError.sanitize(try r.string("detail"))
    try r.finish()
    switch status {
    case "qualified": self = .qualified(detail)
    case "unqualified": self = .unqualified(detail)
    default: throw .invalidRequest("invalid runtime.status")
    }
  }
}

/// The worker's filtered-egress boot identity for a grant: issued only after
/// the worker's own native proof (owner lock, egress companion, live boot,
/// recorded policy) holds for this boot.
package struct FilteredGrantPolicy: Sendable, Equatable {
  package let bootID: BootID
  package let policyHash: FilteredPolicyHash

  package init(bootID: BootID, policyHash: FilteredPolicyHash) {
    self.bootID = bootID
    self.policyHash = policyHash
  }
}

/// A filtered boot's recorded egress policy hash as `NetworkPolicy` writes
/// it: `sha256:` and 64 lowercase hex digits.
package struct FilteredPolicyHash: Hashable, Sendable, CustomStringConvertible {
  package let rawValue: String

  package init(_ value: String) throws(ValidationError) {
    guard value.hasPrefix("sha256:"),
      (try? SHA256Hex(String(value.dropFirst(7))))?.rawValue == String(value.dropFirst(7))
    else { throw ValidationError("invalid filtered policy hash") }
    rawValue = value
  }

  package var description: String { rawValue }
}

/// Nonsecret metadata of a live access grant. The bearer never appears here.
package struct AccessGrant: Sendable, Equatable {
  package let session: SessionID
  package let epoch: DaemonEpoch
  package let instance: QualifiedInstance
  package let bootID: BootID
  package let policyHash: SHA256Hex
  package let generation: UInt64
  package let purpose: AccessPurpose
  package let issuedAt: WireTime
  package let leaseExpiresAt: WireTime
  package let vmExpiresAt: WireTime?
  /// The guest's pinned SSH host key (`ssh-ed25519 <base64>`); the client
  /// verifies it end to end through the relay.
  package let guestHostKey: String
  package let guestUser: GuestUser
  /// Present for filtered-egress VMs; the client's broker readiness binds to it.
  package let filteredPolicy: FilteredGrantPolicy?

  package init(
    session: SessionID, epoch: DaemonEpoch, instance: QualifiedInstance, bootID: BootID,
    policyHash: SHA256Hex, generation: UInt64, purpose: AccessPurpose, issuedAt: WireTime,
    leaseExpiresAt: WireTime, vmExpiresAt: WireTime?, guestHostKey: String, guestUser: GuestUser,
    filteredPolicy: FilteredGrantPolicy? = nil
  ) {
    self.filteredPolicy = filteredPolicy
    self.guestHostKey = guestHostKey
    self.guestUser = guestUser
    self.session = session
    self.epoch = epoch
    self.instance = instance
    self.bootID = bootID
    self.policyHash = policyHash
    self.generation = generation
    self.purpose = purpose
    self.issuedAt = issuedAt
    self.leaseExpiresAt = leaseExpiresAt
    self.vmExpiresAt = vmExpiresAt
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("session_id", session)
    b.set("daemon_epoch", epoch)
    b.set("instance", instance.wire)
    b.set("boot_id", bootID)
    b.set("policy_hash", policyHash)
    b.set("generation", generation)
    b.set("purpose", purpose.rawValue)
    b.set("issued_at", issuedAt.seconds)
    b.set("lease_expires_at", leaseExpiresAt.seconds)
    b.setIfPresent("vm_expires_at", vmExpiresAt?.seconds)
    b.set("guest_host_key", guestHostKey)
    b.set("guest_user", guestUser)
    if let filteredPolicy {
      var policy = WireBuilder()
      policy.set("boot_id", filteredPolicy.bootID)
      policy.set("policy_hash", filteredPolicy.policyHash)
      b.set("filtered_policy", policy.value)
    }
    return b.value
  }

  package init(wire value: JSONValue) throws(HostControlError) {
    var r = try WireObject(value, field: "grant")
    session = try r.parsed("session_id", SessionID.init)
    epoch = try r.parsed("daemon_epoch", DaemonEpoch.init)
    instance = try QualifiedInstance(wire: try r.required("instance"), field: "grant.instance")
    bootID = try r.parsed("boot_id", BootID.init)
    policyHash = try r.parsed("policy_hash", SHA256Hex.init)
    generation = try r.unsigned("generation")
    guard let purpose = AccessPurpose(rawValue: try r.string("purpose")) else {
      throw .invalidRequest("invalid grant.purpose")
    }
    self.purpose = purpose
    issuedAt = WireTime(seconds: try r.unsigned("issued_at"))
    leaseExpiresAt = WireTime(seconds: try r.unsigned("lease_expires_at"))
    vmExpiresAt = try r.optionalUnsigned("vm_expires_at", as: UInt64.self).map(
      WireTime.init(seconds:))
    let pin = try r.string("guest_host_key")
    guard let key = try? HostPublicKey(parsing: pin) else {
      throw .invalidRequest("invalid grant.guest_host_key")
    }
    guestHostKey = "ssh-ed25519 " + key.base64
    guestUser = try r.parsed("guest_user", GuestUser.init)
    if var policy = try r.optionalObject("filtered_policy") {
      filteredPolicy = FilteredGrantPolicy(
        bootID: try policy.parsed("boot_id", BootID.init),
        policyHash: try policy.parsed("policy_hash", FilteredPolicyHash.init))
      try policy.finish()
    } else {
      filteredPolicy = nil
    }
    try r.finish()
  }
}

/// Clock seam: wall time for persisted deadlines, a suspension-aware
/// monotonic instant for live leases within one supervisor lifetime.
package protocol HostClock: Sendable {
  func now() -> Date
  func monotonic() -> ContinuousClock.Instant
}

package struct SystemHostClock: HostClock {
  package init() {}
  package func now() -> Date { Date() }
  package func monotonic() -> ContinuousClock.Instant { ContinuousClock.now }
}
