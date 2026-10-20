import Foundation

/// How one GitHub request authenticates. Values are secrets.
package enum GitHubAuthorization: Sendable {
  case none
  /// An App GitHubJWT (App-level endpoints only).
  case app(RedactedSecret)
  /// An installation access token.
  case installation(RedactedSecret)

  var header: String? {
    switch self {
    case .none: nil
    case .app(let jwt): "Bearer " + jwt.value
    case .installation(let token): "Bearer " + token.value
    }
  }
}

/// Typed GitHub REST transport: strict JSON parsing, bounded retries with
/// backoff for rate limits and server errors, and capped same-origin
/// pagination. Error text never includes request headers or bodies.
package final class GitHubAPI: Sendable {
  package static let apiVersion = "2022-11-28"
  package static let defaultBase = URL(string: "https://api.github.com")!

  package let http: any GitHubHTTP
  package let baseURL: URL
  let sleeper: any GitHubSleeper
  package let maxRetries: Int
  package let maxPages: Int
  package let maxBackoffSeconds: Double

  package init(
    http: any GitHubHTTP, baseURL: URL = GitHubAPI.defaultBase,
    sleeper: any GitHubSleeper = GitHubThreadSleeper(),
    maxRetries: Int = 4, maxPages: Int = 10, maxBackoffSeconds: Double = 60
  ) {
    self.http = http
    self.baseURL = baseURL
    self.sleeper = sleeper
    self.maxRetries = maxRetries
    self.maxPages = maxPages
    self.maxBackoffSeconds = maxBackoffSeconds
  }

  /// One parsed response.
  package struct Reply: Sendable {
    package let status: Int
    package let headers: [String: String]
    package let json: JSONValue?
  }

  package func url(_ path: String, query: [(String, String)] = []) throws(CIError) -> URL {
    guard path.hasPrefix("/"), !path.contains(".."), !path.contains("//") else {
      throw CIError.invalid("invalid GitHub API path")
    }
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      throw CIError.invalid("invalid GitHub API base URL")
    }
    components.percentEncodedPath =
      (components.percentEncodedPath.hasSuffix("/")
        ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath) + path
    if !query.isEmpty {
      components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    }
    guard let url = components.url else { throw CIError.invalid("invalid GitHub API URL") }
    return url
  }

  /// Sends one request. `idempotent: false` (for example JIT creation)
  /// retries only when GitHub definitely refused the request (rate limit);
  /// a server error or lost reply is surfaced as `githubUnavailable` with
  /// `details["uncertain"] = "true"`, never blindly re-sent.
  package func send(
    _ method: GitHubHTTPMethod, url: URL, auth: GitHubAuthorization, body: JSONValue? = nil,
    idempotent: Bool = true, expect: Set<Int> = [200]
  ) throws(CIError) -> Reply {
    var headers = [
      "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": Self.apiVersion,
      "User-Agent": IsoCIVersion.clientBuild,
    ]
    if let header = auth.header { headers["Authorization"] = header }
    if body != nil { headers["Content-Type"] = "application/json" }
    let request = GitHubHTTPRequest(
      method: method, url: url, headers: headers, body: body?.canonical)
    var attempt = 0
    while true {
      let response: GitHubHTTPResponse
      do {
        response = try http.send(request)
      } catch {
        if idempotent && attempt < maxRetries {
          backoff(attempt: attempt, retryAfter: nil)
          attempt += 1
          continue
        }
        throw CIError(
          .githubUnavailable, error.message, details: idempotent ? [:] : ["uncertain": "true"])
      }
      if expect.contains(response.status) {
        let json: JSONValue? =
          response.body.isEmpty ? nil : try StrictJSON.parse(response.body, limits: .github)
        return Reply(status: response.status, headers: response.headers, json: json)
      }
      let rateLimited =
        response.status == 429
        || (response.status == 403
          && (response.headers["retry-after"] != nil
            || response.headers["x-ratelimit-remaining"] == "0"))
      let serverError = response.status >= 500
      if attempt < maxRetries && (rateLimited || (serverError && idempotent)) {
        backoff(attempt: attempt, retryAfter: retryAfter(response))
        attempt += 1
        continue
      }
      throw failure(response, path: url.path, uncertain: serverError && !idempotent)
    }
  }

  private func retryAfter(_ response: GitHubHTTPResponse) -> Double? {
    if let raw = response.headers["retry-after"], let seconds = Double(raw), seconds >= 0 {
      return seconds
    }
    if response.headers["x-ratelimit-remaining"] == "0",
      let raw = response.headers["x-ratelimit-reset"],
      let reset = Double(raw)
    {
      return max(0, reset - Date().timeIntervalSince1970)
    }
    return nil
  }

  private func backoff(attempt: Int, retryAfter: Double?) {
    let exponential = Double(1 << min(attempt, 6))
    sleeper.sleep(seconds: min(retryAfter ?? exponential, maxBackoffSeconds))
  }

  private func failure(_ response: GitHubHTTPResponse, path: String, uncertain: Bool) -> CIError {
    var message = "GitHub returned HTTP \(response.status)"
    if let json = try? StrictJSON.parse(response.body, limits: .github),
      let text = json["message"]?.stringValue
    {
      message += ": " + String(text.prefix(200))
    }
    var details = ["status": String(response.status)]
    if uncertain { details["uncertain"] = "true" }
    let code: CIError.Code =
      switch response.status {
      case 401: .unauthorized
      case 404: .notFound
      case 409: .conflict
      case 429: .githubUnavailable
      case 500...: .githubUnavailable
      default: .githubRefused
      }
    return CIError(code, message, details: details)
  }

  /// GETs every page of a list endpoint, following only same-origin
  /// `rel="next"` links and stopping at `maxPages`. `extract` returns the
  /// items of one page.
  package func paginate(
    _ path: String, query: [(String, String)] = [], auth: GitHubAuthorization,
    perPage: Int = 100, pageLimit: Int? = nil,
    extract: (JSONValue) throws(CIError) -> [JSONValue]
  ) throws(CIError) -> (items: [JSONValue], truncated: Bool) {
    var next: URL? = try url(path, query: query + [("per_page", String(perPage))])
    var items: [JSONValue] = []
    var pages = 0
    while let current = next {
      guard pages < min(pageLimit ?? maxPages, maxPages) else { return (items, true) }
      let reply = try send(.get, url: current, auth: auth)
      guard let json = reply.json else { throw CIError(.githubUnavailable, "empty GitHub page") }
      items += try extract(json)
      pages += 1
      next = nextLink(reply.headers["link"])
    }
    return (items, false)
  }

  /// The `rel="next"` target when it has the API's own scheme, host and port.
  package func nextLink(_ header: String?) -> URL? {
    guard let header else { return nil }
    for part in header.split(separator: ",") {
      let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
      guard pieces.count >= 2, pieces[1...].contains(#"rel="next""#),
        pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">"),
        let target = URL(string: String(pieces[0].dropFirst().dropLast()))
      else { continue }
      guard target.scheme == baseURL.scheme, target.host == baseURL.host,
        target.port == baseURL.port
      else { return nil }
      return target
    }
    return nil
  }
}

