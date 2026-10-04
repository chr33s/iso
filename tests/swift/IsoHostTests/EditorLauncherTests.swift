import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

/// Stub launchers on a `PATH` holding nothing else, so no real editor or
/// `open` can run. Each records its name and argv, then exits as told; a
/// status of -1 is an executable that cannot be spawned, -2 one that hangs.
private func launch(
  _ guest: FakeGuest, stubs: [String: Int32], choice: EditorChoice,
  path: GuestPath = guestWorkspace, deadline: Duration = .seconds(30)
) throws -> [String] {
  let log = guest.root + "/editor.log"
  try? FileManager.default.removeItem(atPath: guest.root + "/editors")
  try FileManager.default.createDirectory(
    atPath: guest.root + "/editors", withIntermediateDirectories: true)
  for (tool, status) in stubs {
    let body =
      switch status {
      case -1: "#!/nonexistent/interpreter\n"
      case -2: "#!/bin/sh\nexec /bin/sleep 30\n"
      default: "#!/bin/sh\nprintf '%s %s\\n' '\(tool)' \"$*\" >> '\(log)'\nexit \(status)\n"
      }
    try writeFile(guest.root + "/editors/" + tool, body, mode: 0o755)
  }
  let running = try workloadRunning(guest, identity: nil)
  defer { try? FileManager.default.removeItem(atPath: log) }
  do {
    try EditorLauncher(
      environment: ["PATH": guest.root + "/editors"], diagnostics: guest.sink.diagnostics,
      deadline: deadline
    )
    .launch(
      running, SSHConnectionTarget(running, guestPath: path, egress: .open), choice: choice)
  } catch {
    throw LaunchFailure(error: error, spawned: rustLines(readFile(log) ?? ""))
  }
  return rustLines(readFile(log) ?? "")
}

private struct LaunchFailure: Error {
  let error: any Error
  let spawned: [String]

  var reason: HostFailure.Reason? { (error as? HostFailure)?.reason }
}

private func failure(_ body: () throws -> [String]) -> LaunchFailure? {
  do {
    _ = try body()
    return nil
  } catch {
    return error as? LaunchFailure
  }
}

@Test func explicitProvidersNeverFallBackToAnotherEditor() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let alias = SSHConfigFile.host(try workloadRunning(guest, identity: nil).instance)

  // Zed missing, VS Code present: `iso zed` reports not found, never opens VS Code.
  let missing = try #require(
    failure { try launch(guest, stubs: ["code": 0], choice: .only(ZedEditorProvider())) })
  #expect(missing.reason == .editorNotFound([.zed]))
  #expect(missing.spawned.isEmpty)
  #expect("\(missing.error)".contains("cli: install"))

  // VS Code missing, Zed present: `iso code` reports not found.
  let code = try #require(
    failure { try launch(guest, stubs: ["zed": 0], choice: .only(VSCodeEditorProvider())) })
  #expect(code.reason == .editorNotFound([.code]))
  #expect(code.spawned.isEmpty)

  // The Zed CLI declines: only Zed's own URL fallback may still run.
  let declined = try #require(
    failure {
      try launch(
        guest, stubs: ["zed": 1, "open": 1, "code": 0], choice: .only(ZedEditorProvider()))
    })
  #expect(declined.reason == .editorLaunchFailed(.zed))
  #expect(
    declined.spawned == ["zed ssh://\(alias)/workspace", "open zed://ssh/\(alias)/workspace"])

  #expect(
    try launch(guest, stubs: ["code": 0], choice: .only(VSCodeEditorProvider()))
      == ["code --remote ssh-remote+\(alias) /workspace"])
  #expect(
    try launch(
      guest, stubs: ["zed": 0], choice: .only(ZedEditorProvider()),
      path: GuestPath("/workspace/a b")) == ["zed ssh://\(alias)/workspace/a%20b"])
}

