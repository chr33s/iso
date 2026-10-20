import Foundation

/// The immutable workflow plan produced by the preflight compiler (spec
/// section 9) and consumed by the job graph, the job-message builder and
/// provenance. Values that the official runner evaluates at run time stay
/// unevaluated `TemplateValue`s; the compiler only validates them.

/// A workflow value as written: literals, or expressions the runner (or the
/// controller, for job-level fields) evaluates later.
package indirect enum TemplateValue: Sendable, Equatable, Hashable, Codable {
  /// A literal string with no `${{ }}`.
  case string(String)
  /// An expression. A whole-value `${{ x }}` is stored as `x`; a string that
  /// mixes literal text and expressions is stored as the equivalent
  /// `format('…{0}…', x)` expression, as GitHub compiles it.
  case expression(String)
  case bool(Bool)
  case number(Double)
  case null
  case sequence([TemplateValue])
  case mapping([TemplateEntry])

  package var literalString: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// Whether this value or any nested value is an expression.
  package var containsExpression: Bool {
    switch self {
    case .expression: true
    case .sequence(let items): items.contains(where: \.containsExpression)
    case .mapping(let entries): entries.contains { $0.value.containsExpression }
    default: false
    }
  }
}

package struct TemplateEntry: Sendable, Equatable, Hashable, Codable {
  package let key: String
  package let value: TemplateValue

  package init(key: String, value: TemplateValue) {
    self.key = key
    self.value = value
  }
}

/// A `uses:` reference.
package enum ActionReference: Sendable, Equatable, Hashable, Codable {
  /// `owner/repo[/path]@ref`.
  case repository(owner: String, repository: String, path: String?, ref: String)
  /// `docker://image`.
  case docker(image: String)
  /// `./path` inside the workspace.
  case local(path: String)

  package var displayName: String {
    switch self {
    case .repository(let owner, let repository, let path, let ref):
      "\(owner)/\(repository)\(path.map { "/" + $0 } ?? "")@\(ref)"
    case .docker(let image): "docker://\(image)"
    case .local(let path): path
    }
  }

  /// `owner/repo` for repository actions.
  package var nameWithOwner: String? {
    if case .repository(let owner, let repository, _, _) = self { return "\(owner)/\(repository)" }
    return nil
  }
}

/// An action archive approved for delivery: the exact resolved commit and
/// the archive digest in the object store.
package struct ResolvedAction: Sendable, Equatable, Hashable, Codable {
  package let nameWithOwner: String
  package let ref: String
  package let commit: String
  package let archiveDigest: Digest

  package init(nameWithOwner: String, ref: String, commit: String, archiveDigest: Digest) {
    self.nameWithOwner = nameWithOwner
    self.ref = ref
    self.commit = commit
    self.archiveDigest = archiveDigest
  }
}

/// What a step does.
package enum StepKind: Sendable, Equatable, Codable {
  case run(script: TemplateValue, shell: TemplateValue?, workingDirectory: TemplateValue?)
  case uses(ActionReference, with: [TemplateEntry])
  /// Visible synthetic step: materialize the base commit from the snapshot
  /// in place of an approved `actions/checkout`.
  case syntheticCheckout(path: String)
  /// Visible synthetic step: apply and verify the selected working-tree
  /// snapshot (including deletions and modes) at this boundary.
  case snapshotOverlay(path: String)
}

package struct StepPlan: Sendable, Equatable, Codable {
  /// The step's context name (`id:` or a generated `__N`).
  package let contextName: String
  package let name: TemplateValue?
  package let kind: StepKind
  package let env: [TemplateEntry]
  /// The step `if:` as expression text (default `success()`).
  package let condition: String
  package let continueOnError: TemplateValue
  package let timeoutMinutes: TemplateValue?
  /// True for steps iso-ci inserted; always shown in logs and results.
  package let synthetic: Bool

  package init(
    contextName: String, name: TemplateValue?, kind: StepKind, env: [TemplateEntry],
    condition: String, continueOnError: TemplateValue, timeoutMinutes: TemplateValue?,
    synthetic: Bool
  ) {
    self.contextName = contextName
    self.name = name
    self.kind = kind
    self.env = env
    self.condition = condition
    self.continueOnError = continueOnError
    self.timeoutMinutes = timeoutMinutes
    self.synthetic = synthetic
  }
}

package struct ContainerPlan: Sendable, Equatable, Codable {
  package let image: TemplateValue
  package let env: [TemplateEntry]
  package let ports: [TemplateValue]
  package let volumes: [TemplateValue]
  package let options: TemplateValue?

  package init(
    image: TemplateValue, env: [TemplateEntry], ports: [TemplateValue], volumes: [TemplateValue],
    options: TemplateValue?
  ) {
    self.image = image
    self.env = env
    self.ports = ports
    self.volumes = volumes
    self.options = options
  }
}

