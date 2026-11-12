import Foundation
import IsoMacProtocol

/// Which parts of a display changed, and when
/// (docs/design/computer-use-screen-sync.md §3). Fed whole RGBX frames; each
/// sample is compared with the previous one tile by tile over every byte, so
/// a change is never missed. `seq` rises by one for each sample that changed
/// any tile, and each tile remembers the `seq` it last changed at. Pure, so
/// it is unit-testable with synthetic buffers.
package struct DamageGrid: Sendable {
  package static let tile = 16
  package let width: Int
  package let height: Int
  package let columns: Int
  package let rows: Int
  package private(set) var seq: UInt64 = 0
  /// Samples taken: the owner's cost, for tests and diagnostics.
  package private(set) var samples = 0
  private var tileSeq: [UInt64]
  /// The previous sample; empty until the first, which sets the baseline.
  private var previous: [UInt8] = []
  /// Scratch for one sample's dirty tiles, kept to avoid an allocation per sample.
  private var dirty: [Bool]

  package init(width: Int, height: Int) {
    self.width = width
    self.height = height
    columns = (width + Self.tile - 1) / Self.tile
    rows = (height + Self.tile - 1) / Self.tile
    tileSeq = Array(repeating: 0, count: columns * rows)
    dirty = Array(repeating: false, count: columns * rows)
  }

  package var byteCount: Int { width * height * 4 }

  /// Compares `pixels` (RGBX, rows packed) with the previous sample and
  /// keeps it as the new one. Returns `seq` afterwards.
  @discardableResult
  package mutating func sample(_ pixels: UnsafeRawBufferPointer) throws -> UInt64 {
    guard pixels.count == byteCount, let new = pixels.baseAddress else {
      throw SandboxError("damage sample of \(pixels.count) bytes, expected \(byteCount)")
    }
    samples += 1
    guard previous.count == byteCount else {
      previous = Array(pixels)
      return seq
    }
    let rowBytes = width * 4
    let tileBytes = Self.tile * 4
    var any = false
    for i in dirty.indices { dirty[i] = false }
    previous.withUnsafeBytes { oldBuffer in
      let old = oldBuffer.baseAddress!
      for y in 0..<height {
        let row = y * rowBytes
        // Most rows of a mostly static screen are identical.
        guard memcmp(new + row, old + row, rowBytes) != 0 else { continue }
        let base = (y / Self.tile) * columns
        for tx in 0..<columns where !dirty[base + tx] {
          let start = row + tx * tileBytes
          let length = min(tileBytes, rowBytes - tx * tileBytes)
          if memcmp(new + start, old + start, length) != 0 {
            dirty[base + tx] = true
            any = true
          }
        }
      }
    }
    if any {
      seq += 1
      for i in dirty.indices where dirty[i] { tileSeq[i] = seq }
    }
    previous.withUnsafeMutableBytes { $0.copyMemory(from: pixels) }
    return seq
  }

  /// The latest `seq` at which a tile overlapping `region` changed; the
  /// whole screen when nil. `region` is validated by the caller.
  package func latest(in region: GuestCURegion?) -> UInt64 {
    guard let r = region else { return seq }
    let x0 = max(0, r.x) / Self.tile
    let y0 = max(0, r.y) / Self.tile
    let x1 = min(columns - 1, (r.x + r.width - 1) / Self.tile)
    let y1 = min(rows - 1, (r.y + r.height - 1) / Self.tile)
    guard x0 <= x1, y0 <= y1 else { return 0 }
    var m: UInt64 = 0
    for ty in y0...y1 {
      for tx in x0...x1 { m = max(m, tileSeq[ty * columns + tx]) }
    }
    return m
  }
}
