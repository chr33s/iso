import Foundation

/// The persisted record families (spec section 5): profile/pool state,
/// allocations, and preflight runs/jobs. These records correlate work; the
/// host ledger keeps owning the actual resources. No record stores a secret.

package enum AllocationKind: String, Sendable, Codable, CaseIterable {
  case connected
  case preflight
}

/// What the controller wants to happen to an allocation next.
package enum DesiredDisposition: String, Sendable, Codable, CaseIterable {
  /// Keep (or get) the environment ready and let it run its job.
  case active
  /// Retire when idle; let assigned work finish within its bounds.
  case drain
  /// Externally stop now (abort, expiry, revocation).
  case stop
  /// Keep the VM running for debugging until a host deadline.
  case retainLive = "retain_live"
  /// Keep the stopped disk and results until a host deadline.
  case retainStopped = "retain_stopped"
  /// Destroy and verify cleanup.
  case release
}

/// The workload's own result. `unknown` is never failed, stopped or reusable.
package enum ExecutionOutcome: String, Sendable, Codable, CaseIterable {
  case pending, running, succeeded, failed, cancelled, interrupted, unknown

  package var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled, .interrupted: true
    case .pending, .running, .unknown: false
    }
  }
}

/// Result export, independent of execution. Only an operator request
/// (`iso-ci results`) moves it past `notRequested`.
package enum ExportOutcome: String, Sendable, Codable, CaseIterable {
  case notRequested = "not_requested"
  case requested, pending, exported, failed
}

/// VM/storage cleanup, independent of execution and registration.
package enum CleanupOutcome: String, Sendable, Codable, CaseIterable {
  case notStarted = "not_started"
  case pending
  /// The host verified the VM and its storage are gone.
  case verified
  /// Cleanup was requested and not verified; still consumes budget.
  case debt
}

/// GitHub runner registration, independent of the VM.
package enum RegistrationState: String, Sendable, Codable, CaseIterable {
  case notApplicable = "not_applicable"
  /// The runner name is persisted; no JIT request was sent yet.
  case intended
  /// A JIT request was sent and its reply is unknown; never blindly retried.
  case uncertain
  case registered
  /// GitHub reports the runner busy or a job assigned to it.
  case assigned
  case removalPending = "removal_pending"
  case removed
}

/// Host operation identities persisted before their request is sent.
package struct HostOperations: Sendable, Equatable, Codable {
  package var create: HostOperationID
  package var complete: HostOperationID?
  package var retain: HostOperationID?
  package var release: HostOperationID?
  package var acknowledge: HostOperationID?

  package init(create: HostOperationID) { self.create = create }
}

/// A host-side resource reservation counted against budgets until cleanup
/// is verified.
package struct ResourceReservation: Sendable, Equatable, Codable {
  package var cpus: UInt32
  package var memoryMiB: UInt64
  package var diskGiB: UInt64

  package init(cpus: UInt32, memoryMiB: UInt64, diskGiB: UInt64) {
    self.cpus = cpus
    self.memoryMiB = memoryMiB
    self.diskGiB = diskGiB
  }

  package static let zero = ResourceReservation(cpus: 0, memoryMiB: 0, diskGiB: 0)
}

/// The GitHub job a connected runner ran, bound from GitHub observations
/// (never from guest log hints). Absent for an idle allocation.
package struct GitHubJobRef: Sendable, Equatable, Codable {
  package var repository: String
  package var runID: Int64
  package var runAttempt: Int64
  package var jobID: Int64
  package var jobName: String
  package var htmlURL: String?
  package var status: String
  /// GitHub's conclusion; nil while the API cannot confirm one.
  package var conclusion: String?

  package init(
    repository: String, runID: Int64, runAttempt: Int64, jobID: Int64, jobName: String,
    htmlURL: String?, status: String, conclusion: String?
  ) {
    self.repository = repository
    self.runID = runID
    self.runAttempt = runAttempt
    self.jobID = jobID
    self.jobName = jobName
    self.htmlURL = htmlURL
    self.status = status
    self.conclusion = conclusion
  }
}

