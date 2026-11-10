import Foundation
import IsoMacProtocol
import Testing

@testable import IsoSandboxCore

// docs/design/computer-use-screen-sync.md §10.

private func refusal(_ body: () throws -> Void) -> CURefusal? {
  do { try body() } catch let e as SandboxError { return e.refusal } catch {}
  return nil
}

/// A blank RGBX frame of `width`×`height`, with `set` pixels changed.
private func frame(_ width: Int, _ height: Int, set: [(x: Int, y: Int)] = []) -> [UInt8] {
  var px = [UInt8](repeating: 0, count: width * height * 4)
  for p in set { px[(p.y * width + p.x) * 4] = 0xFF }
  return px
}

private func sample(_ grid: inout DamageGrid, _ px: [UInt8]) throws -> UInt64 {
  try px.withUnsafeBytes { try grid.sample($0) }
}

private func region(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> GuestCURegion {
  GuestCURegion(x: x, y: y, width: w, height: h)
}

// MARK: damage grid

@Test func theFirstSampleIsTheBaselineAndIdenticalFramesLeaveTheSequenceAlone() throws {
  var g = DamageGrid(width: 64, height: 48)
  #expect(try sample(&g, frame(64, 48)) == 0)
  #expect(try sample(&g, frame(64, 48, set: [(5, 5)])) == 1)
  #expect(try sample(&g, frame(64, 48, set: [(5, 5)])) == 1)
  #expect(g.samples == 3)
  // Back to the old content is a change too; the sequence never decreases.
  #expect(try sample(&g, frame(64, 48)) == 2)
}

@Test func oneChangedByteDirtiesExactlyItsTile() throws {
  var g = DamageGrid(width: 64, height: 48)
  try sample(&g, frame(64, 48))
  var px = frame(64, 48)
  // The last byte of pixel (17, 33): tile (1, 2).
  px[(33 * 64 + 17) * 4 + 3] = 1
  #expect(try sample(&g, px) == 1)
  #expect(g.latest(in: region(16, 32, 16, 16)) == 1)
  #expect(g.latest(in: region(17, 33, 1, 1)) == 1)
  for (x, y) in [(0, 32), (32, 32), (16, 16), (16, 0)] {
    #expect(g.latest(in: region(x, y, 16, 16)) == 0)
  }
  #expect(g.latest(in: nil) == 1)
}

@Test func partialTilesOnTheRightAndBottomEdgesAreTracked() throws {
  // 40×20: three columns (the last 8 wide) and two rows (the last 4 high).
  var g = DamageGrid(width: 40, height: 20)
  #expect(g.columns == 3 && g.rows == 2)
  try sample(&g, frame(40, 20))
  #expect(try sample(&g, frame(40, 20, set: [(39, 19)])) == 1)
  #expect(g.latest(in: region(32, 16, 8, 4)) == 1)
  #expect(g.latest(in: region(0, 0, 32, 16)) == 0)
  #expect(try sample(&g, frame(40, 20, set: [(39, 19), (0, 0)])) == 2)
  #expect(g.latest(in: region(0, 0, 1, 1)) == 2)
  #expect(g.latest(in: region(39, 19, 1, 1)) == 1)
}

@Test func aSampleOfTheWrongSizeIsRefusedAndChangesNothing() throws {
  var g = DamageGrid(width: 16, height: 16)
  try sample(&g, frame(16, 16))
  #expect(throws: SandboxError.self) { try sample(&g, frame(8, 8)) }
  #expect(g.seq == 0)
}

@Test func theFullDisplayGridHasNineThousandTiles() {
  let g = DamageGrid(width: MacDisplay.width, height: MacDisplay.height)
  #expect(g.columns * g.rows == 9000)
}

// MARK: wait

private func parameters(
  idleMs: Int? = nil, timeoutMs: Int? = nil, until: GuestCUWaitUntil? = nil,
  region: GuestCURegion? = nil
) throws -> ScreenWait.Parameters {
  try ScreenWait.Parameters.validated(
    since: nil, idleMs: idleMs, timeoutMs: timeoutMs, until: until, region: region,
    width: MacDisplay.width, height: MacDisplay.height, current: 0)
}

/// Runs a wait on a fake clock that advances one tick per sleep; the region
/// changes at each time in `changes` (ms after entry).
private func simulate(_ p: ScreenWait.Parameters, changes: [Int]) async throws
  -> GuestCUWaitResult
{
  var now = 0
  return try await ScreenWait.run(
    ScreenWait(p, since: 0), first: 0, elapsedMs: { now },
    sleep: { now += ScreenWait.tickMs }, check: {},
    sample: { UInt64(changes.filter { $0 <= now }.count) })
}

@Test func anAnimationSettlesAboutIdleMsAfterItStops() async throws {
  // A 600 ms transition drawn at 60 Hz.
  let r = try await simulate(try parameters(), changes: Array(stride(from: 16, to: 600, by: 16)))
  #expect(r.outcome == .settled)
  #expect((844...900).contains(r.elapsedMs))
}

@Test func aBlinkingCaretSettlesBetweenTogglesAtTheDefaultButNotAt500() async throws {
  let caret = Array(stride(from: 250, to: 30_000, by: 500))
  let short = try await simulate(try parameters(idleMs: 250), changes: caret)
  #expect(short.outcome == .settled)
  let long = try await simulate(try parameters(idleMs: 500), changes: caret)
  #expect(long.outcome == .timedOut)
  #expect(long.elapsedMs >= GuestCUProtocol.Wait.defaultTimeoutMs)
}

@Test func untilIdleWithNoChangeReturnsUnchangedAfterIdleMs() async throws {
  let r = try await simulate(try parameters(until: .idle), changes: [])
  #expect(r.outcome == .unchanged)
  #expect((250..<300).contains(r.elapsedMs))
  // until: change keeps waiting for a change, to the timeout.
  let c = try await simulate(try parameters(timeoutMs: 1000), changes: [])
  #expect(c.outcome == .timedOut)
}

@Test func aChangeOutsideTheRegionIsIgnored() throws {
  var g = DamageGrid(width: 64, height: 64)
  try sample(&g, frame(64, 64))
  let watched = region(0, 0, 16, 16)
  let p = try ScreenWait.Parameters.validated(
    since: nil, idleMs: 100, timeoutMs: 400, until: .change, region: watched, width: 64,
    height: 64, current: g.seq)
  var w = ScreenWait(p, since: g.seq)
  #expect(w.feed(elapsedMs: 0, latest: g.latest(in: watched)) == nil)
  try sample(&g, frame(64, 64, set: [(50, 50)]))
  #expect(g.seq == 1)
  #expect(w.feed(elapsedMs: 200, latest: g.latest(in: watched)) == nil)
  #expect(w.feed(elapsedMs: 400, latest: g.latest(in: watched)) == .timedOut)
}

@Test func aChangeBetweenSinceAndEntryCountsAndQuietRunsFromEntry() {
  let p = ScreenWait.Parameters(since: 3, idleMs: 250, timeoutMs: 5000, until: .idle, region: nil)
  var w = ScreenWait(p, since: 3)
  #expect(w.feed(elapsedMs: 0, latest: 4) == nil)
  #expect(w.feed(elapsedMs: 249, latest: 4) == nil)
  #expect(w.feed(elapsedMs: 250, latest: 4) == .settled)
}

@Test func aHoldOrBrokenBindingEndsAWaitWithItsRefusal() async throws {
  var checks = 0
  let p = try parameters()
  await #expect(throws: SandboxError.self) {
    _ = try await ScreenWait.run(
      ScreenWait(p, since: 0), first: 0, elapsedMs: { checks * ScreenWait.tickMs }, sleep: {},
      check: {
        checks += 1
        if checks == 3 { throw SandboxError("the host holds computer use", refusal: .heldByHost) }
      },
      sample: { 0 })
  }
  #expect(checks == 3)
}

