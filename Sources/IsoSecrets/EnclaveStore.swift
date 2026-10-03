import CryptoKit
import Foundation
import IsoCore

/// A held `store.lock`; released explicitly or on deinit.
final class StoreLock {
  private var descriptor: Int32
  init(descriptor: Int32) { self.descriptor = descriptor }
  func release() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }
  deinit { release() }
}

/// Proof that the operator accepted the no-recovery warning (D-001).
package enum NoRecoveryAcknowledgement: Sendable { case accepted }

package struct SecretMetadata: Sendable, Equatable {
  package let name: SecretName
  package let createdAt: String
  package let updatedAt: String
}

/// The Secure Enclave-bound local secret store (embedded-secrets spec).
///
/// Unlocking needs both the passphrase (scrypt) and the device unlock key
/// sealed to the device factor; either alone decrypts nothing. Every
/// operation unlocks once; nothing is cached between calls.
package struct EnclaveStore: Sendable {
  package let directory: String
  let factor: any DeviceFactor
  let now: @Sendable () -> Date

  package init(
    directory: String, factor: any DeviceFactor = SecureEnclaveFactor(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.directory = directory
    self.factor = factor
    self.now = now
  }

  var storePath: String { directory + "/store.v1.json" }
  var deviceKeyPath: String { directory + "/device.sekey" }
  var sealedKeyPath: String { directory + "/store-duk.sealed" }
  var lockPath: String { directory + "/store.lock" }

  package var exists: Bool { FileManager.default.fileExists(atPath: storePath) }

  /// Key files present without `store.v1.json`: an interrupted `init`, or a
  /// store file lost from this directory.
  package var leftovers: [String] {
    [deviceKeyPath, sealedKeyPath].filter { FileManager.default.fileExists(atPath: $0) }
  }

  // MARK: Lifecycle

  /// Creates the store, then proves a full unlock before reporting success.
  /// Any failure removes what this call created.
  package func initialize(
    passphrase: Secret<[UInt8]>, acknowledgement: NoRecoveryAcknowledgement,
    parameters: ScryptParameters = .fresh()
  ) throws(EnclaveStoreError) {
    try ensureDirectory()
    let lock = try acquireLock()
    defer { lock.release() }
    if exists { throw .alreadyInitialized }
    if let leftover = leftovers.first { throw .incomplete(leftover) }
    var created: [String] = []
    do {
      let (representation, publicKey) = try factor.createKey()
      let duk = SymmetricKey(size: .bits256)
      let sealed = try SealedDeviceUnlockKey.seal(duk, to: publicKey)
      let keyFile = try Self.encode(DeviceKeyFile(representation: representation))
      try createExclusive(keyFile, at: deviceKeyPath)
      created.append(deviceKeyPath)
      try createExclusive(sealed, at: sealedKeyPath)
      created.append(sealedKeyPath)
      let key = KDF.storeKey(
        passwordKey: try KDF.passwordKey(passphrase, parameters), deviceUnlockKey: duk)
      let envelope = try StoreEnvelope.seal(
        Data(try Self.encode(StorePlaintext.empty)), key: key, parameters: parameters)
      try createExclusive(try Self.encode(envelope), at: storePath)
      created.append(storePath)
      _ = try unlock(passphrase)
    } catch {
      for path in created { unlink(path) }
      throw error
    }
  }

  package func set(_ name: SecretName, value: Secret<[UInt8]>, passphrase: Secret<[UInt8]>)
    throws(EnclaveStoreError)
  {
    guard value.expose().count <= StoreLimits.valueBytes else {
      throw .limitExceeded("a secret value is limited to \(StoreLimits.valueBytes) bytes")
    }
    let lock = try acquireLock()
    defer { lock.release() }
    var unlocked = try unlock(passphrase)
    let stamp = Self.timestamp(now())
    let encoded = Data(value.expose()).base64EncodedString()
    if var entry = unlocked.plaintext.entries[name.rawValue] {
      entry.value = encoded
      entry.updatedAt = stamp
      unlocked.plaintext.entries[name.rawValue] = entry
    } else {
      guard unlocked.plaintext.entries.count < StoreLimits.entries else {
        throw .limitExceeded("the store holds at most \(StoreLimits.entries) secrets")
      }
      unlocked.plaintext.entries[name.rawValue] = .init(
        value: encoded, createdAt: stamp, updatedAt: stamp)
    }
    try rewrite(unlocked)
  }

  package func remove(_ name: SecretName, passphrase: Secret<[UInt8]>) throws(EnclaveStoreError) {
    let lock = try acquireLock()
    defer { lock.release() }
    var unlocked = try unlock(passphrase)
    guard unlocked.plaintext.entries.removeValue(forKey: name.rawValue) != nil else {
      throw .notFound(name)
    }
    try rewrite(unlocked)
  }

  package func list(passphrase: Secret<[UInt8]>) throws(EnclaveStoreError) -> [SecretMetadata] {
    let lock = try acquireLock()
    defer { lock.release() }
    let unlocked = try unlock(passphrase)
    return unlocked.plaintext.entries.compactMap { key, entry in
      (try? SecretName(key)).map {
        SecretMetadata(name: $0, createdAt: entry.createdAt, updatedAt: entry.updatedAt)
      }
    }.sorted { $0.name < $1.name }
  }

  /// Batch resolution: one scrypt derivation and one user-presence check for
  /// every name. A missing name fails the whole call.
  package func resolve(_ names: Set<SecretName>, passphrase: Secret<[UInt8]>)
    throws(EnclaveStoreError) -> [SecretName: Secret<[UInt8]>]
  {
    let lock = try acquireLock()
    defer { lock.release() }
    let unlocked = try unlock(passphrase)
    var out: [SecretName: Secret<[UInt8]>] = [:]
    for name in names.sorted() {
      guard let entry = unlocked.plaintext.entries[name.rawValue],
        let value = Data(base64Encoded: entry.value)
      else { throw .notFound(name) }
      out[name] = Secret(Array(value))
    }
    return out
  }

  // MARK: Unlock

  struct Unlocked {
    let key: SymmetricKey
    let parameters: ScryptParameters
    var plaintext: StorePlaintext
  }

  /// Spec §17: permissions, bounded outer format, scrypt, device factor,
  /// HKDF, AES-GCM. The device key is only ever loaded, never created.
  func unlock(_ passphrase: Secret<[UInt8]>) throws(EnclaveStoreError) -> Unlocked {
    try checkDirectory()
    guard exists else {
      if let leftover = leftovers.first { throw .incomplete(leftover) }
      throw .notInitialized
    }
    let envelope: StoreEnvelope = try Self.decode(try readPrivateFile(storePath))
    let parameters = try envelope.parameters()
    let sealed = try readPrivateFile(sealedKeyPath)
    let ephemeral = try SealedDeviceUnlockKey.ephemeralKey(sealed)
    let passwordKey = try KDF.passwordKey(passphrase, parameters)
    let keyBytes: [UInt8]
    do {
      keyBytes = try readPrivateFile(deviceKeyPath)
    } catch .notInitialized {
      throw .enclaveKeyUnavailable
    }
    let keyFile: DeviceKeyFile
    do {
      keyFile = try Self.decode(keyBytes)
    } catch {
      throw .enclaveKeyUnavailable
    }
    let shared = try factor.agree(representation: try keyFile.representation(), with: ephemeral)
    let duk = try SealedDeviceUnlockKey.open(sealed, shared: shared)
    let key = KDF.storeKey(passwordKey: passwordKey, deviceUnlockKey: duk)
    let plaintext: StorePlaintext = try Self.decode(
      Array(try envelope.open(key: key, parameters: parameters)))
    return Unlocked(key: key, parameters: parameters, plaintext: try plaintext.validated())
  }

  /// Re-encrypts with a fresh nonce and replaces the store atomically.
  func rewrite(_ unlocked: Unlocked) throws(EnclaveStoreError) {
    let envelope = try StoreEnvelope.seal(
      Data(try Self.encode(unlocked.plaintext)), key: unlocked.key, parameters: unlocked.parameters)
    let bytes = try Self.encode(envelope)
    guard bytes.count <= StoreLimits.fileBytes else {
      throw .limitExceeded("the encrypted store is limited to \(StoreLimits.fileBytes) bytes")
    }
    do {
      try AtomicFile.write(bytes, to: storePath, mode: .atMost(0o600))
    } catch {
      throw .io("\(error)")
    }
  }

  // MARK: Files

  func ensureDirectory() throws(EnclaveStoreError) {
    let parent = (directory as NSString).deletingLastPathComponent
    for path in [parent, directory] {
      var info = stat()
      if lstat(path, &info) != 0 {
        guard errno == ENOENT, mkdir(path, 0o700) == 0 else {
          throw .io("Failed to create \(path)")
        }
      }
    }
    try checkDirectory()
  }

  func checkDirectory() throws(EnclaveStoreError) {
    var info = stat()
    guard lstat(directory, &info) == 0 else {
      if errno == ENOENT { throw .notInitialized }
      throw .io("Failed to inspect \(directory)")
    }
    guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0
    else { throw .unsafePermissions(directory) }
  }

  /// A regular file owned by the current user and not group/world writable,
  /// read without following links and bounded by the store limit.
  func readPrivateFile(_ path: String) throws(EnclaveStoreError) -> [UInt8] {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
      if errno == ENOENT { throw .notInitialized }
      if errno == ELOOP { throw .unsafePermissions(path) }
      throw .io("Failed to open \(path)")
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o022 == 0
    else { throw .unsafePermissions(path) }
    guard info.st_size <= StoreLimits.fileBytes else {
      throw .limitExceeded("\(path) is larger than \(StoreLimits.fileBytes) bytes")
    }
    var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
    var offset = 0
    while offset < bytes.count {
      let count = bytes[offset...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 && errno == EINTR { continue }
      guard count > 0 else { throw .io("Failed to read \(path)") }
      offset += count
    }
    return bytes
  }

  func createExclusive(_ bytes: [UInt8], at path: String) throws(EnclaveStoreError) {
    do {
      try AtomicFile.createExclusive(bytes, at: path, mode: 0o600)
    } catch {
      throw .io("\(error)")
    }
  }

  /// An exclusive `flock` on `store.lock`, opened without following links
  /// and required to be a private regular file like the other state files.
  func acquireLock() throws(EnclaveStoreError) -> StoreLock {
    try checkDirectory()
    let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else {
      if errno == ELOOP { throw .unsafePermissions(lockPath) }
      throw .io("Failed to open \(lockPath)")
    }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
      info.st_mode & 0o022 == 0
    else {
      close(fd)
      throw .unsafePermissions(lockPath)
    }
    while flock(fd, LOCK_EX) != 0 {
      if errno == EINTR { continue }
      close(fd)
      throw .io("Failed to lock \(lockPath)")
    }
    return StoreLock(descriptor: fd)
  }

  static func encode(_ value: some Encodable) throws(EnclaveStoreError) -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      return Array(try encoder.encode(value))
    } catch {
      throw .io("Failed to serialize secret store state")
    }
  }

  static func decode<T: Decodable>(_ bytes: [UInt8]) throws(EnclaveStoreError) -> T {
    do {
      return try JSONDecoder().decode(T.self, from: Data(bytes))
    } catch {
      throw .malformed("unreadable \(T.self)")
    }
  }

  static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