/// Immutable input provenance recorded at allocation (spec sections 5, 9).
package struct InputProvenance: Sendable, Equatable, Codable {
  package var profileDigest: Digest
  package var imageReference: String
  package var imageDigest: Digest?
  package var expectedRunnerVersion: String?
  package var networkPolicyDigest: Digest?
  package var qualificationDigest: Digest?
  package var qualificationTuple: [String: String]
  package var compatibilityDigest: Digest?
  package var limitsDigest: Digest?
  package var platform: String
  /// Preflight only: base commit, snapshot, workflow, actions, patch revision.
  package var baseCommit: String?
  package var snapshotDigest: Digest?
  package var workflowDigest: Digest?
  package var actionsDigest: Digest?
  package var patchRevision: Int?
  /// Dependency outputs/artifacts consumed, by origin attempt.
  package var dependencyAttempts: [String]

  package init(
    profileDigest: Digest, imageReference: String, imageDigest: Digest?,
    expectedRunnerVersion: String?, networkPolicyDigest: Digest?, qualificationDigest: Digest?,
    qualificationTuple: [String: String], compatibilityDigest: Digest?, limitsDigest: Digest?,
    platform: String
  ) {
    self.profileDigest = profileDigest
    self.imageReference = imageReference
    self.imageDigest = imageDigest
    self.expectedRunnerVersion = expectedRunnerVersion
    self.networkPolicyDigest = networkPolicyDigest
    self.qualificationDigest = qualificationDigest
    self.qualificationTuple = qualificationTuple
    self.compatibilityDigest = compatibilityDigest
    self.limitsDigest = limitsDigest
    self.platform = platform
    dependencyAttempts = []
  }
}

/// One owned environment request (spec section 5).
package struct AllocationRecord: Sendable, Equatable, Codable {
  package let id: AllocationID
  package let kind: AllocationKind
  package let controller: ControllerID
  package var pool: Name?
  package var preflightRun: PreflightRunID?
  package var jobAttempt: JobAttemptID?
  package var host: Name
  package var hostID: HostID?
  package var ownerID: OwnerID?
  package let hostRun: HostRunID
  package var operations: HostOperations
  package var instance: QualifiedInstance?
  package var bootID: BootID?
  package var runGeneration: UInt64?
  package var observedRunPhase: RunPhase?
  package var networkProof: NetworkProof?
  package var provenance: InputProvenance
  package var reservation: ResourceReservation
  package var desired: DesiredDisposition
  package var execution: ExecutionOutcome
  package var export: ExportOutcome
  /// The staged result archive, once exported.
  package var resultDigest: Digest?
  /// Stop plus export grace from the profile, bounding the host's completion.
  package var completionGraceSeconds: EpochSeconds?
  package var vmCleanup: CleanupOutcome
  package var registration: RegistrationState
  package var runnerName: String?
  package var runnerID: Int64?
  package var actualRunnerVersion: String?
  package var githubScope: String?
  package var labels: [String]
  package var job: GitHubJobRef?
  /// Runner-process health, distinct from GitHub's job conclusion.
  package var runnerExitStatus: Int32?
  package var createdAt: EpochSeconds
  package var readyAt: EpochSeconds?
  package var assignedAt: EpochSeconds?
  package var finishedAt: EpochSeconds?
  package var hardDeadline: EpochSeconds
  package var idleRetireAt: EpochSeconds?
  package var retentionUntil: EpochSeconds?
  package var lastObservedAt: EpochSeconds?
  /// Why the controller cannot currently decide (unknown, never failed).
  package var uncertainty: String?
  package var diagnostics: [String]

  package init(
    id: AllocationID, kind: AllocationKind, controller: ControllerID, host: Name,
    hostRun: HostRunID, operations: HostOperations, provenance: InputProvenance,
    reservation: ResourceReservation, createdAt: EpochSeconds, hardDeadline: EpochSeconds
  ) {
    self.id = id
    self.kind = kind
    self.controller = controller
    self.host = host
    self.hostRun = hostRun
    self.operations = operations
    self.provenance = provenance
    self.reservation = reservation
    desired = .active
    execution = .pending
    export = .notRequested
    vmCleanup = .notStarted
    registration = kind == .connected ? .intended : .notApplicable
    labels = []
    self.createdAt = createdAt
    self.hardDeadline = hardDeadline
    diagnostics = []
  }

  /// Whether this allocation still holds (or may hold) host resources and
  /// therefore consumes budget. Uncertain and debt states count.
  package var holdsResources: Bool {
    vmCleanup != .verified
  }

  /// Whether a GitHub registration may still exist and must be resolved.
  package var holdsRegistration: Bool {
    switch registration {
    case .intended, .uncertain, .registered, .assigned, .removalPending: true
    case .notApplicable, .removed: false
    }
  }

  /// Fully settled: nothing left to observe, release or verify.
  package var isSettled: Bool { !holdsResources && !holdsRegistration }

  /// The UI phase is derived from independent observations, never stored.
  package var phase: String {
    if isSettled { return "settled" }
    if uncertainty != nil { return "uncertain" }
    if vmCleanup == .debt { return "cleanup-debt" }
    switch desired {
    case .retainLive: return "retained-live"
    case .retainStopped: return "retained-stopped"
    case .stop: return "stopping"
    case .release: return "releasing"
    case .drain, .active: break
    }
    switch execution {
    case .pending: return readyAt == nil ? "starting" : (job == nil ? "idle" : "assigned")
    case .running: return "running"
    case .unknown: return "unknown"
    default: return "finished"
    }
  }

  package mutating func note(_ message: String) {
    diagnostics.append(CIError.bounded(message))
    if diagnostics.count > 32 { diagnostics.removeFirst(diagnostics.count - 32) }
  }
}

