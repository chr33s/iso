import Foundation
import IsoConfiguration
import IsoCore

// The `iso.audit/v1` event model (docs/audit.md): one immutable, typed event
// per host observation, request or decision. Producers submit an
// `AuditRecord`; only `AuditStore.append` assigns identity, order and time,
// and the record's case fixes its producer, evidence class and subject.

// MARK: - Identities

/// A host-generated audit identity: a fixed prefix and 32 lowercase hex.
package protocol AuditIdentifier: Hashable, Sendable, Codable, Comparable,
  CustomStringConvertible
{
  static var prefix: String { get }
  var rawValue: String { get }
  init(unchecked rawValue: String)
}

extension AuditIdentifier {
  package init(_ text: String) throws(IsoCore.ValidationError) {
    guard Self.isValid(text) else {
      throw ValidationError(
        "\(debugQuoted(neutralizeControls(text))) is not a valid id (\(Self.prefix) and 32 lowercase hex)"
      )
    }
    self.init(unchecked: text)
  }

  static func isValid(_ text: String) -> Bool {
    guard text.hasPrefix(Self.prefix) else { return false }
    let hex = text.utf8.dropFirst(Self.prefix.utf8.count)
    return hex.count == 32
      && hex.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  package static func generate() -> Self { Self(unchecked: prefix + randomHex(16)) }
  package var description: String { rawValue }
  package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

  package init(from decoder: any Decoder) throws {
    let text = try decoder.singleValueContainer().decode(String.self)
    guard Self.isValid(text) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "invalid \(Self.prefix) id"))
    }
    self.init(unchecked: text)
  }

  package func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    try value.encode(rawValue)
  }
}

/// One managed or administrative invocation (`iso run`, `claude`, ...).
package struct AuditRunID: AuditIdentifier {
  package static let prefix = "run_"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

package struct AuditEventID: AuditIdentifier {
  package static let prefix = "evt_"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

/// One journal generation; a new one invalidates every older cursor.
package struct AuditJournalID: AuditIdentifier {
  package static let prefix = "journal_"
  package let rawValue: String
  package init(unchecked rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Classification

package enum AuditProducer: String, Codable, Sendable {
  case iso
}

package enum AuditEvidence: String, Codable, Sendable {
  /// What the host was asked to do.
  case hostRequest = "host_request"
  /// What the host saw happen.
  case hostObservation = "host_observation"
  /// A grant, policy verdict or approval the host made.
  case hostDecision = "host_decision"
  /// The store's own statement about its recording (a gap).
  case storeRecord = "store_record"
}

/// Whose event this is. Ownership is never inferred from names or times.
package enum AuditSubject: Sendable, Hashable, Codable {
  case invocation(AuditRunID)
  /// A VM by its stable host identity; `bootID` only when the host knew the
  /// boot. Only an exact boot joins a run's VM context.
  case vm(vmID: HexID, bootID: HexID?)
  /// A later `run-cleanup` of a disposable run, linked by its session id.
  case runCleanup(sessionID: RunSessionID)
  case journal

  enum CodingKeys: String, CodingKey {
    case type, operation
    case auditRunID = "audit_run_id"
    case vmID = "vm_id"
    case bootID = "boot_id"
    case sessionID = "session_id"
  }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .invocation(let run):
      try values.encode("invocation", forKey: .type)
      try values.encode(run, forKey: .auditRunID)
    case .vm(let vm, let boot):
      try values.encode("vm", forKey: .type)
      try values.encode(vm, forKey: .vmID)
      try values.encode(boot, forKey: .bootID)
    case .runCleanup(let session):
      try values.encode("operation", forKey: .type)
      try values.encode("run_cleanup", forKey: .operation)
      try values.encode(session, forKey: .sessionID)
    case .journal:
      try values.encode("journal", forKey: .type)
    }
  }

  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .type) {
    case "invocation": self = .invocation(try values.decode(AuditRunID.self, forKey: .auditRunID))
    case "vm":
      self = .vm(
        vmID: try values.decode(HexID.self, forKey: .vmID),
        bootID: try values.decode(HexID?.self, forKey: .bootID))
    case "operation":
      guard try values.decode(String.self, forKey: .operation) == "run_cleanup" else {
        throw DecodingError.dataCorruptedError(
          forKey: .operation, in: values, debugDescription: "unknown operation")
      }
      self = .runCleanup(sessionID: try values.decode(RunSessionID.self, forKey: .sessionID))
    case "journal": self = .journal
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: values, debugDescription: "unknown subject type")
    }
  }
}

