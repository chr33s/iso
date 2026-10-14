import CryptoKit
import Foundation
import IsoPolicy
import IsoProxyCore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import IsoProxyTransport

private let capability = String(repeating: "c", count: 64)
private let seed = String(repeating: "b", count: 64)
private let instanceID = String(repeating: "1", count: 32)
private let policyBoot = String(repeating: "2", count: 32)
private let epoch = "00000000-0000-4000-8000-000000000001"
private let generation = "00000000-0000-4000-8000-000000000002"
private let nonce = String(repeating: "d", count: 32)

/// A test-only integer clock; production configuration cannot select it.
private final class FakeClock: MonotonicClock {
  let value = Mutex<UInt64?>(1)
  func nanoseconds() -> UInt64? { value.withLock { $0 } }
  func set(_ next: UInt64?) { value.withLock { $0 = next } }
}

private func policy(mode: String = "enforce", capacity: Int = 2) throws -> CompiledPolicy {
  let json = """
    {"version":1,"mode":"\(mode)","actions":["credential.use","proxy.request"],
     "rules":[{"id":"use","effect":"permit","action":"credential.use","resources":["provider:anthropic"]},
              {"id":"request","effect":"permit","action":"proxy.request","resources":["provider:anthropic"]}],
     "guards":[{"id":"limit","action":"proxy.request","resources":["provider:anthropic"],
                "require":{"rate_limit":{"max_requests":\(capacity),"within_seconds":60}}}]}
    """
  let tree = try PolicyJSON(foundation: JSONSerialization.jsonObject(with: Data(json.utf8)))
  return try PolicyCompiler.compile(PolicyDocument.parse(tree))
}

private func settings(
  provider: String = "anthropic", policy compiled: CompiledPolicy, digest: String? = nil,
  version: Int = 3
) -> [String: Any] {
  [
    "version": version, "listen": "127.0.0.1:0", "provider": provider,
    "capability_token": capability,
    "injection": [
      "scheme": provider == "openai" ? "bearer" : "x_api_key", "credential": "synthetic-provider",
    ],
    "readiness": ["privateKeyHex": seed],
    "authorization": [
      "schemaVersion": 1, "canonicalizationVersion": 1, "instanceID": instanceID,
      "instanceName": "vm", "bootID": policyBoot, "policyEpoch": epoch,
      "proxyGenerationID": generation, "policyDigest": digest ?? compiled.digest,
      "policy": compiled.canonicalJSON,
    ],
  ]
}

private func config(_ value: [String: Any]) throws -> ProxyConfig {
  try ProxyConfig(json: JSONSerialization.data(withJSONObject: value))
}

private func channel(
  _ config: ProxyConfig, authorizer: ProviderAuthorizer?, requests: Capacity = Capacity(256)
) throws -> EmbeddedChannel {
  let channel = EmbeddedChannel()
  try InboundPipeline.configure(
    channel: channel, config: config, connections: Capacity(256), requests: requests,
    authorizer: authorizer)
  try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
  return channel
}

private func output(_ channel: EmbeddedChannel) throws -> String {
  var text = ""
  while let part = try channel.readOutbound(as: ByteBuffer.self) { text += String(buffer: part) }
  return text
}

private func request(_ extra: String = "Content-Length: 0\r\n") -> String {
  "POST /v1/messages HTTP/1.1\r\nHost: guest\r\nAuthorization: Bearer \(capability)\r\n\(extra)\r\n"
}

/// Sends one request on a fresh connection; returns the local response
/// (empty when forwarded) and whether the head reached the upstream side.
private func exchange(
  _ config: ProxyConfig, _ authorizer: ProviderAuthorizer?, wire: String = request(),
  requests: Capacity = Capacity(256)
) throws -> (response: String, forwarded: Bool) {
  let channel = try channel(config, authorizer: authorizer, requests: requests)
  defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
  _ = try channel.writeInbound(ByteBuffer(string: wire))
  let response = try output(channel)
  var forwarded = false
  if case .head = try channel.readInbound(as: HTTPServerRequestPart.self) { forwarded = true }
  return (response, forwarded)
}

