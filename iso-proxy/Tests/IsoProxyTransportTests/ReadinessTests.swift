import CryptoKit
import Foundation
import IsoProxyCore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing

@testable import IsoProxyTransport

private let nonce = String(repeating: "d", count: 32)
private let boot = String(repeating: "a", count: 32)
private let hash = "sha256:" + String(repeating: "e", count: 64)
private let seed = String(repeating: "b", count: 64)
private let capability = String(repeating: "c", count: 64)

private func settings(version: Int = 2) -> [String: Any] {
  var value: [String: Any] = [
    "version": version, "listen": "127.0.0.1:0", "provider": "anthropic",
    "capability_token": capability,
    "injection": ["scheme": "x_api_key", "credential": "synthetic-provider"],
  ]
  if version == 2 {
    value["readiness"] = ["privateKeyHex": seed, "bootID": boot, "policyHash": hash]
  }
  return value
}

private func channel(_ value: [String: Any] = settings()) throws -> EmbeddedChannel {
  let channel = EmbeddedChannel()
  let config = try ProxyConfig(json: JSONSerialization.data(withJSONObject: value))
  try InboundPipeline.configure(
    channel: channel, config: config, connections: Capacity(256), requests: Capacity(256))
  try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
  return channel
}

private func output(_ channel: EmbeddedChannel) throws -> String {
  var text = ""
  while let part = try channel.readOutbound(as: ByteBuffer.self) { text += String(buffer: part) }
  return text
}

private let wire =
  "GET /__iso/broker-ready HTTP/1.1\r\nHost: localhost\r\nX-Iso-Nonce: \(nonce)\r\nConnection: close\r\n\r\n"

@Test(arguments: ["anthropic", "openai"])
func brokerLocalReadinessSignsWithoutForwardingOrCredentials(provider: String) throws {
  var value = settings()
  value["provider"] = provider
  value["injection"] = [
    "scheme": provider == "openai" ? "bearer" : "x_api_key", "credential": "synthetic-provider",
  ]
  let channel = try channel(value)
  defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
  _ = try channel.writeInbound(ByteBuffer(string: wire))
  let response = try output(channel)
  #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
  #expect(!channel.isActive)
  #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
  let body = try #require(response.components(separatedBy: "\r\n\r\n").last)
  let json = try #require(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
  #expect(json["version"] as? Int == 1)
  #expect(json["nonce"] as? String == nonce)
  #expect(json["provider"] as? String == provider)
  #expect(json["bootID"] as? String == boot)
  #expect(json["policyHash"] as? String == hash)
  let signatureText = try #require(json["signature"] as? String)
  let signature = try #require(Data(base64Encoded: signatureText))
  // OpenSSL 3.6.5 independently derived this key and protocol signature.
  let publicBytes: [UInt8] = [
    0x7d, 0x59, 0xc5, 0x62, 0x3d, 0xd4, 0x0a, 0x74, 0xaa, 0x4d, 0x5a, 0x32, 0xac, 0x64, 0x5d, 0x3b,
    0x3f, 0x95, 0xda, 0xea, 0xe4, 0xc2, 0x2b, 0xe2, 0x54, 0x76, 0xdd, 0x6a, 0x48, 0x6f, 0x73, 0x82,
  ]
  let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
  let message = Data("iso-broker-readiness-v1\n\(nonce)\n\(provider)\n\(boot)\n\(hash)\n".utf8)
  #expect(key.isValidSignature(signature, for: message))
  let independent = try #require(
    Data(
      base64Encoded:
        "q583ysibRgivzGgKtXcAOUw7FJsUJ4iF46i9lfMYCwKK59VqoQ/Yd3S1/c8vdNifynlN4HdWL3kDFZzFdCK4Bg=="))
  if provider == "anthropic" { #expect(key.isValidSignature(independent, for: message)) }
  for secret in [seed, capability, "synthetic-provider"] { #expect(!response.contains(secret)) }
}

@Test func brokerReadinessRejectsBodyFramingAndRouteVariantsLocally() throws {
  for invalid in [
    wire.replacingOccurrences(of: "GET", with: "POST"),
    wire.replacingOccurrences(of: "broker-ready", with: "broker-ready?x=1"),
    wire.replacingOccurrences(of: "broker-ready", with: "broker-ready/"),
    wire.replacingOccurrences(of: nonce, with: "invalid"),
    wire.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Iso-Nonce: \(nonce)\r\n\r\n"),
    wire.replacingOccurrences(of: "\r\n\r\n", with: "\r\nContent-Length: 1\r\n\r\nx"),
    wire.replacingOccurrences(
      of: "\r\n\r\n", with: "\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"),
    wire.replacingOccurrences(of: "localhost", with: "evil"),
    wire.replacingOccurrences(
      of: "\r\n\r\n", with: "\r\nAuthorization: Bearer \(capability)\r\n\r\n"),
  ] {
    let channel = try channel()
    defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
    _ = try channel.writeInbound(ByteBuffer(string: invalid))
    #expect(!(try output(channel)).hasPrefix("HTTP/1.1 200"), "\(invalid)")
    #expect(!channel.isActive)
    #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
  }
  let legacy = try channel(settings(version: 1))
  defer { _ = try? legacy.finish(acceptAlreadyClosed: true) }
  _ = try legacy.writeInbound(ByteBuffer(string: wire))
  #expect(try output(legacy).hasPrefix("HTTP/1.1 401"))
  #expect(try legacy.readInbound(as: HTTPServerRequestPart.self) == nil)
}

@Test func brokerReadinessWaitsForEndAndBoundsIncompleteChallenges() throws {
  let channel = try channel()
  defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
  _ = try channel.writeInbound(ByteBuffer(string: String(wire.dropLast(2))))
  #expect(try output(channel).isEmpty)
  channel.embeddedEventLoop.advanceTime(by: .seconds(31))
  #expect(try output(channel).hasPrefix("HTTP/1.1 408"))
  #expect(!channel.isActive)
}

private final class PausedReadinessWrites: ChannelOutboundHandler {
  typealias OutboundIn = ByteBuffer
  private var promises: [EventLoopPromise<Void>] = []

  func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
    if let promise { promises.append(promise) }
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    let pending = promises
    promises = []
    for promise in pending { promise.fail(ChannelError.ioOnClosedChannel) }
  }
}

