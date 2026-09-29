import CoopCore
import CryptoKit
import Foundation
import Testing

@testable import CoopHost

// MARK: - Helpers

func signerKey(_ key: Curve25519.Signing.PrivateKey) -> SignerKey {
  try! SignerKey(blob: SignerKey.prefix + Array(key.publicKey.rawRepresentation))
}

/// An armored `SSHSIG`, byte for byte what `ssh-keygen -Y sign` writes.
func sshSign(
  _ message: [UInt8], key: Curve25519.Signing.PrivateKey,
  namespace: String = ReleaseSigners.namespace, hash: String = "sha512",
  trailing: [UInt8] = []
) throws -> String {
  let digest: [UInt8] =
    hash == "sha512" ? Array(SHA512.hash(data: message)) : Array(SHA256.hash(data: message))
  var signed = SSHSignature.magic
  for field in [Array(namespace.utf8), [], Array(hash.utf8), digest] {
    signed += WireReader.encode(field)
  }
  let signature = Array(try key.signature(for: signed))
  var blob = SSHSignature.magic + [0, 0, 0, 1]
  for field in [
    signerKey(key).blob, Array(namespace.utf8), [], Array(hash.utf8),
    WireReader.encode(Array("ssh-ed25519".utf8)) + WireReader.encode(signature),
  ] {
    blob += WireReader.encode(field)
  }
  blob += trailing
  let body = Data(blob).base64EncodedString(options: [
    .lineLength76Characters, .endLineWithLineFeed,
  ])
  return "-----BEGIN SSH SIGNATURE-----\n\(body)\n-----END SSH SIGNATURE-----\n"
}

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../..").standardized.path

// MARK: - SSHSIG verification

@Test func sshSignatureVerifiesOnlyTheSignedBytesFromATrustedKey() throws {
  let key = Curve25519.Signing.PrivateKey()
  let message = Array("abc  coop.tar.gz\n".utf8)
  for hash in ["sha512", "sha256"] {
    try SSHSignature.verify(
      armored: try sshSign(message, key: key, hash: hash), message: message,
      trusted: [signerKey(key)])
  }
  let armored = try sshSign(message, key: key)
  #expect(throws: ReleaseSignatureError.badSignature) {
    try SSHSignature.verify(
      armored: armored, message: Array("abd  coop.tar.gz\n".utf8), trusted: [signerKey(key)])
  }
  let other = signerKey(Curve25519.Signing.PrivateKey())
  #expect(throws: ReleaseSignatureError.untrustedKey(signerKey(key).fingerprint)) {
    try SSHSignature.verify(armored: armored, message: message, trusted: [other])
  }
  #expect(throws: ReleaseSignatureError.untrustedKey(signerKey(key).fingerprint)) {
    try SSHSignature.verify(armored: armored, message: message, trusted: [])
  }
  // A signature the same key made for another purpose does not transfer.
  #expect(throws: ReleaseSignatureError.wrongNamespace("git")) {
    try SSHSignature.verify(
      armored: try sshSign(message, key: key, namespace: "git"), message: message,
      trusted: [signerKey(key)])
  }
}

@Test func malformedSignaturesAreRejected() throws {
  let key = Curve25519.Signing.PrivateKey()
  let message = Array("x".utf8)
  for armored in [
    "", "-----BEGIN SSH SIGNATURE-----\n-----END SSH SIGNATURE-----\n",
    "-----BEGIN SSH SIGNATURE-----\n!!!\n-----END SSH SIGNATURE-----\n",
    "-----BEGIN SSH SIGNATURE-----\nU1NIU0lH\n-----END SSH SIGNATURE-----\n",
    try sshSign(message, key: key, trailing: [0]),
    try sshSign(message, key: key, hash: "md5"),
  ] {
    do {
      try SSHSignature.verify(armored: armored, message: message, trusted: [signerKey(key)])
      Issue.record("accepted \(armored.debugDescription)")
    } catch {
      guard case .malformed = error else {
        Issue.record("\(armored.debugDescription): \(error)")
        continue
      }
    }
  }
}

/// Interoperability: a signature made by the real `ssh-keygen -Y sign`.
@Test func verifiesSignaturesMadeByOpenSSH() throws {
  let directory = try temporaryDirectory("sshsig")
  defer { try? FileManager.default.removeItem(atPath: directory) }
  func run(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }
  try run(["-q", "-t", "ed25519", "-N", "", "-f", directory + "/key"])
  let sums = "\(String(repeating: "a", count: 64))  coop-v1.0.0-aarch64-apple-darwin.tar.gz\n"
  try writeUpdateFile(directory + "/SHA256SUMS", sums)
  try run([
    "-Y", "sign", "-f", directory + "/key", "-n", ReleaseSigners.namespace,
    directory + "/SHA256SUMS",
  ])
  let publicKey = try #require(readText(directory + "/key.pub"))
  let armored = try #require(readText(directory + "/SHA256SUMS.sig"))
  let trusted = try SignerKey(parsing: publicKey.trimmingCharacters(in: .whitespacesAndNewlines))
  try SSHSignature.verify(armored: armored, message: Array(sums.utf8), trusted: [trusted])
  #expect(throws: ReleaseSignatureError.badSignature) {
    try SSHSignature.verify(armored: armored, message: Array((sums + " ").utf8), trusted: [trusted])
  }
}

// MARK: - Signer list

@Test func compiledSignersAreValidEd25519Keys() throws {
  #expect(!ReleaseSigners.keys.isEmpty)
  #expect(ReleaseSigners.trusted.count == ReleaseSigners.keys.count)
  #expect(Set(ReleaseSigners.trusted.map(\.blob)).count == ReleaseSigners.keys.count)
}

/// The signer list and namespace live in four places with no compiler link:
/// this binary, the allowed_signers file the signing script checks against,
/// the installer and the signing script.
@Test func signerListAgreesAcrossBinaryInstallerAndSigningScript() throws {
  let allowed = try String(
    contentsOfFile: repositoryRoot + "/.github/release-signers", encoding: .utf8)
  let expected = ReleaseSigners.keys.map {
    "release namespaces=\"\(ReleaseSigners.namespace)\" \($0)"
  }
  #expect(
    allowed.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init) == expected)
  let installer = try String(contentsOfFile: repositoryRoot + "/install.sh", encoding: .utf8)
  #expect(installer.contains("SIGNATURE_NAMESPACE=\"\(ReleaseSigners.namespace)\"\n"))
  #expect(
    installer.contains("ALLOWED_SIGNERS='\(expected.joined(separator: "\n"))'\n"))
  #expect(
    installer.contains(#"verify_signature "${TMPDIR}/SHA256SUMS" "${TMPDIR}/SHA256SUMS.sig""#))
  let script = try String(
    contentsOfFile: repositoryRoot + "/scripts/sign-release.py", encoding: .utf8)
  #expect(script.contains("NAMESPACE = \"\(ReleaseSigners.namespace)\"\n"))
  let workflow = try String(
    contentsOfFile: repositoryRoot + "/.github/workflows/release.yml", encoding: .utf8)
  #expect(workflow.contains("gh release create \"$TAG\" --draft "))
}
