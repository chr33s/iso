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
  func runners(scope: GitHubRunnerScope, named name: String) throws(CIError) -> [GitHubRunnerInfo]
  func runner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> GitHubRunnerInfo?
  func deleteRunner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> Bool
  /// Jobs of the scope's in-progress, then queued, runs, read lazily: a run's
  /// jobs are fetched only while the search has not found what it looks
  /// for. Used only to correlate jobs with runners through
  /// runner_id/runner_name.
  func activeJobs(scope: GitHubScope) throws(CIError) -> JobSearch
  /// Jobs of the newest completed runs in the scope, read lazily; used only
  /// to bind a job that started and finished between two passes to the
  /// exact runner that ran it.
  func completedJobs(scope: GitHubScope) throws(CIError) -> JobSearch
  func job(repository: RepositoryName, id: Int64) throws(CIError) -> GitHubJobInfo
}

/// A lazy walk over GitHub jobs, shared by every lookup in one pass: each
/// batch (one run's jobs) is fetched at most once, and only until a lookup
/// finds its job. GitHub offers no runner-to-job lookup (a runner record
/// carries no job; jobs are listed per run), so the walk visits runs.
package final class JobSearch {
  private let next: () throws(CIError) -> [GitHubJobInfo]?
  private var seen: [GitHubJobInfo] = []
  private var exhausted = false

  /// `next` returns the following batch, or nil once there is none.
  package init(next: @escaping () throws(CIError) -> [GitHubJobInfo]?) { self.next = next }

  package convenience init(_ jobs: [GitHubJobInfo]) {
    var pending = Optional(jobs)
    self.init { () throws(CIError) -> [GitHubJobInfo]? in
      defer { pending = nil }
      return pending
    }
  }

  /// The first job matching `match`, fetching further batches only as
  /// needed. A batch that fails to load ends the walk with that error.
  package func first(where match: (GitHubJobInfo) -> Bool) throws(CIError) -> GitHubJobInfo? {
    if let hit = seen.first(where: match) { return hit }
    while !exhausted {
      guard let batch = try next() else {
        exhausted = true
        break
      }
      seen += batch
      if let hit = batch.first(where: match) { return hit }
    }
    return nil
  }
}

package final class InstallationRunnerService: RunnerService {
  /// Completed runs searched per repository for a job that finished
  /// between two passes (newest first).
  package static let maxCompletedRuns = 20

  let client: GitHubInstallationClient

  package init(client: GitHubInstallationClient) { self.client = client }

  package func runnerGroupID(_ scope: GitHubScope) throws(CIError) -> Int64 {
    switch scope {
    case .repository: return 1
    case .organization(let org, let groupName):
      let groups = try client.api.runnerGroups(
        org: org, token: try client.token(.runnerGroupsRead))
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
      token: try client.token(.runnerAdministration(scope)))
  }

  package func runners(scope: GitHubRunnerScope, named name: String) throws(CIError)
    -> [GitHubRunnerInfo]
  {
    try client.api.runners(
      scope: scope, name: name, token: try client.token(.runnerAdministration(scope)))
  }

  package func runner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> GitHubRunnerInfo? {
    try client.api.runner(
      scope: scope, id: id, token: try client.token(.runnerAdministration(scope)))
  }

  package func deleteRunner(scope: GitHubRunnerScope, id: Int64) throws(CIError) -> Bool {
    try client.api.deleteRunner(
      scope: scope, id: id, token: try client.token(.runnerAdministration(scope)))
  }

  /// A busy runner's job is in an in-progress run, so those are read
  /// first; queued runs cover a run whose status GitHub has not updated.
  package func activeJobs(scope: GitHubScope) throws(CIError) -> JobSearch {
    try search(scope) { (repository, token) throws(CIError) in
      var runs: [GitHubRunInfo] = []
      for status in ["in_progress", "queued"] {
        runs += try self.client.api.workflowRuns(
          repository: repository, status: status, token: token)
      }
      return runs
    }
  }

  package func completedJobs(scope: GitHubScope) throws(CIError) -> JobSearch {
    try search(scope) { (repository, token) throws(CIError) in
      try self.client.api.workflowRuns(
        repository: repository, status: "completed", newest: Self.maxCompletedRuns, token: token)
    }
  }

  /// Walks the scope's repositories, listing each one's runs only when the
  /// search reaches it, then each run's jobs one batch at a time.
  private func search(
    _ scope: GitHubScope,
    runs list: @escaping (RepositoryName, RedactedSecret) throws(CIError) -> [GitHubRunInfo]
  ) throws(CIError) -> JobSearch {
    let token = try client.token(.actionsRead(Self.repository(scope)))
    var repositories: [RepositoryName]?
    var pending: [(RepositoryName, Int64)] = []
    return JobSearch { [self] () throws(CIError) -> [GitHubJobInfo]? in
      if repositories == nil { repositories = try correlationRepositories(scope, token: token) }
      while pending.isEmpty {
        guard let repository = repositories?.first else { return nil }
        repositories?.removeFirst()
        pending = try list(repository, token).map { (repository, $0.id) }
      }
      let (repository, run) = pending.removeFirst()
      return try client.api.jobs(repository: repository, runID: run, token: token)
    }
  }

  static func repository(_ scope: GitHubScope) -> RepositoryName? {
    guard case .repository(let repository) = scope else { return nil }
    return repository
  }

  private func correlationRepositories(_ scope: GitHubScope, token: RedactedSecret)
    throws(CIError) -> [RepositoryName]
  {
    switch scope {
    case .repository(let repository): return [repository]
    case .organization:
      return try client.api.installationRepositories(token: token).repositories
        .compactMap { try? RepositoryName($0.fullName) }
    }
  }

  package func job(repository: RepositoryName, id: Int64) throws(CIError) -> GitHubJobInfo {
    try client.api.job(
      repository: repository, id: id, token: try client.token(.actionsRead(repository)))
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

  package func activeJobs(scope: GitHubScope) throws(CIError) -> JobSearch {
    throw unavailable()
  }

  package func completedJobs(scope: GitHubScope) throws(CIError) -> JobSearch {
    throw unavailable()
  }

  package func job(repository: RepositoryName, id: Int64) throws(CIError) -> GitHubJobInfo {
    throw unavailable()
  }
}
