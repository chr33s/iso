import Foundation
import Testing

@testable import IsoCICore

/// Scripted authority reads for pool activation.
final class GitHubFakeAuthority: AuthorityReader, @unchecked Sendable {
  var permissions = ["administration": "write", "actions": "read", "metadata": "read"]
  var account = "octo"
  var selection = "selected"
  var repositories = ["octo/app"]
  var visibility: String? = "private"
  var repositoryFailure: CIError?
  var groups: [GitHubRunnerGroupInfo] = []
  var policies: [String: JSONValue] = [:]

  func installation(_ id: Int64) throws(CIError) -> GitHubInstallationInfo {
    try GitHubInstallationInfo(
      json: [
        "id": .integer(id), "app_id": 42, "account": ["login": .string(account), "type": "User"],
        "repository_selection": .string(selection),
        "permissions": .object(permissions.mapValues(JSONValue.string)),
      ])
  }

  func installationRepositories() throws(CIError) -> (
    repositories: [GitHubRepositoryInfo], truncated: Bool
  ) {
    var out: [GitHubRepositoryInfo] = []
    for (index, name) in repositories.enumerated() {
      out.append(
        try GitHubRepositoryInfo(json: [
          "id": .integer(Int64(index)), "full_name": .string(name), "private": true,
        ]))
    }
    return (out, false)
  }

  func repository(_ repository: RepositoryName) throws(CIError) -> GitHubRepositoryInfo {
    if let repositoryFailure { throw repositoryFailure }
    return try GitHubRepositoryInfo(
      json: [
        "id": 1, "full_name": .string(repository.rawValue),
        "private": .bool(visibility != "public"),
        "visibility": visibility.map(JSONValue.string) ?? .null, "fork": false,
      ])
  }

  func runnerGroups(org: String) throws(CIError) -> [GitHubRunnerGroupInfo] { groups }

  func policy(_ path: String, of repository: RepositoryName) throws(CIError) -> JSONValue? {
    policies[path]
  }
}

@Suite struct GitHubActivationTests {
  private func setup() throws -> (CIConfiguration, InstallationRecord) {
    let configuration = try CIConfiguration.parse(
      CIConfiguration.template(repository: "octo/app", host: "local"))
    let installation = InstallationRecord(
      name: "selected-installation", installationID: 7, appID: 42, account: "octo",
      accountType: "User",
      repositorySelection: "selected", permissions: [:], verifiedAt: 0)
    return (configuration, installation)
  }

  /// Regression fixture: "GitHub secret delivery despite a validation
  /// label". The repository's Actions policy lets jobs receive secrets and a
  /// write-default token; the validation label cannot change that, so the
  /// report says secret withholding is unavailable rather than enforced.
  @Test func validationLabelNeverClaimsSecretWithholding() throws {
    let (configuration, installation) = try setup()
    let reader = GitHubFakeAuthority()
    reader.policies["/repos/octo/app/actions/permissions/workflow"] = [
      "default_workflow_permissions": "write", "can_approve_pull_request_reviews": true,
    ]
    let report = PoolActivation.evaluate(
      pool: "validation", configuration: configuration, installation: installation, reader: reader)
    #expect(report.state == .active)
    let secrets = try #require(report.guarantees.first { $0.name == "secret withholding" })
    #expect(secrets.status == .unavailable)
    #expect(!secrets.required)
    #expect(report.guarantees.first { $0.name == "GITHUB_TOKEN default" }?.status == .unavailable)
    #expect(
      report.guarantees.first { $0.name == "fork pull request approval" }?.status == .unavailable)
    #expect(report.guarantees.filter(\.required).allSatisfy { $0.status == .verified })
  }

  @Test func unverifiableRequiredControlsRefuseAdmission() throws {
    let (configuration, installation) = try setup()
    let reader = GitHubFakeAuthority()
    reader.repositoryFailure = CIError(.githubRefused, "forbidden")
    let report = PoolActivation.evaluate(
      pool: "validation", configuration: configuration, installation: installation, reader: reader)
    #expect(report.state == .inactive)
    #expect(report.reasons.contains { $0.contains("visibility") })
  }

  @Test func publicRepositoriesAreNotGrantedByPrivacyOrName() throws {
    let (configuration, installation) = try setup()
    let reader = GitHubFakeAuthority()
    reader.visibility = "public"
    let report = PoolActivation.evaluate(
      pool: "validation", configuration: configuration, installation: installation, reader: reader)
    #expect(report.state == .inactive)
    #expect(report.reasons.contains { $0.contains("public repository") })
  }

  @Test func privilegedPoolsStayInactive() throws {
    var (configuration, installation) = try setup()
    configuration.profiles["linux-validation"]?.authority = .privileged
    let report = PoolActivation.evaluate(
      pool: "validation", configuration: configuration, installation: installation,
      reader: GitHubFakeAuthority())
    #expect(report.state == .inactive)
    #expect(report.reasons == [PoolActivation.privilegedReason])
  }

  @Test func permissionsAccountAndRepositoryAccessAreRequired() throws {
    let (configuration, installation) = try setup()
    let missing = GitHubFakeAuthority()
    missing.permissions = ["actions": "read"]
    #expect(
      PoolActivation.evaluate(
        pool: "validation", configuration: configuration, installation: installation,
        reader: missing
      ).state == .inactive)
    let otherAccount = GitHubFakeAuthority()
    otherAccount.account = "mallory"
    #expect(
      PoolActivation.evaluate(
        pool: "validation", configuration: configuration, installation: installation,
        reader: otherAccount
      ).state == .inactive)
    let noAccess = GitHubFakeAuthority()
    noAccess.repositories = ["octo/other"]
    #expect(
      PoolActivation.evaluate(
        pool: "validation", configuration: configuration, installation: installation,
        reader: noAccess
      ).state == .inactive)
    #expect(
      PoolActivation.evaluate(
        pool: "validation", configuration: configuration, installation: nil,
        reader: GitHubFakeAuthority()
      ).state == .inactive)
  }

  @Test func sharedScopeAndLabelsAreRefused() throws {
    var (configuration, installation) = try setup()
    configuration.pools["second"] = configuration.pools["validation"]
    let report = PoolActivation.evaluate(
      pool: "validation", configuration: configuration, installation: installation,
      reader: GitHubFakeAuthority())
    #expect(report.state == .inactive)
  }

  @Test func organizationPoolsNeedAPrivateRunnerGroup() throws {
    var (configuration, installation) = try setup()
    configuration.pools["validation"]?.scope = .organization("octo", runnerGroup: "iso")
    let reader = GitHubFakeAuthority()
    reader.permissions = ["organization_self_hosted_runners": "write", "actions": "read"]
    #expect(
      PoolActivation.evaluate(
        pool: "validation", configuration: configuration, installation: installation, reader: reader
      ).state == .inactive)
    reader.groups = [
      try GitHubRunnerGroupInfo(
        json: [
          "id": 9, "name": "iso", "visibility": "selected", "allows_public_repositories": true,
        ])
    ]
    #expect(
      PoolActivation.evaluate(
        pool: "validation", configuration: configuration, installation: installation, reader: reader
      ).state == .inactive)
    reader.groups = [
      try GitHubRunnerGroupInfo(
        json: [
          "id": 9, "name": "iso", "visibility": "selected", "allows_public_repositories": false,
        ])
    ]
    let report = PoolActivation.evaluate(
      pool: "validation", configuration: configuration, installation: installation, reader: reader)
    #expect(report.state == .active)
    #expect(report.runnerGroupID == 9)
  }
}
