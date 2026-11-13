import Darwin
import Foundation

package enum GitHookKind: String, Sendable, Equatable, Codable, CaseIterable {
  case preCommit = "pre-commit"
  /// Runs before a push to the protected branch, against the checked-out
  /// commit (refused when it is not what is being pushed).
  case prePush = "pre-push"
}

/// What a managed hook runs. Everything is project-scoped: the hook file is
/// meant to be committed with the project, so it names no host path.
package struct ManagedHookSettings: Sendable, Equatable, Codable {
  package static let defaultTimeoutSeconds = 1_800

  package var hook: GitHookKind
  package var branch: String
  package var workflow: String
  package var event: String
  package var snapshot: SnapshotSource
  package var timeoutSeconds: Int

  package init(
    hook: GitHookKind, branch: String = "main", workflow: String = ".github/workflows/ci.yml",
    event: String = "push", snapshot: SnapshotSource = .staged,
    timeoutSeconds: Int = Self.defaultTimeoutSeconds
  ) {
    self.hook = hook
    self.branch = branch
    self.workflow = workflow
    self.event = event
    self.snapshot = snapshot
    self.timeoutSeconds = timeoutSeconds
  }

  /// Refuses values that are not plain branch names, repository-relative
  /// paths or event names; the script quotes them, but nothing unusual
  /// should reach it in the first place.
  package func validate() throws(CIError) {
    let branchScalars = branch.unicodeScalars
    guard !branch.isEmpty, branch.utf8.count <= 200, !branch.hasPrefix("-"),
      !branch.hasPrefix("/"), !branch.hasSuffix("/"), !branch.hasSuffix(".lock"),
      !branch.contains(".."), !branch.contains("//"), !branch.contains("@{"),
      branchScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" })
    else { throw CIError.invalid("--branch must be a plain branch name, for example main") }
    let parts = workflow.split(separator: "/", omittingEmptySubsequences: false)
    guard !workflow.isEmpty, workflow.utf8.count <= 1_024, !workflow.hasPrefix("/"),
      !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
      workflow.unicodeScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" }),
      workflow.hasSuffix(".yml") || workflow.hasSuffix(".yaml")
    else {
      throw CIError.invalid(
        "--workflow must be a repository-relative .yml or .yaml path, for example .github/workflows/ci.yml"
      )
    }
    guard !event.isEmpty, event.utf8.count <= 64,
      event.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || $0 == "_" })
    else { throw CIError.invalid("--event must be a GitHub event name, for example push") }
    guard (1...86_400).contains(timeoutSeconds) else {
      throw CIError.invalid("--timeout must be between 1 and 86400 seconds")
    }
  }
}

