import Darwin
import Foundation
import IsoGitIndex

/// The working tree's Git index and HEAD, read as inert data (CI-01, the
/// iso INPUT-01 rule): no Git process, no repository configuration, hooks,
/// filters, helpers or fsmonitor. Forms it cannot read safely are refused.
package enum GitIndex {
  package typealias Entry = GitIndexFile.Entry

  package struct Layout: Sendable, Equatable {
    /// The working-tree root.
    package let root: String
    /// The repository's administrative directory (`.git` or a gitfile's).
    package let gitDirectory: String
    /// Shared refs for a linked worktree, else `gitDirectory`.
    package let commonDirectory: String
  }

  static let maxIndexBytes = 256 << 20

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

  static let maxConfigBytes = 1 << 20

  /// The last `remote.origin.url` in the repository's own `config` (the
  /// shared one for a linked worktree), parsed as data. Include directives
  /// are not followed and no system or global configuration is read, so
  /// nothing outside the repository decides the name. Nil when there is no
  /// such value or the file is not a plain, bounded, well-formed config.
  package static func originURL(_ layout: Layout) throws(CIError) -> String? {
    guard
      let bytes = try PrivateFiles.read(
        layout.commonDirectory + "/config", limit: maxConfigBytes)
    else { return nil }
    return GitConfigFile.lastValue(
      bytes, section: "remote", subsection: "origin", key: "url")
  }

  /// Stage-0 entries, read by the shared inert reader (`IsoGitIndex`).
  package static func entries(_ layout: Layout) throws(CIError) -> [Entry] {
    // Only an absent index means "nothing tracked"; an index that exists
    // but cannot be read fails the capture instead of looking clean.
    guard let bytes = try PrivateFiles.read(layout.gitDirectory + "/index", limit: maxIndexBytes)
    else { return [] }
    return try parse(bytes)
  }

  package static func parse(_ bytes: [UInt8]) throws(CIError) -> [Entry] {
    do {
      return try GitIndexFile.parse(bytes)
    } catch .unmerged {
      throw CIError(.conflict, "the index has unresolved merge conflicts")
    } catch .submodule {
      throw CIError(.compatibilityRejected, "submodule layouts are unsupported")
    } catch {
      throw CIError(.compatibilityRejected, "the Git index cannot be read inertly (\(error))")
    }
  }
}

