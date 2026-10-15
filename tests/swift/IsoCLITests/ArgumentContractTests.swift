import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Testing

@testable import IsoCLI

private func parse<T>(_ argv: [String], as: T.Type = T.self) throws -> T {
  try #require(try IsoCommand.parseAsRoot(argv) as? T)
}

// MARK: - shared argument groups

@Test func upAndStartParseTheSameBootOptions() throws {
  let flags = [
    "--no-agents", "--no-github", "--no-prompt", "--forward-port", "3000:3001", "--post-start",
    "make dev", "--env", "A=b", "--env-file", "/e.env",
  ]
  let up: Up = try parse(["up", "/p"] + flags)
  let start: Start = try parse(["start", "vm"] + flags)
  for boot in [up.project.boot, start.boot] {
    #expect(boot.noAgents && boot.noGithub && boot.noPrompt)
    #expect(boot.forwardPort.map(\.guest) == [3000] && boot.forwardPort.map(\.host) == [3001])
    #expect(boot.postStart == "make dev" && boot.envFile == "/e.env")
    #expect(boot.guestEnvironment.map(\.0.rawValue) == ["A"])
  }
  let request = up.project.request(
    configTarget: ConfigTarget(path: "/c.jsonc", format: .jsonc), command: "up")
  #expect(request.noAgents && request.noGithub && request.noPrompt)
  #expect(request.postStart == "make dev" && request.envFile == "/e.env")
}

@Test func startStillRefusesCreationOptions() {
  for creation in [["--disk", "20"], ["--image", "x"], ["--profile", "go"], ["--mount"]] {
    #expect(throws: (any Error).self, "\(creation)") {
      try IsoCommand.parseAsRoot(["start", "vm"] + creation)
    }
  }
}

@Test func devcontainerFlagsConflictTheSameWayEverywhere() throws {
  for command in [["up"], ["start"], ["setup"], ["code"], ["zed"]] {
    #expect(throws: (any Error).self, "\(command)") {
      try IsoCommand.parseAsRoot(command + ["--devcontainer", "/d.json", "--no-devcontainer"])
    }
  }
  let setup: Setup = try parse(["setup", "--devcontainer", "/d.json"])
  #expect(setup.devcontainerArguments.devcontainer == "/d.json")
  let start: Start = try parse(["start", "--no-devcontainer"])
  #expect(start.devcontainerArguments.noDevcontainer)
  #expect(throws: (any Error).self) {
    try IsoCommand.parseAsRoot(["setup", "--config-only", "--no-devcontainer"])
  }
}

