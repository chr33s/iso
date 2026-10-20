import Foundation

/// GitHub response models. GitHub adds fields freely, so these readers take
/// the members they need and ignore the rest; every string kept is bounded.

private func field(_ json: JSONValue, _ key: String, _ context: String) throws(CIError) -> JSONValue
{
  guard let value = json[key], value != .null else {
    throw CIError(.githubUnavailable, "GitHub \(context) is missing \(key)")
  }
  return value
}

private func int(_ json: JSONValue, _ key: String, _ context: String) throws(CIError) -> Int64 {
  guard let value = try field(json, key, context).intValue else {
    throw CIError(.githubUnavailable, "GitHub \(context).\(key) is not an integer")
  }
  return value
}

private func string(_ json: JSONValue, _ key: String, _ context: String) throws(CIError) -> String {
  guard let value = try field(json, key, context).stringValue else {
    throw CIError(.githubUnavailable, "GitHub \(context).\(key) is not a string")
  }
  return String(value.prefix(1_024))
}

private func optionalString(_ json: JSONValue, _ key: String) -> String? {
  json[key]?.stringValue.map { String($0.prefix(1_024)) }
}

private func permissionMap(_ json: JSONValue) -> [String: String] {
  var out: [String: String] = [:]
  for (key, value) in json["permissions"]?.objectValue ?? [:] {
    if let text = value.stringValue { out[key] = text }
  }
  return out
}

package struct GitHubAppInfo: Sendable, Equatable {
  package let id: Int64
  package let slug: String
  package let owner: String
  package let clientID: String?
  package let htmlURL: String?
  package let permissions: [String: String]

  package init(json: JSONValue) throws(CIError) {
    id = try int(json, "id", "app")
    slug = try string(json, "slug", "app")
    owner = optionalString(json["owner"] ?? .null, "login") ?? ""
    clientID = optionalString(json, "client_id")
    htmlURL = optionalString(json, "html_url")
    permissions = permissionMap(json)
  }
}

package struct GitHubInstallationInfo: Sendable, Equatable {
  package let id: Int64
  package let appID: Int64
  package let account: String
  package let accountType: String
  package let repositorySelection: String
  package let permissions: [String: String]
  package let suspended: Bool

  package init(json: JSONValue) throws(CIError) {
    id = try int(json, "id", "installation")
    appID = try int(json, "app_id", "installation")
    let account = try field(json, "account", "installation")
    self.account = try string(account, "login", "installation.account")
    accountType = optionalString(account, "type") ?? "User"
    repositorySelection = optionalString(json, "repository_selection") ?? "selected"
    permissions = permissionMap(json)
    suspended = (json["suspended_at"].map { $0 != .null }) ?? false
  }
}

package struct GitHubRepositoryInfo: Sendable, Equatable {
  package let id: Int64
  package let fullName: String
  package let isPrivate: Bool
  /// `public`, `private` or `internal`; nil when GitHub did not say.
  package let visibility: String?
  package let isFork: Bool

  package init(json: JSONValue) throws(CIError) {
    id = try int(json, "id", "repository")
    fullName = try string(json, "full_name", "repository")
    isPrivate = json["private"]?.boolValue ?? false
    visibility = optionalString(json, "visibility")
    isFork = json["fork"]?.boolValue ?? false
  }

  package var isPublic: Bool { visibility.map { $0 == "public" } ?? !isPrivate }
}

/// Manifest conversion result. `privateKeyPEM` and `webhookSecret` are
/// secrets that go straight to the credential store; the client secret is
/// not needed by iso-ci and is never kept.
package struct GitHubManifestConversion: Sendable {
  package let id: Int64
  package let slug: String
  package let owner: String
  package let clientID: String?
  package let htmlURL: String?
  package let privateKeyPEM: RedactedSecret
  package let webhookSecret: RedactedSecret?

  package init(json: JSONValue) throws(CIError) {
    id = try int(json, "id", "manifest conversion")
    slug = try string(json, "slug", "manifest conversion")
    owner = optionalString(json["owner"] ?? .null, "login") ?? ""
    clientID = optionalString(json, "client_id")
    htmlURL = optionalString(json, "html_url")
    guard let pem = json["pem"]?.stringValue, pem.contains("PRIVATE KEY") else {
      throw CIError(.githubUnavailable, "GitHub manifest conversion returned no private key")
    }
    privateKeyPEM = RedactedSecret(pem)
    webhookSecret = json["webhook_secret"]?.stringValue.map(RedactedSecret.init)
  }
}

