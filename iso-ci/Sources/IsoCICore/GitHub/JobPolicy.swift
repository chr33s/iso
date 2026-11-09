import Foundation

/// Why a queued job was refused before any runner or VM existed. The raw
/// values are the audit event codes.
package enum JobRejection: String, Sendable, Codable, CaseIterable {
  case publicRepository = "JOB_REJECTED_PUBLIC_REPO"
  case forkPullRequest = "JOB_REJECTED_FORK_PR"
  case event = "JOB_REJECTED_EVENT"
  case actor = "JOB_REJECTED_ACTOR"
  /// The job is outside the pool's GitHub scope.
  case scope = "JOB_REJECTED_SCOPE"
  /// Its facts could not be read or did not agree with the offer.
  case unverifiable = "JOB_REJECTED_UNVERIFIABLE"
}

package enum JobPolicyDecision: Sendable, Equatable {
  case allow
  case deny(JobRejection, String)
}

/// What the policy decides on, read from GitHub's own workflow run record
/// (never from the guest or the job offer alone).
package struct JobFacts: Sendable, Equatable {
  package var repository: String
  package var repositoryID: Int64
  package var repositoryPrivate: Bool
  package var event: String
  package var actor: String?
  /// Who started this attempt (a re-run's actor), when GitHub says.
  package var triggeringActor: String?
  /// The repository the run's head commit came from; nil when GitHub
  /// reports none.
  package var headRepositoryID: Int64?
  package var headRepositoryIsFork: Bool

  package init(
    repository: String, repositoryID: Int64, repositoryPrivate: Bool, event: String,
    actor: String?, triggeringActor: String? = nil, headRepositoryID: Int64?,
    headRepositoryIsFork: Bool = false
  ) {
    self.repository = repository
    self.repositoryID = repositoryID
    self.repositoryPrivate = repositoryPrivate
    self.event = event
    self.actor = actor
    self.triggeringActor = triggeringActor
    self.headRepositoryID = headRepositoryID
    self.headRepositoryIsFork = headRepositoryIsFork
  }

  /// `GET /repos/{owner}/{repo}/actions/runs/{id}`.
  package init(run json: JSONValue) throws(CIError) {
    guard let repository = json["repository"], let id = repository["id"]?.intValue,
      let name = repository["full_name"]?.stringValue,
      let event = json["event"]?.stringValue
    else { throw CIError(.githubUnavailable, "the workflow run record is incomplete") }
    self.repository = name
    repositoryID = id
    // A missing flag is treated as public: the stricter reading.
    repositoryPrivate = repository["private"]?.boolValue ?? false
    self.event = event
    actor = json["actor"]?["login"]?.stringValue
    triggeringActor = json["triggering_actor"]?["login"]?.stringValue
    headRepositoryID = json["head_repository"]?["id"]?.intValue
    headRepositoryIsFork = json["head_repository"]?["fork"]?.boolValue ?? false
  }

  static let pullRequestEvents: Set<String> = [
    "pull_request", "pull_request_target", "pull_request_review", "pull_request_review_comment",
  ]

  /// Code from another repository: a head repository other than this one,
  /// or a pull request event whose head repository GitHub does not name.
  package var isFork: Bool {
    if let head = headRepositoryID { return head != repositoryID || headRepositoryIsFork }
    return Self.pullRequestEvents.contains(event)
  }
}

/// The pre-assignment gate for scale-set pools: evaluated on GitHub's own
/// records before a job is acquired, so a refused job never reaches a
/// runner registration, a host admission or a VM.
package enum JobPolicyEvaluator {
  package static func evaluate(_ facts: JobFacts, policy: JobPolicy) -> JobPolicyDecision {
    if !facts.repositoryPrivate && !policy.allowPublicRepo {
      return .deny(.publicRepository, "\(facts.repository) is public")
    }
    if facts.isFork && !policy.allowForkPRs {
      return .deny(.forkPullRequest, "the run's head comes from another repository")
    }
    if !policy.allowedEvents.contains(facts.event) {
      return .deny(.event, "event \(facts.event) is not allowed")
    }
    if !policy.allowedActors.isEmpty {
      guard let actor = facts.actor else { return .deny(.actor, "the run names no actor") }
      for login in [actor] + [facts.triggeringActor].compactMap({ $0 })
      where !policy.allowedActors.contains(login.lowercased()) {
        return .deny(.actor, "actor \(login) is not allowed")
      }
    }
    return .allow
  }

  /// Evaluates one job offer: its repository must be inside the pool's
  /// scope, and GitHub's run record must agree with the offer's event.
  /// Anything unreadable is refused.
  package static func evaluate(
    offer: ScaleSetJobMessage, scope: GitHubScope, policy: JobPolicy,
    facts: () throws(CIError) -> JobFacts
  ) -> JobPolicyDecision {
    guard let repository = offer.repository else {
      return .deny(.unverifiable, "the offer names no repository")
    }
    switch scope {
    case .repository(let configured):
      guard configured.rawValue.lowercased() == repository.rawValue.lowercased() else {
        return .deny(.scope, "\(repository) is not \(configured)")
      }
    case .organization(let org, _):
      guard repository.owner.lowercased() == org.lowercased() else {
        return .deny(.scope, "\(repository) is outside \(org)")
      }
    }
    let read: JobFacts
    do { read = try facts() } catch {
      return .deny(.unverifiable, "run facts could not be read: \(error.message)")
    }
    guard read.repository.lowercased() == repository.rawValue.lowercased() else {
      return .deny(.unverifiable, "the run belongs to \(read.repository)")
    }
    if let offered = offer.eventName, offered != read.event {
      return .deny(
        .unverifiable, "the offer's event \(offered) differs from the run's \(read.event)")
    }
    return evaluate(read, policy: policy)
  }
}
