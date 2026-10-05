// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// The `iso-<name>` aliases iso manages in `~/.ssh/config`; the
/// marker namespace and block editing live in `SSHConfigBlocks`.
package struct SSHConfigFile: Sendable {
  package let path: String
  let diagnostics: Diagnostics

  package init(path: String, diagnostics: Diagnostics) {
    self.path = path
    self.diagnostics = diagnostics
  }

  package static func forHome(_ home: String?, diagnostics: Diagnostics) throws -> SSHConfigFile {
    guard let home else { throw HostError("Could not determine home directory") }
    return SSHConfigFile(path: home + "/.ssh/config", diagnostics: diagnostics)
  }

  package static func host(_ instance: Instance) -> String {
    SSHConfigBlocks.host(for: instance.name)
  }

  package static func block(_ target: SSHTarget, _ instance: Instance) -> String {
    let host = host(instance)
    let hostKeys = target.hostKeyOptions.map { option -> String in
      guard let equals = option.firstIndex(of: "=") else { return "    \(option)\n" }
      return "    \(option[..<equals]) \(option[option.index(after: equals)...])\n"
    }.joined()
    return """
      \(SSHConfigBlocks.markerPrefix) \(host)
      Host \(host)
          HostName \(target.host)
          Port \(target.port)
          User \(target.user)
          IdentityFile \(SSHTarget.quoteValue(target.keyPath))
          IdentitiesOnly yes
      \(hostKeys)    LogLevel ERROR
      \(SSHConfigBlocks.markerEnd)
      """
  }

  func read() throws -> String? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    guard let data = FileManager.default.contents(atPath: path),
      let text = String(data: data, encoding: .utf8)
    else { throw HostError("Failed to read ~/.ssh/config") }
    return text
  }

  /// Keeps the existing file's mode; a new file is `0600`.
  func write(_ content: String) throws {
    do {
      try AtomicFile.write(
        Array(content.utf8), to: path, mode: .preserveExisting(default: 0o600))
    } catch {
      throw ContextError("Failed to write ~/.ssh/config", cause: error)
    }
  }

  @discardableResult
  package func update(_ target: SSHTarget, _ instance: Instance) throws -> SSHAlias {
    do {
      try FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    } catch {
      throw ContextError("Failed to create ~/.ssh directory", cause: error)
    }
    let host = Self.host(instance)
    let existing = try read() ?? ""
    try SSHConfigBlocks.checkAliasAvailable(existing, host: host)
    let cleaned = SSHConfigBlocks.removeNamedMarkerBlock(existing, host: host)
    let block = Self.block(target, instance)
    try target.requireHandoff()
    try write(cleaned.isEmpty ? block + "\n" : cleaned + "\n" + block + "\n")
    diagnostics.log(.info, "Updated SSH config at \(path)")
    return SSHAlias(host: host, configPath: path)
  }

  package func refreshIfPresent(_ target: SSHTarget, _ instance: Instance) throws {
    guard let content = try read() else { return }
    let marker = "\(SSHConfigBlocks.markerPrefix) \(Self.host(instance))"
    guard rustLines(content).contains(where: { $0.trimmingUnicodeWhitespace() == marker })
    else { return }
    try update(target, instance)
  }

  package func remove(_ instance: Instance) throws {
    guard let content = try read() else { return }
    let cleaned = SSHConfigBlocks.removeNamedMarkerBlock(content, host: Self.host(instance))
    guard cleaned.utf8.count != content.utf8.count else { return }
    try write(cleaned)
    diagnostics.log(.info, "Removed SSH config block for instance '\(instance.name)'")
  }

  package func removeAll() throws {
    guard let content = try read() else { return }
    let cleaned = SSHConfigBlocks.removeMarkerBlocks(content)
    guard cleaned.utf8.count != content.utf8.count else { return }
    try write(cleaned)
    diagnostics.log(.info, "Removed iso SSH config blocks")
  }

  /// `iso ssh-config` / `iso editor`: install the alias and print how to
  /// use it (stderr).
  @discardableResult
  package func install(_ running: AppleBackend.Running, stderr: (String) -> Void) throws
    -> SSHAlias
  {
    let alias = try update(running.target, running.instance)
    let host = Self.host(running.instance)
    stderr(
      "\nSSH alias '\(host)' is ready:\n\n\(Self.block(running.target, running.instance))\n\nUse it with ssh/scp/rsync, e.g.:\n    ssh \(host)\n    scp ./file \(host):/workspace/\n    rsync -az ./dir/ \(host):/workspace/dir/\n\nThese connections verify the VM's pinned host key; a changed key is refused."
    )
    return alias
  }
}