/// Where runners register: one repository or one organization.
package enum GitHubRunnerScope: Sendable, Equatable, Hashable {
  case repository(RepositoryName)
  case organization(String)

  package init(_ scope: GitHubScope) {
    switch scope {
    case .repository(let repository): self = .repository(repository)
    case .organization(let org, _): self = .organization(org)
    }
  }

  var prefix: String {
    switch self {
    case .repository(let repository): "/repos/\(repository.owner)/\(repository.name)"
    case .organization(let org): "/orgs/\(org)"
    }
  }

  package var owner: String {
    switch self {
    case .repository(let repository): repository.owner
    case .organization(let org): org
    }
  }

  package var description: String {
    switch self {
    case .repository(let repository): "repository:\(repository.rawValue)"
    case .organization(let org): "organization:\(org)"
    }
  }
}

// MARK: - Typed endpoints

extension GitHubAPI {
  package func app(jwt: RedactedSecret) throws(CIError) -> GitHubAppInfo {
    try GitHubAppInfo(json: try required(try send(.get, url: try url("/app"), auth: .app(jwt))))
  }

  package func installation(_ id: Int64, jwt: RedactedSecret) throws(CIError)
    -> GitHubInstallationInfo
  {
    try GitHubInstallationInfo(
      json: try required(try send(.get, url: try url("/app/installations/\(id)"), auth: .app(jwt))))
  }

