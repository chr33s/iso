// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// `iso uninstall`: remove this binary and, unless `--keep-data`, the
/// owned backend state (`<data_dir>/backends/apple-container-v1`) and the
/// update-check state. Configuration and unrelated files under `data_dir`
/// are never removed. This build's SSH config blocks are always stripped.
package struct Uninstaller {
  package struct Options: Sendable, Equatable {
    package var yes: Bool
    package var keepData: Bool
    package var purge: Bool

    package init(yes: Bool = false, keepData: Bool = false, purge: Bool = false) {
      self.yes = yes
      self.keepData = keepData
      self.purge = purge
    }
  }

  package let backend: AppleBackend
  package let configPath: String
  package let home: String?
  /// The running binary (`_NSGetExecutablePath`, as Rust `current_exe`).
  package let binaryPath: String?
  package let stdinIsTerminal: Bool
  let environment: [String: String]
  let confirm: (String) throws -> Bool
  let runner: ProcessRunner
  /// Per-instance teardown before destroy (port forwards, credential proxy).
  package var teardown: (Instance) -> Void = { _ in }

  var config: IsoConfig { backend.config }
  var diagnostics: Diagnostics { backend.diagnostics }

  package init(
    backend: AppleBackend, configPath: String, home: String?, binaryPath: String?,
    environment: [String: String], stdinIsTerminal: Bool = Prompt.stdinIsTerminal,
    confirm: @escaping (String) throws -> Bool = Prompt.confirm,
    runner: ProcessRunner = ProcessRunner()
  ) {
    self.backend = backend
    self.configPath = configPath
    self.home = home
    self.binaryPath = binaryPath
    self.environment = environment
    self.stdinIsTerminal = stdinIsTerminal
    self.confirm = confirm
    self.runner = runner
  }

  /// The directory `--purge` may remove wholesale: backend state only.
  var ownedDataDirectory: String { config.stateRoot.path }

  package func run(_ options: Options) throws {
    guard let binaryPath else {
      throw HostError("Failed to resolve current executable path for removal")
    }
    diagnostics.debug("Resolved binary path: \(binaryPath)")
    if !options.yes && !stdinIsTerminal {
      throw HostError(
        "stdin is not a TTY; pass --yes (and optionally --keep-data or --purge) for non-interactive uninstall."
      )
    }
    printSummary(binaryPath)
    if !options.yes, try !confirm("Remove iso binary at \(binaryPath)?") {
      diagnostics.log(.info, "Uninstall cancelled")
      return
    }
    if try decideRemoveData(options) {
      try purgeAllData()
      wipe(ownedDataDirectory, failure: .warn("Failed to remove data dir"))
      do { try UpdateCheck.removeState(home: home, diagnostics: diagnostics) } catch {
        diagnostics.debug("Failed to remove update-check state (non-fatal): \(error)")
      }
      if !Self.configPathIsUnderDataDirectory(configPath, ownedDataDirectory),
        pathExists(configPath)
      {
        diagnostics.log(
          .info, "Config at \(configPath) is outside the data directory and was not removed")
      }
    } else {
      do {
        try SSHConfigBlocks.removeAll(
          at: SSHConfigBlocks.path(home: home), diagnostics: diagnostics)
      } catch {
        diagnostics.debug("SSH config cleanup failed (non-fatal): \(error)")
      }
      if pathExists(ownedDataDirectory) {
        diagnostics.log(
          .info, "Keeping \(ownedDataDirectory); reinstall iso to manage existing instances.")
      }
    }
    try removeSelfBinary(binaryPath)
    diagnostics.log(
      .info,
      "iso uninstalled. To reinstall: curl -fsSL https://raw.githubusercontent.com/chr33s/iso/main/install.sh | sh"
    )
  }

  func counts() -> (instances: Int, images: Int) {
    let instances = (try? listInstances().count) ?? 0
    let images = (try? ImageStore.list(config).count) ?? 0
    return (instances, images)
  }

  func listInstances() throws -> [Instance] {
    try InstanceStore.list(config) { path, error in
      diagnostics.warn(
        "Skipping corrupted instance dir \(path) (\(error)). Remove it manually or run `destroy --all`."
      )
    }
  }

  func printSummary(_ binaryPath: String) {
    let (instances, images) = counts()
    diagnostics.log(.info, "This will remove:")
    diagnostics.log(.info, "  binary:    \(binaryPath)")
    if pathExists(ownedDataDirectory) {
      diagnostics.log(
        .info,
        "  data dir:  \(ownedDataDirectory) (\(instances) instance(s), \(images) image(s))")
    } else {
      diagnostics.log(.info, "  data dir:  \(ownedDataDirectory) (already absent)")
    }
  }

  /// Flags decide without prompting; otherwise the confirmer answers.
  func decideRemoveData(_ options: Options) throws -> Bool {
    if options.keepData { return false }
    if options.yes || options.purge { return true }
    let (instances, images) = counts()
    return try confirm(
      "Also remove data directory \(ownedDataDirectory) (\(instances) instance(s), \(images) image(s))?"
    )
  }

  /// Destroy every instance and image through the backend, then remove the
  /// VM key, the instances directory and this build's SSH config blocks.
  func purgeAllData() throws {
    for instance in try listInstances() {
      diagnostics.log(.info, "Destroying instance '\(instance.name)'")
      teardown(instance)
      try backend.destroyInstance(instance)
      try SSHConfigBlocks.remove(
        host: SSHConfigBlocks.host(for: instance.name), instanceName: instance.name.rawValue,
        at: SSHConfigBlocks.path(home: home), diagnostics: diagnostics)
    }
    backend.destroyShared()
    for suffix in ["", ".pub"] where unlink(config.sshKeyPath.path + suffix) != 0 {
      diagnostics.debug(
        "Failed to remove SSH \(suffix.isEmpty ? "private" : "public") key (non-fatal): \(rustIOError(errno))"
      )
    }
    wipe(config.instancesDirectory.path, failure: .debug("Failed to remove instances dir"))
    try SSHConfigBlocks.removeAll(at: SSHConfigBlocks.path(home: home), diagnostics: diagnostics)
  }

  enum WipeFailure {
    case warn(String)
    case debug(String)
  }

  /// Remove a directory tree; fall back to `sudo rm -rf` (baseline), and
  /// report a final failure as non-fatal.
  func wipe(_ directory: String, failure: WipeFailure) {
    guard pathExists(directory) else { return }
    do { try FileManager.default.removeItem(atPath: directory) } catch {
      diagnostics.debug("User remove_dir_all failed, trying sudo: \(error)")
      do { try sudoRemove(directory) } catch {
        switch failure {
        case .warn(let message):
          diagnostics.warn("\(message) \(directory) (non-fatal): \(error)")
        case .debug(let message):
          diagnostics.debug("\(message) \(directory) (non-fatal): \(error)")
        }
      }
    }
  }

  func sudoRemove(_ directory: String) throws {
    let tools = UpdateTools(environment: environment, runner: runner, diagnostics: diagnostics)
    try tools.run("sudo", ["rm", "-rf", directory])
  }

  func removeSelfBinary(_ path: String) throws {
    if Self.isDevTargetPath(path) {
      diagnostics.warn(
        "Refusing to remove \(path) — looks like a build artifact (under .build/ or target/). Delete it with the build tree if you really want to remove it."
      )
      return
    }
    guard unlink(path) == 0 else {
      let code = errno
      if code == EACCES || code == EPERM {
        throw HostError("Cannot remove \(path): \(rustIOError(code)). Try `sudo iso uninstall`.")
      }
      throw ContextError("Failed to remove binary at \(path)", cause: HostError(rustIOError(code)))
    }
  }

  /// A build-output binary: consecutive `target/{debug,release}` (cargo) or
  /// `.build/{debug,release}` / `.build/<triple>/{debug,release}` (SwiftPM).
  static func isDevTargetPath(_ path: String) -> Bool {
    let components = path.split(separator: "/").map(String.init)
    let profile: (String) -> Bool = { $0 == "debug" || $0 == "release" }
    for index in components.indices.dropLast() {
      let next = components[index + 1]
      if components[index] == "target" && profile(next) { return true }
      if components[index] == ".build" {
        if profile(next) { return true }
        if index + 2 < components.count && profile(components[index + 2]) { return true }
      }
    }
    return false
  }

  /// Canonical comparison when both sides resolve; lexical when neither
  /// does; "can't tell" (true, suppressing the notice) when only one does.
  static func configPathIsUnderDataDirectory(_ configPath: String, _ dataDirectory: String) -> Bool
  {
    switch (canonical(configPath), canonical(dataDirectory)) {
    case (let config?, let data?): return componentsStart(config, with: data)
    case (nil, nil): return componentsStart(configPath, with: dataDirectory)
    default: return true
    }
  }

  static func canonical(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  /// Rust `Path::starts_with`: whole components only.
  static func componentsStart(_ path: String, with prefix: String) -> Bool {
    func components(_ text: String) -> [Substring] {
      var parts = text.split(separator: "/").filter { $0 != "." }
      if text.hasPrefix("/") { parts.insert("/", at: 0) }
      return parts
    }
    let whole = components(path)
    let head = components(prefix)
    return whole.starts(with: head)
  }
}

/// iso-owned blocks in the user's shared SSH configuration.
package enum SSHConfigBlocks {
  package static let markerPrefix = "# iso START"
  package static let markerEnd = "# iso END"
  package static let hostAliasPrefix = "iso-"

  package static func host(for name: InstanceName) -> String { hostAliasPrefix + name.rawValue }

  package static func path(home: String?) throws -> String {
    guard let home, !home.isEmpty else { throw HostError("Could not determine home directory") }
    return home + "/.ssh/config"
  }

  /// Every block from `markerPrefix` through `markerEnd` removed.
  package static func removeMarkerBlocks(_ content: String) -> String {
    filter(content) { line in line.hasPrefix(markerPrefix) }
  }

  /// Only the block for `host`.
  package static func removeNamedMarkerBlock(_ content: String, host: String) -> String {
    let marker = "\(markerPrefix) \(host)"
    return filter(content, endOnlyInBlock: true) { $0 == marker }
  }

  private static func filter(
    _ content: String, endOnlyInBlock: Bool = false, starts: (String) -> Bool
  ) -> String {
    var result = ""
    var inBlock = false
    for raw in rustLines(content) {
      let line = raw.trimmingUnicodeWhitespace()
      if starts(line) {
        inBlock = true
        continue
      }
      if (!endOnlyInBlock || inBlock) && line == markerEnd {
        inBlock = false
        continue
      }
      if !inBlock { result += raw + "\n" }
    }
    var trimmed = Substring(result)
    while trimmed.utf8.last == UInt8(ascii: "\n") { trimmed = trimmed.dropLast() }
    return trimmed.isEmpty ? "" : trimmed + "\n"
  }

  /// SSH uses the first matching Host; never shadow an explicit user alias.
  package static func checkAliasAvailable(_ content: String, host: String) throws {
    let unmanaged = removeMarkerBlocks(content)
    for line in rustLines(unmanaged) {
      let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
      guard fields.first?.lowercased() == "host" else { continue }
      if fields.dropFirst().contains(where: { $0.lowercased() == host.lowercased() }) {
        throw HostError(
          "~/.ssh/config already defines '\(host)' outside an iso block; choose another instance name or remove that entry"
        )
      }
    }
  }

  /// Strip every block of this build; rewrite only when something changed.
  package static func removeAll(at path: String, diagnostics: Diagnostics) throws {
    if try rewrite(path, removeMarkerBlocks) {
      diagnostics.log(.info, "Removed iso SSH config blocks")
    }
  }

  /// Strip one instance's block; rewrite only when it was present.
  package static func remove(
    host: String, instanceName: String, at path: String, diagnostics: Diagnostics
  ) throws {
    if try rewrite(path, { removeNamedMarkerBlock($0, host: host) }) {
      diagnostics.log(.info, "Removed SSH config block for instance '\(instanceName)'")
    }
  }

  /// Whether the file was rewritten.
  private static func rewrite(_ path: String, _ clean: (String) -> String) throws -> Bool {
    guard pathExists(path) else { return false }
    let content: String
    do { content = try readUTF8(path) } catch {
      throw ContextError("Failed to read ~/.ssh/config", cause: error)
    }
    let cleaned = clean(content)
    guard cleaned.utf8.count != content.utf8.count else { return false }
    do { try ReplaceFile.write(Array(cleaned.utf8), to: path, newFileMode: 0o600) } catch {
      throw ContextError("Failed to write ~/.ssh/config", cause: error)
    }
    return true
  }
}
