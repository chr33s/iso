import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import IsoSandboxCore

private func request(_ kind: String, _ build: (inout CUActionRequest) -> Void = { _ in })
  -> CUActionRequest
{
  var r = CUActionRequest(kind: kind)
  build(&r)
  return r
}

@Test func coordinatesOutsideTheFramebufferAreRefusedNotClamped() throws {
  let w = 1920
  let h = 1200
  #expect(throws: Never.self) {
    try request("move") {
      $0.x = 0
      $0.y = 0
    }.validated(width: w, height: h)
  }
  #expect(throws: Never.self) {
    try request("move") {
      $0.x = 1919.9
      $0.y = 1199.9
    }.validated(width: w, height: h)
  }
  for (x, y) in [
    (1920.0, 0.0), (0.0, 1200.0), (-0.1, 5.0), (Double.nan, 1.0), (Double.infinity, 1.0),
  ] {
    #expect(throws: SandboxError.self) {
      try request("click") {
        $0.x = x
        $0.y = y
      }.validated(width: w, height: h)
    }
  }
  #expect(throws: SandboxError.self) { try request("click").validated(width: w, height: h) }
}

@Test func actionBoundsAreEnforced() throws {
  let v = { (r: CUActionRequest) in try r.validated(width: 100, height: 100) }
  #expect(throws: SandboxError.self) {
    try v(
      request("click") {
        $0.x = 1
        $0.y = 1
        $0.count = 4
      })
  }
  #expect(throws: SandboxError.self) { try v(request("drag") { $0.path = [CUPoint(x: 1, y: 1)] }) }
  #expect(throws: SandboxError.self) {
    try v(request("drag") { $0.path = Array(repeating: CUPoint(x: 1, y: 1), count: 1001) })
  }
  #expect(throws: SandboxError.self) {
    try v(request("drag") { $0.path = [CUPoint(x: 1, y: 1), CUPoint(x: 100, y: 1)] })
  }
  #expect(throws: SandboxError.self) {
    try v(
      request("scroll") {
        $0.x = 1
        $0.y = 1
      })
  }
  #expect(throws: SandboxError.self) { try v(request("key") { $0.keyCode = 128 }) }
  #expect(throws: SandboxError.self) { try v(request("key") { $0.keyCode = 55 }) }
  #expect(throws: SandboxError.self) {
    try v(
      request("key") {
        $0.keyCode = 1
        $0.modifiers = [.shift, .shift]
      })
  }
  #expect(throws: SandboxError.self) { try v(request("type") { $0.text = "café" }) }
  #expect(throws: SandboxError.self) {
    try v(request("type") { $0.text = String(repeating: "a", count: 4097) })
  }
  #expect(throws: SandboxError.self) { try v(request("exec")) }
  #expect(try v(request("type") { $0.text = "Hello, World!\n" }) == .type("Hello, World!\n"))
}

@Test func chordsPressInOrderReleaseInReverseAndCarryDeviceBits() {
  let events = CUKeys.chord(keyCode: 1, modifiers: [.command, .shift])
  #expect(events.map(\.kind) == [.flags, .flags, .down, .up, .flags, .flags])
  #expect(events.map(\.keyCode) == [55, 56, 1, 1, 56, 55])
  #expect(events[0].flags == (1 << 20) | 0x8 | 0x100)
  #expect(events[2].flags == (1 << 20) | (1 << 17) | 0x8 | 0x2 | 0x100)
  #expect(events.last?.flags == 0)
}

@Test func textMapsToUSKeysWithShiftWhereNeeded() {
  let events = CUKeys.events(forText: "aA!")
  let downs = events.filter { $0.kind == .down }
  #expect(downs.map(\.keyCode) == [0, 0, 18])
  #expect(downs.map(\.characters) == ["a", "A", "!"])
  #expect(downs[0].flags == 0)
  #expect(downs[1].flags & (1 << 17) != 0)
  #expect(events.last?.flags == 0)
}

@Test func anInterruptedSequenceIsFullyReleased() {
  let events = CUKeys.chord(keyCode: 12, modifiers: [.command, .option])
  let rel = CUKeys.releases(after: events.prefix(3))
  #expect(rel.map(\.kind) == [.up, .flags, .flags])
  #expect(rel.map(\.keyCode) == [12, 58, 55])
  #expect(rel.last?.flags == 0)
  #expect(CUKeys.releases(after: events[...]).isEmpty)
}

@Test func aSessionIsRefusedOnAnyChangeOfItsBinding() {
  let b = CUBinding(
    bootId: "o1", vmInstance: "v1", guestBoot: "g1", helperGeneration: 3, width: 1920, height: 1200)
  #expect(b.mismatch(b) == nil)
  #expect(b.mismatch(nil) == "guest helper not connected")
  var c = b
  c.bootId = "o2"
  #expect(b.mismatch(c) == "owner restarted")
  c = b
  c.vmInstance = "v2"
  #expect(b.mismatch(c) == "vm instance changed")
  c = b
  c.guestBoot = "g2"
  #expect(b.mismatch(c) == "guest boot changed")
  c = b
  c.helperGeneration = 4
  #expect(b.mismatch(c) == "guest boot changed")
  c = b
  c.width = 1280
  #expect(b.mismatch(c) == "geometry changed")
}

@Test func actReplyWaitCoversTheLongestTypedText() {
  #expect(MacSandboxes.replyTimeout(MacControlRequest(op: .cuFrame)) == 120)
  let longest = request("type") {
    $0.text = String(repeating: "A", count: CUActionRequest.maxText)
  }
  let wait = MacSandboxes.replyTimeout(MacControlRequest(op: .cuAct, action: longest))
  let typing = Double(CUActionRequest.maxText * 4) * 0.012
  #expect(wait >= typing + 60)
}

// MARK: frame encoding

@MainActor private final class GateLog {
  var order: [Int] = []
  var inside = 0
  var most = 0
}

/// Frames are encoded off the main actor, one at a time and in the order asked: the gate holds
/// later frames, so at most one captured image waits for its encode.
@MainActor @Test func theFrameGateAdmitsOneHolderAtATimeInTheOrderAsked() async {
  let gate = SerialGate()
  let log = GateLog()
  await gate.enter()
  var tasks: [Task<Void, Never>] = []
  for i in 0..<4 {
    tasks.append(
      Task { @MainActor in
        await gate.enter()
        log.inside += 1
        log.most = max(log.most, log.inside)
        log.order.append(i)
        await Task.yield()
        log.inside -= 1
        gate.leave()
      })
    for _ in 0..<100 where gate.queued < i + 1 { await Task.yield() }
  }
  #expect(log.order.isEmpty)
  gate.leave()
  for t in tasks { await t.value }
  #expect(log.order == [0, 1, 2, 3])
  #expect(log.most == 1)
  #expect(gate.queued == 0)
  // Free again: the next holder enters at once.
  await gate.enter()
  gate.leave()
}

@Test func framesAreEncodedAsPNGsOfTheirOwnSize() async throws {
  let ctx = try #require(
    CGContext(
      data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 64 * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
  ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 40))
  let png = try await VMScreen.png(try #require(ctx.makeImage()))
  let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
  #expect(CGImageSourceGetType(source) as String? == "public.png")
  let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  #expect(decoded.width == 64 && decoded.height == 40)
}
