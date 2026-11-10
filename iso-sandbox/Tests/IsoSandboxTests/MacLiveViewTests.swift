import Darwin
import Foundation
import IsoMacProtocol
import Testing

@testable import IsoSandboxCore

// docs/design/computer-use-live-view.md: the listener's admission rules,
// the closed viewer input set, takeover and stuck-input state.

private let t0 = Date(timeIntervalSince1970: 1_000_000)

// MARK: token

@Test func streamTokensAre256BitsAndNeverPrinted() throws {
  let a = try LiveViewToken.random()
  let b = try LiveViewToken.random()
  #expect(a.value.count == 64 && a.value.allSatisfy(\.isHexDigit))
  #expect(a.value != b.value)
  #expect("\(a)" == "<stream token>")
  #expect(a.matches(a.value))
  #expect(!a.matches(b.value))
  #expect(!a.matches(String(a.value.dropLast())))
  #expect(!a.matches(a.value + "0"))
  #expect(!a.matches(""))
}

// MARK: HTTP admission

private func request(_ path: String, host: String = "127.0.0.1:6000", extra: [String] = [])
  -> LiveViewHTTPRequest?
{
  let lines = ["GET \(path) HTTP/1.1", "Host: \(host)"] + extra + ["", ""]
  return LiveViewHTTPRequest.parse(Array(lines.joined(separator: "\r\n").utf8))
}

private let upgrade = [
  "Origin: http://127.0.0.1:6000", "Upgrade: websocket", "Connection: keep-alive, Upgrade",
  "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
]