@Test func waitParametersAreBoundedAndDefaulted() throws {
  let d = try parameters()
  #expect(d.idleMs == 250 && d.timeoutMs == 5000 && d.until == .change && d.region == nil)
  func refused(
    since: UInt64? = nil, idleMs: Int? = nil, timeoutMs: Int? = nil, region: GuestCURegion? = nil
  ) -> CURefusal? {
    refusal {
      _ = try ScreenWait.Parameters.validated(
        since: since, idleMs: idleMs, timeoutMs: timeoutMs, until: nil, region: region,
        width: 1920, height: 1200, current: 7)
    }
  }
  #expect(refused(idleMs: 49) == .invalidAction)
  #expect(refused(idleMs: 2001) == .invalidAction)
  #expect(refused(timeoutMs: 99) == .invalidAction)
  #expect(refused(timeoutMs: 30_001) == .invalidAction)
  #expect(refused(since: 8) == .invalidAction)
  #expect(refused(since: 7) == nil)
  #expect(refused(region: region(0, 0, 1920, 1200)) == nil)
  #expect(refused(region: region(1919, 1199, 1, 1)) == nil)
  for bad in [
    region(0, 0, 0, 1), region(0, 0, 1, 0), region(-1, 0, 1, 1), region(0, -1, 1, 1),
    region(1, 0, 1920, 1), region(0, 1, 1, 1200), region(Int.max, 0, 1, 1),
    region(0, 0, Int.max, 1),
  ] {
    #expect(refused(region: bad) == .invalidAction)
  }
}