@Test func version3StartupValidatesThePolicyIndependently() throws {
  let compiled = try policy()
  let parsed = try config(settings(policy: compiled))
  #expect(parsed.authorization?.policy == compiled)
  #expect(parsed.authorization?.resource == .anthropic)
  #expect(!String(reflecting: parsed).contains("synthetic-provider"))

  var bad: [[String: Any]] = []
  bad.append(settings(policy: compiled, digest: "sha256:" + String(repeating: "0", count: 64)))
  var missing = settings(policy: compiled)
  missing["authorization"] = nil
  bad.append(missing)
  bad.append(settings(policy: try policy(mode: "off")))
  var noncanonical = settings(policy: compiled)
  var block = noncanonical["authorization"] as! [String: Any]
  block["policy"] = compiled.canonicalJSON.replacingOccurrences(
    of: "{\"actions\"", with: "{ \"actions\"")
  noncanonical["authorization"] = block
  bad.append(noncanonical)
  var unknown = settings(policy: compiled)
  block = unknown["authorization"] as! [String: Any]
  block["credential"] = "x"
  unknown["authorization"] = block
  bad.append(unknown)
  var guestName = settings(policy: compiled)
  block = guestName["authorization"] as! [String: Any]
  block["instanceName"] = "../vm"
  guestName["authorization"] = block
  bad.append(guestName)
  // Older versions never carry policy; v3 never drops readiness.
  bad.append(settings(policy: compiled, version: 2))
  bad.append(settings(policy: compiled, version: 1))
  var unready = settings(policy: compiled)
  unready["readiness"] = nil
  bad.append(unready)
  for value in bad {
    #expect(throws: (any Error).self) { try config(value) }
  }
}

@Test func startupBoundsAreVersionSpecific() throws {
  let compiled = try policy()
  // JSON whitespace pads a valid document past the 64 KiB v1/v2 bound.
  let padding = Data(repeating: 0x20, count: Limits.startupBytes)
  var legacy = settings(policy: compiled)
  legacy["version"] = 2
  legacy["authorization"] = nil
  legacy["readiness"] = [
    "privateKeyHex": seed, "bootID": policyBoot,
    "policyHash": "sha256:" + String(repeating: "e", count: 64),
  ]
  let legacyData = try JSONSerialization.data(withJSONObject: legacy)
  #expect(throws: Never.self) { try ProxyConfig(json: legacyData) }
  #expect(throws: (any Error).self) { try ProxyConfig(json: legacyData + padding) }
  let v3 = try JSONSerialization.data(withJSONObject: settings(policy: compiled))
  #expect(throws: Never.self) { try ProxyConfig(json: v3 + padding) }
  #expect(throws: (any Error).self) {
    try ProxyConfig(json: v3 + Data(repeating: 0x20, count: Limits.startupBytesV3))
  }
}

@Test func deniedProviderGets403AndNothingForwards() throws {
  let compiled = try policy()
  let openai = try config(settings(provider: "openai", policy: compiled))
  let clock = FakeClock()
  let authorizer = ProviderAuthorizer(config: openai, clock: clock, log: { _ in })
  let result = try exchange(openai, authorizer)
  #expect(result.response.hasPrefix("HTTP/1.1 403"))
  #expect(!result.forwarded)
}

@Test func quotaAdmitsExactlyCapacityThen429WithRetryAfter() throws {
  let parsed = try config(settings(policy: try policy(capacity: 2)))
  let clock = FakeClock()
  let lines = Mutex<[String]>([])
  let authorizer = ProviderAuthorizer(
    config: parsed, clock: clock, log: { line in lines.withLock { $0.append(line) } })
  let requests = Capacity(256)
  for _ in 0..<2 {
    let result = try exchange(parsed, authorizer, requests: requests)
    #expect(result.forwarded)
    #expect(result.response.isEmpty)
  }
  let denied = try exchange(parsed, authorizer, requests: requests)
  #expect(denied.response.hasPrefix("HTTP/1.1 429"))
  #expect(denied.response.lowercased().contains("retry-after: 60\r\n"))
  #expect(!denied.forwarded)
  // The denial released its ordinary capacity lease.
  #expect(requests.acquire() != nil)
  // Bounded diagnostics name the guard, never the request.
  let logged = lines.withLock { $0 }
  #expect(logged.count == 1)
  #expect(logged[0].contains("reason=quota_exceeded"))
  #expect(logged[0].contains("failed_guards=limit"))
  #expect(!logged[0].contains(capability))
}

@Test func hardDenialsChargeNoAdmission() throws {
  let parsed = try config(settings(policy: try policy(capacity: 1)))
  let authorizer = ProviderAuthorizer(config: parsed, clock: FakeClock(), log: { _ in })
  // Bad capability, wrong operation and bad framing fail before policy.
  for wire in [
    "POST /v1/messages HTTP/1.1\r\nHost: guest\r\nContent-Length: 0\r\n\r\n",
    "GET /v1/messages HTTP/1.1\r\nHost: guest\r\nAuthorization: Bearer \(capability)\r\n\r\n",
    request("Content-Length: 0\r\nContent-Length: 1\r\n"),
  ] {
    #expect(try !exchange(parsed, authorizer, wire: wire).forwarded)
  }
  #expect(try exchange(parsed, authorizer).forwarded)
}