@Test func profileListsKeepOrderAndRefuseEmptyNames() throws {
  let up: Up = try parse(["up", "--profile", "rust,python", "--profile", "go"])
  #expect(up.project.profiles == ["rust", "python", "go"])
  let run: RunCommand = try parse(["run", "claude", "--profile", "node,go"])
  #expect(run.profiles == ["node", "go"])
  let setup: Setup = try parse(["setup", "--profile", "python,node"])
  #expect(setup.profile.flatMap { $0 } == ["python", "node"])
  let image: HostImage = try parse(["host", "image", "h", "--profile", "a,b", "--profile", "c"])
  #expect(image.profiles.flatMap { $0 } == ["a", "b", "c"])
  for bad in [
    ["up", "--profile", "rust,,go"], ["up", "--profile", ","], ["run", "claude", "--profile", ""],
    ["setup", "--profile", "python,"], ["host", "image", "h", "--profile", ",a"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
}

@Test func egressValuesAreTypedBeforeAnyWork() throws {
  let up: Up = try parse(["up", "--egress", "filtered", "--allow-host", "api.example.com"])
  #expect(up.project.egressOptions.egress == .filtered)
  let run: RunCommand = try parse(["run", "codex", "--egress", "none"])
  #expect(run.egressOptions.egress == EgressMode.none)
  let hostUp: HostUp = try parse(["host", "up", "h", "--egress", "none"])
  #expect(hostUp.egress == EgressMode.none)
  let hostRun: HostRun = try parse(["host", "run", "h", "--", "true"])
  #expect(hostRun.egress == EgressMode.none)
  let create: HostVMCreate = try parse(["host", "vm", "create", "h", "vm"])
  #expect(create.egress == .open)
  for bad in [
    ["up", "--egress", "sideways"], ["start", "--egress", "closed"],
    ["run", "claude", "--egress", "x"], ["host", "up", "h", "--egress", "x"],
    ["host", "run", "h", "--egress", "x", "--", "true"],
    ["host", "vm", "create", "h", "vm", "--egress", "x"],
    ["up", "--allow-host", "https://x"], ["run", "claude", "--allow-host", "a b"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
}

@Test func egressOverrideKeepsAllowHostRule() throws {
  let config = try ConfigLoader.load(.defaultsOnly(defaultPath: "/c.jsonc"), environment: .empty)
  let none: Up = try parse(["up", "--egress", "none", "--allow-host", "a.example"])
  #expect(throws: (any Error).self) { try applyEgressOverride(config, none.project.egressOptions) }
  let filtered: Up = try parse(["up", "--egress", "filtered", "--allow-host", "a.example"])
  #expect(try applyEgressOverride(config, filtered.project.egressOptions).egress == .filtered)
  let plain: Up = try parse(["up"])
  #expect(try applyEgressOverride(config, plain.project.egressOptions).egress == config.egress)
}

@Test func ttlsShareTheDurationParser() throws {
  let start: HostVMStart = try parse(["host", "vm", "start", "h", "vm", "--ttl", "30m"])
  #expect(ttlSeconds(start.ttl, default: 1) == 1_800)
  let up: HostUp = try parse(["host", "up", "h", "--ttl", "2h"])
  #expect(ttlSeconds(up.ttl, default: 1) == 7_200)
  let run: HostRun = try parse(["host", "run", "h", "--", "true"])
  #expect(ttlSeconds(run.ttl, default: 3_600) == 3_600)
  #expect(ttlSeconds(nil, default: 42) == 42)
  for bad in ["0", "soon", "-1m", ""] {
    #expect(throws: (any Error).self, "\(bad)") {
      try IsoCommand.parseAsRoot(["host", "vm", "start", "h", "vm", "--ttl", bad])
    }
  }
}

// MARK: - contract corrections: conflicting or ignored flags

/// Each pair is refused while parsing, so nothing is listed, stopped,
/// spawned, recovered or deleted.
@Test func conflictingOperationsAreUsageErrors() throws {
  for bad in [
    ["destroy", "vm-a", "--all"], ["host", "migrate", "local", "--activate", "--rollback"],
    ["host", "session", "h", "vm", "--detach", "--stop"],
    ["host", "run-results", "h", "run", "--recover", "--discard"],
    ["images", "--delete", "x", "--json"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
  #expect(try IsoCommand.parseAsRoot(["destroy", "--all"]) is Destroy)
  #expect(try IsoCommand.parseAsRoot(["destroy", "vm-a"]) is Destroy)
  #expect(try IsoCommand.parseAsRoot(["images", "--delete", "x"]) is Images)
  #expect(try IsoCommand.parseAsRoot(["images", "--json"]) is Images)
  #expect(try IsoCommand.parseAsRoot(["host", "session", "h", "vm", "--stop"]) is HostSession)
  #expect(
    try IsoCommand.parseAsRoot(["host", "run-results", "h", "run", "--discard"]) is HostRunResults)
}

@Test func remotePullFlagsBelongToOneMode() throws {
  for bad in [
    ["host", "pull", "h", "vm", "--stage-id", "s"], ["host", "pull", "h", "vm", "--force"],
    ["host", "pull", "h", "vm", "--apply", "--dir", "d"],
    ["host", "pull", "h", "vm", "--apply", "--exclude-git"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
  let apply: HostPull = try parse([
    "host", "pull", "h", "vm", "--apply", "--stage-id", "s", "--force",
  ])
  #expect(apply.apply && apply.force && apply.stageID == "s")
  let stage: HostPull = try parse(["host", "pull", "h", "vm", "--dir", "d", "--exclude-git"])
  #expect(!stage.apply && stage.dir == "d" && stage.excludeGit)
}

@Test func runForwardsEveryTokenAfterTheTerminator() throws {
  let cases: [([String], Bool, [String])] = [
    (["run", "claude", "--", "--ask"], false, ["--ask"]),
    (["run", "claude", "--ask", "--", "--ask"], true, ["--ask"]),
    (["run", "claude", "--", "--", "--ask"], false, ["--", "--ask"]),
    (
      ["run", "codex", "--", "--config", "--output", "json", " spaced  arg ", ""], false,
      ["--config", "--output", "json", " spaced  arg ", ""]
    ),
  ]
  for (argv, ask, forwarded) in cases {
    let run: RunCommand = try parse(argv)
    // What `RunWorkflow` receives, not just what the parser stored.
    #expect(run.launch.ask == ask, "\(argv)")
    #expect(run.launch.forwarded == forwarded, "\(argv)")
  }
}

@Test func agentAddAcceptsTheShortYes() throws {
  let short: AgentAddCommand = try parse(["agent", "add", "d.jsonc", "-y"])
  let long: AgentAddCommand = try parse(["agent", "add", "d.jsonc", "--yes"])
  #expect(short.yes && long.yes && !short.replace)
}

@Test func setupYesStaysAcceptedButIsDeprecated() throws {
  let setup: Setup = try parse(["setup", "-y", "--workspace", "."])
  #expect(setup.yes)
  // It grants no trust: the devcontainer input is still plain discovery.
  #expect(!setup.devcontainerArguments.isSet)
  #expect(Setup.yesDeprecation.contains("--devcontainer PATH"))
  #expect(Setup.yesDeprecation.contains("--no-devcontainer"))
  #expect(Setup.helpMessage().contains("Deprecated; has no effect"))
  #expect(setup.deprecationNotes == [Setup.yesDeprecation])
  #expect((try parse(["setup"]) as Setup).deprecationNotes.isEmpty)
}

@Test func explicitEgressIsCheckedAgainstAReusedRemoteVM() throws {
  let name = try InstanceName("app")
  #expect(
    HostUp.reusedEgressRefusal(requested: .none, observed: EgressMode.none, name: name, host: "h")
      == nil)
  let mismatch = try #require(
    HostUp.reusedEgressRefusal(requested: .filtered, observed: .open, name: name, host: "h"))
  #expect(
    mismatch.contains("created with egress open") && mismatch.contains("iso host vm destroy h app"))
  let unknown = try #require(
    HostUp.reusedEgressRefusal(requested: .none, observed: nil, name: name, host: "h"))
  #expect(unknown.contains("cannot be confirmed"))
}

@Test func onlySucceededReceiptsSucceed() throws {
  for state in OperationState.allCases {
    let receipt = OperationReceipt(
      operationID: .generate(), method: .vmStop, state: state, disposition: .accepted,
      acceptedAt: WireTime(seconds: 1), completedAt: nil, instance: nil, generation: nil,
      bootID: nil,
      expiresAt: nil, outcome: nil, cancelRequested: false)
    if state == .succeeded {
      try requireSucceeded(receipt, output: StandardStreams())
    } else {
      #expect(throws: ExitCode.failure, "\(state)") {
        try requireSucceeded(receipt, output: StandardStreams())
      }
    }
  }
}

// MARK: - canonical spellings and their compatibility adapters

@Test func serviceResourceAliasesParseToTheSameValues() throws {
  let canonical: HostVMCreate = try parse([
    "host", "vm", "create", "h", "vm", "--vcpus", "4", "--mem", "8192", "--disk", "32",
  ])
  let legacy: HostVMCreate = try parse([
    "host", "vm", "create", "h", "vm", "--cpus", "4", "--memory-mib", "8192", "--disk-gib", "32",
  ])
  for create in [canonical, legacy] {
    #expect(create.cpus == 4 && create.memoryMiB == 8_192 && create.diskGiB == 32)
  }
  // Fixed service defaults are unchanged by the aliases.
  let defaults: HostVMCreate = try parse(["host", "vm", "create", "h", "vm"])
  #expect(defaults.cpus == 2 && defaults.memoryMiB == 4_096 && defaults.diskGiB == 16)
  let resize: HostVMResize = try parse(["host", "vm", "resize", "local", "vm", "--disk", "40"])
  #expect(resize.diskGiB == 40)
  // The service's disk is absolute only; relative sizes stay local.
  for bad in [
    ["host", "vm", "resize", "local", "vm", "--disk", "+20"],
    ["host", "vm", "resize", "local", "vm", "--disk-gib", "+20"],
    ["host", "vm", "create", "h", "vm", "--disk", "+20"],
    ["host", "vm", "create", "h", "vm", "--disk-gib", "+20"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
  let local: Resize = try parse(["resize", "vm", "--disk", "+20"])
  let older: Resize = try parse(["resize", "vm", "--size", "+20"])
  #expect(local.disk == older.disk)
  #expect(local.disk == .relative(GiB(20)!))
}

@Test func maintenanceImageTakesTheOptionOrTheOldPositional() throws {
  let option: HostVMCommit = try parse(["host", "vm", "commit", "local", "vm", "--image", "snap"])
  let positional: HostVMCommit = try parse(["host", "vm", "commit", "local", "vm", "snap"])
  #expect(option.imageArguments.resolved?.rawValue == "snap")
  #expect(option.imageArguments.resolved == positional.imageArguments.resolved)
  let restore: HostVMRestore = try parse(["host", "vm", "restore", "local", "vm", "--image", "s"])
  #expect(restore.imageArguments.resolved?.rawValue == "s")
  for bad in [
    ["host", "vm", "commit", "local", "vm"],
    ["host", "vm", "commit", "local", "vm", "a", "--image", "b"],
    ["host", "vm", "restore", "local", "vm", "Bad!"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
}

@Test func remoteForwardingGrammarsAgreeAndDoNotMix() throws {
  let old: HostForward = try parse(["host", "forward", "h", "vm", "13000:3000"])
  let new: HostForward = try parse(["host", "forward", "h", "vm", "--forward-port", "3000:13000"])
  let oldPairs = try old.parsed()
  let newPairs = try new.parsed()
  #expect(oldPairs.map(\.host) == [13_000] && oldPairs.map(\.guest) == [3_000])
  #expect(newPairs == oldPairs)
  let same: HostForward = try parse(["host", "forward", "h", "vm", "--forward-port", "8080"])
  #expect(try same.parsed().map(\.host) == [8_080] && same.parsed().map(\.guest) == [8_080])
  for bad in [
    ["host", "forward", "h", "vm"], ["host", "forward", "h", "vm", "1:2", "--forward-port", "3"],
    ["host", "forward", "h", "vm", "--forward-port", "0"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
}

@Test func guestPathSpellingsNameTheSameGuestDirectory() throws {
  let code: CodeCommand = try parse(["code", "--guest-path", "/workspace/app"])
  let older: CodeCommand = try parse(["code", "--project", "/workspace/app"])
  #expect(try code.launchOptions.parsedGuestPath() == older.launchOptions.parsedGuestPath())
  let editor: Editor = try parse(["editor", "--guest-path", "/srv"])
  #expect(editor.guestPath == "/srv")
  let remote: HostEditor = try parse(["host", "editor", "h", "vm", "zed", "--guest-path", "/srv"])
  let remoteOld: HostEditor = try parse(["host", "editor", "h", "vm", "zed", "--path", "/srv"])
  #expect(remote.guestPath == "/srv" && remoteOld.guestPath == "/srv")
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["code", "--guest-path", "rel"]) }
}

@Test func modelCanonicalAndLegacyGrammars() throws {
  let show: ModelShow = try parse(["model", "show", "dev"])
  #expect(show.name?.rawValue == "dev")
  #expect((try parse(["model", "show"]) as ModelShow).name == nil)
  let set: ModelSet = try parse(["model", "set", "local", "dev"])
  #expect(set.mode == .local && set.name?.rawValue == "dev")
  // Instances named after the modes stay addressable.
  let local: ModelShow = try parse(["model", "show", "local"])
  #expect(local.name?.rawValue == "local")
  let remote: ModelSet = try parse(["model", "set", "remote", "local"])
  #expect(remote.mode == .remote && remote.name?.rawValue == "local")
  // The older grammar is the hidden default.
  let legacy: ModelLegacy = try parse(["model", "dev", "remote"])
  #expect(legacy.words == ["dev", "remote"])
  #expect((try parse(["model"]) as ModelLegacy).words.isEmpty)
  #expect((try parse(["model", "local"]) as ModelLegacy).words == ["local"])
  for bad in [
    ["model", "set"], ["model", "set", "sideways"], ["model", "show", "a", "b"],
    ["model", "dev", "sideways"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
  // The hidden legacy entry cannot be an instance's name.
  #expect(throws: (any Error).self) { try InstanceName(ModelLegacy._commandName) }
  #expect(ModelCommand.helpMessage().contains("show"))
  // The hidden default never names itself in usage or machine output.
  #expect(commandPath(ModelLegacy.self, under: IsoCommand.self) == ["model"])
  #expect(ModelLegacy._commandName == "[NAME]")
}

@Test func modelKeywordsAreRefusedOnlyWhenTheOlderGrammarWouldRetarget() throws {
  let show = try InstanceName("show")
  let set = try InstanceName("set")
  let dev = try InstanceName("dev")
  // An instance named after the keyword exists: the older reading is refused.
  for rest in [[], ["local"], ["remote"]] {
    #expect(ModelCommand.ambiguity("show", rest: rest, instances: [show, dev]) != nil, "\(rest)")
  }
  #expect(ModelCommand.ambiguity("set", rest: ["local"], instances: [set]) != nil)
  // A form the older grammar could not read, or no such instance: allowed.
  #expect(ModelCommand.ambiguity("show", rest: ["dev"], instances: [show, dev]) == nil)
  #expect(ModelCommand.ambiguity("set", rest: ["remote", "dev"], instances: [set, dev]) == nil)
  #expect(ModelCommand.ambiguity("show", rest: ["local"], instances: [dev]) == nil)
  let message = try #require(ModelCommand.ambiguity("show", rest: ["local"], instances: [show]))
  #expect(message.contains("`iso model show local`") && message.contains("iso model show show"))
}

// MARK: - machine-command discovery

private struct NestedMachineCommand: MachineCommand {
  static let configuration = CommandConfiguration(commandName: "nested")
}
private struct HiddenMachineCommand: MachineCommand {
  static let configuration = CommandConfiguration(commandName: "hidden", shouldDisplay: false)
}
private struct UnderHiddenMachineCommand: MachineCommand {
  static let configuration = CommandConfiguration(commandName: "under")
}
private struct HiddenGroup: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "internal", shouldDisplay: false,
    subcommands: [UnderHiddenMachineCommand.self])
}
private struct VisibleGroup: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "group",
    subcommands: [NestedMachineCommand.self, HiddenMachineCommand.self, HiddenGroup.self])
}

@Test func discoveryFindsNestedCommandsAndSkipsHiddenOnes() {
  let found = MachineCommands.collect([VisibleGroup.self, Status.self]).map {
    ObjectIdentifier($0)
  }
  #expect(
    found == [ObjectIdentifier(NestedMachineCommand.self), ObjectIdentifier(Status.self)])
}

@Test func machineDiscoveryWalksTheCommandTree() throws {
  let names = MachineCommands.all.map { $0.machineName }
  #expect(names.contains("code") && names.contains("zed"))
  #expect(Set(names).count == names.count)
  // Every advertised path dispatches to that same machine command.
  for command in MachineCommands.all {
    let path = command.machineName.split(separator: " ").map(String.init)
    let parsed = try IsoCommand.parseAsRoot(path)
    #expect(type(of: parsed) == command, "\(path)")
  }
}

/// A machine command nested under a hidden group stays unadvertised.
@Test func hiddenSubtreesAreNotAdvertised() {
  for command in MachineCommands.all {
    var current: (any ParsableCommand.Type)? = IsoCommand.self
    for component in command.machineName.split(separator: " ") {
      current = current?.configuration.subcommands.first { $0._commandName == component }
      #expect(current?.configuration.shouldDisplay == true, "\(command.machineName)")
    }
  }
}

@Test func validateFailsTheCommandOnlyAfterAFailedCheck() throws {
  try ValidateOutcome(failed: 0, notChecked: 3).requireSucceeded()
  #expect(throws: ExitCode.failure) {
    try ValidateOutcome(failed: 1, notChecked: 0).requireSucceeded()
  }
}

@Test func previewsScheduleNoUpdateCheck() throws {
  #expect(LoadIntent.normal.checksForUpdates && LoadIntent.normal.attachesSecretStore)
  #expect(!LoadIntent.preview.checksForUpdates && !LoadIntent.preview.attachesSecretStore)
  // A devcontainer dry run keeps the lazy store for a git-repo PAT only.
  #expect(!LoadIntent.dryRun(true).checksForUpdates && LoadIntent.dryRun(true).attachesSecretStore)
  #expect(LoadIntent.dryRun(false) == .normal)
  // Each command's own choice, not just the enum.
  #expect((try parse(["up", "--dry-run"]) as Up).loadIntent == .devcontainerPreview)
  #expect((try parse(["up"]) as Up).loadIntent == .normal)
  #expect((try parse(["start", "--dry-run"]) as Start).loadIntent == .devcontainerPreview)
  #expect((try parse(["setup", "--dry-run"]) as Setup).loadIntent == .devcontainerPreview)
  #expect((try parse(["run", "claude", "--dry-run"]) as RunCommand).loadIntent == .preview)
  #expect((try parse(["run", "claude"]) as RunCommand).loadIntent == .normal)
}

@Test func uncertainOperationsKeepTheirIDAndOnlySuggestRealFlags() throws {
  let id = HostOperationID.generate()
  let host = try HostAlias("studio")
  let retry = uncertainMessage("reply lost", host: host, id, retryable: true)
  #expect(
    retry.contains("--operation-id \(id)") && retry.contains("iso host operation studio \(id)"))
  let check = uncertainMessage("reply lost", host: host, id, retryable: false)
  #expect(!check.contains("--operation-id") && check.contains("iso host operation studio \(id)"))
}

@Test func workloadExitBecomesTheProcessStatus() {
  #expect(throws: ExitCode(7)) { try IsoCLI.run { throw WorkloadExit(.exited(7)) } }
  #expect(throws: ExitCode(1)) { try IsoCLI.run { throw WorkloadExit(.signaled(15)) } }
  #expect(throws: ExitCode(3)) { try IsoCLI.run { throw WorkloadExit(.exited(3), reported: true) } }
}

@Test func destroyAllRefusesANameBeforeAnyWork() {
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["destroy", "vm-a", "--all"]) }
}