/// The closed event-kind discriminator.
package enum AuditEventKind: String, Codable, Sendable, CaseIterable {
  case invocationRequested = "invocation.requested"
  case invocationEnvironment = "invocation.environment"
  case invocationPreparationFailed = "invocation.preparation_failed"
  case launchHandoff = "launch.handoff"
  case launchTransportEnded = "launch.transport_ended"
  case launchTransportFailed = "launch.transport_failed"
  case cleanupObserved = "cleanup.observed"
  case boundaryBoot = "boundary.boot"
  case boundaryRawProviderForward = "boundary.raw_provider_forward"
  case boundaryStop = "boundary.stop"
  case boundaryPullStage = "boundary.pull_stage"
  case boundaryPullApply = "boundary.pull_apply"
  case boundaryPullApplyPartial = "boundary.pull_apply_partial"
  case boundaryPullDirect = "boundary.pull_direct"
  case boundaryPolicyBoot = "boundary.policy_boot"
  case boundaryPolicyProxyClaim = "boundary.policy_proxy_claim"
  case boundaryPolicyDecision = "boundary.policy_decision"
  case boundaryApprovalIssued = "boundary.approval_issued"
  case boundaryApprovalConsumed = "boundary.approval_consumed"
  case boundaryPullHeld = "boundary.pull_held"
  case boundaryInputSnapshot = "boundary.input_snapshot"
  case boundaryHandoffFence = "boundary.handoff_fence"
  case storeRecordingGap = "store.recording_gap"
}

// MARK: - Typed payloads

