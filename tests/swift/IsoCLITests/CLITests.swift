import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Testing

@testable import IsoCLI

@Test(arguments: ["bash", "zsh", "fish"])
func staticCompletionScriptsAreGenerated(_ shell: String) throws {
  let script = try #require(CompletionScripts.script(for: shell))
  for command in ["setup", "validate", "completions"] { #expect(script.contains(command)) }
  // No runtime discovery hooks (C-02).
  #expect(!script.contains("COMPLETE="))
  #expect(!script.contains("---completion"))
}

@Test func unsupportedShellsAreActionableErrors() {
  #expect(CompletionScripts.script(for: "powershell") == nil)
  #expect(CompletionScripts.script(for: "elvish") == nil)
  #expect(CompletionScripts.unsupportedMessage("powershell").contains("unsupported shell"))
  #expect(
    CompletionScripts.unsupportedMessage("tcsh").contains("supported shells: bash, zsh, fish"))
}

@Test func globalOptionsParseBeforeOrAfterTheSubcommand() throws {
  for argv in [["--config", "/x.jsonc", "validate"], ["validate", "--config", "/x.jsonc"]] {
    let command = try IsoCommand.parseAsRoot(argv)
    let validate = try #require(command as? Validate)
    #expect(validate.global.config == "/x.jsonc")
  }
  #expect(try IsoCommand.parseAsRoot(["setup", "--config-only"]) is Setup)
  for command in ["init", "quickstart"] {
    #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot([command]) }
  }
}

final class RecordingStreams: OutputStreams, @unchecked Sendable {
  var stdout: [String] = []
  var stderr: [String] = []
  func out(_ line: String) { stdout.append(line) }
  func write(_ text: String) { stdout.append(contentsOf: rustLinesForTest(text)) }
  func error(_ line: String) { stderr.append(line) }
}

@Test func configOnlySetupCreatesOnceAndReportsExisting() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "iso-cli-\(UUID().uuidString)"
  ).path
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/config.jsonc"
  let streams = RecordingStreams()
  try SetupConfigOnly.run(path, format: .jsonc, output: streams)
  try SetupConfigOnly.run(path, format: .jsonc, output: streams)
  #expect(
    streams.stdout == [
      "Created \(path). Edit to customize, or leave as-is for defaults.",
      "Config file already exists at \(path); left unchanged.",
    ])
}

@Test func writableTargetRejectsLegacyTOML() {
  let options = try? GlobalOptions.parse(["--config", "/x/config.toml"])
  #expect(options != nil)
  #expect(throws: (any Error).self) { try options!.writableTarget(environment: .empty) }
}

private struct Directories: ConfigFileSystem {
  let existing: Set<String>
  func exists(_ path: String) -> Bool { existing.contains(path) }
  func isDirectory(_ path: String) -> Bool { existing.contains(path) }
}

@Test func validateReportsWarningsAndPATResolution() throws {
  let value = try ConfigLoader.parse(
    Array(
      #"{"github": {"pat": {"a/fine": {"token": "cmd:printf github_pat_SYNTHETIC"}, "b/classic": {"token": "ghp_SYNTHETIC"}, "c/broken": {"token": "cmd:exit 3"}}}}"#
        .utf8), format: .jsonc, path: "c", limits: .configuration)
  let config = try ConfigLoader.decode(
    value, path: "c", environment: ConfigEnvironment(home: "/nohome", variables: [:]))
  let streams = RecordingStreams()
  try ValidateReport.run(
    config: config, resolver: CredentialResolver(environment: ["PATH": "/usr/bin:/bin"]),
    fileSystem: Directories(existing: []), output: streams)
  #expect(streams.stdout.first == "Validating config (backend: apple-container)...")
  #expect(
    streams.stdout.contains(
      "  warning: data_dir parent '/nohome' does not exist (will be created on setup)"))
  #expect(
    streams.stdout.contains("  github.pat.\"a/fine\": ok (resolves, fine-grained PAT format)"))
  #expect(streams.stdout.contains { $0.hasPrefix("  github.pat.\"b/classic\": warning") })
  #expect(
    streams.stdout.contains {
      $0.hasPrefix(
        "  github.pat.\"c/broken\": FAILED to resolve token (Secret command failed (exit 3)")
    })
  #expect(streams.stdout.last == "Config OK")
  #expect(!streams.stdout.joined().contains("SYNTHETIC"))
}

private struct FixedLogin: GitHubUserProbe {
  func userLogin(token: Secret<String>) throws -> String { "octocat" }
}

