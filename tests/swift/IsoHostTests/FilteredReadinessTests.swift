import CryptoKit
import Foundation
import IsoCore
import Testing

@testable import IsoHost

private let probeBoot = String(repeating: "a", count: 32)
private let probePublicKey = "7d59c5623dd40a74aa4d5a32ac645d3b3f95daeae4c22be25476dd6a486f7382"
private let probeNonce = String(repeating: "d", count: 32)
private let probeHash = "sha256:58f3dc06f00b17767fb781f32c1260e5193096daa6a74125261ae7be8a5a89d4"
// Independently generated with OpenSSL 3.6.5 Ed25519, seed 0xbb repeated 32 times.
private let probeSignature =
  "CkfmyfRYE4WJyxQPj+Z7snqWgWLM5LB5w3YEUQX6Akg0HgWQQA1I5MW6tDkkmAMJO4Sm6G23hmPDOTWaBGCxAg=="

private func probeReply(change: String = "") throws -> [UInt8] {
  let signed: [String: String] = [
    "signed-nonce":
      "mlo1/31fMxqX4uRrZdQBDBjaNDIo9/ZFTTVSmiKfz3GqZLebiico0IZEl1tgYFp11URDueqj8UTJv8TyHMTQDg==",
    "signed-boot":
      "A5CMJNgKiEekYUMp9S4cnt3E74renGeJMq9dPMBaBorKHfcOq2aEE0gDN2uX4DnpPs/Cho994hdv0YDVEyiqDw==",
    "signed-policy":
      "/vRGFf5O8Kzg7M7Q82SBod9exSFovYfdS/i9+rTVptVsD7Be4ig1Ey8mUkMe1vjtZJeDEPJlLCx8kqjurDj7Bw==",
  ]
  let field = change.replacingOccurrences(of: "signed-", with: "")
  var object: [String: Any] = [
    "version": field == "version" ? 1 : 2,
    "nonce": field == "nonce" ? String(repeating: "e", count: 32) : probeNonce,
    "bootID": field == "boot" ? String(repeating: "e", count: 32) : probeBoot,
    "policyHash": field == "policy" ? "sha256:other" : probeHash,
    "signature": signed[change]
      ?? (change == "signature"
        ? Data(repeating: 0, count: 64).base64EncodedString() : probeSignature)
      ,
  ]
  if change == "legacy" {
    object["version"] = 1
    object.removeValue(forKey: "signature")
    object["authentication"] = Data(repeating: 0, count: 32).base64EncodedString()
  }
  let body = try JSONSerialization.data(withJSONObject: object)
  let status = change == "status" ? "403 Forbidden" : "200 OK"
  let length = body.count + (change == "length" ? 1 : 0)
  let duplicate = change == "duplicate" ? "Content-Length: \(length)\r\n" : ""
  var reply =
    Array(
      "HTTP/1.1 \(status)\r\nContent-Length: \(length)\r\n\(duplicate)Connection: close\r\n\r\n"
        .utf8) + body
  if change == "truncated" { reply.removeLast() }
  if change == "oversize" { reply += [UInt8](repeating: 32, count: 1025) }
  return reply
}

@Test func filteredReadinessAcceptsTheIndependentWireVector() throws {
  #expect(
    FilteredReadiness.verifies(
      try probeReply(), nonce: probeNonce,
      policy: .init(bootID: probeBoot, policyHash: probeHash),
      key: try .init(encoded: probePublicKey)))
}

@Test(arguments: [
  "signature", "version", "nonce", "boot", "policy", "status", "length", "duplicate", "truncated",
  "oversize", "wrong-key", "signed-nonce", "signed-boot", "signed-policy", "legacy",
])
func filteredReadinessRejectsForgeryReplayAndFraming(change: String) throws {
  let publicKey =
    change == "wrong-key"
    ? FilteredReadiness.SigningIdentity().verificationKey : try .init(encoded: probePublicKey)
  #expect(
    !FilteredReadiness.verifies(
      try probeReply(change: change), nonce: probeNonce,
      policy: .init(bootID: probeBoot, policyHash: probeHash), key: publicKey))
}

