import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Testing

@testable import IsoCLI

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../fixtures/machine/v1").standardized

/// Semantic comparison: member order and whitespace are not part of the
/// contract.
private func json(_ data: Data) throws -> NSObject {
  try #require(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSObject)
}

private func encoded(_ value: some Encodable) throws -> NSObject {
  try json(Data(try JSONOutput.render(value, pretty: false).utf8))
}

private func fixture(_ name: String) throws -> NSObject {
  try json(Data(contentsOf: fixtures.appending(path: name + ".json")))
}

private func expectFixture(_ name: String, _ value: some Encodable) throws {
  let actual = try encoded(value)
  let expected = try fixture(name)
  #expect(actual == expected, "\(name): \(actual) != \(expected)")
}

/// Only the name and image reach a document; the allocated state is removed.
private func instance(_ name: String = "my-project") throws -> Instance {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "iso-machine-\(UUID().uuidString)"
  ).path
  defer { try? FileManager.default.removeItem(atPath: root) }
  let config = try ConfigLoader.decode(
    ConfigLoader.parse(
      Array(#"{"data_dir": "\#(root)"}"#.utf8), format: .jsonc, path: "c", limits: .configuration),
    path: "c", environment: .empty)
  return try Instance.allocate(
    config, name: try InstanceName(name), image: .default, workspacePath: nil)
}

private let usage = ResourceUsage.parse(
  """
  0.42 0.30 0.20 1/42 1234
  MemTotal:        8388608 kB
  MemAvailable:    7340032 kB
  Filesystem     1M-blocks  Used Available Use% Mounted on
  /dev/vda1          65536  8192     57344  13% /
  """)

private let copyWorkspace = WorkspaceState(
  guestPath: guestWorkspace, source: .workspace(hostPath: "/Users/me/code/my-project"))

// MARK: - Golden v1 documents

@Test func listAndStatusMatchTheV1Fixtures() throws {
  let a = try instance("project-a")
  let b = try instance("project-b")
  let c = try instance("project-c")
  try expectFixture(
    "list",
    MachineEnvelope(
      command: "list", ok: true,
      body: MachineListResult(instances: [
        MachineInstance(a, .running), MachineInstance(b, .stopped),
        MachineInstance(c, .unhealthy),
      ])))
  let one = try instance()
  try expectFixture(
    "status-single-running",
    MachineEnvelope(
      command: "status", ok: true,
      body: MachineStatusResult.one(
        MachineStatusEntry(Status.Row(instance: one, state: .running, usage: usage)))))
  try expectFixture(
    "status-single-stopped",
    MachineEnvelope(
      command: "status", ok: true,
      body: MachineStatusResult.one(
        MachineStatusEntry(Status.Row(instance: one, state: .stopped, usage: nil)))))
  try expectFixture(
    "status-single-unhealthy",
    MachineEnvelope(
      command: "status", ok: true,
      body: MachineStatusResult.one(
        MachineStatusEntry(
          Status.Row(
            instance: one, state: .unhealthy, usage: nil,
            reason: "FILTERED_EGRESS_NOT_READY: egress tunnel is not running for 'my-project'")))))
  try expectFixture(
    "status-all",
    MachineEnvelope(
      command: "status", ok: true,
      body: MachineStatusResult.all([
        MachineStatusEntry(Status.Row(instance: a, state: .running, usage: usage)),
        MachineStatusEntry(Status.Row(instance: b, state: .stopped, usage: nil)),
        MachineStatusEntry(
          Status.Row(
            instance: c, state: .unhealthy, usage: nil,
            reason: "FILTERED_EGRESS_NOT_READY: egress tunnel is not running for 'project-c'")),
      ])))
}

@Test func lifecycleResultsMatchTheV1Fixtures() throws {
  let one = try instance()
  for (name, action) in [
    ("up-created", LifecycleAction.created), ("up-started", .started), ("up-reused", .reused),
  ] {
    try expectFixture(
      name,
      MachineEnvelope(
        command: "up", ok: true,
        body: MachineUpResult(
          UpOutcome(action: action, instance: one), workspace: copyWorkspace)))
  }
  try expectFixture(
    "up-git-repo",
    MachineEnvelope(
      command: "up", ok: true,
      body: MachineUpResult(
        UpOutcome(action: .created, instance: one),
        workspace: WorkspaceState(
          guestPath: guestWorkspace, source: .gitRepo(url: "https://github.com/o/r")))))
  try expectFixture(
    "start",
    MachineEnvelope(
      command: "start", ok: true, body: MachineLifecycleResult(.started, one, state: .running)))
  try expectFixture(
    "stop",
    MachineEnvelope(
      command: "stop", ok: true, body: MachineLifecycleResult(.stopped, one, state: .stopped))
  )
  try expectFixture(
    "stop-unchanged",
    MachineEnvelope(
      command: "stop", ok: true, body: MachineLifecycleResult(.unchanged, one, state: .stopped)))
  try expectFixture(
    "destroy",
    MachineEnvelope(command: "destroy", ok: true, body: MachineDestroyResult.one(.init(one))))
  try expectFixture(
    "destroy-all",
    MachineEnvelope(
      command: "destroy", ok: true,
      body: MachineDestroyResult.all([
        .init(try instance("project-a")), .init(try instance("project-b")),
      ])))
}

@Test func sshConfigCarriesTheAliasNeverKeyMaterial() throws {
  let one = try instance()
  let result = MachineSSHConfigResult(
    instance: .running(MachineInstance(one, .running)),
    connection: MachineConnection(
      SSHAlias(host: SSHConfigFile.host(one), configPath: "/Users/me/.ssh/config")))
  try expectFixture("ssh-config", MachineEnvelope(command: "ssh-config", ok: true, body: result))
  let rendered = try JSONOutput.render(result, pretty: false)
  for forbidden in ["IdentityFile", "vm_key", "PRIVATE KEY", "HostName"] {
    #expect(!rendered.contains(forbidden))
  }
  try expectFixture(
    "ssh-config-clean",
    MachineEnvelope(
      command: "ssh-config", ok: true,
      body: MachineSSHConfigResult(instance: .removed(name: "my-project"), connection: nil)))
}

@Test func editorResultsCarryTheAliasAndLaunchTargetNeverKeyMaterial() throws {
  let one = try instance()
  let outcome = ProjectEditorWorkflow.Outcome(
    up: UpOutcome(action: .reused, instance: one),
    alias: SSHAlias(host: SSHConfigFile.host(one), configPath: "/Users/me/.ssh/config"),
    provider: .zed, launchTarget: "ssh://iso-my-project/workspace", warnings: [],
    mode: .prepareOnly)
  let result = MachineEditorResult(outcome, workspace: copyWorkspace)
  try expectFixture("zed-no-launch", MachineEnvelope(command: "zed", ok: true, body: result))
  let rendered = try JSONOutput.render(result, pretty: false)
  for forbidden in ["IdentityFile", "vm_key", "PRIVATE KEY", "HostName", "ssh_command"] {
    #expect(!rendered.contains(forbidden))
  }
  let created = UpOutcome(action: .created, instance: try instance())
  let notFound = FailureAfterLifecycle(
    created, cause: HostFailure(.editorNotFound([.code]), "Could not open an editor."))
  try expectFixture(
    "machine-error-editor-not-found",
    MachineEnvelope(command: "code", ok: false, body: MachineFailure(notFound)))
  let failed = try encoded(MachineFailure(HostFailure(.editorLaunchFailed(.zed), "x")))
  #expect(
    (failed as? NSDictionary)?["details"] as? NSDictionary == [
      "providers": ["zed"], "name": NSNull(), "action": NSNull(),
    ])
  // Any other failure after the lifecycle step still names the instance.
  let alias = try encoded(MachineFailure(FailureAfterLifecycle(created, cause: HostError("x"))))
  #expect((alias as? NSDictionary)?["code"] as? String == "OPERATION_FAILED")
  #expect(
    (alias as? NSDictionary)?["details"] as? NSDictionary == [
      "name": "my-project", "action": "created",
    ])
}