/// A just-in-time runner configuration. `encoded` is guest-visible JIT
/// material: it is delivered only through guest stdin, never argv or logs.
package struct GitHubJITConfig: Sendable {
  package let runner: GitHubRunnerInfo
  package let encoded: RedactedSecret

  package init(runner: GitHubRunnerInfo, encoded: RedactedSecret) {
    self.runner = runner
    self.encoded = encoded
  }

  package init(json: JSONValue) throws(CIError) {
    runner = try GitHubRunnerInfo(json: try field(json, "runner", "jitconfig"))
    guard let encoded = json["encoded_jit_config"]?.stringValue, !encoded.isEmpty,
      encoded.utf8.count <= 64 << 10
    else { throw CIError(.githubUnavailable, "GitHub returned no JIT configuration") }
    self.encoded = RedactedSecret(encoded)
  }

  /// Hostnames of the GitHub services this runner will contact, read from
  /// the `.runner` and `.credentials` entries of the JIT configuration (a
  /// base64 JSON map of base64 files). GitHub assigns some of them per
  /// account (for example a sharded `pipelines…actions.githubusercontent.com`),
  /// so they are checked against the approved policy before the runner
  /// starts. Only hostnames leave this function; nil when unreadable.
  package func serviceHosts() -> Set<String>? {
    let limits = JSONLimits(maxBytes: 64 << 10, maxKeys: 256, maxArrayElements: 256)
    guard let outer = Data(base64Encoded: encoded.value),
      let files = try? StrictJSON.parse(Array(outer), limits: limits).objectValue
    else { return nil }
    var hosts: Set<String> = []
    for name in [".runner", ".credentials"] {
      guard let raw = files[name]?.stringValue, let decoded = Data(base64Encoded: raw),
        let file = try? StrictJSON.parse(Array(decoded), limits: limits)
      else { return nil }
      Self.collectHosts(file, into: &hosts)
    }
    return hosts.isEmpty ? nil : hosts
  }

  private static func collectHosts(_ value: JSONValue, into hosts: inout Set<String>) {
    switch value {
    case .string(let text):
      if let url = URL(string: text), let scheme = url.scheme?.lowercased(),
        scheme == "https" || scheme == "http", let host = url.host?.lowercased()
      {
        hosts.insert(host)
      }
    case .object(let members): for member in members.values { collectHosts(member, into: &hosts) }
    case .array(let items): for item in items { collectHosts(item, into: &hosts) }
    default: break
    }
  }
}

package struct GitHubRunnerInfo: Sendable, Equatable {
  package let id: Int64
  package let name: String
  /// `online` or `offline`.
  package let status: String
  package let busy: Bool
  package let labels: [String]
  package let runnerGroupID: Int64?

  package init(
    id: Int64, name: String, status: String, busy: Bool, labels: [String], runnerGroupID: Int64?
  ) {
    self.id = id
    self.name = name
    self.status = status
    self.busy = busy
    self.labels = labels
    self.runnerGroupID = runnerGroupID
  }

  package init(json: JSONValue) throws(CIError) {
    id = try int(json, "id", "runner")
    name = try string(json, "name", "runner")
    status = optionalString(json, "status") ?? "offline"
    busy = json["busy"]?.boolValue ?? false
    labels = (json["labels"]?.arrayValue ?? []).compactMap { $0["name"]?.stringValue }
    runnerGroupID = json["runner_group_id"]?.intValue
  }

  /// Case-insensitive label-set comparison, as GitHub routes labels.
  package func hasExactly(_ expected: [String]) -> Bool {
    Set(labels.map { $0.lowercased() }) == Set(expected.map { $0.lowercased() })
  }
}

package struct GitHubRunnerGroupInfo: Sendable, Equatable {
  package let id: Int64
  package let name: String
  /// `all`, `selected` or `private`.
  package let visibility: String
  package let allowsPublicRepositories: Bool
  package let restrictedToWorkflows: Bool

  package init(json: JSONValue) throws(CIError) {
    id = try int(json, "id", "runner group")
    name = try string(json, "name", "runner group")
    visibility = optionalString(json, "visibility") ?? "all"
    allowsPublicRepositories = json["allows_public_repositories"]?.boolValue ?? false
    restrictedToWorkflows = json["restricted_to_workflows"]?.boolValue ?? false
  }
}

package struct GitHubRunInfo: Sendable, Equatable {
  package let id: Int64
  package let runAttempt: Int64
  package let status: String
  package let event: String

  package init(json: JSONValue) throws(CIError) {
    id = try int(json, "id", "workflow run")
    runAttempt = json["run_attempt"]?.intValue ?? 1
    status = optionalString(json, "status") ?? "unknown"
    event = optionalString(json, "event") ?? "unknown"
  }
}

package struct GitHubJobInfo: Sendable, Equatable {
  package let id: Int64
  package let runID: Int64
  package let runAttempt: Int64
  package let repository: RepositoryName
  package let name: String
  /// `queued`, `in_progress`, `completed`, `waiting`, ...
  package let status: String
  package let conclusion: String?
  package let runnerID: Int64?
  package let runnerName: String?
  package let labels: [String]
  package let htmlURL: String?

  package init(
    id: Int64, runID: Int64, runAttempt: Int64, repository: RepositoryName, name: String,
    status: String, conclusion: String?, runnerID: Int64?, runnerName: String?, labels: [String],
    htmlURL: String?
  ) {
    self.id = id
    self.runID = runID
    self.runAttempt = runAttempt
    self.repository = repository
    self.name = name
    self.status = status
    self.conclusion = conclusion
    self.runnerID = runnerID
    self.runnerName = runnerName
    self.labels = labels
    self.htmlURL = htmlURL
  }

  package init(json: JSONValue, repository: RepositoryName) throws(CIError) {
    id = try int(json, "id", "job")
    runID = try int(json, "run_id", "job")
    runAttempt = json["run_attempt"]?.intValue ?? 1
    self.repository = repository
    name = optionalString(json, "name") ?? ""
    status = optionalString(json, "status") ?? "unknown"
    conclusion = optionalString(json, "conclusion")
    runnerID = json["runner_id"]?.intValue
    runnerName = optionalString(json, "runner_name")
    labels = (json["labels"]?.arrayValue ?? []).compactMap(\.stringValue)
    htmlURL = optionalString(json, "html_url")
  }

  package var reference: GitHubJobRef {
    GitHubJobRef(
      repository: repository.rawValue, runID: runID, runAttempt: runAttempt, jobID: id,
      jobName: name, htmlURL: htmlURL, status: status,
      conclusion: status == "completed" ? conclusion : nil)
  }
}