@Test func oneWaitRunsAtATimePerOrigin() throws {
  var slots = CUWaitSlots()
  try slots.take(.guest)
  #expect(refusal { try slots.take(.guest) } == .busy)
  // A waiting guest does not refuse the host's wait.
  try slots.take(.host)
  #expect(refusal { try slots.take(.host) } == .busy)
  slots.free(.guest)
  try slots.take(.guest)
}

// MARK: wire

private func parse(_ s: String) -> Result<GuestCURequest, GuestCURequest.ParseError> {
  GuestCURequest.parse(Array(s.utf8))
}

@Test func waitRequestsParseWithClosedBoundedFields() throws {
  guard
    case .success(let w) = parse(
      #"{"op":"wait","session":"s","since":4,"idleMs":300,"timeoutMs":900,"until":"idle","region":{"x":1,"y":2,"width":3,"height":4}}"#
    )
  else {
    Issue.record("wait refused")
    return
  }
  #expect(w.since == 4 && w.idleMs == 300 && w.timeoutMs == 900 && w.until == .idle)
  #expect(w.region == region(1, 2, 3, 4))
  #expect(parse(#"{"op":"wait"}"#) == .failure(.missing("session")))
  #expect(
    parse(#"{"op":"wait","session":"s","region":{"x":1,"y":2,"width":3,"height":4,"z":0}}"#)
      == .failure(.unknownField("region.z")))
  #expect(parse(#"{"op":"wait","session":"s","region":[1,2,3,4]}"#) == .failure(.malformed))
  #expect(parse(#"{"op":"wait","session":"s","until":"forever"}"#) == .failure(.malformed))
  #expect(parse(#"{"op":"wait","session":"s","since":-1}"#) == .failure(.malformed))
  #expect(parse(#"{"op":"wait","session":"s","idleMs":2.5}"#) == .failure(.malformed))
  #expect(parse(#"{"op":"wait","session":"s","region":{"x":1}}"#) == .failure(.malformed))
}

/// The response fields of the helper released before screen sync.
private struct ReleasedGuestCUResponse: Decodable {
  var ok: Bool
  var error: String?
  var refusal: CURefusal?
  var beforeInput: Bool?
  var session: String?
  var frame: GuestCUFrame?
  var submitted: Int?
  var controller: GuestCUController?
  var holdRemainingSeconds: Int?
}

