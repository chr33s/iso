import Foundation
import IsoCore

/// `iso code` / `iso zed`: `iso up`'s project lifecycle, then the managed
/// alias, then one explicitly selected editor provider. Lifecycle stays in
/// `UpWorkflow`; this adds only the editor handoff.
package struct ProjectEditorWorkflow {
  package let up: UpWorkflow
  package let launcher: EditorLauncher

  package init(up: UpWorkflow, launcher: EditorLauncher) {
    self.up = up
    self.launcher = launcher
  }

  /// What the workflow settled on; no key material or workload state.
  package struct Outcome: Sendable {
    package let up: UpOutcome
    package let alias: SSHAlias
    package let provider: EditorProviderID
    package let launchTarget: String
    package let warnings: [String]
    package let mode: EditorLaunchMode

    package init(
      up: UpOutcome, alias: SSHAlias, provider: EditorProviderID, launchTarget: String,
      warnings: [String], mode: EditorLaunchMode
    ) {
      self.up = up
      self.alias = alias
      self.provider = provider
      self.launchTarget = launchTarget
      self.warnings = warnings
      self.mode = mode
    }
  }

  package func run(_ provider: any EditorProvider, guestPath: GuestPath, mode: EditorLaunchMode)
    throws -> Outcome
  {
    let outcome = try up.run()
    do {
      let instance = outcome.instance
      guard let running = try up.lifecycle.backend.asRunning(instance) else {
        throw HostFailure(
          .instanceNotRunning(instance.name),
          "Instance '\(instance.name)' stopped before the editor could attach.\nStart it with: iso start \(instance.name)"
        )
      }
      return try open(
        provider, outcome: outcome, running: running, guestPath: guestPath, mode: mode)
    } catch let error as IsoCore.ValidationError {
      throw error
    } catch {
      throw FailureAfterLifecycle(outcome, cause: error)
    }
  }

  /// Publishes the alias and launches exactly `provider`.
  func open(
    _ provider: any EditorProvider, outcome: UpOutcome, running: AppleBackend.Running,
    guestPath: GuestPath, mode: EditorLaunchMode
  ) throws -> Outcome {
    let alias = try up.lifecycle.sshConfig.update(running.target, running.instance)
    let egress = up.lifecycle.config.egress
    let target = SSHConnectionTarget(running, guestPath: guestPath, egress: egress)
    let warnings = provider.warnings(target)
    switch mode {
    case .launch:
      up.diagnostics.log(
        .info, "Opening \(guestPath) in \(provider.displayName) via \(alias.host)...")
      try launcher.launch(running, target, choice: .only(provider))
    case .prepareOnly:
      for warning in warnings { up.diagnostics.warn(warning) }
    }
    return Outcome(
      up: outcome, alias: alias, provider: provider.id,
      launchTarget: provider.launchTarget(target), warnings: warnings, mode: mode)
  }
}
