import CryptoKit
import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private let boot = String(repeating: "a", count: 32)
private let hash = "sha256:" + String(repeating: "e", count: 64)
private let nonce = String(repeating: "d", count: 32)
private let publicKey = "7d59c5623dd40a74aa4d5a32ac645d3b3f95daeae4c22be25476dd6a486f7382"
private let signature =
  "q583ysibRgivzGgKtXcAOUw7FJsUJ4iF46i9lfMYCwKK59VqoQ/Yd3S1/c8vdNifynlN4HdWL3kDFZzFdCK4Bg=="

private func reply(change: String = "") throws -> [UInt8] {
  let changedNonce = change == "nonce" ? String(repeating: "f", count: 32) : nonce
  let changedBoot = change == "boot" ? String(repeating: "f", count: 32) : boot
  let changedHash = change == "policy" ? "sha256:" + String(repeating: "f", count: 64) : hash
  let provider = change == "provider" ? "openai" : "anthropic"
  let message =
    "iso-broker-readiness-v1\n\(changedNonce)\n\(provider)\n\(changedBoot)\n\(changedHash)\n"
  let signer = try Curve25519.Signing.PrivateKey(
    rawRepresentation: Data(repeating: 0xbb, count: 32))
  let signed =
    change.isEmpty ? signature : try signer.signature(for: Data(message.utf8)).base64EncodedString()
  let body = try JSONSerialization.data(withJSONObject: [
    "version": change == "version" ? 2 : 1, "nonce": changedNonce, "provider": provider,
    "bootID": changedBoot, "policyHash": changedHash,
    "signature": change == "signature"
      ? Data(repeating: 0, count: 64).base64EncodedString() : signed,
  ])
  var result =
    Array(
      ("HTTP/1.1 200 OK\r\ncontent-length: \(body.count + (change == "length" ? 1 : 0))\r\nconnection: close\r\n\r\n")
        .utf8) + body
  if change == "truncated" { result.removeLast() }
  if change == "oversize" { result += [UInt8](repeating: 32, count: 1025) }
  return result
}

@Test func brokerReadinessAcceptsIndependentVector() throws {
  #expect(
    BrokerReadiness.verifies(
      try reply(), nonce: nonce, provider: .anthropic,
      policy: .init(bootID: boot, policyHash: hash), key: try .init(encoded: publicKey)))
}

@Test(arguments: [
  "signature", "nonce", "provider", "boot", "policy", "version", "length", "truncated", "oversize",
])
func brokerReadinessRejectsSignedWrongFieldsAndForgery(change: String) throws {
  #expect(
    !BrokerReadiness.verifies(
      try reply(change: change), nonce: nonce, provider: .anthropic,
      policy: .init(bootID: boot, policyHash: hash), key: try .init(encoded: publicKey)))
}

@Test func brokerRequirementsUseEffectiveRemoteUpstreamsWithoutResolvingSecrets() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let config = try testConfig(
    #""proxy": {"mode": "auto", "anthropic": {"credential": "cmd:exit 91"}}"#)
  #expect(try BrokerReadiness.requiredProviders(instance, config: config) == [.anthropic])
  try ProxyState.setOverride(
    instance, provider: .openai,
    credential: CredentialReference("cmd:exit 92")!, auth: .bearer)
  #expect(try BrokerReadiness.requiredProviders(instance, config: config) == [.anthropic, .openai])
  #expect(
    try BrokerReadiness.requiredProviders(
      instance, config: testConfig(#""proxy": {"mode": "off"}"#)
    ).isEmpty)
  let routed = try testInstance(guest.root + "/routed")
  try GuestEnvState(entries: [try EnvVarName("OPENAI_API_KEY"): .secret(try SecretName("broker"))])
    .save(routed)
  #expect(
    try BrokerReadiness.requiredProviders(routed, config: testConfig("")).map(\.rawValue) == [
      "openai"
    ])
  #expect(throws: (any Error).self) {
    try BrokerReadiness.requiredProviders(routed, config: testConfig(#""proxy": {"mode": "off"}"#))
  }
  var model = ModelState()
  model.mode = .local
  try model.save(instance)
  #expect(try BrokerReadiness.requiredProviders(instance, config: config).isEmpty)
  model.mode = .remote
  try model.save(instance)
  try writeFile(instance.proxyStatePath, "malformed")
  #expect(throws: (any Error).self) {
    try BrokerReadiness.requiredProviders(instance, config: config)
  }
}

@Test func brokerStartupIsVersionedAndOnlyPublicMaterialIsPersisted() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let identity = try FilteredReadiness.SigningIdentity(seed: Data(repeating: 0xbb, count: 32))
  let value = ProxyLauncher.wireConfig(
    listen: "127.0.0.1:8788", capabilityToken: Secret(String(repeating: "c", count: 64)),
    provider: .anthropic, auth: .apiKey, credential: Secret("synthetic-provider"),
    readiness: .init(identity: identity, policy: .init(bootID: boot, policyHash: hash)))
  let json = try OrderedJSON.parse(String(decoding: value.expose(), as: UTF8.self))
  #expect(json["version"] == .uint(2))
  #expect(json["readiness"]?["privateKeyHex"] == .string(identity.startupKey.expose()))
  #expect(json["readiness"]?["bootID"] == .string(boot))
  #expect("\(value)" == "<redacted>")
  let path = BrokerReadiness.keyPath(instance, provider: .anthropic)
  try BrokerReadiness.Startup(identity: identity, policy: .init(bootID: boot, policyHash: hash))
    .persistVerificationKey(instance, provider: .anthropic)
  #expect(
    try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
  #expect(try FilteredReadiness.readVerificationKey(at: path).encoded == publicKey)
  #expect(readFile(path)?.contains(identity.startupKey.expose()) == false)
  guest.proxies().stop(instance, provider: .anthropic)
  #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func brokerRequiredProofRefusesAMissingBroker() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  try BrokerReadiness.requireAll(
    instance, config: testConfig(""), target: guest.target, environment: [:],
    policy: .init(bootID: boot, policyHash: hash))
  let configured = try testConfig(#""proxy": {"anthropic": {"credential": "cmd:exit 93"}}"#)
  let error = try #require(throws: HostError.self) {
    try BrokerReadiness.requireAll(
      instance, config: configured, target: guest.target, environment: [:],
      policy: .init(bootID: boot, policyHash: hash))
  }
  #expect(error.message.contains("anthropic process or tunnel is not running"))
}

@Test func brokerFailureAfterStartupCleansSigningStateProcessAndTunnel() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let iso = try guest.installProxyStubs()
  let instance = try testInstance(guest.root + "/instance", index: 11)
  let launcher = guest.proxies(iso: iso)
  defer { launcher.stopAll(instance) }
  let error = try #require(throws: (any Error).self) {
    try launcher.start(
      instance, provider: .openai,
      upstream: .init(credential: CredentialReference("cmd:printf synthetic")!, auth: .bearer),
      target: guest.target, readinessPolicy: .init(bootID: boot, policyHash: hash))
  }
  #expect(oneLineError(error).contains("authenticated openai companion probe failed"))
  for path in [
    BrokerReadiness.keyPath(instance, provider: .openai),
    ProxyLauncher.pidPath(instance, "openai"), ProxyLauncher.forwardPIDPath(instance, "openai"),
    ProxyLauncher.tokenPath(instance, "openai"),
  ] {
    #expect(!FileManager.default.fileExists(atPath: path))
  }
}