/// Just enough of Git's configuration syntax (`git help config`, "Syntax")
/// to read one value as data: `#`/`;` comments, `[section]`,
/// `[section "subsection"]` and legacy `[section.subsection]` headers on
/// any line, case-insensitive section and key names, case-sensitive quoted
/// subsections, quoted values, the `\\` `\"` `\n` `\t` `\b` escapes and
/// line continuations. `[include]` and `[includeIf]` are ordinary sections
/// here: they are never followed.
package enum GitConfigFile {
  struct Malformed: Error {}

  /// The last value of `key` in `[section "subsection"]`; nil when it is
  /// absent, valueless, not UTF-8 or the file does not parse as Git would.
  package static func lastValue(
    _ bytes: [UInt8], section: String, subsection: String?, key: String
  ) -> String? {
    var parser = Parser(bytes: bytes)
    var found: [UInt8]?
    do {
      while let entry = try parser.next() {
        guard entry.section == Array(section.lowercased().utf8),
          entry.subsection == subsection.map({ Array($0.utf8) }),
          entry.key == Array(key.lowercased().utf8)
        else { continue }
        found = entry.value
      }
    } catch { return nil }
    return found.flatMap { String(validating: $0, as: UTF8.self) }
  }

  struct Parser {
    struct Entry {
      let section: [UInt8]
      let subsection: [UInt8]?
      let key: [UInt8]
      let value: [UInt8]?
    }

    let bytes: [UInt8]
    var offset = 0
    var section: [UInt8]?
    var subsection: [UInt8]?

    init(bytes: [UInt8]) { self.bytes = bytes }

    /// The next byte, with CRLF read as LF and end of file as LF (Git's
    /// `get_next_char`); nil only past the end.
    mutating func character() -> UInt8? {
      guard offset < bytes.count else {
        offset += 1
        return offset == bytes.count + 1 ? 0x0A : nil
      }
      var c = bytes[offset]
      offset += 1
      if c == 0x0D, offset < bytes.count, bytes[offset] == 0x0A {
        c = 0x0A
        offset += 1
      }
      return c
    }

    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0B || c == 0x0C }
    static func isAlpha(_ c: UInt8) -> Bool {
      (0x41...0x5A).contains(c) || (0x61...0x7A).contains(c)
    }
    static func isKeyCharacter(_ c: UInt8) -> Bool {
      isAlpha(c) || (0x30...0x39).contains(c) || c == UInt8(ascii: "-")
    }
    static func lower(_ c: UInt8) -> UInt8 { (0x41...0x5A).contains(c) ? c + 0x20 : c }

    mutating func next() throws(Malformed) -> Entry? {
      while let c = character() {
        if c == 0x0A || c == 0x0D || Self.isSpace(c) { continue }
        if c == UInt8(ascii: "#") || c == UInt8(ascii: ";") {
          while let d = character(), d != 0x0A {}
          continue
        }
        if c == UInt8(ascii: "[") {
          try header()
          continue
        }
        guard Self.isAlpha(c), let section else { throw Malformed() }
        var key = [Self.lower(c)]
        var d = character()
        while let current = d, Self.isKeyCharacter(current) {
          key.append(Self.lower(current))
          d = character()
        }
        while let current = d, Self.isSpace(current) { d = character() }
        switch d {
        case .some(0x0A), .none:
          return Entry(section: section, subsection: subsection, key: key, value: nil)
        case .some(UInt8(ascii: "=")):
          let value = try self.value()
          return Entry(section: section, subsection: subsection, key: key, value: value)
        default: throw Malformed()
        }
      }
      return nil
    }

    /// `[name]`, `[name.legacy]` or `[name "subsection"]`; a key may follow
    /// on the same line.
    mutating func header() throws(Malformed) {
      var name: [UInt8] = []
      while let c = character() {
        if c == UInt8(ascii: "]") {
          guard !name.isEmpty else { throw Malformed() }
          if let dot = name.firstIndex(of: UInt8(ascii: ".")) {
            section = Array(name[..<dot])
            subsection = Array(name[(dot + 1)...])
          } else {
            section = name
            subsection = nil
          }
          return
        }
        if Self.isSpace(c) {
          guard !name.isEmpty, !name.contains(UInt8(ascii: ".")) else { throw Malformed() }
          var d = character()
          while let current = d, Self.isSpace(current) { d = character() }
          guard d == UInt8(ascii: "\"") else { throw Malformed() }
          var quoted: [UInt8] = []
          while true {
            guard var e = character(), e != 0x0A else { throw Malformed() }
            if e == UInt8(ascii: "\"") { break }
            if e == UInt8(ascii: "\\") {
              guard let escaped = character(), escaped != 0x0A else { throw Malformed() }
              e = escaped
            }
            quoted.append(e)
          }
          guard character() == UInt8(ascii: "]") else { throw Malformed() }
          section = name
          subsection = quoted
          return
        }
        guard Self.isKeyCharacter(c) || c == UInt8(ascii: ".") else { throw Malformed() }
        name.append(Self.lower(c))
      }
      throw Malformed()
    }

    /// A value up to the end of its line (Git's `parse_value`).
    mutating func value() throws(Malformed) -> [UInt8] {
      var out: [UInt8] = []
      var quoted = false
      var comment = false
      var spaces = 0
      while true {
        guard var c = character() else { return out }
        if c == 0x0A {
          guard !quoted else { throw Malformed() }
          return out
        }
        if comment { continue }
        if Self.isSpace(c) || c == 0x0D, !quoted {
          if !out.isEmpty { spaces += 1 }
          continue
        }
        if !quoted, c == UInt8(ascii: ";") || c == UInt8(ascii: "#") {
          comment = true
          continue
        }
        out += [UInt8](repeating: 0x20, count: spaces)
        spaces = 0
        if c == UInt8(ascii: "\\") {
          guard let escaped = character() else { throw Malformed() }
          switch escaped {
          case 0x0A: continue
          case UInt8(ascii: "t"): c = 0x09
          case UInt8(ascii: "b"): c = 0x08
          case UInt8(ascii: "n"): c = 0x0A
          case UInt8(ascii: "\\"), UInt8(ascii: "\""): c = escaped
          default: throw Malformed()
          }
          out.append(c)
          continue
        }
        if c == UInt8(ascii: "\"") {
          quoted.toggle()
          continue
        }
        out.append(c)
      }
    }
  }
}
