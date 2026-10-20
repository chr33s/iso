// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// A private temporary directory holding allowlisted host files on their way
/// to the guest. Removed by `remove()`; callers scope it with `defer`.
final class StagingDirectory: Sendable {
  let path: String

  init(root: String = NSTemporaryDirectory()) throws {
    let base = root.hasSuffix("/") ? String(root.dropLast()) : root
    var template = Array((base + "/iso-stage-XXXXXX").utf8CString)
    guard let created = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
      throw HostError("Failed to create staging directory")
    }
    path = String(cString: created)
  }

  func remove() { try? FileManager.default.removeItem(atPath: path) }

  /// Entry names, sorted for a deterministic copy order.
  func entries() throws -> [String] {
    do {
      return try FileManager.default.contentsOfDirectory(atPath: path).sorted()
    } catch {
      throw HostError("Failed to read staging directory")
    }
  }

  /// Copy the allowlisted `files` and `directories` of `source` in, as one
  /// confined snapshot of the approved root (IMPORT-01): a link is followed
  /// only to a regular file or directory inside that root, special files and
  /// cycles are refused, and the whole import is bounded. `reads` are
  /// further files read as data (never staged); they are captured here so
  /// no later step reopens the host path. An overlay: nothing already staged
  /// is removed.
  @discardableResult
  func stage(from source: String, files: [String], directories: [String], reads: [String] = [])
    throws -> [String: [UInt8]]
  {
    var copy = try ConfinedCopy(root: source)
    for name in files {
      do { try copy.file(name, to: path + "/" + name) } catch {
        throw ContextError("Failed to stage \(name)", cause: error)
      }
    }
    for name in directories {
      do { try copy.tree(name, to: path + "/" + name) } catch {
        throw ContextError("Failed to stage \(name)/", cause: error)
      }
    }
    var captured: [String: [UInt8]] = [:]
    for name in reads {
      do { captured[name] = try copy.read(name) } catch {
        throw ContextError("Failed to read \(name)", cause: error)
      }
    }
    return captured
  }
}

/// Copies out of one approved host root without leaving it: every entry is
/// resolved and must stay below the root, and counts and bytes are capped.
struct ConfinedCopy {
  static let maxEntries = 10_000
  static let maxBytes: Int64 = 256 << 20

  let root: String
  private var entries = 0
  private var bytes: Int64 = 0

  init(root source: String) throws {
    guard let resolved = canonicalPath(source), HostFiles.isDirectory(resolved) else {
      throw HostError("Import root \(neutralizeControls(source)) is not a directory")
    }
    root = resolved
  }

  /// `name` below the root, resolved; nil when absent. Throws when it
  /// resolves outside the root or to anything but a file or directory.
  func resolve(_ relative: String) throws -> (path: String, directory: Bool)? {
    let lexical = root + "/" + relative
    var link = stat()
    guard lstat(lexical, &link) == 0 else {
      if errno == ENOENT { return nil }
      throw HostError.posix("Failed to inspect", lexical)
    }
    guard let resolved = canonicalPath(lexical) else {
      throw HostError("\(neutralizeControls(relative)) is a dangling or cyclic link")
    }
    guard resolved.hasPrefix(root + "/") else {
      throw HostError("\(neutralizeControls(relative)) resolves outside the import root")
    }
    var info = stat()
    guard stat(resolved, &info) == 0 else { throw HostError.posix("Failed to inspect", resolved) }
    switch info.st_mode & S_IFMT {
    case S_IFREG: return (resolved, false)
    case S_IFDIR: return (resolved, true)
    default: throw HostError("\(neutralizeControls(relative)) is not a regular file or directory")
    }
  }

  private mutating func count(_ size: Int64) throws {
    entries += 1
    bytes += size
    guard entries <= Self.maxEntries, bytes <= Self.maxBytes else {
      throw HostError(
        "The import exceeds \(Self.maxEntries) entries or \(Self.maxBytes >> 20) MiB; import named files instead"
      )
    }
  }