@Test func legacyAutoDetectionTriesVSCodeThenZed() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let alias = SSHConfigFile.host(try workloadRunning(guest, identity: nil).instance)
  let all = EditorChoice.firstAvailable(EditorProviderID.allCases.map(\.provider))

  // VS Code unavailable (no CLI, app launcher misses): Zed opens.
  #expect(
    try launch(guest, stubs: ["open": 1, "zed": 0], choice: all) == [
      "open vscode://vscode-remote/ssh-remote+\(alias)/workspace",
      "zed ssh://\(alias)/workspace",
    ])

  // VS Code started and declined: Zed is never tried.
  let declined = try #require(
    failure { try launch(guest, stubs: ["code": 1, "open": 1, "zed": 0], choice: all) })
  #expect(declined.reason == .editorLaunchFailed(.code))
  #expect(!declined.spawned.contains { $0.hasPrefix("zed") })

  let none = try #require(failure { try launch(guest, stubs: [:], choice: all) })
  #expect(none.reason == .editorNotFound([.code, .zed]))
  #expect(
    "\(none.error)".contains("Shell Command: Install") && "\(none.error)".contains("cli: install"))
}

@Test func providersBuildStrategiesForTheManagedAliasAndEscapeURLPaths() throws {
  let name = try InstanceName("test")
  func target(_ path: GuestPath, egress: EgressMode = .open) -> SSHConnectionTarget {
    SSHConnectionTarget(instance: name, guestPath: path, egress: egress)
  }
  #expect(target(guestWorkspace).sshHostAlias == "iso-test")
  let code = VSCodeEditorProvider().strategies(target(guestWorkspace))
  #expect(code.map(\.executable) == ["code", "open"])
  #expect(code[0].arguments == ["--remote", "ssh-remote+iso-test", "/workspace"])
  #expect(code[1].arguments == ["vscode://vscode-remote/ssh-remote+iso-test/workspace"])
  #expect(
    VSCodeEditorProvider().strategies(target(GuestPath("/a#b")))[1].arguments == [
      "vscode://vscode-remote/ssh-remote+iso-test/a%23b"
    ])
  #expect(code.map(\.nonzeroExit) == [.editorFailure, .launcherMiss])
  #expect(
    VSCodeEditorProvider().launchTarget(target(guestWorkspace))
      == "vscode-remote://ssh-remote+iso-test/workspace")
  let odd = target(GuestPath("/a#b c%d?e"))
  let zed = ZedEditorProvider().strategies(odd)
  #expect(zed.map(\.executable) == ["zed", "open"])
  #expect(zed[0].arguments == ["ssh://iso-test/a%23b%20c%25d%3Fe"])
  #expect(zed[1].arguments == ["zed://ssh/iso-test/a%23b%20c%25d%3Fe"])
  #expect(ZedEditorProvider().launchTarget(odd) == zed[0].arguments[0])
  #expect(percentEncodeGuestPath(GuestPath("/\u{1}\"<>`{}é")) == "/%01%22%3C%3E%60%7B%7D%C3%A9")
  #expect(EditorProviderID.allCases.map(\.provider.id) == [.code, .zed])
  #expect(EditorProviderID.allCases.allSatisfy { $0.provider.remoteTransport == .ssh })
}

@Test func zedWarnsUnderRestrictedEgressWithoutChangingIt() throws {
  let open = SSHConnectionTarget(
    instance: try InstanceName("test"), guestPath: guestWorkspace, egress: .open)
  #expect(ZedEditorProvider().warnings(open).isEmpty)
  for egress in [EgressMode.none, .filtered] {
    let target = SSHConnectionTarget(
      instance: open.instance, guestPath: guestWorkspace, egress: egress)
    let warnings = ZedEditorProvider().warnings(target)
    #expect(warnings.count == 1 && warnings[0].contains("upload_binary_over_ssh"))
    #expect(VSCodeEditorProvider().warnings(target).isEmpty)
  }
}

