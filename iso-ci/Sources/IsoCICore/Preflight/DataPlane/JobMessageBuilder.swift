import Foundation

/// Builds the official runner's job message (`AgentJobRequestMessage`,
/// delivered through the run-service `acquirejob` route) from a compiled
/// `JobPlan`.
///
/// Wire format provenance: actions/runner v2.329.0 (MIT) —
/// `src/Sdk/DTPipelines/Pipelines/AgentJobRequestMessage.cs`,
/// `ObjectTemplating/Tokens/TemplateTokenJsonConverter.cs` (template tokens:
/// plain JSON scalars for literals, `{"type":3,"expr":…}` expressions,
/// `{"type":1,"seq":[…]}`, `{"type":2,"map":[{"Key":…,"Value":…}]}`),
/// `ContextData/PipelineContextDataJsonConverter.cs` (`{"t":1,"a":[…]}`,
/// `{"t":2,"d":[{"k":…,"v":…}]}`), `ActionStep.cs`,
/// `ActionStepDefinitionReference.cs`, and the worker's use of
/// `system.github.results_endpoint`, `system.github.launch_endpoint` and the
/// `SystemVssConnection` endpoint data (`CacheServerUrl`,
/// `ResultsServiceUrl`). See iso-ci/PROVENANCE.md.
///
/// The runner evaluates step-level expressions itself; the message carries
/// them unevaluated. No OIDC request URL (`GenerateIdTokenUrl`) is ever
/// provided, so `ACTIONS_ID_TOKEN_REQUEST_*` never reaches a job.
package enum JobMessageBuilder {
  /// The access-token placeholder the endpoint replaces, structurally, with
  /// a job token it minted when the runner acquires the job.
  package static let accessTokenPlaceholder = "__ISO_CI_JOB_ACCESS_TOKEN__"
  /// The message type that routes the worker through run-service, results
  /// and launch clients (plain REST/twirp, no VSS location service).
  package static let messageType = "RunnerJobRequest"
  package static let reservedSecretNames: Set<String> = ["ISO_CI_TOKEN", "GITHUB_TOKEN"]
  package static let maxSecrets = 100
  package static let maxSecretBytes = 48 << 10

  /// Guest-side addresses of the single scoped endpoint.
  package struct Endpoint: Sendable, Equatable {
    /// `http://<host>:<port>/` as the runner (and its containers) see it.
    package let base: String
    /// `github.server_url`: a `.localhost` name so toolkits do not treat the
    /// endpoint as GHES (they never contact it through this name).
    package let serverURL: String

    package init(host: GuestEndpointHost = .loopback, guestPort: UInt16) {
      base = "http://\(host.rawValue):\(guestPort)/"
      serverURL = "http://iso-ci.localhost:\(guestPort)"
    }

    package var runService: String { base + "run/" }
    package var cache: String { base + "cache/" }
    package var broker: String { base + "broker/" }
    package var oauth: String { base + "_apis/oauth2/token" }
  }

  /// Identity of one attempt in runner terms.
  package struct Identity: Sendable, Equatable {
    package let planID: UUID
    package let jobID: UUID
    package let timelineID: UUID

    package init(attempt: JobAttemptID, run: PreflightRunID) {
      jobID = UUID(uuidString: attempt.rawValue) ?? UUID()
      planID = UUID(uuidString: run.rawValue) ?? UUID()
      timelineID = Self.derived(attempt.rawValue + "/timeline")
    }

    /// A stable UUID derived from a string (step and timeline ids).
    package static func derived(_ seed: String) -> UUID {
      let digest = Array(Digest(hashing: seed).rawValue.utf8)
      var bytes = [UInt8](repeating: 0, count: 16)
      for index in 0..<16 {
        let high = hexValue(digest[index * 2])
        let low = hexValue(digest[index * 2 + 1])
        bytes[index] = high << 4 | low
      }
      bytes[6] = (bytes[6] & 0x0F) | 0x50
      bytes[8] = (bytes[8] & 0x3F) | 0x80
      return UUID(
        uuid: (
          bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
          bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func hexValue(_ byte: UInt8) -> UInt8 {
      byte >= UInt8(ascii: "a") ? byte - UInt8(ascii: "a") + 10 : byte - UInt8(ascii: "0")
    }
  }

  /// Run-level values for the `github`, `needs`, `vars` and `inputs`
  /// contexts. The event payload is the local simulated payload.
  package struct Contexts: Sendable, Equatable {
    package struct Need: Sendable, Equatable {
      package let result: String
      package let outputs: [String: String]

      package init(result: String, outputs: [String: String]) {
        self.result = result
        self.outputs = outputs
      }
    }

    package var repository: String
    package var sha: String
    package var ref: String
    package var actor: String
    package var runID: Int64
    package var runNumber: Int64
    package var runAttempt: Int64
    package var needs: [String: Need]
    package var vars: [String: String]
    package var inputs: JSONValue?

    package init(
      repository: String, sha: String, ref: String, actor: String = "iso-ci", runID: Int64,
      runNumber: Int64 = 1, runAttempt: Int64 = 1, needs: [String: Need] = [:],
      vars: [String: String] = [:], inputs: JSONValue? = nil
    ) {
      self.repository = repository
      self.sha = sha
      self.ref = ref
      self.actor = actor
      self.runID = runID
      self.runNumber = runNumber
      self.runAttempt = runAttempt
      self.needs = needs
      self.vars = vars
      self.inputs = inputs
    }
  }

  /// Builds the message. `secrets` values are delivered only as secret
  /// variables (masked by the runner); their names come from the plan.
  package static func build(
    plan: WorkflowPlan, job: JobPlan, attempt: JobAttemptID, run: PreflightRunID,
    contexts: Contexts, endpoint: Endpoint, secrets: [String: String],
    syntheticScripts: any SyntheticStepScripts, snapshot: Digest?
  ) throws(CIError) -> JSONValue {
    guard secrets.count <= maxSecrets else { throw CIError.invalid("too many secrets") }
    var secretBytes = 0
    for (name, value) in secrets {
      guard !reservedSecretNames.contains(name.uppercased()), isSecretName(name) else {
        throw CIError.invalid("secret name is invalid or reserved")
      }
      secretBytes += value.utf8.count
    }
    guard secretBytes <= maxSecretBytes else { throw CIError.invalid("secrets are too large") }

    let identity = Identity(attempt: attempt, run: run)
    var variables: [String: JSONValue] = [
      // A local placeholder GitHub token: masked, and accepted by no route.
      "system.github.token": variable("iso-ci-local-" + randomHex(bytes: 20), secret: true),
      "system.github.job": variable(job.jobID, secret: false),
      "system.github.results_endpoint": variable(endpoint.base, secret: false),
      "system.github.launch_endpoint": variable(endpoint.base, secret: false),
      "system.orchestrationId": variable(
        "\(identity.planID.uuidString.lowercased()).\(job.key).\(contexts.runAttempt)",
        secret: false),
      "system.runner.lowdiskspacethreshold": variable("100", secret: false),
    ]
    for (name, value) in secrets { variables[name] = variable(value, secret: true) }

    var steps: [JSONValue] = []
    for (index, step) in job.steps.enumerated() {
      steps.append(
        try stepJSON(
          step, index: index, attempt: attempt, endpoint: endpoint,
          syntheticScripts: syntheticScripts,
          snapshot: snapshot))
    }

    var environment: [JSONValue] = []
    if !plan.env.isEmpty { environment.append(token(.mapping(plan.env))) }
    if !job.env.isEmpty { environment.append(token(.mapping(job.env))) }

    var defaultsRun: [TemplateEntry] = []
    let shell = job.defaults.shell ?? plan.defaults.shell
    let directory = job.defaults.workingDirectory ?? plan.defaults.workingDirectory
    if let shell { defaultsRun.append(TemplateEntry(key: "shell", value: .string(shell))) }
    if let directory {
      defaultsRun.append(TemplateEntry(key: "working-directory", value: .string(directory)))
    }

    let systemConnection: JSONValue = [
      "name": "SystemVssConnection",
      "url": .string(endpoint.runService),
      "authorization": [
        "scheme": "OAuth", "parameters": ["AccessToken": .string(accessTokenPlaceholder)],
      ],
      "data": [
        "CacheServerUrl": .string(endpoint.cache),
        "ResultsServiceUrl": .string(endpoint.base),
      ],
      "isShared": false, "isReady": true,
    ]

    var message: [String: JSONValue] = [
      "messageType": .string(messageType),
      "plan": [
        "scopeIdentifier": "00000000-0000-0000-0000-000000000000", "planType": "actions",
        "version": 12, "planId": .string(identity.planID.uuidString.lowercased()),
        "planGroup": "", "definition": ["id": 0, "name": .string(plan.name)],
        "owner": ["id": 0, "name": .string(plan.name)],
      ],
      "timeline": ["id": .string(identity.timelineID.uuidString.lowercased()), "changeId": 1],
      "jobId": .string(identity.jobID.uuidString.lowercased()),
      "jobDisplayName": .string(job.displayName),
      "jobName": .string(job.jobID),
      "requestId": 1,
      "lockedUntil": "0001-01-01T00:00:00",
      "resources": ["endpoints": [systemConnection], "repositories": [], "containers": []],
      "contextData": .object(
        try contextData(plan: plan, job: job, contexts: contexts, endpoint: endpoint)),
      "workspace": [:],
      "variables": .object(variables),
      "steps": .array(steps),
      "fileTable": [.string(plan.workflowPath)],
      "mask": [],
    ]
    if !environment.isEmpty { message["environmentVariables"] = .array(environment) }
    if !defaultsRun.isEmpty {
      message["defaults"] = [
        token(.mapping([TemplateEntry(key: "run", value: .mapping(defaultsRun))]))
      ]
    }
    if let container = job.container { message["jobContainer"] = token(containerValue(container)) }
    if !job.services.isEmpty {
      let services = job.services.keys.sorted().map {
        TemplateEntry(key: $0, value: containerValue(job.services[$0]!))
      }
      message["jobServiceContainers"] = token(.mapping(services))
    }
    if !job.outputs.isEmpty { message["jobOutputs"] = token(.mapping(job.outputs)) }
    return .object(message)
  }

  static func variable(_ value: String, secret: Bool) -> JSONValue {
    ["value": .string(value), "isSecret": .bool(secret)]
  }

  /// Secret names as GitHub allows them: `[A-Za-z_][A-Za-z0-9_]*`.
  package static func isSecretName(_ name: String) -> Bool {
    guard (1...100).contains(name.utf8.count), let first = name.unicodeScalars.first,
      !("0"..."9").contains(first), !name.uppercased().hasPrefix("GITHUB_")
    else { return false }
    return name.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
    }
  }

  // MARK: Steps

  static func stepJSON(
    _ step: StepPlan, index: Int, attempt: JobAttemptID, endpoint: Endpoint,
    syntheticScripts: any SyntheticStepScripts, snapshot: Digest?
  ) throws(CIError) -> JSONValue {
    var json: [String: JSONValue] = [
      "type": "action",
      "id": .string(Identity.derived("\(attempt.rawValue)/step/\(index)").uuidString.lowercased()),
      "name": .string(step.contextName),
      "contextName": .string(step.contextName),
      "condition": .string(step.condition),
      "continueOnError": token(step.continueOnError),
    ]
    if let name = step.name { json["displayNameToken"] = token(name) }
    if let timeout = step.timeoutMinutes { json["timeoutInMinutes"] = token(timeout) }
    var env = step.env
    switch step.kind {
    case .run(let script, let shell, let directory):
      json["reference"] = ["type": "script"]
      var inputs = [TemplateEntry(key: "script", value: script)]
      if let shell { inputs.append(TemplateEntry(key: "shell", value: shell)) }
      if let directory { inputs.append(TemplateEntry(key: "workingDirectory", value: directory)) }
      json["inputs"] = token(.mapping(inputs))
    case .uses(.repository(let owner, let repository, let path, let ref), let with):
      json["reference"] = [
        "type": "repository", "name": .string("\(owner)/\(repository)"), "ref": .string(ref),
        "repositoryType": "GitHub", "path": .string(path ?? ""),
      ]
      if !with.isEmpty { json["inputs"] = token(.mapping(with)) }
    case .uses(.docker(let image), let with):
      json["reference"] = ["type": "containerRegistry", "image": .string(image)]
      if !with.isEmpty { json["inputs"] = token(.mapping(with)) }
    case .uses(.local(let path), let with):
      json["reference"] = ["type": "repository", "repositoryType": "self", "path": .string(path)]
      if !with.isEmpty { json["inputs"] = token(.mapping(with)) }
    case .syntheticCheckout, .snapshotOverlay:
      guard let script = syntheticScripts.script(for: step.kind, snapshot: snapshot) else {
        throw CIError(.compatibilityRejected, "no script is available for a synthetic step")
      }
      json["reference"] = ["type": "script"]
      json["inputs"] = token(
        .mapping([
          TemplateEntry(key: "script", value: .string(script)),
          // POSIX sh, so the step also runs in minimal job containers.
          TemplateEntry(key: "shell", value: .string("\(OverlayScripts.shell) -e {0}")),
        ]))
      if json["displayNameToken"] == nil {
        let label =
          if case .syntheticCheckout = step.kind {
            "iso-ci checkout (snapshot base commit)"
          } else {
            "iso-ci overlay (snapshot \(snapshot?.short ?? "none"))"
          }
        json["displayNameToken"] = .string(label)
      }
      env.append(TemplateEntry(key: "ISO_CI_ENDPOINT", value: .string(endpoint.base)))
      env.append(TemplateEntry(key: "ISO_CI_TOKEN", value: .expression("secrets.ISO_CI_TOKEN")))
      if let snapshot {
        env.append(TemplateEntry(key: "ISO_CI_SNAPSHOT", value: .string(snapshot.rawValue)))
      }
    }
    if !env.isEmpty { json["environment"] = token(.mapping(env)) }
    return .object(json)
  }

  static func containerValue(_ container: ContainerPlan) -> TemplateValue {
    var entries = [TemplateEntry(key: "image", value: container.image)]
    if !container.env.isEmpty {
      entries.append(TemplateEntry(key: "env", value: .mapping(container.env)))
    }
    if !container.ports.isEmpty {
      entries.append(TemplateEntry(key: "ports", value: .sequence(container.ports)))
    }
    if !container.volumes.isEmpty {
      entries.append(TemplateEntry(key: "volumes", value: .sequence(container.volumes)))
    }
    if let options = container.options {
      entries.append(TemplateEntry(key: "options", value: options))
    }
    return .mapping(entries)
  }

  // MARK: Template tokens and context data

  /// A `TemplateValue` in the runner's template-token JSON form.
  package static func token(_ value: TemplateValue) -> JSONValue {
    switch value {
    case .string(let text): return .string(text)
    case .expression(let expression): return ["type": 3, "expr": .string(expression)]
    case .bool(let flag): return .bool(flag)
    case .number(let number):
      if number.rounded() == number, abs(number) < 9e15 { return .integer(Int64(number)) }
      return .double(number)
    case .null: return .null
    case .sequence(let items):
      return items.isEmpty ? ["type": 1] : ["type": 1, "seq": .array(items.map(token))]
    case .mapping(let entries):
      if entries.isEmpty { return ["type": 2] }
      return [
        "type": 2,
        "map": .array(entries.map { ["Key": .string($0.key), "Value": token($0.value)] }),
      ]
    }
  }

  /// A JSON value in the runner's pipeline-context-data JSON form.
  package static func contextValue(_ value: JSONValue) -> JSONValue {
    switch value {
    case .null, .bool, .integer, .double, .string: return value
    case .array(let items): return ["t": 1, "a": .array(items.map(contextValue))]
    case .object(let members):
      let keys = members.keys.sorted()
      return [
        "t": 2, "d": .array(keys.map { ["k": .string($0), "v": contextValue(members[$0]!)] }),
      ]
    }
  }

  static func contextData(
    plan: WorkflowPlan, job: JobPlan, contexts: Contexts, endpoint: Endpoint
  ) throws(CIError) -> [String: JSONValue] {
    let owner = contexts.repository.split(separator: "/").first.map(String.init) ?? ""
    let refName =
      contexts.ref.split(separator: "/", maxSplits: 2).last.map(String.init) ?? contexts.ref
    let github: JSONValue = [
      "event_name": .string(plan.event), "event": plan.eventPayload,
      "repository": .string(contexts.repository), "repository_owner": .string(owner),
      "sha": .string(contexts.sha), "ref": .string(contexts.ref), "ref_name": .string(refName),
      "ref_type": .string(contexts.ref.hasPrefix("refs/tags/") ? "tag" : "branch"),
      "actor": .string(contexts.actor), "triggering_actor": .string(contexts.actor),
      "run_id": .string(String(contexts.runID)), "run_number": .string(String(contexts.runNumber)),
      "run_attempt": .string(String(contexts.runAttempt)), "workflow": .string(plan.name),
      "workflow_ref": .string("\(contexts.repository)/\(plan.workflowPath)@\(contexts.ref)"),
      "job": .string(job.jobID), "server_url": .string(endpoint.serverURL),
      "api_url": .string(endpoint.serverURL + "/api/v3"),
      "graphql_url": .string(endpoint.serverURL + "/api/graphql"), "retention_days": "1",
      "repositoryUrl": .string("\(endpoint.serverURL)/\(contexts.repository).git"),
    ]
    var needs: [String: JSONValue] = [:]
    for name in job.needsJobIDs {
      guard let need = contexts.needs[name] else {
        throw CIError.invalid("needs context for \(name) is missing")
      }
      needs[name] = [
        "result": .string(need.result),
        "outputs": .object(need.outputs.mapValues(JSONValue.string)),
      ]
    }
    let strategy: JSONValue = [
      "fail-fast": .bool(job.strategy.failFast),
      "job-index": .integer(Int64(job.strategy.jobIndex)),
      "job-total": .integer(Int64(job.strategy.jobTotal)),
      "max-parallel": .integer(Int64(job.strategy.maxParallel)),
    ]
    var data: [String: JSONValue] = [
      "github": contextValue(github), "needs": contextValue(.object(needs)),
      "strategy": contextValue(strategy),
      "vars": contextValue(.object(contexts.vars.mapValues(JSONValue.string))),
    ]
    data["matrix"] = job.matrix.map(contextValue) ?? .null
    data["inputs"] = contexts.inputs.map(contextValue) ?? .null
    return data
  }

  /// Replaces the access-token placeholder in a built message with `token`
  /// (structural replacement at the SystemVssConnection endpoint only).
  package static func withAccessToken(_ message: JSONValue, token: String) throws(CIError)
    -> JSONValue
  {
    guard case .object(var members) = message, case .object(var resources)? = members["resources"],
      case .array(var endpoints)? = resources["endpoints"]
    else { throw CIError.invalid("job message has no resources") }
    var replaced = false
    for index in endpoints.indices {
      guard case .object(var endpoint) = endpoints[index],
        endpoint["name"] == .string("SystemVssConnection"),
        case .object(var authorization)? = endpoint["authorization"],
        case .object(var parameters)? = authorization["parameters"],
        parameters["AccessToken"] == .string(accessTokenPlaceholder)
      else { continue }
      parameters["AccessToken"] = .string(token)
      authorization["parameters"] = .object(parameters)
      endpoint["authorization"] = .object(authorization)
      endpoints[index] = .object(endpoint)
      replaced = true
    }
    guard replaced else { throw CIError.invalid("job message has no access-token placeholder") }
    resources["endpoints"] = .array(endpoints)
    members["resources"] = .object(resources)
    return .object(members)
  }
}

/// Supplies the script text of the compiler's visible synthetic steps.
/// The compiler fork owns the scripts (snapshot materialization and
/// verification); the builder only places them in the message.
package protocol SyntheticStepScripts: Sendable {
  func script(for kind: StepKind, snapshot: Digest?) -> String?
}

/// Where the guest reaches its preflight endpoint. Job, service and action
/// containers cannot reach the guest's loopback, so an image with Docker
/// serves the endpoint on Docker's default gateway as well (a guest-internal
/// bridge to the same forward), and every URL the job sees names that.
package enum GuestEndpointHost: String, Sendable, Equatable, CaseIterable {
  case loopback = "127.0.0.1"
  case dockerGateway = "172.17.0.1"
}
