import Foundation

/// Persisted preflight state (spec section 5, "Preflight run/job"): the
/// compiled graph, matrix identities, dependency outputs, snapshots and
/// attempt links. Absent from connected scheduling. No secret values.

package enum PreflightRunState: String, Sendable, Codable, CaseIterable {
  case running
  case finished
  case aborting
  case aborted
}

/// One immutable input revision: the base commit and the selected snapshot.
/// A patch adds a revision; it never rewrites an earlier one.
package struct InputRevision: Sendable, Equatable, Codable {
  package let number: Int
  package let baseCommit: String
  package let snapshot: Digest
  package let dirty: Bool
  package let capturedAt: EpochSeconds
  /// The attempt whose retained workspace received this revision (patch).
  package let patchedAttempt: JobAttemptID?

  package init(
    number: Int, baseCommit: String, snapshot: Digest, dirty: Bool, capturedAt: EpochSeconds,
    patchedAttempt: JobAttemptID?
  ) {
    self.number = number
    self.baseCommit = baseCommit
    self.snapshot = snapshot
    self.dirty = dirty
    self.capturedAt = capturedAt
    self.patchedAttempt = patchedAttempt
  }
}

package struct PreflightRunRecord: Sendable, Equatable, Codable {
  package let id: PreflightRunID
  package let repositoryPath: String
  package let repository: String
  package let plan: WorkflowPlan
  package var revisions: [InputRevision]
  package var state: PreflightRunState
  package var conclusion: String?
  package let createdAt: EpochSeconds
  package var finishedAt: EpochSeconds?
  package let pinnedHost: Name?
  package let profile: Name
  package let inputs: [String: String]
  /// Names only: values live in controller memory for the run's lifetime.
  package let secretNames: [String]
  package let retainOnFailure: FailureRetention
  package var notes: [String]

  package init(
    id: PreflightRunID, repositoryPath: String, repository: String, plan: WorkflowPlan,
    revision: InputRevision, createdAt: EpochSeconds, pinnedHost: Name?, profile: Name,
    inputs: [String: String], secretNames: [String], retainOnFailure: FailureRetention
  ) {
    self.id = id
    self.repositoryPath = repositoryPath
    self.repository = repository
    self.plan = plan
    revisions = [revision]
    state = .running
    self.createdAt = createdAt
    self.pinnedHost = pinnedHost
    self.profile = profile
    self.inputs = inputs
    self.secretNames = secretNames
    self.retainOnFailure = retainOnFailure
    notes = []
  }

  package var baseRevision: InputRevision { revisions[0] }
}

package enum JobAttemptState: String, Sendable, Codable, CaseIterable {
  case pending
  case provisioning
  case running
  case succeeded
  case failed
  case cancelled
  case skipped
  /// The environment was lost before a result: never presented as failed or passed.
  case interrupted

  package var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled, .skipped, .interrupted: true
    case .pending, .provisioning, .running: false
    }
  }
}

package struct StepOutcome: Sendable, Equatable, Codable {
  package let name: String
  package let conclusion: String
  package let synthetic: Bool

  package init(name: String, conclusion: String, synthetic: Bool) {
    self.name = name
    self.conclusion = conclusion
    self.synthetic = synthetic
  }
}

/// One whole-job attempt. Retry creates a new attempt in a clean VM; it
/// never continues a failed step.
package struct JobAttemptRecord: Sendable, Equatable, Codable {
  package let id: JobAttemptID
  package let run: PreflightRunID
  package let jobKey: String
  package let number: Int
  package var state: JobAttemptState
  package var allocation: AllocationID?
  /// The input revision this attempt received at its materialization
  /// boundary, plus any later patch revisions applied to its workspace.
  package var inputRevision: Int
  package var patchRevisions: [Int]
  /// Dependency attempts whose outputs/artifacts this attempt consumed.
  package var dependencyAttempts: [JobAttemptID]
  /// True when dependencies ran on a different input revision.
  package var mixedInputs: Bool
  package var outputs: [String: String]
  package var steps: [StepOutcome]
  package var logObjects: [Digest]
  package var reason: String?
  package var startedAt: EpochSeconds?
  /// When the runner acquired the job; a launch that never acquires within
  /// the profile's boot allowance fails instead of holding its VM.
  package var acquiredAt: EpochSeconds?
  package var finishedAt: EpochSeconds?
  package var retainedUntil: EpochSeconds?

  package init(
    id: JobAttemptID, run: PreflightRunID, jobKey: String, number: Int, inputRevision: Int
  ) {
    self.id = id
    self.run = run
    self.jobKey = jobKey
    self.number = number
    state = .pending
    self.inputRevision = inputRevision
    patchRevisions = []
    dependencyAttempts = []
    mixedInputs = false
    outputs = [:]
    steps = []
    logObjects = []
  }

  /// The ObjectStore subject this attempt authenticates as.
  package var subject: String { "attempt:\(id)" }
}