/// The bounded, typed payloads of audit-owned events. Names, modes, counts
/// and identities only: never argv, prompts, values, output or hashes of
/// any of them.
package enum AuditFacts {
  package enum Command: String, Codable, Sendable {
    case run, claude, codex
    case claudeAgents = "claude-agents"
  }

  package enum Role: String, Codable, Sendable {
    /// iso launches and supervises the workload.
    case managed
    /// An attachment to state iso does not own (`claude-agents`).
    case administrative
  }

  package enum Lifecycle: String, Codable, Sendable {
    /// `iso run`: reuses or creates a retained instance.
    case persistent
    /// `iso run --rm`.
    case disposable
    /// `iso claude` / `iso codex` on a running instance.
    case existing
    /// `iso claude-agents`.
    case attachment
  }

  package enum PermissionMode: String, Codable, Sendable {
    case bypass, ask
  }

  package struct Request: Codable, Sendable, Equatable {
    package let command: Command
    package let role: Role
    package let lifecycle: Lifecycle
    /// The agent id as given (`claude`, `codex`, a definition id).
    @EncodedNull package private(set) var requestedAgent: String?
    @EncodedNull package private(set) var requestedInstance: String?
    /// iso's own `--ask`; never the agent's arguments.
    @EncodedNull package private(set) var permissionMode: PermissionMode?
    package let isoVersion: String

    package init(
      command: Command, role: Role, lifecycle: Lifecycle, requestedAgent: String?,
      requestedInstance: String?, permissionMode: PermissionMode?, isoVersion: String
    ) {
      self.command = command
      self.role = role
      self.lifecycle = lifecycle
      self.requestedAgent = requestedAgent
      self.requestedInstance = requestedInstance
      self.permissionMode = permissionMode
      self.isoVersion = isoVersion
    }

    enum CodingKeys: String, CodingKey {
      case command, role, lifecycle
      case requestedAgent = "requested_agent"
      case requestedInstance = "requested_instance"
      case permissionMode = "permission_mode"
      case isoVersion = "iso_version"
    }
  }

  /// Where an invocation failed before its workload was handed off.
  package enum Stage: String, Codable, Sendable {
    case resolve, prepare, start, connect
  }

  package struct PreparationFailure: Codable, Sendable, Equatable {
    package let stage: Stage
    package init(stage: Stage) { self.stage = stage }
  }

  package enum AgentSource: String, Codable, Sendable {
    case builtin, installed
  }

  package struct Agent: Codable, Sendable, Equatable {
    package let definitionID: String
    @EncodedNull package private(set) var source: AgentSource?
    @EncodedNull package private(set) var definitionHash: String?
    package let adapterID: String
    @EncodedNull package private(set) var adapterContractVersion: Int?

    package init(
      definitionID: String, source: AgentSource?, definitionHash: String?, adapterID: String,
      adapterContractVersion: Int?
    ) {
      self.definitionID = definitionID
      self.source = source
      self.definitionHash = definitionHash
      self.adapterID = adapterID
      self.adapterContractVersion = adapterContractVersion
    }

    enum CodingKeys: String, CodingKey {
      case source
      case definitionID = "definition_id"
      case definitionHash = "definition_hash"
      case adapterID = "adapter_id"
      case adapterContractVersion = "adapter_contract_version"
    }
  }

  package enum StartAction: String, Codable, Sendable {
    case created, restarted, attached
  }

  /// Effective settings come from host records of the running boot;
  /// `requested` is what this invocation's configuration asked for.
  package struct Environment: Codable, Sendable, Equatable {
    package struct Egress: Codable, Sendable, Equatable {
      package let mode: String
      package let transport: String
      package init(mode: String, transport: String) {
        self.mode = mode
        self.transport = transport
      }
    }

    package struct Policy: Codable, Sendable, Equatable {
      package let mode: String
      @EncodedNull package private(set) var digest: String?
      package init(mode: String, digest: String?) {
        self.mode = mode
        self.digest = digest
      }
    }

    package struct Requested: Codable, Sendable, Equatable {
      package let egress: String
      package let proxyMode: String
      @EncodedNull package private(set) var sessionTTLSeconds: UInt64?

      package init(egress: String, proxyMode: String, sessionTTLSeconds: UInt64?) {
        self.egress = egress
        self.proxyMode = proxyMode
        self.sessionTTLSeconds = sessionTTLSeconds
      }

      enum CodingKeys: String, CodingKey {
        case egress
        case proxyMode = "proxy_mode"
        case sessionTTLSeconds = "session_ttl_seconds"
      }
    }

    package enum Workspace: String, Codable, Sendable {
      case copy, mount, none, unknown
      case gitRepo = "git_repo"
    }

    package let action: StartAction
    package let instanceName: String
    @EncodedNull package private(set) var vmID: HexID?
    @EncodedNull package private(set) var bootID: HexID?
    package let image: String
    package let guestOS: String
    package let workspace: Workspace
    @EncodedNull package private(set) var egress: Egress?
    @EncodedNull package private(set) var policy: Policy?
    package let proxiedProviders: [String]
    package let requested: Requested
    @EncodedNull package private(set) var agent: Agent?
    @EncodedNull package private(set) var disposableSessionID: RunSessionID?
    /// Host records that exist but could not be read, so their fields above
    /// are unknown rather than absent (`vm_identity`, `policy_binding`,
    /// `network_policy`, `workspace`, `proxy`).
    package let unreadable: [String]

    package init(
      action: StartAction, instanceName: String, vmID: HexID?, bootID: HexID?, image: String,
      guestOS: String, workspace: Workspace, egress: Egress?, policy: Policy?,
      proxiedProviders: [String], requested: Requested, agent: Agent?,
      disposableSessionID: RunSessionID?, unreadable: [String] = []
    ) {
      self.action = action
      self.instanceName = instanceName
      self.vmID = vmID
      self.bootID = bootID
      self.image = image
      self.guestOS = guestOS
      self.workspace = workspace
      self.egress = egress
      self.policy = policy
      self.proxiedProviders = proxiedProviders
      self.requested = requested
      self.agent = agent
      self.disposableSessionID = disposableSessionID
      self.unreadable = unreadable
    }

    enum CodingKeys: String, CodingKey {
      case action, image, workspace, egress, policy, requested, agent, unreadable
      case instanceName = "instance_name"
      case vmID = "vm_id"
      case bootID = "boot_id"
      case guestOS = "guest_os"
      case proxiedProviders = "proxied_providers"
      case disposableSessionID = "disposable_session_id"
    }

    /// A record without `unreadable` names no unreadable host record.
    package init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      self.init(
        action: try values.decode(StartAction.self, forKey: .action),
        instanceName: try values.decode(String.self, forKey: .instanceName),
        vmID: try values.decodeIfPresent(HexID.self, forKey: .vmID),
        bootID: try values.decodeIfPresent(HexID.self, forKey: .bootID),
        image: try values.decode(String.self, forKey: .image),
        guestOS: try values.decode(String.self, forKey: .guestOS),
        workspace: try values.decode(Workspace.self, forKey: .workspace),
        egress: try values.decodeIfPresent(Egress.self, forKey: .egress),
        policy: try values.decodeIfPresent(Policy.self, forKey: .policy),
        proxiedProviders: try values.decode([String].self, forKey: .proxiedProviders),
        requested: try values.decode(Requested.self, forKey: .requested),
        agent: try values.decodeIfPresent(Agent.self, forKey: .agent),
        disposableSessionID: try values.decodeIfPresent(
          RunSessionID.self, forKey: .disposableSessionID),
        unreadable: try values.decodeIfPresent([String].self, forKey: .unreadable) ?? [])
    }
  }

  package struct Handoff: Codable, Sendable, Equatable {
    package let transport: String
    package let pty: Bool
    /// Names forwarded into the workload session; never values.
    package let forwardedVariables: [String]

    package init(transport: String, pty: Bool, forwardedVariables: [String]) {
      self.transport = transport
      self.pty = pty
      self.forwardedVariables = forwardedVariables
    }

    enum CodingKeys: String, CodingKey {
      case transport, pty
      case forwardedVariables = "forwarded_variables"
    }
  }

  /// The observed transport status. `exited 0` is the transport's status,
  /// never a verdict on the task.
  package enum Termination: Codable, Sendable, Equatable {
    case exited(Int32)
    case signaled(Int32)

    package init(_ termination: ProcessRunner.Termination) {
      switch termination {
      case .exited(let code): self = .exited(code)
      case .signaled(let number): self = .signaled(number)
      }
    }

    enum CodingKeys: String, CodingKey { case kind, status, signal }

    /// `{"kind", "status", "signal"}`, the member that does not apply `null`.
    package func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      switch self {
      case .exited(let status):
        try values.encode("exited", forKey: .kind)
        try values.encode(status, forKey: .status)
        try values.encodeNil(forKey: .signal)
      case .signaled(let signal):
        try values.encode("signaled", forKey: .kind)
        try values.encodeNil(forKey: .status)
        try values.encode(signal, forKey: .signal)
      }
    }

    package init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      switch try values.decode(String.self, forKey: .kind) {
      case "exited": self = .exited(try values.decode(Int32.self, forKey: .status))
      case "signaled": self = .signaled(try values.decode(Int32.self, forKey: .signal))
      default:
        throw DecodingError.dataCorruptedError(
          forKey: .kind, in: values, debugDescription: "unknown termination kind")
      }
    }

    package var text: String {
      switch self {
      case .exited(let status): "exited \(status)"
      case .signaled(let signal): "signaled \(signal)"
      }
    }
  }

  package struct TransportEnded: Codable, Sendable, Equatable {
    package let transport: String
    package let termination: Termination
    package init(transport: String, termination: Termination) {
      self.transport = transport
      self.termination = termination
    }
  }

  package enum TransportFailure: String, Codable, Sendable {
    /// The pre-launch readiness recheck refused the handoff.
    case revalidationFailed = "revalidation_failed"
    /// Launch or supervision failed; no exit status was observed.
    case sessionError = "session_error"
  }

  package struct TransportFailed: Codable, Sendable, Equatable {
    package let transport: String
    package let reason: TransportFailure
    package init(transport: String, reason: TransportFailure) {
      self.transport = transport
      self.reason = reason
    }
  }

  package enum CleanupOutcome: String, Codable, Sendable {
    case destroyed
    /// Left for review (a pending staged pull or an unproven object).
    case deferred
    case destroyFailed = "destroy_failed"
    case startFailed = "start_failed"
  }

  package struct Cleanup: Codable, Sendable, Equatable {
    package let sessionID: RunSessionID
    package let outcome: CleanupOutcome
    package init(sessionID: RunSessionID, outcome: CleanupOutcome) {
      self.sessionID = sessionID
      self.outcome = outcome
    }
    enum CodingKeys: String, CodingKey {
      case outcome
      case sessionID = "session_id"
    }
  }

  /// The store's statement that records are missing: `torn_record` (its
  /// sequence number is never reused) or `capture_degraded` (refused while
  /// the store could not accept them).
  package struct RecordingGap: Codable, Sendable, Equatable {
    package let reason: AuditGap.Reason
    @EncodedNull package private(set) var afterSequence: UInt64?
    @EncodedNull package private(set) var refusedSince: String?
    @EncodedNull package private(set) var refusedCount: UInt64?

    package init(
      reason: AuditGap.Reason, afterSequence: UInt64?, refusedSince: String? = nil,
      refusedCount: UInt64? = nil
    ) {
      self.reason = reason
      self.afterSequence = afterSequence
      self.refusedSince = refusedSince
      self.refusedCount = refusedCount
    }

    enum CodingKeys: String, CodingKey {
      case reason
      case afterSequence = "after_sequence"
      case refusedSince = "refused_since"
      case refusedCount = "refused_count"
    }
  }
}

