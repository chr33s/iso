import Foundation
import IsoProxyCore
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import Testing

@testable import IsoProxyTransport

private let token = String(repeating: "a", count: 64)
private func configuration() throws -> ProxyConfig {
  try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "listen": "127.0.0.1:0", "provider": "anthropic",
      "capability_token": token, "injection": ["scheme": "x_api_key", "credential": "test-secret"],
    ]))
}

private func channel(connections: Capacity = Capacity(256), requests: Capacity = Capacity(256))
  throws -> EmbeddedChannel
{
  let channel = EmbeddedChannel()
  try InboundPipeline.configure(
    channel: channel, config: configuration(), connections: connections, requests: requests)
  try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
  return channel
}

private func send(_ text: String, to channel: EmbeddedChannel) throws {
  _ = try channel.writeInbound(ByteBuffer(string: text))
}

private func output(_ channel: EmbeddedChannel) throws -> String {
  var result = ""
  while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
    result += String(buffer: buffer)
  }
  return result
}

private func request(
  method: String = "POST", target: String = "/v1/messages", extra: String = "Content-Length: 0\r\n"
) -> String {
  "\(method) \(target) HTTP/1.1\r\nHost: guest\r\nAuthorization: Bearer \(token)\r\n\(extra)\r\n"
}

@Test func authAndOperationsFailLocally() throws {
  for (wire, status) in [
    ("GET / HTTP/1.1\r\nHost: guest\r\n\r\n", 401),
    (request(method: "GET"), 403),
    (request(target: "/v1/responses"), 403),
    (request(target: "https://evil/v1/messages"), 400),
    (request(extra: "Content-Length: 67108865\r\n"), 413),
    (request(extra: "Content-Length: 0\r\nTrailer: x-private\r\n"), 400),
    (request(extra: "Content-Length: 0\r\nx-api-key: wrong\r\n"), 401),
  ] {
    let channel = try channel()
    try send(wire, to: channel)
    #expect(try output(channel).hasPrefix("HTTP/1.1 \(status)"))
    #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
    _ = try channel.finish(acceptAlreadyClosed: true)
  }
}

@Test func parserLimitsApplyBeforeCompleteHeaders() throws {
  for fields in [
    "X-Large: " + String(repeating: "a", count: Limits.headerFieldBytes + 1),
    String(repeating: "X-F: a\r\n", count: Limits.headerCount + 1),
    String(repeating: "X-M: " + String(repeating: "a", count: 8192) + "\r\n", count: 9),
  ] {
    let channel = try channel()
    try send("POST /v1/messages HTTP/1.1\r\n" + fields, to: channel)
    #expect(try output(channel).hasPrefix("HTTP/1.1 431"))
    #expect(!channel.isActive)
    _ = try channel.finish(acceptAlreadyClosed: true)
  }
}

@Test func framingAmbiguityIsRejected() throws {
  for extra in [
    "Content-Length: 0\r\nContent-Length: 1\r\n",
    "Content-Length: 0\r\nTransfer-Encoding: chunked\r\n",
  ] {
    let channel = try channel()
    try send(request(extra: extra), to: channel)
    #expect(try output(channel).hasPrefix("HTTP/1.1 400"))
    #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
    _ = try channel.finish(acceptAlreadyClosed: true)
  }
}

@Test func combinedHeaderFieldBoundaryIsEnforcedBeforeAuthentication() throws {
  for extra in [0, 1] {
    let channel = try channel()
    defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
    let value = String(repeating: "x", count: 16_381 + extra)
    try send("GET / HTTP/1.1\r\nX-F: \(value)\r\n\r\n", to: channel)
    #expect(try output(channel).hasPrefix("HTTP/1.1 \(extra == 0 ? 401 : 431)"))
    #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
  }
}

