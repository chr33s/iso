import CryptoKit
import Foundation
import Security

/// Credentials of the preflight data plane. Nothing here is a host or
/// GitHub credential: every key and token authenticates one allocation to
/// its own namespace on the local endpoint and nothing else.

package enum Base64URL {
  package static func encode(_ bytes: some Sequence<UInt8>) -> String {
    Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }

  package static func decode(_ text: some StringProtocol) -> [UInt8]? {
    guard text.utf8.count <= 64 << 10,
      text.unicodeScalars.allSatisfy({
        ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
          || $0 == "-" || $0 == "_"
      })
    else { return nil }
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    while standard.utf8.count % 4 != 0 { standard += "=" }
    return Data(base64Encoded: standard).map(Array.init)
  }
}

/// The RSA key pair a runner uses for its OAuth client assertion (the
/// runner's `.credentials_rsaparams`). The private half is guest-visible by
/// design; the controller keeps only the public half (PKCS#1 DER).
package struct RunnerKeyPair: Sendable {
  package let publicKeyDER: [UInt8]
  /// The runner's `RSAParametersSerializable` JSON (base64 byte arrays).
  package let rsaParametersJSON: [UInt8]

  /// A fresh 2048-bit key from the system generator.
  package static func generate() throws(CIError) -> RunnerKeyPair {
    let (privateKey, publicDER) = try generateKey()
    var error: Unmanaged<CFError>?
    guard let external = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
      throw CIError(.internalError, "cannot export the runner key")
    }
    let parameters = try RSAPrivateParameters(pkcs1: Array(external))
    return RunnerKeyPair(publicKeyDER: publicDER, rsaParametersJSON: parameters.runnerJSON)
  }

  /// Generates a key and also returns the private `SecKey` (tests sign
  /// client assertions with it as the runner would).
  package static func generateKey() throws(CIError) -> (SecKey, [UInt8]) {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
    ]
    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
      let publicKey = SecKeyCopyPublicKey(privateKey),
      let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
    else { throw CIError(.internalError, "cannot generate a runner key") }
    return (privateKey, Array(publicData))
  }

  /// Rebuilds the private key from the runner JSON (tests).
  package static func privateKey(fromRunnerJSON json: [UInt8]) throws(CIError) -> SecKey {
    let value = try StrictJSON.parse(json, limits: JSONLimits(maxBytes: 16 << 10))
    func field(_ name: String) throws(CIError) -> [UInt8] {
      guard let text = value[name]?.stringValue, let data = Data(base64Encoded: text) else {
        throw CIError.invalid("runner key is missing \(name)")
      }
      return Array(data)
    }
    let der = DER.sequence([
      DER.integer([0]), DER.integer(try field("modulus")), DER.integer(try field("exponent")),
      DER.integer(try field("d")), DER.integer(try field("p")), DER.integer(try field("q")),
      DER.integer(try field("dp")), DER.integer(try field("dq")),
      DER.integer(try field("inverseQ")),
    ])
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error)
    else { throw CIError.invalid("runner key is not a valid RSA key") }
    return key
  }
}