  mutating func file(_ relative: String, to destination: String) throws {
    guard let entry = try resolve(relative), !entry.directory else { return }
    try count(size(entry.path))
    try HostFiles.copyFile(entry.path, to: destination)
  }

  mutating func tree(_ relative: String, to destination: String, depth: Int = 0) throws {
    guard let entry = try resolve(relative), entry.directory else { return }
    guard depth < HostFiles.maxDepth else {
      throw HostError("\(neutralizeControls(relative)) is too deeply nested")
    }
    try count(0)
    do {
      try FileManager.default.createDirectory(
        atPath: destination, withIntermediateDirectories: true)
    } catch {
      throw HostError("Failed to create \(destination)")
    }
    let names: [String]
    do { names = try FileManager.default.contentsOfDirectory(atPath: entry.path).sorted() } catch {
      throw HostError("Failed to read \(entry.path)")
    }
    for name in names {
      let child = relative + "/" + name
      guard let resolved = try resolve(child) else { continue }
      if resolved.directory {
        try tree(child, to: destination + "/" + name, depth: depth + 1)
      } else {
        try file(child, to: destination + "/" + name)
      }
    }
  }

  /// A regular file's bytes, nil when absent.
  mutating func read(_ relative: String) throws -> [UInt8]? {
    guard let entry = try resolve(relative) else { return nil }
    guard !entry.directory else {
      throw HostError("\(neutralizeControls(relative)) is a directory")
    }
    let size = size(entry.path)
    try count(size)
    let fd = open(entry.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw HostError.posix("Failed to open", entry.path) }
    defer { close(fd) }
    return try StateStore.readBounded(
      fd, path: entry.path, limit: Int(Self.maxBytes), tooLarge: "\(relative) is too large")
  }

  private func size(_ path: String) -> Int64 {
    var info = stat()
    return stat(path, &info) == 0 ? Int64(info.st_size) : 0
  }
}

/// Host file copies with `std::fs::copy` semantics: the source is followed
/// through symlinks, the destination replaced, and permission bits kept.
enum HostFiles {
  /// Directory trees deeper than this (a symlink cycle) are refused.
  static let maxDepth = 64

  static func isFile(_ path: String) -> Bool {
    var status = stat()
    return stat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
  }

  static func isDirectory(_ path: String) -> Bool {
    var status = stat()
    return stat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFDIR
  }

  static func copyFile(_ source: String, to destination: String) throws {
    let input = open(source, O_RDONLY | O_CLOEXEC)
    guard input >= 0 else { throw HostError.posix("Failed to open", source) }
    defer { close(input) }
    var status = stat()
    guard fstat(input, &status) == 0 else { throw HostError.posix("Failed to stat", source) }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw HostError("Failed to copy \(source): not a regular file")
    }
    let mode = status.st_mode & 0o7777
    let output = open(destination, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, mode)
    guard output >= 0 else { throw HostError.posix("Failed to create", destination) }
    defer { close(output) }
    var buffer = [UInt8](repeating: 0, count: 64 << 10)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR { continue }
        throw HostError.posix("Failed to read", source)
      }
      if count == 0 { break }
      var offset = 0
      while offset < count {
        let written = buffer[offset..<count].withUnsafeBytes {
          write(output, $0.baseAddress, $0.count)
        }
        if written < 0 {
          if errno == EINTR { continue }
          throw HostError.posix("Failed to write", destination)
        }
        offset += written
      }
    }
    guard fchmod(output, mode) == 0 else {
      throw HostError.posix("Failed to set permissions on", destination)
    }
  }

  static func copyTree(_ source: String, to destination: String, depth: Int = 0) throws {
    guard depth < maxDepth else { throw HostError("Failed to read \(source): too deeply nested") }
    do {
      try FileManager.default.createDirectory(
        atPath: destination, withIntermediateDirectories: true)
    } catch {
      throw HostError("Failed to create \(destination)")
    }
    let names: [String]
    do { names = try FileManager.default.contentsOfDirectory(atPath: source).sorted() } catch {
      throw HostError("Failed to read \(source)")
    }
    for name in names {
      let from = source + "/" + name
      let to = destination + "/" + name
      if isDirectory(from) {
        try copyTree(from, to: to, depth: depth + 1)
      } else {
        do { try copyFile(from, to: to) } catch {
          throw ContextError("Failed to copy \(from) -> \(to)", cause: error)
        }
      }
    }
  }
}

