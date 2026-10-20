import CryptoKit
import IsoGitIndex
import Testing

/// Index bytes built to Git's on-disk format (gitformat-index), so the
/// reader is checked without running Git.
private struct IndexBuilder {
  struct Item {
    var path: String
    var mode: UInt32 = 0o100644
    var size: UInt32 = 1
    var stage: Int = 0
    var skipWorktree = false
  }

  var version: UInt32
  var items: [Item]

  static func u32(_ value: UInt32) -> [UInt8] {
    [
      UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
  }

  static func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }

  /// Git's `encode_varint`: big-endian 7-bit groups, one subtracted per
  /// continuation.
  static func varint(_ value: Int) -> [UInt8] {
    var value = value
    var out = [UInt8(value & 0x7F)]
    value >>= 7
    while value > 0 {
      value -= 1
      out.insert(UInt8(0x80 | (value & 0x7F)), at: 0)
      value >>= 7
    }
    return out
  }

  func bytes() -> [UInt8] {
    var out = Array("DIRC".utf8) + Self.u32(version) + Self.u32(UInt32(items.count))
    var previous: [UInt8] = []
    for item in items {
      let name = Array(item.path.utf8)
      var entry = [UInt8](repeating: 0, count: 8)  // ctime
      entry += Self.u32(1_700_000_000) + Self.u32(7)  // mtime
      entry += Self.u32(1) + Self.u32(2)  // dev, ino
      entry += Self.u32(item.mode) + Self.u32(501) + Self.u32(20) + Self.u32(item.size)
      entry += [UInt8](repeating: 0xAB, count: 20)  // object id
      var flags = min(name.count, 0xFFF) | (item.stage << 12)
      if item.skipWorktree { flags |= 0x4000 }
      entry += Self.u16(flags)
      if item.skipWorktree { entry += Self.u16(0x4000) }
      if version == 4 {
        let common = zip(previous, name).prefix { $0 == $1 }.count
        entry += Self.varint(previous.count - common) + name[common...] + [0]
      } else {
        entry += name
        let padded = ((entry.count + 1 + 7) / 8) * 8
        entry += [UInt8](repeating: 0, count: padded - entry.count)
      }
      previous = name
      out += entry
    }
    return out + Array(Insecure.SHA1.hash(data: out))
  }
}

@Test(arguments: [UInt32(2), 3, 4]) func entriesRoundTripInIndexOrder(version: UInt32) throws {
  // `long/…` then `z.txt`: a version 4 prefix strip of 128 bytes or more
  // needs a multi-byte varint.
  let long = "long/" + String(repeating: "p", count: 200) + "/x.txt"
  let paths = ["a.txt", "dir/b.txt", "dir/c.txt", long, "z.txt"]
  let builder = IndexBuilder(
    version: version,
    items: paths.map { .init(path: $0) } + [.init(path: "zz-link", mode: 0o120000)])
  let entries = try GitIndexFile.parse(builder.bytes())
  #expect(entries.map(\.path) == paths + ["zz-link"])
  #expect(entries.last?.mode == 0o120000)
  #expect(entries.first?.mtimeSeconds == 1_700_000_000 && entries.first?.mtimeNanos == 7)
}

@Test func varintMatchesGitsEncodingAtTheBoundaries() {
  #expect(IndexBuilder.varint(127) == [0x7F])
  #expect(IndexBuilder.varint(128) == [0x80, 0x00])
  #expect(IndexBuilder.varint(16_511) == [0xFF, 0x7F])
}

@Test func unreadableFormsAreRefusedNotGuessed() {
  func refusal(_ bytes: [UInt8]) -> GitIndexFile.Refusal? {
    do {
      _ = try GitIndexFile.parse(bytes)
      return nil
    } catch { return error }
  }
  var good = IndexBuilder(version: 2, items: [.init(path: "a")]).bytes()
  #expect(refusal([]) == .notAnIndex)
  good[good.count - 1] ^= 0xFF
  #expect(refusal(good) == .checksumMismatch)
  #expect(refusal(IndexBuilder(version: 5, items: []).bytes()) == .unsupportedVersion(5))
  #expect(
    refusal(IndexBuilder(version: 2, items: [.init(path: "a", stage: 2)]).bytes()) == .unmerged)
  #expect(
    refusal(IndexBuilder(version: 3, items: [.init(path: "a", skipWorktree: true)]).bytes())
      == .skipWorktree)
  #expect(
    refusal(IndexBuilder(version: 2, items: [.init(path: "a", skipWorktree: true)]).bytes())
      == .extendedFlagsInVersion2)
  #expect(
    refusal(IndexBuilder(version: 2, items: [.init(path: "m", mode: 0o160000)]).bytes())
      == .submodule)
  #expect(
    refusal(IndexBuilder(version: 2, items: [.init(path: "d", mode: 0o040000)]).bytes())
      == .sparseIndex)
  // A count larger than the entries present runs off the end.
  var short = Array(IndexBuilder(version: 2, items: [.init(path: "a")]).bytes().dropLast(20))
  short[11] = 2
  #expect(refusal(short + Array(Insecure.SHA1.hash(data: short))) == .truncated)
}
