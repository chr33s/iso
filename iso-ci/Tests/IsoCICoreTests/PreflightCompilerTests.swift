import Foundation
import Testing

@testable import IsoCICore

/// The fixture corpus: every `Fixtures/workflows/<name>.yml` has a
/// `<name>.expect.json` naming the event and either the accepted shape or
/// the rejection reasons (C-T09: rejected before allocation).
@Suite struct PreflightCompilerTests {
  static let platformMap = ["ubuntu-latest": "linux/arm64"]
  static let snapshot = SnapshotReference(
    baseCommit: String(repeating: "a", count: 40), digest: Digest(hashing: "snapshot"),
    isDirty: true)

  static var directory: URL {
    Bundle.module.resourceURL!.appendingPathComponent("Fixtures/workflows")
  }

  static var fixtures: [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".yml") }.map { String($0.dropLast(4)) }.sorted()
  }

  func report(_ name: String) throws -> (CompileReport, JSONValue) {
    let source = try Data(contentsOf: Self.directory.appendingPathComponent(name + ".yml"))
    let expect = try StrictJSON.parse(
      try Data(contentsOf: Self.directory.appendingPathComponent(name + ".expect.json")),
      limits: .control)
    let report = WorkflowCompiler.analyze(
      source: source, path: ".github/workflows/\(name).yml",
      event: expect["event"]?.stringValue ?? "push", manifest: .localActionsV1,
      platformMap: Self.platformMap, inputs: expect["inputs"]?.objectValue ?? [:],
      github: ["repository": "owner/repo", "sha": "abc"], snapshot: Self.snapshot)
    return (report, expect)
  }

  @Test func corpusIsPresent() {
    #expect(Self.fixtures.count >= 30)
    #expect(Self.fixtures.contains { $0.hasPrefix("accept-") })
    #expect(Self.fixtures.contains { $0.hasPrefix("reject-") })
  }

  @Test(arguments: fixtures) func fixture(_ name: String) throws {
    let (compiled, expect) = try report(name)
    let report = compiled
    if let reasons = expect["reject"]?.arrayValue {
      #expect(report.plan == nil, "\(name) should be rejected")
      let text = report.diagnostics.map(\.description).joined(separator: "\n")
      for reason in reasons.compactMap(\.stringValue) {
        #expect(text.contains(reason), "\(name): missing '\(reason)' in:\n\(text)")
      }
      return
    }
    guard let plan = report.plan else {
      Issue.record("\(name) rejected: \(report.diagnostics.map(\.description))")
      return
    }
    #expect(plan.manifestID == "local-actions/v1")
    #expect(plan.jobs.allSatisfy { $0.platform == "linux/arm64" })
    if let jobs = expect["jobs"]?.arrayValue {
      #expect(plan.jobs.map(\.key) == jobs.compactMap(\.stringValue))
    }
    if let count = expect["jobCount"]?.intValue { #expect(plan.jobs.count == Int(count)) }
    if let warnings = expect["warnings"]?.intValue {
      #expect(report.warnings.count == Int(warnings))
    }
    for (key, ids) in expect["steps"]?.objectValue ?? [:] {
      #expect(plan.job(key)?.steps.map(\.contextName) == ids.arrayValue?.compactMap(\.stringValue))
    }
    for (key, flags) in expect["synthetic"]?.objectValue ?? [:] {
      #expect(plan.job(key)?.steps.map(\.synthetic) == flags.arrayValue?.compactMap(\.boolValue))
    }
    for (key, conditions) in expect["conditions"]?.objectValue ?? [:] {
      #expect(
        plan.job(key)?.steps.map(\.condition) == conditions.arrayValue?.compactMap(\.stringValue))
    }
    for (key, secrets) in expect["secrets"]?.objectValue ?? [:] {
      #expect(plan.job(key)?.secretNames == secrets.arrayValue?.compactMap(\.stringValue))
    }
    for (key, minutes) in expect["timeout"]?.objectValue ?? [:] {
      #expect(plan.job(key)?.timeoutMinutes == minutes.intValue.map(Int.init))
    }
    if let actions = expect["actions"]?.arrayValue {
      #expect(plan.actions.map(\.displayName) == actions.compactMap(\.stringValue))
    }
    // The plan is deterministic.
    let (again, _) = try self.report(name)
    #expect(again.plan?.digest == plan.digest)
  }

  /// CI-01: local snapshots carry no history, so history-dependent
  /// checkouts are refused rather than run on a truncated tree.
  @Test(arguments: ["fetch-depth: 0", "fetch-depth: 50", "fetch-tags: true"])
  func historyDependentCheckoutsAreRefused(input: String) throws {
    let source = Data(
      """
      on: push
      jobs:
        a:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/checkout@v4
              with:
                \(input)
      """.utf8)
    do {
      _ = try WorkflowCompiler.compile(
        source: source, path: "w.yml", event: "push", manifest: .localActionsV1,
        platformMap: Self.platformMap)
      Issue.record("expected a rejection")
    } catch {
      #expect(error.code == .compatibilityRejected)
      #expect(error.details.values.contains { $0.contains("history") || $0.contains("tags") })
    }
  }

  @Test func rejectionCarriesEveryDiagnostic() throws {
    let source = Data(
      """
      on: push
      jobs:
        a:
          runs-on: macos-latest
          environment: prod
          steps:
            - uses: actions/setup-python@v5
      """.utf8)
    do {
      _ = try WorkflowCompiler.compile(
        source: source, path: "w.yml", event: "push", manifest: .localActionsV1,
        platformMap: Self.platformMap)
      Issue.record("expected a rejection")
    } catch {
      #expect(error.code == .compatibilityRejected)
      #expect(error.details.count == 3)
      #expect(error.details.values.allSatisfy { $0.hasPrefix("line ") })
    }
  }

  @Test func checkoutIsReplacedByVisibleSyntheticSteps() throws {
    let (compiled, _) = try report("accept-actions")
    let steps = try #require(compiled.plan?.jobs.first?.steps)
    #expect(steps[0].kind == .syntheticCheckout(path: "src"))
    #expect(steps[1].kind == .snapshotOverlay(path: "src"))
    #expect(steps[0].synthetic && steps[1].synthetic)
    #expect(steps[0].name?.literalString?.contains("base aaaaaaaaaaaa") == true)
    #expect(steps[1].name?.literalString?.contains(Self.snapshot.digest.prefixed) == true)
    #expect(steps[1].name?.literalString?.contains("dirty") == true)
    #expect(steps[2...].allSatisfy { !$0.synthetic })
  }

  @Test func withoutCheckoutTheOverlayPrecedesTheFirstUserStep() throws {
    let source = Data(
      """
      on: push
      jobs:
        a:
          runs-on: ubuntu-latest
          steps:
            - run: ls
      """.utf8)
    let plan = try WorkflowCompiler.compile(
      source: source, path: "w.yml", event: "push", manifest: .localActionsV1,
      platformMap: Self.platformMap, snapshot: Self.snapshot)
    let steps = plan.jobs[0].steps
    #expect(steps.count == 2)
    #expect(steps[0].kind == .snapshotOverlay(path: "."))
    #expect(steps[0].synthetic)
  }

  @Test func platformMappingIsExplicitOnly() {
    let map = ["ubuntu-latest": "linux/arm64", "iso-ci": "linux/arm64"]
    #expect(WorkflowCompiler.platform(for: ["ubuntu-latest"], map: map) == "linux/arm64")
    #expect(
      WorkflowCompiler.platform(for: ["self-hosted", "Linux", "ARM64"], map: [:]) == "linux/arm64")
    #expect(
      WorkflowCompiler.platform(for: ["self-hosted", "linux", "ARM64", "iso-ci"], map: map)
        == "linux/arm64")
    #expect(
      WorkflowCompiler.platform(for: ["self-hosted", "linux", "ARM64", "gpu"], map: map) == nil)
    #expect(WorkflowCompiler.platform(for: ["ubuntu-latest"], map: [:]) == nil)
    #expect(WorkflowCompiler.platform(for: ["macos-14"], map: map) == nil)
    #expect(WorkflowCompiler.platform(for: ["self-hosted", "linux", "x64"], map: map) == nil)
    #expect(
      WorkflowCompiler.platform(for: ["windows-latest"], map: ["windows-latest": "windows/x64"])
        == nil)
  }

  @Test func matrixIncludeExcludeExpansion() throws {
    let (compiled, _) = try report("accept-matrix")
    let plan = try #require(compiled.plan)
    let legs = plan.jobs.filter { $0.jobID == "test" }
    let combos = legs.compactMap { $0.matrix }
    #expect(combos.count == 4)
    #expect(combos.contains(["os": "a", "node": 18, "experimental": true]))
    #expect(combos.contains(["os": "a", "node": 20, "experimental": true]))
    #expect(combos.contains(["os": "b", "node": 20]))
    #expect(combos.contains(["os": "c", "node": 22]))
    #expect(!combos.contains(["os": "b", "node": 18]))
    #expect(
      legs.allSatisfy {
        !$0.strategy.failFast && $0.strategy.maxParallel == 2 && $0.strategy.jobTotal == 4
      })
    #expect(Set(legs.map(\.key)).count == 4)
    let reporter = try #require(plan.job("report"))
    #expect(Set(reporter.needs) == Set(legs.map(\.key)))
    #expect(reporter.condition == "always()")
  }

  @Test func manifestIsCanonicalAndKnown() throws {
    #expect(
      try CompatibilityManifest.builtin("local-actions/v1").digest
        == CompatibilityManifest.localActionsV1.digest)
    #expect(throws: CIError.self) { try CompatibilityManifest.builtin("local-actions/v9") }
    let checkout = try #require(
      CompatibilityManifest.localActionsV1.approvedAction("actions/checkout"))
    #expect(CompatibilityManifest.refAccepted("v4", for: checkout))
    #expect(CompatibilityManifest.refAccepted("v4.1.7", for: checkout))
    #expect(CompatibilityManifest.refAccepted(String(repeating: "b", count: 40), for: checkout))
    #expect(!CompatibilityManifest.refAccepted("v3", for: checkout))
    #expect(!CompatibilityManifest.refAccepted("v40", for: checkout))
    #expect(!CompatibilityManifest.refAccepted("main", for: checkout))
  }

  @Test func onStaysAWorkflowKey() throws {
    // `on` is a key, never the YAML 1.1 boolean.
    let node = try YAML.parse("on: push\njobs: {}\n")
    #expect(node["on"]?.scalar?.value == "push")
  }
}

