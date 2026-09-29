import CryptoExtras
import CryptoKit
import Foundation
import IsoCore
import Testing

@testable import IsoSecrets

/// A software stand-in for the Secure Enclave with the same sealing format.
/// `representation` is the raw private key.
private struct SoftwareFactor: DeviceFactor {
  func createKey() throws(EnclaveStoreError) -> (
    representation: [UInt8], publicKey: P256.KeyAgreement.PublicKey
  ) {
    let key = P256.KeyAgreement.PrivateKey()
    return (Array(key.rawRepresentation), key.publicKey)
  }

  func agree(representation: [UInt8], with peer: P256.KeyAgreement.PublicKey)
    throws(EnclaveStoreError) -> SharedSecret
  {
    do {
      return try P256.KeyAgreement.PrivateKey(rawRepresentation: representation)
        .sharedSecretFromKeyAgreement(with: peer)
    } catch {
      throw .enclaveKeyUnavailable
    }
  }
}

/// Counts key creation so a test can prove unlock never mints a key.
private final class CountingFactor: DeviceFactor, @unchecked Sendable {
  let inner = SoftwareFactor()
  var created = 0
  func createKey() throws(EnclaveStoreError) -> (
    representation: [UInt8], publicKey: P256.KeyAgreement.PublicKey
  ) {
    created += 1
    return try inner.createKey()
  }
  func agree(representation: [UInt8], with peer: P256.KeyAgreement.PublicKey)
    throws(EnclaveStoreError) -> SharedSecret
  {
    try inner.agree(representation: representation, with: peer)
  }
}

private func hex(_ text: String) -> [UInt8] {
  var out: [UInt8] = []
  var index = text.startIndex
  while index < text.endIndex {
    let next = text.index(index, offsetBy: 2)
    out.append(UInt8(text[index..<next], radix: 16)!)
    index = next
  }
  return out
}

private func bytes(_ key: SymmetricKey) -> [UInt8] { key.withUnsafeBytes { Array($0) } }

/// Minimum-cost parameters that still pass the reader bounds.
private let fast = try! ScryptParameters(
  n: 1 << 15, r: 8, p: 1, salt: Array(repeating: 7, count: 16))
private let passphrase = Secret(Array("correct horse battery".utf8))

private struct Scratch {
  let root: String
  let store: EnclaveStore
  var directory: String { store.directory }

  init(factor: any DeviceFactor = SoftwareFactor()) throws {
    root = FileManager.default.temporaryDirectory.appending(path: "iso-secrets-\(UUID())").path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    store = EnclaveStore(
      directory: root + "/secrets", factor: factor,
      now: { Date(timeIntervalSince1970: 1_800_000_000) })
  }

  func initialize() throws {
    try store.initialize(passphrase: passphrase, acknowledgement: .accepted, parameters: fast)
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: root) }
}

private func name(_ text: String) -> SecretName { try! SecretName(text) }

// MARK: - Vectors

@Test func scryptMatchesRFC7914Vectors() throws {
  let two = try CryptoExtras.KDF.Scrypt.deriveKey(
    from: Array("password".utf8), salt: Array("NaCl".utf8), outputByteCount: 64, rounds: 1024,
    blockSize: 8, parallelism: 16)
  #expect(
    bytes(two)
      == hex(
        "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"
      ))
  let three = try CryptoExtras.KDF.Scrypt.deriveKey(
    from: Array("pleaseletmein".utf8), salt: Array("SodiumChloride".utf8), outputByteCount: 64,
    rounds: 16384, blockSize: 8, parallelism: 1)
  #expect(
    bytes(three)
      == hex(
        "7023bdcb3afd7348461c06cd81fd38ebfda8fbba904f8e3ea9b543f6545da1f2d5432955613f0fcf62d49705242a9af9e61e85dc0d651e40dfcf017b45575887"
      ))
}

@Test func storeKeyNeedsBothFactors() throws {
  let password = SymmetricKey(data: hex(String(repeating: "11", count: 32)))
  let duk = SymmetricKey(data: hex(String(repeating: "22", count: 32)))
  let key = KDF.storeKey(passwordKey: password, deviceUnlockKey: duk)
  let expected = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: password, salt: bytes(duk), info: Data("coop/secrets/store-key/v1".utf8),
    outputByteCount: 32)
  #expect(bytes(key) == bytes(expected))
  #expect(bytes(KDF.storeKey(passwordKey: duk, deviceUnlockKey: password)) != bytes(key))
}