/// Installs, reports and removes `iso-ci` Git hooks in a project. Nothing
/// is overwritten silently: an existing hook that iso-ci did not write, a
/// hooks directory another tool configured, or active hooks that switching
/// `core.hooksPath` would disable all refuse the install unless forced, and
/// a forced replacement keeps a backup that uninstall restores.
package enum GitHooks {
  package static let marker = "# iso-ci managed hook v1"
  static let settingsPrefix = "# iso-ci-settings: "
  /// Local config key recording the `core.hooksPath` iso-ci itself set, so
  /// uninstall only unsets what it configured.
  static let ownedHooksPathKey = "iso-ci.hooksPath"
  static let defaultDirectory = ".githooks"

  // MARK: Script

  package static func script(_ settings: ManagedHookSettings) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = (try? encoder.encode(settings)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    let hook = settings.hook.rawValue
    let selector: String
    switch settings.hook {
    case .preCommit:
      selector = """
        current=$(git symbolic-ref --quiet --short HEAD || true)
        [ "$current" = "$branch" ] || exit 0
        """
    case .prePush:
      selector = """
        protected=0
        head=$(git rev-parse --verify --quiet HEAD || true)
        while read -r local_ref local_sha remote_ref remote_sha; do
          [ "$remote_ref" = "refs/heads/$branch" ] || continue
          case "$local_sha" in *[!0]*) ;; *) continue ;; esac  # a deletion
          protected=1
          if [ "$local_sha" != "$head" ]; then
            printf '%s: iso-ci checks the checked-out commit; check out %s before pushing it to %s\\n' \\
              "$hook" "$local_sha" "$branch" >&2
            exit 1
          fi
        done
        [ "$protected" = 1 ] || exit 0
        if ! git diff --cached --quiet; then
          printf '%s: staged changes are not part of the pushed commit; commit or unstage them first\\n' \\
            "$hook" >&2
          exit 1
        fi
        """
    }
    return """
      #!/bin/sh
      \(marker)
      \(settingsPrefix)\(json)
      #
      # Runs this project's GitHub Actions workflow locally in disposable ISO
      # VMs (iso-ci local preflight) before changes reach the protected
      # branch. Linux ARM64 only: hosted CI stays authoritative.
      # Manage with `iso-ci hooks install|status|uninstall`; bypass once
      # with --no-verify. Set ISO_CI to the iso-ci executable when it is not
      # on the PATH Git gives hooks.
      set -eu
      hook=\(shellQuote(hook))
      branch=\(shellQuote(settings.branch))
      workflow=\(shellQuote(settings.workflow))
      event=\(shellQuote(settings.event))
      snapshot=\(shellQuote(settings.snapshot.rawValue))
      timeout=\(settings.timeoutSeconds)

      \(selector)

      cd "$(git rev-parse --show-toplevel)"
      iso_ci=${ISO_CI:-iso-ci}
      if ! command -v "$iso_ci" >/dev/null 2>&1; then
        printf '%s: iso-ci is required for changes to %s; see https://github.com/chr33s/iso/blob/main/docs/ci.md (or set ISO_CI)\\n' \\
          "$hook" "$branch" >&2
        exit 1
      fi
      if [ ! -f "$workflow" ]; then
        printf '%s: missing workflow %s\\n' "$hook" "$workflow" >&2
        exit 1
      fi
      printf '%s: running %s in disposable ISO VMs (%s snapshot, %ss limit)\\n' \\
        "$hook" "$workflow" "$snapshot" "$timeout" >&2
      exec "$iso_ci" run "$workflow" --event "$event" --snapshot "$snapshot" --follow \\
        --timeout "$timeout"

      """
  }

  package static func settings(fromScript text: String) -> ManagedHookSettings? {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count > 2, lines[1] == Substring(marker),
      lines[2].hasPrefix(settingsPrefix)
    else { return nil }
    let json = lines[2].dropFirst(settingsPrefix.count)
    return try? JSONDecoder().decode(ManagedHookSettings.self, from: Data(json.utf8))
  }

  static func shellQuote(_ value: String) -> String {
    shellSingleQuoted(value)
  }

  // MARK: Hooks directory

  package enum HooksPathSource: String, Sendable, Equatable {
    case local
    case global
    case none
  }

  package struct Repository: Sendable, Equatable {
    package let layout: GitIndex.Layout
    package let hooksPath: String?
    package let hooksPathSource: HooksPathSource
    package let ownedHooksPath: String?

    package var hooksDirectory: String {
      guard let hooksPath else { return layout.commonDirectory + "/hooks" }
      return GitHooks.resolve(hooksPath, root: layout.root)
    }
  }

  package static func repository(
    containing path: String, environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws(CIError) -> Repository {
    let layout = try GitIndex.layout(containing: path)
    let local = try configValue(layout.commonDirectory + "/config", "hooksPath")
    let owned = try configValue(layout.commonDirectory + "/config", "hooksPath", section: "iso-ci")
    if let local {
      return Repository(
        layout: layout, hooksPath: local, hooksPathSource: .local, ownedHooksPath: owned)
    }
    let home = environment["HOME"] ?? NSHomeDirectory()
    let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
    for file in [
      home + "/.gitconfig", (xdg ?? home + "/.config") + "/git/config", "/etc/gitconfig",
    ] {
      if let global = try configValue(file, "hooksPath") {
        return Repository(
          layout: layout, hooksPath: global, hooksPathSource: .global, ownedHooksPath: owned)
      }
    }
    return Repository(layout: layout, hooksPath: nil, hooksPathSource: .none, ownedHooksPath: owned)
  }

  static func configValue(_ file: String, _ key: String, section: String = "core")
    throws(CIError) -> String?
  {
    guard let bytes = try? PrivateFiles.read(file, limit: GitIndex.maxConfigBytes) else {
      return nil
    }
    return GitConfigFile.lastValue(bytes, section: section, subsection: nil, key: key)
  }

  static func resolve(_ value: String, root: String) -> String {
    if value.hasPrefix("/") { return (value as NSString).standardizingPath }
    if value == "~" || value.hasPrefix("~/") {
      return (NSHomeDirectory() + value.dropFirst()) as String
    }
    return ((root + "/" + value) as NSString).standardizingPath
  }

  // MARK: Install

  package enum Existing: String, Sendable, Equatable {
    case absent, managed, unmanaged
  }

  package struct InstallPlan: Sendable, Equatable {
    package let repository: Repository
    package let settings: ManagedHookSettings
    package let hooksDirectory: String
    package let hookPath: String
    package let existing: Existing
    package let setsHooksPath: String?
    package let backupPath: String?
    package let content: String
  }

  package static func planInstall(
    repository: Repository, settings: ManagedHookSettings, directory: String?, force: Bool
  ) throws(CIError) -> InstallPlan {
    try settings.validate()
    let root = repository.layout.root
    var workflowStatus = stat()
    guard lstat(root + "/" + settings.workflow, &workflowStatus) == 0,
      workflowStatus.st_mode & S_IFMT == S_IFREG
    else { throw CIError(.notFound, "workflow \(settings.workflow) does not exist in \(root)") }
    if let directory {
      let parts = directory.split(separator: "/", omittingEmptySubsequences: false)
      guard !directory.isEmpty, !directory.hasPrefix("/"),
        !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
        parts.first != ".git"
      else {
        throw CIError.invalid(
          "--directory must be a repository-relative path, for example .githooks")
      }
    }
    var setsHooksPath: String?
    let hooksDirectory: String
    switch repository.hooksPathSource {
    case .local:
      let current = repository.hooksDirectory
      if let directory, resolve(directory, root: root) != current, !force {
        throw CIError(
          .conflict,
          "core.hooksPath is already \(repository.hooksPath ?? ""); install there (omit --directory) or pass --force to re-point it"
        )
      }
      if let directory, resolve(directory, root: root) != current {
        setsHooksPath = directory
        hooksDirectory = resolve(directory, root: root)
      } else {
        hooksDirectory = current
      }
    case .global:
      guard force else {
        throw CIError(
          .conflict,
          "your Git configuration sets core.hooksPath to \(repository.hooksPath ?? ""); a project hooks directory would bypass those hooks for this repository. Pass --force to set a local core.hooksPath anyway"
        )
      }
      setsHooksPath = directory ?? defaultDirectory
      hooksDirectory = resolve(setsHooksPath!, root: root)
    case .none:
      let active = activeHooks(in: repository.layout.commonDirectory + "/hooks")
      guard active.isEmpty || force else {
        throw CIError(
          .conflict,
          "setting core.hooksPath would disable the active hooks in .git/hooks (\(active.joined(separator: ", "))); move them into the project hooks directory first, or pass --force"
        )
      }
      setsHooksPath = directory ?? defaultDirectory
      hooksDirectory = resolve(setsHooksPath!, root: root)
    }
    let hookPath = hooksDirectory + "/" + settings.hook.rawValue
    let existing = try existingHook(hookPath)
    var backupPath: String?
    if existing == .unmanaged {
      guard force else {
        throw CIError(
          .conflict,
          "\(hookPath) exists and was not written by iso-ci; call iso-ci from it yourself, or pass --force to replace it (it is kept as \(settings.hook.rawValue).iso-ci-backup)"
        )
      }
      let backup = hookPath + ".iso-ci-backup"
      var status = stat()
      guard lstat(backup, &status) != 0 else {
        throw CIError(.conflict, "\(backup) already exists; remove it first")
      }
      backupPath = backup
    }
    return InstallPlan(
      repository: repository, settings: settings, hooksDirectory: hooksDirectory,
      hookPath: hookPath, existing: existing, setsHooksPath: setsHooksPath,
      backupPath: backupPath, content: script(settings))
  }

  /// Carries out `plan`. `git` sets `core.hooksPath` in the repository's own
  /// configuration when the plan needs it.
  package static func install(_ plan: InstallPlan, git: GitConfigWriter) throws(CIError) {
    do {
      try FileManager.default.createDirectory(
        atPath: plan.hooksDirectory, withIntermediateDirectories: true)
    } catch {
      throw CIError.storage("cannot create \(plan.hooksDirectory)")
    }
    if let backup = plan.backupPath {
      guard rename(plan.hookPath, backup) == 0 else {
        throw CIError.storage("cannot move \(plan.hookPath) to \(backup)")
      }
    }
    try writeExecutable(Array(plan.content.utf8), to: plan.hookPath)
    if let hooksPath = plan.setsHooksPath {
      try git.set("core.hooksPath", hooksPath)
      try git.set(ownedHooksPathKey, hooksPath)
    }
  }

  // MARK: Status

  package struct HookStatus: Sendable, Equatable {
    package let hook: GitHookKind
    package let path: String
    package let state: Existing
    package let settings: ManagedHookSettings?
    package let hasBackup: Bool
  }

  package static func status(_ repository: Repository) throws(CIError) -> [HookStatus] {
    let directory = repository.hooksDirectory
    var result: [HookStatus] = []
    for hook in GitHookKind.allCases {
      let path = directory + "/" + hook.rawValue
      let state = try existingHook(path)
      var parsed: ManagedHookSettings?
      if state == .managed, let bytes = try? PrivateFiles.read(path, limit: 1 << 16) {
        parsed = Self.settings(fromScript: String(decoding: bytes, as: UTF8.self))
      }
      var backup = stat()
      result.append(
        HookStatus(
          hook: hook, path: path, state: state, settings: parsed,
          hasBackup: lstat(path + ".iso-ci-backup", &backup) == 0))
    }
    return result
  }

  // MARK: Uninstall

  package struct UninstallResult: Sendable, Equatable {
    package var removed: [String] = []
    package var restored: [String] = []
    package var skipped: [String] = []
    package var unsetHooksPath = false
  }

  /// Removes the managed `hooks` (restoring any backup), and unsets the
  /// `core.hooksPath` iso-ci set once its directory holds no other hook.
  package static func uninstall(
    _ repository: Repository, hooks: [GitHookKind], git: GitConfigWriter
  ) throws(CIError) -> UninstallResult {
    var result = UninstallResult()
    let directory = repository.hooksDirectory
    for hook in hooks {
      let path = directory + "/" + hook.rawValue
      switch try existingHook(path) {
      case .absent: continue
      case .unmanaged:
        result.skipped.append(path)
        continue
      case .managed:
        guard unlink(path) == 0 else { throw CIError.storage("cannot remove \(path)") }
        result.removed.append(path)
        let backup = path + ".iso-ci-backup"
        var status = stat()
        if lstat(backup, &status) == 0 {
          guard rename(backup, path) == 0 else {
            throw CIError.storage("cannot restore \(backup)")
          }
          result.restored.append(path)
        }
      }
    }
    if repository.hooksPathSource == .local, let owned = repository.ownedHooksPath,
      owned == repository.hooksPath, activeHooks(in: directory).isEmpty
    {
      try git.unset("core.hooksPath")
      try git.unset(ownedHooksPathKey)
      rmdir(directory)  // only when empty
      result.unsetHooksPath = true
    }
    return result
  }

  // MARK: Helpers

  static func existingHook(_ path: String) throws(CIError) -> Existing {
    var status = stat()
    guard lstat(path, &status) == 0 else { return .absent }
    guard status.st_mode & S_IFMT == S_IFREG,
      let bytes = try? PrivateFiles.read(path, limit: 1 << 16)
    else { return .unmanaged }
    return settings(fromScript: String(decoding: bytes, as: UTF8.self)) != nil
      ? .managed : .unmanaged
  }

  static func activeHooks(in directory: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return names.filter { name in
      guard !name.hasSuffix(".sample"), !name.hasSuffix(".iso-ci-backup"),
        !name.hasPrefix(".")
      else { return false }
      return access(directory + "/" + name, X_OK) == 0
    }.sorted()
  }

  static func writeExecutable(_ bytes: [UInt8], to path: String) throws(CIError) {
    try PrivateFiles.write(bytes, to: path, mode: 0o755)
    guard chmod(path, 0o755) == 0 else { throw CIError.storage("cannot make \(path) executable") }
  }
}

package protocol GitConfigWriter {
  func set(_ key: String, _ value: String) throws(CIError)
  func unset(_ key: String) throws(CIError)
}

package struct GitCommandConfigWriter: GitConfigWriter {
  let git: String
  let root: String

  package init(root: String) throws(CIError) {
    guard let git = Subprocess.which("git") else {
      throw CIError(.capabilityMissing, "git is required to set core.hooksPath")
    }
    self.git = git
    self.root = root
  }

  package func set(_ key: String, _ value: String) throws(CIError) {
    try run(["config", "--local", key, value])
  }

  package func unset(_ key: String) throws(CIError) {
    try run(["config", "--local", "--unset-all", key])
  }

  private func run(_ arguments: [String]) throws(CIError) {
    let output = try Subprocess.run(
      .init(
        executable: git, arguments: ["-C", root] + arguments,
        environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]))
    guard output.status == 0 else {
      throw CIError(
        .internalError,
        "git config \(arguments.dropFirst(2).first ?? "") failed: \(String(decoding: output.stderr.prefix(300), as: UTF8.self))"
      )
    }
  }
}