@Suite struct PreflightJobGraphTests {
  func plan(_ text: String) throws -> WorkflowPlan {
    try WorkflowCompiler.compile(
      source: Data(text.utf8), path: "w.yml", event: "push", manifest: .localActionsV1,
      platformMap: ["ubuntu-latest": "linux/arm64"])
  }

  let base = ExpressionContexts(github: ["event_name": "push"])

  @Test func needsOrderingOutputsAndSkips() throws {
    let plan = try plan(
      """
      on: push
      jobs:
        build:
          runs-on: ubuntu-latest
          outputs:
            version: ${{ steps.v.outputs.version }}
          steps:
            - id: v
              run: echo
        test:
          needs: build
          runs-on: ubuntu-latest
          steps:
            - run: echo
        cleanup:
          needs: [build, test]
          if: always()
          runs-on: ubuntu-latest
          steps:
            - run: echo
        notify:
          needs: test
          if: failure()
          runs-on: ubuntu-latest
          steps:
            - run: echo
      """)
    let graph = JobGraph(plan: plan)
    var outcomes: [String: JobOutcome] = [:]
    var decision = graph.schedule(outcomes: outcomes, runCancelled: false, base: base)
    #expect(decision.ready == ["build"])
    outcomes["build"] = JobOutcome(state: .succeeded, outputs: ["version": "1.2"])
    decision = graph.schedule(outcomes: outcomes, runCancelled: false, base: base)
    #expect(decision.ready == ["test"])
    #expect(
      graph.needsContext(for: "test", outcomes: outcomes)
        == ["build": ["result": "success", "outputs": ["version": "1.2"]]])
    outcomes["test"] = JobOutcome(state: .failed)
    decision = graph.schedule(outcomes: outcomes, runCancelled: false, base: base)
    #expect(Set(decision.ready) == ["cleanup", "notify"])
    outcomes["cleanup"] = JobOutcome(state: .succeeded)
    outcomes["notify"] = JobOutcome(state: .succeeded)
    #expect(graph.conclusion(outcomes: outcomes) == .failure)
  }

  @Test func defaultConditionSkipsAfterFailureAndSkips() throws {
    let plan = try plan(
      """
      on: push
      jobs:
        a:
          runs-on: ubuntu-latest
          steps:
            - run: echo
        b:
          needs: a
          runs-on: ubuntu-latest
          steps:
            - run: echo
        c:
          needs: b
          runs-on: ubuntu-latest
          steps:
            - run: echo
      """)
    let graph = JobGraph(plan: plan)
    var outcomes = ["a": JobOutcome(state: .failed)]
    var decision = graph.schedule(outcomes: outcomes, runCancelled: false, base: base)
    #expect(decision.skip.map(\.key) == ["b"])
    outcomes["b"] = JobOutcome(state: .skipped)
    decision = graph.schedule(outcomes: outcomes, runCancelled: false, base: base)
    #expect(decision.skip.map(\.key) == ["c"])
    outcomes["c"] = JobOutcome(state: .skipped)
    #expect(graph.conclusion(outcomes: outcomes) == .failure)
  }

  @Test func failFastCancelsSiblingsAndMaxParallelLimits() throws {
    let plan = try plan(
      """
      on: push
      jobs:
        t:
          runs-on: ubuntu-latest
          strategy:
            max-parallel: 2
            matrix:
              n: [1, 2, 3, 4]
          steps:
            - run: echo
      """)
    let graph = JobGraph(plan: plan)
    var outcomes: [String: JobOutcome] = [:]
    let first = graph.schedule(outcomes: outcomes, runCancelled: false, base: base)
    #expect(first.ready.count == 2)
    for key in first.ready { outcomes[key] = JobOutcome(state: .running) }
    #expect(graph.schedule(outcomes: outcomes, runCancelled: false, base: base).ready.isEmpty)
    outcomes[first.ready[0]] = JobOutcome(state: .failed)
    let decision = graph.schedule(outcomes: outcomes, runCancelled: false, base: base)
    #expect(decision.ready.isEmpty)
    #expect(decision.cancel.count == 3)
    #expect(decision.cancel.allSatisfy { $0.reason.hasPrefix("fail-fast") })
  }

  @Test func matrixAggregationAndGlobalLimit() throws {
    let plan = try plan(
      """
      on: push
      jobs:
        t:
          runs-on: ubuntu-latest
          strategy:
            fail-fast: false
            matrix:
              n: [1, 2]
          outputs:
            o: x
          steps:
            - run: echo
        after:
          needs: t
          runs-on: ubuntu-latest
          steps:
            - run: echo
      """)
    let graph = JobGraph(plan: plan)
    let legs = plan.jobs.filter { $0.jobID == "t" }.map(\.key)
    #expect(
      graph.schedule(outcomes: [:], runCancelled: false, base: base, limit: 1).ready.count == 1)
    var outcomes = [legs[0]: JobOutcome(state: .succeeded, outputs: ["o": "first"])]
    #expect(graph.aggregateResult(jobID: "t", outcomes: outcomes) == nil)
    outcomes[legs[1]] = JobOutcome(state: .skipped)
    #expect(graph.aggregateResult(jobID: "t", outcomes: outcomes) == "success")
    #expect(graph.schedule(outcomes: outcomes, runCancelled: false, base: base).ready == ["after"])
    outcomes[legs[1]] = JobOutcome(state: .cancelled)
    #expect(graph.aggregateResult(jobID: "t", outcomes: outcomes) == "cancelled")
    let cancelled = graph.schedule(outcomes: outcomes, runCancelled: true, base: base)
    #expect(cancelled.cancel.map(\.key) == ["after"])
    #expect(graph.dependents(of: legs[0]) == ["after"])
  }

  @Test func continueOnErrorJobCountsAsSuccess() throws {
    let plan = try plan(
      """
      on: push
      jobs:
        flaky:
          runs-on: ubuntu-latest
          continue-on-error: true
          steps:
            - run: exit 1
        next:
          needs: flaky
          runs-on: ubuntu-latest
          steps:
            - run: echo
      """)
    let graph = JobGraph(plan: plan)
    let outcomes = ["flaky": JobOutcome(state: .failed)]
    #expect(graph.schedule(outcomes: outcomes, runCancelled: false, base: base).ready == ["next"])
  }
}
