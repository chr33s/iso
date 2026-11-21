import Testing

@testable import IsoEgressCore

private func push(_ ring: inout RelayRing, _ bytes: [UInt8]) -> Int {
  ring.receive(upTo: bytes.count) { region in
    let n = min(region.count, bytes.count)
    region.copyBytes(from: bytes[0..<n])
    return n
  }
}

private func pop(_ ring: inout RelayRing, max: Int) -> [UInt8] {
  var out: [UInt8] = []
  _ = ring.send { region in
    let n = min(region.count, max)
    out = Array(region[0..<n])
    return n
  }
  return out
}

/// Bytes leave in arrival order across wrap-around and growth, partial
/// sends keep the rest in place, and an emptied ring reuses its storage.
@Test func relayRingKeepsOrderAcrossWrapGrowthAndPartialSends() {
  var ring = RelayRing()
  var expected: [UInt8] = []
  var received: [UInt8] = []
  var next: UInt8 = 0
  func bytes(_ n: Int) -> [UInt8] {
    (0..<n).map { _ in
      next &+= 1
      return next
    }
  }
  for round in 0..<400 {
    let incoming = bytes(1 + (round * 37) % 3000)
    var offset = 0
    while offset < incoming.count {
      let n = push(&ring, Array(incoming[offset...]))
      guard n > 0 else {
        Issue.record("ring refused room it should have")
        return
      }
      offset += n
    }
    expected += incoming
    // Drain unevenly so the start index wraps.
    while ring.count > (round % 7) * 500 {
      let out = pop(&ring, max: 1 + (round * 53) % 1700)
      guard !out.isEmpty else {
        Issue.record("ring held bytes it would not send")
        return
      }
      received += out
    }
  }
  while !ring.isEmpty { received += pop(&ring, max: 4096) }
  #expect(received == expected)
  #expect(pop(&ring, max: 10).isEmpty)
}

@Test func relayRingCountsOnlyWhatTheSocketMoved() {
  var ring = RelayRing()
  #expect(ring.receive(upTo: 64) { _ in -1 } == -1)
  #expect(ring.isEmpty)
  #expect(push(&ring, [1, 2, 3]) == 3)
  #expect(ring.send { _ in -1 } == -1)
  #expect(ring.count == 3)
  #expect(pop(&ring, max: 2) == [1, 2])
  #expect(pop(&ring, max: 2) == [3])
  #expect(ring.isEmpty)
}

/// A terminator split across reads is still found, and nothing after the
/// first one is taken into the head.
@Test func connectHeadTerminatorSpansReadsAndStopsAtTheFirst() {
  let head = Array("CONNECT a.b:443 HTTP/1.1\r\n\r".utf8)
  #expect(HeadTerminator.take(after: head, next: Array("\nTLS".utf8)[...]) == 1)
  #expect(HeadTerminator.take(after: Array("X\r\n".utf8), next: Array("\r\n\r\n".utf8)[...]) == 2)
  #expect(HeadTerminator.take(after: Array("X\r".utf8), next: Array("\r\n\r\nZ".utf8)[...]) == 4)
  #expect(HeadTerminator.take(after: [], next: Array("ab\r\n\rc".utf8)[...]) == 6)
}
