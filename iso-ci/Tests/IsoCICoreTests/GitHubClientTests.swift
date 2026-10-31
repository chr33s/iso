import Foundation
import Security
import Synchronization
import Testing

@testable import IsoCICore

private func isoDate(_ seconds: EpochSeconds) -> String {
  ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
}

private func der(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
  var length: [UInt8]
  if body.count < 0x80 {
    length = [UInt8(body.count)]
  } else {
    var count = body.count
    var bytes: [UInt8] = []
    while count > 0 {
      bytes.insert(UInt8(count & 0xFF), at: 0)
      count >>= 8
    }
    length = [0x80 | UInt8(bytes.count)] + bytes
  }
  return [tag] + length + body
}

@Suite struct GitHubAuthTests {
  @Test func jwtHasTheRequiredShapeAndVerifies() throws {
    let app = try GitHubTestApp.make()
    let clock = TestClock()
    let auth = GitHubAppAuth(
      app: app.record, credentials: app.credentials,
      api: GitHubAPI(http: ScriptedGitHubHTTP(), sleeper: RecordingGitHubSleeper()), clock: clock)
    let token = try auth.jwt()
    #expect("\(token)" == "<redacted>")
    let parts = token.value.split(separator: ".").map(String.init)
    #expect(parts.count == 3)
    let header = try StrictJSON.parse(
      try #require(GitHubJWT.decodeBase64URL(parts[0])), limits: .control)
    let payload = try StrictJSON.parse(
      try #require(GitHubJWT.decodeBase64URL(parts[1])), limits: .control)
    #expect(header == ["alg": "RS256", "typ": "JWT"])
    #expect(payload["iss"] == "Iv1.test")
    #expect(payload["iat"]?.intValue == Int64(clock.now()) - 60)
    let exp = try #require(payload["exp"]?.intValue)
    #expect(exp - Int64(clock.now()) <= 600)
    let signature = try #require(GitHubJWT.decodeBase64URL(parts[2]))
    let input = Data((parts[0] + "." + parts[1]).utf8)
    var error: Unmanaged<CFError>?
    #expect(
      SecKeyVerifySignature(
        app.publicKey, .rsaSignatureMessagePKCS1v15SHA256, input as CFData,
        Data(signature) as CFData,
        &error))
  }

  @Test func acceptsPKCS8WrappedKeysAndRejectsOthers() throws {
    let key = try makeGitHubTestRSAKey()
    let pkcs1 = try #require(GitHubAppPrivateKey.pemBody(key.pem, label: "RSA PRIVATE KEY"))
    let algorithm = der(
      0x30, der(0x06, [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]) + [0x05, 0x00])
    let pkcs8 = der(0x30, der(0x02, [0x00]) + algorithm + der(0x04, pkcs1))
    let pem =
      "-----BEGIN PRIVATE KEY-----\n\(Data(pkcs8).base64EncodedString())\n-----END PRIVATE KEY-----\n"
    _ = try GitHubAppPrivateKey(pem: pem)
    #expect(throws: CIError.self) { try GitHubAppPrivateKey(pem: "not a key") }
    let ecAlgorithm = der(0x30, der(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]))
    let ec = der(0x30, der(0x02, [0x00]) + ecAlgorithm + der(0x04, [1, 2, 3]))
    #expect(throws: CIError.self) {
      try GitHubAppPrivateKey(
        pem:
          "-----BEGIN PRIVATE KEY-----\n\(Data(ec).base64EncodedString())\n-----END PRIVATE KEY-----"
      )
    }
  }

  @Test func installationTokensAreCachedUntilNearExpiry() throws {
    let app = try GitHubTestApp.make()
    let clock = TestClock()
    let http = ScriptedGitHubHTTP()
    http.on { request in
      guard request.method == .post, request.url.path == "/app/installations/7/access_tokens" else {
        return nil
      }
      #expect(request.headers["Authorization"]?.hasPrefix("Bearer ") == true)
      return GitHubHTTPResponse(
        status: 201,
        body: Array(#"{"token":"ghs_one","expires_at":"\#(isoDate(clock.now() + 3_600))"}"#.utf8))
    }
    let auth = GitHubAppAuth(
      app: app.record, credentials: app.credentials,
      api: GitHubAPI(http: http, sleeper: RecordingGitHubSleeper()), clock: clock)
    #expect(try auth.installationToken(7).value == "ghs_one")
    #expect(try auth.installationToken(7).value == "ghs_one")
    #expect(http.requests.count == 1)
    _ = try auth.installationToken(
      7, repositories: ["app"], permissions: ["administration": "write"])
    #expect(http.requests.count == 2)
    clock.advance(3_600 - GitHubAppAuth.refreshMargin + 1)
    _ = try auth.installationToken(7)
    #expect(http.requests.count == 3)
  }

  /// Each use asks GitHub for a token narrowed to its repository and
  /// permissions; never the installation's full grant.
  @Test func installationTokensAreNarrowedPerUse() throws {
    let app = try GitHubTestApp.make()
    let clock = TestClock()
    let http = ScriptedGitHubHTTP()
    let issued = Mutex(0)
    http.on { request in
      guard request.method == .post, request.url.path == "/app/installations/7/access_tokens" else {
        return nil
      }
      let n = issued.withLock {
        $0 += 1
        return $0
      }
      return GitHubHTTPResponse(
        status: 201,
        body: Array(
          #"{"token":"ghs_\#(n)","expires_at":"\#(isoDate(clock.now() + 3_600))"}"#.utf8))
    }
    http.route(.delete, "/repos/octo/demo/actions/runners/5", status: 204, json: "")
    http.route(.delete, "/orgs/octo/actions/runners/6", status: 204, json: "")
    http.route(.get, "/repos/octo/demo/actions/runs", json: #"{"workflow_runs":[]}"#)
    http.route(.get, "/repos/octo/demo/actions/permissions/workflow", json: "{}")
    let api = GitHubAPI(http: http, sleeper: RecordingGitHubSleeper())
    let client = GitHubInstallationClient(
      api: api,
      auth: GitHubAppAuth(app: app.record, credentials: app.credentials, api: api, clock: clock),
      installationID: 7)
    let runners = InstallationRunnerService(client: client)
    let repository = try RepositoryName("octo/demo")
    func tokenRequests() throws -> [JSONValue] {
      try http.requests.filter { $0.url.path.hasSuffix("/access_tokens") }.map {
        try StrictJSON.parse(try #require($0.body), limits: JSONLimits(maxBytes: 1 << 16))
      }
    }

    #expect(try runners.deleteRunner(scope: .repository(repository), id: 5))
    #expect(
      try tokenRequests().last
        == [
          "repositories": ["demo"],
          "permissions": ["administration": "write", "metadata": "read"],
        ])
    #expect(try runners.deleteRunner(scope: .organization("octo"), id: 6))
    #expect(
      try tokenRequests().last
        == ["permissions": ["organization_self_hosted_runners": "write", "metadata": "read"]])
    _ = try runners.activeJobs(scope: .repository(repository))
    #expect(
      try tokenRequests().last
        == [
          "repositories": ["demo"], "permissions": ["actions": "read", "metadata": "read"],
        ])
    _ = try APIAuthorityReader(client: client).policy(
      "/repos/octo/demo/actions/permissions/workflow", of: repository)
    #expect(
      try tokenRequests().last
        == [
          "repositories": ["demo"],
          "permissions": ["administration": "read", "actions": "read", "metadata": "read"],
        ])
    // A narrowed token is cached under its own narrowing only.
    #expect(try tokenRequests().count == 4)
    #expect(try runners.deleteRunner(scope: .repository(repository), id: 5))
    #expect(try tokenRequests().count == 4)
    // No request ever asks for the unnarrowed installation grant.
    #expect(try tokenRequests().allSatisfy { $0["permissions"] != nil })
  }

  @Test func missingKeyIsUnauthorized() throws {
    let record = GitHubAppRecord(
      appID: 1, slug: "x", owner: "o", clientID: nil, htmlURL: nil,
      credentialReference: "github-app-1",
      createdAt: 0)
    let auth = GitHubAppAuth(
      app: record, credentials: MemoryCredentialStore(),
      api: GitHubAPI(http: ScriptedGitHubHTTP(), sleeper: RecordingGitHubSleeper()))
    #expect(throws: CIError.self) { try auth.jwt() }
  }

  @Test func credentialReferencesAreValidated() throws {
    let store = MemoryCredentialStore()
    #expect(throws: CIError.self) { try store.store([1], reference: "../escape key") }
    try store.store([1, 2], reference: "github-app-9/app-private-key")
    #expect(try store.load("github-app-9/app-private-key") == [1, 2])
    try store.remove("github-app-9/app-private-key")
    #expect(try store.load("github-app-9/app-private-key") == nil)
  }
}

@Suite struct GitHubAPITests {
  private let token = RedactedSecret("ghs_test")

  @Test func paginationIsCappedAndSameOriginOnly() throws {
    let http = ScriptedGitHubHTTP()
    http.on { request in
      guard request.url.path == "/repos/octo/app/actions/runners" else { return nil }
      let page =
        Int(
          URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first {
            $0.name == "page"
          }?.value ?? "1") ?? 1
      return GitHubHTTPResponse(
        status: 200,
        headers: [
          "Link":
            "<https://api.github.com/repos/octo/app/actions/runners?page=\(page + 1)>; rel=\"next\""
        ],
        body: Array(
          #"{"total_count":1000,"runners":[{"id":\#(page),"name":"r\#(page)","labels":[]}]}"#.utf8))
    }
    let api = GitHubAPI(http: http, sleeper: RecordingGitHubSleeper(), maxPages: 3)
    let page = try api.paginate("/repos/octo/app/actions/runners", auth: .installation(token)) {
      (json) throws(CIError) in json["runners"]?.arrayValue ?? []
    }
    #expect(page.items.count == 3)
    #expect(page.truncated)
    #expect(http.requests.count == 3)

    let foreign = ScriptedGitHubHTTP()
    foreign.route(
      .get, "/repos/octo/app/actions/runners",
      json: #"{"runners":[{"id":1,"name":"a","labels":[]}]}"#,
      headers: ["Link": "<https://evil.example/steal?page=2>; rel=\"next\""])
    let other = GitHubAPI(http: foreign, sleeper: RecordingGitHubSleeper())
    #expect(
      try other.runners(scope: .repository(try RepositoryName("octo/app")), name: nil, token: token)
        .count == 1)
    #expect(foreign.requests.allSatisfy { $0.url.host == "api.github.com" })
  }

  @Test func serverErrorsBackOffBoundedly() throws {
    let http = ScriptedGitHubHTTP()
    http.route(
      .get, "/app", status: 503, json: #"{"message":"unavailable"}"#,
      headers: ["Retry-After": "1000"])
    let sleeper = RecordingGitHubSleeper()
    let api = GitHubAPI(http: http, sleeper: sleeper, maxRetries: 4, maxBackoffSeconds: 60)
    #expect(throws: CIError.self) { try api.app(jwt: RedactedSecret("jwt")) }
    #expect(http.requests.count == 5)
    #expect(sleeper.recorded == [60, 60, 60, 60])
    do { _ = try api.app(jwt: RedactedSecret("jwt")) } catch {
      #expect(error.code == .githubUnavailable)
      #expect(!error.message.contains("jwt"))
    }
  }

  @Test func jitCreationIsNeverBlindlyRetried() throws {
    let http = ScriptedGitHubHTTP()
    http.route(.post, "/repos/octo/app/actions/runners/generate-jitconfig", status: 502)
    let api = GitHubAPI(http: http, sleeper: RecordingGitHubSleeper())
    let scope = GitHubRunnerScope.repository(try RepositoryName("octo/app"))
    do {
      _ = try api.generateJITConfig(
        scope: scope, name: "n", runnerGroupID: 1, labels: ["self-hosted"], workFolder: "_work",
        token: token)
      Issue.record("expected failure")
    } catch {
      #expect(error.code == .githubUnavailable)
      #expect(error.details["uncertain"] == "true")
    }
    #expect(http.requests.count == 1)

    // A rate-limit refusal had no effect, so it may be retried.
    let limited = ScriptedGitHubHTTP()
    let count = Mutex(0)
    limited.on { request in
      guard request.url.path.hasSuffix("generate-jitconfig") else { return nil }
      let n = count.withLock { value -> Int in
        value += 1
        return value
      }
      if n == 1 { return GitHubHTTPResponse(status: 429, headers: ["Retry-After": "2"]) }
      return GitHubHTTPResponse(
        status: 201,
        body: Array(
          #"{"runner":{"id":5,"name":"n","status":"offline","busy":false,"labels":[{"name":"self-hosted"}]},"encoded_jit_config":"abc"}"#
            .utf8))
    }
    let sleeper = RecordingGitHubSleeper()
    let jit = try GitHubAPI(http: limited, sleeper: sleeper).generateJITConfig(
      scope: scope, name: "n", runnerGroupID: 1, labels: ["self-hosted"], workFolder: "_work",
      token: token)
    #expect(jit.runner.id == 5)
    #expect(jit.encoded.value == "abc")
    #expect(sleeper.recorded == [2])
  }

  @Test func deleteAndLookupHandleAbsence() throws {
    let http = ScriptedGitHubHTTP()
    let api = GitHubAPI(http: http, sleeper: RecordingGitHubSleeper())
    let scope = GitHubRunnerScope.organization("octo")
    #expect(try api.runner(scope: scope, id: 9, token: token) == nil)
    #expect(try api.deleteRunner(scope: scope, id: 9, token: token) == false)
    #expect(
      http.requests.map(\.url.path) == [
        "/orgs/octo/actions/runners/9", "/orgs/octo/actions/runners/9",
      ])
  }
}

@Suite struct GitHubManifestTests {
  @Test func manifestRequestsLeastPrivilege() {
    let repo = ManifestFlow.permissions([.repository])
    #expect(repo == ["administration": "write", "actions": "read", "metadata": "read"])
    let org = ManifestFlow.permissions([.organization])
    #expect(org["organization_self_hosted_runners"] == "write")
    #expect(org["administration"] == nil)
    #expect(!repo.values.contains("admin"))
    #expect(repo["actions"] == "read")
    let manifest = ManifestFlow.manifest(
      name: "iso-ci", homepage: "https://example.com", redirectURL: "http://127.0.0.1:1/callback",
      scopes: [.repository])
    #expect(manifest["public"] == false)
    #expect(manifest["hook_attributes"] == nil)
    let page = ManifestFlow.formPage(
      manifest: manifest, action: "https://github.com/settings/apps/new?state=x")
    #expect(!page.contains(#"value="{""#))
    #expect(page.contains("&quot;"))
  }

  final class ServeHandle: Sendable {
    let result = Mutex<Result<String, CIError>?>(nil)
    let done = DispatchSemaphore(value: 0)
  }

  /// Runs the server on a thread; returns a handle to its result.
  private func serve(_ server: ManifestCallbackServer) -> ServeHandle {
    let handle = ServeHandle()
    Thread.detachNewThread {
      let outcome: Result<String, CIError>
      do throws(CIError) {
        outcome = .success(try server.waitForCode(formPage: "<form>", timeoutSeconds: 10))
      } catch {
        outcome = .failure(error)
      }
      handle.result.withLock { $0 = outcome }
      handle.done.signal()
    }
    return handle
  }

  private func get(_ port: UInt16, _ path: String, host: String? = nil) -> String? {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connected == 0 else { return nil }
    let request = Array("GET \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n\r\n".utf8)
    _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var out: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count <= 0 { break }
      out += buffer[0..<count]
    }
    return String(decoding: out, as: UTF8.self)
  }

  @Test func callbackAcceptsOnlyTheMatchingStateOnce() throws {
    let state = randomHex()
    let server = try ManifestCallbackServer(state: state)
    let port = server.port
    let handle = serve(server)
    #expect(get(port, server.formPath)?.contains("200 OK") == true)
    // The form lives only under its unguessable path.
    #expect(get(port, "/")?.contains("404") == true)
    #expect(get(port, "/favicon.ico")?.contains("404") == true)
    #expect(get(port, "/callback?code=abc123&state=\(state)")?.contains("200 OK") == true)
    handle.done.wait()
    #expect(try handle.result.withLock { $0 }?.get() == "abc123")
    // Single use: the code is never accepted again. (The port may already
    // belong to another test's listener, so only acceptance is checked.)
    #expect(get(port, "/callback?code=again&state=\(state)")?.contains("200 OK") != true)
    #expect(try handle.result.withLock { $0 }?.get() == "abc123")
  }

  // DNS rebinding: a page on another origin resolved to 127.0.0.1 sends its
  // own Host header and is refused, even with the right path.
  @Test func callbackRefusesOtherHostHeaders() throws {
    let state = randomHex()
    let server = try ManifestCallbackServer(state: state)
    let port = server.port
    let handle = serve(server)
    #expect(get(port, server.formPath, host: "attacker.example:\(port)")?.contains("421") == true)
    #expect(
      get(port, "/callback?code=evil&state=\(state)", host: "attacker.example")?.contains("421")
        == true)
    #expect(get(port, "/callback?code=good&state=\(state)")?.contains("200 OK") == true)
    handle.done.wait()
    #expect(try handle.result.withLock { $0 }?.get() == "good")
  }

  @Test func callbackStateMismatchIsRefusedWithoutEndingTheFlow() throws {
    let state = randomHex()
    let server = try ManifestCallbackServer(state: state)
    let port = server.port
    let handle = serve(server)
    #expect(get(port, "/callback?code=abc&state=\(randomHex())")?.contains("400") == true)
    #expect(get(port, "/callback?state=\(state)")?.contains("400") == true)
    #expect(get(port, "/callback?code=ok1&state=\(state)")?.contains("200 OK") == true)
    handle.done.wait()
    #expect(try handle.result.withLock { $0 }?.get() == "ok1")
  }

  @Test func conversionStoresKeysInTheCredentialStoreOnly() throws {
    let key = try makeGitHubTestRSAKey()
    let http = ScriptedGitHubHTTP()
    let pemJSON = key.pem.replacingOccurrences(of: "\n", with: "\\n")
    http.route(
      .post, "/app-manifests/CODE1/conversions", status: 201,
      json:
        #"{"id":77,"slug":"iso-ci-octo","owner":{"login":"octo"},"client_id":"Iv1.a","client_secret":"cs","webhook_secret":"ws","pem":"\#(pemJSON)","html_url":"https://github.com/apps/iso-ci-octo"}"#
    )
    let credentials = MemoryCredentialStore()
    let store = try ControllerStore.inMemory()
    let record = try ManifestFlow.complete(
      code: "CODE1", api: GitHubAPI(http: http, sleeper: RecordingGitHubSleeper()),
      credentials: credentials,
      store: store)
    #expect(record.appID == 77)
    #expect(
      credentials.references == ["github-app-77/app-private-key", "github-app-77/webhook-secret"])
    #expect(try store.apps() == [record])
    let encoded = try ControllerStore.encode(record)
    #expect(!encoded.contains("PRIVATE KEY"))
    #expect(!encoded.contains("\"cs\""))
    #expect(
      ManifestFlow.installURL(slug: record.slug)
        == "https://github.com/apps/iso-ci-octo/installations/new")
  }

  @Test func unstorableConversionNamesTheCreatedAppAndRecovery() throws {
    struct RefusingStore: CredentialStore {
      func store(_ secret: [UInt8], reference: String) throws(CIError) {
        throw CIError(.storage, "the keychain refused to store a credential (status -34018)")
      }
      func load(_ reference: String) throws(CIError) -> [UInt8]? { nil }
      func remove(_ reference: String) throws(CIError) {}
    }
    let key = try makeGitHubTestRSAKey()
    let http = ScriptedGitHubHTTP()
    let pemJSON = key.pem.replacingOccurrences(of: "\n", with: "\\n")
    http.route(
      .post, "/app-manifests/CODE2/conversions", status: 201,
      json:
        #"{"id":78,"slug":"iso-ci-lost","owner":{"login":"octo"},"pem":"\#(pemJSON)"}"#)
    let store = try ControllerStore.inMemory()
    do {
      _ = try ManifestFlow.complete(
        code: "CODE2", api: GitHubAPI(http: http, sleeper: RecordingGitHubSleeper()),
        credentials: RefusingStore(), store: store)
      Issue.record("expected a storage failure")
    } catch {
      #expect(error.code == .storage)
      #expect(error.message.contains("iso-ci-lost (id 78) was created"))
      #expect(error.message.contains("--app-id 78 --private-key"))
      #expect(!error.message.contains("PRIVATE KEY"))
    }
    #expect(try store.apps().isEmpty)
    #expect(try store.events(after: 0).contains { $0.kind == "app.credentials_unstored" })
  }

  @Test func connectingAnExistingAppProvesTheKey() throws {
    let key = try makeGitHubTestRSAKey()
    let http = ScriptedGitHubHTTP()
    http.route(.get, "/app", json: #"{"id":43,"slug":"other","owner":{"login":"octo"}}"#)
    let credentials = MemoryCredentialStore()
    let store = try ControllerStore.inMemory()
    let api = GitHubAPI(http: http, sleeper: RecordingGitHubSleeper())
    #expect(throws: CIError.self) {
      try ManifestFlow.connectExistingApp(
        appID: 42, privateKeyPEM: RedactedSecret(key.pem), api: api, credentials: credentials,
        store: store)
    }
    #expect(credentials.references.isEmpty)
    http.route(
      .get, "/app", json: #"{"id":42,"slug":"mine","owner":{"login":"octo"},"client_id":"Iv1.b"}"#)
    let record = try ManifestFlow.connectExistingApp(
      appID: 42, privateKeyPEM: RedactedSecret(key.pem), api: api, credentials: credentials,
      store: store)
    #expect(record.slug == "mine")
    #expect(record.clientID == "Iv1.b")
  }

  @Test func installationVerificationChecksAppAccountAndPermissions() throws {
    let app = try GitHubTestApp.make()
    let http = ScriptedGitHubHTTP()
    let store = try ControllerStore.inMemory()
    let api = GitHubAPI(http: http, sleeper: RecordingGitHubSleeper())
    http.route(
      .get, "/app/installations/7",
      json:
        #"{"id":7,"app_id":42,"account":{"login":"octo","type":"User"},"repository_selection":"selected","permissions":{"actions":"read","metadata":"read"}}"#
    )
    #expect(throws: CIError.self) {
      try ManifestFlow.verifyInstallation(
        name: "selected-installation", installationID: 7, app: app.record, api: api,
        credentials: app.credentials, store: store, expectedAccount: "octo", scopes: [.repository])
    }
    http.route(
      .get, "/app/installations/7",
      json:
        #"{"id":7,"app_id":42,"account":{"login":"octo","type":"User"},"repository_selection":"selected","permissions":{"actions":"read","administration":"write","metadata":"read"}}"#
    )
    #expect(throws: CIError.self) {
      try ManifestFlow.verifyInstallation(
        name: "selected-installation", installationID: 7, app: app.record, api: api,
        credentials: app.credentials, store: store, expectedAccount: "someone-else",
        scopes: [.repository])
    }
    let record = try ManifestFlow.verifyInstallation(
      name: "selected-installation", installationID: 7, app: app.record, api: api,
      credentials: app.credentials, store: store, expectedAccount: "octo", scopes: [.repository])
    #expect(try store.installation("selected-installation") == record)
  }
}

@Suite struct GitHubSmokeTests {
  @Test func generatesTheSpecSmokeWorkflow() throws {
    let labels = try ["self-hosted", "linux", "ARM64", "iso-ci"].map { (raw) throws(CIError) in
      try RunnerLabel(raw)
    }
    let text = SmokeWorkflow.generate(labels: labels)
    #expect(
      text == """
        name: ISO runner smoke
        on:
          workflow_dispatch:
        permissions: {}
        jobs:
          smoke:
            runs-on: [self-hosted, linux, ARM64, iso-ci]
            timeout-minutes: 5
            steps:
              - name: Identify the runner
                env:
                  CI_RUNNER_NAME: ${{ runner.name }}
                run: |
                  uname -a
                  printf 'runner=%s\\n' "$CI_RUNNER_NAME"

        """)
    let parsed = try YAML.parse(text)
    #expect(parsed["on"]?["workflow_dispatch"] != nil)
    let grouped = try YAML.parse(SmokeWorkflow.generate(labels: labels, runnerGroup: "ci's group"))
    #expect(grouped["jobs"]?["smoke"]?["runs-on"]?["group"]?.scalar?.value == "ci's group")
  }
}