/// PKCS#1 RSAPrivateKey fields, normalized to the exact lengths .NET's
/// `RSA.ImportParameters` requires (D as long as the modulus; P, Q, DP, DQ
/// and InverseQ half as long).
package struct RSAPrivateParameters: Sendable, Equatable {
  package let modulus: [UInt8]
  package let exponent: [UInt8]
  package let d: [UInt8]
  package let p: [UInt8]
  package let q: [UInt8]
  package let dp: [UInt8]
  package let dq: [UInt8]
  package let inverseQ: [UInt8]

  package init(pkcs1 der: [UInt8]) throws(CIError) {
    var reader = DER.Reader(der)
    var sequence = try reader.sequence()
    _ = try sequence.integer()  // version
    let n = DER.unsigned(try sequence.integer())
    let e = DER.unsigned(try sequence.integer())
    let modulusLength = n.count
    let half = (modulusLength + 1) / 2
    modulus = n
    exponent = e
    d = DER.leftPad(DER.unsigned(try sequence.integer()), to: modulusLength)
    p = DER.leftPad(DER.unsigned(try sequence.integer()), to: half)
    q = DER.leftPad(DER.unsigned(try sequence.integer()), to: half)
    dp = DER.leftPad(DER.unsigned(try sequence.integer()), to: half)
    dq = DER.leftPad(DER.unsigned(try sequence.integer()), to: half)
    inverseQ = DER.leftPad(DER.unsigned(try sequence.integer()), to: half)
  }

  /// `{"d","dp","dq","exponent","inverseQ","modulus","p","q"}` as base64.
  package var runnerJSON: [UInt8] {
    func b64(_ bytes: [UInt8]) -> JSONValue { .string(Data(bytes).base64EncodedString()) }
    return JSONValue.object([
      "d": b64(d), "dp": b64(dp), "dq": b64(dq), "exponent": b64(exponent),
      "inverseQ": b64(inverseQ), "modulus": b64(modulus), "p": b64(p), "q": b64(q),
    ]).canonical
  }
}

/// Minimal DER for PKCS#1 RSA keys (read and write INTEGER/SEQUENCE).
package enum DER {
  package struct Reader {
    private let bytes: [UInt8]
    private var index = 0

    package init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func header(_ tag: UInt8) throws(CIError) -> [UInt8] {
      guard index < bytes.count, bytes[index] == tag else { throw CIError.invalid("malformed DER") }
      index += 1
      guard index < bytes.count else { throw CIError.invalid("malformed DER") }
      var length = Int(bytes[index])
      index += 1
      if length & 0x80 != 0 {
        let count = length & 0x7F
        guard (1...4).contains(count), index + count <= bytes.count else {
          throw CIError.invalid("malformed DER")
        }
        length = 0
        for _ in 0..<count {
          length = length << 8 | Int(bytes[index])
          index += 1
        }
      }
      guard length >= 0, index + length <= bytes.count else {
        throw CIError.invalid("malformed DER")
      }
      let body = Array(bytes[index..<(index + length)])
      index += length
      return body
    }

    package mutating func sequence() throws(CIError) -> Reader { Reader(try header(0x30)) }
    package mutating func integer() throws(CIError) -> [UInt8] { try header(0x02) }
  }

  package static func unsigned(_ integer: [UInt8]) -> [UInt8] {
    var value = integer[...]
    while value.count > 1, value.first == 0 { value = value.dropFirst() }
    return Array(value)
  }

  package static func leftPad(_ value: [UInt8], to length: Int) -> [UInt8] {
    value.count >= length ? value : [UInt8](repeating: 0, count: length - value.count) + value
  }

  static func length(_ count: Int) -> [UInt8] {
    if count < 0x80 { return [UInt8(count)] }
    var bytes: [UInt8] = []
    var remaining = count
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xFF), at: 0)
      remaining >>= 8
    }
    return [0x80 | UInt8(bytes.count)] + bytes
  }

  package static func integer(_ unsigned: [UInt8]) -> [UInt8] {
    var body = Self.unsigned(unsigned.isEmpty ? [0] : unsigned)
    if body[0] & 0x80 != 0 { body.insert(0, at: 0) }
    return [0x02] + length(body.count) + body
  }

  package static func sequence(_ items: [[UInt8]]) -> [UInt8] {
    let body = items.flatMap { $0 }
    return [0x30] + length(body.count) + body
  }
}

