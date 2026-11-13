import Foundation
import IsoCore
import IsoHost

/// Streaming policy check of a staged POSIX tar (spec 11.4); never extracts, never follows a link.
package enum ArchiveValidator {
  package struct Limits: Sendable {
    package var maxMembers: Int
    package var maxPathBytes: Int
    package var maxPaxBytes: Int

    package static let standard = Limits(
      maxMembers: 1 << 20, maxPathBytes: 4_096, maxPaxBytes: 64 << 10)
  }

  package struct Summary: Sendable, Equatable {
    package let members: Int
    package let contentBytes: UInt64
  }

  package static func validate(path: String, limits: Limits = .standard) throws(HostControlError)
    -> Summary
  {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw .invalidRequest("artifact is unreadable") }
    defer { close(fd) }
    var reader = BlockReader(fd: fd)
    return try validate(&reader, limits: limits)
  }

  package static func validate(bytes: [UInt8], limits: Limits = .standard) throws(HostControlError)
    -> Summary
  {
    var reader = MemoryBlocks(bytes: bytes)
    return try validate(&reader, limits: limits)
  }

  private static func validate(_ reader: inout some BlockSource, limits: Limits)
    throws(HostControlError) -> Summary
  {
    var seen = MemberIndex()
    var members = 0
    var content: UInt64 = 0
    var pendingPath: String?
    var pendingLink: String?
    var zeroBlocks = 0

    while true {
      guard let header = try reader.next() else {
        throw reject("truncated archive: missing end-of-archive blocks")
      }
      if header.allSatisfy({ $0 == 0 }) {
        zeroBlocks += 1
        if zeroBlocks == 2 { break }
        continue
      }
      guard zeroBlocks == 0 else { throw reject("data after an end-of-archive block") }
      try verifyChecksum(header)
      let type = Character(Unicode.Scalar(header[156]))
      let size = try octal(header[124..<136], field: "size")
      let blocks = (size + 511) / 512

      switch type {
      case "x", "L", "K":
        guard size <= UInt64(limits.maxPaxBytes) else { throw reject("extended header too large") }
        var payload: [UInt8] = []
        for _ in 0..<blocks {
          guard let block = try reader.next() else { throw reject("truncated extended header") }
          payload += block
        }
        payload = Array(payload.prefix(Int(size)))
        // Extractors disagree on which of two overriding names wins (PAX
        // after GNU, or the reverse), so a member names itself once.
        if type == "x" {
          let records = try paxRecords(payload)
          if let path = records["path"] {
            guard pendingPath == nil else { throw reject("member name is set twice") }
            pendingPath = path
          }
          if let link = records["linkpath"] {
            guard pendingLink == nil else { throw reject("link target is set twice") }
            pendingLink = link
          }
        } else {
          let text = try utf8(Array(payload.prefix { $0 != 0 }))
          if type == "L" {
            guard pendingPath == nil else { throw reject("member name is set twice") }
            pendingPath = text
          } else {
            guard pendingLink == nil else { throw reject("link target is set twice") }
            pendingLink = text
          }
        }
        continue
      case "g":
        throw reject("global extended headers are not accepted")
      default:
        break
      }

      let name: String
      if let pendingPath { name = pendingPath } else { name = try headerPath(header) }
      let link: String
      if let pendingLink {
        link = pendingLink
      } else {
        link = try utf8(Array(header[157..<257].prefix { $0 != 0 }))
      }
      pendingPath = nil
      pendingLink = nil

      members += 1
      guard members <= limits.maxMembers else { throw reject("too many archive members") }
      // GNU and BSD tar name the archive root (`./`) as an empty directory
      // member; it carries nothing to extract, so only that is skipped.
      if type == "5", size == 0, namesRoot(name) { continue }
      // libarchive extracts any member whose name ends in `/` as a
      // directory and reads its "data" as further headers.
      if type != "5", name.hasSuffix("/") {
        throw reject("non-directory member \(debugQuoted(name)) has a directory name")
      }
      let normalized = fold(try normalize(name, limits: limits))
      let kind: Character =
        switch type {
        case "0", "\0", "7": "f"
        case "5": "d"
        case "2": "l"
        case "1": "h"
        default: throw reject("unsupported member type in \(debugQuoted(normalized))")
        }
      // `normalize` returned at least one component.
      let components = normalized.split(separator: "/")
      // A member under a path that is not a directory would follow it.
      let parent = try seen.walk(components.dropLast()) { existing throws(HostControlError) in
        guard existing == "d" else {
          throw reject("member \(debugQuoted(normalized)) is beneath a non-directory")
        }
      }
      if let parent, let previous = seen.kind(of: components[components.count - 1], under: parent) {
        // A directory may be repeated; anything else is a conflict.
        guard previous == "d" && kind == "d" else {
          throw reject("duplicate archive member \(debugQuoted(normalized))")
        }
      }
      switch kind {
      case "l":
        try checkSymlink(link, member: normalized, parent: parent, seen: seen, limits: limits)
      case "h":
        let target = fold(try normalize(link, limits: limits))
        guard seen.kind(of: target.split(separator: "/")) == "f" else {
          throw reject("hard link \(debugQuoted(normalized)) names no earlier regular file")
        }
      default: break
      }
      // Implied parents are directories: a later link or file there conflicts.
      seen.insert(components, kind: kind)
      if kind == "f" {
        let (sum, overflow) = content.addingReportingOverflow(size)
        guard !overflow else { throw reject("archive size overflows") }
        content = sum
      } else if size != 0 && kind != "f" {
        throw reject("non-file member \(debugQuoted(normalized)) carries data")
      }
      for _ in 0..<blocks {
        guard try reader.next() != nil else { throw reject("truncated member data") }
      }
    }
    return Summary(members: members, contentBytes: content)
  }

  private static func reject(_ reason: String) -> HostControlError {
    .invalidRequest("archive refused: \(reason)")
  }

  private static func utf8(_ bytes: [UInt8]) throws(HostControlError) -> String {
    guard let text = String(validating: bytes, as: UTF8.self) else {
      throw reject("member name is not UTF-8")
    }
    return text
  }

  /// The header's own name. Only POSIX ustar has a prefix field (GNU keeps times there);
  /// other variants are refused.
  private static func headerPath(_ header: [UInt8]) throws(HostControlError) -> String {
    let name = try utf8(Array(header[0..<100].prefix { $0 != 0 }))
    let magic = Array(header[257..<265])
    if magic == Array("ustar\u{0}00".utf8) {
      let prefix = try utf8(Array(header[345..<500].prefix { $0 != 0 }))
      return prefix.isEmpty ? name : prefix + "/" + name
    }
    if magic == Array("ustar  \u{0}".utf8) { return name }
    guard Array(header[257..<262]) != Array("ustar".utf8) else {
      throw reject("unsupported tar header format")
    }
    return name
  }

  static func namesRoot(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/")
      && path.split(separator: "/", omittingEmptySubsequences: true).allSatisfy { $0 == "." }
  }

  /// Lexical normal form: relative, no empty, `.` or `..` components.
  static func normalize(_ path: String, limits: Limits) throws(HostControlError) -> String {
    guard !path.isEmpty, path.utf8.count <= limits.maxPathBytes else {
      throw reject("member name is empty or too long")
    }
    guard !path.hasPrefix("/") else { throw reject("absolute member \(debugQuoted(path))") }
    guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
      throw reject("member name contains a control character")
    }
    var parts: [Substring] = []
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
      if part == "." { continue }
      guard part != ".." else { throw reject("traversal in member \(debugQuoted(path))") }
      parts.append(part)
    }
    guard !parts.isEmpty else { throw reject("member \(debugQuoted(path)) names the root") }
    return parts.joined(separator: "/")
  }

  /// The key members are compared by: the default APFS volume is case- and
  /// normalization-insensitive, so `a` and `A` name the same file.
  static func fold(_ path: String) -> String {
    path.precomposedStringWithCanonicalMapping.lowercased()
  }

  /// A symlink target must be relative, never climb with `..`, and never pass through an
  /// earlier symlink member.
  private static func checkSymlink(
    _ target: String, member: String, parent: Int?, seen: MemberIndex, limits: Limits
  ) throws(HostControlError) {
    guard !target.isEmpty, !target.hasPrefix("/"), target.utf8.count <= limits.maxPathBytes else {
      throw reject("symlink \(debugQuoted(member)) has an absolute or empty target")
    }
    var depth = member.split(separator: "/").count - 1
    // Once a prefix names no earlier member, no longer prefix can either.
    var node = parent
    for part in target.split(separator: "/", omittingEmptySubsequences: true) where part != "." {
      guard part != ".." else {
        throw reject("symlink \(debugQuoted(member)) climbs with '..'")
      }
      depth += 1
      let folded = Substring(fold(String(part)))
      node = node.flatMap { seen.child(of: $0, named: folded) }
      guard node.map({ seen.kind(at: $0) }) != "l" else {
        throw reject("symlink \(debugQuoted(member)) passes through another symlink")
      }
    }
    guard depth > 0 else { throw reject("symlink \(debugQuoted(member)) names the root") }
  }

  private static func verifyChecksum(_ header: [UInt8]) throws(HostControlError) {
    let stored = try octal(header[148..<156], field: "checksum")
    var sum: UInt64 = 0
    for (index, byte) in header.enumerated() {
      sum += (148..<156).contains(index) ? 32 : UInt64(byte)
    }
    guard sum == stored else { throw reject("header checksum mismatch") }
  }

  private static func octal(_ field: ArraySlice<UInt8>, field name: String) throws(HostControlError)
    -> UInt64
  {
    var value: UInt64 = 0
    var started = false
    for byte in field {
      if byte == 0 || byte == UInt8(ascii: " ") {
        if started { break } else { continue }
      }
      guard (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) else {
        throw reject("invalid \(name) field")
      }
      started = true
      let (shifted, overflow) = value.multipliedReportingOverflow(by: 8)
      guard !overflow else { throw reject("\(name) field overflows") }
      value = shifted + UInt64(byte - UInt8(ascii: "0"))
    }
    return value
  }

  private static func paxRecords(_ payload: [UInt8]) throws(HostControlError) -> [String: String] {
    var records: [String: String] = [:]
    var index = 0
    while index < payload.count {
      guard let space = payload[index...].firstIndex(of: UInt8(ascii: " ")),
        let lengthText = String(validating: payload[index..<space], as: UTF8.self),
        let length = Int(lengthText), length > 0, length <= payload.count - index,
        space + 1 <= index + length - 1, payload[index + length - 1] == UInt8(ascii: "\n")
      else { throw reject("malformed extended header") }
      let body = try utf8(Array(payload[(space + 1)..<(index + length - 1)]))
      guard let equals = body.firstIndex(of: "=") else {
        throw reject("malformed extended header record")
      }
      let key = String(body[..<equals])
      // Keys an extractor would honour differently (size, sparse maps,
      // xattrs) would desynchronize this check from extraction.
      guard ["path", "linkpath", "mtime", "atime", "ctime"].contains(key) else {
        throw reject("extended header key \(debugQuoted(key)) is not accepted")
      }
      guard records[key] == nil else { throw reject("duplicate extended header key") }
      records[key] = String(body[body.index(after: equals)...])
      index += length
    }
    return records
  }
}

