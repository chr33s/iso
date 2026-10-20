import Foundation

/// GitHub App onboarding (spec section 8): create an App through the
/// manifest flow, or connect an operator-owned App; installation is a
/// separate operator step that `verifyInstallation` then validates. There is
/// no PAT or `gh` fallback.
package enum ManifestFlow {
  /// Which runner-management permission the App needs.
  package enum ScopeKind: String, Sendable, CaseIterable {
    case repository
    case organization
  }

  /// Least-privilege App permissions: runner management for the chosen
  /// scope, Actions read for observation, metadata read. Never Actions write.
  package static func permissions(_ scopes: Set<ScopeKind>) -> [String: String] {
    var out = ["actions": "read", "metadata": "read"]
    if scopes.contains(.repository) { out["administration"] = "write" }
    if scopes.contains(.organization) { out["organization_self_hosted_runners"] = "write" }
    return out
  }

  package static func manifest(
    name: String, homepage: String, redirectURL: String, scopes: Set<ScopeKind>
  ) -> JSONValue {
    [
      "name": .string(name), "url": .string(homepage), "redirect_url": .string(redirectURL),
      "public": false, "default_events": [],
      "default_permissions": .object(permissions(scopes).mapValues(JSONValue.string)),
    ]
  }

  /// Where the browser posts the manifest: the user's or an organization's
  /// App settings.
  package static func creationURL(organization: String?, state: String) -> String {
    let base =
      organization.map { "https://github.com/organizations/\($0)/settings/apps/new" }
      ?? "https://github.com/settings/apps/new"
    return base + "?state=" + state
  }

  package static func installURL(slug: String) -> String {
    "https://github.com/apps/\(slug)/installations/new"
  }

  /// The local page that submits the manifest to GitHub.
  package static func formPage(manifest: JSONValue, action: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><title>iso-ci GitHub App</title></head>
    <body><p>Submitting the iso-ci App manifest to GitHub for your review…</p>
    <form id="f" method="post" action="\(htmlEscape(action))">
    <input type="hidden" name="manifest" value="\(htmlEscape(manifest.canonicalString))">
    <noscript><button type="submit">Continue to GitHub</button></noscript></form>
    <script>document.getElementById("f").submit()</script></body></html>
    """
  }

  package static func htmlEscape(_ text: String) -> String {
    var out = ""
    for character in text {
      switch character {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case "'": out += "&#39;"
      default: out.append(character)
      }
    }
    return out
  }

  package static func credentialReference(appID: Int64) -> String { "github-app-\(appID)" }

  /// Converts the single-use code, stores the private key (and webhook
  /// secret) in the credential store and the App metadata in the database.
  /// The client secret is not needed and is discarded.
  package static func complete(
    code: String, api: GitHubAPI, credentials: any CredentialStore, store: ControllerStore
  ) throws(CIError) -> GitHubAppRecord {
    let conversion = try api.convertManifest(code: code)
    let reference = credentialReference(appID: conversion.id)
    // The App exists and the code is spent: a storage failure must name the
    // App and its recovery path (the key is not written anywhere else).
    do throws(CIError) {
      try credentials.store(
        conversion.privateKeyPEM.bytes, reference: CredentialKind.appPrivateKey.reference(reference)
      )
      if let secret = conversion.webhookSecret {
        try credentials.store(
          secret.bytes, reference: CredentialKind.webhookSecret.reference(reference))
      }
    } catch {
      try? credentials.remove(CredentialKind.appPrivateKey.reference(reference))
      _ = try? store.event(
        "github", "app.credentials_unstored",
        "created GitHub App \(conversion.slug) but could not store its key",
        data: ["app_id": String(conversion.id)])
      throw CIError(
        error.code,
        "GitHub App \(conversion.slug) (id \(conversion.id)) was created but its key could not be stored: \(error.message). Generate a new private key in the App's settings on GitHub, then run `iso-ci setup --app-id \(conversion.id) --private-key FILE`; or delete the App on GitHub."
      )
    }
    let record = GitHubAppRecord(
      appID: conversion.id, slug: conversion.slug, owner: conversion.owner,
      clientID: conversion.clientID, htmlURL: conversion.htmlURL, credentialReference: reference,
      createdAt: store.now)
    try store.save(record)
    try store.event(
      "github", "app.created", "created GitHub App \(conversion.slug)",
      data: ["app_id": String(conversion.id)])
    return record
  }

  /// Connects an operator-owned App: proves the key by authenticating as
  /// the App, and only then stores it.
  package static func connectExistingApp(
    appID: Int64, privateKeyPEM: RedactedSecret, api: GitHubAPI, credentials: any CredentialStore,
    store: ControllerStore, clock: any CIClock = SystemClock()
  ) throws(CIError) -> GitHubAppRecord {
    guard appID > 0 else { throw CIError.invalid("invalid App id") }
    _ = try GitHubAppPrivateKey(pem: privateKeyPEM.value)
    let reference = credentialReference(appID: appID)
    let keyReference = CredentialKind.appPrivateKey.reference(reference)
    // Prove the key with an in-memory copy first: a wrong key must never
    // overwrite (or then delete) a working one already in the keychain.
    let trial = MemoryCredentialStore()
    try trial.store(privateKeyPEM.bytes, reference: keyReference)
    let provisional = GitHubAppRecord(
      appID: appID, slug: "", owner: "", clientID: nil, htmlURL: nil,
      credentialReference: reference, createdAt: clock.now())
    let auth = GitHubAppAuth(app: provisional, credentials: trial, api: api, clock: clock)
    let info = try api.app(jwt: try auth.jwt())
    guard info.id == appID else {
      throw CIError(.githubRefused, "the key authenticates a different App")
    }
    try credentials.store(privateKeyPEM.bytes, reference: keyReference)
    let record = GitHubAppRecord(
      appID: appID, slug: info.slug, owner: info.owner, clientID: info.clientID,
      htmlURL: info.htmlURL, credentialReference: reference, createdAt: clock.now())
    try store.save(record)
    try store.event(
      "github", "app.connected", "connected GitHub App \(info.slug)",
      data: ["app_id": String(appID)])
    return record
  }

  /// Validates an installation the operator completed and records it.
  /// The App's installation covering `repository`, found as the App (no
  /// operator copy-paste); verification still runs separately.
  package static func findInstallation(
    repository: RepositoryName, app: GitHubAppRecord, api: GitHubAPI,
    credentials: any CredentialStore, clock: any CIClock = SystemClock()
  ) throws(CIError) -> GitHubInstallationInfo {
    let auth = GitHubAppAuth(app: app, credentials: credentials, api: api, clock: clock)
    guard let info = try api.repositoryInstallation(repository, jwt: try auth.jwt()),
      info.appID == app.appID
    else {
      throw CIError(
        .notFound,
        "GitHub App \(app.slug) is not installed on \(repository); install it with \(installURL(slug: app.slug))"
      )
    }
    return info
  }

  package static func verifyInstallation(
    name: Name, installationID: Int64, app: GitHubAppRecord, api: GitHubAPI,
    credentials: any CredentialStore, store: ControllerStore, expectedAccount: String?,
    scopes: Set<ScopeKind>, clock: any CIClock = SystemClock()
  ) throws(CIError) -> InstallationRecord {
    let auth = GitHubAppAuth(app: app, credentials: credentials, api: api, clock: clock)
    let info = try api.installation(installationID, jwt: try auth.jwt())
    guard info.appID == app.appID else {
      throw CIError(.githubRefused, "installation \(installationID) belongs to another App")
    }
    guard !info.suspended else {
      throw CIError(.githubRefused, "installation \(installationID) is suspended")
    }
    if let expectedAccount, info.account.lowercased() != expectedAccount.lowercased() {
      throw CIError(
        .githubRefused,
        "installation \(installationID) is on \(info.account), not \(expectedAccount)")
    }
    for (permission, level) in permissions(scopes) where permission != "metadata" {
      guard PoolActivation.satisfies(info.permissions[permission], level) else {
        throw CIError(.githubRefused, "installation lacks \(permission):\(level)")
      }
    }
    let record = InstallationRecord(
      name: name, installationID: installationID, appID: app.appID, account: info.account,
      accountType: info.accountType, repositorySelection: info.repositorySelection,
      permissions: info.permissions, verifiedAt: clock.now())
    try store.save(record)
    try store.event(
      "github", "installation.verified", "verified installation \(name) on \(info.account)",
      data: ["installation_id": String(installationID)])
    return record
  }

  /// Removes an App's credentials from the store (explicit offboarding only).
  package static func removeCredentials(app: GitHubAppRecord, credentials: any CredentialStore)
    throws(CIError)
  {
    for kind in [CredentialKind.appPrivateKey, .webhookSecret] {
      try credentials.remove(kind.reference(app.credentialReference))
    }
  }
}

/// A single-use loopback server for the manifest redirect: binds 127.0.0.1
/// on an ephemeral port, serves the local form page under an unguessable
/// path, accepts requests only for its exact `Host` (defeating DNS
/// rebinding), verifies the callback `state` in constant time, and closes
/// after the first valid callback.
package final class ManifestCallbackServer: @unchecked Sendable {
  package static let maxRequestBytes = 8 << 10
  package static let maxFormServes = 8

  private var listener: Int32
  package let port: UInt16
  private let state: String
  /// The unguessable path of the local form page.
  package let formPath = "/" + randomHex(bytes: 16)

  package init(state: String) throws(CIError) {
    guard state.utf8.count >= 32 else { throw CIError.invalid("callback state is too short") }
    self.state = state
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CIError(.internalError, "cannot create the callback socket") }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
      close(fd)
      throw CIError(.internalError, "cannot listen on loopback for the callback")
    }
    var actual = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &actual) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    listener = fd
    port = UInt16(bigEndian: actual.sin_port)
  }

  deinit { shutdown() }

  package var baseURL: String { "http://127.0.0.1:\(port)" }
  package var callbackURL: String { baseURL + "/callback" }
  package var formURL: String { baseURL + formPath }

  package func shutdown() {
    if listener >= 0 {
      close(listener)
      listener = -1
    }
  }

  /// Serves until the single callback arrives or `timeoutSeconds` passes.
  /// Returns the manifest code. Requests for another `Host`, and callbacks
  /// with a wrong state or no code, are refused without ending the wait.
  package func waitForCode(formPage: String, timeoutSeconds: Int) throws(CIError) -> String {
    defer { shutdown() }
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    var served = 0
    while Date() < deadline {
      var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
      let remaining = Int32(max(1, min(1_000, deadline.timeIntervalSinceNow * 1_000)))
      guard poll(&poller, 1, remaining) > 0 else { continue }
      let client = accept(listener, nil, nil)
      guard client >= 0 else { continue }
      defer { close(client) }
      var timeout = timeval(tv_sec: 5, tv_usec: 0)
      setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
      var noSigPipe: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
      guard let (target, host) = Self.readRequest(client) else {
        Self.respond(client, status: "400 Bad Request", body: "bad request")
        continue
      }
      guard host == "127.0.0.1:\(port)" else {
        Self.respond(client, status: "421 Misdirected Request", body: "wrong host")
        continue
      }
      let components = URLComponents(string: "http://127.0.0.1" + target)
      switch components?.path {
      case formPath:
        guard served < Self.maxFormServes else {
          Self.respond(client, status: "410 Gone", body: "expired")
          continue
        }
        served += 1
        Self.respond(client, status: "200 OK", body: formPage, type: "text/html; charset=utf-8")
      case "/callback":
        let items = components?.queryItems ?? []
        let received = items.first { $0.name == "state" }?.value ?? ""
        guard constantTimeEqual(Array(received.utf8), Array(state.utf8)) else {
          Self.respond(client, status: "400 Bad Request", body: "state mismatch")
          continue
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty,
          code.utf8.count <= 200, code.unicodeScalars.allSatisfy(isSafeNameScalar)
        else {
          Self.respond(client, status: "400 Bad Request", body: "missing code")
          continue
        }
        Self.respond(
          client, status: "200 OK", body: "iso-ci received the App. You can close this window.")
        return code
      default:
        Self.respond(client, status: "404 Not Found", body: "not found")
      }
    }
    throw CIError(.timeout, "the GitHub App manifest flow timed out")
  }

  /// The request target and `Host` header of one GET request.
  static func readRequest(_ fd: Int32) -> (target: String, host: String)? {
    var buffer: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 1_024)
    while buffer.count < maxRequestBytes {
      let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count <= 0 { break }
      buffer += chunk[0..<count]
      if buffer.count >= 4, buffer.suffix(4) == [13, 10, 13, 10] { break }
      if let text = String(bytes: buffer, encoding: .utf8), text.contains("\r\n\r\n") { break }
    }
    guard let text = String(bytes: buffer, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")
    guard let line = lines.first else { return nil }
    let parts = line.split(separator: " ")
    guard parts.count == 3, parts[0] == "GET", parts[1].hasPrefix("/"), parts[1].utf8.count <= 2_048
    else { return nil }
    var hosts: [String] = []
    for header in lines.dropFirst() where header.lowercased().hasPrefix("host:") {
      hosts.append(header.dropFirst(5).trimmingCharacters(in: .whitespaces))
    }
    guard hosts.count == 1 else { return nil }
    return (String(parts[1]), hosts[0])
  }

  static func respond(
    _ fd: Int32, status: String, body: String, type: String = "text/plain; charset=utf-8"
  ) {
    let bytes = Array(body.utf8)
    let head =
      "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\n"
      + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
    let all = Array(head.utf8) + bytes
    _ = all.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
  }
}