package struct RunDefaults: Sendable, Equatable, Codable {
  package let shell: String?
  package let workingDirectory: String?

  package init(shell: String?, workingDirectory: String?) {
    self.shell = shell
    self.workingDirectory = workingDirectory
  }
}

/// `strategy` values a job sees in its `strategy` context.
package struct StrategyContext: Sendable, Equatable, Codable {
  package let failFast: Bool
  package let jobIndex: Int
  package let jobTotal: Int
  package let maxParallel: Int

  package init(failFast: Bool, jobIndex: Int, jobTotal: Int, maxParallel: Int) {
    self.failFast = failFast
    self.jobIndex = jobIndex
    self.jobTotal = jobTotal
    self.maxParallel = maxParallel
  }
}

/// One expanded job (a matrix combination is its own job).
package struct JobPlan: Sendable, Equatable, Codable {
  /// Unique within the plan: the job id plus a canonical matrix suffix.
  package let key: String
  package let jobID: String
  package let displayName: String
  /// Job keys this job depends on (all matrix expansions of each `needs`).
  package let needs: [String]
  /// The workflow job ids named in `needs` (for the `needs` context).
  package let needsJobIDs: [String]
  /// Job-level `if:` expression text, evaluated by the controller.
  package let condition: String
  package let runsOn: [String]
  package let platform: String
  package let matrix: JSONValue?
  package let strategy: StrategyContext
  package let env: [TemplateEntry]
  package let defaults: RunDefaults
  package let timeoutMinutes: Int
  package let continueOnError: Bool
  package let container: ContainerPlan?
  package let services: [String: ContainerPlan]
  package let steps: [StepPlan]
  package let outputs: [TemplateEntry]
  /// Secret names the job's expressions reference (values are never in the plan).
  package let secretNames: [String]

  package init(
    key: String, jobID: String, displayName: String, needs: [String], needsJobIDs: [String],
    condition: String, runsOn: [String], platform: String, matrix: JSONValue?,
    strategy: StrategyContext, env: [TemplateEntry], defaults: RunDefaults, timeoutMinutes: Int,
    continueOnError: Bool, container: ContainerPlan?, services: [String: ContainerPlan],
    steps: [StepPlan], outputs: [TemplateEntry], secretNames: [String]
  ) {
    self.key = key
    self.jobID = jobID
    self.displayName = displayName
    self.needs = needs
    self.needsJobIDs = needsJobIDs
    self.condition = condition
    self.runsOn = runsOn
    self.platform = platform
    self.matrix = matrix
    self.strategy = strategy
    self.env = env
    self.defaults = defaults
    self.timeoutMinutes = timeoutMinutes
    self.continueOnError = continueOnError
    self.container = container
    self.services = services
    self.steps = steps
    self.outputs = outputs
    self.secretNames = secretNames
  }
}

/// The compiled workflow. Its digest identifies the plan independently of
/// the source snapshot and patch revision.
package struct WorkflowPlan: Sendable, Equatable, Codable {
  package let name: String
  /// Repository-relative workflow path (for example `.github/workflows/ci.yml`).
  package let workflowPath: String
  package let workflowDigest: Digest
  /// The simulated triggering event name and its payload.
  package let event: String
  package let eventPayload: JSONValue
  package let env: [TemplateEntry]
  package let defaults: RunDefaults
  /// Expanded jobs in a deterministic topological order.
  package let jobs: [JobPlan]
  package let manifestID: String
  package let manifestDigest: Digest
  /// Repository actions the plan uses (before resolution to commits).
  package let actions: [ActionReference]
  /// Explicit platform mappings applied (runs-on label → platform).
  package let platformMappings: [String: String]

  package init(
    name: String, workflowPath: String, workflowDigest: Digest, event: String,
    eventPayload: JSONValue, env: [TemplateEntry], defaults: RunDefaults, jobs: [JobPlan],
    manifestID: String, manifestDigest: Digest, actions: [ActionReference],
    platformMappings: [String: String]
  ) {
    self.name = name
    self.workflowPath = workflowPath
    self.workflowDigest = workflowDigest
    self.event = event
    self.eventPayload = eventPayload
    self.env = env
    self.defaults = defaults
    self.jobs = jobs
    self.manifestID = manifestID
    self.manifestDigest = manifestDigest
    self.actions = actions
    self.platformMappings = platformMappings
  }

  package var digest: Digest { descriptorDigest(self) }

  package func job(_ key: String) -> JobPlan? { jobs.first { $0.key == key } }
}

extension JSONValue: Codable {
  package init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}