@Test func sealedDeviceUnlockKeyFormatIsLocked() throws {
  let recipient = try P256.KeyAgreement.PrivateKey(
    rawRepresentation: hex(String(repeating: "01", count: 32)))
  let ephemeral = try P256.KeyAgreement.PrivateKey(
    rawRepresentation: hex(String(repeating: "02", count: 32)))
  let duk = SymmetricKey(data: hex(String(repeating: "33", count: 32)))
  let nonce = try AES.GCM.Nonce(data: hex(String(repeating: "44", count: 12)))
  let sealed = try SealedDeviceUnlockKey.seal(
    duk, to: recipient.publicKey, ephemeral: ephemeral, nonce: nonce)
  #expect(sealed.count == 126)
  #expect(sealed[0] == 1)
  #expect(Array(sealed[1..<66]) == Array(ephemeral.publicKey.x963Representation))
  #expect(Array(sealed[66..<78]) == hex(String(repeating: "44", count: 12)))
  let shared = try recipient.sharedSecretFromKeyAgreement(
    with: try SealedDeviceUnlockKey.ephemeralKey(sealed))
  #expect(bytes(try SealedDeviceUnlockKey.open(sealed, shared: shared)) == bytes(duk))
  var tampered = sealed
  tampered[100] ^= 1
  #expect(throws: EnclaveStoreError.unlockFailed) {
    try SealedDeviceUnlockKey.open(tampered, shared: shared)
  }
  #expect(throws: EnclaveStoreError.self) {
    try SealedDeviceUnlockKey.ephemeralKey(Array(sealed.dropLast()))
  }
}

@Test func envelopeBindsTheKDFParameters() throws {
  let key = SymmetricKey(size: .bits256)
  let envelope = try StoreEnvelope.seal(Data("{}".utf8), key: key, parameters: fast)
  #expect(
    StoreEnvelope.additionalData(fast)
      == Data("coop-secrets:v1:scrypt:32768:8:1:\(Data(fast.salt).base64EncodedString())".utf8))
  #expect(try envelope.open(key: key, parameters: fast) == Data("{}".utf8))
  let other = try ScryptParameters(n: 1 << 16, r: 8, p: 1, salt: fast.salt)
  #expect(throws: EnclaveStoreError.unlockFailed) { try envelope.open(key: key, parameters: other) }
}

// MARK: - Bounds

@Test func scryptParametersAreBoundedBeforeUse() {
  let salt = [UInt8](repeating: 1, count: 16)
  #expect(throws: EnclaveStoreError.self) {
    try ScryptParameters(n: 1 << 14, r: 8, p: 1, salt: salt)
  }
  #expect(throws: EnclaveStoreError.self) {
    try ScryptParameters(n: 1 << 21, r: 8, p: 1, salt: salt)
  }
  #expect(throws: EnclaveStoreError.self) {
    try ScryptParameters(n: 3 << 15, r: 8, p: 1, salt: salt)
  }
  #expect(throws: EnclaveStoreError.self) {
    try ScryptParameters(n: 1 << 17, r: 4, p: 1, salt: salt)
  }
  #expect(throws: EnclaveStoreError.self) {
    try ScryptParameters(n: 1 << 17, r: 8, p: 2, salt: salt)
  }
  #expect(throws: EnclaveStoreError.self) {
    try ScryptParameters(n: 1 << 17, r: 8, p: 1, salt: Array(salt.prefix(15)))
  }
  #expect(throws: EnclaveStoreError.self) {
    try ScryptParameters(n: 1 << 17, r: 8, p: 1, salt: [UInt8](repeating: 0, count: 65))
  }
  #expect(ScryptParameters.fresh().n == 1 << 17)
}

@Test func secretNamesFollowTheGrammar() {
  for good in [
    "anthropic", "a", "database-password", "x.y_z-1", String(repeating: "a", count: 128),
  ] {
    #expect((try? SecretName(good)) != nil, "\(good)")
  }
  for bad in [
    "", "-lead", ".dot", "a/b", "../x", "a b", "tab\t", "ü", String(repeating: "a", count: 129),
  ] {
    #expect(throws: ValidationError.self) { try SecretName(bad) }
  }
}

// MARK: - Store lifecycle