@Test func rawHeaderBudgetBoundsWhitespaceAndExcludesCoalescedBody() throws {
  let prefix = "GET / HTTP/1.1\r\nX: "
  let suffix = "x\r\n\r\n"
  for extra in [0, 1] {
    let channel = try channel()
    defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
    let padding = String(
      repeating: " ", count: 82_496 - prefix.utf8.count - suffix.utf8.count + extra)
    try send(prefix + padding + suffix, to: channel)
    #expect(try output(channel).hasPrefix("HTTP/1.1 \(extra == 0 ? 401 : 431)"))
  }
  let channel = try channel()
  defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
  let head = request(extra: "Content-Length: 2\r\nX: $PADDING$x\r\n")
  let padding = String(repeating: " ", count: 82_496 - head.utf8.count + "$PADDING$".utf8.count)
  try send(head.replacingOccurrences(of: "$PADDING$", with: padding) + "ab", to: channel)
  #expect(try output(channel).isEmpty)
  guard case .head = try channel.readInbound(as: HTTPServerRequestPart.self),
    case .body(let body) = try channel.readInbound(as: HTTPServerRequestPart.self),
    case .end = try channel.readInbound(as: HTTPServerRequestPart.self)
  else {
    Issue.record("wire budget consumed coalesced body bytes")
    return
  }
  #expect(String(buffer: body) == "ab")
  _ = try channel.writeOutbound(
    HTTPServerResponsePart.head(.init(version: .http1_1, status: .noContent)))
  _ = try channel.writeOutbound(HTTPServerResponsePart.end(nil))
  _ = try output(channel)
  channel.embeddedEventLoop.run()
  try send(prefix + String(repeating: " ", count: 82_496 - prefix.utf8.count), to: channel)
  #expect(try output(channel).hasPrefix("HTTP/1.1 431"))
}

