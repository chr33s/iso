import Foundation
import IsoMacProtocol
import Testing

@testable import IsoSandboxCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func refusal(_ body: () throws -> Void) -> CURefusal? {
  do { try body() } catch let e as SandboxError { return e.refusal } catch {}
  return nil
}

// MARK: control

@Test func aHostHoldEndsTheGuestSessionAndRefusesNewOnesUntilItEnds() throws {
  var c = CUControl()
  #expect(c.controller(at: t0) == .idle)
  #expect(try c.openGuest("g1", at: t0) == nil)
  #expect(c.controller(at: t0) == .guest)
  #expect(refusal { try c.requireGuest("g1", at: t0) } == nil)
  // A second guest session replaces the first.
  #expect(try c.openGuest("g2", at: t0) == "g1")
  #expect(refusal { try c.requireGuest("g1", at: t0) } == .unknownSession)

  #expect(c.hold(for: 60, at: t0) == "g2")
  #expect(c.controller(at: t0) == .host)
  #expect(c.holdRemaining(at: t0.addingTimeInterval(0.5)) == 60)
  #expect(refusal { try c.requireGuest("g2", at: t0) } == .heldByHost)
  let duringHold = refusal { _ = try c.openGuest("g3", at: t0.addingTimeInterval(59)) }
  #expect(duringHold == .heldByHost)
  // Expired: the guest may open a new session; the old one stays gone.
  let later = t0.addingTimeInterval(61)
  #expect(c.controller(at: later) == .idle)
  #expect(c.holdRemaining(at: later) == 0)
  #expect(refusal { try c.requireGuest("g2", at: later) } == .unknownSession)
  #expect(try c.openGuest("g3", at: later) == nil)
}

@Test func holdsExtendButNeverShortenAndReleaseEndsThem() {
  var c = CUControl()
  _ = c.hold(for: 300, at: t0)
  // The implicit 60 s hold of host input keeps a longer explicit hold.
  _ = c.hold(for: CUControl.implicitHold, at: t0.addingTimeInterval(10))
  #expect(c.holdRemaining(at: t0.addingTimeInterval(10)) == 290)
  _ = c.hold(for: 600, at: t0.addingTimeInterval(10))
  #expect(c.holdRemaining(at: t0.addingTimeInterval(10)) == 600)
  c.release()
  #expect(c.controller(at: t0.addingTimeInterval(10)) == .idle)
}

// MARK: limits

@Test func tokenBucketsRefillAtTheirRateAndCapAtOneSecond() {
  var b = TokenBucket(rate: 4, now: t0)
  for _ in 0..<4 {
    do {
      let ok = b.take(1, at: t0)
      #expect(ok)
    }
  }
  do {
    let ok = !b.take(1, at: t0)
    #expect(ok)
  }
  do {
    let ok = b.take(1, at: t0.addingTimeInterval(0.25))
    #expect(ok)
  }
  do {
    let ok = !b.take(1, at: t0.addingTimeInterval(0.25))
    #expect(ok)
  }
  // A long idle saves at most one second of tokens.
  let idle = t0.addingTimeInterval(100)
  for _ in 0..<4 {
    do {
      let ok = b.take(1, at: idle)
      #expect(ok)
    }
  }
  do {
    let ok = !b.take(1, at: idle)
    #expect(ok)
  }
}

@Test func framesAndActionsHaveSeparateLimitsAndTypingCostsByLength() {
  var l = GuestCULimits(frameRate: 2, now: t0)
  let frame = GuestCURequest(op: .frame, session: "s")
  do {
    let ok = l.admit(frame, at: t0)
    #expect(ok)
  }
  do {
    let ok = l.admit(frame, at: t0)
    #expect(ok)
  }
  do {
    let ok = !l.admit(frame, at: t0)
    #expect(ok)
  }
  // Actions are unaffected by the frame limit.
  do {
    let ok = l.admit(GuestCURequest(op: .status), at: t0)
    #expect(ok)
  }
  var long = GuestCUAction(kind: "type")
  long.text = String(repeating: "a", count: 65)
  #expect(GuestCULimits.actionCost(GuestCURequest(op: .act, action: long)) == 2)
  long.text = String(repeating: "a", count: 64 * 20)  // 20 > the 19 left
  do {
    let ok = !l.admit(
      GuestCURequest(op: .act, session: "s", action: long, basedOnFrame: "f"), at: t0)
    #expect(ok)
  }
}

