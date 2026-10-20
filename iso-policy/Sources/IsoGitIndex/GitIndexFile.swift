import CryptoKit

/// A Git index file (`.git/index`) read as inert data: no Git process, no
/// repository configuration, hooks, filters, helpers or fsmonitor. Shared by
/// the host's outbound snapshots and iso-ci's capture, so both refuse the
/// same forms. A form it cannot read safely is refused, never guessed.
public enum GitIndexFile {
  public static let maxEntries = 1_000_000

  /// One stage-0 entry: a regular file or a symlink.
  public struct Entry: Sendable, Equatable {
    public let path: String
    public let mode: UInt32
    /// The low 32 bits of the size Git recorded.
    public let size: UInt32
    public let mtimeSeconds: UInt32
    public let mtimeNanos: UInt32
  }

  public enum Refusal: Error, Sendable, Equatable, CustomStringConvertible {
    case notAnIndex
    /// The SHA-1 trailer does not verify; SHA-256 repositories land here.
    case checksumMismatch
    case unsupportedVersion(UInt32)
    case tooManyEntries
    case truncated
    case unmerged
    case extendedFlagsInVersion2
    case skipWorktree
    case badPathPrefix
    case submodule
    case sparseIndex
    case unknownEntryType
    case nonUTF8Path

    public var description: String {
      switch self {
      case .notAnIndex: "not an index file"
      case .checksumMismatch: "checksum mismatch or a non-SHA-1 repository"
      case .unsupportedVersion(let version): "version \(version)"
      case .tooManyEntries: "too many entries"
      case .truncated: "truncated"
      case .unmerged: "unmerged entries"
      case .extendedFlagsInVersion2: "extended flags in version 2"
      case .skipWorktree: "skip-worktree (sparse) entries"
      case .badPathPrefix: "bad path prefix"
      case .submodule: "submodules"
      case .sparseIndex: "a sparse index"
      case .unknownEntryType: "an unknown entry type"
      case .nonUTF8Path: "a non-UTF-8 path"
      }
    }
  }

  /// Stage-0 entries of a version 2–4 SHA-1 index whose trailer verifies,
  /// in index order.
  public static func parse(_ bytes: [UInt8]) throws(Refusal) -> [Entry] {
    guard bytes.count >= 32, Array(bytes[0..<4]) == Array("DIRC".utf8) else {
      throw .notAnIndex
    }
    let body = bytes[0..<(bytes.count - 20)]
    guard Array(Insecure.SHA1.hash(data: body)) == Array(bytes[(bytes.count - 20)...]) else {
      throw .checksumMismatch
    }
    func u32(_ at: Int) throws(Refusal) -> UInt32 {
      guard at + 4 <= body.count else { throw .truncated }
      return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8
        | UInt32(bytes[at + 3])
    }
    func u16(_ at: Int) throws(Refusal) -> Int {
      guard at + 2 <= body.count else { throw .truncated }
      return Int(bytes[at]) << 8 | Int(bytes[at + 1])
    }
    let version = try u32(4)
    guard [2, 3, 4].contains(version) else { throw .unsupportedVersion(version) }
    let count = Int(try u32(8))
    guard count <= maxEntries else { throw .tooManyEntries }
    var offset = 12
    var previous: [UInt8] = []
    var entries: [Entry] = []
    for _ in 0..<count {
      let start = offset
      let mtimeSeconds = try u32(start + 8)
      let mtimeNanos = try u32(start + 12)
      let mode = try u32(start + 24)
      let size = try u32(start + 36)
      offset = start + 62
      let flags = try u16(offset - 2)
      guard (flags >> 12) & 0x3 == 0 else { throw .unmerged }
      if flags & 0x4000 != 0 {
        guard version >= 3 else { throw .extendedFlagsInVersion2 }
        let extended = try u16(offset)
        offset += 2
        guard extended & 0x4000 == 0 else { throw .skipWorktree }
      }
      var name: [UInt8]
      if version == 4 {
        // Git's offset varint: big-endian 7-bit groups, each continuation
        // adding one (`decode_varint`).
        var strip = 0
        var byte: UInt8
        var first = true
        repeat {
          guard offset < body.count, strip < 1 << 24 else { throw .badPathPrefix }
          byte = bytes[offset]
          offset += 1
          strip = (first ? 0 : (strip + 1) << 7) + Int(byte & 0x7F)
          first = false
        } while byte & 0x80 != 0
        guard strip <= previous.count else { throw .badPathPrefix }
        name = Array(previous.prefix(previous.count - strip))
        guard let end = body[offset...].firstIndex(of: 0) else { throw .truncated }
        name += bytes[offset..<end]
        offset = end + 1
      } else {
        guard let end = body[offset...].firstIndex(of: 0) else { throw .truncated }
        name = Array(bytes[offset..<end])
        offset = start + ((end - start + 1 + 7) / 8) * 8
      }
      previous = name
      switch mode & 0o170000 {
      case 0o100000, 0o120000: break
      case 0o160000: throw .submodule
      case 0o040000: throw .sparseIndex
      default: throw .unknownEntryType
      }
      guard let path = String(validating: name, as: UTF8.self) else { throw .nonUTF8Path }
      entries.append(
        Entry(
          path: path, mode: mode, size: size, mtimeSeconds: mtimeSeconds, mtimeNanos: mtimeNanos))
    }
    return entries
  }
}