@Test func capabilitiesMatchTheV1FixtureAndTheRegistry() throws {
  let value = try #require(
    try encoded(
      MachineEnvelope(command: "capabilities", ok: true, body: MachineCapabilitiesResult()))
      as? NSDictionary)
  let result = try #require(value["result"] as? NSDictionary)
  #expect(result["cli_version"] as? String == IsoVersion.string)
  let patched = try #require(value.mutableCopy() as? NSMutableDictionary)
  let patchedResult = try #require(result.mutableCopy() as? NSMutableDictionary)
  patchedResult["cli_version"] = "<CLI_VERSION>"
  patched["result"] = patchedResult
  #expect(patched == (try fixture("capabilities")))
}

@Test func machineCommandsAreTheV1Set() {
  #expect(
    Set(MachineCommands.all.map { $0.machineName })
      == [
        "capabilities", "list", "status", "up", "start", "stop", "destroy", "code", "zed",
        "ssh-config",
      ])
  // Workload streams stay out of v1.
  for command: any ParsableCommand.Type in [
    Shell.self, Exec.self, Logs.self, ClaudeCommand.self, CodexCommand.self, RunCommand.self,
  ] {
    #expect(!(command is any MachineCommand.Type))
  }
}

// MARK: - Errors

@Test func errorDocumentsMatchTheV1Fixtures() throws {
  let path = "/repo/.devcontainer/devcontainer.json"
  let devcontainer = HostFailure(
    .interactionRequired(
      .devcontainer(path: path, acceptedFlags: ["--devcontainer \(path)", "--no-devcontainer"])),
    "Found \(path) but stdin is not a TTY.")
  try expectFixture(
    "machine-error", MachineEnvelope(command: "up", ok: false, body: MachineFailure(devcontainer)))
  let ambiguous = HostFailure(
    .ambiguousInstance(
      candidates: [try InstanceName("project-a"), try InstanceName("project-b")],
      resolution: "<NAME>"),
    "Multiple instances exist. Specify one: project-a, project-b")
  try expectFixture(
    "machine-error-ambiguous",
    MachineEnvelope(command: "stop", ok: false, body: MachineFailure(ambiguous)))
}