@Test func responsesStayReadableAcrossVersionSkew() throws {
  // New host, old helper: the new fields are ignored.
  var new = GuestCUResponse(ok: true)
  new.submitted = 3
  new.damageSeq = 9
  new.wait = GuestCUWaitResult(outcome: .settled, elapsedMs: 300)
  let old = try JSONDecoder().decode(ReleasedGuestCUResponse.self, from: new.encodedLine())
  #expect(old.ok && old.submitted == 3)
  // Old host, new helper: no damageSeq, so no wait support.
  let fromOld = try JSONDecoder().decode(
    GuestCUResponse.self,
    from: Data(#"{"ok":true,"controller":"idle","holdRemainingSeconds":0}"#.utf8))
  #expect(fromOld.damageSeq == nil && fromOld.wait == nil)
  // An owner from before `wait` reports no wait counts.
  let counts = try JSONDecoder().decode(
    MacGuestCUCounters.self,
    from: Data(
      #"{"frameRate":4,"sessions":1,"frames":2,"actions":3,"statusRequests":4,"preemptions":0,"refusals":{}}"#
        .utf8))
  #expect(counts.waits == 0 && counts.waitOutcomes.isEmpty && counts.actions == 3)
}

@Test func theLinkCountsWaitsByOutcomeOnly() {
  let link = MacGuestCULink(
    frameRate: 4, log: { _ in },
    handle: { _ in
      var r = GuestCUResponse(ok: true)
      r.wait = GuestCUWaitResult(outcome: .timedOut, elapsedMs: 5000)
      r.damageSeq = 1
      return r
    })
  let line = Array(#"{"op":"wait","session":"s","region":{"x":1,"y":2,"width":3,"height":4}}"#.utf8)
  #expect(link.respond(to: line, now: Date(timeIntervalSince1970: 1)).ok)
  #expect(link.counters.waits == 1)
  #expect(link.counters.waitOutcomes == ["timedOut": 1])
}

@Test func aWaitCostsOneActionToken() {
  var l = GuestCULimits(frameRate: 1, now: Date(timeIntervalSince1970: 1))
  let wait = GuestCURequest(op: .wait, session: "s")
  #expect(GuestCULimits.actionCost(wait) == 1)
  let t = Date(timeIntervalSince1970: 1)
  for _ in 0..<GuestCUProtocol.actionRate {
    let ok = l.admit(wait, at: t)
    #expect(ok)
  }
  let over = !l.admit(wait, at: t)
  #expect(over)
}

// MARK: MCP

private final class Host: @unchecked Sendable {
  var sent: [GuestCURequest] = []
  var damage: UInt64? = 5
  var frameRefusal: CURefusal?

  func send(_ r: GuestCURequest) throws -> GuestCUResponse {
    sent.append(r)
    var out = GuestCUResponse(ok: true)
    switch r.op {
    case .session: out.session = "s1"
    case .status:
      out.controller = .idle
      out.damageSeq = damage
    case .act:
      out.submitted = 4
      out.damageSeq = damage
    case .wait:
      out.wait = GuestCUWaitResult(outcome: .settled, elapsedMs: 280)
      out.damageSeq = damage.map { $0 + 1 }
    case .frame:
      if let frameRefusal { return .refused("refused", frameRefusal) }
      out.frame = GuestCUFrame(frameId: "f2", width: 1920, height: 1200, png: Data([7]))
      out.damageSeq = damage.map { $0 + 1 }
    }
    return out
  }
}

private func call(_ server: GuestCUMCP, _ name: String, _ args: [String: Any] = [:]) throws
  -> [String: Any]
{
  let object: [String: Any] = [
    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
    "params": ["name": name, "arguments": args],
  ]
  let reply = try #require(server.handle(Array(try JSONSerialization.data(withJSONObject: object))))
  let r = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
  return try #require(r["result"] as? [String: Any])
}

private func texts(_ result: [String: Any]) -> [String] {
  (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
}

@Test func actionsSettleByDefaultFromTheActionsOwnSequence() throws {
  let host = Host()
  let server = GuestCUMCP(send: host.send)
  let r = try call(server, "click", ["x": 1, "y": 2, "frameId": "f1"])
  #expect(r["isError"] == nil)
  #expect(host.sent.map(\.op) == [.session, .act, .wait])
  let w = try #require(host.sent.last)
  #expect(w.session == "s1" && w.since == 5 && w.until == .idle && w.region == nil)
  #expect(w.idleMs == 250 && w.timeoutMs == 3000)
  #expect(texts(r).first?.contains("submitted 4") == true)
  #expect(texts(r).first?.contains("settled after 280 ms (damageSeq 6)") == true)
}

@Test func settleMsZeroAnOlderHostOrABadValueSendNoWait() throws {
  let host = Host()
  let server = GuestCUMCP(send: host.send)
  _ = try call(server, "move", ["x": 1, "y": 2, "frameId": "f1", "settle_ms": 0])
  #expect(host.sent.map(\.op) == [.session, .act])
  // A bad value is refused before the action runs.
  host.sent = []
  for bad: Any in [10, 2001, -1, 2.5, "250", true] {
    let r = try call(server, "move", ["x": 1, "y": 2, "frameId": "f1", "settle_ms": bad])
    #expect(r["isError"] as? Bool == true)
  }
  #expect(host.sent.isEmpty)
  let old = Host()
  old.damage = nil
  _ = try call(GuestCUMCP(send: old.send), "key", ["keyCode": 1, "frameId": "f1"])
  #expect(old.sent.map(\.op) == [.session, .act])
}

@Test func aRefusedSettleWaitStillReportsTheActionAsSubmitted() throws {
  let host = Host()
  let server = GuestCUMCP(
    send: { r in
      r.op == .wait ? .refused("busy", .busy, beforeInput: true) : try host.send(r)
    })
  let r = try call(server, "type", ["text": "hi", "frameId": "f1"])
  #expect(r["isError"] == nil)
  #expect(texts(r).first?.contains("submitted 4") == true)
  #expect(texts(r).first?.contains("settling skipped: refused (busy)") == true)
}

@Test func waitForScreenWaitsThenTakesOneScreenshot() throws {
  let host = Host()
  let server = GuestCUMCP(send: host.send)
  let r = try call(
    server, "wait_for_screen",
    [
      "since": 3, "idle_ms": 400, "timeout_ms": 2000, "until": "idle",
      "region": ["x": 0, "y": 0, "width": 10, "height": 10],
    ])
  #expect(r["isError"] == nil)
  #expect(host.sent.map(\.op) == [.status, .session, .wait, .frame])
  let w = host.sent[2]
  #expect(w.since == 3 && w.idleMs == 400 && w.timeoutMs == 2000 && w.until == .idle)
  #expect(w.region == region(0, 0, 10, 10))
  let content = r["content"] as? [[String: Any]] ?? []
  #expect(content.first?["type"] as? String == "image")
  #expect(texts(r).contains { $0.contains("frameId: f2") && $0.contains("damageSeq: 6") })
  #expect(texts(r).contains { $0.contains("settled after 280 ms") })
  // `status` is asked once.
  _ = try call(server, "wait_for_screen", ["include_screenshot": false])
  #expect(host.sent.map(\.op) == [.status, .session, .wait, .frame, .wait])
}

@Test func waitForScreenReturnsTheWaitAloneWhenTheFrameIsRateLimited() throws {
  let host = Host()
  host.frameRefusal = .rateLimited
  let r = try call(GuestCUMCP(send: host.send), "wait_for_screen")
  #expect(r["isError"] == nil)
  #expect(texts(r).contains { $0.contains("settled after 280 ms") })
  #expect(texts(r).contains { $0.contains("frame rate limit") })
}

@Test func waitForScreenOnAnOlderHostSaysItIsNotSupported() throws {
  let host = Host()
  host.damage = nil
  let r = try call(GuestCUMCP(send: host.send), "wait_for_screen")
  #expect(r["isError"] as? Bool == true)
  #expect(texts(r).first?.contains("not supported by this host") == true)
  #expect(host.sent.map(\.op) == [.status])
}

@Test func waitForScreenRefusesMalformedArgumentsBeforeSending() throws {
  let host = Host()
  let server = GuestCUMCP(send: host.send)
  for args: [String: Any] in [
    ["until": "forever"], ["idle_ms": "250"], ["since": -1],
    ["region": ["x": 0, "y": 0, "width": 1]],
    ["region": ["x": 0, "y": 0, "width": 1, "height": 1, "z": 1]],
  ] {
    let r = try call(server, "wait_for_screen", args)
    #expect(r["isError"] as? Bool == true)
  }
  #expect(host.sent.map(\.op) == [.status])
}

@Test func screenshotsReportTheDamageSequence() throws {
  let host = Host()
  let r = try call(GuestCUMCP(send: host.send), "screenshot")
  #expect(texts(r).first == "frameId: f2 (1920×1200 pixels, origin top-left), damageSeq: 6")
}
