import AsyncHTTPClient
import CryptoKit
import Foundation
import IsoProxyCore
import IsoProxyTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing

@testable import IsoProxyTransport

private struct ForwardCase: Decodable, Sendable {
  let id: String
  let certificate: String?
  let trustAnchor: Bool?
  let establishmentFailure: Bool?
  let stallHandshake: Bool?
  let dnsFailure: Bool?
  let minimumElapsedMs: Int?
  let maximumElapsedMs: Int?
  let provider: String
  let scheme: String
  let path: String
  let responseDate: String
  let responseStatus: UInt
  let requestBody: String
  let responseBody: String

  private enum CodingKeys: String, CodingKey {
    case id, certificate, provider, scheme, path
    case trustAnchor = "trust_anchor"
    case establishmentFailure = "establishment_failure"
    case stallHandshake = "stall_handshake"
    case dnsFailure = "dns_failure"
    case minimumElapsedMs = "minimum_elapsed_ms"
    case maximumElapsedMs = "maximum_elapsed_ms"
    case responseDate = "response_date"
    case responseStatus = "response_status"
    case requestBody = "request_body"
    case responseBody = "response_body"
  }
}

private struct ObservedRequest: Sendable {
  let head: HTTPRequestHead
  let body: [UInt8]
}

private let repository: URL = {
  var path = URL(fileURLWithPath: #filePath)
  for _ in 0..<4 { path.deleteLastPathComponent() }
  return path
}()

@Test func sharedForwardingCorpusThroughTLS() async throws {
  let corpus = try Data(
    contentsOf: repository.appendingPathComponent("tests/fixtures/credential-proxy/forwarding.json")
  )
  _ = try ObservationContracts.forwardingCases(corpus)
  let cases = try JSONDecoder().decode([ForwardCase].self, from: corpus)
  let evidence = try Evidence("forwarding")
  try corpus.write(to: evidence.file("corpus.json"), options: .atomic)
  let hash = SHA256.hash(data: corpus).map { String(format: "%02x", $0) }.joined()
  try Data((hash + "\n").utf8).write(to: evidence.file("corpus.sha256"))
  let fixtures = try generateForwardingFixtures()
  defer { try? FileManager.default.removeItem(at: fixtures) }
  var observations: [[String: Any]] = []
  for item in cases {
    observations.append(try await runForwardCase(item, fixtures: fixtures))
    try JSONSerialization.data(
      withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: evidence.file("observations.json"), options: .atomic)
  }
  try ObservationContracts.forwarding(
    decodeRecords(
      JSONSerialization.jsonObject(with: Data(contentsOf: evidence.file("observations.json")))),
    corpus: corpus)
  if let path = ProcessInfo.processInfo.environment["ISO_FORWARD_OBSERVATIONS"] {
    try JSONSerialization.data(
      withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]
    )
    .write(to: URL(fileURLWithPath: path), options: .atomic)
  }
}

