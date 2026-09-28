import ArgumentParser
import CoopConfiguration
import CoopCore
import CoopHost
import Foundation
import Testing

@testable import CoopCLI

@Test func agentCommandsParseLikeTheBaseline() throws {
  let claude = try #require(
    try CoopCommand.parseAsRoot(["claude", "myvm", "--", "--model", "opus"]) as? ClaudeCommand)
  #expect(claude.name?.rawValue == "myvm")
  #expect(passthrough(claude.args) == ["--model", "opus"])
  #expect(!claude.ask)
  let bare = try #require(
    try CoopCommand.parseAsRoot(["claude", "myvm", "--model", "opus"]) as? ClaudeCommand)
  #expect(passthrough(bare.args) == ["--model", "opus"])
  let ask = try #require(
    try CoopCommand.parseAsRoot(["claude", "--ask", "myvm"]) as? ClaudeCommand)
  #expect(ask.ask)
  #expect(try CoopCommand.parseAsRoot(["ca"]) is ClaudeAgentsCommand)
  let agents = try #require(
    try CoopCommand.parseAsRoot(["ca", "myvm", "--", "--cwd", "/workspace"])
      as? ClaudeAgentsCommand)
  #expect(passthrough(agents.args) == ["--cwd", "/workspace"])
  let codex = try #require(
    try CoopCommand.parseAsRoot(["codex", "myvm", "--ask", "--", "--model", "gpt-5"])
      as? CodexCommand)
  #expect(splitAsk(codex.ask, codex.args) == (true, ["--model", "gpt-5"]))
  #expect(splitAsk(false, ["x", "--ask"]) == (false, ["x", "--ask"]))
  #expect(throws: (any Error).self) { try CoopCommand.parseAsRoot(["claude", "Bad!"]) }
  let update = try #require(
    try CoopCommand.parseAsRoot(["agent", "update", "dev", "--codex", "-y"]) as? AgentUpdateCommand)
  #expect(update.codex && !update.claude && update.yes)
  #expect(throws: (any Error).self) {
    try CoopCommand.parseAsRoot(["proxy", "setup", "--openai", "--anthropic"])
  }
  #expect(
    try CoopCommand.parseAsRoot(["proxy", "setup", "--vm", "dev", "--api-key"]) is ProxySetup)
}

@Test func modelWordsAreNameThenCommand() throws {
  #expect(try ModelCommand.parse([]) == (nil, nil))
  #expect(try ModelCommand.parse(["local"]) == (nil, .local))
  #expect(try ModelCommand.parse(["dev"]) == (try InstanceName("dev"), nil))
  #expect(try ModelCommand.parse(["dev", "remote"]) == (try InstanceName("dev"), .remote))
  for bad in [["local", "dev"], ["dev", "remote", "extra"], ["Bad!"], ["dev", "sideways"]] {
    #expect(throws: (any Error).self, "\(bad)") { try ModelCommand.parse(bad) }
  }
}

@Test func modelStatusAndSwitchReports() throws {
  let endpoint = try LocalModel(hostURL: "http://localhost:11434", model: "qwen", authToken: nil)
  #expect(
    try ModelCommand.toolLine("Claude", mode: .local, endpoint: endpoint)
      == "Claude    local — qwen @ http://localhost:11434/ (via SSH reverse tunnel)")
  #expect(
    try ModelCommand.toolLine("Codex", mode: .local, endpoint: nil)
      == "Codex     cloud (no local endpoint configured)")
  #expect(
    try ModelCommand.toolLine("Codex", mode: .remote, endpoint: endpoint) == "Codex     cloud")

  var lines = ModelCommand.reportLines(
    "dev", mode: .local, claudeLocal: true, codexLocal: true, applied: true)
  #expect(lines[0] == "'dev' now uses a local model for Claude and Codex.")
  #expect(!lines.contains { $0.contains("stays on cloud") })
  #expect(lines.last!.contains("relaunch"))
  lines = ModelCommand.reportLines(
    "dev", mode: .local, claudeLocal: true, codexLocal: false, applied: true)
  #expect(lines[0] == "'dev' now uses a local model for Claude.")
  let warning = try #require(lines.first { $0.contains("stays on cloud") })
  #expect(warning.contains("Codex") && warning.contains("codex.local_model"))
  #expect(!warning.contains("Claude"))
  lines = ModelCommand.reportLines(
    "dev", mode: .remote, claudeLocal: false, codexLocal: false, applied: false)
  #expect(
    lines == [
      "'dev' now uses cloud models for Claude and Codex.", "Saved — applies on next start.",
    ])
}

/// A private data directory with one stopped instance, loaded as a command.
private struct CLIFixture {
  let root: String
  let context: CommandContext
  let streams = RecordingStreams()