  /// `GET /repos/{owner}/{repo}/installation`: this App's installation that
  /// covers `repository`, if any.
  package func repositoryInstallation(_ repository: RepositoryName, jwt: RedactedSecret)
    throws(CIError) -> GitHubInstallationInfo?
  {
    let reply = try send(
      .get, url: try url("/repos/\(repository.owner)/\(repository.name)/installation"),
      auth: .app(jwt), expect: [200, 404])
    guard reply.status == 200 else { return nil }
    return try GitHubInstallationInfo(json: try required(reply))
  }

  /// `POST /app/installations/{id}/access_tokens`, optionally narrowed to
  /// repositories and permissions.
  package func createInstallationToken(
    _ id: Int64, jwt: RedactedSecret, repositories: [String]?, permissions: [String: String]?
  ) throws(CIError) -> (token: RedactedSecret, expiresAt: EpochSeconds) {
    var body: [String: JSONValue] = [:]
    if let repositories { body["repositories"] = .array(repositories.map { .string($0) }) }
    if let permissions { body["permissions"] = .object(permissions.mapValues { .string($0) }) }
    let reply = try send(
      .post, url: try url("/app/installations/\(id)/access_tokens"), auth: .app(jwt),
      body: .object(body), expect: [201])
    var r = try ObjectReader(try required(reply), field: "token")
    let token = try r.string("token")
    let expires = try r.string("expires_at")
    guard let date = ISO8601DateFormatter().date(from: expires) else {
      throw CIError(.githubUnavailable, "GitHub returned an unreadable token expiry")
    }
    return (RedactedSecret(token), EpochSeconds(max(0, date.timeIntervalSince1970)))
  }

  /// Repositories the installation can access (capped).
  package func installationRepositories(token: RedactedSecret) throws(CIError) -> (
    repositories: [GitHubRepositoryInfo], truncated: Bool
  ) {
    let page = try paginate("/installation/repositories", auth: .installation(token)) {
      (json) throws(CIError) in json["repositories"]?.arrayValue ?? []
    }
    var out: [GitHubRepositoryInfo] = []
    for item in page.items { out.append(try GitHubRepositoryInfo(json: item)) }
    return (out, page.truncated)
  }

  /// `POST /app-manifests/{code}/conversions` (unauthenticated, single use).
  package func convertManifest(code: String) throws(CIError) -> GitHubManifestConversion {
    guard (1...200).contains(code.utf8.count),
      code.unicodeScalars.allSatisfy({ isSafeNameScalar($0) })
    else { throw CIError.invalid("invalid manifest code") }
    let reply = try send(
      .post, url: try url("/app-manifests/\(code)/conversions"), auth: .none, body: nil,
      idempotent: false, expect: [201])
    return try GitHubManifestConversion(json: try required(reply))
  }

  // Runners

  package func generateJITConfig(
    scope: GitHubRunnerScope, name: String, runnerGroupID: Int64, labels: [String],
    workFolder: String,
    token: RedactedSecret
  ) throws(CIError) -> GitHubJITConfig {
    let body: JSONValue = [
      "name": .string(name), "runner_group_id": .integer(runnerGroupID),
      "labels": .array(labels.map { .string($0) }), "work_folder": .string(workFolder),
    ]
    let reply = try send(
      .post, url: try url(scope.prefix + "/actions/runners/generate-jitconfig"),
      auth: .installation(token), body: body, idempotent: false, expect: [201])
    return try GitHubJITConfig(json: try required(reply))
  }

  /// Runners in `scope`, optionally filtered by exact name.
  package func runners(scope: GitHubRunnerScope, name: String?, token: RedactedSecret)
    throws(CIError)
    -> [GitHubRunnerInfo]
  {
    let page = try paginate(
      scope.prefix + "/actions/runners", query: name.map { [("name", $0)] } ?? [],
      auth: .installation(token)
    ) { (json) throws(CIError) in json["runners"]?.arrayValue ?? [] }
    var out: [GitHubRunnerInfo] = []
    for item in page.items { out.append(try GitHubRunnerInfo(json: item)) }
    if let name { out = out.filter { $0.name == name } }
    return out
  }