@Test func anEditorThatCannotBeSpawnedIsALaunchFailureNotAMissingEditor() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let alias = SSHConfigFile.host(try workloadRunning(guest, identity: nil).instance)
  let broken = try #require(
    failure {
      try launch(
        guest, stubs: ["zed": -1, "open": 1, "code": 0], choice: .only(ZedEditorProvider()))
    })
  #expect(broken.reason == .editorLaunchFailed(.zed))
  // Zed's own URL fallback still ran; VS Code never did.
  #expect(broken.spawned == ["open zed://ssh/\(alias)/workspace"])
  #expect(!"\(broken.error)".contains("cli: install"))

  // `iso editor` auto-detection keeps treating it as a miss and moves on.
  let all = EditorChoice.firstAvailable(EditorProviderID.allCases.map(\.provider))
  #expect(
    try launch(guest, stubs: ["code": -1, "open": 1, "zed": 0], choice: all).last
      == "zed ssh://\(alias)/workspace")
}

@Test func aHangingEditorIsKilledAtTheDeadline() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let start = ContinuousClock.now
  let hung = try #require(
    failure {
      try launch(
        guest, stubs: ["zed": -2], choice: .only(ZedEditorProvider()),
        deadline: .milliseconds(300))
    })
  #expect(ContinuousClock.now - start < .seconds(10))
  #expect(hung.reason == .editorLaunchFailed(.zed))
  #expect("\(hung.error)".contains("timed out"))

  // Auto-detection: a found editor that hangs stops the chain too.
  let all = EditorChoice.firstAvailable(EditorProviderID.allCases.map(\.provider))
  let hungCode = try #require(
    failure {
      try launch(
        guest, stubs: ["code": -2, "open": 1, "zed": 0], choice: all,
        deadline: .milliseconds(300))
    })
  #expect(hungCode.reason == .editorLaunchFailed(.code))
  #expect(!hungCode.spawned.contains { $0.hasPrefix("zed") })
}

/// `iso zed`'s handoff after the lifecycle step, with the editor stubs on
/// `PATH` and the alias written under the fake host home.
private func editorWorkflow(_ guest: FakeGuest) throws -> ProjectEditorWorkflow {
  let home = guest.root + "/hosthome"
  let config = try testConfig(home: home)
  let diagnostics = guest.sink.diagnostics
  let backend = AppleBackend(
    config: config, environment: [:], diagnostics: diagnostics,
    runtime: { () throws(RuntimeError) in throw RuntimeError.unqualified("unused") })
  let lifecycle = ProjectLifecycle(
    context: CommandContext(
      environment: ConfigEnvironment(home: home, variables: [:]), config: config,
      backend: backend, output: SilentOutput(), diagnostics: diagnostics,
      ssh: SSHClient(environment: [:])),
    noGitHub: true, secretResolver: NoSecrets(), executable: nil,
    prepareGitHub: { _, _, _, _ in throw HostError("unexpected prompt") })
  return ProjectEditorWorkflow(
    up: UpWorkflow(
      request: UpRequest(configTarget: ConfigTarget(path: home + "/c.jsonc", format: .jsonc)),
      lifecycle: lifecycle, target: nil),
    launcher: EditorLauncher(
      environment: ["PATH": guest.root + "/editors"], diagnostics: diagnostics))
}

@Test func projectEditorCommandsLaunchOnlyTheirProviderAndReportTheLifecycleStep() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let running = try workloadRunning(guest, identity: nil)
  let outcome = UpOutcome(action: .created, instance: running.instance)
  let workflow = try editorWorkflow(guest)
  let log = guest.root + "/editor.log"
  // VS Code is installed, Zed is not.
  try writeFile(
    guest.root + "/editors/code", "#!/bin/sh\necho code >> '\(log)'\nexit 0\n", mode: 0o755)

  let prepared = try workflow.open(
    ZedEditorProvider(), outcome: outcome, running: running, guestPath: guestWorkspace,
    mode: .prepareOnly)
  #expect(prepared.mode == .prepareOnly && prepared.provider == .zed)
  #expect(prepared.launchTarget == "ssh://\(prepared.alias.host)/workspace")
  #expect(readFile(prepared.alias.configPath)?.contains("Host \(prepared.alias.host)") == true)

  let failure = try #require(throws: HostFailure.self) {
    try workflow.open(
      ZedEditorProvider(), outcome: outcome, running: running, guestPath: guestWorkspace,
      mode: .launch)
  }
  #expect(failure.reason == .editorNotFound([.zed]))
  #expect(readFile(log) == nil)
}
