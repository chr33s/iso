import Foundation

/// One expanded job's lifecycle state inside a preflight run.
package enum JobState: String, Sendable, Codable, CaseIterable {
  case pending, running, succeeded, failed, cancelled, skipped

  package var isTerminal: Bool {
    switch self {
    case .succeeded, .failed, .cancelled, .skipped: true
    case .pending, .running: false
    }
  }
}

/// A finished (or running) job's state and its job outputs.
package struct JobOutcome: Sendable, Equatable, Codable {
  package var state: JobState
  package var outputs: [String: String]

  package init(state: JobState, outputs: [String: String] = [:]) {
    self.state = state
    self.outputs = outputs
  }
}

package struct JobTransition: Sendable, Equatable, Hashable {
  package let key: String
  package let reason: String

  package init(key: String, reason: String) {
    self.key = key
    self.reason = CIError.bounded(reason)
  }
}

/// What the orchestrator should do next.
package struct ScheduleDecision: Sendable, Equatable {
  /// Jobs whose needs finished and whose `if:` evaluated true.
  package var ready: [String] = []
  /// Jobs whose `if:` evaluated false.
  package var skip: [JobTransition] = []
  /// Jobs whose `if:` could not be evaluated (GitHub fails the job).
  package var fail: [JobTransition] = []
  /// Pending or running jobs to cancel (fail-fast, run cancellation).
  package var cancel: [JobTransition] = []

  package var isEmpty: Bool { ready.isEmpty && skip.isEmpty && fail.isEmpty && cancel.isEmpty }
}

package enum RunConclusion: String, Sendable, Codable {
  case inProgress = "in_progress"
  case success, failure, cancelled
}

