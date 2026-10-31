import Foundation

/// How strongly a security-relevant property is established (spec section 10).
package enum AuthorityGuaranteeStatus: String, Sendable, Codable, CaseIterable {
  /// Checked against GitHub or iso state now.
  case verified
  /// Asserted by the operator; iso-ci cannot check it.
  case operatorAttested = "operator_attested"
  /// Not established; never assumed.
  case unavailable
}

package struct AuthorityGuarantee: Sendable, Equatable, Codable {
  package let name: String
  package let status: AuthorityGuaranteeStatus
  package let detail: String
  /// Admission requires this guarantee to be verified.
  package let required: Bool

  package init(
    _ name: String, _ status: AuthorityGuaranteeStatus, _ detail: String, required: Bool = false
  ) {
    self.name = name
    self.status = status
    self.detail = CIError.bounded(detail)
    self.required = required
  }
}

package struct PoolActivationReport: Sendable, Equatable {
  package let pool: Name
  package let state: PoolState
  package let reasons: [String]
  package let guarantees: [AuthorityGuarantee]
  package let runnerGroupID: Int64?
}

/// The GitHub reads activation needs, scoped to one installation; faked in
/// tests.
package protocol AuthorityReader: Sendable {
  func installation(_ id: Int64) throws(CIError) -> GitHubInstallationInfo
  func installationRepositories() throws(CIError) -> (
    repositories: [GitHubRepositoryInfo], truncated: Bool
  )
  func repository(_ repository: RepositoryName) throws(CIError) -> GitHubRepositoryInfo
  func runnerGroups(org: String) throws(CIError) -> [GitHubRunnerGroupInfo]
  /// A policy document of `repository` at `path`, or nil when unavailable
  /// to the installation.
  func policy(_ path: String, of repository: RepositoryName) throws(CIError) -> JSONValue?
}

package final class APIAuthorityReader: AuthorityReader {
  let client: GitHubInstallationClient

  package init(client: GitHubInstallationClient) { self.client = client }

  package func installation(_ id: Int64) throws(CIError) -> GitHubInstallationInfo {
    try client.api.installation(id, jwt: try client.auth.jwt())
  }

  package func installationRepositories() throws(CIError) -> (
    repositories: [GitHubRepositoryInfo], truncated: Bool
  ) {
    try client.api.installationRepositories(token: try client.token(.metadataRead(nil)))
  }

  package func repository(_ repository: RepositoryName) throws(CIError) -> GitHubRepositoryInfo {
    try client.api.repository(repository, token: try client.token(.metadataRead(repository)))
  }

  package func runnerGroups(org: String) throws(CIError) -> [GitHubRunnerGroupInfo] {
    try client.api.runnerGroups(org: org, token: try client.token(.runnerGroupsRead))
  }

  package func policy(_ path: String, of repository: RepositoryName) throws(CIError)
    -> JSONValue?
  {
    try client.api.optionalPolicy(path, token: try client.token(.actionsPolicyRead(repository)))
  }
}