private func vaultPATConfig() throws -> IsoConfig {
  let value = try ConfigLoader.parse(
    Array(
      #"{"github": {"pat": {"a/one": {"token": "vault:one"}, "b/two": {"token": "vault:two"}}}}"#
        .utf8), format: .jsonc, path: "c", limits: .configuration)
  return try ConfigLoader.decode(
    value, path: "c", environment: ConfigEnvironment(home: "/nohome", variables: [:]))
}

@Test func validateLeavesStoredPATsAloneWithoutProbe() throws {
  let secrets = CountingSecrets(["one": "github_pat_1", "two": "github_pat_2"])
  let streams = RecordingStreams()
  try ValidateReport.run(
    config: try vaultPATConfig(),
    resolver: CredentialResolver(environment: [:], secrets: secrets),
    fileSystem: Directories(existing: []), output: streams)
  #expect(secrets.calls.isEmpty)
  #expect(streams.stdout.filter { $0.contains("not resolved") }.count == 2)
  #expect(streams.stdout.last == "Config OK")
}

@Test func validateResolvesStoredPATsInOneUnlockWhenAsked() throws {
  let secrets = CountingSecrets(["one": "github_pat_1", "two": "classic"])
  let streams = RecordingStreams()
  try ValidateReport.run(
    config: try vaultPATConfig(),
    resolver: CredentialResolver(environment: [:], secrets: secrets),
    fileSystem: Directories(existing: []), output: streams, probe: FixedLogin())
  #expect(secrets.calls.count == 1)
  #expect(
    streams.stdout.contains("  github.pat.\"a/one\": ok (resolves, fine-grained PAT format)"))
  #expect(streams.stdout.contains { $0.hasPrefix("  github.pat.\"b/two\": warning") })

  let missing = CountingSecrets(["one": "github_pat_1"])
  let failed = RecordingStreams()
  try ValidateReport.run(
    config: try vaultPATConfig(),
    resolver: CredentialResolver(environment: [:], secrets: missing),
    fileSystem: Directories(existing: []), output: failed, probe: FixedLogin())
  #expect(missing.calls.count == 1)
  #expect(failed.stdout.filter { $0.contains("FAILED to resolve token") }.count == 2)
}

@Test func validateFailsOnEnvironmentalErrors() throws {
  let value = try ConfigLoader.parse(
    Array(#"{"claude": {"config_dir": "/missing"}}"#.utf8), format: .jsonc, path: "c",
    limits: .configuration)
  let config = try ConfigLoader.decode(value, path: "c", environment: .empty)
  #expect(
    throws: ConfigError.validation(errors: [
      "claude.config_dir '/missing' does not exist or is not a directory"
    ])
  ) {
    try ValidateReport.run(
      config: config, resolver: CredentialResolver(environment: [:]),
      fileSystem: Directories(existing: []), output: RecordingStreams())
  }
}

func rustLinesForTest(_ text: String) -> [String] {
  var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  if lines.last == "" { lines.removeLast() }
  return lines
}

@Test func upAndStartParseTheBaselineFlags() throws {
  let up = try #require(
    try IsoCommand.parseAsRoot([
      "up", "/p", "--no-agents", "--profile", "rust,python", "--profile", "go", "--env", "A=b",
      "--forward-port", "3000:3001", "--mem", "2048",
    ]) as? Up)
  #expect(up.project.noAgents)
  #expect(up.project.profiles == ["rust", "python", "go"])
  #expect(
    try ProjectArguments.profileTarget(up.project.profiles)?.image.rawValue == "go-python-rust")
  #expect(up.project.guestEnvironment.first?.0.rawValue == "A")
  #expect(up.project.forwardPort.first?.host == 3001)
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["up", "--new-instance"]) }
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["up", "--copy", "--mount"]) }
  #expect(throws: (any Error).self) {
    try IsoCommand.parseAsRoot(["up", "/p", "--git-repo", "https://github.com/o/r"])
  }
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["up", "--json"]) }
  #expect(try IsoCommand.parseAsRoot(["ssh", "vm", "--", "ls", "-la"]) is Shell)
  let exec = try #require(try IsoCommand.parseAsRoot(["exec", "--", "ls", "-la"]) as? Exec)
  #expect(exec.command == ["ls", "-la"] && exec.name == nil)
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["exec", "vm"]) }
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["restore", "vm"]) }
  #expect(throws: (any Error).self) {
    try IsoCommand.parseAsRoot(["restore", "vm", "--image", "x", "-y"])
  }
  #expect(try IsoCommand.parseAsRoot(["restore", "vm", "--reprovision", "-y"]) is Restore)
}

