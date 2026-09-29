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

  /// Copy the allowlisted `files` and `directories` of `source` in. An
  /// overlay: nothing already staged is removed. Symlinks are followed.
  func stage(from source: String, files: [String], directories: [String]) throws {
    for name in files where HostFiles.isFile(source + "/" + name) {
      do { try HostFiles.copyFile(source + "/" + name, to: path + "/" + name) } catch {
        throw ContextError("Failed to stage \(name)", cause: error)
      }
    }
    for name in directories where HostFiles.isDirectory(source + "/" + name) {
      do { try HostFiles.copyTree(source + "/" + name, to: path + "/" + name) } catch {
        throw ContextError("Failed to stage \(name)/", cause: error)
      }
    }
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