private func runForwardCase(_ item: ForwardCase, fixtures: URL) async throws -> [String: Any] {
  let ca = try NIOSSLCertificate.fromDERFile(fixtures.appendingPathComponent("forward_ca.der").path)
  let leaf = try NIOSSLCertificate.fromDERFile(
    fixtures.appendingPathComponent((item.certificate ?? "forward_leaf") + ".der").path)
  let key = try NIOSSLPrivateKey(
    file: fixtures.appendingPathComponent("forward_leaf.pkcs8.der").path, format: .der)
  let tls = try NIOSSLContext(
    configuration: .makeServerConfiguration(
      certificateChain: [.certificate(leaf), .certificate(ca)], privateKey: .privateKey(key)))
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  var clientConfig = UpstreamClient.configuration()
  // Per-test trust anchor and DNS mapping; production configuration is unchanged.
  if item.trustAnchor ?? true {
    clientConfig.tlsConfiguration?.additionalTrustRoots = [.certificates([ca])]
  }
  let destination = item.dnsFailure == true ? "iso-proxy-test.invalid" : "127.0.0.1"
  clientConfig.dnsOverride = ["api.anthropic.com": destination, "api.openai.com": destination]
  let transportTLS = try #require(clientConfig.tlsConfiguration)
  let observed = NIOLockedValueBox<[ObservedRequest]>([])
  let stalledPeerClosed = NIOLockedValueBox(false)
  var servers: [Channel] = []
  do {
    let upstream = try await ServerBootstrap(group: group).childChannelInitializer { channel in
      if item.stallHandshake == true {
        return channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(StalledHandshake(stalledPeerClosed))
        }
      }
      return channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
      }.flatMap { channel.pipeline.configureHTTPServerPipeline() }.flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            CorpusProvider(item: item, observed: observed))
        }
      }
    }.bind(host: "127.0.0.1", port: 0).get()
    servers.append(upstream)
    let upstreamPort = try #require(upstream.localAddress?.port)
    let token = String(repeating: "a", count: 64)
    let config = try ProxyConfig(
      json: JSONSerialization.data(withJSONObject: [
        "version": 1, "listen": "127.0.0.1:0", "provider": item.provider,
        "capability_token": token,
        "injection": ["scheme": item.scheme, "credential": "test-credential"],
      ]))
    let proxy = try await Server.bind(config: config, group: group) { channel in
      channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(
            StreamingBridge(config: config) { request, relay, loop in
              let prefix = "https://api.\(item.provider).com"
              let target = String(request.url.absoluteString.dropFirst(prefix.count))
              let local = try! HTTPClient.Request(
                url: "\(prefix):\(upstreamPort)\(target)", method: request.method,
                headers: request.headers, body: request.body)
              let task = OwnedHTTPRequest(
                request: local, relay: relay, eventLoop: loop,
                tlsConfiguration: transportTLS, connectHost: destination)
              task.futureResult.whenFailure { error in
                if item.dnsFailure == true {
                  if let connection = error as? NIOConnectionError {
                    #expect(connection.connectionErrors.isEmpty)
                    for failure in [connection.dnsAError, connection.dnsAAAAError] {
                      if let dns = failure as? SocketAddressError.UnknownHost {
                        #expect(dns.host == "iso-proxy-test.invalid")
                      } else {
                        Issue.record("expected resolver failure: \(String(describing: failure))")
                      }
                    }
                  } else {
                    Issue.record("expected DNS resolution failure: \(error)")
                  }
                }
                if item.establishmentFailure != true {
                  Issue.record("fixture upstream failed: \(error)")
                }
              }
              return task
            })
        }
      }
    }.get()
    servers.append(proxy)
    let proxyPort = try #require(proxy.localAddress?.port)
    let started = ContinuousClock.now
    let response = try await rawGuestExchange(
      group: group, port: proxyPort, item: item, token: token)
    let elapsed = started.duration(to: .now)
    var observation: [String: Any]
    if item.establishmentFailure == true {
      #expect(response.status.code == 502, "\(item.id)")
      let count = observed.withLockedValue { $0.count }
      #expect(count == 0, "TLS failure must prevent HTTP credential delivery")
      let diagnostic = response.body.map { String(buffer: $0) } ?? ""
      #expect(!diagnostic.contains(token))
      #expect(!diagnostic.contains("test-credential"))
      observation = [
        "id": item.id, "upstream_count": count,
        "response_status": response.status.code, "connection_closed": true,
      ]
    } else {
      #expect(response.status.code == item.responseStatus, "\(item.id)")
      #expect(response.headers.first(name: "location") == "https://unreached.invalid/redirect")
      #expect(!response.headers.contains(name: "x-private"))
      #expect(response.headers.first(name: "content-encoding") == "gzip")
      #expect(response.headers["set-cookie"] == ["a=1", "b=2"])
      #expect(response.body.map { Array($0.readableBytesView) } == Array(item.responseBody.utf8))
      let requests = observed.withLockedValue { $0 }
      #expect(requests.count == 1)
      let upstreamRequest = try #require(requests.first)
      #expect(upstreamRequest.head.method == .POST)
      #expect(upstreamRequest.head.uri == item.path, "\(item.id)")
      #expect(upstreamRequest.head.headers.first(name: "host") == "api.\(item.provider).com")
      let name = item.scheme == "bearer" ? "authorization" : "x-api-key"
      let value = item.scheme == "bearer" ? "Bearer test-credential" : "test-credential"
      #expect(upstreamRequest.head.headers.first(name: name) == value)
      #expect(!upstreamRequest.head.headers.contains(name: "x-guest"))
      #expect(!upstreamRequest.head.headers.contains { $0.value.contains(token) })
      #expect(upstreamRequest.body == Array(item.requestBody.utf8))
      observation = [
        "id": item.id, "upstream_count": requests.count, "connection_closed": true,
        "method": upstreamRequest.head.method.rawValue, "path": upstreamRequest.head.uri,
        "request_headers": upstreamRequest.head.headers.map { [$0.name, $0.value] },
        "request_body": upstreamRequest.body, "response_status": response.status.code,
        "response_headers": response.headers.map { [$0.name, $0.value] },
        "response_body": response.body.map { Array($0.readableBytesView) } ?? [],
      ]
    }
    if item.stallHandshake == true {
      let elapsedMilliseconds =
        elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
      try #require(elapsedMilliseconds >= Int64(item.minimumElapsedMs!), "deadline fired early")
      try #require(elapsedMilliseconds <= Int64(item.maximumElapsedMs!), "deadline fired late")
      let deadline = ContinuousClock.now + .seconds(2)
      while !stalledPeerClosed.withLockedValue({ $0 }) && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(
        stalledPeerClosed.withLockedValue { $0 }, "upstream socket must be released at timeout")
      observation["elapsed_ms"] = elapsedMilliseconds
      observation["upstream_closed"] = true
    }
    for server in servers.reversed() { try await server.close().get() }
    try await group.shutdownGracefully()
    return observation
  } catch {
    for server in servers.reversed() { try? await server.close().get() }
    try await group.shutdownGracefully()
    throw error
  }
}

