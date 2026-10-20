import Foundation

/// The GitHub runner and job operations one pool's reconciler needs, scoped
/// to that pool's installation. Polling here is for correlation and status
/// only, never for local scheduling (spec section 7).
package protocol RunnerService: Sendable {
  /// The runner group JIT registrations use (1, the default group, for
  /// repository scope; the configured group for organization scope).
  func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64
  /// Not idempotent: a `githubUnavailable` error with
  /// `details["uncertain"] == "true"` means the registration may exist.
  func generateJIT(
    scope: GitHubRunnerScope, name: String, runnerGroupID: Int64, labels: [String],
    workFolder: String
  ) throws(CIError) -> GitHubJITConfig
  /// Runners with exactly this name in exactly this scope.
  func runners(scope: GitHubRunnerScope, named name: String) throws(CIError) -> [GitHubRunnerInfo]
  func runner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> GitHubRunnerInfo?
  /// False when the runner was already gone.
  func deleteRunner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> Bool
  /// Queued and in-progress jobs visible in the scope, bounded; used only to
  /// correlate jobs with runners through runner_id/runner_name.
  func activeJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo]
  /// Jobs of the newest completed runs in the scope, bounded; used only to
  /// bind a job that started and finished between two passes to the exact
  /// runner that ran it.
  func completedJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo]
  func job(repository: RepositoryName, id: Int64) throws(CIError) -> GitHubJobInfo
}

/// `RunnerService` over the GitHub REST API with installation tokens.
package final class InstallationRunnerService: RunnerService {
  package static let maxCorrelationRepositories = 20
  package static let maxCorrelationRuns = 20

  let client: GitHubInstallationClient

  package init(client: GitHubInstallationClient) { self.client = client }

  package func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64 {
    switch scope {
    case .repository: return 1
    case .organization(let org, let groupName):
      let groups = try client.api.runnerGroups(org: org, token: try client.token())
      guard let group = groups.first(where: { $0.name == groupName }) else {
        throw CIError(.githubRefused, "runner group \(groupName) does not exist in \(org)")
      }
      return group.id
    }
  }

  package func generateJIT(
    scope: GitHubRunnerScope, name: String, runnerGroupID: Int64, labels: [String],
    workFolder: String
  ) throws(CIError) -> GitHubJITConfig {
    try client.api.generateJITConfig(
      scope: scope, name: name, runnerGroupID: runnerGroupID, labels: labels,
      workFolder: workFolder,
      token: try client.token())
  }

  package func runners(scope: GitHubRunnerScope, named name: String) throws(CIError)
    -> [GitHubRunnerInfo]
  {
    try client.api.runners(scope: scope, name: name, token: try client.token())
  }

  package func runner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> GitHubRunnerInfo? {
    try client.api.runner(scope: scope, id: id, token: try client.token())
  }

  package func deleteRunner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> Bool {
    try client.api.deleteRunner(scope: scope, id: id, token: try client.token())
  }

  package func activeJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo] {
    let token = try client.token()
    var jobs: [GitHubJobInfo] = []
    for repository in try correlationRepositories(scope, token: token) {
      var runs: [GitHubRunInfo] = []
      for status in ["in_progress", "queued"] {
        runs += try client.api.workflowRuns(repository: repository, status: status, token: token)
      }
      for run in runs.prefix(Self.maxCorrelationRuns) {
        jobs += try client.api.jobs(repository: repository, runID: run.id, token: token)
      }
    }
    return jobs
  }

  package func completedJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo] {
    let token = try client.token()
    var jobs: [GitHubJobInfo] = []
    for repository in try correlationRepositories(scope, token: token) {
      let runs = try client.api.workflowRuns(
        repository: repository, status: "completed", newest: Self.maxCorrelationRuns, token: token)
      for run in runs {
        jobs += try client.api.jobs(repository: repository, runID: run.id, token: token)
      }
    }
    return jobs
  }

  private func correlationRepositories(_ scope: GitHubScope, token: RedactedSecret)
    throws(CIError) -> [RepositoryName]
  {
    switch scope {
    case .repository(let repository): return [repository]
    case .organization:
      return try client.api.installationRepositories(token: token).repositories
        .prefix(Self.maxCorrelationRepositories).compactMap { try? RepositoryName($0.fullName) }
    }
  }

  package func job(repository: RepositoryName, id: Int64) throws(CIError) -> GitHubJobInfo {
    try client.api.job(repository: repository, id: id, token: try client.token())
  }
}

/// Used when a pool has no usable installation (credentials removed,
/// revoked, or GitHub unreachable): every GitHub call fails as unavailable,
/// so the reconciler still observes, stops and releases owned VMs while
/// registrations stay pending until GitHub access returns.
package struct OfflineRunnerService: RunnerService {
  package let reason: String

  package init(reason: String) { self.reason = reason }

  private func unavailable() -> CIError { CIError(.githubUnavailable, reason) }

  package func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64 { throw unavailable() }

  package func generateJIT(
    scope: GitHubRunnerScope, name: String, runnerGroupID: Int64, labels: [String],
    workFolder: String
  ) throws(CIError) -> GitHubJITConfig { throw unavailable() }

  package func runners(scope: GitHubRunnerScope, named name: String) throws(CIError)
    -> [GitHubRunnerInfo]
  { throw unavailable() }

  package func runner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> GitHubRunnerInfo? {
    throw unavailable()
  }

  package func deleteRunner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> Bool {
    throw unavailable()
  }

  package func activeJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo] {
    throw unavailable()
  }

  package func completedJobs(scope: GitHubScope) throws(CIError) -> [GitHubJobInfo] {
    throw unavailable()
  }

  package func job(repository: RepositoryName, id: Int64) throws(CIError) -> GitHubJobInfo {
    throw unavailable()
  }
}
