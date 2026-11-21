/// Bytes waiting in one tunnel direction, oldest first. Reads land directly
/// in free space and writes leave from the oldest byte, so draining never
/// shifts the bytes still held. Storage grows on demand, up to the caller's
/// queue cap, so an idle or fast tunnel holds little memory.
package struct RelayRing {
  private var storage: [UInt8] = []
  private var start = 0
  package private(set) var count = 0

  package init() {}

  package var isEmpty: Bool { count == 0 }

  /// Lends the largest contiguous free region, at most `limit` bytes, to
  /// `fill`, which returns how many bytes it wrote there or a negative
  /// failure. The ring first grows so it can hold `limit` more bytes.
  package mutating func receive(
    upTo limit: Int, _ fill: (UnsafeMutableRawBufferPointer) -> Int
  ) -> Int {
    guard limit > 0 else { return 0 }
    if storage.count - count < limit { grow(toHold: count + limit) }
    if count == 0 { start = 0 }
    let end = (start + count) % storage.count
    let room = end < start ? start - end : storage.count - end
    // The lent region lies inside storage, is free, and lives for this call.
    let wrote = storage.withUnsafeMutableBytes { raw in
      unsafe fill(UnsafeMutableRawBufferPointer(rebasing: raw[end..<(end + min(room, limit))]))
    }
    if wrote > 0 { count += wrote }
    return wrote
  }

  /// Lends the oldest contiguous bytes to `drain`, which returns how many it
  /// consumed or a negative failure. Consumed bytes leave the ring.
  package mutating func send(_ drain: (UnsafeRawBufferPointer) -> Int) -> Int {
    guard count > 0 else { return 0 }
    let length = min(count, storage.count - start)
    // The lent region holds the oldest bytes and lives for this call.
    let sent = storage.withUnsafeBytes { raw in
      unsafe drain(UnsafeRawBufferPointer(rebasing: raw[start..<(start + length)]))
    }
    if sent > 0 {
      start = (start + sent) % storage.count
      count -= sent
      if count == 0 { start = 0 }
    }
    return sent
  }

  /// Copies the held bytes, oldest first, into larger storage. Amortized:
  /// capacity at least doubles, and only while the queue is filling.
  private mutating func grow(toHold needed: Int) {
    let head = min(count, storage.count - start)
    var next = Array(storage[start..<(start + head)])
    next += storage[0..<(count - head)]
    next += repeatElement(0, count: max(needed, storage.count * 2, 4096) - count)
    storage = next
    start = 0
  }
}
