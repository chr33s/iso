import Foundation
import Security
import Synchronization

/// The protected credential store (spec sections 8 and 12). GitHub App
/// private keys and webhook secrets live only here, under the record's
/// `credentialReference`; never in configuration, the database, logs, argv,
/// worker requests or guests.
package protocol CredentialStore: Sendable {
  func store(_ secret: [UInt8], reference: String) throws(CIError)
  /// nil when no secret is stored under `reference`.
  func load(_ reference: String) throws(CIError) -> [UInt8]?
  func remove(_ reference: String) throws(CIError)
}

/// The kinds of secret stored per App.
package enum CredentialKind: String, Sendable {
  case appPrivateKey = "app-private-key"
  case webhookSecret = "webhook-secret"

  /// The store reference for `kind` under an App's credential reference.
  package func reference(_ base: String) -> String { base + "/" + rawValue }
}

/// macOS login-keychain generic passwords (service `dev.iso.ci`), readable
/// only while this device is unlocked and never synchronized. The
/// data-protection keychain is not used: it needs a keychain-access-group
/// entitlement that an ad-hoc-signed command-line tool cannot hold.
///
/// Limitation: an unattended controller (a background user service before
/// login, or after the login keychain locks) cannot read the App key; the
/// affected pools stay inactive until the keychain is available again. This
/// is surfaced by status, never worked around with an on-disk copy.
package struct KeychainCredentialStore: CredentialStore {
  package static let service = "dev.iso.ci"

  package init() {}

  private func query(_ reference: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: reference,
    ]
  }

  package func store(_ secret: [UInt8], reference: String) throws(CIError) {
    try Self.validate(reference)
    var attributes = query(reference)
    SecItemDelete(attributes as CFDictionary)
    attributes[kSecValueData as String] = Data(secret)
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    attributes[kSecAttrSynchronizable as String] = false
    let status = SecItemAdd(attributes as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw CIError(.storage, "the keychain refused to store a credential (status \(status))")
    }
  }

  package func load(_ reference: String) throws(CIError) -> [UInt8]? {
    try Self.validate(reference)
    var search = query(reference)
    search[kSecReturnData as String] = true
    search[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(search as CFDictionary, &item)
    switch status {
    case errSecSuccess:
      guard let data = item as? Data else { throw CIError.storage("unexpected keychain item") }
      return Array(data)
    case errSecItemNotFound: return nil
    case errSecInteractionNotAllowed:
      throw CIError(
        .unauthorized,
        "the login keychain is locked, or it needs your approval for this iso-ci executable (a rebuilt or updated executable must be allowed again); unlock it or run the controller in your login session to approve"
      )
    default:
      throw CIError(.storage, "the keychain refused to read a credential (status \(status))")
    }
  }

  package func remove(_ reference: String) throws(CIError) {
    try Self.validate(reference)
    let status = SecItemDelete(query(reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw CIError(.storage, "the keychain refused to remove a credential (status \(status))")
    }
  }

  static func validate(_ reference: String) throws(CIError) {
    guard (1...200).contains(reference.utf8.count),
      reference.unicodeScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" })
    else { throw CIError.invalid("invalid credential reference") }
  }
}

/// In-memory store for tests and dry runs.
package final class MemoryCredentialStore: CredentialStore {
  private let secrets = Mutex<[String: [UInt8]]>([:])

  package init() {}

  package func store(_ secret: [UInt8], reference: String) throws(CIError) {
    try KeychainCredentialStore.validate(reference)
    secrets.withLock { $0[reference] = secret }
  }

  package func load(_ reference: String) throws(CIError) -> [UInt8]? {
    secrets.withLock { $0[reference] }
  }

  package func remove(_ reference: String) throws(CIError) {
    _ = secrets.withLock { $0.removeValue(forKey: reference) }
  }

  package var references: [String] { secrets.withLock { $0.keys.sorted() } }
}