private final class CorpusProvider: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  let item: ForwardCase
  let observed: NIOLockedValueBox<[ObservedRequest]>
  var head: HTTPRequestHead?
  var body: [UInt8] = []
  init(item: ForwardCase, observed: NIOLockedValueBox<[ObservedRequest]>) {
    self.item = item
    self.observed = observed
  }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head): self.head = head
    case .body(let bytes): body.append(contentsOf: bytes.readableBytesView)
    case .end:
      if let head { observed.withLockedValue { $0.append(.init(head: head, body: body)) } }
      let headers = HTTPHeaders([
        ("date", item.responseDate),
        ("location", "https://unreached.invalid/redirect"), ("connection", "x-private, close"),
        ("x-private", "must-strip"), ("content-encoding", "gzip"),
        ("set-cookie", "a=1"), ("set-cookie", "b=2"),
        ("content-length", String(item.responseBody.utf8.count)),
      ])
      context.write(
        wrapOutboundOut(
          .head(
            .init(
              version: .http1_1,
              status: .init(statusCode: Int(item.responseStatus)), headers: headers))),
        promise: nil)
      context.write(
        wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: item.responseBody)))), promise: nil)
      context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
  }
}

private struct RawReply: Sendable {
  var head: HTTPResponseHead?
  var body = ByteBuffer()
  var ends = 0
  var closed = false
  var failed = false
}

private struct GuestResponse {
  let status: HTTPResponseStatus
  let headers: HTTPHeaders
  let body: ByteBuffer?
}

private final class RawGuestCapture: ChannelInboundHandler {
  typealias InboundIn = HTTPClientResponsePart
  let observed: NIOLockedValueBox<RawReply>
  init(_ observed: NIOLockedValueBox<RawReply>) { self.observed = observed }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    switch unwrapInboundIn(data) {
    case .head(let head):
      observed.withLockedValue {
        if $0.head != nil { $0.failed = true }
        $0.head = head
      }
    case .body(let bytes): observed.withLockedValue { _ = $0.body.writeImmutableBuffer(bytes) }
    case .end: observed.withLockedValue { $0.ends += 1 }
    }
  }
  func channelInactive(context: ChannelHandlerContext) {
    observed.withLockedValue { $0.closed = true }
    context.fireChannelInactive()
  }
  func errorCaught(context: ChannelHandlerContext, error: Error) {
    observed.withLockedValue { $0.failed = true }
    context.close(promise: nil)
  }
}

/// No handler closes the client on the response's Connection header or .end.
/// The peer must close its socket while our write side is still open.
private func rawGuestExchange(
  group: MultiThreadedEventLoopGroup, port: Int,
  item: ForwardCase, token: String
) async throws -> GuestResponse {
  let observed = NIOLockedValueBox(RawReply())
  let channel = try await ClientBootstrap(group: group).channelInitializer { channel in
    channel.pipeline.addHTTPClientHandlers().flatMap {
      channel.eventLoop.makeCompletedFuture {
        try channel.pipeline.syncOperations.addHandler(RawGuestCapture(observed))
      }
    }
  }.connect(host: "127.0.0.1", port: port).get()
  do {
    let head = HTTPRequestHead(
      version: .http1_1, method: .POST, uri: item.path,
      headers: HTTPHeaders([
        ("host", "guest-controlled.invalid"), ("authorization", "Bearer " + token),
        ("x-api-key", token), ("connection", "x-guest, authorization, host"),
        ("x-guest", "must-strip"), ("content-length", String(item.requestBody.utf8.count)),
      ]))
    channel.write(HTTPClientRequestPart.head(head), promise: nil)
    channel.write(
      HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(string: item.requestBody))), promise: nil)
    try await channel.writeAndFlush(HTTPClientRequestPart.end(nil)).get()
    let deadline = ContinuousClock.now + .milliseconds(item.maximumElapsedMs ?? 5000)
    while !observed.withLockedValue({ $0.closed }) && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let reply = observed.withLockedValue { $0 }
    try #require(reply.closed, "peer must close without client half-close")
    try #require(!reply.failed, "socket/HTTP decoding must finish cleanly")
    try #require(reply.ends == 1, "exactly one complete response before close")
    let responseHead = try #require(reply.head)
    return GuestResponse(
      status: responseHead.status, headers: responseHead.headers, body: reply.body)
  } catch {
    try? await channel.close().get()
    throw error
  }
}

private final class StalledHandshake: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let closed: NIOLockedValueBox<Bool>
  init(_ closed: NIOLockedValueBox<Bool>) { self.closed = closed }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {}
  func channelInactive(context: ChannelHandlerContext) {
    closed.withLockedValue { $0 = true }
    context.fireChannelInactive()
  }
}

func generateForwardingFixtures() throws -> URL {
  let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(
    at: fixtures, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  let generator = Process()
  generator.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
  generator.arguments = [
    repository.appendingPathComponent(
      "tests/fixtures/credential-proxy/generate-forwarding-certificates.py"
    ).path, fixtures.path,
  ]
  try generator.run()
  generator.waitUntilExit()
  try #require(generator.terminationStatus == 0)
  return fixtures
}