@Test func errorsClassifyAlongTheContextChain() throws {
  let name = try InstanceName("a")
  let cases: [(any Error, MachineErrorCode)] = [
    (HostFailure(.instanceNotFound, "x"), .instanceNotFound),
    (HostFailure(.instanceAlreadyRunning(name), "x"), .instanceAlreadyRunning),
    (HostFailure(.instanceNotRunning(nil), "x"), .instanceNotRunning),
    (HostFailure(.instanceIncompatible(name), "x"), .instanceIncompatible),
    (HostFailure(.projectAlreadyAssociated(name), "x"), .projectAlreadyAssociated),
    (
      HostFailure(.interactionRequired(.passphrase(descriptorVariable: "V")), "x"),
      .interactionRequired
    ),
    (RuntimeError.hostKeyChanged("k"), .appleHostKeyChanged),
    (RuntimeError.networkIsolation("n"), .appleNetworkIsolation),
    (RuntimeError.unavailable("u"), .appleRuntimeUnavailable),
    (RuntimeError.failed("f"), .operationFailed),
    (
      ContextError(
        "Guest booted", cause: ContextError("probe", cause: RuntimeError.bootTimeout("t"))),
      .appleBootTimeout
    ),
    (ContextError("outer", cause: HostFailure(.instanceNotFound, "x")), .instanceNotFound),
    (InstanceUnhealthy(name, cause: HostError("FILTERED_EGRESS_NOT_READY: x")), .instanceUnhealthy),
    (
      ContextError("outer", cause: InstanceUnhealthy(name, cause: HostError("x"))),
      .instanceUnhealthy
    ),
    (HostError("untyped"), .operationFailed),
    (IsoCore.ValidationError("bad"), .invalidArgument),
    (ArgumentParser.ValidationError("bad"), .invalidArgument),
  ]
  for (error, code) in cases {
    #expect(MachineFailure(error).code == code, "\(error)")
  }
  let failure = MachineFailure(HostFailure(.instanceNotRunning(name), "x"))
  #expect(failure.details == .instance(name: "a"))
  #expect(MachineFailure(HostFailure(.instanceNotRunning(nil), "x")).details == nil)
  let unhealthy = MachineFailure(InstanceUnhealthy(name, cause: HostError("why")))
  #expect(unhealthy.details == .instance(name: "a"))
  #expect(
    unhealthy.message
      == "Instance 'a' is running but cannot be reached safely; `iso stop a` stops it without connecting to the guest: why"
  )
}