  init(_ extra: String = "") throws {
    root =
      FileManager.default.temporaryDirectory.appending(path: "coop-agent-\(UUID().uuidString)")
      .path
    let instanceDirectory = root + "/data/backends/apple-container-v1/instances/dev"
    try FileManager.default.createDirectory(
      atPath: instanceDirectory, withIntermediateDirectories: true)
    try Data(#"{"name":"dev","index":0,"image":"default"}"#.utf8).write(
      to: URL(fileURLWithPath: instanceDirectory + "/instance.json"))
    let environment = ConfigEnvironment(
      home: root, variables: ["HOME": root, "PATH": "/usr/bin:/bin"])
    let config = try ConfigLoader.decode(
      ConfigLoader.parse(
        Array(#"{"data_dir": "\#(root)/data"\#(extra)}"#.utf8), format: .jsonc, path: "c",
        limits: .configuration), path: "c", environment: environment)
    let diagnostics = Diagnostics(verbosity: 0) { _ in }
    context = CommandContext(
      environment: environment, config: config,
      backend: AppleBackend(
        config: config, environment: environment.variables, executable: nil,
        diagnostics: diagnostics), output: streams, diagnostics: diagnostics,
      ssh: SSHClient(environment: environment.variables))
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }
}

@Test func stoppedModelSwitchesPersistAndReport() throws {
  let fixture = try CLIFixture(
    #", "claude": {"local_model": {"host_url": "http://localhost:11434", "model": "qwen"}}"#)
  defer { fixture.remove() }
  let instance = try InstanceStore.resolve(fixture.context.config, name: nil)
  // The runtime is unavailable here, so applying live fails: a stopped
  // instance must not be probed without a sidecar.
  #expect(throws: (any Error).self) { try ModelCommand.setLocal(fixture.context, instance) }
  #expect(try ModelState.loadOrDefault(instance).mode == .local)
  try ModelCommand.status(fixture.context, instance)
  #expect(
    fixture.streams.stdout == [
      "Instance: dev", "Mode:     local",
      "Claude    local — qwen @ http://localhost:11434/ (via SSH reverse tunnel)",
      "Codex     cloud (no local endpoint configured)",
    ])
  // Non-interactive with nothing configured: refused before saving.
  let bare = try CLIFixture()
  defer { bare.remove() }
  let bareInstance = try InstanceStore.resolve(bare.context.config, name: nil)
  let error = try #require(throws: (any Error).self) {
    try ModelCommand.setLocal(bare.context, bareInstance)
  }
  #expect("\(error)".contains("No local model endpoint configured for 'dev'"))
  #expect(try ModelState.tryLoad(bareInstance) == nil)
}

@Test func proxySetupStoresOnlyInTheKeychainAndWritesTheReference() throws {
  let fixture = try CLIFixture()
  defer { fixture.remove() }
  let tool = fixture.root + "/security"
  try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(fixture.root)/argv\"\n".utf8).write(
    to: URL(fileURLWithPath: tool))
  chmod(tool, 0o755)
  let configPath = fixture.root + "/config.jsonc"
  try ProxySetup.run(
    fixture.context, provider: .openai, vm: nil, apiKey: true,
    target: (configPath, .jsonc), token: { Secret("sk-synthetic") }, keychainTool: tool)
  let written = try ConfigLoader.load(
    .file(path: configPath, format: .jsonc), environment: fixture.context.environment)
  #expect(
    written.proxy.openai?.credential.command.expose()
      == "cmd:security find-generic-password -s coop-openai -a openai -w")
  #expect(written.proxy.openai?.auth == .bearer)
  #expect(
    !(String(data: FileManager.default.contents(atPath: configPath)!, encoding: .utf8)!).contains(
      "sk-synthetic"))
  #expect(fixture.streams.stderr.joined().contains("proxy.openai.credential"))
  #expect(!fixture.streams.stderr.joined().contains("sk-synthetic"))

  // Per-VM override: service suffixed with the VM, stored in proxy.json.
  try ProxySetup.run(
    fixture.context, provider: .anthropic, vm: "dev", apiKey: true, target: (configPath, .jsonc),
    token: { Secret("sk-ant-synthetic") }, keychainTool: tool)
  let instance = try InstanceStore.resolve(fixture.context.config, name: nil)
  let state = try ProxyState.load(instance)
  #expect(state.anthropic?.auth == .apiKey)
  #expect(
    state.anthropic?.credential
      == .reference(
        CredentialReference(
          "cmd:security find-generic-password -s coop-anthropic-dev -a anthropic -w")!))

  // Unknown VM or a failed Keychain write: nothing is written anywhere.
  #expect(throws: (any Error).self) {
    try ProxySetup.run(
      fixture.context, provider: .openai, vm: "ghost", apiKey: false, target: (configPath, .jsonc),
      token: {
        Issue.record("prompted for an unknown VM")
        return Secret("x")
      }, keychainTool: tool)
  }
  try Data("#!/bin/sh\nexit 1\n".utf8).write(to: URL(fileURLWithPath: tool))
  let before = FileManager.default.contents(atPath: configPath)
  let error = try #require(throws: (any Error).self) {
    try ProxySetup.run(
      fixture.context, provider: .anthropic, vm: nil, apiKey: false, target: (configPath, .jsonc),
      token: { Secret("sk-2") }, keychainTool: tool)
  }
  #expect("\(error)".contains("Failed to store the anthropic credential in the macOS Keychain"))
  #expect(FileManager.default.contents(atPath: configPath) == before)
}