/// An external operation persisted before it is sent (spec section 7 step 2).
package struct IntentRecord: Sendable, Equatable, Codable {
  package enum Kind: String, Sendable, Codable, CaseIterable {
    case hostRunCreate = "host.run.create"
    case hostRunComplete = "host.run.complete"
    case hostRunRetain = "host.run.retain"
    case hostRunDiscard = "host.run.discard"
    case hostRunAcknowledge = "host.run.ack"
    case githubJITCreate = "github.jit.create"
    case githubRunnerDelete = "github.runner.delete"
  }

  package enum Status: String, Sendable, Codable, CaseIterable {
    /// Persisted; not yet sent.
    case pending
    /// Sent; awaiting a reply or confirmation.
    case sent
    /// The external system confirmed the effect.
    case confirmed
    /// Sent and the outcome could not be established.
    case uncertain
    /// The external system refused it (no effect).
    case refused
  }

  package let id: String
  package let allocation: AllocationID
  package let kind: Kind
  package var status: Status
  package var attempts: Int
  package let createdAt: EpochSeconds
  package var updatedAt: EpochSeconds
  /// Nonsecret parameters needed to retry or reconcile the same identity.
  package var parameters: [String: String]
  package var outcome: String?

  package init(
    id: String, allocation: AllocationID, kind: Kind, parameters: [String: String],
    at: EpochSeconds
  ) {
    self.id = id
    self.allocation = allocation
    self.kind = kind
    status = .pending
    attempts = 0
    createdAt = at
    updatedAt = at
    self.parameters = parameters
  }
}

/// Pool lifecycle chosen by the operator; replenishment follows it.
package enum PoolState: String, Sendable, Codable, CaseIterable {
  case active
  /// Stop replenishment; never kill assigned work.
  case paused
  /// Stop replenishment and retire idle capacity.
  case draining
  /// Configuration invalid, unqualified or unapproved: no admission.
  case inactive
  /// Offboarding requested: remove owned resources.
  case removing
  case removed
}

package struct PoolStatusRecord: Sendable, Equatable, Codable {
  package let name: Name
  package var state: PoolState
  package var reason: String?
  package var configDigest: Digest?
  package var updatedAt: EpochSeconds

  package init(
    name: Name, state: PoolState, reason: String?, configDigest: Digest?, at: EpochSeconds
  ) {
    self.name = name
    self.state = state
    self.reason = reason
    self.configDigest = configDigest
    updatedAt = at
  }
}

