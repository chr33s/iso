import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

extension EditorProviderID: ExpressibleByArgument {}

/// The options every project-aware editor command adds to `ProjectArguments`.
struct EditorLaunchOptions: ParsableArguments {
  @Option(help: "Remote path to open in the editor") var project = "/workspace"
  @Flag(help: "Prepare the instance and SSH alias without starting the editor") var noLaunch = false

  func guestPath() throws -> GuestPath { try parseProjectGuestPath(project) }
}

/// `--project` of `iso code`, `iso zed` and `iso editor`.
func parseProjectGuestPath(_ project: String) throws -> GuestPath {
  do {
    return try GuestPath.absolute(project)
  } catch {
    throw UsageError("--project must be an absolute guest path: \(debugQuoted(project))")
  }
}

/// A top-level command that opens one editor provider on a project.
protocol ProjectEditorCommand: MachineCommand {
  static var provider: EditorProviderID { get }
  var global: GlobalOptions { get }
  var projectArguments: ProjectArguments { get }
  var launchOptions: EditorLaunchOptions { get }
}

extension ProjectEditorCommand {
  static func editorConfiguration(_ name: String) -> CommandConfiguration {
    CommandConfiguration(
      commandName: name,
      abstract:
        "Ensure an environment for a project directory is running and open it in \(provider.provider.displayName)",
      discussion:
        "Creates, restarts or reuses the instance exactly as `iso up` does, refreshes the pinned `iso-<name>` SSH alias, then launches only this editor; it never falls back to another one."
    )
  }

  func validate() throws { _ = try launchOptions.guestPath() }

  /// `--project` is a guest path. A directory under the host home almost
  /// certainly meant DIR, and falling back to the current directory would copy
  /// it into the guest. Other paths (`/tmp`, `/opt`) are ordinary guest paths.
  func rejectHostHomeProject(_ path: GuestPath, home: String?) throws {
    var isDirectory: ObjCBool = false
    if projectArguments.dir == nil, projectArguments.gitRepo == nil, let home,
      path.rawValue == home || path.rawValue.hasPrefix(home + "/"),
      FileManager.default.fileExists(atPath: path.rawValue, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      throw UsageError(
        "--project is the guest path to open, but \(debugQuoted(path.rawValue)) is a directory in your home folder. Pass the project directory as DIR (`iso \(Self.machineName) \(path.rawValue)`), or give DIR as well to open that guest path."
      )
    }
  }

  func run() throws {
    try IsoCLI.run(global, Self.self) { () -> MachineEditorResult? in
      let provider = Self.provider.provider
      let guestPath = try launchOptions.guestPath()
      let context = try projectArguments.loadContext(global)
      try rejectHostHomeProject(guestPath, home: context.environment.home)
      let workflow = ProjectEditorWorkflow(
        up: try projectArguments.workflow(context, global: global, command: Self.machineName),
        launcher: EditorLauncher(
          environment: context.environment.variables, diagnostics: context.diagnostics))
      let outcome = try workflow.run(
        provider, guestPath: guestPath, mode: launchOptions.noLaunch ? .prepareOnly : .launch)
      guard global.output == .json else { return nil }
      return MachineEditorResult(
        outcome,
        workspace: WorkspaceState.loadOrWarn(
          outcome.up.instance, consequence: "the result reports no workspace",
          diagnostics: context.diagnostics))
    }
  }
}

struct CodeCommand: ProjectEditorCommand {
  static let provider = EditorProviderID.code
  static let configuration = editorConfiguration("code")

  @OptionGroup var global: GlobalOptions
  @OptionGroup var projectArguments: ProjectArguments
  @OptionGroup var launchOptions: EditorLaunchOptions
}

struct ZedCommand: ProjectEditorCommand {
  static let provider = EditorProviderID.zed
  static let configuration = editorConfiguration("zed")

  @OptionGroup var global: GlobalOptions
  @OptionGroup var projectArguments: ProjectArguments
  @OptionGroup var launchOptions: EditorLaunchOptions
}
