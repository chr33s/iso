import CoopCore
import CryptoExtras
import CryptoKit
import Foundation

/// scrypt parameters as stored in the envelope. Construction enforces the
/// reader bounds (spec §13.3) before any derivation runs.
public struct ScryptParameters: Sendable, Equatable {
  public static let minimumLogN = 15
  public static let maximumLogN = 20
  public static let saltRange = 16...64

  public let n: Int
  public let r: Int
  public let p: Int
  public let salt: [UInt8]

  public init(n: Int, r: Int, p: Int, salt: [UInt8]) throws(EnclaveStoreError) {
    guard n > 0, n & (n - 1) == 0,
      (1 << Self.minimumLogN...1 << Self.maximumLogN).contains(n)
    else { throw .malformed("scrypt N must be a power of two in 2^15...2^20") }
    guard r == 8, p == 1 else { throw .malformed("scrypt r must be 8 and p must be 1") }
    guard Self.saltRange.contains(salt.count) else {
      throw .malformed("scrypt salt must be 16-64 bytes")
    }
    self.n = n
    self.r = r
    self.p = p
    self.salt = salt
  }

  /// The release default: N = 2^17, r = 8, p = 1, a fresh 16-byte salt.
  public static func fresh() -> ScryptParameters {
    try! ScryptParameters(n: 1 << 17, r: 8, p: 1, salt: randomBytes(16))
  }
}

enum KDF {
  static let storeKeyInfo = Data("coop/secrets/store-key/v1".utf8)

  /// `scrypt(passphrase, salt, N, r, p, 32)`.
  static func passwordKey(_ passphrase: Secret<[UInt8]>, _ parameters: ScryptParameters)
    throws(EnclaveStoreError) -> SymmetricKey
  {
    do {
      return try CryptoExtras.KDF.Scrypt.deriveKey(
        from: passphrase.expose(), salt: parameters.salt, outputByteCount: 32,
        rounds: parameters.n, blockSize: parameters.r, parallelism: parameters.p)
    } catch {
      throw .io("scrypt derivation failed")
    }
  }

  /// `HKDF-SHA256(ikm: passwordKey, salt: DUK, info: "coop/secrets/store-key/v1")`.
  /// Neither factor alone determines the result.
  static func storeKey(passwordKey: SymmetricKey, deviceUnlockKey: SymmetricKey) -> SymmetricKey {
    let salt = deviceUnlockKey.withUnsafeBytes { Data($0) }
    return HKDF<SHA256>.deriveKey(
      inputKeyMaterial: passwordKey, salt: salt, info: storeKeyInfo, outputByteCount: 32)
  }
}

func randomBytes(_ count: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
  precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
  return bytes
}