@Test func onlyTheExactLoopbackHostAndOriginAreServed() throws {
  #expect(
    LiveViewRoute.decide(try #require(request("/")), port: 6000)
      == .asset(contentType: "text/html; charset=utf-8", body: LiveViewPage.html))
  #expect(
    LiveViewRoute.decide(try #require(request("/viewer.js")), port: 6000)
      == .asset(contentType: "text/javascript; charset=utf-8", body: LiveViewPage.script))
  #expect(
    LiveViewRoute.decide(try #require(request("/ws", extra: upgrade)), port: 6000)
      == .upgrade(acceptKey: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
  // DNS rebinding: any other Host, even another name for loopback.
  for host in ["localhost:6000", "127.0.0.1", "127.0.0.1:6001", "evil.example:6000"] {
    #expect(
      LiveViewRoute.decide(try #require(request("/ws", host: host, extra: upgrade)), port: 6000)
        == .refused(status: 421, reason: .host))
  }
  // Cross-site WebSocket hijacking: any other Origin, or none.
  for origin in ["Origin: http://evil.example", "Origin: http://localhost:6000", "Origin: null"] {
    let extra = upgrade.map { $0.hasPrefix("Origin") ? origin : $0 }
    #expect(
      LiveViewRoute.decide(try #require(request("/ws", extra: extra)), port: 6000)
        == .refused(status: 403, reason: .origin))
  }
  let noOrigin = upgrade.filter { !$0.hasPrefix("Origin") }
  #expect(
    LiveViewRoute.decide(try #require(request("/ws", extra: noOrigin)), port: 6000)
      == .refused(status: 403, reason: .origin))
  let oldVersion = upgrade.map {
    $0.hasPrefix("Sec-WebSocket-Version") ? "Sec-WebSocket-Version: 8" : $0
  }
  #expect(
    LiveViewRoute.decide(try #require(request("/ws", extra: oldVersion)), port: 6000)
      == .refused(status: 400, reason: .upgrade))
  #expect(
    LiveViewRoute.decide(try #require(request("/etc/passwd")), port: 6000)
      == .refused(status: 404, reason: .notFound))
  // A repeated header is not a request.
  #expect(request("/", extra: ["Host: 127.0.0.1:6000"]) == nil)
  #expect(LiveViewHTTPRequest.parse(Array("GET / HTTP/1.0\r\n\r\n".utf8)) == nil)
}

// MARK: WebSocket frames

private func masked(_ opcode: UInt8, _ payload: [UInt8], fin: Bool = true) -> [UInt8] {
  let mask: [UInt8] = [1, 2, 3, 4]
  var out: [UInt8] = [(fin ? 0x80 : 0) | opcode]
  if payload.count < 126 {
    out.append(0x80 | UInt8(payload.count))
  } else {
    out += [0x80 | 126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
  }
  out += mask
  out += payload.enumerated().map { $0.element ^ mask[$0.offset % 4] }
  return out
}

@Test func clientFramesAreMaskedWholeAndSmall() throws {
  var buffer = masked(0x1, Array("hello".utf8)) + masked(0x9, [7])
  #expect(try WSFrame.decode(&buffer) == .text("hello"))
  #expect(try WSFrame.decode(&buffer) == .ping([7]))
  #expect(buffer.isEmpty)
  var partial = Array(masked(0x1, Array("hello".utf8)).prefix(5))
  #expect(try WSFrame.decode(&partial) == nil)
  func refused(_ bytes: [UInt8]) -> WSFrame.DecodeError? {
    var b = bytes
    do { _ = try WSFrame.decode(&b) } catch { return error }
    return nil
  }
  #expect(refused([0x81, 0x01, 0x41]) == .unmasked)
  #expect(refused(masked(0x1, Array("a".utf8), fin: false)) == .fragmented)
  #expect(
    refused(masked(0x1, [UInt8](repeating: 0x61, count: LiveView.maxMessage + 1))) == .tooLarge)
  #expect(refused([0x81, 0xFF] + [UInt8](repeating: 0, count: 12)) == .tooLarge)
  #expect(refused(masked(0x3, [])) == .badOpcode)
  #expect(refused([0xC1, 0x80, 0, 0, 0, 0]) == .reserved)
  #expect(refused(masked(0x1, [0xFF])) == .notUTF8)
  #expect(WSFrame.encode(opcode: 0x2, [9]) == [0x82, 1, 9])
  #expect(
    Array(WSFrame.encode(opcode: 0x2, [UInt8](repeating: 0, count: 300)).prefix(4)) == [
      0x82, 126, 1, 44,
    ])
  #expect(WSFrame.encode(opcode: 0x2, [UInt8](repeating: 0, count: 70_000))[1] == 127)
}

// MARK: viewer messages

private func parse(_ s: String) -> Result<LiveViewMessage, LiveViewMessage.ParseError> {
  LiveViewMessage.parse(s, width: 1920, height: 1200)
}

@Test func viewerMessagesAreAClosedBoundedSet() {
  #expect(parse(#"{"type":"auth","token":"t"}"#) == .success(.auth("t")))
  #expect(
    parse(#"{"type":"pointer","kind":"move","x":10.5,"y":20}"#)
      == .success(.input(.move(CUPoint(x: 10.5, y: 20)))))
  #expect(
    parse(#"{"type":"pointer","kind":"down","x":1,"y":2,"button":"right"}"#)
      == .success(.input(.button(CUPoint(x: 1, y: 2), .right, down: true))))
  #expect(
    parse(#"{"type":"scroll","x":1,"y":2,"dx":0,"dy":-30}"#)
      == .success(.input(.scroll(CUPoint(x: 1, y: 2), dx: 0, dy: -30))))
  #expect(
    parse(#"{"type":"key","kind":"down","code":"KeyA"}"#)
      == .success(.input(.key(keyCode: 0, down: true))))
  #expect(
    parse(#"{"type":"key","kind":"up","code":"MetaRight"}"#)
      == .success(.input(.key(keyCode: 55, down: false))))
  #expect(parse(#"{"type":"text","text":"echo hi\n"}"#) == .success(.text("echo hi\n")))
  #expect(parse(#"{"type":"control","action":"take"}"#) == .success(.take))
  #expect(parse(#"{"type":"control","action":"release"}"#) == .success(.release))

  #expect(parse(#"{"type":"exec","cmd":"id"}"#) == .failure(.unknownType))
  #expect(parse(#"{"type":"pointer","kind":"move","x":1,"y":1,"z":0}"#) == .failure(.unknownField))
  #expect(
    parse(#"{"type":"pointer","kind":"move","x":1,"y":1,"button":"left"}"#)
      == .failure(.unknownField))
  #expect(parse(#"{"type":"pointer","kind":"move","x":1920,"y":1}"#) == .failure(.outOfRange))
  #expect(parse(#"{"type":"pointer","kind":"move","x":-1,"y":1}"#) == .failure(.outOfRange))
  #expect(
    parse(#"{"type":"pointer","kind":"down","x":1,"y":1,"button":"fourth"}"#)
      == .failure(.malformed))
  #expect(parse(#"{"type":"scroll","x":1,"y":1,"dx":0,"dy":10001}"#) == .failure(.outOfRange))
  #expect(parse(#"{"type":"scroll","x":1,"y":1,"dx":0,"dy":0}"#) == .failure(.outOfRange))
  #expect(parse(#"{"type":"key","kind":"down","code":"Power"}"#) == .failure(.unknownKey))
  #expect(parse(#"{"type":"text","text":"é"}"#) == .failure(.outOfRange))
  #expect(parse(#"{"type":"text","text":""}"#) == .failure(.outOfRange))
  #expect(parse(#"{"type":"control","action":"steal"}"#) == .failure(.malformed))
  #expect(parse("[]") == .failure(.notJSON))
  #expect(parse(String(repeating: " ", count: LiveView.maxMessage + 1)) == .failure(.tooLong))
}

@Test func theKeyTableMapsPhysicalKeysToMacKeyCodes() {
  #expect(LiveViewKeys.macKeyCode("KeyQ") == 12)
  #expect(LiveViewKeys.macKeyCode("Enter") == 36)
  #expect(LiveViewKeys.macKeyCode("ArrowUp") == 126)
  #expect(LiveViewKeys.macKeyCode("ShiftRight") == CUModifier.shift.keyCode)
  #expect(LiveViewKeys.macKeyCode("keya") == nil)
  #expect(LiveViewKeys.table.values.allSatisfy { (0...127).contains($0) })
}

// MARK: held input and takeover

@Test func heldInputIsReleasedKeysThenModifiersThenButtons() {
  var held = LiveViewHeld()
  let command = held.apply(.key(keyCode: CUModifier.command.keyCode, down: true))
  let a = held.apply(.key(keyCode: 0, down: true))
  let again = held.apply(.key(keyCode: 0, down: true))
  let button = held.apply(.button(CUPoint(x: 5, y: 6), .left, down: true))
  #expect(command && a && !again && button)
  #expect(held.flags & CUModifier.command.flag != 0)
  let releases = held.releaseAll()
  #expect(
    releases == [
      .key(keyCode: 0, down: false), .key(keyCode: CUModifier.command.keyCode, down: false),
      .button(CUPoint(x: 5, y: 6), .left, down: false),
    ])
  #expect(held.isEmpty)
  let none = held.releaseAll()
  let unheld = held.apply(.key(keyCode: 0, down: false))
  #expect(none.isEmpty && !unheld)
}