@Test func expectContinueIsSentOnlyAfterAuthorization() throws {
  let parsed = try config(settings(policy: try policy(capacity: 1)))
  let authorizer = ProviderAuthorizer(config: parsed, clock: FakeClock(), log: { _ in })
  let continued = request("Content-Length: 5\r\nExpect: 100-continue\r\n")
  let first = try exchange(parsed, authorizer, wire: continued)
  #expect(first.response.hasPrefix("HTTP/1.1 100"))
  #expect(first.forwarded)
  // The admission stays charged though the body never arrived.
  let second = try exchange(parsed, authorizer, wire: continued)
  #expect(second.response.hasPrefix("HTTP/1.1 429"))
  #expect(!second.response.contains("100 Continue"))
  #expect(!second.forwarded)
}

@Test func unusableClockFailsClosedWith503() throws {
  let parsed = try config(settings(policy: try policy()))
  let clock = FakeClock()
  clock.set(nil)
  let authorizer = ProviderAuthorizer(config: parsed, clock: clock, log: { _ in })
  let result = try exchange(parsed, authorizer)
  #expect(result.response.hasPrefix("HTTP/1.1 503"))
  #expect(!result.forwarded)
}

@Test func version3WithoutAnAuthorizerNeverForwards() throws {
  let parsed = try config(settings(policy: try policy()))
  let result = try exchange(parsed, nil)
  #expect(result.response.hasPrefix("HTTP/1.1 503"))
  #expect(!result.forwarded)
}

@Test func shadowModeReportsButNeverChangesTheOutcome() throws {
  let parsed = try config(settings(policy: try policy(mode: "shadow", capacity: 1)))
  let lines = Mutex<[String]>([])
  let authorizer = ProviderAuthorizer(
    config: parsed, clock: FakeClock(), log: { line in lines.withLock { $0.append(line) } })
  for _ in 0..<3 { #expect(try exchange(parsed, authorizer).forwarded) }
  let logged = lines.withLock { $0 }
  #expect(logged.count == 2)
  #expect(logged.allSatisfy { $0.contains("shadow (hypothetical)") })
}

@Test func readinessProbeIsLocalAndUncharged() throws {
  let parsed = try config(settings(policy: try policy(capacity: 1)))
  let authorizer = ProviderAuthorizer(config: parsed, clock: FakeClock(), log: { _ in })
  let probe =
    "GET /__iso/broker-ready HTTP/1.1\r\nHost: localhost\r\nX-Iso-Nonce: \(nonce)\r\nConnection: close\r\n\r\n"
  for _ in 0..<3 {
    let result = try exchange(parsed, authorizer, wire: probe)
    #expect(result.response.hasPrefix("HTTP/1.1 200 OK"))
    #expect(!result.forwarded)
  }
  #expect(try exchange(parsed, authorizer).forwarded)
}

@Test func version3ReadinessSignsTheAuthorizationBinding() throws {
  let compiled = try policy()
  let parsed = try config(settings(policy: compiled))
  let body = try #require(try parsed.readiness?.response(nonce: nonce))
  #expect(body.count <= BrokerReadiness.maxReplyBytes)
  let reply = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
  #expect(reply["version"] as? Int == 3)
  #expect(reply["policyEpoch"] as? String == epoch)
  #expect(reply["policyDigest"] as? String == compiled.digest)
  #expect(reply["proxyGenerationID"] as? String == generation)
  #expect(reply["bootID"] as? String == "")
  let message =
    "iso-broker-readiness-v3\n\(nonce)\nanthropic\n\n\n\(instanceID)\n\(policyBoot)\n\(epoch)\n\(compiled.digest)\n\(generation)\n"
  let key = try Curve25519.Signing.PrivateKey(
    rawRepresentation: Data(repeating: 0xbb, count: 32)
  ).publicKey
  let encoded = try #require(reply["signature"] as? String)
  let signature = try #require(Data(base64Encoded: encoded))
  #expect(key.isValidSignature(signature, for: Data(message.utf8)))
}

@Test func concurrentConnectionsShareOneLimiter() async throws {
  let parsed = try config(settings(policy: try policy(capacity: 100)))
  let made = ProviderAuthorizer(config: parsed, clock: FakeClock(), log: { _ in })
  let authorizer = try #require(made)
  let forwarded = await withTaskGroup(of: Bool.self) { group in
    for _ in 0..<1_000 {
      group.addTask { authorizer.authorize() == .forward }
    }
    var count = 0
    for await result in group where result { count += 1 }
    return count
  }
  #expect(forwarded == 100)
}