/// Scheduling over the compiled plan: dependency order, job-level `if:`,
/// `needs` aggregation over matrix legs, fail-fast and max-parallel.
/// Pure: it never mutates state, so the orchestrator persists decisions.
package struct JobGraph: Sendable {
  package let plan: WorkflowPlan

  package init(plan: WorkflowPlan) { self.plan = plan }

  /// GitHub's result string for one finished leg. A failed job with
  /// `continue-on-error: true` counts as success for dependents and the run.
  func result(_ job: JobPlan, _ outcome: JobOutcome?) -> String? {
    guard let outcome, outcome.state.isTerminal else { return nil }
    switch outcome.state {
    case .succeeded: return "success"
    case .failed: return job.continueOnError ? "success" : "failure"
    case .cancelled: return "cancelled"
    case .skipped: return "skipped"
    case .pending, .running: return nil
    }
  }

  /// Aggregated result of all legs of one workflow job id, or nil while any
  /// leg is unfinished.
  package func aggregateResult(jobID: String, outcomes: [String: JobOutcome]) -> String? {
    let legs = plan.jobs.filter { $0.jobID == jobID }
    var results: [String] = []
    for leg in legs {
      guard let result = result(leg, outcomes[leg.key]) else { return nil }
      results.append(result)
    }
    if results.contains("failure") { return "failure" }
    if results.contains("cancelled") { return "cancelled" }
    if !results.isEmpty && results.allSatisfy({ $0 == "skipped" }) { return "skipped" }
    return "success"
  }

  /// The `needs` context for `key`: `needs.<id>.result` and `.outputs`
  /// (matrix legs merged in plan order; later non-empty values win).
  package func needsContext(for key: String, outcomes: [String: JobOutcome]) -> JSONValue {
    guard let job = plan.job(key) else { return [:] }
    var context: [String: JSONValue] = [:]
    for id in job.needsJobIDs {
      var outputs: [String: JSONValue] = [:]
      for leg in plan.jobs where leg.jobID == id {
        for (name, value) in outcomes[leg.key]?.outputs ?? [:]
        where !value.isEmpty || outputs[name] == nil {
          outputs[name] = .string(value)
        }
      }
      context[id] = [
        "result": aggregateResult(jobID: id, outcomes: outcomes).map(JSONValue.string) ?? .null,
        "outputs": .object(outputs),
      ]
    }
    return .object(context)
  }

  /// The contexts a job-level `if:` sees: `base` (github, vars, inputs)
  /// plus `needs` and the status derived from the needs' results.
  package func conditionContexts(
    for key: String, outcomes: [String: JobOutcome], runCancelled: Bool, base: ExpressionContexts
  ) -> ExpressionContexts {
    var contexts = ExpressionContexts(
      github: base[.github], vars: base[.vars], needs: needsContext(for: key, outcomes: outcomes),
      inputs: base[.inputs])
    let results = (plan.job(key)?.needsJobIDs ?? []).map {
      aggregateResult(jobID: $0, outcomes: outcomes)
    }
    contexts.status = ExpressionStatus(
      success: results.allSatisfy { $0 == "success" }, failure: results.contains("failure"),
      cancelled: runCancelled)
    return contexts
  }

  /// The next decisions given current outcomes. `limit` caps how many jobs
  /// may be running at once across the run (nil: no cap beyond max-parallel).
  package func schedule(
    outcomes: [String: JobOutcome], runCancelled: Bool, base: ExpressionContexts,
    limit: Int? = nil
  ) -> ScheduleDecision {
    var decision = ScheduleDecision()
    var cancelled: Set<String> = []
    // Fail-fast: a failed leg (without continue-on-error) cancels its
    // unfinished siblings.
    for job in plan.jobs where job.strategy.failFast && job.matrix != nil {
      guard outcomes[job.key]?.state == .failed, !job.continueOnError else { continue }
      for sibling in plan.jobs where sibling.jobID == job.jobID && sibling.key != job.key {
        let state = outcomes[sibling.key]?.state ?? .pending
        if !state.isTerminal, cancelled.insert(sibling.key).inserted {
          decision.cancel.append(
            JobTransition(
              key: sibling.key, reason: "fail-fast: matrix job \(job.displayName) failed"))
        }
      }
    }
    var running = plan.jobs.filter {
      outcomes[$0.key]?.state == .running && !cancelled.contains($0.key)
    }
    .count
    var runningPerJob: [String: Int] = [:]
    for job in plan.jobs where outcomes[job.key]?.state == .running {
      runningPerJob[job.jobID, default: 0] += 1
    }
    for job in plan.jobs {
      let state = outcomes[job.key]?.state ?? .pending
      guard state == .pending, !cancelled.contains(job.key) else { continue }
      let finished = job.needsJobIDs.allSatisfy {
        aggregateResult(jobID: $0, outcomes: outcomes) != nil
      }
      guard finished else { continue }
      let contexts = conditionContexts(
        for: job.key, outcomes: outcomes, runCancelled: runCancelled, base: base)
      let run: Bool
      do {
        run = try ExpressionEvaluator.condition(job.condition, contexts)
      } catch {
        decision.fail.append(
          JobTransition(
            key: job.key, reason: "the job's if: condition failed to evaluate: \(error.message)"))
        continue
      }
      guard run else {
        if runCancelled {
          decision.cancel.append(JobTransition(key: job.key, reason: "the run was cancelled"))
        } else {
          decision.skip.append(
            JobTransition(key: job.key, reason: "the job's if: condition was false"))
        }
        continue
      }
      if let limit, running >= limit { continue }
      if runningPerJob[job.jobID, default: 0] >= job.strategy.maxParallel, job.matrix != nil {
        continue
      }
      decision.ready.append(job.key)
      running += 1
      runningPerJob[job.jobID, default: 0] += 1
    }
    return decision
  }

  /// The run's conclusion once every job is terminal.
  package func conclusion(outcomes: [String: JobOutcome]) -> RunConclusion {
    var sawCancelled = false
    var sawFailure = false
    for job in plan.jobs {
      guard let result = result(job, outcomes[job.key]) else { return .inProgress }
      if result == "failure" { sawFailure = true }
      if result == "cancelled" { sawCancelled = true }
    }
    if sawFailure { return .failure }
    if sawCancelled { return .cancelled }
    return .success
  }

  /// Job keys that transitively depend on `key` (for re-running an
  /// affected dependency closure after a changed input).
  package func dependents(of key: String) -> [String] {
    var out: Set<String> = []
    var frontier = [key]
    while let next = frontier.popLast() {
      for job in plan.jobs where job.needs.contains(next) && out.insert(job.key).inserted {
        frontier.append(job.key)
      }
    }
    return plan.jobs.map(\.key).filter(out.contains)
  }
}
