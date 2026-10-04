// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// Which editors a launch may open.
package enum EditorChoice: Sendable {
  /// Exactly this provider (`iso code`, `iso zed`). An editor that is found
  /// but cannot be spawned or times out is a launch failure.
  case only(any EditorProvider)
  /// The first provider that opens (`iso editor`'s auto-detection, in
  /// order). A nonzero exit or timeout of a provider's own CLI stops the
  /// chain; a CLI that cannot be spawned is a miss.
  case firstAvailable([any EditorProvider])

  var isExplicit: Bool {
    if case .only = self { true } else { false }
  }

  var providers: [any EditorProvider] {
    switch self {
    case .only(let provider): [provider]
    case .firstAvailable(let providers): providers
    }
  }
}

/// Runs editor providers' launch strategies against a verified running
/// instance whose alias is already installed. Every spawn is preceded by a
/// late handoff check on the running proof.
package struct EditorLauncher: Sendable {
  let runner: ProcessRunner
  let environment: [String: String]
  let diagnostics: Diagnostics
  /// How long one strategy may run before it is killed.
  let deadline: Duration

  package init(
    runner: ProcessRunner = ProcessRunner(), environment: [String: String],
    diagnostics: Diagnostics,
    deadline: Duration = HostTools.deadline
  ) {
    self.runner = runner
    self.environment = environment
    self.diagnostics = diagnostics
    self.deadline = deadline
  }

  /// Tries each chosen provider in order, first printing its advisory
  /// warnings. Once a provider's editor has failed (see `EditorChoice`), no
  /// other provider is tried: a different editor must not open unexpectedly.
  /// Throws `.editorLaunchFailed` in that case and `.editorNotFound` when no
  /// strategy reached an editor.
  package func launch(
    _ running: AppleBackend.Running, _ target: SSHConnectionTarget, choice: EditorChoice
  ) throws {
    guard target.instance == running.instance.name else {
      throw HostError("The editor target is not for instance '\(running.instance.name)'")
    }
    let tools = HostTools(environment: environment, runner: runner)
    let providers = choice.providers
    var tried: [String] = []
    var declined: (any EditorProvider)?
    for provider in providers where declined == nil {
      for warning in provider.warnings(target) { diagnostics.warn(warning) }
      for strategy in provider.strategies(target) {
        diagnostics.log(
          .info,
          "Trying \(strategy.name): \(strategy.executable) \(strategy.arguments.joined(separator: " "))"
        )
        guard let executable = tools.locate(strategy.executable) else {
          diagnostics.debug("\(strategy.name): No such file or directory (os error 2)")
          tried.append("\(strategy.name) (No such file or directory (os error 2))")
          continue
        }
        try running.target.requireHandoff()
        let request = ProcessRunner.Request(
          executable: executable, arguments: strategy.arguments, environment: environment,
          deadline: deadline)
        do {
          let termination = try runner.attached(request, inheritStdin: true, deadline: deadline)
          if termination.succeeded { return }
          diagnostics.debug("\(strategy.name) exited with \(termination)")
          tried.append("\(strategy.name) exited with \(termination)")
          if strategy.nonzeroExit == .editorFailure { declined = provider }
        } catch {
          let timedOut = error == .timedOut
          let reason = timedOut ? "timed out after \(deadline)" : "\(error)"
          diagnostics.debug("\(strategy.name): \(reason)")
          tried.append("\(strategy.name) (\(reason))")
          // A hung editor was found: never fall through to another one.
          if strategy.nonzeroExit == .editorFailure, choice.isExplicit || timedOut {
            declined = provider
          }
        }
      }
    }
    let attempts =
      "Could not open an editor. Tried:\n\(tried.map { "  - \($0)" }.joined(separator: "\n"))"
    if let declined {
      throw HostFailure(.editorLaunchFailed(declined.id), attempts)
    }
    throw HostFailure(
      .editorNotFound(providers.map(\.id)),
      attempts + "\n\n" + providers.map(\.installHint).joined(separator: "\n"))
  }
}