@Test func brokerReadinessBoundsPausedResponseWrites() throws {
  let channel = try channel()
  defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
  try channel.pipeline.syncOperations.addHandler(PausedReadinessWrites(), position: .first)
  _ = try channel.writeInbound(ByteBuffer(string: wire))
  #expect(channel.isActive)
  #expect(try output(channel).isEmpty)
  channel.embeddedEventLoop.advanceTime(by: .seconds(2))
  #expect(!channel.isActive)
}

@Test func brokerReadinessBoundsAParsedIncompleteChallenge() throws {
  let channel = try channel()
  defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
  let context = try channel.pipeline.syncOperations.context(handlerType: InboundGate.self)
  let gate = try #require(context.handler as? InboundGate)
  let headers = HTTPHeaders([
    ("Host", "localhost"), ("X-Iso-Nonce", nonce), ("Connection", "close"),
  ])
  gate.channelRead(
    context: context,
    data: NIOAny(
      HTTPServerRequestPart.head(
        .init(version: .http1_1, method: .GET, uri: BrokerReadiness.path, headers: headers))))
  channel.embeddedEventLoop.advanceTime(by: .seconds(3))
  #expect(try output(channel).hasPrefix("HTTP/1.1 408"))
  #expect(!channel.isActive)
}

@Test func brokerReadinessChallengesAreClosed() {
  let headers = [
    Header("host", "localhost"), Header("x-iso-nonce", nonce), Header("connection", "close"),
  ]
  #expect(
    BrokerReadiness.challenge(method: "GET", uri: BrokerReadiness.path, headers: headers) == nonce)
  #expect(
    BrokerReadiness.challenge(method: "POST", uri: BrokerReadiness.path, headers: headers) == nil)
  #expect(
    BrokerReadiness.challenge(method: "GET", uri: BrokerReadiness.path + "?x=1", headers: headers)
      == nil)
  #expect(
    BrokerReadiness.challenge(
      method: "GET", uri: BrokerReadiness.path,
      headers: headers + [Header("authorization", "Bearer " + capability)]) == nil)
  #expect(
    BrokerReadiness.challenge(
      method: "GET", uri: BrokerReadiness.path,
      headers: [headers[0], Header("x-iso-nonce", "invalid"), headers[2]]) == nil)
}

@Test func brokerReadinessStartupRejectsMalformedAndUnknownIdentities() throws {
  for field in ["privateKeyHex", "bootID", "policyHash", "extra"] {
    var value = settings()
    var identity = try #require(value["readiness"] as? [String: String])
    identity[field] = "bad"
    value["readiness"] = identity
    #expect(throws: PolicyError.self) {
      try ProxyConfig(json: JSONSerialization.data(withJSONObject: value))
    }
  }
  var value = settings()
  value["version"] = 1
  #expect(throws: PolicyError.self) {
    try ProxyConfig(json: JSONSerialization.data(withJSONObject: value))
  }
  value = settings(version: 1)
  value["version"] = 2
  #expect(throws: PolicyError.self) {
    try ProxyConfig(json: JSONSerialization.data(withJSONObject: value))
  }
  #expect(
    try ProxyConfig(json: JSONSerialization.data(withJSONObject: settings(version: 1))).readiness
      == nil)
}
