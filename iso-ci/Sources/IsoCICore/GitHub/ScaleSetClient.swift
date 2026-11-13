import Foundation

/// The GitHub Actions service endpoints runner scale sets use. Their URLs
/// come from GitHub's replies, so each is checked before a token is sent.
package enum ActionsService {
  package static let apiVersion = "6.0-preview"
  /// Every Actions service and message-queue host is below this suffix.
  package static let hostSuffix = ".actions.githubusercontent.com"

  /// An https URL on an Actions service host, without credentials; nil
  /// for anything else, so a token never leaves for another origin.
  package static func validatedURL(_ raw: String) -> URL? {
    guard let components = URLComponents(string: raw), components.scheme == "https",
      let host = components.host?.lowercased(), host.hasSuffix(hostSuffix),
      isExactHostname(host), components.user == nil, components.password == nil,
      components.port == nil || components.port == 443, let url = components.url
    else { return nil }
    return url
  }
}

package struct ScaleSetStatistics: Sendable, Equatable, Codable {
  package var availableJobs: Int64 = 0
  package var acquiredJobs: Int64 = 0
  package var assignedJobs: Int64 = 0
  package var runningJobs: Int64 = 0
  package var registeredRunners: Int64 = 0
  package var busyRunners: Int64 = 0
  package var idleRunners: Int64 = 0

  package init() {}

  package init(json: JSONValue?) {
    guard let json else { return }
    availableJobs = json["totalAvailableJobs"]?.intValue ?? 0
    acquiredJobs = json["totalAcquiredJobs"]?.intValue ?? 0
    assignedJobs = json["totalAssignedJobs"]?.intValue ?? 0
    runningJobs = json["totalRunningJobs"]?.intValue ?? 0
    registeredRunners = json["totalRegisteredRunners"]?.intValue ?? 0
    busyRunners = json["totalBusyRunners"]?.intValue ?? 0
    idleRunners = json["totalIdleRunners"]?.intValue ?? 0
  }

  package var waitingJobs: Int64 { max(0, assignedJobs - runningJobs) }
}

package struct ScaleSetJobMessage: Sendable, Equatable {
  package enum Kind: String, Sendable, CaseIterable {
    case available = "JobAvailable"
    case assigned = "JobAssigned"
    case started = "JobStarted"
    case completed = "JobCompleted"
  }

  package let kind: Kind
  package let runnerRequestID: Int64
  package let repository: RepositoryName?
  package let workflowRunID: Int64?
  package let eventName: String?
  package let jobID: String?
  package let jobDisplayName: String?
  package let queueTime: EpochSeconds?
  package let runnerID: Int64?
  package let runnerName: String?
  package let result: String?

  package init(
    kind: Kind, runnerRequestID: Int64, repository: RepositoryName?, workflowRunID: Int64?,
    eventName: String?, jobID: String? = nil, jobDisplayName: String? = nil,
    queueTime: EpochSeconds? = nil, runnerID: Int64? = nil, runnerName: String? = nil,
    result: String? = nil
  ) {
    self.kind = kind
    self.runnerRequestID = runnerRequestID
    self.repository = repository
    self.workflowRunID = workflowRunID
    self.eventName = eventName
    self.jobID = jobID
    self.jobDisplayName = jobDisplayName
    self.queueTime = queueTime
    self.runnerID = runnerID
    self.runnerName = runnerName
    self.result = result
  }

  package init?(json: JSONValue) {
    guard let raw = json["messageType"]?.stringValue, let kind = Kind(rawValue: raw),
      let request = json["runnerRequestId"]?.intValue
    else { return nil }
    self.kind = kind
    runnerRequestID = request
    if let owner = json["ownerName"]?.stringValue, let name = json["repositoryName"]?.stringValue {
      repository = try? RepositoryName("\(owner)/\(name)")
    } else {
      repository = nil
    }
    workflowRunID = json["workflowRunId"]?.intValue
    eventName = json["eventName"]?.stringValue.map { CIError.bounded(String($0.prefix(64))) }
    jobID = json["jobId"]?.stringValue.map { String($0.prefix(128)) }
    jobDisplayName = json["jobDisplayName"]?.stringValue.map {
      CIError.bounded(String($0.prefix(200)))
    }
    queueTime = json["queueTime"]?.stringValue.flatMap(Self.epoch)
    runnerID = json["runnerId"]?.intValue
    runnerName = json["runnerName"]?.stringValue.map { String($0.prefix(128)) }
    result = json["result"]?.stringValue.map { String($0.prefix(64)) }
  }

  /// The job's identity in this session: its runner request when GitHub
  /// numbers one (elastic scale sets), else its job id (GitHub assigns jobs
  /// to a non-elastic scale set with `runnerRequestId` 0).
  package var key: String { runnerRequestID != 0 ? "r\(runnerRequestID)" : "j\(jobID ?? "0")" }

  static func epoch(_ text: String) -> EpochSeconds? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date =
      formatter.date(from: text)
      ?? {
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
      }()
    guard let date, date.timeIntervalSince1970 > 0 else { return nil }
    return EpochSeconds(date.timeIntervalSince1970)
  }
}

