import CryptoKit
import Foundation
import IsoCore
import LocalAuthentication
import Security

/// The device-bound factor: a P-256 key-agreement key the store's Device
/// Unlock Key (DUK) is sealed to. Production uses the Secure Enclave; tests
/// use a software key with the same sealing format.
package protocol DeviceFactor: Sendable {
  /// Creates a new key. Returns its opaque representation and public key.
  func createKey() throws(EnclaveStoreError) -> (
    representation: [UInt8], publicKey: P256.KeyAgreement.PublicKey
  )
  /// ECDH with `peer` using the stored key; may require user presence.
  func agree(representation: [UInt8], with peer: P256.KeyAgreement.PublicKey)
    throws(EnclaveStoreError) -> SharedSecret
}

/// The Secure Enclave key: `WhenUnlockedThisDeviceOnly`, `.privateKeyUsage`
/// and `.userPresence`. Never created during an unlock.
package struct SecureEnclaveFactor: DeviceFactor {
  package let reason: String

  package init(reason: String = "Unlock Iso secrets") { self.reason = reason }

  package static var available: Bool { SecureEnclave.isAvailable }

  package func createKey() throws(EnclaveStoreError) -> (
    representation: [UInt8], publicKey: P256.KeyAgreement.PublicKey
  ) {
    guard SecureEnclave.isAvailable else { throw .secureEnclaveUnavailable }
    var error: Unmanaged<CFError>?
    guard
      let access = SecAccessControlCreateWithFlags(
        nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .userPresence],
        &error)
    else { throw .io("Failed to create Secure Enclave access control") }
    do {
      let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
      return (Array(key.dataRepresentation), key.publicKey)
    } catch {
      throw .io("Failed to create the Secure Enclave key")
    }
  }

  package func agree(representation: [UInt8], with peer: P256.KeyAgreement.PublicKey)
    throws(EnclaveStoreError) -> SharedSecret
  {
    guard SecureEnclave.isAvailable else { throw .enclaveKeyUnavailable }
    let context = LAContext()
    context.localizedReason = reason
    let key: SecureEnclave.P256.KeyAgreement.PrivateKey
    do {
      key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: Data(representation), authenticationContext: context)
    } catch {
      throw .enclaveKeyUnavailable
    }
    do {
      return try key.sharedSecretFromKeyAgreement(with: peer)
    } catch {
      // A cancelled or failed user-presence check.
      throw .unlockFailed
    }
  }
}

/// `device.sekey`: the key representation plus its SHA-256. CryptoKit traps
/// (rather than throws) on some corrupted representations, so the digest is
/// verified before the bytes reach it (spec §9.7).
struct DeviceKeyFile: Codable, Equatable {
  static let currentVersion = 1

  let version: Int
  let key: String
  let sha256: String

  init(representation: [UInt8]) {
    version = Self.currentVersion
    key = Data(representation).base64EncodedString()
    sha256 = Self.digest(representation)
  }

  static func digest(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }

  /// The verified representation, or `enclaveKeyUnavailable`.
  func representation() throws(EnclaveStoreError) -> [UInt8] {
    guard version == Self.currentVersion, let data = Data(base64Encoded: key),
      (1...4096).contains(data.count), Self.digest(Array(data)) == sha256
    else { throw .enclaveKeyUnavailable }
    return Array(data)
  }
}

/// `store-duk.sealed`: `version(1) || ephemeral public key (X9.63, 65) ||
/// nonce (12) || ciphertext (32) || tag (16)`.
enum SealedDeviceUnlockKey {
  static let version: UInt8 = 1
  static let info = Data("iso/secrets/enclave-duk/v1".utf8)
  static let length = 1 + 65 + 12 + 32 + 16

  static func seal(
    _ duk: SymmetricKey, to recipient: P256.KeyAgreement.PublicKey,
    ephemeral: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey(),
    nonce: AES.GCM.Nonce = AES.GCM.Nonce()
  ) throws(EnclaveStoreError) -> [UInt8] {
    do {
      let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
      let wrap = wrapKey(shared, ephemeral: ephemeral.publicKey)
      let plaintext = duk.withUnsafeBytes { Data($0) }
      let box = try AES.GCM.seal(plaintext, using: wrap, nonce: nonce)
      return [version] + Array(ephemeral.publicKey.x963Representation) + Array(box.nonce)
        + Array(box.ciphertext) + Array(box.tag)
    } catch {
      throw .io("Failed to seal the device unlock key")
    }
  }

  static func ephemeralKey(_ sealed: [UInt8]) throws(EnclaveStoreError)
    -> P256.KeyAgreement.PublicKey
  {
    guard sealed.count == length, sealed[0] == version else {
      throw .malformed("store-duk.sealed has an unexpected size or version")
    }
    do {
      return try P256.KeyAgreement.PublicKey(x963Representation: sealed[1..<66])
    } catch {
      throw .malformed("store-duk.sealed has an invalid ephemeral key")
    }
  }

  static func open(_ sealed: [UInt8], shared: SharedSecret) throws(EnclaveStoreError)
    -> SymmetricKey
  {
    let ephemeral = try ephemeralKey(sealed)
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: sealed[66..<78]), ciphertext: sealed[78..<110],
        tag: sealed[110..<126])
      return SymmetricKey(data: try AES.GCM.open(box, using: wrapKey(shared, ephemeral: ephemeral)))
    } catch {
      throw .unlockFailed
    }
  }

  static func wrapKey(_ shared: SharedSecret, ephemeral: P256.KeyAgreement.PublicKey)
    -> SymmetricKey
  {
    shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: ephemeral.x963Representation, sharedInfo: info,
      outputByteCount: 32)
  }
}
