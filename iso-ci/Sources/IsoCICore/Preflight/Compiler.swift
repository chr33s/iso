import Foundation

/// The snapshot a plan's synthetic steps materialize (named in their
/// visible display names; the digest is what the overlay verifies).
package struct SnapshotReference: Sendable, Equatable, Hashable, Codable {
  package let baseCommit: String
  package let digest: Digest
  package let isDirty: Bool

  package init(baseCommit: String, digest: Digest, isDirty: Bool) {
    self.baseCommit = baseCommit
    self.digest = digest
    self.isDirty = isDirty
  }
}

/// A compile result with its non-fatal warnings and fatal diagnostics.
package struct CompileReport: Sendable, Equatable {
  package let plan: WorkflowPlan?
  package let diagnostics: [CompatibilityDiagnostic]
  package let warnings: [CompatibilityDiagnostic]
}

/// Compiles a workflow file into an immutable `WorkflowPlan`, validating
/// syntax, the declared expression subset, the compatibility manifest and
/// every statically decidable rule before any allocation (spec section 9).
/// Data-dependent failures are left to the first responsible boundary.
package enum WorkflowCompiler {
  package static let maxJobs = 256
  package static let maxStepsPerJob = 1_000
  package static let defaultTimeoutMinutes = 360
  package static let maxTimeoutMinutes = 4_320

  /// Compiles or throws `CIError(.compatibilityRejected)` whose details
  /// carry every diagnostic (`d001`, `d002`, …).
  package static func compile(
    source: Data, path: String, event: String, eventPayload: JSONValue = [:],
    manifest: CompatibilityManifest, platformMap: [String: String],
    inputs: [String: JSONValue] = [:], github: JSONValue = [:], vars: [String: String] = [:],
    snapshot: SnapshotReference? = nil
  ) throws(CIError) -> WorkflowPlan {
    let report = analyze(
      source: source, path: path, event: event, eventPayload: eventPayload, manifest: manifest,
      platformMap: platformMap, inputs: inputs, github: github, vars: vars, snapshot: snapshot)
    if let plan = report.plan, report.diagnostics.isEmpty { return plan }
    throw rejection(report.diagnostics)
  }

  package static func rejection(_ diagnostics: [CompatibilityDiagnostic]) -> CIError {
    var details: [String: String] = [:]
    for (index, diagnostic) in diagnostics.enumerated() {
      details[String(format: "d%03d", index + 1)] = diagnostic.description
    }
    let first = diagnostics.first?.description ?? "unknown problem"
    return CIError(
      .compatibilityRejected,
      "\(diagnostics.count) compatibility problem\(diagnostics.count == 1 ? "" : "s"); first: \(first)",
      details: details)
  }

  package static func analyze(
    source: Data, path: String, event: String, eventPayload: JSONValue = [:],
    manifest: CompatibilityManifest, platformMap: [String: String],
    inputs: [String: JSONValue] = [:], github: JSONValue = [:], vars: [String: String] = [:],
    snapshot: SnapshotReference? = nil
  ) -> CompileReport {
    var session = CompilerSession(
      source: source, path: path, event: event, eventPayload: eventPayload, manifest: manifest,
      platformMap: platformMap, inputs: inputs, github: github, vars: vars, snapshot: snapshot)
    let plan = session.run()
    let diagnostics = session.diagnostics.sorted { ($0.line, $0.path) < ($1.line, $1.path) }
    return CompileReport(
      plan: diagnostics.isEmpty ? plan : nil, diagnostics: diagnostics, warnings: session.warnings)
  }

  /// `runs-on` label set → platform, through the operator's explicit map
  /// only: one mapped label, exactly `self-hosted, linux, ARM64` (optionally
  /// plus mapped labels), or labels that all map to the same platform.
  package static func platform(for labels: [String], map: [String: String]) -> String? {
    let set = Set(labels.map { $0.lowercased() })
    guard !set.isEmpty else { return nil }
    let lowered = Dictionary(
      map.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    let base: Set<String> = ["self-hosted", "linux", "arm64"]
    if set.isSuperset(of: base), set.subtracting(base).allSatisfy({ lowered[$0] == "linux/arm64" })
    {
      return "linux/arm64"
    }
    let mapped = Set(set.compactMap { lowered[$0] })
    if set.allSatisfy({ lowered[$0] != nil }), mapped.count == 1, mapped.first == "linux/arm64" {
      return "linux/arm64"
    }
    return nil
  }
}

// MARK: - Session

private struct NotStatic: Error {}

private struct CompilerSession {
  let source: Data
  let path: String
  let event: String
  let eventPayload: JSONValue
  let manifest: CompatibilityManifest
  let platformMap: [String: String]
  let suppliedInputs: [String: JSONValue]
  let github: JSONValue
  let varsJSON: JSONValue
  let snapshot: SnapshotReference?
  var diagnostics: [CompatibilityDiagnostic] = []
  var warnings: [CompatibilityDiagnostic] = []
  var inputsJSON: JSONValue = [:]
  var workflowSecrets: Set<String> = []
  var actions: Set<ActionReference> = []
  var platformMappings: [String: String] = [:]

  init(
    source: Data, path: String, event: String, eventPayload: JSONValue,
    manifest: CompatibilityManifest, platformMap: [String: String], inputs: [String: JSONValue],
    github: JSONValue, vars: [String: String], snapshot: SnapshotReference?
  ) {
    self.source = source
    self.path = path
    self.event = event
    self.eventPayload = eventPayload
    self.manifest = manifest
    self.platformMap = platformMap
    suppliedInputs = inputs
    var context = github.objectValue ?? [:]
    if context["event_name"] == nil { context["event_name"] = .string(event) }
    if context["event"] == nil { context["event"] = eventPayload }
    self.github = .object(context)
    varsJSON = .object(vars.mapValues { .string($0) })
    self.snapshot = snapshot
  }

  mutating func report(_ line: Int, _ path: String, _ reason: String) {
    diagnostics.append(CompatibilityDiagnostic(line: line, path: path, reason: reason))
  }

  mutating func warn(_ line: Int, _ path: String, _ reason: String) {
    warnings.append(CompatibilityDiagnostic(line: line, path: path, reason: reason))
  }

  mutating func absorb(_ converter: TemplateConverter) { diagnostics += converter.diagnostics }

  static func isIdentifier(_ value: String) -> Bool {
    guard (1...100).contains(value.utf8.count), let first = value.unicodeScalars.first,
      ("a"..."z").contains(first) || ("A"..."Z").contains(first) || first == "_"
    else { return false }
    return value.unicodeScalars.allSatisfy {
      ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
        || $0 == "-"
    }
  }

  // MARK: Top level

  mutating func run() -> WorkflowPlan? {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
      path.utf8.count <= 512
    else {
      report(0, "workflow", "the workflow path must be repository-relative")
      return nil
    }
    let root: YAMLNode
    do { root = try YAML.parse(source) } catch {
      report(0, "workflow", error.message)
      return nil
    }
    guard let pairs = root.mapping else {
      report(root.line, "workflow", "a workflow must be a mapping")
      return nil
    }
    let allowed: Set<String> = [
      "name", "run-name", "on", "env", "defaults", "jobs", "permissions", "concurrency",
    ]
    for pair in pairs where !allowed.contains(pair.key.value) {
      report(pair.key.line, pair.key.value, "unknown or unsupported workflow key")
    }
    var name = path
    if let node = root["name"] {
      if let scalar = node.scalar, !scalar.isNull {
        name = scalar.value
      } else {
        report(node.line, "name", "must be a string")
      }
    }
    if let node = root["run-name"] {
      var converter = TemplateConverter()
      _ = converter.value(node, field: .runName, path: "run-name")
      absorb(converter)
    }
    checkTrigger(root["on"], line: root.line)
    if let node = root["permissions"] { checkPermissions(node, path: "permissions") }
    if let node = root["concurrency"] {
      warn(
        node.line, "concurrency",
        "ignored: local preflight runs are not grouped or cancelled by concurrency")
    }
    var converter = TemplateConverter()
    let env = root["env"].map { converter.entries($0, field: .workflowEnv, path: "env") } ?? []
    workflowSecrets = converter.secretNames
    absorb(converter)
    let defaults = workflowDefaults(root["defaults"])
    guard let jobsNode = root["jobs"] else {
      report(root.line, "jobs", "a workflow needs jobs")
      return nil
    }
    let jobs = compileJobs(jobsNode, workflowDefaults: defaults)
    guard diagnostics.isEmpty else { return nil }
    return WorkflowPlan(
      name: name, workflowPath: path, workflowDigest: Digest(hashing: source), event: event,
      eventPayload: eventPayload, env: env, defaults: defaults, jobs: jobs,
      manifestID: manifest.id, manifestDigest: manifest.digest,
      actions: actions.sorted { $0.displayName < $1.displayName },
      platformMappings: platformMappings)
  }

  mutating func checkTrigger(_ node: YAMLNode?, line: Int) {
    guard let node else {
      report(line, "on", "a workflow needs an 'on' trigger")
      return
    }
    var events: [String: YAMLNode] = [:]
    switch node {
    case .scalar(let scalar):
      events[scalar.value] = .scalar(YAMLScalar(value: "", style: .plain, line: scalar.line))
    case .sequence(let items, _):
      for item in items {
        if let scalar = item.scalar {
          events[scalar.value] = .scalar(YAMLScalar(value: "", style: .plain, line: scalar.line))
        }
      }
    case .mapping(let pairs, _):
      for pair in pairs { events[pair.key.value] = pair.value }
    }
    if event == "workflow_call" {
      report(
        node.line, "on.workflow_call", "reusable workflows are not supported in local preflight")
    }
    guard let configuration = events[event] else {
      report(node.line, "on", "the workflow does not run on the '\(event)' event")
      return
    }
    var inputs: [String: JSONValue] = [:]
    let declared = event == "workflow_dispatch" ? configuration["inputs"]?.mapping ?? [] : []
    var declaredNames: Set<String> = []
    for pair in declared {
      let name = pair.key.value
      declaredNames.insert(name)
      let path = "on.workflow_dispatch.inputs.\(name)"
      let type = pair.value["type"]?.scalar?.value ?? "string"
      let required = pair.value["required"]?.scalar?.bool ?? false
      let defaultValue = pair.value["default"]?.scalar
      if type == "environment" {
        report(
          pair.key.line, path,
          "environment inputs are not supported (approval authority cannot be forged)")
        continue
      }
      guard ["string", "boolean", "choice", "number"].contains(type) else {
        report(pair.key.line, path, "unsupported input type '\(type)'")
        continue
      }
      var value: JSONValue? = suppliedInputs[name]
      if value == nil, let defaultValue { value = defaultValue.resolved }
      guard var resolved = value else {
        if required { report(pair.key.line, path, "required input was not supplied") }
        inputs[name] = type == "boolean" ? .bool(false) : .string("")
        continue
      }
      switch type {
      case "boolean":
        if case .string(let text) = resolved { resolved = .bool(text.lowercased() == "true") }
        guard case .bool = resolved else {
          report(pair.key.line, path, "boolean input needs true or false")
          continue
        }
      case "number":
        let number = ExpressionEvaluator.toNumber(resolved)
        guard number.isFinite else {
          report(pair.key.line, path, "number input is not a number")
          continue
        }
        resolved = numberValue(number)
      case "choice":
        let options = pair.value["options"]?.sequence?.compactMap(\.scalar?.value) ?? []
        let text = ExpressionEvaluator.toText(resolved)
        guard options.contains(text) else {
          report(pair.key.line, path, "choice input is not one of its options")
          continue
        }
        resolved = .string(text)
      default:
        resolved = .string(ExpressionEvaluator.toText(resolved))
      }
      inputs[name] = resolved
    }
    for name in suppliedInputs.keys.sorted() where !declaredNames.contains(name) {
      report(node.line, "inputs.\(name)", "the workflow declares no such input")
    }
    inputsJSON = .object(inputs)
  }

  mutating func checkPermissions(_ node: YAMLNode, path: String) {
    if let scalar = node.scalar {
      switch scalar.value {
      case "read-all", "": break
      case "write-all":
        report(
          node.line, path,
          "write-all includes id-token: write; OIDC tokens cannot be issued by local preflight")
      default:
        report(node.line, path, "unknown permissions value")
      }
      return
    }
    guard let pairs = node.mapping else {
      report(node.line, path, "permissions must be a mapping or read-all")
      return
    }
    for pair in pairs {
      let value = pair.value.scalar?.value ?? ""
      guard ["read", "write", "none"].contains(value) else {
        report(pair.key.line, "\(path).\(pair.key.value)", "permission must be read, write or none")
        continue
      }
      if pair.key.value == "id-token" && value == "write" {
        report(pair.key.line, "\(path).id-token", "OIDC tokens cannot be issued by local preflight")
      }
    }
  }

  mutating func workflowDefaults(_ node: YAMLNode?) -> RunDefaults {
    guard let node, !node.isNull else { return RunDefaults(shell: nil, workingDirectory: nil) }
    guard let pairs = node.mapping else {
      report(node.line, "defaults", "must be a mapping")
      return RunDefaults(shell: nil, workingDirectory: nil)
    }
    for pair in pairs where pair.key.value != "run" {
      report(pair.key.line, "defaults.\(pair.key.value)", "unsupported defaults key")
    }
    guard let run = node["run"] else { return RunDefaults(shell: nil, workingDirectory: nil) }
    var shell: String?
    var directory: String?
    for pair in run.mapping ?? [] {
      let value = pair.value.scalar?.value
      if value?.contains("${{") == true {
        report(
          pair.key.line, "defaults.run.\(pair.key.value)",
          "workflow defaults cannot use expressions")
      }
      switch pair.key.value {
      case "shell": shell = value
      case "working-directory": directory = value
      default:
        report(pair.key.line, "defaults.run.\(pair.key.value)", "unsupported defaults.run key")
      }
    }
    if let shell { checkShell(shell, line: run.line, path: "defaults.run.shell") }
    return RunDefaults(shell: shell, workingDirectory: directory)
  }

  mutating func checkShell(_ shell: String, line: Int, path: String) {
    let program = shell.split(separator: " ").first.map(String.init) ?? ""
    if ["cmd", "powershell"].contains(program.lowercased()) {
      report(line, path, "\(program) is a Windows shell; the preflight target is linux/arm64")
    }
  }

  // MARK: Jobs

  struct ParsedJob {
    let id: String
    let node: YAMLNode
    let line: Int
    var needs: [String]
  }

  mutating func compileJobs(_ node: YAMLNode, workflowDefaults: RunDefaults) -> [JobPlan] {
    guard let pairs = node.mapping, !pairs.isEmpty else {
      report(node.line, "jobs", "jobs must be a non-empty mapping")
      return []
    }
    var parsed: [ParsedJob] = []
    for pair in pairs {
      let id = pair.key.value
      guard Self.isIdentifier(id) else {
        report(pair.key.line, "jobs.\(id)", "invalid job id")
        continue
      }
      guard pair.value.mapping != nil else {
        report(pair.value.line, "jobs.\(id)", "a job must be a mapping")
        continue
      }
      var needs: [String] = []
      if let needsNode = pair.value["needs"] {
        if let scalar = needsNode.scalar {
          needs = [scalar.value]
        } else if let items = needsNode.sequence {
          needs = items.compactMap(\.scalar?.value)
        } else {
          report(needsNode.line, "jobs.\(id).needs", "needs must be a job id or a list of job ids")
        }
      }
      parsed.append(ParsedJob(id: id, node: pair.value, line: pair.key.line, needs: needs))
    }
    let ids = Set(parsed.map(\.id))
    for job in parsed {
      for need in job.needs where !ids.contains(need) || need == job.id {
        report(job.line, "jobs.\(job.id).needs", "unknown or self-referencing job '\(need)'")
      }
      if Set(job.needs).count != job.needs.count {
        report(job.line, "jobs.\(job.id).needs", "duplicate needs entries")
      }
    }
    guard let order = topologicalOrder(parsed) else {
      report(node.line, "jobs", "the needs graph has a cycle")
      return []
    }
    var expandedKeys: [String: [String]] = [:]
    var plans: [JobPlan] = []
    for job in order {
      let legs = compileJob(job, expandedKeys: expandedKeys, workflowDefaults: workflowDefaults)
      expandedKeys[job.id] = legs.map(\.key)
      plans += legs
      if plans.count > WorkflowCompiler.maxJobs {
        report(
          job.line, "jobs", "more than \(WorkflowCompiler.maxJobs) jobs after matrix expansion")
        return []
      }
    }
    return plans
  }

  /// Kahn's algorithm, ties broken by definition order.
  func topologicalOrder(_ jobs: [ParsedJob]) -> [ParsedJob]? {
    var remaining = jobs
    var done: Set<String> = []
    var out: [ParsedJob] = []
    while !remaining.isEmpty {
      guard let index = remaining.firstIndex(where: { $0.needs.allSatisfy(done.contains) }) else {
        return nil
      }
      let job = remaining.remove(at: index)
      done.insert(job.id)
      out.append(job)
    }
    return out
  }

  static let jobKeys: Set<String> = [
    "name", "needs", "runs-on", "if", "env", "defaults", "timeout-minutes", "continue-on-error",
    "strategy", "container", "services", "steps", "outputs", "permissions", "concurrency",
  ]

  mutating func compileJob(
    _ job: ParsedJob, expandedKeys: [String: [String]], workflowDefaults: RunDefaults
  ) -> [JobPlan] {
    let base = "jobs.\(job.id)"
    let pairs = job.node.mapping ?? []
    for pair in pairs where !Self.jobKeys.contains(pair.key.value) {
      let reason: String
      switch pair.key.value {
      case "uses", "with", "secrets":
        reason = "reusable workflows are not supported in local preflight"
      case "environment":
        reason = "environments are not supported: approval authority cannot be forged locally"
      default: reason = "unknown or unsupported job key"
      }
      report(pair.key.line, "\(base).\(pair.key.value)", reason)
    }
    // A reusable-workflow call has no runs-on or steps of its own; its
    // refusal above is the only diagnostic it needs.
    if job.node["uses"] != nil { return [] }
    if let node = job.node["permissions"] { checkPermissions(node, path: "\(base).permissions") }
    if let node = job.node["concurrency"] {
      warn(
        node.line, "\(base).concurrency",
        "ignored: local preflight runs are not grouped by concurrency")
    }
    var converter = TemplateConverter()
    converter.secretNames = workflowSecrets
    let condition = converter.condition(job.node["if"], field: .jobIf, path: "\(base).if")
    let env =
      job.node["env"].map { converter.entries($0, field: .jobEnv, path: "\(base).env") } ?? []
    let outputs =
      job.node["outputs"].map {
        converter.entries($0, field: .jobOutputs, path: "\(base).outputs")
      } ?? []
    let nameValue = job.node["name"].map {
      converter.value($0, field: .jobName, path: "\(base).name")
    }
    let runsOnValue = runsOn(job.node["runs-on"], base: base, converter: &converter, line: job.line)
    let timeoutValue = job.node["timeout-minutes"].map {
      converter.value($0, field: .jobTimeout, path: "\(base).timeout-minutes")
    }
    let continueValue = job.node["continue-on-error"].map {
      converter.value($0, field: .jobContinueOnError, path: "\(base).continue-on-error")
    }
    var defaultsShell: TemplateValue?
    var defaultsDirectory: TemplateValue?
    if let defaults = job.node["defaults"] {
      for pair in defaults.mapping ?? [] where pair.key.value != "run" {
        report(pair.key.line, "\(base).defaults.\(pair.key.value)", "unsupported defaults key")
      }
      for pair in defaults["run"]?.mapping ?? [] {
        let value = converter.value(
          pair.value, field: .jobDefaultsRun, path: "\(base).defaults.run.\(pair.key.value)")
        switch pair.key.value {
        case "shell": defaultsShell = value
        case "working-directory": defaultsDirectory = value
        default:
          report(
            pair.key.line, "\(base).defaults.run.\(pair.key.value)", "unsupported defaults.run key")
        }
      }
    }
    let container = job.node["container"].flatMap {
      containerPlan($0, path: "\(base).container", converter: &converter, isService: false)
    }
    var services: [String: ContainerPlan] = [:]
    if let node = job.node["services"] {
      if !manifest.allowsServiceContainers {
        report(
          node.line, "\(base).services", "service containers are not in the compatibility manifest")
      }
      for pair in node.mapping ?? [] {
        guard Self.isIdentifier(pair.key.value) else {
          report(pair.key.line, "\(base).services.\(pair.key.value)", "invalid service id")
          continue
        }
        if let plan = containerPlan(
          pair.value, path: "\(base).services.\(pair.key.value)", converter: &converter,
          isService: true)
        {
          services[pair.key.value] = plan
        }
      }
    }
    if container != nil && !manifest.allowsJobContainers {
      report(job.line, "\(base).container", "job containers are not in the compatibility manifest")
    }
    let steps = compileSteps(job.node["steps"], base: base, converter: &converter, line: job.line)
    let secrets = converter.secretNames.sorted()
    absorb(converter)
    let matrix = expandMatrix(job.node["strategy"], base: base)
    var legs: [JobPlan] = []
    for (index, combination) in matrix.combinations.enumerated() {
      let matrixJSON: JSONValue? =
        matrix.isMatrix
        ? .object(Dictionary(combination.map { ($0.0, $0.1) }, uniquingKeysWith: { _, b in b }))
        : nil
      let strategy = StrategyContext(
        failFast: matrix.failFast, jobIndex: index, jobTotal: matrix.combinations.count,
        maxParallel: matrix.maxParallel)
      let contexts = ExpressionContexts(
        github: github, vars: varsJSON,
        strategy: [
          "fail-fast": .bool(strategy.failFast), "job-index": .integer(Int64(index)),
          "job-total": .integer(Int64(strategy.jobTotal)),
          "max-parallel": .integer(Int64(strategy.maxParallel)),
        ], matrix: matrixJSON ?? [:], inputs: inputsJSON)
      let key: String
      var displayName: String
      if let matrixJSON {
        key = "\(job.id)-\(Digest(hashing: matrixJSON.canonical).short)"
        displayName =
          "\(job.id) (\(combination.map { ExpressionEvaluator.toText($0.1) }.joined(separator: ", ")))"
      } else {
        key = job.id
        displayName = job.id
      }
      if let nameValue, let evaluated = try? staticEval(nameValue, contexts) {
        displayName = ExpressionEvaluator.toText(evaluated)
      }
      var labels: [String] = []
      if let runsOnValue {
        do {
          labels = flattenLabels(try staticEval(runsOnValue, contexts))
        } catch {
          report(job.line, "\(base).runs-on", "runs-on is not statically decidable")
        }
      }
      var platform = ""
      if runsOnValue != nil, !labels.isEmpty {
        if let mapped = WorkflowCompiler.platform(for: labels, map: platformMap) {
          platform = mapped
          platformMappings[labels.map { $0.lowercased() }.sorted().joined(separator: ",")] = mapped
        } else {
          report(
            job.line, "\(base).runs-on",
            "runs-on [\(labels.joined(separator: ", "))] has no operator-approved mapping to linux/arm64; ARM64 preflight is not equivalent to hosted x86 or macOS runners"
          )
        }
      }
      var timeout = WorkflowCompiler.defaultTimeoutMinutes
      if let timeoutValue {
        if let value = try? staticEval(timeoutValue, contexts) {
          let number = ExpressionEvaluator.toNumber(value)
          if number.isFinite, number >= 1, number <= Double(WorkflowCompiler.maxTimeoutMinutes) {
            timeout = Int(number.rounded(.up))
          } else {
            report(
              job.line, "\(base).timeout-minutes",
              "timeout-minutes must be 1-\(WorkflowCompiler.maxTimeoutMinutes)")
          }
        } else {
          report(job.line, "\(base).timeout-minutes", "timeout-minutes is not statically decidable")
        }
      }
      var continueOnError = false
      if let continueValue {
        if let value = try? staticEval(continueValue, contexts) {
          continueOnError = ExpressionEvaluator.truthy(value)
        } else {
          report(
            job.line, "\(base).continue-on-error", "continue-on-error is not statically decidable")
        }
      }
      var shell = workflowDefaults.shell
      var directory = workflowDefaults.workingDirectory
      if let defaultsShell {
        if let value = try? staticEval(defaultsShell, contexts) {
          shell = ExpressionEvaluator.toText(value)
          checkShell(shell ?? "", line: job.line, path: "\(base).defaults.run.shell")
        } else {
          report(
            job.line, "\(base).defaults.run.shell", "defaults.run.shell is not statically decidable"
          )
        }
      }
      if let defaultsDirectory {
        if let value = try? staticEval(defaultsDirectory, contexts) {
          directory = ExpressionEvaluator.toText(value)
        } else {
          report(
            job.line, "\(base).defaults.run.working-directory",
            "defaults.run.working-directory is not statically decidable")
        }
      }
      let needs = job.needs.flatMap { expandedKeys[$0] ?? [] }
      legs.append(
        JobPlan(
          key: key, jobID: job.id, displayName: displayName, needs: needs, needsJobIDs: job.needs,
          condition: condition, runsOn: labels, platform: platform, matrix: matrixJSON,
          strategy: strategy, env: env,
          defaults: RunDefaults(shell: shell, workingDirectory: directory),
          timeoutMinutes: timeout, continueOnError: continueOnError, container: container,
          services: services, steps: steps, outputs: outputs, secretNames: secrets))
    }
    return legs
  }

  /// Evaluates a template statically; throws when it reads data only known
  /// at run time (needs, steps, …) or fails to evaluate.
  func staticEval(_ value: TemplateValue, _ contexts: ExpressionContexts) throws -> JSONValue {
    switch value {
    case .string(let text): return .string(text)
    case .bool(let flag): return .bool(flag)
    case .number(let number): return numberValue(number)
    case .null: return .null
    case .sequence(let items): return .array(try items.map { try staticEval($0, contexts) })
    case .mapping(let entries):
      var out: [String: JSONValue] = [:]
      for entry in entries { out[entry.key] = try staticEval(entry.value, contexts) }
      return .object(out)
    case .expression(let text):
      let node = try Expression.parse(text)
      let runtime: Set<String> = ["needs", "steps", "job", "jobs", "runner", "env", "secrets"]
      guard node.contexts.isDisjoint(with: runtime) else { throw NotStatic() }
      return try ExpressionEvaluator.evaluate(node, contexts)
    }
  }

  func flattenLabels(_ value: JSONValue) -> [String] {
    switch value {
    case .array(let items): items.flatMap(flattenLabels)
    case .null: []
    default:
      ExpressionEvaluator.toText(value).isEmpty ? [] : [ExpressionEvaluator.toText(value)]
    }
  }

  mutating func runsOn(
    _ node: YAMLNode?, base: String, converter: inout TemplateConverter, line: Int
  )
    -> TemplateValue?
  {
    guard let node, !node.isNull else {
      report(line, "\(base).runs-on", "a job needs runs-on")
      return nil
    }
    if let pairs = node.mapping {
      for pair in pairs where pair.key.value != "labels" {
        let reason =
          pair.key.value == "group"
          ? "runner groups are not supported in local preflight" : "unsupported runs-on key"
        report(pair.key.line, "\(base).runs-on.\(pair.key.value)", reason)
      }
      guard let labels = node["labels"] else {
        report(node.line, "\(base).runs-on", "runs-on needs labels")
        return nil
      }
      return converter.value(labels, field: .jobRunsOn, path: "\(base).runs-on.labels")
    }
    return converter.value(node, field: .jobRunsOn, path: "\(base).runs-on")
  }

  mutating func containerPlan(
    _ node: YAMLNode, path: String, converter: inout TemplateConverter, isService: Bool
  ) -> ContainerPlan? {
    if let scalar = node.scalar {
      return ContainerPlan(
        image: converter.scalar(scalar, field: .jobContainer, path: "\(path).image"), env: [],
        ports: [], volumes: [], options: nil)
    }
    guard node.mapping != nil else {
      report(node.line, path, "a container must be an image or a mapping")
      return nil
    }
    let allowed: Set<String> = ["image", "env", "ports", "volumes", "options", "credentials"]
    for pair in node.mapping ?? [] where !allowed.contains(pair.key.value) {
      report(pair.key.line, "\(path).\(pair.key.value)", "unknown container key")
    }
    if let credentials = node["credentials"] {
      report(
        credentials.line, "\(path).credentials",
        "registry credentials are not supported in local preflight")
    }
    guard let image = node["image"] else {
      report(node.line, "\(path).image", "a container needs an image")
      return nil
    }
    let env =
      node["env"].map { converter.entries($0, field: .jobContainerEnv, path: "\(path).env") } ?? []
    func list(_ key: String) -> [TemplateValue] {
      guard let value = node[key] else { return [] }
      guard let items = value.sequence else {
        report(value.line, "\(path).\(key)", "must be a list")
        return []
      }
      return items.enumerated().map {
        converter.value($0.element, field: .jobContainer, path: "\(path).\(key)[\($0.offset)]")
      }
    }
    let ports = list("ports")
    let volumes = list("volumes")
    let options = node["options"].map {
      converter.value($0, field: .jobContainer, path: "\(path).options")
    }
    return ContainerPlan(
      image: converter.value(image, field: .jobContainer, path: "\(path).image"), env: env,
      ports: ports, volumes: volumes, options: options)
  }

  // MARK: Matrix

  struct Matrix {
    var isMatrix = false
    var combinations: [[(String, JSONValue)]] = [[]]
    var failFast = true
    var maxParallel = 0
  }

  static func containsExpression(_ node: YAMLNode) -> Bool {
    switch node {
    case .scalar(let scalar): scalar.value.contains("${{")
    case .sequence(let items, _): items.contains(where: containsExpression)
    case .mapping(let pairs, _):
      pairs.contains { $0.key.value.contains("${{") || containsExpression($0.value) }
    }
  }

  mutating func expandMatrix(_ node: YAMLNode?, base: String) -> Matrix {
    var result = Matrix()
    guard let node, !node.isNull else { return result }
    let path = "\(base).strategy"
    if Self.containsExpression(node) {
      report(
        node.line, path,
        "dynamic strategies and matrices (${{ }}) are not supported; use a static matrix")
      return result
    }
    guard let pairs = node.mapping else {
      report(node.line, path, "strategy must be a mapping")
      return result
    }
    for pair in pairs {
      switch pair.key.value {
      case "fail-fast":
        guard let flag = pair.value.scalar?.bool else {
          report(pair.value.line, "\(path).fail-fast", "must be true or false")
          continue
        }
        result.failFast = flag
      case "max-parallel":
        guard let number = pair.value.scalar?.int, number >= 1, number <= 256 else {
          report(pair.value.line, "\(path).max-parallel", "must be an integer from 1 to 256")
          continue
        }
        result.maxParallel = Int(number)
      case "matrix": break
      default: report(pair.key.line, "\(path).\(pair.key.value)", "unknown strategy key")
      }
    }
    guard let matrix = node["matrix"] else { return result }
    guard let dimensions = matrix.mapping else {
      report(matrix.line, "\(path).matrix", "matrix must be a mapping")
      return result
    }
    result.isMatrix = true
    var originalKeys: [String] = []
    var combinations: [[(String, JSONValue)]] = [[]]
    var includes: [[(String, JSONValue)]] = []
    var excludes: [[(String, JSONValue)]] = []
    func entries(_ node: YAMLNode, _ location: String) -> [[(String, JSONValue)]]? {
      guard let items = node.sequence else {
        report(node.line, location, "must be a list of mappings")
        return nil
      }
      var out: [[(String, JSONValue)]] = []
      for item in items {
        guard let pairs = item.mapping else {
          report(item.line, location, "entries must be mappings")
          continue
        }
        out.append(pairs.map { ($0.key.value, $0.value.json) })
      }
      return out
    }
    for pair in dimensions {
      switch pair.key.value {
      case "include": includes = entries(pair.value, "\(path).matrix.include") ?? []
      case "exclude": excludes = entries(pair.value, "\(path).matrix.exclude") ?? []
      default:
        guard let values = pair.value.sequence, !values.isEmpty else {
          report(
            pair.value.line, "\(path).matrix.\(pair.key.value)",
            "a matrix dimension must be a non-empty list")
          continue
        }
        originalKeys.append(pair.key.value)
        let size = combinations.count * values.count
        guard size <= WorkflowCompiler.maxJobs else {
          report(
            matrix.line, "\(path).matrix",
            "the matrix expands to more than \(WorkflowCompiler.maxJobs) jobs")
          return result
        }
        var next: [[(String, JSONValue)]] = []
        for combination in combinations {
          for value in values { next.append(combination + [(pair.key.value, value.json)]) }
        }
        combinations = next
      }
    }
    if originalKeys.isEmpty { combinations = [] }
    func value(_ combination: [(String, JSONValue)], _ key: String) -> JSONValue? {
      combination.last { $0.0 == key }?.1
    }
    combinations.removeAll { combination in
      excludes.contains { exclude in
        exclude.allSatisfy { entry in value(combination, entry.0).map { $0 == entry.1 } ?? false }
      }
    }
    for include in includes {
      var matched = false
      for index in combinations.indices {
        let original = include.filter { originalKeys.contains($0.0) }
        guard !originalKeys.isEmpty,
          original.allSatisfy({ entry in value(combinations[index], entry.0) == entry.1 })
        else { continue }
        matched = true
        for entry in include where !originalKeys.contains(entry.0) {
          if let position = combinations[index].firstIndex(where: { $0.0 == entry.0 }) {
            combinations[index][position].1 = entry.1
          } else {
            combinations[index].append(entry)
          }
        }
      }
      if !matched { combinations.append(include) }
    }
    if combinations.isEmpty {
      report(matrix.line, "\(path).matrix", "the matrix produces no jobs")
      combinations = [[]]
    }
    if combinations.count > WorkflowCompiler.maxJobs {
      report(
        matrix.line, "\(path).matrix",
        "the matrix expands to more than \(WorkflowCompiler.maxJobs) jobs")
      combinations = Array(combinations.prefix(1))
    }
    result.combinations = combinations
    if result.maxParallel == 0 { result.maxParallel = combinations.count }
    return result
  }

  // MARK: Steps

  static let stepKeys: Set<String> = [
    "id", "name", "if", "uses", "run", "shell", "with", "env", "working-directory",
    "continue-on-error", "timeout-minutes",
  ]

  mutating func compileSteps(
    _ node: YAMLNode?, base: String, converter: inout TemplateConverter, line: Int
  ) -> [StepPlan] {
    guard let node, let items = node.sequence, !items.isEmpty else {
      report(node?.line ?? line, "\(base).steps", "a job needs a non-empty steps list")
      return []
    }
    guard items.count <= WorkflowCompiler.maxStepsPerJob else {
      report(node.line, "\(base).steps", "more than \(WorkflowCompiler.maxStepsPerJob) steps")
      return []
    }
    var steps: [StepPlan] = []
    var ids: Set<String> = []
    var generated: [String: Int] = [:]
    var checkoutCount = 0
    // With an approved checkout, the overlay follows it; without one, the
    // snapshot is materialized before the first user step.
    let hasCheckout = items.contains { item in
      guard let text = item["uses"]?.scalar?.value,
        let approved = manifest.approvedAction(String(text.split(separator: "@").first ?? ""))
      else { return false }
      return approved.kind == .checkoutReplacement
    }
    var overlayInserted = hasCheckout
    for (index, item) in items.enumerated() {
      let path = "\(base).steps[\(index)]"
      guard let pairs = item.mapping else {
        report(item.line, path, "a step must be a mapping")
        continue
      }
      for pair in pairs where !Self.stepKeys.contains(pair.key.value) {
        report(pair.key.line, "\(path).\(pair.key.value)", "unknown or unsupported step key")
      }
      let uses = item["uses"]
      let run = item["run"]
      guard (uses == nil) != (run == nil) else {
        report(item.line, path, "a step needs exactly one of uses or run")
        continue
      }
      var contextName: String
      if let idNode = item["id"] {
        let id = idNode.scalar?.value ?? ""
        if !Self.isIdentifier(id) || id.hasPrefix("__") {
          report(idNode.line, "\(path).id", "invalid step id")
        }
        if !ids.insert(id).inserted { report(idNode.line, "\(path).id", "duplicate step id") }
        contextName = id
      } else {
        var stem = "__run"
        if let scalar = uses?.scalar {
          stem =
            "__"
            + scalar.value.split(separator: "@").first.map(String.init)!
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        }
        let count = (generated[stem] ?? 0) + 1
        generated[stem] = count
        contextName = count == 1 ? stem : "\(stem)_\(count)"
      }
      let name = item["name"].map { converter.value($0, field: .stepField, path: "\(path).name") }
      let condition = converter.condition(item["if"], field: .stepIf, path: "\(path).if")
      let env =
        item["env"].map { converter.entries($0, field: .stepField, path: "\(path).env") } ?? []
      let continueOnError =
        item["continue-on-error"].map {
          converter.value($0, field: .stepField, path: "\(path).continue-on-error")
        } ?? .bool(false)
      let timeout = item["timeout-minutes"].map {
        converter.value($0, field: .stepField, path: "\(path).timeout-minutes")
      }
      if let run {
        guard let scalar = run.scalar else {
          report(run.line, "\(path).run", "run must be a string")
          continue
        }
        for key in ["with"] where item[key] != nil {
          report(item.line, "\(path).\(key)", "with applies only to uses steps")
        }
        let shell = item["shell"].map {
          converter.value($0, field: .stepField, path: "\(path).shell")
        }
        if case .string(let text)? = shell {
          checkShell(text, line: item.line, path: "\(path).shell")
        }
        let directory = item["working-directory"].map {
          converter.value($0, field: .stepField, path: "\(path).working-directory")
        }
        let script = converter.string(
          scalar.value, field: .stepField, line: scalar.line, path: "\(path).run")
        if !overlayInserted {
          steps.append(overlayStep(path: ".", condition: "success()"))
          overlayInserted = true
        }
        steps.append(
          StepPlan(
            contextName: contextName, name: name,
            kind: .run(script: script, shell: shell, workingDirectory: directory), env: env,
            condition: condition, continueOnError: continueOnError, timeoutMinutes: timeout,
            synthetic: false))
        continue
      }
      for key in ["shell", "working-directory"] where item[key] != nil {
        report(item.line, "\(path).\(key)", "\(key) applies only to run steps")
      }
      guard let usesNode = uses, let text = usesNode.scalar?.value, !text.isEmpty else {
        report(item.line, "\(path).uses", "uses must be a string")
        continue
      }
      if text.contains("${{") {
        report(usesNode.line, "\(path).uses", "uses cannot contain expressions")
        continue
      }
      guard let reference = parseReference(text, line: usesNode.line, path: "\(path).uses") else {
        continue
      }
      let with =
        item["with"].map { converter.entries($0, field: .stepField, path: "\(path).with") } ?? []
      if case .repository(let owner, let repository, _, _) = reference,
        let approved = manifest.approvedAction("\(owner)/\(repository)")
      {
        let names = Set(with.map(\.key))
        for input in approved.rejectedInputs where names.contains(input) {
          report(
            item.line, "\(path).with.\(input)",
            "input '\(input)' of \(approved.nameWithOwner) is outside the local preflight subset")
        }
        for input in names.subtracting(approved.inputs).subtracting(approved.rejectedInputs)
          .sorted()
        {
          warn(
            item.line, "\(path).with.\(input)",
            "unexpected input '\(input)' for \(approved.nameWithOwner)")
        }
        if approved.kind == .checkoutReplacement {
          checkoutCount += 1
          if checkoutCount > 1 {
            report(
              item.line, path,
              "multiple checkouts are not supported (single-workspace checkout only)")
            continue
          }
          let checkoutPath = checkCheckout(with, line: item.line, path: path)
          steps.append(
            StepPlan(
              contextName: contextName, name: .string(checkoutName),
              kind: .syntheticCheckout(path: checkoutPath), env: [], condition: condition,
              continueOnError: .bool(false), timeoutMinutes: timeout, synthetic: true))
          steps.append(overlayStep(path: checkoutPath, condition: condition))
          overlayInserted = true
          continue
        }
        actions.insert(reference)
      } else if case .repository = reference {
        actions.insert(reference)
      }
      if !overlayInserted {
        steps.append(overlayStep(path: ".", condition: "success()"))
        overlayInserted = true
      }
      steps.append(
        StepPlan(
          contextName: contextName, name: name, kind: .uses(reference, with: with), env: env,
          condition: condition, continueOnError: continueOnError, timeoutMinutes: timeout,
          synthetic: false))
    }
    return steps
  }

  var checkoutName: String {
    "iso-ci checkout (synthetic; base \(snapshot.map { String($0.baseCommit.prefix(12)) } ?? "pending"))"
  }

  func overlayStep(path: String, condition: String) -> StepPlan {
    let state = snapshot.map { $0.isDirty ? "dirty working tree" : "clean tree" } ?? "pending"
    let digest = snapshot.map { $0.digest.prefixed } ?? "pending"
    return StepPlan(
      contextName: "__iso_ci_overlay",
      name: .string("iso-ci overlay (synthetic; snapshot \(digest), \(state))"),
      kind: .snapshotOverlay(path: path), env: [], condition: condition,
      continueOnError: .bool(false), timeoutMinutes: nil, synthetic: true)
  }

  /// Validates the approved checkout's inputs; returns its workspace path.
  mutating func checkCheckout(_ with: [TemplateEntry], line: Int, path: String) -> String {
    var checkoutPath = "."
    for entry in with {
      let input = "\(path).with.\(entry.key)"
      switch entry.key {
      case "path":
        guard case .string(let text) = entry.value, !text.isEmpty, !text.hasPrefix("/"),
          !text.split(separator: "/").contains(".."),
          text.unicodeScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" })
        else {
          report(line, input, "checkout path must be a plain workspace-relative path")
          continue
        }
        checkoutPath = text
      case "repository":
        let allowed: Set<String> = ["github.repository"]
        if case .expression(let text) = entry.value, allowed.contains(text.lowercased()) {
          continue
        }
        if case .string(let text) = entry.value,
          text.lowercased() == github["repository"]?.stringValue?.lowercased()
        {
          continue
        }
        report(
          line, input,
          "checking out another repository is not supported (single-workspace checkout only)")
      case "ref":
        if case .expression(let text) = entry.value,
          ["github.sha", "github.ref"].contains(text.lowercased())
        {
          continue
        }
        report(line, input, "checkout ref must be the snapshot base (omit ref)")
      case "lfs":
        if entry.value != .bool(false) && entry.value != .string("false") {
          report(line, input, "LFS checkouts are not supported")
        }
      case "submodules":
        if entry.value != .bool(false) && entry.value != .string("false") {
          report(line, input, "submodule checkouts are not supported")
        }
      // A local snapshot carries selected content only, never the original
      // history (CI-01): a job that needs history is refused, not run on a
      // truncated one.
      case "fetch-depth":
        if entry.value != .string("1") && entry.value != .number(1) {
          report(
            line, input,
            "unsupported capability: local snapshots carry no history (fetch-depth must be 1)")
        }
      case "fetch-tags":
        if entry.value != .bool(false) && entry.value != .string("false") {
          report(line, input, "unsupported capability: local snapshots carry no tags or history")
        }
      default: break
      }
    }
    return checkoutPath
  }

  mutating func parseReference(_ text: String, line: Int, path: String) -> ActionReference? {
    if text.hasPrefix("docker://") {
      let image = String(text.dropFirst("docker://".count))
      guard !image.isEmpty, image.utf8.count <= 512, !image.contains(" ") else {
        report(line, path, "invalid docker image reference")
        return nil
      }
      guard manifest.allowsDockerActions else {
        report(line, path, "container actions are not in the compatibility manifest")
        return nil
      }
      return .docker(image: image)
    }
    if text.hasPrefix("./") {
      let local = String(text)
      guard !local.split(separator: "/").contains(".."), local.utf8.count <= 512,
        local.unicodeScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" })
      else {
        report(line, path, "local action paths must stay inside the workspace")
        return nil
      }
      guard manifest.allowsLocalActions else {
        report(line, path, "local actions are not in the compatibility manifest")
        return nil
      }
      return .local(path: local)
    }
    let parts = text.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(
      String.init)
    let segments = parts[0].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 2, !parts[1].isEmpty, segments.count >= 2,
      RepositoryName.validOrganization(segments[0]),
      (try? RepositoryName("\(segments[0])/\(segments[1])")) != nil,
      segments.dropFirst(2).allSatisfy({
        !$0.isEmpty && $0 != ".." && $0.unicodeScalars.allSatisfy(isSafeNameScalar)
      }),
      parts[1].unicodeScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" })
    else {
      report(line, path, "invalid action reference (expected owner/repo[/path]@ref)")
      return nil
    }
    let subpath = segments.count > 2 ? segments.dropFirst(2).joined(separator: "/") : nil
    let nameWithOwner = "\(segments[0])/\(segments[1])"
    guard let approved = manifest.approvedAction(nameWithOwner) else {
      report(
        line, path, "action \(nameWithOwner) is not in the compatibility manifest \(manifest.id)")
      return nil
    }
    guard CompatibilityManifest.refAccepted(parts[1], for: approved) else {
      report(
        line, path,
        "\(nameWithOwner)@\(parts[1]) is not an approved version (\(approved.majorVersion) or a full commit SHA)"
      )
      return nil
    }
    if subpath != nil {
      report(line, path, "action subpaths are not in the compatibility manifest")
      return nil
    }
    return .repository(owner: segments[0], repository: segments[1], path: subpath, ref: parts[1])
  }
}