/// A decoded JSON Web Token (header, claims, signed input, signature).
package struct JWTParts: Sendable {
  package let header: JSONValue
  package let claims: JSONValue
  package let signingInput: [UInt8]
  package let signature: [UInt8]

  package init(_ token: String) throws(CIError) {
    guard token.utf8.count <= 16 << 10 else { throw CIError(.unauthorized, "token too large") }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let header = Base64URL.decode(parts[0]),
      let claims = Base64URL.decode(parts[1]), let signature = Base64URL.decode(parts[2])
    else { throw CIError(.unauthorized, "malformed token") }
    let limits = JSONLimits(maxBytes: 8 << 10, maxDepth: 4, maxKeys: 64, maxArrayElements: 16)
    do {
      self.header = try StrictJSON.parse(header, limits: limits)
      self.claims = try StrictJSON.parse(claims, limits: limits)
    } catch { throw CIError(.unauthorized, "malformed token") }
    signingInput = Array((parts[0] + "." + parts[1]).utf8)
    self.signature = signature
  }

  package func numericClaim(_ name: String) -> Int64? { claims[name]?.intValue }
}

/// Verifies the runner's OAuth client assertion: RS256 over the
/// allocation's registered public key, `iss == sub == client_id`,
/// `aud == authorization URL`, a bounded validity window, and a `jti` that
/// was not seen before (replay).
package struct ClientAssertionVerifier: Sendable {
  package static let maxLifetime: Int64 = 600
  package static let clockSkew: Int64 = 120

  package let clientID: String
  package let audience: String
  /// PKCS#1 DER; the `SecKey` is recreated per verification so this value
  /// stays `Sendable`.
  package let publicKeyDER: [UInt8]

  package init(clientID: String, audience: String, publicKeyDER: [UInt8]) throws(CIError) {
    self.clientID = clientID
    self.audience = audience
    self.publicKeyDER = publicKeyDER
    _ = try Self.key(publicKeyDER)
  }

  static func key(_ der: [UInt8]) throws(CIError) -> SecKey {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    ]
    var error: Unmanaged<CFError>?
    guard let key = SecKeyCreateWithData(Data(der) as CFData, attributes as CFDictionary, &error)
    else { throw CIError.invalid("runner public key is not a valid RSA key") }
    return key
  }

  /// A verified assertion: its `jti` and the last moment it is accepted
  /// (`exp` plus the allowed clock skew).
  package struct Verified: Sendable, Equatable {
    package let id: String
    package let acceptedUntil: Int64
  }

  /// Returns the assertion's `jti` and acceptance window once every check
  /// passed.
  package func verify(_ assertion: String, now: Int64) throws(CIError) -> Verified {
    let token = try JWTParts(assertion)
    guard token.header["alg"]?.stringValue == "RS256" else {
      throw CIError(.unauthorized, "unsupported assertion algorithm")
    }
    var error: Unmanaged<CFError>?
    let publicKey = try Self.key(publicKeyDER)
    guard
      SecKeyVerifySignature(
        publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data(token.signingInput) as CFData,
        Data(token.signature) as CFData, &error)
    else { throw CIError(.unauthorized, "assertion signature is invalid") }
    guard token.claims["iss"]?.stringValue == clientID, token.claims["sub"]?.stringValue == clientID
    else { throw CIError(.unauthorized, "assertion names another client") }
    let audienceOK: Bool
    switch token.claims["aud"] {
    case .string(let value)?: audienceOK = value == audience
    case .array(let values)?: audienceOK = values.contains(.string(audience))
    default: audienceOK = false
    }
    guard audienceOK else { throw CIError(.unauthorized, "assertion audience mismatch") }
    guard let expires = token.numericClaim("exp"), let notBefore = token.numericClaim("nbf") else {
      throw CIError(.unauthorized, "assertion lacks a validity window")
    }
    guard expires - notBefore <= Self.maxLifetime, now <= expires + Self.clockSkew,
      now + Self.clockSkew >= notBefore
    else { throw CIError(.unauthorized, "assertion is expired or not yet valid") }
    guard let jti = token.claims["jti"]?.stringValue, (1...128).contains(jti.utf8.count) else {
      throw CIError(.unauthorized, "assertion lacks an identifier")
    }
    return Verified(id: jti, acceptedUntil: expires + Self.clockSkew)
  }
}