package struct ScaleSetMessage: Sendable, Equatable {
  package let id: Int64
  package let type: String
  package let jobs: [ScaleSetJobMessage]
  package let statistics: ScaleSetStatistics

  package init(id: Int64, type: String, jobs: [ScaleSetJobMessage], statistics: ScaleSetStatistics)
  {
    self.id = id
    self.type = type
    self.jobs = jobs
    self.statistics = statistics
  }

  package static let maxJobsPerMessage = 1_000

  package init(json: JSONValue) throws(CIError) {
    guard let id = json["messageId"]?.intValue, let type = json["messageType"]?.stringValue else {
      throw CIError(.githubUnavailable, "the scale set message is incomplete")
    }
    self.id = id
    self.type = type
    statistics = ScaleSetStatistics(json: json["statistics"])
    var jobs: [ScaleSetJobMessage] = []
    if type == "RunnerScaleSetJobMessages", let body = json["body"]?.stringValue {
      let parsed = try StrictJSON.parse(Array(body.utf8), limits: .github)
      for item in (parsed.arrayValue ?? []).prefix(Self.maxJobsPerMessage) {
        if let job = ScaleSetJobMessage(json: item) { jobs.append(job) }
      }
    }
    self.jobs = jobs
  }
}

package struct ScaleSetInfo: Sendable, Equatable {
  package let id: Int64
  package let name: String
  package let runnerGroupID: Int64?
  /// Elastic scale sets are offered jobs (`JobAvailable`) and take only the
  /// ones the listener acquires. GitHub assigns jobs to a non-elastic scale
  /// set directly. Creating an elastic one needs Administer permission.
  package let elastic: Bool

  package init(id: Int64, name: String, runnerGroupID: Int64?, elastic: Bool = false) {
    self.id = id
    self.name = name
    self.runnerGroupID = runnerGroupID
    self.elastic = elastic
  }

  init(json: JSONValue) throws(CIError) {
    guard let id = json["id"]?.intValue, let name = json["name"]?.stringValue else {
      throw CIError(.githubUnavailable, "the scale set record is incomplete")
    }
    let setting = json["runnerSetting"] ?? json["RunnerSetting"]
    self.init(
      id: id, name: name, runnerGroupID: json["runnerGroupId"]?.intValue,
      elastic: setting?["isElastic"]?.boolValue ?? false)
  }
}

/// A message session: the queue URL and its bearer are secrets of this
/// controller instance.
package struct ScaleSetSession: Sendable {
  package let id: String
  package let queueURL: URL
  package let queueToken: RedactedSecret
  package let statistics: ScaleSetStatistics

  package init(
    id: String, queueURL: URL, queueToken: RedactedSecret, statistics: ScaleSetStatistics
  ) {
    self.id = id
    self.queueURL = queueURL
    self.queueToken = queueToken
    self.statistics = statistics
  }

  init(json: JSONValue) throws(CIError) {
    guard let id = json["sessionId"]?.stringValue, (1...128).contains(id.utf8.count),
      id.unicodeScalars.allSatisfy(isSafeNameScalar),
      let raw = json["messageQueueUrl"]?.stringValue, let url = ActionsService.validatedURL(raw),
      let token = json["messageQueueAccessToken"]?.stringValue, !token.isEmpty,
      token.utf8.count <= 16_384
    else { throw CIError(.githubUnavailable, "GitHub returned no usable message session") }
    self.init(
      id: id, queueURL: url, queueToken: RedactedSecret(token),
      statistics: ScaleSetStatistics(json: json["statistics"]))
  }
}

package struct ActionsServiceConnection: Sendable {
  package let url: URL
  package let token: RedactedSecret
  package let expiresAt: EpochSeconds

  package init(url: URL, token: RedactedSecret, expiresAt: EpochSeconds) {
    self.url = url
    self.token = token
    self.expiresAt = expiresAt
  }
}