/// A host the operator enabled for CI; identity pinned on first contact.
package struct HostRecord: Sendable, Equatable, Codable {
  package enum State: String, Sendable, Codable {
    case enabled
    case disabled
    /// Unreachable or unresolved: budgets stay reserved, no new admission.
    case quarantined
  }

  package let alias: Name
  package var hostID: HostID?
  package var ownerID: OwnerID?
  package var state: State
  package var reason: String?
  package var capabilities: HostCapabilitiesSnapshot?
  package var observedAt: EpochSeconds?
  package var enabledAt: EpochSeconds

  package init(alias: Name, at: EpochSeconds) {
    self.alias = alias
    state = .enabled
    enabledAt = at
  }
}

/// The persisted subset of `host.capabilities` used for admission and status.
package struct HostCapabilitiesSnapshot: Sendable, Equatable, Codable {
  package var advertised: [String]
  package var transport: String?
  package var qualificationStatus: String?
  package var qualificationDigest: Digest?
  package var qualificationTuple: [String: String]
  package var qualificationExpiresAt: EpochSeconds?
  package var runPolicyDigests: [String: Digest]
  package var retentionSlots: UInt64
  package var maxTTLSeconds: UInt64
  package var epoch: DaemonEpoch?

  package init(_ capabilities: HostCapabilities, epoch: DaemonEpoch?) {
    advertised = capabilities.advertised.sorted()
    transport = capabilities.transport
    qualificationStatus = capabilities.qualification?.status.rawValue
    qualificationDigest = capabilities.qualification?.manifestDigest
    qualificationTuple = capabilities.qualification?.tuple ?? [:]
    qualificationExpiresAt = capabilities.qualification?.expiresAt
    runPolicyDigests = Dictionary(
      uniqueKeysWithValues: capabilities.runPolicies.map { ($0.key.rawValue, $0.value.digest) })
    retentionSlots = capabilities.retentionSlots
    maxTTLSeconds = capabilities.maxTTLSeconds
    self.epoch = epoch
  }
}

/// A descriptor digest the operator approved; a changed descriptor needs
/// re-approval before any pool using it activates.
package struct ApprovalRecord: Sendable, Equatable, Codable {
  package enum Kind: String, Sendable, Codable, CaseIterable {
    case image
    case networkPolicy = "network_policy"
    case compatibility, limits, profile
  }

  package let kind: Kind
  package let name: Name
  package let digest: Digest
  package let approvedAt: EpochSeconds

  package init(kind: Kind, name: Name, digest: Digest, approvedAt: EpochSeconds) {
    self.kind = kind
    self.name = name
    self.digest = digest
    self.approvedAt = approvedAt
  }
}

/// A GitHub App this controller manages. The private key lives only in the
/// protected credential store under `credentialReference`.
package struct GitHubAppRecord: Sendable, Equatable, Codable {
  package let appID: Int64
  package var slug: String
  package var owner: String
  package var clientID: String?
  package var htmlURL: String?
  package var credentialReference: String
  package var createdAt: EpochSeconds

  package init(
    appID: Int64, slug: String, owner: String, clientID: String?, htmlURL: String?,
    credentialReference: String, createdAt: EpochSeconds
  ) {
    self.appID = appID
    self.slug = slug
    self.owner = owner
    self.clientID = clientID
    self.htmlURL = htmlURL
    self.credentialReference = credentialReference
    self.createdAt = createdAt
  }
}

package struct InstallationRecord: Sendable, Equatable, Codable {
  package let name: Name
  package var installationID: Int64
  package var appID: Int64
  package var account: String
  package var accountType: String
  /// `all` or `selected`, as GitHub reports it.
  package var repositorySelection: String
  package var permissions: [String: String]
  package var verifiedAt: EpochSeconds

  package init(
    name: Name, installationID: Int64, appID: Int64, account: String, accountType: String,
    repositorySelection: String, permissions: [String: String], verifiedAt: EpochSeconds
  ) {
    self.name = name
    self.installationID = installationID
    self.appID = appID
    self.account = account
    self.accountType = accountType
    self.repositorySelection = repositorySelection
    self.permissions = permissions
    self.verifiedAt = verifiedAt
  }
}

/// One bounded operational event, readable by cursor (spec section 12).
package struct EventRecord: Sendable, Equatable, Codable {
  package let sequence: Int64
  package let at: EpochSeconds
  package let subject: String
  package let kind: String
  package let message: String
  package let data: [String: String]
}
