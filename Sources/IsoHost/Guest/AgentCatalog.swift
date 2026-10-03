import Foundation
import IsoConfiguration
import IsoCore

/// Where a launch-time definition came from. Installed files are host-owned
/// copies, not executable plugins.
package enum AgentDefinitionSource: Sendable, Equatable {
  case builtin
  case installed
}

package struct InstalledAgent: Sendable, Equatable {
  package let definition: AgentDefinition
  package let path: String
  package let snapshotHash: String
  package let definitionHash: String
}

package enum CatalogEntry: Sendable, Equatable {
  case builtin(AgentDefinition, hash: String)
  case installed(InstalledAgent)
  case invalid(name: String, reason: String)
}

package enum AgentCatalog {
  package static func directory(_ config: IsoConfig) -> String {
    config.dataDirectory.appending("agents").path
  }

  package static func builtin(_ id: AgentDefinitionID) -> AgentDefinition? {
    builtins.first { $0.id == id }
  }

  package static let builtins: [AgentDefinition] = [
    AgentDefinition(
      id: AgentDefinitionID(unchecked: "claude"), displayName: "Claude Code", environment: nil,
      launch: AgentLaunchSpec(
        argv: ["claude"], workingDirectory: GuestPath("/workspace"), terminal: .auto,
        environment: []),
      authAdapter: .claude, networkHints: []),
    AgentDefinition(
      id: AgentDefinitionID(unchecked: "codex"), displayName: "Codex", environment: nil,
      launch: AgentLaunchSpec(
        argv: ["codex"], workingDirectory: GuestPath("/workspace"), terminal: .auto,
        environment: []),
      authAdapter: .codex, networkHints: []),
  ]

  package static func definitionHash(_ definition: AgentDefinition) -> String {
    "sha256:" + sha256Hex(AgentDefinitionDecoder.canonicalBytes(definition))
  }

  /// Built-in first. A reserved id never reads a file. An invalid installed
  /// file is an error, not a fallback to another definition.
  package static func resolve(_ id: AgentDefinitionID, config: IsoConfig) throws -> (
    definition: AgentDefinition, source: AgentDefinitionSource, hash: String
  ) {
    if let builtin = builtin(id) {
      return (builtin, .builtin, definitionHash(builtin))
    }
    if id.isReserved {
      throw HostError("agent id '\(id)' is reserved for a compiled adapter")
    }
    let path = directory(config) + "/\(id.rawValue).json"
    guard let bytes = try readIfPresent(path) else {
      throw HostError(
        "No agent definition '\(id)'. Install one with `iso agent add`, or use claude or codex.")
    }
    let definition = try decodeInstalled(bytes, path: path, id: id)
    return (definition, .installed, definitionHash(definition))
  }

  package static func list(_ config: IsoConfig) -> [CatalogEntry] {
    var entries = builtins.map { CatalogEntry.builtin($0, hash: definitionHash($0)) }
    let root = directory(config)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    for name in names.sorted() {
      guard name.hasSuffix(".json"), name != ".lock" else { continue }
      let path = root + "/" + name
      do {
        let bytes = try readIfPresent(path)
        guard let bytes else {
          entries.append(.invalid(name: name, reason: "not a regular file"))
          continue
        }
        let stem = String(name.dropLast(5))
        let id = try AgentDefinitionID(stem)
        if id.isReserved {
          entries.append(.invalid(name: name, reason: "reserved id '\(id)' cannot be installed"))
          continue
        }
        let definition = try decodeInstalled(bytes, path: path, id: id)
        entries.append(
          .installed(
            InstalledAgent(
              definition: definition, path: path,
              snapshotHash: "sha256:" + sha256Hex(bytes),
              definitionHash: definitionHash(definition))))
      } catch {
        entries.append(.invalid(name: name, reason: neutralizeControls("\(error)")))
      }
    }
    return entries
  }

  /// Read and validate a source file without writing. The returned definition
  /// is the only value `install` may persist for this review.
  package static func review(sourcePath: String) throws -> (AgentDefinition, [UInt8]) {
    let bytes = try readSource(sourcePath)
    let format = try definitionFormat(sourcePath)
    let definition = try AgentDefinitionDecoder.decode(bytes, path: sourcePath, format: format)
    if definition.id.isReserved {
      throw HostError("agent id '\(definition.id)' is reserved and cannot be installed")
    }
    let stem = ((sourcePath as NSString).lastPathComponent as NSString).deletingPathExtension
    guard stem == definition.id.rawValue else {
      throw HostError(
        "definition id '\(definition.id)' does not match source file name '\(stem)'")
    }
    return (definition, bytes)
  }

  /// Persist the already-validated definition. Does not re-read `sourcePath`.
  package static func install(
    _ definition: AgentDefinition, config: IsoConfig, replace: Bool
  ) throws -> InstalledAgent {
    if definition.id.isReserved {
      throw HostError("agent id '\(definition.id)' is reserved and cannot be installed")
    }
    let root = directory(config)
    try StateStore.ensurePrivateDirectory(root)
    try requirePrivateDirectory(root)
    let lock = try FileLock(path: root + "/.lock")
    defer { lock.release() }
    let path = root + "/\(definition.id.rawValue).json"
    var existing = stat()
    let exists = lstat(path, &existing) == 0
    if exists {
      guard replace else {
        throw HostError(
          "agent '\(definition.id)' is already installed; pass --replace to replace it")
      }
      guard (existing.st_mode & S_IFMT) != S_IFLNK else {
        throw HostError("refusing to replace a symlink at \(path)")
      }
    }
    let bytes = AgentDefinitionDecoder.canonicalBytes(definition) + [UInt8(ascii: "\n")]
    try AtomicFile.write(bytes, to: path, mode: .atMost(0o600))
    return InstalledAgent(
      definition: definition, path: path, snapshotHash: "sha256:" + sha256Hex(bytes),
      definitionHash: definitionHash(definition))
  }

  static func decodeInstalled(_ bytes: [UInt8], path: String, id: AgentDefinitionID) throws
    -> AgentDefinition
  {
    let definition = try AgentDefinitionDecoder.decode(bytes, path: path, format: .json)
    guard definition.id == id else {
      throw HostError("installed definition id '\(definition.id)' does not match \(path)")
    }
    return definition
  }

  static func definitionFormat(_ path: String) throws -> ConfigFormat {
    if path.hasSuffix(".jsonc") { return .jsonc }
    if path.hasSuffix(".json") { return .json }
    throw HostError("agent definition must be a .json or .jsonc file")
  }

  /// Source file for `agent add`: regular, owned by this user, not group or
  /// world writable, not a symlink.
  package static func readSource(_ path: String) throws -> [UInt8] {
    guard let bytes = try readIfPresent(path) else {
      throw HostError("No agent definition file at \(path)")
    }
    return bytes
  }

  static func readIfPresent(_ path: String) throws -> [UInt8]? {
    let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    if fd < 0 {
      if errno == ENOENT { return nil }
      if errno == ELOOP { throw HostError("refusing to read symlink \(path)") }
      throw HostError.posix("Failed to open", path)
    }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw HostError("Failed to read \(path): not a regular file")
    }
    guard info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
      throw HostError("refusing to read \(path): owner or mode is not private to this user")
    }
    guard info.st_size <= AgentDefinition.fileBytes else {
      throw HostError("\(path) is larger than \(AgentDefinition.fileBytes) bytes")
    }
    return try StateStore.readBounded(
      fd, path: path, limit: AgentDefinition.fileBytes,
      tooLarge: "\(path) is larger than \(AgentDefinition.fileBytes) bytes")
  }

  static func requirePrivateDirectory(_ path: String) throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
      info.st_mode & 0o077 == 0
    else { throw HostError("agent catalog \(path) must be a private directory owned by this user") }
  }
}

extension AgentDefinitionID {
  /// Built-in descriptors are compiled literals, not parsed input.
  fileprivate init(unchecked raw: String) {
    // The literals "claude" and "codex" satisfy the validating initializer.
    self = try! AgentDefinitionID(raw)
  }
}
