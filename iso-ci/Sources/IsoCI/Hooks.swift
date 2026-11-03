import ArgumentParser
import Foundation
import IsoCICore

extension GitHookKind: ExpressibleByArgument {}

/// Project Git hooks that run the project's own workflow through local
/// preflight before changes reach a protected branch.
struct Hooks: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Run a project's CI through local preflight from its Git hooks",
    discussion:
      "Hooks are project-scoped and meant to be committed (by default in .githooks). Existing hooks and hook managers are never overwritten without --force. Local preflight is Linux ARM64 only; hosted CI stays authoritative.",
    subcommands: [HooksInstall.self, HooksStatus.self, HooksUninstall.self])
}

struct HooksInstall: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "install",
    abstract: "Install a hook that runs a workflow before commits or pushes to one branch")

  @OptionGroup var global: GlobalOptions
  @Option(help: "Repository working directory (default: the current directory)")
  var repository: String?
  @Option(help: "pre-commit (checks the staged index) or pre-push (checks the pushed commit)")
  var hook: GitHookKind = .preCommit
  @Option(help: "Protected branch; other branches skip the hook") var branch = "main"
  @Option(help: "Repository-relative workflow file") var workflow = ".github/workflows/ci.yml"
  @Option(help: "Simulated triggering event") var event = "push"
  @Option(
    help: ArgumentHelp(
      "staged (exactly what is committed; refuses unstaged differences) or working-tree",
      valueName: "source"))
  var snapshot: SnapshotSource = .staged
  @Option(help: ArgumentHelp("Abort the run after this many seconds", valueName: "seconds"))
  var timeout = ManagedHookSettings.defaultTimeoutSeconds
  @Option(
    help:
      "Repository-relative hooks directory when core.hooksPath is not set (default: .githooks)")
  var directory: String?
  @Flag(help: "Replace an existing hook (kept as a backup) or override a configured hooks path")
  var force = false
  @Flag(name: .customLong("dry-run"), help: "Show what would change without changing anything")
  var dryRun = false

  func run() throws {
    try global.run { () throws(CIError) in
      let repo = try GitHooks.repository(containing: absolutePath(repository))
      let settings = ManagedHookSettings(
        hook: hook, branch: branch, workflow: workflow, event: event, snapshot: snapshot,
        timeoutSeconds: timeout)
      let plan = try GitHooks.planInstall(
        repository: repo, settings: settings, directory: directory, force: force)
      if !dryRun {
        try GitHooks.install(plan, git: try GitCommandConfigWriter(root: repo.layout.root))
      }
      var value: [String: JSONValue] = [
        "hook": .string(hook.rawValue), "path": .string(plan.hookPath),
        "replaced": .string(plan.existing.rawValue), "dry_run": .bool(dryRun),
        "branch": .string(branch), "workflow": .string(workflow),
        "snapshot": .string(snapshot.rawValue), "timeout_seconds": .integer(Int64(timeout)),
      ]
      if let hooksPath = plan.setsHooksPath { value["sets_hooks_path"] = .string(hooksPath) }
      if let backup = plan.backupPath { value["backup"] = .string(backup) }
      Output.emit(.object(value), json: global.json) { _ in
        let verb = dryRun ? "Would write" : (plan.existing == .managed ? "Updated" : "Installed")
        Output.line("\(verb) \(plan.hookPath)")
        if let backup = plan.backupPath {
          Output.line("\(dryRun ? "Would keep" : "Kept") the previous hook as \(backup)")
        }
        if let hooksPath = plan.setsHooksPath {
          Output.line(
            "\(dryRun ? "Would set" : "Set") git config --local core.hooksPath \(hooksPath)")
        }
        Output.line(
          "On \(branch), \(hook.rawValue) runs \(workflow) (\(snapshot.rawValue) snapshot, \(timeout) s limit); other branches skip it. Bypass once with --no-verify."
        )
        if snapshot == .workingTree {
          Output.line(
            "Note: a working-tree snapshot includes unstaged edits, so it does not check exactly what is committed."
          )
        }
        if dryRun {
          Output.line("--- \(plan.hookPath)")
          Output.line(plan.content)
        } else if plan.setsHooksPath != nil {
          Output.line(
            "Commit \(plan.hookPath) with the project; collaborators enable it with `git config --local core.hooksPath \(plan.setsHooksPath ?? "")`."
          )
        }
      }
    }
  }
}