@Test func heldResponseRejectsFurtherGuestInput() throws {
  let channel = try channel()
  defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
  try send(request(), to: channel)
  _ = try channel.readInbound(as: HTTPServerRequestPart.self)
  _ = try channel.readInbound(as: HTTPServerRequestPart.self)
  _ = try channel.writeOutbound(
    HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
  #expect(try output(channel).hasPrefix("HTTP/1.1 200"))
  try send("GET / HTTP/1.1\r\nX: " + String(repeating: " ", count: 16_384), to: channel)
  #expect(!channel.isActive)
  #expect(try output(channel).isEmpty)
}

@Test func continueAcknowledgesOnlyAdmittedUploads() throws {
  for framing in ["Content-Length: 2\r\n"] {
    let capacity = Capacity(1)
    let channel = try channel(requests: capacity)
    defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
    try send(request(extra: framing + "Expect: 100-Continue\r\n"), to: channel)
    #expect(try output(channel) == "HTTP/1.1 100 Continue\r\n\r\n")
    guard case .head = try channel.readInbound(as: HTTPServerRequestPart.self) else {
      Issue.record("missing admitted upload")
      continue
    }
    #expect(capacity.acquire() == nil)
    try send("ab", to: channel)
    guard case .body(let body) = try channel.readInbound(as: HTTPServerRequestPart.self) else {
      Issue.record("missing body after continue")
      continue
    }
    #expect(String(buffer: body) == "ab")
    guard case .end = try channel.readInbound(as: HTTPServerRequestPart.self) else {
      Issue.record("missing upload completion")
      continue
    }
    #expect(capacity.acquire() == nil)
    _ = try channel.writeOutbound(
      HTTPServerResponsePart.head(.init(version: .http1_1, status: .noContent)))
    _ = try channel.writeOutbound(HTTPServerResponsePart.end(nil))
    #expect(try output(channel).hasPrefix("HTTP/1.1 204"))
    channel.embeddedEventLoop.run()
    #expect(capacity.acquire() != nil)
  }
  for (wire, status) in [
    (
      "POST /v1/messages HTTP/1.1\r\nHost: guest\r\nContent-Length: 2\r\nExpect: 100-continue\r\n\r\n",
      401
    ),
    (request(method: "GET", extra: "Content-Length: 2\r\nExpect: 100-continue\r\n"), 403),
    (request(extra: "Content-Length: 67108865\r\nExpect: 100-continue\r\n"), 413),
    (request(extra: "Transfer-Encoding: chunked\r\nExpect: 100-continue\r\n"), 411),
  ] {
    let channel = try channel()
    defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
    try send(wire, to: channel)
    let response = try output(channel)
    #expect(response.hasPrefix("HTTP/1.1 \(status)"))
    #expect(!response.contains("100 Continue"))
    #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
  }
  let full = try channel(requests: Capacity(0))
  defer { _ = try? full.finish(acceptAlreadyClosed: true) }
  try send(request(extra: "Content-Length: 2\r\nExpect: 100-continue\r\n"), to: full)
  let refusal = try output(full)
  #expect(refusal.hasPrefix("HTTP/1.1 503"))
  #expect(!refusal.contains("100 Continue"))
  for framing in ["", "Content-Length: 0\r\n", "Content-Length: 000\r\n"] {
    let channel = try channel()
    defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
    try send(request(extra: framing + "Expect: 100-continue\r\n"), to: channel)
    #expect(try output(channel).isEmpty)
    guard case .head = try channel.readInbound(as: HTTPServerRequestPart.self),
      case .end = try channel.readInbound(as: HTTPServerRequestPart.self)
    else {
      Issue.record("bodyless request was not admitted")
      continue
    }
  }
}

@Test func declaredBodyStreamsBeforeCompletion() throws {
  let channel = try channel()
  defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
  try send(request(extra: "Content-Length: 4\r\n"), to: channel)
  guard case .head = try channel.readInbound(as: HTTPServerRequestPart.self) else {
    Issue.record("missing accepted head")
    return
  }
  try send("abc", to: channel)
  guard case .body(let buffer) = try channel.readInbound(as: HTTPServerRequestPart.self) else {
    Issue.record("body was not streamed before request completion")
    return
  }
  #expect(String(buffer: buffer) == "abc")
  #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
  try send("d", to: channel)
  _ = try channel.readInbound(as: HTTPServerRequestPart.self)
  guard case .end = try channel.readInbound(as: HTTPServerRequestPart.self) else {
    Issue.record("missing declared body completion")
    return
  }
}

@Test func chunkedBodiesAreRejectedBeforeForwarding() throws {
  for body in ["", "0\r\n\r\n", "3\r\nabc\r\n0\r\n\r\n"] {
    let capacity = Capacity(1)
    let channel = try channel(requests: capacity)
    defer { _ = try? channel.finish(acceptAlreadyClosed: true) }
    try send(request(extra: "Transfer-Encoding: chunked\r\n") + body, to: channel)
    #expect(try output(channel).hasPrefix("HTTP/1.1 411"))
    #expect(try channel.readInbound(as: HTTPServerRequestPart.self) == nil)
    #expect(capacity.acquire() != nil)
  }
}

@Test func deadlinesApplyToHeadersAndIdleBody() throws {
  let headers = try channel()
  try send("POST /v1/", to: headers)
  headers.embeddedEventLoop.advanceTime(by: .seconds(10))
  #expect(try output(headers).hasPrefix("HTTP/1.1 408"))
  _ = try headers.finish(acceptAlreadyClosed: true)

  let body = try channel()
  try send(request(extra: "Content-Length: 2\r\n"), to: body)
  _ = try body.readInbound(as: HTTPServerRequestPart.self)
  body.embeddedEventLoop.advanceTime(by: .seconds(29))
  try send("a", to: body)
  _ = try body.readInbound(as: HTTPServerRequestPart.self)
  body.embeddedEventLoop.advanceTime(by: .seconds(29))
  #expect(body.isActive)
  body.embeddedEventLoop.advanceTime(by: .seconds(1))
  #expect(try output(body).hasPrefix("HTTP/1.1 408"))
  _ = try body.finish(acceptAlreadyClosed: true)
}

@Test func permitsSurviveResponseHeadersAndReleaseOnDisconnect() throws {
  let capacity = Capacity(1)
  let first = try channel(requests: capacity)
  try send(request(), to: first)
  _ = try first.readInbound(as: HTTPServerRequestPart.self)
  _ = try first.readInbound(as: HTTPServerRequestPart.self)
  _ = try first.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
  _ = try output(first)
  // Long streaming responses must have no short total response deadline.
  first.embeddedEventLoop.advanceTime(by: .seconds(3600))
  #expect(first.isActive)
  let second = try channel(requests: capacity)
  try send(request(), to: second)
  #expect(try output(second).hasPrefix("HTTP/1.1 503"))
  _ = try second.finish(acceptAlreadyClosed: true)
  try first.close().wait()
  _ = try first.finish(acceptAlreadyClosed: true)
  let third = try channel(requests: capacity)
  try send(request(), to: third)
  guard case .head = try third.readInbound(as: HTTPServerRequestPart.self) else {
    Issue.record("disconnect did not release permit")
    return
  }
  _ = try third.readInbound(as: HTTPServerRequestPart.self)
  _ = try third.finish()
}

@Test func idleConnectionsConsumeCapacity() throws {
  let capacity = Capacity(1)
  let first = try channel(connections: capacity)
  let second = EmbeddedChannel()
  try InboundPipeline.configure(
    channel: second, config: configuration(), connections: capacity, requests: Capacity(1))
  #expect(!second.isActive)
  _ = try second.finish(acceptAlreadyClosed: true)
  try first.close().wait()
  _ = try first.finish(acceptAlreadyClosed: true)
  let third = try channel(connections: capacity)
  #expect(third.isActive)
  _ = try third.finish()
}

@Test func responseCompletionReleasesPermitAndAllowsNextRequest() throws {
  let capacity = Capacity(1)
  let channel = try channel(requests: capacity)
  try send(request(), to: channel)
  _ = try channel.readInbound(as: HTTPServerRequestPart.self)
  _ = try channel.readInbound(as: HTTPServerRequestPart.self)
  _ = try channel.writeOutbound(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
  #expect(capacity.acquire() == nil)
  _ = try channel.writeOutbound(HTTPServerResponsePart.end(nil))
  _ = try output(channel)
  channel.embeddedEventLoop.run()
  try send(request(), to: channel)
  guard case .head = try channel.readInbound(as: HTTPServerRequestPart.self) else {
    Issue.record("completed response did not release permit")
    return
  }
  _ = try channel.readInbound(as: HTTPServerRequestPart.self)
  _ = try channel.finish()
}

@Test func capacity256HoldsFullResponses() throws {
  let requests = Capacity(Limits.requests)
  var channels: [EmbeddedChannel] = []
  for _ in 0..<256 {
    let channel = try channel(requests: requests)
    channels.append(channel)
    try send(request(), to: channel)
    _ = try channel.readInbound(as: HTTPServerRequestPart.self)
    _ = try channel.readInbound(as: HTTPServerRequestPart.self)
    _ = try channel.writeOutbound(
      HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok)))
    _ = try output(channel)
  }
  let excess = try channel(requests: requests)
  try send(request(), to: excess)
  #expect(try output(excess).hasPrefix("HTTP/1.1 503"))
  _ = try excess.finish(acceptAlreadyClosed: true)
  for channel in channels { _ = try channel.finish() }
  #expect(requests.acquire() != nil)
}