// MARK: - Producer input

/// What a producer submits. Each case fixes the event's kind, evidence and
/// subject, so an invalid combination cannot be expressed.
package enum AuditRecord: Sendable {
  case requested(AuditRunID, AuditFacts.Request)
  case preparationFailed(AuditRunID, AuditFacts.PreparationFailure)
  case environment(AuditRunID, AuditFacts.Environment)
  case handoff(AuditRunID, AuditFacts.Handoff)
  case transportEnded(AuditRunID, AuditFacts.TransportEnded)
  case transportFailed(AuditRunID, AuditFacts.TransportFailed)
  case cleanup(AuditRunID, AuditFacts.Cleanup)
  /// `run-cleanup` reconciling a disposable session after its run.
  case cleanupReconciled(AuditFacts.Cleanup)
  case boundary(
    vmID: HexID, bootID: HexID?, instanceName: InstanceName, BoundaryAudit.Event)
  case recordingGap(AuditFacts.RecordingGap)

  var kind: AuditEventKind {
    switch self {
    case .requested: .invocationRequested
    case .preparationFailed: .invocationPreparationFailed
    case .environment: .invocationEnvironment
    case .handoff: .launchHandoff
    case .transportEnded: .launchTransportEnded
    case .transportFailed: .launchTransportFailed
    case .cleanup, .cleanupReconciled: .cleanupObserved
    case .boundary(_, _, _, let event): event.auditKind
    case .recordingGap: .storeRecordingGap
    }
  }

  var evidence: AuditEvidence {
    switch self {
    case .requested: .hostRequest
    case .preparationFailed, .environment, .handoff, .transportEnded, .transportFailed,
      .cleanup, .cleanupReconciled:
      .hostObservation
    case .boundary(_, _, _, let event): event.evidence
    case .recordingGap: .storeRecord
    }
  }

  var subject: AuditSubject {
    switch self {
    case .requested(let run, _), .preparationFailed(let run, _), .environment(let run, _),
      .handoff(let run, _), .transportEnded(let run, _), .transportFailed(let run, _),
      .cleanup(let run, _):
      .invocation(run)
    case .cleanupReconciled(let cleanup): .runCleanup(sessionID: cleanup.sessionID)
    case .boundary(let vm, let boot, _, _): .vm(vmID: vm, bootID: boot)
    case .recordingGap: .journal
    }
  }

  var payload: AuditPayload {
    switch self {
    case .requested(_, let fact): .requested(fact)
    case .preparationFailed(_, let fact): .preparationFailed(fact)
    case .environment(_, let fact): .environment(fact)
    case .handoff(_, let fact): .handoff(fact)
    case .transportEnded(_, let fact): .transportEnded(fact)
    case .transportFailed(_, let fact): .transportFailed(fact)
    case .cleanup(_, let fact), .cleanupReconciled(let fact): .cleanup(fact)
    case .boundary(_, _, let name, let event):
      // The legacy producer's vocabulary, without its own time and kind.
      .boundary(
        .object(
          [("instance_name", .string(name.rawValue))]
            + event.members.filter { $0.0 != "time" && $0.0 != "event" }))
    case .recordingGap(let fact): .recordingGap(fact)
    }
  }
}

