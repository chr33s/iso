import Foundation
import Security
import Synchronization

/// GitHub App authentication (spec section 8): one credential component for
/// App JWTs and installation tokens. The private key is loaded from the
/// credential store per signing; tokens are cached in memory only and never
/// leave the controller process.
package final class GitHubAppAuth: Sendable {
  /// GitHubJWT lifetime; GitHub accepts at most 10 minutes.
  package static let jwtLifetime: EpochSeconds = 540
  /// Backdating for clock drift.
  package static let jwtBackdate: EpochSeconds = 60
  /// Installation tokens are refreshed this long before expiry.
  package static let refreshMargin: EpochSeconds = 300

  package let appID: Int64
  /// The GitHubJWT issuer: the App's client id when known, else its numeric id.
  package let issuer: String
  private let credentialReference: String
  private let credentials: any CredentialStore
  private let api: GitHubAPI
  private let clock: any CIClock
  private let cache = Mutex<[String: (token: RedactedSecret, expiresAt: EpochSeconds)]>([:])

  package init(
    app: GitHubAppRecord, credentials: any CredentialStore, api: GitHubAPI,
    clock: any CIClock = SystemClock()
  ) {
    appID = app.appID
    issuer = app.clientID ?? String(app.appID)
    credentialReference = app.credentialReference
    self.credentials = credentials
    self.api = api
    self.clock = clock
  }

  /// A fresh App GitHubJWT (iat backdated 60s, exp at most 9 minutes ahead).
  package func jwt() throws(CIError) -> RedactedSecret {
    guard
      let pem = try credentials.load(CredentialKind.appPrivateKey.reference(credentialReference))
    else {
      throw CIError(.unauthorized, "the GitHub App private key is not in the credential store")
    }
    let key = try GitHubAppPrivateKey(pem: String(decoding: pem, as: UTF8.self))
    return try GitHubJWT.sign(issuer: issuer, now: clock.now(), key: key)
  }

  /// An installation token, optionally narrowed to repositories and
  /// permissions. Cached until `refreshMargin` before its expiry.
  package func installationToken(
    _ installationID: Int64, repositories: [String]? = nil, permissions: [String: String]? = nil
  ) throws(CIError) -> RedactedSecret {
    let key = Self.cacheKey(installationID, repositories, permissions)
    let now = clock.now()
    if let cached = cache.withLock({ $0[key] }), cached.expiresAt > now + Self.refreshMargin {
      return cached.token
    }
    let issued = try api.createInstallationToken(
      installationID, jwt: try jwt(), repositories: repositories, permissions: permissions)
    cache.withLock { $0[key] = (issued.token, issued.expiresAt) }
    return issued.token
  }

  /// Drops cached tokens (after revocation or a 401).
  package func invalidate() { cache.withLock { $0.removeAll() } }

  static func cacheKey(_ id: Int64, _ repositories: [String]?, _ permissions: [String: String]?)
    -> String
  {
    let value: JSONValue = [
      "id": .integer(id),
      "repositories": repositories.map { .array($0.sorted().map(JSONValue.string)) } ?? .null,
      "permissions": permissions.map { .object($0.mapValues(JSONValue.string)) } ?? .null,
    ]
    return value.canonicalString
  }
}

