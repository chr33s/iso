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

  /// Install or refresh the alias for a running instance.
  package func update(_ target: SSHTarget, _ instance: Instance) throws {
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
  }

  /// Only rewrites an alias the user already installed.
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
  package func install(_ running: AppleBackend.Running, stderr: (String) -> Void) throws {
    try update(running.target, running.instance)
    let host = Self.host(running.instance)
    stderr(
      "\nSSH alias '\(host)' is ready:\n\n\(Self.block(running.target, running.instance))\n\nUse it with ssh/scp/rsync, e.g.:\n    ssh \(host)\n    scp ./file \(host):/workspace/\n    rsync -az ./dir/ \(host):/workspace/dir/\n\nThese connections verify the VM's pinned host key; a changed key is refused."
    )
  }
}

/// Editors that attach over SSH remote development.
package enum EditorKind: String, Sendable, CaseIterable {
  case code
  case zed
}

/// `iso editor`: install the alias, then try each launch strategy.
package struct EditorLauncher: Sendable {
  enum NonzeroExit {
    case editorFailure
    case launcherMiss
  }

  struct Strategy {
    let editor: EditorKind
    let nonzeroExit: NonzeroExit
    let name: String
    let command: String
    let arguments: [String]
  }

  static let codeHint =
    "To install the `code` CLI: open VS Code, Cmd+Shift+P, 'Shell Command: Install'"
  static let zedHint = "To install the `zed` CLI: open Zed, Cmd+Shift+P, 'cli: install'"

  /// Guest paths reach Zed inside a URL: escape what would end or reshape
  /// it (`#` would truncate the path as a fragment) and `%` itself.
  static func percentEncode(_ path: String) -> String {
    var out = ""
    for byte in path.utf8 {
      if byte < 0x20 || byte >= 0x7F || Array(" \"#%<>?`{}".utf8).contains(byte) {
        out += String(format: "%%%02X", byte)
      } else {
        out.unicodeScalars.append(Unicode.Scalar(byte))
      }
    }
    return out
  }

  static func strategies(_ editor: EditorKind?, host: String, path: GuestPath) -> [Strategy] {
    let code = [
      Strategy(
        editor: .code, nonzeroExit: .editorFailure, name: "code CLI", command: "code",
        arguments: ["--remote", "ssh-remote+\(host)", path.rawValue]),
      Strategy(
        editor: .code, nonzeroExit: .launcherMiss, name: "macOS open -a 'Visual Studio Code'",
        command: "open",
        arguments: [
          "-a", "Visual Studio Code", "--args", "--remote", "ssh-remote+\(host)", path.rawValue,
        ]),
    ]
    let encoded = percentEncode(path.rawValue)
    let zed = [
      Strategy(
        editor: .zed, nonzeroExit: .editorFailure, name: "zed CLI", command: "zed",
        arguments: ["ssh://\(host)\(encoded)"]),
      Strategy(
        editor: .zed, nonzeroExit: .launcherMiss, name: "macOS open zed:// URL", command: "open",
        arguments: ["zed://ssh/\(host)\(encoded)"]),
    ]
    switch editor {
    case .code: return code
    case .zed: return zed
    case nil: return code + zed
    }
  }

  static func hints(_ editor: EditorKind?) -> [String] {
    switch editor {
    case .code: [codeHint]
    case .zed: [zedHint]
    case nil: [codeHint, zedHint]
    }
  }

  let runner: ProcessRunner
  let environment: [String: String]
  let diagnostics: Diagnostics

  package init(
    runner: ProcessRunner = ProcessRunner(), environment: [String: String], diagnostics: Diagnostics
  ) {
    self.runner = runner
    self.environment = environment
    self.diagnostics = diagnostics
  }

  func resolve(_ command: String) -> String? {
    for directory in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":")
    where !directory.isEmpty {
      let candidate = "\(directory)/\(command)"
      if access(candidate, X_OK) == 0 { return candidate }
    }
    return nil
  }

  package func launch(_ running: AppleBackend.Running, path: GuestPath, editor: EditorKind?) throws
  {
    try launch(running.instance, path: path, editor: editor, target: running.target)
  }

  package func launch(_ instance: Instance, path: GuestPath, editor: EditorKind?) throws {
    try launch(instance, path: path, editor: editor, target: nil)
  }

  private func launch(
    _ instance: Instance, path: GuestPath, editor: EditorKind?, target: SSHTarget?
  ) throws {
    var tried: [String] = []
    var failedEditor: EditorKind?
    for strategy in Self.strategies(editor, host: SSHConfigFile.host(instance), path: path) {
      // A declining editor may still recover through its own launcher, but
      // a different editor must not open unexpectedly.
      if let failedEditor, failedEditor != strategy.editor { break }
      diagnostics.log(
        .info,
        "Trying \(strategy.name): \(strategy.command) \(strategy.arguments.joined(separator: " "))")
      guard let executable = resolve(strategy.command) else {
        diagnostics.debug("\(strategy.name): No such file or directory (os error 2)")
        tried.append("\(strategy.name) (No such file or directory (os error 2))")
        continue
      }
      try target?.requireHandoff()
      do {
        let termination = try runner.attached(
          .init(
            executable: executable, arguments: strategy.arguments, environment: environment,
            deadline: .seconds(300)), inheritStdin: true)
        if termination.succeeded { return }
        diagnostics.debug("\(strategy.name) exited with \(termination)")
        tried.append("\(strategy.name) exited with \(termination)")
        if strategy.nonzeroExit == .editorFailure { failedEditor = strategy.editor }
      } catch {
        diagnostics.debug("\(strategy.name): \(error)")
        tried.append("\(strategy.name) (\(error))")
      }
    }
    throw HostError(
      "Could not open an editor. Tried:\n\(tried.map { "  - \($0)" }.joined(separator: "\n"))\n\n\(Self.hints(editor).joined(separator: "\n"))"
    )
  }
}