extension BoundaryAudit.Event {
  var auditKind: AuditEventKind {
    switch self {
    case .boot: .boundaryBoot
    case .rawProviderForward: .boundaryRawProviderForward
    case .stop: .boundaryStop
    case .pullStage: .boundaryPullStage
    case .pullApply: .boundaryPullApply
    case .pullApplyPartial: .boundaryPullApplyPartial
    case .pullDirect: .boundaryPullDirect
    case .policyBoot: .boundaryPolicyBoot
    case .policyProxyClaim: .boundaryPolicyProxyClaim
    case .policyDecision: .boundaryPolicyDecision
    case .approvalIssued: .boundaryApprovalIssued
    case .approvalConsumed: .boundaryApprovalConsumed
    case .pullHeld: .boundaryPullHeld
    case .inputSnapshot: .boundaryInputSnapshot
    case .handoffFence: .boundaryHandoffFence
    }
  }

  var evidence: AuditEvidence {
    switch self {
    case .boot, .policyBoot, .policyProxyClaim, .policyDecision, .approvalIssued,
      .approvalConsumed, .pullHeld, .handoffFence:
      .hostDecision
    case .rawProviderForward, .stop, .pullStage, .pullApply, .pullApplyPartial, .pullDirect,
      .inputSnapshot:
      .hostObservation
    }
  }