@Test func errorMessagesAreSanitizedAndBounded() throws {
  let failure = MachineFailure(HostError("guest said \u{1B}[31mred\u{202E}"))
  #expect(failure.message == "guest said ?[31mred?")
  let long = MachineFailure(HostError(String(repeating: "é", count: 10_000)))
  #expect(long.message.utf8.count <= MachineFailure.messageLimit)
  #expect(long.message.hasSuffix("..."))
  let path = "/repo/\u{07}.devcontainer/devcontainer.json"
  let details = MachineFailure(
    HostFailure(
      .interactionRequired(.devcontainer(path: path, acceptedFlags: ["--devcontainer \(path)"])),
      "x")
  ).details
  #expect(
    details
      == .devcontainer(
        path: "/repo/?.devcontainer/devcontainer.json",
        acceptedFlags: ["--devcontainer /repo/?.devcontainer/devcontainer.json"]))
}

@Test func nullableFieldsArePresentNotOmitted() throws {
  let failure = try #require(
    try encoded(MachineEnvelope(command: "x", ok: false, body: MachineFailure(HostError("e"))))
      as? NSDictionary)
  let error = try #require(failure["error"] as? NSDictionary)
  #expect(error["details"] is NSNull)
  #expect(error["retryable"] as? Bool == false)
  let up = try #require(
    try encoded(
      MachineUpResult(UpOutcome(action: .reused, instance: try instance()), workspace: nil))
      as? NSDictionary)
  #expect(up["workspace"] is NSNull)
}

// MARK: - Parsing

@Test func outputFormatParsesOnEverySubcommandPosition() throws {
  for argv in [["--output", "json", "status"], ["status", "--output", "json"]] {
    let command = try IsoCommand.parseAsRoot(argv)
    #expect(GlobalOptions.parsed(in: command)?.output == .json)
    #expect(command is any MachineCommand)
  }
  let logs = try IsoCommand.parseAsRoot(["logs", "--output", "json"])
  #expect(GlobalOptions.parsed(in: logs)?.output == .json)
  #expect(!(logs is any MachineCommand))
  #expect(GlobalOptions.parsed(in: try IsoCommand.parseAsRoot(["status"]))?.output == .text)
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["status", "--output", "yaml"]) }
}

@Test func conflictingOutputFlagsAreUsageErrors() throws {
  for argv in [
    ["list", "--json", "--output", "json"], ["status", "--json", "--output", "json"],
    ["up", "--dry-run", "--output", "json"], ["start", "--dry-run", "--output", "json"],
    ["status", "--quiet"],
  ] {
    #expect(throws: (any Error).self, "\(argv)") { try IsoCommand.parseAsRoot(argv) }
  }
  // Legacy JSON keeps working beside the default text format.
  #expect(try IsoCommand.parseAsRoot(["list", "--json", "--output", "text"]) is List)
  #expect(try IsoCommand.parseAsRoot(["status", "--output", "json", "--quiet"]) is Status)
}

// MARK: - Non-interactive