@Test func socketListenerRejectsUnauthenticatedRequest() async throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  do {
    let server = try await Server.bind(config: configuration(), group: group) { channel in
      channel.eventLoop.makeSucceededVoidFuture()
    }.get()
    let response = group.next().makePromise(of: String.self)
    let client = try await ClientBootstrap(group: group)
      .channelInitializer { channel in
        channel.eventLoop.makeCompletedFuture {
          try channel.pipeline.syncOperations.addHandler(ResponseCapture(result: response))
        }
      }
      .connect(to: #require(server.localAddress)).get()
    try await client.writeAndFlush(
      ByteBuffer(string: "GET / HTTP/1.1\r\nHost: guest\r\nConnection: close\r\n\r\n")
    ).get()
    let deadline = client.eventLoop.scheduleTask(in: .seconds(5)) { client.close(promise: nil) }
    let text = try await response.futureResult.get()
    deadline.cancel()
    #expect(text.hasPrefix("HTTP/1.1 401"))
    try await server.close().get()
    try await group.shutdownGracefully()
  } catch {
    try await group.shutdownGracefully()
    throw error
  }
}

private final class ResponseCapture: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  let result: EventLoopPromise<String>
  var response = ""
  init(result: EventLoopPromise<String>) { self.result = result }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    response += String(buffer: unwrapInboundIn(data))
  }
  func channelInactive(context: ChannelHandlerContext) { result.succeed(response) }
  func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}