  /// The legacy record's members.
  var members: [(String, OutputJSON)] {
    guard case .object(let members) = json(at: Date()) else { return [] }
    return members
  }
}

// MARK: - Stored event

/// An event's `data`, decoded once by its kind. Boundary events keep the
/// legacy producer's object; every other kind is a typed fact.
package enum AuditPayload: Sendable, Equatable, Encodable {
  case requested(AuditFacts.Request)
  case preparationFailed(AuditFacts.PreparationFailure)
  case environment(AuditFacts.Environment)
  case handoff(AuditFacts.Handoff)
  case transportEnded(AuditFacts.TransportEnded)
  case transportFailed(AuditFacts.TransportFailed)
  case cleanup(AuditFacts.Cleanup)
  case recordingGap(AuditFacts.RecordingGap)
  case boundary(OutputJSON)

  init(_ kind: AuditEventKind, from data: KeyedDecodingContainer<AuditEvent.CodingKeys>) throws {
    let key = AuditEvent.CodingKeys.data
    switch kind {
    case .invocationRequested:
      self = .requested(try data.decode(AuditFacts.Request.self, forKey: key))
    case .invocationEnvironment:
      self = .environment(try data.decode(AuditFacts.Environment.self, forKey: key))
    case .invocationPreparationFailed:
      self = .preparationFailed(try data.decode(AuditFacts.PreparationFailure.self, forKey: key))
    case .launchHandoff: self = .handoff(try data.decode(AuditFacts.Handoff.self, forKey: key))
    case .launchTransportEnded:
      self = .transportEnded(try data.decode(AuditFacts.TransportEnded.self, forKey: key))
    case .launchTransportFailed:
      self = .transportFailed(try data.decode(AuditFacts.TransportFailed.self, forKey: key))
    case .cleanupObserved: self = .cleanup(try data.decode(AuditFacts.Cleanup.self, forKey: key))
    case .storeRecordingGap:
      self = .recordingGap(try data.decode(AuditFacts.RecordingGap.self, forKey: key))
    case .boundaryBoot, .boundaryRawProviderForward, .boundaryStop, .boundaryPullStage,
      .boundaryPullApply, .boundaryPullApplyPartial, .boundaryPullDirect, .boundaryPolicyBoot,
      .boundaryPolicyProxyClaim, .boundaryPolicyDecision, .boundaryApprovalIssued,
      .boundaryApprovalConsumed, .boundaryPullHeld, .boundaryInputSnapshot, .boundaryHandoffFence:
      let object = try data.decode(OutputJSON.self, forKey: key)
      guard case .object = object else {
        throw DecodingError.dataCorruptedError(
          forKey: key, in: data, debugDescription: "boundary data is not an object")
      }
      self = .boundary(object)
    }
  }

  package func encode(to encoder: any Encoder) throws {
    switch self {
    case .requested(let fact): try fact.encode(to: encoder)
    case .preparationFailed(let fact): try fact.encode(to: encoder)
    case .environment(let fact): try fact.encode(to: encoder)
    case .handoff(let fact): try fact.encode(to: encoder)
    case .transportEnded(let fact): try fact.encode(to: encoder)
    case .transportFailed(let fact): try fact.encode(to: encoder)
    case .cleanup(let fact): try fact.encode(to: encoder)
    case .recordingGap(let fact): try fact.encode(to: encoder)
    case .boundary(let object): try object.encode(to: encoder)
    }
  }
}