/// Decides whether a pool may admit work (spec sections 8 and 10). A pool's
/// `validation` authority describes intended policy and iso-side grants; it
/// cannot reduce GitHub-issued token permissions or strip workflow secrets,
/// so those properties are reported, never assumed. Any required guarantee
/// that cannot be verified leaves the pool inactive.
package enum PoolActivation {
  package static let privilegedReason = "privileged release execution is not qualified"

  package static func evaluate(
    pool name: Name, configuration: CIConfiguration, installation: InstallationRecord?,
    reader: any AuthorityReader
  ) -> PoolActivationReport {
    var reasons: [String] = []
    var guarantees: [AuthorityGuarantee] = []
    var groupID: Int64?
    func inactive() -> PoolActivationReport {
      PoolActivationReport(
        pool: name, state: .inactive, reasons: reasons, guarantees: guarantees,
        runnerGroupID: groupID)
    }
    guard let pool = configuration.pools[name], let profile = configuration.profiles[pool.profile]
    else {
      reasons.append("pool configuration is incomplete")
      return inactive()
    }
    if profile.authority == .privileged {
      reasons.append(privilegedReason)
      guarantees.append(
        AuthorityGuarantee(
          "privileged admission", .unavailable,
          "every eligible job would need enforceable admission and credential release controls",
          required: true))
      return inactive()
    }
    // Scope exclusivity among this controller's pools.
    let labelSet = Set(pool.labels.map(\.normalized))
    let clashing = configuration.pools.filter { other in
      other.key != name && GitHubRunnerScope(other.value.scope) == GitHubRunnerScope(pool.scope)
        && Set(other.value.labels.map(\.normalized)) == labelSet
    }
    if clashing.isEmpty {
      guarantees.append(
        AuthorityGuarantee(
          "routing exclusivity", .verified,
          "no other pool of this controller uses this scope and label set",
          required: true))
    } else {
      reasons.append(
        "another pool uses the same scope and labels: \(clashing.keys.map(\.rawValue).sorted().joined(separator: ", "))"
      )
      guarantees.append(
        AuthorityGuarantee(
          "routing exclusivity", .unavailable, "scope and labels are shared", required: true))
    }
    guard let installation else {
      reasons.append("installation \(pool.installation) is not connected; run `iso-ci setup`")
      return inactive()
    }
    // Installation identity and permissions.
    let info: GitHubInstallationInfo
    do { info = try reader.installation(installation.installationID) } catch {
      reasons.append("installation could not be verified: \(error.message)")
      guarantees.append(
        AuthorityGuarantee("installation identity", .unavailable, error.message, required: true))
      return inactive()
    }
    let scopeOwner = GitHubRunnerScope(pool.scope).owner.lowercased()
    guard info.id == installation.installationID, info.appID == installation.appID,
      info.account.lowercased() == scopeOwner, !info.suspended
    else {
      reasons.append("installation does not belong to \(scopeOwner) for this App, or is suspended")
      guarantees.append(
        AuthorityGuarantee(
          "installation identity", .unavailable, "identity mismatch", required: true))
      return inactive()
    }
    guarantees.append(
      AuthorityGuarantee(
        "installation identity", .verified, "installation \(info.id) on \(info.account)",
        required: true))
    let needed: [(String, String)]
    switch pool.scope {
    case .repository: needed = [("administration", "write"), ("actions", "read")]
    case .organization:
      needed = [("organization_self_hosted_runners", "write"), ("actions", "read")]
    }
    var missing: [String] = []
    for (permission, level) in needed where !satisfies(info.permissions[permission], level) {
      missing.append("\(permission):\(level)")
    }
    if missing.isEmpty {
      guarantees.append(
        AuthorityGuarantee(
          "App permissions", .verified, needed.map { "\($0.0):\($0.1)" }.joined(separator: ", "),
          required: true))
    } else {
      reasons.append("the installation lacks \(missing.joined(separator: ", "))")
      guarantees.append(
        AuthorityGuarantee("App permissions", .unavailable, "missing permissions", required: true))
      return inactive()
    }
    if info.permissions["actions"] == "write" {
      guarantees.append(
        AuthorityGuarantee(
          "least privilege", .unavailable,
          "the installation holds Actions write, broader than required"))
    }
    switch pool.scope {
    case .repository(let repository):
      if info.repositorySelection == "selected" {
        do {
          let accessible = try reader.installationRepositories()
          if accessible.repositories.contains(where: {
            $0.fullName.lowercased() == repository.rawValue.lowercased()
          }) {
            guarantees.append(
              AuthorityGuarantee(
                "repository access", .verified, repository.rawValue, required: true))
          } else if accessible.truncated {
            reasons.append("repository access could not be confirmed (listing truncated)")
            guarantees.append(
              AuthorityGuarantee(
                "repository access", .unavailable, "listing truncated", required: true))
            return inactive()
          } else {
            reasons.append("the installation cannot access \(repository.rawValue)")
            guarantees.append(
              AuthorityGuarantee("repository access", .unavailable, "not selected", required: true))
            return inactive()
          }
        } catch {
          reasons.append("repository access could not be verified: \(error.message)")
          return inactive()
        }
      } else {
        guarantees.append(
          AuthorityGuarantee(
            "repository access", .verified, "installation covers all repositories", required: true))
      }
      // Public triggers are a separately qualified target, never granted
      // by repository privacy or name.
      do {
        let repo = try reader.repository(repository)
        if repo.isPublic {
          reasons.append("public repository execution is not qualified")
          guarantees.append(
            AuthorityGuarantee(
              "public trigger exposure", .unavailable, "repository is public", required: true))
          return inactive()
        }
        guarantees.append(
          AuthorityGuarantee(
            "public trigger exposure", .verified, "repository is \(repo.visibility ?? "private")",
            required: true))
      } catch {
        reasons.append("repository visibility could not be verified: \(error.message)")
        guarantees.append(
          AuthorityGuarantee("public trigger exposure", .unavailable, error.message, required: true)
        )
        return inactive()
      }
      guarantees += policyGuarantees(repository: repository, reader: reader)
    case .organization(let org, let groupName):
      do {
        let groups = try reader.runnerGroups(org: org)
        guard let group = groups.first(where: { $0.name == groupName }) else {
          reasons.append("runner group \(groupName) does not exist")
          guarantees.append(
            AuthorityGuarantee("runner group", .unavailable, "group missing", required: true))
          return inactive()
        }
        groupID = group.id
        if group.allowsPublicRepositories {
          reasons.append(
            "runner group \(groupName) allows public repositories; public execution is not qualified"
          )
          guarantees.append(
            AuthorityGuarantee(
              "public trigger exposure", .unavailable, "group admits public repositories",
              required: true))
          return inactive()
        }
        guarantees.append(
          AuthorityGuarantee(
            "runner group", .verified,
            "group \(group.name) (visibility \(group.visibility), public repositories refused)",
            required: true))
        guarantees.append(
          AuthorityGuarantee(
            "workflow restriction", group.restrictedToWorkflows ? .verified : .unavailable,
            group.restrictedToWorkflows
              ? "group is restricted to selected workflows" : "any workflow may target the group"))
      } catch {
        reasons.append("runner groups could not be read: \(error.message)")
        guarantees.append(
          AuthorityGuarantee("runner group", .unavailable, error.message, required: true))
        return inactive()
      }
    }
    // Labels never withhold secrets or narrow GITHUB_TOKEN.
    guarantees.append(
      AuthorityGuarantee(
        "secret withholding", .unavailable,
        "a \(profile.authority.rawValue) label does not withhold workflow or environment secrets from jobs"
      ))
    guarantees.append(
      AuthorityGuarantee(
        "actual runner labels", .operatorAttested,
        "verified against GitHub after each registration; a mismatch retires the runner"))
    let failedRequired = guarantees.filter { $0.required && $0.status != .verified }
    if !failedRequired.isEmpty {
      reasons += failedRequired.map { "\($0.name) is not verified" }
      return inactive()
    }
    return PoolActivationReport(
      pool: name, state: .active, reasons: reasons, guarantees: guarantees, runnerGroupID: groupID)
  }

  /// Repository Actions policy, reported (not required) because labels
  /// cannot change it.
  static func policyGuarantees(repository: RepositoryName, reader: any AuthorityReader)
    -> [AuthorityGuarantee]
  {
    let base = "/repos/\(repository.owner)/\(repository.name)/actions/permissions"
    var out: [AuthorityGuarantee] = []
    if let workflow = try? reader.policy(base + "/workflow", of: repository),
      let level = workflow["default_workflow_permissions"]?.stringValue
    {
      out.append(
        AuthorityGuarantee(
          "GITHUB_TOKEN default", level == "read" ? .verified : .unavailable,
          "default workflow token permissions are \(level); workflows may still request more"))
    } else {
      out.append(
        AuthorityGuarantee(
          "GITHUB_TOKEN default", .unavailable, "policy not readable by the installation"))
    }
    if let approval = try? reader.policy(
      base + "/fork-pr-contributor-approval", of: repository),
      let policy = approval["approval_policy"]?.stringValue
    {
      out.append(
        AuthorityGuarantee("fork pull request approval", .verified, "approval policy: \(policy)"))
    } else {
      out.append(
        AuthorityGuarantee(
          "fork pull request approval", .unavailable, "policy not readable by the installation"))
    }
    return out
  }

  static func satisfies(_ granted: String?, _ needed: String) -> Bool {
    switch (granted, needed) {
    case ("write", _), ("admin", _): true
    case ("read", "read"): true
    default: false
    }
  }
}