@Test func aViewerStartsViewOnlyAndInputFromAnotherIsDropped() {
  var c = LiveViewControl()
  let before = c.admit(1, at: t0)
  let took = c.take(1, at: t0)
  let mine = c.admit(1, at: t0)
  let other = c.admit(2, at: t0)
  let steal = c.take(2, at: t0.addingTimeInterval(10))
  let released = c.release(1)
  let next = c.take(2, at: t0.addingTimeInterval(10))
  #expect(before == .viewOnly && took == .taken && mine == .accepted)
  #expect(other == .viewOnly && steal == .otherViewerControls)
  #expect(released && next == .taken)
}

@Test func eachInputExtendsControlAndItLapsesSixtySecondsAfterTheLast() {
  var c = LiveViewControl()
  _ = c.take(1, at: t0)
  let at50 = c.admit(1, at: t0.addingTimeInterval(50))
  let at100 = c.admit(1, at: t0.addingTimeInterval(100))
  let notYet = c.lapse(at: t0.addingTimeInterval(159))
  let late = c.admit(1, at: t0.addingTimeInterval(161))
  #expect(at50 == .accepted && at100 == .accepted && notYet == nil && late == .expired)
  #expect(c.controller == nil)
  var d = LiveViewControl()
  _ = d.take(1, at: t0)
  let lapsed = d.lapse(at: t0.addingTimeInterval(61))
  let after = d.admit(1, at: t0.addingTimeInterval(62))
  #expect(lapsed == 1 && after == .viewOnly)
  // A lapsed controller does not keep another viewer out.
  var e = LiveViewControl()
  _ = e.take(1, at: t0)
  let second = e.take(2, at: t0.addingTimeInterval(61))
  #expect(second == .taken)
}