/// An iso-owned value as dynamic JSON, for rendering beside other members.
package func auditJSON(_ value: some Encodable) throws -> OutputJSON {
  let bytes = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(OutputJSON.self, from: bytes)
}

/// One immutable `iso.audit/v1` event as stored and returned.
package struct AuditEvent: Sendable, Equatable, Codable {
  /// The largest encoded event the store accepts.
  package static let maxEncodedBytes = 16 << 10

  package let eventID: AuditEventID
  package let journalID: AuditJournalID
  package let sequence: UInt64
  package let recordedAt: String
  package let kind: AuditEventKind
  package let producer: AuditProducer
  package let evidence: AuditEvidence
  package let subject: AuditSubject
  package let data: AuditPayload

  enum CodingKeys: String, CodingKey {
    case sequence, kind, producer, evidence, subject, data
    case eventID = "event_id"
    case journalID = "journal_id"
    case recordedAt = "recorded_at"
  }

  init(
    eventID: AuditEventID, journalID: AuditJournalID, sequence: UInt64, recordedAt: String,
    record: AuditRecord
  ) {
    self.eventID = eventID
    self.journalID = journalID
    self.sequence = sequence
    self.recordedAt = recordedAt
    self.kind = record.kind
    self.producer = .iso
    self.evidence = record.evidence
    self.subject = record.subject
    self.data = record.payload
  }

  /// A payload that does not match its kind makes the whole record
  /// unparseable; it is never half-trusted.
  package init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    eventID = try values.decode(AuditEventID.self, forKey: .eventID)
    journalID = try values.decode(AuditJournalID.self, forKey: .journalID)
    sequence = try values.decode(UInt64.self, forKey: .sequence)
    recordedAt = try values.decode(String.self, forKey: .recordedAt)
    kind = try values.decode(AuditEventKind.self, forKey: .kind)
    producer = try values.decode(AuditProducer.self, forKey: .producer)
    evidence = try values.decode(AuditEvidence.self, forKey: .evidence)
    subject = try values.decode(AuditSubject.self, forKey: .subject)
    data = try AuditPayload(kind, from: values)
    guard sequence > 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .sequence, in: values, debugDescription: "not an audit event")
    }
  }

  /// Compact JSON, the stored line without its newline.
  package func encoded() throws -> [UInt8] {
    Array(try JSONOutput.render(self, pretty: false).utf8)
  }
}