struct HooksStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status", abstract: "Show the project's hooks directory and iso-ci hooks")

  @OptionGroup var global: GlobalOptions
  @Option(help: "Repository working directory (default: the current directory)")
  var repository: String?

  func run() throws {
    try global.run { () throws(CIError) in
      let repo = try GitHooks.repository(containing: absolutePath(repository))
      let hooks = try GitHooks.status(repo)
      let onPath = Self.onPath("iso-ci")
      let value: JSONValue = [
        "repository": .string(repo.layout.root),
        "hooks_directory": .string(repo.hooksDirectory),
        "hooks_path_source": .string(repo.hooksPathSource.rawValue),
        "iso_ci_on_path": .bool(onPath),
        "hooks": .array(
          hooks.map { status in
            var entry: [String: JSONValue] = [
              "hook": .string(status.hook.rawValue), "path": .string(status.path),
              "state": .string(status.state.rawValue), "backup": .bool(status.hasBackup),
            ]
            if let settings = status.settings {
              entry["branch"] = .string(settings.branch)
              entry["workflow"] = .string(settings.workflow)
              entry["event"] = .string(settings.event)
              entry["snapshot"] = .string(settings.snapshot.rawValue)
              entry["timeout_seconds"] = .integer(Int64(settings.timeoutSeconds))
            }
            return .object(entry)
          }),
      ]
      Output.emit(value, json: global.json) { _ in
        let source =
          switch repo.hooksPathSource {
          case .local: "core.hooksPath (repository)"
          case .global: "core.hooksPath (user or system Git config)"
          case .none: "Git's default"
          }
        Output.line("Repository: \(repo.layout.root)")
        Output.line("Hooks directory: \(repo.hooksDirectory) (\(source))")
        for status in hooks {
          switch status.state {
          case .absent: Output.line("\(status.hook.rawValue): not installed")
          case .unmanaged: Output.line("\(status.hook.rawValue): present, not managed by iso-ci")
          case .managed:
            let settings = status.settings
            Output.line(
              "\(status.hook.rawValue): iso-ci on \(settings?.branch ?? "?") runs \(settings?.workflow ?? "?") (\(settings?.snapshot.rawValue ?? "?") snapshot, \(settings?.timeoutSeconds ?? 0) s limit)\(status.hasBackup ? "; previous hook kept as backup" : "")"
            )
          }
        }
        if !onPath {
          Output.line(
            "Warning: iso-ci is not on PATH; a managed hook fails on its protected branch until it is (or ISO_CI is set)."
          )
        }
      }
    }
  }

  static func onPath(_ name: String) -> Bool {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    return path.split(separator: ":").contains { access("\($0)/\(name)", X_OK) == 0 }
  }
}

struct HooksUninstall: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "uninstall",
    abstract: "Remove iso-ci hooks, restoring any hook they replaced")

  @OptionGroup var global: GlobalOptions
  @Option(help: "Repository working directory (default: the current directory)")
  var repository: String?
  @Option(help: "Only this hook (default: every iso-ci hook)") var hook: GitHookKind?

  func run() throws {
    try global.run { () throws(CIError) in
      let repo = try GitHooks.repository(containing: absolutePath(repository))
      let result = try GitHooks.uninstall(
        repo, hooks: hook.map { [$0] } ?? GitHookKind.allCases,
        git: try GitCommandConfigWriter(root: repo.layout.root))
      let value: JSONValue = [
        "removed": .array(result.removed.map(JSONValue.string)),
        "restored": .array(result.restored.map(JSONValue.string)),
        "skipped_unmanaged": .array(result.skipped.map(JSONValue.string)),
        "unset_hooks_path": .bool(result.unsetHooksPath),
      ]
      Output.emit(value, json: global.json) { _ in
        if result.removed.isEmpty { Output.line("No iso-ci hooks to remove") }
        for path in result.removed { Output.line("Removed \(path)") }
        for path in result.restored { Output.line("Restored the previous hook at \(path)") }
        for path in result.skipped { Output.line("Left \(path): not managed by iso-ci") }
        if result.unsetHooksPath { Output.line("Unset core.hooksPath (iso-ci had set it)") }
      }
    }
  }
}