/// HS256 tokens the endpoint mints and verifies with a key that exists only
/// in the endpoint process. They are JWTs because guest tooling reads
/// claims (the artifact toolkit takes its backend ids from `scp`).
package struct EndpointTokenAuthority: Sendable {
  package enum Purpose: String, Sendable, CaseIterable {
    /// The runner listener's broker/run-service access token.
    case runner
    /// The job token (`ACTIONS_RUNTIME_TOKEN`, results, launch, run service).
    case job
    /// Action archive downloads.
    case actions
  }

  package struct Claims: Sendable, Equatable {
    package let allocation: AllocationID
    package let purpose: Purpose
    package let expiresAt: Int64
  }

  private let key: SymmetricKey

  package init(key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }

  package func mint(
    allocation: AllocationID, purpose: Purpose, expiresAt: Int64, scope: String? = nil
  ) -> String {
    let header = Base64URL.encode(JSONValue.object(["alg": "HS256", "typ": "JWT"]).canonical)
    var claims: [String: JSONValue] = [
      "sub": .string(allocation.rawValue), "aud": .string(purpose.rawValue),
      "exp": .integer(expiresAt), "iss": "iso-ci-preflight", "jti": .string(randomHex(bytes: 12)),
    ]
    if let scope { claims["scp"] = .string(scope) }
    let body = Base64URL.encode(JSONValue.object(claims).canonical)
    let input = Array((header + "." + body).utf8)
    let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
    return header + "." + body + "." + Base64URL.encode(Array(mac))
  }

  package func verify(_ token: String, purpose: Purpose, now: Int64) throws(CIError) -> Claims {
    let parts = try JWTParts(token)
    guard parts.header["alg"]?.stringValue == "HS256",
      HMAC<SHA256>.isValidAuthenticationCode(
        parts.signature, authenticating: parts.signingInput, using: key)
    else { throw CIError(.unauthorized, "invalid token") }
    guard parts.claims["aud"]?.stringValue == purpose.rawValue else {
      throw CIError(.unauthorized, "token is not valid for this route")
    }
    guard let subject = parts.claims["sub"]?.stringValue,
      let allocation = try? AllocationID(subject),
      let expires = parts.numericClaim("exp")
    else { throw CIError(.unauthorized, "invalid token") }
    guard now < expires else { throw CIError(.unauthorized, "token expired") }
    return Claims(allocation: allocation, purpose: purpose, expiresAt: expires)
  }

  /// `sig` for a signed URL path bound to an allocation and expiry.
  package func signature(path: String, allocation: AllocationID, expiresAt: Int64) -> String {
    let input = Array("\(allocation.rawValue)\n\(expiresAt)\n\(path)".utf8)
    return Base64URL.encode(Array(HMAC<SHA256>.authenticationCode(for: input, using: key)))
  }

  package func verifySignature(
    _ signature: String, path: String, allocation: AllocationID, expiresAt: Int64, now: Int64
  ) -> Bool {
    guard now < expiresAt, let provided = Base64URL.decode(signature) else { return false }
    let input = Array("\(allocation.rawValue)\n\(expiresAt)\n\(path)".utf8)
    return HMAC<SHA256>.isValidAuthenticationCode(provided, authenticating: input, using: key)
  }
}

/// A random bearer for the iso-ci routes (`ISO_CI_TOKEN`); the endpoint
/// keeps only its SHA-256 verifier.
package struct IsoBearer: Sendable, Equatable {
  package let value: String

  package static func generate() -> IsoBearer { IsoBearer(value: randomHex(bytes: 32)) }

  package var verifier: Digest { Digest(hashing: value) }

  package static func matches(_ presented: String, verifier: Digest) -> Bool {
    constantTimeEqual(
      Array(Digest(hashing: presented).rawValue.utf8), Array(verifier.rawValue.utf8))
  }
}