/// The runner scale set protocol (the long-poll message session GitHub's
/// Actions Runner Controller uses), over the same bounded transport as the
/// REST client. Tokens travel only to validated Actions service hosts.
package final class ScaleSetClient: Sendable {
  /// The admin token GitHub issues lasts about an hour; refresh early.
  package static let connectionLifetime: EpochSeconds = 45 * 60
  /// Longer than GitHub's ~50 s long-poll window, so an empty poll ends
  /// with GitHub's 202, not a client timeout.
  package static let pollTimeoutSeconds: Double = 60

  let http: any GitHubHTTP

  package init(http: any GitHubHTTP) { self.http = http }

  package func connect(
    scope: GitHubRunnerScope, api: GitHubAPI, installationToken: RedactedSecret, now: EpochSeconds
  ) throws(CIError) -> ActionsServiceConnection {
    let registration = try api.registrationToken(scope: scope, token: installationToken)
    let admin = try api.actionsServiceAdmin(scope: scope, registration: registration)
    return ActionsServiceConnection(
      url: admin.url, token: admin.token, expiresAt: now + Self.connectionLifetime)
  }

  package func scaleSet(named name: String, groupID: Int64, connection: ActionsServiceConnection)
    throws(CIError) -> ScaleSetInfo?
  {
    let reply = try send(
      .get, connection, path: "/_apis/runtime/runnerscalesets",
      query: [("runnerGroupId", String(groupID)), ("name", name)])
    let values = reply?["value"]?.arrayValue ?? []
    let matches = values.compactMap { try? ScaleSetInfo(json: $0) }.filter { $0.name == name }
    guard matches.count <= 1 else {
      throw CIError(.conflict, "GitHub reports \(matches.count) scale sets named \(name)")
    }
    return matches.first
  }

  /// Not idempotent: the caller looks the scale set up again before any
  /// retry after a lost reply.
  package func createScaleSet(
    named name: String, groupID: Int64, labels: [String], elastic: Bool,
    connection: ActionsServiceConnection
  ) throws(CIError) -> ScaleSetInfo {
    let body: JSONValue = [
      "name": .string(name), "runnerGroupId": .integer(groupID),
      "labels": .array(labels.map { ["name": .string($0), "type": "System"] }),
      // Runners are pinned and single-use (scale-set runners are ephemeral
      // by default). `isElastic` needs Administer permission; App
      // installations get 403 and the caller falls back to non-elastic.
      "runnerSetting": elastic
        ? ["disableUpdate": true, "isElastic": true] : ["disableUpdate": true],
    ]
    guard
      let json = try send(
        .post, connection, path: "/_apis/runtime/runnerscalesets", body: body, idempotent: false)
    else { throw CIError(.githubUnavailable, "GitHub returned no scale set") }
    return try ScaleSetInfo(json: json)
  }

  package func createSession(scaleSet: Int64, owner: String, connection: ActionsServiceConnection)
    throws(CIError) -> ScaleSetSession
  {
    guard
      let json = try send(
        .post, connection, path: "/_apis/runtime/runnerscalesets/\(scaleSet)/sessions",
        body: ["ownerName": .string(owner)], idempotent: false)
    else { throw CIError(.githubUnavailable, "GitHub returned no session") }
    return try ScaleSetSession(json: json)
  }

  package func refreshSession(
    scaleSet: Int64, session: String, connection: ActionsServiceConnection
  ) throws(CIError) -> ScaleSetSession {
    guard
      let json = try send(
        .patch, connection, path: "/_apis/runtime/runnerscalesets/\(scaleSet)/sessions/\(session)")
    else { throw CIError(.githubUnavailable, "GitHub returned no session") }
    return try ScaleSetSession(json: json)
  }

  package func deleteSession(scaleSet: Int64, session: String, connection: ActionsServiceConnection)
    throws(CIError)
  {
    _ = try send(
      .delete, connection, path: "/_apis/runtime/runnerscalesets/\(scaleSet)/sessions/\(session)",
      expect: [200, 204, 404])
  }

  /// One long poll. Nil when no message arrived within the poll window.
  /// An expired queue token is `unauthorized`; the caller refreshes the
  /// session and polls again.
  package func poll(session: ScaleSetSession, lastMessageID: Int64, maxCapacity: UInt32)
    throws(CIError) -> ScaleSetMessage?
  {
    var components = URLComponents(url: session.queueURL, resolvingAgainstBaseURL: false)
    let existing = components?.queryItems ?? []
    components?.queryItems =
      existing + [
        URLQueryItem(name: "lastMessageId", value: String(lastMessageID)),
        URLQueryItem(name: "maxCapacity", value: String(maxCapacity)),
      ]
    guard let url = components?.url else { throw CIError.invalid("invalid message queue URL") }
    let response = try http.send(
      GitHubHTTPRequest(
        method: .get, url: url, headers: queueHeaders(session, maxCapacity: maxCapacity),
        timeoutSeconds: Self.pollTimeoutSeconds))
    switch response.status {
    case 200:
      return try ScaleSetMessage(json: try StrictJSON.parse(response.body, limits: .github))
    case 202, 204:
      return nil
    case 401, 403:
      throw CIError(.unauthorized, "the message session token expired")
    default:
      throw Self.failure(response.status, "message poll")
    }
  }

  package func deleteMessage(_ id: Int64, session: ScaleSetSession) throws(CIError) {
    let url = session.queueURL.appendingPathComponent(String(id))
    let response = try http.send(
      GitHubHTTPRequest(method: .delete, url: url, headers: queueHeaders(session, maxCapacity: nil))
    )
    switch response.status {
    case 200, 204, 404: return
    case 401, 403: throw CIError(.unauthorized, "the message session token expired")
    default: throw Self.failure(response.status, "message delete")
    }
  }

  /// Claims jobs for this scale set; returns the request ids GitHub
  /// granted. Only jobs that passed the job policy are ever sent.
  package func acquireJobs(
    _ requests: [Int64], scaleSet: Int64, connection: ActionsServiceConnection
  )
    throws(CIError) -> [Int64]
  {
    guard !requests.isEmpty else { return [] }
    let json = try send(
      .post, connection, path: "/_apis/runtime/runnerscalesets/\(scaleSet)/acquirejobs",
      body: .array(requests.map { .integer($0) }), idempotent: false)
    return (json?["value"]?.arrayValue ?? []).compactMap(\.intValue)
  }

  /// Not idempotent; a lost reply is resolved by runner name like REST JIT.
  package func generateJIT(
    scaleSet: Int64, name: String, workFolder: String, connection: ActionsServiceConnection
  ) throws(CIError) -> GitHubJITConfig {
    guard
      let json = try send(
        .post, connection, path: "/_apis/runtime/runnerscalesets/\(scaleSet)/generatejitconfig",
        body: ["name": .string(name), "workFolder": .string(workFolder)], idempotent: false)
    else { throw CIError(.githubUnavailable, "GitHub returned no JIT configuration") }
    guard let runner = json["runner"], let encoded = json["encodedJITConfig"]?.stringValue else {
      throw CIError(.githubUnavailable, "GitHub returned no JIT configuration")
    }
    return try GitHubJITConfig(
      json: ["runner": runner, "encoded_jit_config": .string(encoded)])
  }

  // MARK: Transport

  private func queueHeaders(_ session: ScaleSetSession, maxCapacity: UInt32?) -> [String: String] {
    var headers = [
      "Authorization": "Bearer " + session.queueToken.value,
      "Accept": "application/json; api-version=\(ActionsService.apiVersion)",
      "User-Agent": IsoCIVersion.clientBuild,
    ]
    if let maxCapacity { headers["X-ScaleSetMaxCapacity"] = String(maxCapacity) }
    return headers
  }

  private func send(
    _ method: GitHubHTTPMethod, _ connection: ActionsServiceConnection, path: String,
    query: [(String, String)] = [], body: JSONValue? = nil, idempotent: Bool = true,
    expect: Set<Int> = [200, 201]
  ) throws(CIError) -> JSONValue? {
    guard path.hasPrefix("/"), !path.contains(".."),
      var components = URLComponents(url: connection.url, resolvingAgainstBaseURL: false)
    else { throw CIError.invalid("invalid Actions service path") }
    let base =
      components.percentEncodedPath.hasSuffix("/")
      ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
    components.percentEncodedPath = base + path
    components.queryItems =
      query.map { URLQueryItem(name: $0.0, value: $0.1) }
      + [URLQueryItem(name: "api-version", value: ActionsService.apiVersion)]
    guard let url = components.url, ActionsService.validatedURL(url.absoluteString) != nil else {
      throw CIError.invalid("invalid Actions service URL")
    }
    var headers = [
      "Authorization": "Bearer " + connection.token.value, "Accept": "application/json",
      "User-Agent": IsoCIVersion.clientBuild,
    ]
    if body != nil { headers["Content-Type"] = "application/json" }
    let response: GitHubHTTPResponse
    do {
      response = try http.send(
        GitHubHTTPRequest(method: method, url: url, headers: headers, body: body?.canonical))
    } catch {
      throw CIError(
        .githubUnavailable, error.message, details: idempotent ? [:] : ["uncertain": "true"])
    }
    guard expect.contains(response.status) else {
      if response.status >= 500 && !idempotent {
        throw CIError(
          .githubUnavailable, "Actions service error \(response.status)",
          details: ["uncertain": "true"])
      }
      throw Self.failure(response.status, path)
    }
    return response.body.isEmpty ? nil : try StrictJSON.parse(response.body, limits: .github)
  }

  static func failure(_ status: Int, _ context: String) -> CIError {
    switch status {
    case 401: CIError(.unauthorized, "the Actions service refused the credentials (\(context))")
    case 429, 500...: CIError(.githubUnavailable, "the Actions service is unavailable (\(status))")
    default: CIError(.githubRefused, "the Actions service refused \(context) (\(status))")
    }
  }
}