/// Members seen so far as a tree of folded path components, so deep names cannot amplify
/// memory beyond the archive's size.
private struct MemberIndex {
  private var kinds: [Character] = ["d"]
  private var children: [[Substring: Int]] = [[:]]
  private static let root = 0

  func child(of node: Int, named part: Substring) -> Int? { children[node][part] }

  func kind(at node: Int) -> Character { kinds[node] }

  func kind(of part: Substring, under node: Int) -> Character? {
    children[node][part].map { kinds[$0] }
  }

  func kind(of components: [Substring]) -> Character? {
    var node = Self.root
    for part in components {
      guard let next = children[node][part] else { return nil }
      node = next
    }
    return node == Self.root ? nil : kinds[node]
  }

  /// Follows `components` from the root, passing each recorded kind to
  /// `visit`; nil once a component names no earlier member.
  func walk(
    _ components: ArraySlice<Substring>, visit: (Character) throws(HostControlError) -> Void
  ) throws(HostControlError) -> Int? {
    var node = Self.root
    for part in components {
      guard let next = children[node][part] else { return nil }
      try visit(kinds[next])
      node = next
    }
    return node
  }

  mutating func insert(_ components: [Substring], kind: Character) {
    var node = Self.root
    for part in components {
      if let next = children[node][part] {
        node = next
      } else {
        let next = kinds.count
        kinds.append("d")
        children.append([:])
        children[node][part] = next
        node = next
      }
    }
    kinds[node] = kind
  }
}

private protocol BlockSource {
  mutating func next() throws(HostControlError) -> [UInt8]?
}

private struct BlockReader: BlockSource {
  let fd: Int32

  mutating func next() throws(HostControlError) -> [UInt8]? {
    var block = [UInt8](repeating: 0, count: 512)
    var filled = 0
    while filled < 512 {
      let count = block[filled...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw .invalidRequest("artifact is unreadable")
      }
      if count == 0 { break }
      filled += count
    }
    if filled == 0 { return nil }
    guard filled == 512 else { throw .invalidRequest("archive refused: partial block") }
    return block
  }
}

private struct MemoryBlocks: BlockSource {
  let bytes: [UInt8]
  var offset = 0

  mutating func next() throws(HostControlError) -> [UInt8]? {
    guard offset < bytes.count else { return nil }
    guard offset + 512 <= bytes.count else {
      throw .invalidRequest("archive refused: partial block")
    }
    defer { offset += 512 }
    return Array(bytes[offset..<(offset + 512)])
  }
}