@Test func storeLifecycleRoundTrips() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  try s.initialize()
  #expect(try s.store.list(passphrase: passphrase).isEmpty)
  try s.store.set(name("anthropic"), value: Secret(Array("sk-1".utf8)), passphrase: passphrase)
  try s.store.set(name("db"), value: Secret(Array("pw".utf8)), passphrase: passphrase)
  try s.store.set(name("anthropic"), value: Secret(Array("sk-2".utf8)), passphrase: passphrase)
  #expect(try s.store.list(passphrase: passphrase).map(\.name) == [name("anthropic"), name("db")])
  let resolved = try s.store.resolve([name("anthropic"), name("db")], passphrase: passphrase)
  #expect(resolved[name("anthropic")]?.expose() == Array("sk-2".utf8))
  try s.store.remove(name("db"), passphrase: passphrase)
  #expect(throws: EnclaveStoreError.notFound(name("db"))) {
    try s.store.resolve([name("db")], passphrase: passphrase)
  }
  #expect(throws: EnclaveStoreError.notFound(name("db"))) {
    try s.store.remove(name("db"), passphrase: passphrase)
  }
  for file in ["store.v1.json", "device.sekey", "store-duk.sealed", "store.lock"] {
    var info = stat()
    #expect(stat(s.directory + "/" + file, &info) == 0 && info.st_mode & 0o777 == 0o600, "\(file)")
  }
  var info = stat()
  #expect(stat(s.directory, &info) == 0 && info.st_mode & 0o777 == 0o700)
}

@Test func storeFileRevealsNoNamesOrValues() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  try s.initialize()
  try s.store.set(
    name("visible-name"), value: Secret(Array("canary-value".utf8)), passphrase: passphrase)
  for file in ["store.v1.json", "device.sekey", "store-duk.sealed"] {
    let text = String(
      decoding: try Data(contentsOf: URL(fileURLWithPath: s.directory + "/" + file)), as: UTF8.self)
    #expect(!text.contains("visible-name") && !text.contains("canary-value"), "\(file)")
  }
}

@Test func everyRewriteUsesAFreshNonce() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  try s.initialize()
  var nonces = Set<String>()
  for index in 0..<3 {
    try s.store.set(name("k"), value: Secret([UInt8(index)]), passphrase: passphrase)
    let envelope: StoreEnvelope = try EnclaveStore.decode(
      try s.store.readPrivateFile(s.directory + "/store.v1.json"))
    nonces.insert(envelope.cipher.nonce)
  }
  #expect(nonces.count == 3)
}

@Test func wrongPassphraseAndTamperingFailClosed() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  try s.initialize()
  #expect(throws: EnclaveStoreError.unlockFailed) {
    try s.store.list(passphrase: Secret(Array("wrong".utf8)))
  }
  let path = s.directory + "/store.v1.json"
  let original = try Data(contentsOf: URL(fileURLWithPath: path))
  var envelope: StoreEnvelope = try EnclaveStore.decode(Array(original))
  var ciphertext = Array(Data(base64Encoded: envelope.cipher.ciphertext)!)
  ciphertext[0] ^= 1
  envelope = StoreEnvelope(
    format: envelope.format, version: envelope.version, kdf: envelope.kdf,
    cipher: .init(
      algorithm: envelope.cipher.algorithm, nonce: envelope.cipher.nonce,
      ciphertext: Data(ciphertext).base64EncodedString(), tag: envelope.cipher.tag))
  try Data(try EnclaveStore.encode(envelope)).write(to: URL(fileURLWithPath: path))
  chmod(path, 0o600)
  #expect(throws: EnclaveStoreError.unlockFailed) { try s.store.list(passphrase: passphrase) }
  try original.write(to: URL(fileURLWithPath: path))
  #expect(try s.store.list(passphrase: passphrase).isEmpty)
  // An out-of-bounds N is refused before scrypt runs.
  let text = String(decoding: original, as: UTF8.self).replacingOccurrences(
    of: "\"N\":32768", with: "\"N\":2097152")
  try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  #expect(throws: EnclaveStoreError.self) { try s.store.list(passphrase: passphrase) }
}

@Test func wrongDeviceKeyCannotUnlock() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  try s.initialize()
  let other = try Scratch()
  defer { other.cleanup() }
  try other.initialize()
  // Same passphrase, another device key: the DUK does not open.
  let foreign = try Data(contentsOf: URL(fileURLWithPath: other.directory + "/device.sekey"))
  try foreign.write(to: URL(fileURLWithPath: s.directory + "/device.sekey"))
  #expect(throws: EnclaveStoreError.unlockFailed) { try s.store.list(passphrase: passphrase) }
}