@Test func refusedRequestsThatDidNoWorkGiveTheirTokensBack() {
  var l = GuestCULimits(frameRate: 1, now: t0)
  let frame = GuestCURequest(op: .frame, session: "s")
  func admitted() -> Bool { l.admit(frame, at: t0) }
  #expect(admitted())
  // A host hold refused it: the retry after reopening the session may run.
  l.settle(frame, .refused("held", .heldByHost))
  #expect(admitted())
  // A blank frame was captured: no refund.
  l.settle(frame, .refused("blank", .blankFrame))
  #expect(!admitted())
  // An action refused after input started is not refunded either.
  var m = GuestCULimits(frameRate: 1, now: t0)
  var long = GuestCUAction(kind: "type")
  long.text = String(repeating: "a", count: 64 * 20)
  let act = GuestCURequest(op: .act, session: "s", action: long, basedOnFrame: "f")
  func acted() -> Bool { m.admit(act, at: t0) }
  #expect(acted())
  m.settle(act, .refused("lost", .sessionRefused, beforeInput: false))
  #expect(!acted())
  m.settle(act, .refused("busy", .busy, beforeInput: true))
  #expect(acted())
}

@Test func everyLineCountsAgainstTheOverallCapMalformedOnesToo() {
  let link = MacGuestCULink(
    frameRate: 10, log: { _ in }, handle: { _ in GuestCUResponse(ok: true) })
  let junk = Array("not json".utf8)
  for _ in 0..<GuestCUProtocol.requestRate {
    #expect(link.respond(to: junk, now: t0).refusal == .invalidAction)
  }
  let over = link.respond(to: Array(#"{"op":"status"}"#.utf8), now: t0)
  #expect(over.refusal == .rateLimited)
  #expect(link.respond(to: Array(#"{"op":"status"}"#.utf8), now: t0.addingTimeInterval(1)).ok)
}

@Test func aLongTypeFitsTheBucketAtTheCostOfAFullSecond() {
  var long = GuestCUAction(kind: "type")
  long.text = String(repeating: "a", count: 4096)
  let act = GuestCURequest(op: .act, session: "s", action: long, basedOnFrame: "f")
  #expect(GuestCULimits.actionCost(act) == Double(GuestCUProtocol.actionRate))
  var l = GuestCULimits(frameRate: 1, now: t0)
  let first = l.admit(act, at: t0)
  let second = l.admit(act, at: t0)
  let later = l.admit(act, at: t0.addingTimeInterval(1))
  #expect(first && !second && later)
}

@Test func aRequestTheHostMayHaveRunIsNeverResentWhenItIsAnAction() {
  let act = GuestCURequest(
    op: .act, session: "s", action: GuestCUAction(kind: "move"), basedOnFrame: "f")
  #expect(!act.mayResend(written: true))
  #expect(act.mayResend(written: false))
  for op in [GuestCURequest.Op.session, .frame, .status] {
    #expect(GuestCURequest(op: op, session: "s").mayResend(written: true))
  }
}

@Test func lineReadingFindsEveryLineWhateverTheReadBoundaries() throws {
  var fds: [Int32] = [0, 0]
  #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
  defer { close(fds[0]) }
  // Two lines in one write, then one split over three writes.
  for chunk in ["one\ntwo\nthr", "e", "e\n"] {
    _ = chunk.utf8CString.withUnsafeBufferPointer {
      write(fds[1], $0.baseAddress, chunk.utf8.count)
    }
  }
  close(fds[1])
  var reader = LineReader(fd: fds[0], limit: 64)
  var lines: [String] = []
  while case .line(let l) = reader.next() { lines.append(String(decoding: l, as: UTF8.self)) }
  #expect(lines == ["one", "two", "three"])
}

// MARK: wire

private func parse(_ s: String) -> Result<GuestCURequest, GuestCURequest.ParseError> {
  GuestCURequest.parse(Array(s.utf8))
}

@Test func guestRequestsParseIntoTheClosedSetOnly() {
  #expect(parse(#"{"op":"session"}"#) == .success(GuestCURequest(op: .session)))
  #expect(parse(#"{"op":"status"}"#) == .success(GuestCURequest(op: .status)))
  guard
    case .success(let act) = parse(
      #"{"op":"act","session":"s","basedOnFrame":"f","action":{"kind":"click","x":1,"y":2}}"#)
  else {
    Issue.record("act refused")
    return
  }
  #expect(act.action?.x == 1)
  #expect(parse(#"{"op":"stop"}"#) == .failure(.malformed))
  #expect(parse(#"{"op":"inspect"}"#) == .failure(.malformed))
  #expect(parse(#"{"op":"session","extra":1}"#) == .failure(.unknownField("extra")))
  #expect(
    parse(#"{"op":"act","session":"s","basedOnFrame":"f","action":{"kind":"click","exec":1}}"#)
      == .failure(.unknownField("action.exec")))
  #expect(
    parse(#"{"op":"act","session":"s","action":{"kind":"click","x":1,"y":2}}"#)
      == .failure(.missing("basedOnFrame")))
  #expect(parse(#"{"op":"frame"}"#) == .failure(.missing("session")))
  #expect(parse("not json") == .failure(.notJSON))
  let big = #"{"op":"session","session":""# + String(repeating: "a", count: 65 * 1024) + #""}"#
  #expect(parse(big) == .failure(.tooLong))
}

@Test func guestActionsBecomeRuntimeActionsFieldForField() throws {
  var a = GuestCUAction(kind: "drag")
  a.path = [GuestCUPoint(x: 1, y: 2), GuestCUPoint(x: 3, y: 4)]
  a.button = "right"
  let host = try MacGuestCULink.hostAction(a)
  #expect(
    try host.validated(width: 100, height: 100)
      == .drag([CUPoint(x: 1, y: 2), CUPoint(x: 3, y: 4)], .right))
  var k = GuestCUAction(kind: "key")
  k.keyCode = 1
  k.modifiers = ["command"]
  #expect(
    try MacGuestCULink.hostAction(k).validated(width: 100, height: 100)
      == .key(keyCode: 1, modifiers: [.command]))
  var bad = GuestCUAction(kind: "click")
  bad.button = "fourth"
  #expect(throws: (any Error).self) { try MacGuestCULink.hostAction(bad) }
}

@Test func theLinkRefusesMalformedAndOverLimitRequestsBeforeTheScreen() {
  let calls = Counter()
  let link = MacGuestCULink(
    frameRate: 1, log: { _ in },
    handle: { _ in
      calls.add()
      return GuestCUResponse(ok: true)
    })
  let bad = link.respond(to: Array(#"{"op":"stop"}"#.utf8), now: t0)
  #expect(bad.refusal == .invalidAction)
  #expect(bad.beforeInput == true)
  let frame = Array(#"{"op":"frame","session":"s"}"#.utf8)
  #expect(link.respond(to: frame, now: t0).ok)
  let limited = link.respond(to: frame, now: t0)
  #expect(limited.refusal == .rateLimited)
  #expect(limited.beforeInput == true)
  #expect(calls.value == 1)
  #expect(link.respond(to: frame, now: t0.addingTimeInterval(1)).ok)
  #expect(calls.value == 2)
}

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  func add() { lock.withLock { n += 1 } }
  var value: Int { lock.withLock { n } }
}

private final class LogLines: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func add(_ s: String) { lock.withLock { lines.append(s) } }
  var all: String { lock.withLock { lines.joined(separator: "\n") } }
}

@Test func guestChosenFieldNamesNeverReachTheOwnerLog() {
  let log = LogLines()
  let link = MacGuestCULink(
    frameRate: 4, log: log.add, handle: { _ in GuestCUResponse(ok: true) })
  let r = link.respond(to: Array(#"{"op":"status","evilname":1}"#.utf8), now: t0)
  #expect(r.refusal == .invalidAction)
  #expect(log.all.contains("unknown field"))
  #expect(!log.all.contains("evilname"))
}

@Test func theConnectionCapRefusesAThirdConnection() {
  let link = MacGuestCULink(frameRate: 4, log: { _ in }, handle: { _ in GuestCUResponse(ok: true) })
  var pairs: [[Int32]] = []
  for _ in 0..<3 {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    pairs.append(fds)
  }
  #expect(link.accept(fd: pairs[0][0], retaining: nil))
  #expect(link.accept(fd: pairs[1][0], retaining: nil))
  #expect(!link.accept(fd: pairs[2][0], retaining: nil))
  #expect(link.connectionCount == 2)
  for p in pairs { close(p[1]) }
}

@Test func guestFrameRatesAreBounded() throws {
  #expect(throws: SandboxError.self) { try MacGuestComputerUse(frameRate: 0) }
  #expect(throws: SandboxError.self) { try MacGuestComputerUse(frameRate: 11) }
  #expect(try MacGuestComputerUse(frameRate: 10).frameRate == 10)
  #expect(GuestCUProtocol.defaultFrameRate == 4)
}

@Test func recordsWithoutGuestComputerUseStillDecode() throws {
  let json = #"""
    {"id":"a","owner":"o","template":"t","templateBuild":"b","cpus":2,"memoryBytes":1,
     "macAddress":"m","subnetIndex":3,"network":"shared","enrollment":"pending",
     "authorizedKey":"k","createdAt":"2026-10-31T00:00:00Z"}
    """#
  let d = JSONDecoder()
  d.dateDecodingStrategy = .iso8601
  #expect(try d.decode(MacSandboxRecord.self, from: Data(json.utf8)).guestComputerUse == nil)
}

// MARK: MCP

private final class FakeHost: @unchecked Sendable {
  var replies: [GuestCURequest.Op: [GuestCUResponse]] = [:]
  var sent: [GuestCURequest] = []

  func send(_ r: GuestCURequest) throws -> GuestCUResponse {
    sent.append(r)
    guard var queue = replies[r.op], !queue.isEmpty else { return GuestCUResponse(ok: true) }
    let next = queue.count > 1 ? queue.removeFirst() : queue[0]
    replies[r.op] = queue
    return next
  }
}

private func ok(_ build: (inout GuestCUResponse) -> Void) -> GuestCUResponse {
  var r = GuestCUResponse(ok: true)
  build(&r)
  return r
}

private func rpc(_ server: GuestCUMCP, _ object: [String: Any]) throws -> [String: Any] {
  let line = Array(try JSONSerialization.data(withJSONObject: object))
  let reply = try #require(server.handle(line))
  return try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
}

private func callTool(_ server: GuestCUMCP, _ name: String, _ args: [String: Any] = [:]) throws
  -> [String: Any]
{
  let r = try rpc(
    server,
    [
      "jsonrpc": "2.0", "id": 7, "method": "tools/call",
      "params": ["name": name, "arguments": args],
    ])
  return try #require(r["result"] as? [String: Any])
}

private func texts(_ result: [String: Any]) -> [String] {
  (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
}

@Test func theMCPServerNegotiatesAndListsItsTools() throws {
  let server = GuestCUMCP(send: { _ in GuestCUResponse(ok: true) })
  let r = try rpc(
    server,
    [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": ["protocolVersion": "2024-11-05"],
    ])
  let result = try #require(r["result"] as? [String: Any])
  #expect(result["protocolVersion"] as? String == "2024-11-05")
  let unknown = try rpc(
    server,
    [
      "jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": ["protocolVersion": "1999-01-01"],
    ])
  #expect(
    (unknown["result"] as? [String: Any])?["protocolVersion"] as? String
      == GuestCUMCP.protocolVersion)
  #expect(
    server.handle(Array(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)) == nil)
  let list = try rpc(server, ["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
  let tools = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap {
    $0["name"] as? String
  }
  #expect(
    Set(tools) == [
      "screenshot", "control_status", "click", "move", "drag", "scroll", "key", "type",
    ])
  // No tool holds a button down.
  #expect(!tools.contains("down") && !tools.contains("up"))
  let missing = try rpc(server, ["jsonrpc": "2.0", "id": 3, "method": "resources/list"])
  #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32601)
}

@Test func screenshotsOpenASessionOnceAndReturnTheImageAndFrameId() throws {
  let host = FakeHost()
  host.replies[.session] = [ok { $0.session = "s1" }]
  host.replies[.frame] = [
    ok { $0.frame = GuestCUFrame(frameId: "f9", width: 1920, height: 1200, png: Data([1, 2])) }
  ]
  let server = GuestCUMCP(send: host.send)
  let shot = try callTool(server, "screenshot")
  let content = shot["content"] as? [[String: Any]] ?? []
  #expect(content.first?["type"] as? String == "image")
  #expect(content.first?["data"] as? String == Data([1, 2]).base64EncodedString())
  #expect(texts(shot).first?.contains("frameId: f9") == true)
  _ = try callTool(server, "screenshot")
  #expect(host.sent.map(\.op) == [.session, .frame, .frame])
  #expect(host.sent.last?.session == "s1")
}

@Test func anActionCutShortIsNeverResentOnANewSession() throws {
  let host = FakeHost()
  host.replies[.session] = [ok { $0.session = "s1" }, ok { $0.session = "s2" }]
  host.replies[.act] = [.refused("session refused", .sessionRefused, beforeInput: false)]
  let server = GuestCUMCP(send: host.send)
  let r = try callTool(server, "type", ["text": "abc", "frameId": "f1"])
  #expect(r["isError"] as? Bool == true)
  #expect(texts(r).first?.contains("may have been applied") == true)
  #expect(host.sent.map(\.op) == [.session, .act])
}

@Test func actionsNeedAFrameAndReopenAForgottenSessionOnce() throws {
  let host = FakeHost()
  host.replies[.session] = [ok { $0.session = "s1" }, ok { $0.session = "s2" }]
  host.replies[.act] = [
    .refused("unknown session", .unknownSession, beforeInput: true), ok { $0.submitted = 6 },
  ]
  let server = GuestCUMCP(send: host.send)
  let noFrame = try callTool(server, "click", ["x": 10, "y": 20])
  #expect(noFrame["isError"] as? Bool == true)
  #expect(host.sent.isEmpty)
  let r = try callTool(server, "click", ["x": 10, "y": 20, "frameId": "f1"])
  #expect(r["isError"] == nil)
  #expect(texts(r).first?.contains("submitted 6") == true)
  #expect(host.sent.map(\.op) == [.session, .act, .session, .act])
  #expect(host.sent.last?.session == "s2")
  #expect(host.sent.last?.basedOnFrame == "f1")
  #expect(host.sent.last?.action?.x == 10)
}

@Test func aHostHoldIsReportedWithItsRemainingTime() throws {
  let host = FakeHost()
  host.replies[.session] = [.refused("the host holds computer use", .heldByHost)]
  host.replies[.status] = [
    ok {
      $0.controller = .host
      $0.holdRemainingSeconds = 42
    }
  ]
  let server = GuestCUMCP(send: host.send)
  let r = try callTool(server, "screenshot")
  #expect(r["isError"] as? Bool == true)
  #expect(texts(r).first?.contains("42 more seconds") == true)
  #expect(host.sent.map(\.op) == [.session, .status])
  let status = try callTool(server, "control_status")
  #expect(texts(status).first == "controller: host, hold remaining: 42 s")
}