// MARK: - MCP server definitions

extension MCPServer {
  /// Header values resolved (`cmd:` references run now); stdio servers carry
  /// no secret-bearing fields.
  func resolvingHeaders(_ resolver: CredentialResolver, label: String, name: String) throws
    -> MCPServer
  {
    func resolve(_ headers: [String: Secret<String>]) throws -> [String: Secret<String>] {
      var resolved: [String: Secret<String>] = [:]
      for key in headers.keys.sorted() {
        do { resolved[key] = try resolver.resolve(headers[key]!) } catch {
          throw ContextError(
            "Failed to resolve header '\(key)' for \(label) '\(name)'", cause: error)
        }
      }
      return resolved
    }
    switch self {
    case .stdio: return self
    case .http(let url, let headers): return .http(url: url, headers: try resolve(headers))
    case .sse(let url, let headers): return .sse(url: url, headers: try resolve(headers))
    }
  }

  static func urlText(_ url: URL) -> String {
    let scheme = url.scheme?.lowercased()
    return scheme == "http" || scheme == "https" ? EndpointURL(url).serialized : url.absoluteString
  }

  static func sorted<V>(_ map: [String: V]) -> [(String, V)] {
    map.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }.map {
      ($0, map[$0]!)
    }
  }

  /// The definition `claude mcp add-json` takes (serde field order).
  var json: OrderedJSON {
    switch self {
    case .stdio(let command, let args, let env):
      var members: [(String, OrderedJSON)] = [("command", .string(command))]
      if !args.isEmpty { members.append(("args", .array(args.map(OrderedJSON.string)))) }
      if !env.isEmpty {
        let pairs = Self.sorted(Dictionary(uniqueKeysWithValues: env.map { ($0.rawValue, $1) }))
        members.append(("env", .object(.init(pairs.map { ($0, .string($1.rawValue)) }))))
      }
      return .object(.init(members))
    case .http(let url, let headers): return Self.remoteJSON("http", url, headers)
    case .sse(let url, let headers): return Self.remoteJSON("sse", url, headers)
    }
  }

  static func remoteJSON(_ kind: String, _ url: URL, _ headers: [String: Secret<String>])
    -> OrderedJSON
  {
    var members: [(String, OrderedJSON)] = [
      ("type", .string(kind)), ("url", .string(urlText(url))),
    ]
    if !headers.isEmpty {
      members.append(
        ("headers", .object(.init(sorted(headers).map { ($0, .string($1.expose())) }))))
    }
    return .object(.init(members))
  }

  /// The Codex `[mcp_servers.<name>]` table.
  var toml: TOMLValue {
    switch self {
    case .stdio(let command, let args, let env):
      var table = TOMLTable([("command", .string(command))])
      if !args.isEmpty { table["args"] = .array(args.map(TOMLValue.string)) }
      if !env.isEmpty {
        table["env"] = .table(TOMLTable(env.map { ($0.rawValue, .string($1.rawValue)) }))
      }
      return .table(table)
    case .http(let url, let headers): return Self.remoteTOML("http", url, headers)
    case .sse(let url, let headers): return Self.remoteTOML("sse", url, headers)
    }
  }

  static func remoteTOML(_ kind: String, _ url: URL, _ headers: [String: Secret<String>])
    -> TOMLValue
  {
    var table = TOMLTable([("type", .string(kind)), ("url", .string(urlText(url)))])
    if !headers.isEmpty {
      table["headers"] = .table(TOMLTable(headers.map { ($0, .string($1.expose())) }))
    }
    return .table(table)
  }
}