/// An RSA private key parsed from PEM (PKCS#1 `RSA PRIVATE KEY`, or PKCS#8
/// `PRIVATE KEY` wrapping an RSA key).
package struct GitHubAppPrivateKey: @unchecked Sendable {
  package let key: SecKey

  package init(key: SecKey) { self.key = key }

  package init(pem: String) throws(CIError) {
    let pkcs1: [UInt8]
    if let body = Self.pemBody(pem, label: "RSA PRIVATE KEY") {
      pkcs1 = body
    } else if let body = Self.pemBody(pem, label: "PRIVATE KEY") {
      pkcs1 = try Self.unwrapPKCS8(body)
    } else {
      throw CIError.invalid("the App private key is not a PEM RSA key")
    }
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(Data(pkcs1) as CFData, attributes as CFDictionary, &error)
    else {
      error?.release()
      throw CIError.invalid("the App private key could not be loaded")
    }
    self.key = key
  }

  static func pemBody(_ pem: String, label: String) -> [UInt8]? {
    let begin = "-----BEGIN \(label)-----"
    let end = "-----END \(label)-----"
    guard let start = pem.range(of: begin),
      let stop = pem.range(of: end, range: start.upperBound..<pem.endIndex)
    else { return nil }
    let base64 = pem[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
    return Data(base64Encoded: String(base64)).map(Array.init)
  }

  /// PrivateKeyInfo ::= SEQUENCE { version INTEGER, algorithm SEQUENCE,
  /// privateKey OCTET STRING } — returns the OCTET STRING contents after
  /// checking the algorithm is rsaEncryption.
  static func unwrapPKCS8(_ der: [UInt8]) throws(CIError) -> [UInt8] {
    var reader = DERReader(der)
    var outer = try reader.read(tag: 0x30)
    _ = try outer.read(tag: 0x02)
    var algorithm = try outer.read(tag: 0x30)
    let oid = try algorithm.read(tag: 0x06)
    guard oid.bytes == [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01] else {
      throw CIError.invalid("the App private key is not an RSA key")
    }
    return try outer.read(tag: 0x04).bytes
  }
}

/// A minimal DER reader for PKCS#8 unwrapping.
private struct DERReader {
  let bytes: [UInt8]
  var index = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  mutating func read(tag: UInt8) throws(CIError) -> DERReader {
    guard index + 2 <= bytes.count, bytes[index] == tag else {
      throw CIError.invalid("malformed DER key")
    }
    index += 1
    var length = Int(bytes[index])
    index += 1
    if length & 0x80 != 0 {
      let count = length & 0x7F
      guard (1...4).contains(count), index + count <= bytes.count else {
        throw CIError.invalid("malformed DER key")
      }
      length = 0
      for _ in 0..<count {
        length = length << 8 | Int(bytes[index])
        index += 1
      }
    }
    guard length >= 0, index + length <= bytes.count else {
      throw CIError.invalid("malformed DER key")
    }
    let body = Array(bytes[index..<(index + length)])
    index += length
    return DERReader(body)
  }
}

/// RS256 JSON Web Tokens for GitHub App authentication.
package enum GitHubJWT {
  package static func sign(issuer: String, now: EpochSeconds, key: GitHubAppPrivateKey)
    throws(CIError)
    -> RedactedSecret
  {
    let header: JSONValue = ["alg": "RS256", "typ": "JWT"]
    let payload: JSONValue = [
      "iat": .integer(Int64(now) - Int64(GitHubAppAuth.jwtBackdate)),
      "exp": .integer(Int64(now + GitHubAppAuth.jwtLifetime)), "iss": .string(issuer),
    ]
    let signingInput = base64URL(header.canonical) + "." + base64URL(payload.canonical)
    var error: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        key.key, .rsaSignatureMessagePKCS1v15SHA256, Data(signingInput.utf8) as CFData, &error)
    else {
      error?.release()
      throw CIError(.internalError, "could not sign the App JWT")
    }
    return RedactedSecret(signingInput + "." + base64URL(Array(signature as Data)))
  }

  package static func base64URL(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  package static func decodeBase64URL(_ text: String) -> [UInt8]? {
    var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    return Data(base64Encoded: base64).map(Array.init)
  }
}

/// The GitHub surface the controller uses for one installation: App
/// authentication plus typed calls with the right token for each.
package final class GitHubInstallationClient: Sendable {
  package let api: GitHubAPI
  package let auth: GitHubAppAuth
  package let installationID: Int64

  package init(api: GitHubAPI, auth: GitHubAppAuth, installationID: Int64) {
    self.api = api
    self.auth = auth
    self.installationID = installationID
  }

  /// An installation token narrowed to `scope`: each use asks for only the
  /// repositories and permissions it needs.
  package func token(_ scope: InstallationTokenScope) throws(CIError) -> RedactedSecret {
    do {
      return try auth.installationToken(
        installationID, repositories: scope.repositories, permissions: scope.permissions)
    } catch {
      if error.code == .unauthorized { auth.invalidate() }
      throw error
    }
  }
}

/// The repositories and permissions one installation token is narrowed to
/// (`POST /app/installations/{id}/access_tokens`). `repositories` holds
/// repository names without the owner; nil keeps the installation's own
/// selection, as an organization-level call needs.
package struct InstallationTokenScope: Sendable, Equatable {
  package let repositories: [String]?
  package let permissions: [String: String]

  init(_ repository: RepositoryName?, _ permissions: [String: String]) {
    repositories = repository.map { [$0.name] }
    self.permissions = permissions.merging(["metadata": "read"]) { granted, _ in granted }
  }

  /// Registering, listing and deleting self-hosted runners: Administration
  /// write on the one repository, or organization Self-hosted runners write.
  package static func runnerAdministration(_ scope: GitHubRunnerScope) -> Self {
    switch scope {
    case .repository(let repository): Self(repository, ["administration": "write"])
    case .organization: Self(nil, ["organization_self_hosted_runners": "write"])
    }
  }

  /// Reading an organization's runner groups.
  package static let runnerGroupsRead = Self(nil, ["organization_self_hosted_runners": "read"])

  /// Reading workflow runs and jobs for correlation: Actions read on the one
  /// repository, or on the installation's repositories for an organization.
  package static func actionsRead(_ repository: RepositoryName?) -> Self {
    Self(repository, ["actions": "read"])
  }

  /// Repository and installation metadata (visibility, accessible
  /// repositories).
  package static func metadataRead(_ repository: RepositoryName?) -> Self {
    Self(repository, [:])
  }

  /// A repository's Actions policy (`/actions/permissions/...`), which
  /// GitHub serves under the Administration read permission.
  package static func actionsPolicyRead(_ repository: RepositoryName) -> Self {
    Self(repository, ["administration": "read", "actions": "read"])
  }
}