@Test func missingOrCorruptDeviceKeyIsPermanentAndMintsNothing() throws {
  let factor = CountingFactor()
  let s = try Scratch(factor: factor)
  defer { s.cleanup() }
  try s.initialize()
  #expect(factor.created == 1)
  let keyPath = s.directory + "/device.sekey"
  let original = try Data(contentsOf: URL(fileURLWithPath: keyPath))
  var corrupt: DeviceKeyFile = try EnclaveStore.decode(Array(original))
  corrupt = try EnclaveStore.decode(
    Array(
      String(decoding: original, as: UTF8.self).replacingOccurrences(
        of: corrupt.sha256, with: String(repeating: "0", count: 64)
      ).utf8))
  try Data(try EnclaveStore.encode(corrupt)).write(to: URL(fileURLWithPath: keyPath))
  chmod(keyPath, 0o600)
  #expect(throws: EnclaveStoreError.enclaveKeyUnavailable) {
    try s.store.list(passphrase: passphrase)
  }
  unlink(keyPath)
  #expect(throws: EnclaveStoreError.enclaveKeyUnavailable) {
    try s.store.list(passphrase: passphrase)
  }
  #expect(factor.created == 1)
  #expect(!FileManager.default.fileExists(atPath: keyPath))
  #expect(EnclaveStoreError.enclaveKeyUnavailable.description.contains("no recovery path"))
}

@Test func unsafePermissionsFailClosed() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  try s.initialize()
  let path = s.directory + "/store.v1.json"
  chmod(path, 0o666)
  #expect(throws: EnclaveStoreError.unsafePermissions(path)) {
    try s.store.list(passphrase: passphrase)
  }
  chmod(path, 0o600)
  chmod(s.directory, 0o755)
  #expect(throws: EnclaveStoreError.unsafePermissions(s.directory)) {
    try s.store.list(passphrase: passphrase)
  }
  chmod(s.directory, 0o700)
  let moved = s.root + "/real.json"
  try FileManager.default.moveItem(atPath: path, toPath: moved)
  try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: moved)
  #expect(throws: EnclaveStoreError.unsafePermissions(path)) {
    try s.store.list(passphrase: passphrase)
  }
}

@Test func initializeRefusesAnExistingStoreAndLimitsValues() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  #expect(throws: EnclaveStoreError.notInitialized) { try s.store.list(passphrase: passphrase) }
  try s.initialize()
  #expect(throws: EnclaveStoreError.alreadyInitialized) { try s.initialize() }
  #expect(throws: EnclaveStoreError.self) {
    try s.store.set(
      name("big"), value: Secret([UInt8](repeating: 0, count: StoreLimits.valueBytes + 1)),
      passphrase: passphrase)
  }
}

@Test func failedInitializationLeavesNoState() throws {
  struct Failing: DeviceFactor {
    func createKey() throws(EnclaveStoreError) -> (
      representation: [UInt8], publicKey: P256.KeyAgreement.PublicKey
    ) {
      let key = P256.KeyAgreement.PrivateKey()
      return (Array(key.rawRepresentation), key.publicKey)
    }
    func agree(representation: [UInt8], with peer: P256.KeyAgreement.PublicKey)
      throws(EnclaveStoreError) -> SharedSecret
    { throw .unlockFailed }
  }
  let s = try Scratch(factor: Failing())
  defer { s.cleanup() }
  #expect(throws: EnclaveStoreError.unlockFailed) { try s.initialize() }
  for file in ["store.v1.json", "device.sekey", "store-duk.sealed"] {
    #expect(!FileManager.default.fileExists(atPath: s.directory + "/" + file), "\(file)")
  }
}

@Test func interruptedInitializationIsReportedNotLooped() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  try s.initialize()
  unlink(s.directory + "/store.v1.json")
  let expected = EnclaveStoreError.incomplete(s.directory + "/device.sekey")
  #expect(throws: expected) { try s.store.list(passphrase: passphrase) }
  #expect(throws: expected) { try s.initialize() }
  #expect(expected.description.contains("remove the leftover device key files"))
}

@Test func lockFileMustBeAPrivateRegularFile() throws {
  let s = try Scratch()
  defer { s.cleanup() }
  try s.initialize()
  let lock = s.directory + "/store.lock"
  let target = s.root + "/victim"
  FileManager.default.createFile(atPath: target, contents: Data("keep".utf8))
  unlink(lock)
  try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: target)
  #expect(throws: EnclaveStoreError.unsafePermissions(lock)) {
    try s.store.list(passphrase: passphrase)
  }
  #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep")
}