@Test func machineModeNeverPromptsForThePassphrase() throws {
  let failure = try #require(throws: HostFailure.self) {
    try PassphraseInput.readFresh(
      prompt: "Passphrase", confirm: false, environment: [:], interactive: false,
      hidden: { _ in
        Issue.record("machine mode reached the terminal prompt")
        return Secret(Array("pw".utf8))
      })
  }
  #expect(
    failure.reason
      == .interactionRequired(
        .passphrase(descriptorVariable: PassphraseInput.descriptorVariable)))
  // Automation's descriptor still works without a terminal.
  var fds: [Int32] = [0, 0]
  #expect(pipe(&fds) == 0)
  #expect(write(fds[1], "pw\n", 3) == 3)
  close(fds[1])
  let passphrase = try PassphraseInput.readFresh(
    prompt: "Passphrase", confirm: false,
    environment: [PassphraseInput.descriptorVariable: String(fds[0])], interactive: false)
  #expect(passphrase.expose() == Array("pw".utf8))
}

@Test func unsupportedCommandsAreNamedByTheirFullPath() throws {
  #expect(commandPath(SecretsList.self, under: IsoCommand.self) == ["secrets", "list"])
  #expect(commandPath(List.self, under: IsoCommand.self) == ["list"])
  #expect(commandPath(IsoCommand.self, under: IsoCommand.self) == [])
  #expect(GlobalOptions.requestsMachineOutput(["iso", "secrets", "--output", "json"]))
  #expect(GlobalOptions.requestsMachineOutput(["iso", "--output=json", "github"]))
  #expect(!GlobalOptions.requestsMachineOutput(["iso", "exec", "--", "x", "--output", "json"]))
  #expect(!GlobalOptions.requestsMachineOutput(["iso", "secrets", "--output", "text"]))
}

private struct PassphraseRequired: SecretReferenceResolver {
  func resolve(_ names: Set<SecretName>) throws -> [SecretName: Secret<[UInt8]>] {
    throw HostFailure(.interactionRequired(.passphrase(descriptorVariable: "V")), "needs V")
  }
}

@Test func storedCredentialsKeepThePassphraseNeedTyped() throws {
  let resolver = CredentialResolver(environment: [:], secrets: PassphraseRequired())
  for attempt in [
    { _ = try resolver.resolveAllowingStored(Secret("vault:ghpat")) },
    { try resolver.prefetchStored([Secret("vault:ghpat")]) },
  ] as [() throws -> Void] {
    let failure = try #require(throws: HostFailure.self) { try attempt() }
    #expect(failure.reason == .interactionRequired(.passphrase(descriptorVariable: "V")))
    #expect(
      MachineFailure(ContextError("Failed to resolve token", cause: failure)).code
        == .interactionRequired)
  }
}

@Test func partialDestroyAllReportsWhatWasRemoved() throws {
  let removed = [MachineRemovedInstance(try instance("project-a"))]
  let untyped = try #require(
    try encoded(
      MachineFailure(PartialDestroy(destroyed: removed, cause: RuntimeError.failed("disk busy"))))
      as? NSDictionary)
  #expect(untyped["code"] as? String == "OPERATION_FAILED")
  #expect(untyped["message"] as? String == "disk busy")
  let details = try #require(untyped["details"] as? NSDictionary)
  #expect(details == ["destroyed": [["name": "project-a", "image": "default"]]] as NSDictionary)

  // A typed cause keeps its code and its own details beside `destroyed`.
  let typed = MachineFailure(
    PartialDestroy(
      destroyed: removed,
      cause: ContextError(
        "destroying 'b'", cause: HostFailure(.instanceAlreadyRunning(try InstanceName("b")), "x"))))
  #expect(typed.code == .instanceAlreadyRunning)
  #expect(
    try encoded(typed.details!)
      == ["name": "b", "destroyed": [["name": "project-a", "image": "default"]]] as NSDictionary)
  // Text mode prints only the cause, as before.
  #expect("\(PartialDestroy(destroyed: removed, cause: HostError("boom")))" == "boom")
}