  /// One runner, or nil when GitHub no longer has it.
  package func runner(scope: GitHubRunnerScope, id: Int64, token: RedactedSecret) throws(CIError)
    -> GitHubRunnerInfo?
  {
    do {
      return try GitHubRunnerInfo(
        json: try required(
          try send(
            .get, url: try url(scope.prefix + "/actions/runners/\(id)"), auth: .installation(token))
        ))
    } catch  where error.code == .notFound {
      return nil
    }
  }

  /// Deletes one runner by id. Returns false when it was already gone.
  @discardableResult
  package func deleteRunner(scope: GitHubRunnerScope, id: Int64, token: RedactedSecret)
    throws(CIError) -> Bool
  {
    do {
      _ = try send(
        .delete, url: try url(scope.prefix + "/actions/runners/\(id)"), auth: .installation(token),
        expect: [204])
      return true
    } catch  where error.code == .notFound {
      return false
    }
  }

  package func runnerGroups(org: String, token: RedactedSecret) throws(CIError)
    -> [GitHubRunnerGroupInfo]
  {
    let page = try paginate("/orgs/\(org)/actions/runner-groups", auth: .installation(token)) {
      (json) throws(CIError) in json["runner_groups"]?.arrayValue ?? []
    }
    var out: [GitHubRunnerGroupInfo] = []
    for item in page.items { out.append(try GitHubRunnerGroupInfo(json: item)) }
    return out
  }

  // Jobs and runs

  /// With `newest`, only the first page of that many runs (newest first).
  package func workflowRuns(
    repository: RepositoryName, status: String, newest: Int? = nil, token: RedactedSecret
  ) throws(CIError) -> [GitHubRunInfo] {
    let page = try paginate(
      "/repos/\(repository.owner)/\(repository.name)/actions/runs", query: [("status", status)],
      auth: .installation(token), perPage: newest ?? 100, pageLimit: newest.map { _ in 1 }
    ) { (json) throws(CIError) in json["workflow_runs"]?.arrayValue ?? [] }
    var out: [GitHubRunInfo] = []
    for item in page.items { out.append(try GitHubRunInfo(json: item)) }
    return out
  }

  package func jobs(repository: RepositoryName, runID: Int64, token: RedactedSecret) throws(CIError)
    -> [GitHubJobInfo]
  {
    let page = try paginate(
      "/repos/\(repository.owner)/\(repository.name)/actions/runs/\(runID)/jobs",
      query: [("filter", "latest")], auth: .installation(token)
    ) { (json) throws(CIError) in json["jobs"]?.arrayValue ?? [] }
    var out: [GitHubJobInfo] = []
    for item in page.items { out.append(try GitHubJobInfo(json: item, repository: repository)) }
    return out
  }

  package func job(repository: RepositoryName, id: Int64, token: RedactedSecret) throws(CIError)
    -> GitHubJobInfo
  {
    try GitHubJobInfo(
      json: try required(
        try send(
          .get, url: try url("/repos/\(repository.owner)/\(repository.name)/actions/jobs/\(id)"),
          auth: .installation(token))), repository: repository)
  }

  // Repository and Actions policy reads (authority validation)

  package func repository(_ repository: RepositoryName, token: RedactedSecret) throws(CIError)
    -> GitHubRepositoryInfo
  {
    try GitHubRepositoryInfo(
      json: try required(
        try send(
          .get, url: try url("/repos/\(repository.owner)/\(repository.name)"),
          auth: .installation(token)))
    )
  }

  /// A policy document, or nil when the endpoint is unavailable to this
  /// installation (403/404): the guarantee is then reported unavailable.
  package func optionalPolicy(_ path: String, token: RedactedSecret) throws(CIError) -> JSONValue? {
    do {
      return try send(.get, url: try url(path), auth: .installation(token)).json
    } catch  where error.code == .notFound || error.code == .githubRefused {
      return nil
    }
  }

  private func required(_ reply: Reply) throws(CIError) -> JSONValue {
    guard let json = reply.json else {
      throw CIError(.githubUnavailable, "GitHub returned an empty body")
    }
    return json
  }
}
