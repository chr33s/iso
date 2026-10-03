import CryptoKit
import Foundation
import IsoCore

/// Store limits (spec §24).
package enum StoreLimits {
  package static let fileBytes = 16 << 20
  package static let entries = 4096
  package static let valueBytes = 1 << 20
}

/// `store.v1.json`: the outer envelope. It holds no secret names or values.
struct StoreEnvelope: Codable, Equatable {
  struct KDFSection: Codable, Equatable {
    let algorithm: String
    let salt: String
    let n: Int
    let r: Int
    let p: Int

    /// The envelope spells scrypt's cost parameter `N`, as the spec does.
    enum CodingKeys: String, CodingKey {
      case algorithm, salt, r, p
      case n = "N"
    }
  }

  struct CipherSection: Codable, Equatable {
    let algorithm: String
    let nonce: String
    let ciphertext: String
    let tag: String
  }

  static let formatName = "iso-secrets"
  static let currentVersion = 1

  let format: String
  let version: Int
  let kdf: KDFSection
  let cipher: CipherSection

  /// Validated KDF parameters; every bound is checked before scrypt runs.
  func parameters() throws(EnclaveStoreError) -> ScryptParameters {
    guard format == Self.formatName, version == Self.currentVersion else {
      throw .malformed("unsupported format or version")
    }
    guard kdf.algorithm == "scrypt", cipher.algorithm == "aes-256-gcm" else {
      throw .malformed("unsupported algorithm")
    }
    guard let salt = Data(base64Encoded: kdf.salt) else { throw .malformed("invalid salt") }
    return try ScryptParameters(n: kdf.n, r: kdf.r, p: kdf.p, salt: Array(salt))
  }

  /// `iso-secrets:v1:scrypt:<N>:<r>:<p>:<base64-salt>`, locale-independent.
  static func additionalData(_ parameters: ScryptParameters) -> Data {
    let salt = Data(parameters.salt).base64EncodedString()
    return Data(
      "iso-secrets:v1:scrypt:\(parameters.n):\(parameters.r):\(parameters.p):\(salt)".utf8)
  }

  static func seal(
    _ plaintext: Data, key: SymmetricKey, parameters: ScryptParameters,
    nonce: AES.GCM.Nonce = AES.GCM.Nonce()
  ) throws(EnclaveStoreError) -> StoreEnvelope {
    let box: AES.GCM.SealedBox
    do {
      box = try AES.GCM.seal(
        plaintext, using: key, nonce: nonce, authenticating: additionalData(parameters))
    } catch {
      throw .io("Failed to encrypt the secret store")
    }
    return StoreEnvelope(
      format: formatName, version: currentVersion,
      kdf: KDFSection(
        algorithm: "scrypt", salt: Data(parameters.salt).base64EncodedString(), n: parameters.n,
        r: parameters.r, p: parameters.p),
      cipher: CipherSection(
        algorithm: "aes-256-gcm", nonce: Data(box.nonce).base64EncodedString(),
        ciphertext: box.ciphertext.base64EncodedString(), tag: box.tag.base64EncodedString()))
  }

  func open(key: SymmetricKey, parameters: ScryptParameters) throws(EnclaveStoreError) -> Data {
    guard let nonce = Data(base64Encoded: cipher.nonce), nonce.count == 12,
      let ciphertext = Data(base64Encoded: cipher.ciphertext),
      let tag = Data(base64Encoded: cipher.tag), tag.count == 16
    else { throw .malformed("invalid cipher encoding") }
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
      return try AES.GCM.open(box, using: key, authenticating: Self.additionalData(parameters))
    } catch {
      throw .unlockFailed
    }
  }
}

/// The decrypted dictionary. Values stay base64 in memory only as long as
/// the unlocked store object lives.
struct StorePlaintext: Codable {
  struct Entry: Codable {
    var value: String
    let createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
      case value
      case createdAt = "created_at"
      case updatedAt = "updated_at"
    }
  }

  static let currentVersion = 1

  var version: Int
  var entries: [String: Entry]

  static let empty = StorePlaintext(version: currentVersion, entries: [:])

  func validated() throws(EnclaveStoreError) -> StorePlaintext {
    guard version == Self.currentVersion else { throw .malformed("unsupported entry version") }
    guard entries.count <= StoreLimits.entries else {
      throw .limitExceeded("more than \(StoreLimits.entries) entries")
    }
    for name in entries.keys {
      do {
        _ = try SecretName(name)
      } catch {
        throw .malformed("invalid secret name in store")
      }
    }
    return self
  }
}