@Test func aDisconnectReleasesTheControllersHeldInputOnly() {
  var c = LiveViewControl()
  var held = LiveViewHeld()
  _ = held.apply(.key(keyCode: 0, down: true))
  let viewOnly = c.disconnect(1, held: &held)
  #expect(viewOnly.isEmpty && !held.isEmpty)
  _ = c.take(1, at: t0)
  let controlling = c.disconnect(1, held: &held)
  #expect(controlling == [.key(keyCode: 0, down: false)])
  #expect(held.isEmpty && c.controller == nil)
}

// MARK: encoder output

@Test func lengthPrefixedUnitsBecomeAnnexBWithParameterSetsFirst() {
  let avcc: [UInt8] = [0, 0, 0, 2, 0x65, 0xAA, 0, 0, 0, 1, 0x41]
  #expect(
    LiveViewEncoder.annexB(avcc: avcc, lengthSize: 4, parameterSets: [[0x67, 1], [0x68, 2]])
      == [0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x68, 2, 0, 0, 0, 1, 0x65, 0xAA, 0, 0, 0, 1, 0x41])
  #expect(LiveViewEncoder.annexB(avcc: [0, 0, 0, 9, 1], lengthSize: 4, parameterSets: []) == nil)
  #expect(LiveViewEncoder.annexB(avcc: [0, 0, 0, 0], lengthSize: 4, parameterSets: []) == nil)
  #expect(
    LiveViewEncoder.annexB(avcc: [0, 2, 7, 8], lengthSize: 2, parameterSets: []) == [
      0, 0, 0, 1, 7, 8,
    ])
  #expect(LiveViewEncoder.annexB(avcc: [], lengthSize: 5, parameterSets: []) == nil)
}

// MARK: listener

private final class FakeHost: LiveViewHost, @unchecked Sendable {
  private let lock = NSLock()
  private var log: [String] = []
  func joined(_ viewer: Int) { lock.withLock { log.append("joined \(viewer)") } }
  func message(_ viewer: Int, _ message: LiveViewMessage) -> String? {
    lock.withLock { log.append("message \(viewer) \(message)") }
    return #"{"type":"state"}"#
  }
  func left(_ viewer: Int) { lock.withLock { log.append("left \(viewer)") } }
  func needKeyframe() {}
  var events: [String] { lock.withLock { log } }
}

