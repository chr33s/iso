import CryptoKit
import Darwin
import Foundation

/// The working tree's Git index and HEAD, read as inert data (CI-01, the
/// iso INPUT-01 rule): no Git process, no repository configuration, hooks,
/// filters, helpers or fsmonitor. Forms it cannot read safely are refused.
package enum GitIndex {
  package struct Entry: Sendable, Equatable {
    package let path: String
    package let mode: UInt32
    package let size: UInt32
    package let mtimeSeconds: UInt32
    package let mtimeNanos: UInt32
  }

  package struct Layout: Sendable, Equatable {
    /// The working-tree root.
    package let root: String
    /// The repository's administrative directory (`.git` or a gitfile's).
    package let gitDirectory: String
    /// Shared refs for a linked worktree, else `gitDirectory`.
    package let commonDirectory: String
  }

  static let maxIndexBytes = 256 << 20
  static let maxEntries = 1_000_000

  /// The repository around `path`: the nearest ancestor with a `.git`
  /// directory or standard gitfile.
  package static func layout(containing path: String) throws(CIError) -> Layout {
    var directory = (path as NSString).standardizingPath
    while true {
      let dotGit = directory + "/.git"
      var info = stat()
      if lstat(dotGit, &info) == 0 {
        let gitDirectory: String
        switch info.st_mode & S_IFMT {
        case S_IFDIR: gitDirectory = dotGit
        case S_IFREG:
          guard let bytes = try? PrivateFiles.read(dotGit, limit: 4096),
            let text = String(validating: bytes, as: UTF8.self),
            text.hasPrefix("gitdir: ")
          else { throw CIError(.compatibilityRejected, "unsupported .git file in \(directory)") }
          let target = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .newlines)
          gitDirectory =
            (target.hasPrefix("/") ? target : directory + "/" + target) as String
        default:
          throw CIError(.compatibilityRejected, ".git in \(directory) is a link or special file")
        }
        var common = gitDirectory
        if let bytes = try? PrivateFiles.read(gitDirectory + "/commondir", limit: 4096),
          let text = String(validating: bytes, as: UTF8.self)
        {
          let relative = text.trimmingCharacters(in: .newlines)
          common = relative.hasPrefix("/") ? relative : gitDirectory + "/" + relative
        }
        return Layout(
          root: directory, gitDirectory: (gitDirectory as NSString).standardizingPath,
          commonDirectory: (common as NSString).standardizingPath)
      }
      guard directory != "/" && !directory.isEmpty else {
        throw CIError.invalid("not a git working tree")
      }
      directory = (directory as NSString).deletingLastPathComponent
    }
  }

  /// The commit HEAD names, from `HEAD`, loose refs and `packed-refs`.
  package static func head(_ layout: Layout) throws(CIError) -> String {
    guard let bytes = try? PrivateFiles.read(layout.gitDirectory + "/HEAD", limit: 4096),
      let text = String(validating: bytes, as: UTF8.self)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
    else { throw CIError.invalid("cannot read HEAD") }
    if isObjectID(text) { return text }
    guard text.hasPrefix("ref: refs/") else { throw CIError.invalid("unsupported HEAD") }
    let ref = String(text.dropFirst("ref: ".count))
    guard !ref.split(separator: "/").contains("..") else {
      throw CIError.invalid("unsupported HEAD")
    }
    for directory in [layout.gitDirectory, layout.commonDirectory] {
      if let loose = try? PrivateFiles.read(directory + "/" + ref, limit: 4096),
        let id = String(validating: loose, as: UTF8.self)?.trimmingCharacters(
          in: .whitespacesAndNewlines), isObjectID(id)
      {
        return id
      }
    }
    if let packed = try? PrivateFiles.read(
      layout.commonDirectory + "/packed-refs", limit: 64 << 20),
      let text = String(validating: packed, as: UTF8.self)
    {
      for line in text.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
        let parts = line.split(separator: " ", maxSplits: 1)
        if parts.count == 2, parts[1] == ref, isObjectID(String(parts[0])) {
          return String(parts[0])
        }
      }
    }
    throw CIError.invalid("HEAD has no commit yet")
  }

  static func isObjectID(_ text: String) -> Bool {
    text.utf8.count == 40
      && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  /// Stage-0 entries of a v2–v4 SHA-1 index whose trailer verifies.
  package static func entries(_ layout: Layout) throws(CIError) -> [Entry] {
    // Only an absent index means "nothing tracked"; an index that exists
    // but cannot be read fails the capture instead of looking clean.
    guard let bytes = try PrivateFiles.read(layout.gitDirectory + "/index", limit: maxIndexBytes)
    else { return [] }
    return try parse(bytes)
  }

  package static func parse(_ bytes: [UInt8]) throws(CIError) -> [Entry] {
    func unsupported(_ why: String) -> CIError {
      CIError(.compatibilityRejected, "the Git index cannot be read inertly (\(why))")
    }
    guard bytes.count >= 32, Array(bytes[0..<4]) == Array("DIRC".utf8) else {
      throw unsupported("not an index file")
    }
    let body = bytes[0..<(bytes.count - 20)]
    guard Array(Insecure.SHA1.hash(data: body)) == Array(bytes[(bytes.count - 20)...]) else {
      throw unsupported("checksum mismatch or a non-SHA-1 repository")
    }
    func u32(_ at: Int) throws(CIError) -> UInt32 {
      guard at + 4 <= body.count else { throw unsupported("truncated") }
      return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8
        | UInt32(bytes[at + 3])
    }
    func u16(_ at: Int) throws(CIError) -> Int {
      guard at + 2 <= body.count else { throw unsupported("truncated") }
      return Int(bytes[at]) << 8 | Int(bytes[at + 1])
    }
    let version = try u32(4)
    guard [2, 3, 4].contains(version) else { throw unsupported("version \(version)") }
    let count = Int(try u32(8))
    guard count <= maxEntries else { throw unsupported("too many entries") }
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
      guard (flags >> 12) & 0x3 == 0 else {
        throw CIError(.conflict, "the index has unresolved merge conflicts")
      }
      if flags & 0x4000 != 0 {
        guard version >= 3 else { throw unsupported("extended flags in version 2") }
        let extended = try u16(offset)
        offset += 2
        guard extended & 0x4000 == 0 else { throw unsupported("sparse checkouts") }
      }
      var name: [UInt8]
      if version == 4 {
        // Git's offset varint: big-endian 7-bit groups, each continuation
        // adding one (`decode_varint`).
        var strip = 0
        var byte: UInt8
        var first = true
        repeat {
          guard offset < body.count, strip < 1 << 24 else { throw unsupported("bad path prefix") }
          byte = bytes[offset]
          offset += 1
          strip = (first ? 0 : (strip + 1) << 7) + Int(byte & 0x7F)
          first = false
        } while byte & 0x80 != 0
        guard strip <= previous.count else { throw unsupported("bad path prefix") }
        name = Array(previous.prefix(previous.count - strip))
        guard let end = body[offset...].firstIndex(of: 0) else { throw unsupported("truncated") }
        name += bytes[offset..<end]
        offset = end + 1
      } else {
        guard let end = body[offset...].firstIndex(of: 0) else { throw unsupported("truncated") }
        name = Array(bytes[offset..<end])
        offset = start + ((end - start + 1 + 7) / 8) * 8
      }
      previous = name
      switch mode & 0o170000 {
      case 0o100000, 0o120000: break
      case 0o160000:
        throw CIError(.compatibilityRejected, "submodule layouts are unsupported")
      default: throw unsupported("an unsupported entry type")
      }
      guard let path = String(validating: name, as: UTF8.self) else {
        throw unsupported("a non-UTF-8 path")
      }
      entries.append(
        Entry(
          path: path, mode: mode, size: size, mtimeSeconds: mtimeSeconds, mtimeNanos: mtimeNanos))
    }
    return entries
  }
}