@Test func filteredReadinessDoesNotForwardTheHostSigningKey() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let capability = Secret(String(repeating: "c", count: 64))
  let identity = try FilteredReadiness.SigningIdentity(seed: Data(repeating: 0xbb, count: 32))
  let subprocess = try FilteredReadiness.guestRequest(
    guest.target,
    client: SSHClient(environment: [
      "PATH": "/usr/bin:/bin", "OPENAI_API_KEY": identity.startupKey.expose(),
    ]),
    port: 10788, nonce: probeNonce, capability: capability)
  let input = String(decoding: try #require(subprocess.input), as: UTF8.self)
  #expect(input.hasPrefix("10788\nGET /__iso/egress-ready HTTP/1.1\r\n"))
  #expect(input.contains(probeNonce))
  #expect(input.contains(Data("iso:\(capability.expose())".utf8).base64EncodedString()))
  #expect(!input.contains(identity.startupKey.expose()))
  #expect(!subprocess.arguments.joined().contains(capability.expose()))
  #expect(!subprocess.arguments.joined().contains(probeNonce))
  #expect(subprocess.environment["OPENAI_API_KEY"] == nil)
  #expect(subprocess.deadline == .seconds(5))
  #expect(subprocess.outputLimit == 1024)
  #expect(subprocess.overflow == .fail)
}

@Test func filteredReadinessPersistsOnlyPublicMaterialEvenWhenWorkspaceCopiesIt() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let project = guest.root + "/project"
  let instance = try testInstance(project + "/vm-data/instances/demo")
  let identity = try FilteredReadiness.SigningIdentity(seed: Data(repeating: 0xbb, count: 32))
  try identity.persistVerificationKey(instance)
  let key = try FilteredReadiness.readVerificationKey(at: FilteredReadiness.keyPath(instance))
  #expect(key.encoded == probePublicKey)
  #expect(key.encoded != identity.startupKey.expose())
  let archive = try ProcessRunner().capture(
    .init(
      executable: "/usr/bin/tar",
      arguments: ["cf", "-"] + defaultExcludes.map { "--exclude=\($0)" } + ["-C", project, "."],
      environment: [:], deadline: .seconds(5), outputLimit: 64 << 10))
  try #require(archive.termination.succeeded)
  let transferred = String(decoding: archive.stdout, as: UTF8.self)
  #expect(transferred.contains(probePublicKey))
  #expect(!transferred.contains(identity.startupKey.expose()))
  // Knowing the copied public bytes does not give the guest a signing key.
  let guessed = try Curve25519.Signing.PrivateKey(rawRepresentation: key.value.rawRepresentation)
  let message = Data("iso-egress-readiness-v2\n\(probeNonce)\n\(probeBoot)\n\(probeHash)\n".utf8)
  #expect(!key.value.isValidSignature(try guessed.signature(for: message), for: message))
}

@Test func filteredReadinessControlErrorsDoNotMasqueradeAsAbsence() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let path = FilteredReadiness.keyPath(instance)
  let missing = try #require(throws: HostError.self) {
    try FilteredReadiness.readVerificationKey(at: path)
  }
  #expect(missing.message.contains("missing readiness identity"))
  for invalid in ["", "garbage", probePublicKey + "\n", probePublicKey.uppercased()] {
    try writeFile(path, invalid)
    let error = try #require(throws: HostError.self) {
      try FilteredReadiness.readVerificationKey(at: path)
    }
    #expect(error.message.contains("invalid readiness identity"))
  }
  try AtomicFile.write(Array(probePublicKey.utf8), to: path, mode: .atMost(0o600))
  #expect(try FilteredReadiness.readVerificationKey(at: path).encoded == probePublicKey)
  #expect(
    try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
  let link = path + "-link"
  try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
  let unreadable = try #require(throws: HostError.self) {
    try FilteredReadiness.readVerificationKey(at: link)
  }
  #expect(!unreadable.message.contains("missing readiness identity"))
}
