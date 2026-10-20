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