private func connect(_ port: UInt16) throws -> Int32 {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = port.bigEndian
  addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard rc == 0 else {
    close(fd)
    throw SandboxError("connect failed")
  }
  var timeout = timeval(tv_sec: 3, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  return fd
}

private func send(_ fd: Int32, _ bytes: [UInt8]) {
  _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

/// Everything the server sends until it closes or goes quiet.
private func receive(_ fd: Int32, until done: ([UInt8]) -> Bool = { _ in false }) -> [UInt8] {
  var out: [UInt8] = []
  var chunk = [UInt8](repeating: 0, count: 65536)
  while !done(out) {
    let n = read(fd, &chunk, chunk.count)
    guard n > 0 else { break }
    out += chunk[..<n]
  }
  return out
}

private func handshake(_ port: UInt16, host: String? = nil, origin: String? = nil) -> String {
  let h = host ?? "127.0.0.1:\(port)"
  let o = origin ?? "http://127.0.0.1:\(port)"
  return
    "GET /ws HTTP/1.1\r\nHost: \(h)\r\nOrigin: \(o)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
}

@Test func theListenerServesThePageAndAdmitsOnlyAnAuthenticatedSameOriginViewer() throws {
  let host = FakeHost()
  let token = try LiveViewToken.random()
  let server = try LiveViewServer(token: token, host: host, log: { _ in })
  server.start()
  defer { server.stop() }
  #expect(server.url == "http://127.0.0.1:\(server.port)/#\(token.value)")

  let page = try connect(server.port)
  send(page, Array("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n".utf8))
  let html = String(decoding: receive(page), as: UTF8.self)
  close(page)
  #expect(html.hasPrefix("HTTP/1.1 200"))
  #expect(html.contains("Content-Security-Policy: default-src 'self'"))
  #expect(html.contains("X-Frame-Options: DENY") && html.contains("Cache-Control: no-store"))
  #expect(!html.contains(token.value))

  // Another origin is refused before any token is read.
  let cross = try connect(server.port)
  send(cross, Array(handshake(server.port, origin: "http://evil.example").utf8))
  #expect(String(decoding: receive(cross), as: UTF8.self).hasPrefix("HTTP/1.1 403"))
  close(cross)
  let rebound = try connect(server.port)
  send(rebound, Array(handshake(server.port, host: "evil.example:\(server.port)").utf8))
  #expect(String(decoding: receive(rebound), as: UTF8.self).hasPrefix("HTTP/1.1 421"))
  close(rebound)

  // A wrong token closes the socket without joining.
  let wrong = try connect(server.port)
  send(wrong, Array(handshake(server.port).utf8))
  _ = receive(wrong) { String(decoding: $0, as: UTF8.self).contains("\r\n\r\n") }
  send(wrong, masked(0x1, Array(#"{"type":"auth","token":"nope"}"#.utf8)))
  #expect(receive(wrong).isEmpty)
  close(wrong)
  #expect(host.events.isEmpty)

  // The right token joins; messages reach the host; closing leaves.
  let good = try connect(server.port)
  send(good, Array(handshake(server.port).utf8))
  let reply = String(
    decoding: receive(good) { String(decoding: $0, as: UTF8.self).contains("\r\n\r\n") },
    as: UTF8.self)
  #expect(reply.hasPrefix("HTTP/1.1 101") && reply.contains("s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
  send(good, masked(0x1, Array(#"{"type":"auth","token":"\#(token.value)"}"#.utf8)))
  send(good, masked(0x1, Array(#"{"type":"control","action":"take"}"#.utf8)))
  let state = receive(good) { $0.count >= 2 + 16 }
  #expect(String(decoding: state.dropFirst(2), as: UTF8.self) == #"{"type":"state"}"#)
  #expect(server.viewerCount == 1)
  send(good, masked(0x8, []))
  _ = receive(good)
  close(good)
  for _ in 0..<50 where !host.events.contains("left 1") { usleep(20_000) }
  #expect(host.events == ["joined 1", "message 1 take", "left 1"])
}

@Test func aViewerThatNeverAuthenticatesIsDroppedAfterTheDeadline() throws {
  let host = FakeHost()
  let server = try LiveViewServer(token: try .random(), host: host, log: { _ in })
  server.start()
  defer { server.stop() }
  let fd = try connect(server.port)
  var timeout = timeval(tv_sec: Int(LiveView.tokenDeadline) + 3, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  send(fd, Array(handshake(server.port).utf8))
  let start = Date()
  _ = receive(fd)
  close(fd)
  #expect(Date().timeIntervalSince(start) < LiveView.tokenDeadline + 2)
  #expect(host.events.isEmpty)
}

@Test func connectionsAreCappedBeforeAnyByteIsRead() throws {
  let host = FakeHost()
  let server = try LiveViewServer(token: try .random(), host: host, log: { _ in })
  server.start()
  defer { server.stop() }
  // Idle connections, each holding a slot until the token deadline.
  let idle = try (0..<LiveView.maxConnections).map { _ in try connect(server.port) }
  defer { for fd in idle { close(fd) } }
  // The accept thread takes them in order: wait for the last to be served.
  let page = Array("GET / HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n\r\n".utf8)
  var refused = false
  for _ in 0..<50 where !refused {
    let extra = try connect(server.port)
    send(extra, page)
    refused = receive(extra).isEmpty
    close(extra)
    if !refused { usleep(20_000) }
  }
  // Past the limit a connection is closed unanswered, well inside the 5 s
  // an unauthenticated one may otherwise sit for.
  #expect(refused)
  // A freed slot serves again.
  close(idle[0])
  var served = false
  for _ in 0..<100 where !served {
    let again = try connect(server.port)
    send(again, page)
    served = String(decoding: receive(again), as: UTF8.self).hasPrefix("HTTP/1.1 200")
    close(again)
    if !served { usleep(20_000) }
  }
  #expect(served)
  #expect(host.events.isEmpty)
}

@Test func releasesAreNeverDroppedForTheMessagesBeforeThem() {
  typealias Parsed = Result<LiveViewMessage, LiveViewMessage.ParseError>
  let p = CUPoint(x: 1, y: 1)
  let move = Parsed.success(.input(.move(p)))
  let full = Array(repeating: true, count: LiveView.messageRate)
  var limits = LiveViewLimits(now: t0)
  // A burst of moves uses the message budget up, and is then dropped, with
  // everything else that presses, takes or does not parse.
  let moves = (0...LiveView.messageRate).map { _ in limits.admit(move, at: t0) }
  #expect(moves == full + [false])
  let others: [Parsed] = [
    .success(.input(.key(keyCode: 0, down: true))), .success(.take), .failure(.malformed),
  ]
  #expect(others.map { limits.admit($0, at: t0) } == [false, false, false])
  // What lets go of input still goes through.
  let releases: [LiveViewMessage] = [
    .input(.key(keyCode: 0, down: false)), .input(.button(p, .left, down: false)), .release,
  ]
  #expect(releases.allSatisfy(LiveViewLimits.isRelease))
  #expect(releases.map { limits.admit(.success($0), at: t0) } == [true, true, true])
  let notReleases: [LiveViewMessage] = [
    .take, .auth("t"), .input(.move(p)), .input(.key(keyCode: 0, down: true)),
    .input(.button(p, .left, down: true)), .input(.scroll(p, dx: 0, dy: 1)), .text("a"),
  ]
  #expect(!notReleases.contains(where: LiveViewLimits.isRelease))
  // Releases are bounded too, at the same rate, apart from the rest.
  var flood = LiveViewLimits(now: t0)
  let ups = (0...LiveView.messageRate).map { _ in flood.admit(.success(.release), at: t0) }
  #expect(ups == full + [false])
  let after = [
    flood.admit(move, at: t0), flood.admit(.success(.release), at: t0.addingTimeInterval(1)),
  ]
  #expect(after == [true, true])
}

private let hasHardwareEncoder = (try? LiveViewEncoder(width: 64, height: 64) { _, _, _ in }) != nil

private final class Chunks: @unchecked Sendable {
  private let lock = NSLock()
  private var all: [([UInt8], Bool)] = []
  func add(_ bytes: [UInt8], _ key: Bool) { lock.withLock { all.append((bytes, key)) } }
  var value: [([UInt8], Bool)] { lock.withLock { all } }
}

/// Virtual CI hosts have no hardware encoder; the owner refuses a stream there.
@Test(.enabled(if: hasHardwareEncoder))
func theHardwareEncoderEmitsAnAnnexBKeyframeWithParameterSets() throws {
  let chunks = Chunks()
  let encoder = try LiveViewEncoder(width: 1920, height: 1200) { bytes, key, _ in
    chunks.add(bytes, key)
  }
  var px = [UInt8](repeating: 0, count: 1920 * 1200 * 4)
  for i in stride(from: 0, to: px.count, by: 4) { px[i] = UInt8(truncatingIfNeeded: i / 4) }
  try px.withUnsafeBytes {
    try encoder.encode(rgbx: $0.baseAddress!, bytesPerRow: 1920 * 4, keyframe: true)
  }
  encoder.invalidate()
  let first = try #require(chunks.value.first)
  #expect(first.1)
  #expect(Array(first.0.prefix(4)) == [0, 0, 0, 1])
  // The first unit is the SPS (type 7).
  #expect(first.0.count > 5 && first.0[4] & 0x1F == 7)
}

@Test func aStoppedStreamListensNoLonger() throws {
  let server = try LiveViewServer(token: try .random(), host: FakeHost(), log: { _ in })
  server.start()
  let before = try connect(server.port)
  close(before)
  server.stop()
  var refused = false
  for _ in 0..<20 where !refused {
    usleep(100_000)
    if let fd = try? connect(server.port) { close(fd) } else { refused = true }
  }
  #expect(refused)
}

// MARK: SPS

private func hex(_ s: String) -> [UInt8] {
  stride(from: 0, to: s.count, by: 2).map {
    let i = s.index(s.startIndex, offsetBy: $0)
    return UInt8(s[i..<s.index(i, offsetBy: 2)], radix: 16)!
  }
}

@Test func theEncodersSPSGainsALowDelayVUIAndKeepsEverythingElse() throws {
  // VideoToolbox's SPS on a macOS 27 host: Constrained Baseline, level 5.0,
  // 120×75 macroblocks, one reference frame, no VUI.
  let sps = hex("2742c032ab403c012f20")
  let out = LiveViewSPS.withLowDelay(sps)
  #expect(out != sps)
  #expect(Array(out.prefix(4)) == Array(sps.prefix(4)))
  var r = LiveViewSPS.BitReader(LiveViewSPS.unescape(Array(out.dropFirst())))
  _ = r.bits(24)
  #expect(r.ue() == 0)  // seq_parameter_set_id
  #expect(r.ue() == 1)  // log2_max_frame_num_minus4
  #expect(r.ue() == 0)  // pic_order_cnt_type
  #expect(r.ue() == 2)  // log2_max_pic_order_cnt_lsb_minus4
  #expect(r.ue() == 1)  // max_num_ref_frames
  #expect(r.bits(1) == 0)
  #expect(r.ue() == 119 && r.ue() == 74)  // 120×75 macroblocks
  // frame_mbs_only, direct_8x8, cropping
  #expect(r.bits(1) == 1 && r.bits(1) == 1 && r.bits(1) == 0)
  #expect(r.bits(1) == 1)  // vui_parameters_present_flag
  #expect(r.bits(8) == 0)  // no aspect, overscan, signal, chroma, timing, HRD, pic_struct
  #expect(r.bits(1) == 1 && r.bits(1) == 1)  // bitstream_restriction, mv over boundaries
  #expect(r.ue() == 2 && r.ue() == 1 && r.ue() == 16 && r.ue() == 16)
  #expect(r.ue() == 0)  // max_num_reorder_frames
  #expect(r.ue() == 1)  // max_dec_frame_buffering
  #expect(r.bits(1) == 1)  // rbsp_stop_one_bit
  // Idempotent: an SPS with VUI is left alone, as is anything else.
  #expect(LiveViewSPS.withLowDelay(out) == out)
  #expect(LiveViewSPS.withLowDelay([0x68, 0xCE, 0x3C, 0x80]) == [0x68, 0xCE, 0x3C, 0x80])
  #expect(LiveViewSPS.withLowDelay([0x27, 0x42]) == [0x27, 0x42])
}

@Test func emulationPreventionRoundTrips() {
  let raw: [UInt8] = [0, 0, 1, 5, 0, 0, 0, 0, 3, 0, 0, 2, 9]
  let escaped = LiveViewSPS.escape(raw)
  #expect(escaped == [0, 0, 3, 1, 5, 0, 0, 3, 0, 0, 3, 3, 0, 0, 3, 2, 9])
  #expect(LiveViewSPS.unescape(escaped) == raw)
}