@Test func editorCommandsShareUpProjectArguments() throws {
  let zed = try #require(
    try IsoCommand.parseAsRoot([
      "zed", "/p", "--project", "/workspace/frontend", "--no-launch", "--mount", "--egress",
      "filtered", "--allow-host", "example.com", "--no-devcontainer",
    ]) as? ZedCommand)
  #expect(ZedCommand.provider == .zed && CodeCommand.provider == .code)
  #expect(try zed.launchOptions.guestPath() == GuestPath("/workspace/frontend"))
  #expect(zed.launchOptions.noLaunch)
  let request = zed.projectArguments.request(
    configTarget: ConfigTarget(path: "/c.jsonc", format: .jsonc), command: "zed")
  #expect(request.dir == "/p" && request.transport == .mount)
  #expect(request.command == "zed" && request.egressRequested)
  #expect(zed.projectArguments.egressOptions.allowHost == ["example.com"])
  let code = try #require(try IsoCommand.parseAsRoot(["code"]) as? CodeCommand)
  #expect(try code.launchOptions.guestPath() == guestWorkspace)
  #expect(!code.launchOptions.noLaunch && code.projectArguments.dir == nil)
  for bad in [
    ["code", "--project", "workspace"], ["zed", "--copy", "--mount"], ["zed", "--new-instance"],
    ["code", "/p", "--git-repo", "https://github.com/o/r"], ["zed", "--dry-run"],
    ["code", "--editor", "zed"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
  // A home-directory path given as --project (with no DIR) is refused, not
  // silently replaced by the current directory; ordinary guest paths that
  // also exist on macOS are not.
  // The home is the configuration environment's, checked when the command
  // runs, not the process's at parse time.
  let home = FileManager.default.temporaryDirectory.appending(path: "iso-home-\(UUID())").path
  try FileManager.default.createDirectory(
    atPath: home + "/project", withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: home) }
  let homeProject = try #require(
    try IsoCommand.parseAsRoot(["zed", "--project", home + "/project"]) as? ZedCommand)
  #expect(throws: (any Error).self) {
    try homeProject.rejectHostHomeProject(GuestPath(home + "/project"), home: home)
  }
  try homeProject.rejectHostHomeProject(GuestPath(home + "/project"), home: "/elsewhere")
  let withDir = try #require(
    try IsoCommand.parseAsRoot(["zed", "/p", "--project", home]) as? ZedCommand)
  try withDir.rejectHostHomeProject(GuestPath(home), home: home)
  for guest in ["/tmp", "/opt", "/usr/local"] {
    let code = try #require(
      try IsoCommand.parseAsRoot(["code", "--project", guest]) as? CodeCommand)
    try code.rejectHostHomeProject(GuestPath(guest), home: home)
  }
  #expect(throws: (any Error).self) {
    try IsoCommand.parseAsRoot(["editor", "--project", "workspace"])
  }
  let up = try #require(try IsoCommand.parseAsRoot(["up", "/p"]) as? Up)
  #expect(
    !up.project.request(
      configTarget: ConfigTarget(path: "/c.jsonc", format: .jsonc), command: "up"
    ).egressRequested)
  let editor = try #require(try IsoCommand.parseAsRoot(["editor", "--editor", "zed"]) as? Editor)
  #expect(editor.editor == .zed)
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["editor", "--editor", "vim"]) }
}

@Test func startRefusalsNameTheNextStep() {
  var options = StoppedInstanceSelection()
  #expect(Start.noStoppedInstanceMessage(options).hasPrefix("No stopped instances exist."))
  options.workspaceDirectory = "/p"
  options.devcontainerPath = "/p/dc.json"
  let message = Start.noStoppedInstanceMessage(options)
  #expect(message.contains("creation options belong to `iso up`"))
  #expect(message.contains("iso up /p"))
}

@Test func plainPullStagesOnlyInStageModeOrWithReview() {
  #expect(!Pull.stages(review: false, mode: .direct))
  #expect(Pull.stages(review: false, mode: .stage))
  #expect(Pull.stages(review: true, mode: .direct))
}

@Test func pullFlagsAreMutuallyExclusive() throws {
  for bad in [
    ["pull", "--review", "--apply"], ["pull", "--apply", "--discard"],
    ["pull", "--stage-id", "x"], ["pull", "--apply", "--dir", "d"], ["pull", "--apply", "--stat"],
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try IsoCommand.parseAsRoot(bad) }
  }
  #expect(try IsoCommand.parseAsRoot(["pull", "--apply", "--stage-id", "x"]) is Pull)
  #expect(try IsoCommand.parseAsRoot(["pull", "--stat"]) is Pull)
}
