import CryptoKit
import Darwin
import Foundation
import Testing

@testable import IsoEgressCore

private let key = String(repeating: "b", count: 64)
private let boot = String(repeating: "a", count: 32)
private let nonce = String(repeating: "d", count: 32)
private let capability = String(repeating: "c", count: 64)
private let auth = "Basic " + Data("iso:\(capability)".utf8).base64EncodedString()

private func probeHead(_ authorization: String = auth) -> [UInt8] {
  Array(
    "GET /__iso/egress-ready HTTP/1.1\r\nProxy-Authorization: \(authorization)\r\nX-Iso-Nonce: \(nonce)\r\n\r\n"
      .utf8)
}

private func readiness() throws -> EgressReadiness {
  try EgressReadiness(
    privateKeyHex: key, bootID: boot, allow: .init([try ExactHostname("api.github.com")]))
}

@Test func readinessSignsTheComputedPolicyAndIndependentWireVector() throws {
  let response = try readiness().response(probeHead(), capability: capability, alive: { true })
  let text = String(decoding: response, as: UTF8.self)
  let body = try #require(text.components(separatedBy: "\r\n\r\n").last)
  let object = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
  #expect(object["version"] as? Int == 2)
  #expect(object["bootID"] as? String == boot)
  #expect(object["nonce"] as? String == nonce)
  #expect(
    object["policyHash"] as? String
      == "sha256:58f3dc06f00b17767fb781f32c1260e5193096daa6a74125261ae7be8a5a89d4")
  // OpenSSL 3.6.5 public key/vector anchors the protocol. CryptoKit signing
  // may randomize valid Ed25519 signatures; do not require identical bytes.
  let publicBytes = try #require(
    EgressReadiness.hex(
      "7d59c5623dd40a74aa4d5a32ac645d3b3f95daeae4c22be25476dd6a486f7382", count: 32))
  let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
  let message = Data(
    "iso-egress-readiness-v2\n\(nonce)\n\(boot)\nsha256:58f3dc06f00b17767fb781f32c1260e5193096daa6a74125261ae7be8a5a89d4\n"
      .utf8)
  let signatureText = try #require(object["signature"] as? String)
  let signature = try #require(Data(base64Encoded: signatureText))
  #expect(verifier.isValidSignature(signature, for: message))
  let independent = try #require(
    Data(
      base64Encoded:
        "CkfmyfRYE4WJyxQPj+Z7snqWgWLM5LB5w3YEUQX6Akg0HgWQQA1I5MW6tDkkmAMJO4Sm6G23hmPDOTWaBGCxAg=="))
  #expect(verifier.isValidSignature(independent, for: message))
  #expect(!text.contains(key))
  #expect(!text.contains(capability))
  let other = try EgressReadiness(privateKeyHex: key, bootID: boot, allow: .init([]))
  #expect(other.response(probeHead(), capability: capability, alive: { true }) != response)
}

@Test func readinessRefusesUnauthorizedRevokedAndAmbiguousChallenges() throws {
  let signer = try readiness()
  let denied = ConnectGate.responseBytes(.authRequired)
  #expect(signer.response(probeHead(), capability: capability, alive: { false }) == denied)
  #expect(
    signer.response(
      probeHead("Basic " + Data("iso:wrong".utf8).base64EncodedString()), capability: capability,
      alive: { true }) == denied)
  let valid = String(decoding: probeHead(), as: UTF8.self)
  for invalid in [
    valid + "body", valid.replacingOccurrences(of: "X-Iso-Nonce:", with: "x-iso-nonce:"),
    valid.replacingOccurrences(of: "\r\n", with: "\n"),
    valid.replacingOccurrences(of: nonce, with: "invalid"),
    valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length: 1\r\n\r\n"),
    valid.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Iso-Nonce: \(nonce)\r\n\r\n"),
  ] {
    #expect(signer.response(Array(invalid.utf8), capability: capability, alive: { true }) == denied)
  }
}

@Test func readinessRejectsMalformedSigningIdentities() {
  for invalid in ["", "bad", String(repeating: "B", count: 64), key + "\n"] {
    #expect(throws: PolicyError.self) {
      try EgressReadiness(privateKeyHex: invalid, bootID: boot, allow: .init([]))
    }
  }
  #expect(throws: PolicyError.self) {
    try EgressReadiness(privateKeyHex: key, bootID: "boot", allow: .init([]))
  }
}

@Test func readinessWritesWithoutSigpipeAndRestoresFlags() throws {
  var pair: [Int32] = [-1, -1]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  defer { close(pair[0]) }
  let flags = fcntl(pair[0], F_GETFL)
  let response = try readiness().response(probeHead(), capability: capability, alive: { true })
  #expect(EgressReadiness.write(response, to: pair[0], alive: { true }))
  #expect(fcntl(pair[0], F_GETFL) == flags)
  var received = [UInt8](repeating: 0, count: 1024)
  let count = recv(pair[1], &received, received.count, 0)
  #expect(Array(received.prefix(max(0, count))) == response)
  close(pair[1])
  var noSignal: Int32 = 0
  var length = socklen_t(MemoryLayout<Int32>.size)
  try #require(getsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, &length) == 0)
  #expect(noSignal == 1)
  // Keep a no-SIGPIPE mutation an assertion failure, not a dead test process.
  guard noSignal == 1 else { return }
  #expect(!EgressReadiness.write(response, to: pair[0], alive: { true }))
  #expect(fcntl(pair[0], F_GETFL) == flags)
  #expect(!EgressReadiness.write(response, to: pair[0], alive: { false }))
}

@Test func readinessPausedWriterHasAMonotonicDeadline() throws {
  var pair: [Int32] = [-1, -1]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  defer {
    close(pair[0])
    close(pair[1])
  }
  let flags = fcntl(pair[0], F_GETFL)
  try #require(fcntl(pair[0], F_SETFL, flags | O_NONBLOCK) == 0)
  let block = [UInt8](repeating: 1, count: 4096)
  while block.withUnsafeBytes({ send(pair[0], $0.baseAddress, block.count, 0) }) > 0 {}
  try #require(errno == EAGAIN || errno == EWOULDBLOCK)
  try #require(fcntl(pair[0], F_SETFL, flags) == 0)
  let start = ContinuousClock.now
  #expect(!EgressReadiness.write([1], to: pair[0], alive: { true }))
  let elapsed = start.duration(to: .now)
  #expect(elapsed >= .milliseconds(700))
  #expect(elapsed < .seconds(3))
  #expect(fcntl(pair[0], F_GETFL) == flags)
}
