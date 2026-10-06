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

/// Opens a chosen editor on a verified running instance: a sandboxed session,
/// or in `unsafe` mode the provider's own launchers. Every spawn is preceded
/// by a late handoff check.
package struct EditorLauncher: Sendable {
  let runner: ProcessRunner
  let environment: [String: String]
  let diagnostics: Diagnostics
  let security: EditorConfig
  let home: String?
  /// How long one `unsafe` strategy may run before it is killed.
  let deadline: Duration
  var locateApp: @Sendable (any EditorProvider, String?) throws -> TrustedEditorApp? = {
    provider, home in
    try TrustedEditorApp.locate(
      provider.bundleIdentity,
      candidates: TrustedEditorApp.candidates(provider.bundleIdentity, home: home))
  }

  package init(
    runner: ProcessRunner = ProcessRunner(), environment: [String: String],
    diagnostics: Diagnostics, security: EditorConfig = .defaults, home: String? = nil,
    deadline: Duration = HostTools.deadline
  ) {
    self.runner = runner
    self.environment = environment
    self.diagnostics = diagnostics
    self.security = security
    self.home = home
    self.deadline = deadline
  }

  /// The caller variables an `unsafe` launcher inherits.
  package static func unsafeEnvironment(_ environment: [String: String]) -> [String: String] {
    let names: Set<String> = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG"]
    return environment.filter { names.contains($0.key) || $0.key.hasPrefix("LC_") }
  }

  /// `revalidate` re-proves `running`; a sandboxed session repeats it.
  package func launch(
    _ running: AppleBackend.Running, _ target: SSHConnectionTarget, choice: EditorChoice,
    revalidate: @escaping @Sendable () throws -> Void
  ) throws {
    guard target.instance == running.instance.name else {
      throw HostError("The editor target is not for instance '\(running.instance.name)'")
    }
    switch security.security {
    case .sandboxed: try launchSandboxed(running, target, choice: choice, revalidate: revalidate)
    case .unsafe: try launchUnsafe(running, target, choice: choice)
    }
  }

  /// Runs the first installed provider. A bundle that fails verification
  /// stops the launch; there is no fallback.
  func launchSandboxed(
    _ running: AppleBackend.Running, _ target: SSHConnectionTarget, choice: EditorChoice,
    revalidate: @escaping @Sendable () throws -> Void
  ) throws {
    let providers = choice.providers
    for provider in providers {
      guard let app = try locateApp(provider, home) else {
        diagnostics.debug("\(provider.displayName): no application bundle installed")
        continue
      }
      for warning in provider.warnings(target, security: security) { diagnostics.warn(warning) }
      try running.target.requireHandoff()
      try SandboxedEditorSession(
        provider: provider, app: app, running: running, target: target,
        capabilities: security.allow, ssh: SSHClient(environment: environment, runner: runner),
        callerEnvironment: environment, hostHome: home, diagnostics: diagnostics,
        revalidate: revalidate
      ).run()
      return
    }
    let locations = providers.flatMap {
      TrustedEditorApp.candidates($0.bundleIdentity, home: home)
    }
    throw HostFailure(
      .editorNotFound(providers.map(\.id)),
      "Could not find an editor application. Looked for:\n"
        + locations.map { "  - \($0)" }.joined(separator: "\n")
        + "\n\nA sandboxed editor runs the signed application directly; its CLI is not used.")
  }

  /// Tries each chosen provider in order, first printing its advisory
  /// warnings. Once a provider's editor has failed (see `EditorChoice`), no
  /// other provider is tried: a different editor must not open unexpectedly.
  /// Throws `.editorLaunchFailed` in that case and `.editorNotFound` when no
  /// strategy reached an editor.
  func launchUnsafe(
    _ running: AppleBackend.Running, _ target: SSHConnectionTarget, choice: EditorChoice
  ) throws {
    diagnostics.warn(
      "Editor security is 'unsafe': the editor runs with your full host authority, and the guest's remote editor server can reach it. This crosses the VM boundary; see docs/editor.md."
    )
    let tools = HostTools(environment: environment, runner: runner)
    let spawnEnvironment = Self.unsafeEnvironment(environment)
    let providers = choice.providers
    var tried: [String] = []
    var declined: (any EditorProvider)?
    for provider in providers where declined == nil {
      for warning in provider.warnings(target, security: security) { diagnostics.warn(warning) }
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
          executable: executable, arguments: strategy.arguments, environment: spawnEnvironment,
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

extension AppleBackend {
  /// Fails once the instance stops, reboots or loses its readiness proof.
  package func editorProof(_ expected: Running) -> @Sendable () throws -> Void {
    { [self] in
      guard let current = try asRunning(expected.instance) else {
        throw HostError("instance '\(expected.instance.name)' stopped")
      }
      guard current.ready == expected.ready, current.target == expected.target,
        current.handoffIdentity == expected.handoffIdentity
      else {
        throw HostError(
          "instance '\(expected.instance.name)' no longer matches the instance the editor opened")
      }
    }
  }
}
