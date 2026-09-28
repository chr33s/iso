import ArgumentParser
import CoopConfiguration
import CoopCore
import CoopHost
import Foundation
import Testing

@testable import CoopCLI

@Test func githubAssignmentCLIRequiresAValidVMAndEntry() throws {
  let command = try CoopCommand.parseAsRoot([
    "github", "assign-pat", "--vm", "projects", "--repo", " org/entry\n",
  ])
  let assign = try #require(command as? GitHubAssignPAT)
  #expect(assign.vm.rawValue == "projects")
  #expect(assign.repo.rawValue == "org/entry")
  for argv in [
    ["github", "assign-pat", "--repo", "org/entry"],
    ["github", "assign-pat", "--vm", "projects"],
    ["github", "assign-pat", "--vm", "../escape", "--repo", "org/entry"],
    ["github", "assign-pat", "--vm", "projects", "--repo", "bad"],
    ["github", "unassign-pat"],
    ["github", "rotate-pat"],
    ["github", "forget-pat"],
  ] {
    #expect(throws: (any Error).self, "\(argv)") { try CoopCommand.parseAsRoot(argv) }
  }
  #expect(try CoopCommand.parseAsRoot(["github", "setup-pat"]) is GitHubSetupPAT)
  let status = try #require(
    try CoopCommand.parseAsRoot(["github", "status", "--vm", "p", "--probe", "--json"])
      as? GitHubStatus)
  #expect(status.vm?.rawValue == "p" && status.probe && status.json)
  #expect(try (CoopCommand.parseAsRoot(["validate", "--probe"]) as? Validate)?.probe == true)
}

@Test func githubStatusWritesTheReportToStdout() throws {
  let home = FileManager.default.temporaryDirectory.appending(path: "coop-cli-gh-\(UUID())").path
  defer { try? FileManager.default.removeItem(atPath: home) }
  let environment = ConfigEnvironment(home: home, variables: ["PATH": "/usr/bin:/bin"])
  let value = try ConfigLoader.parse(
    Array(#"{"github": {"mode": "pat", "skip": ["a/b"]}}"#.utf8), format: .jsonc, path: "c",
    limits: .configuration)
  let config = try ConfigLoader.decode(value, path: "c", environment: environment)
  let streams = RecordingStreams()
  let diagnostics = Diagnostics(verbosity: 0, sink: { _ in })
  let context = CommandContext(
    environment: environment, config: config,
    backend: AppleBackend(
      config: config, environment: environment.variables, executable: nil,
      diagnostics: diagnostics),
    output: streams, diagnostics: diagnostics, ssh: SSHClient(environment: environment.variables))
  try GitHubStatus.run(context, vm: nil, probe: false, json: false)
  try GitHubStatus.run(context, vm: nil, probe: false, json: true)
  #expect(
    streams.stdout == [
      "github mode: pat", "entries (0):", "skip (1):", "  a/b", "{", "  \"mode\": \"pat\",",
      "  \"entries\": [],", "  \"skip\": [", "    \"a/b\"", "  ]", "}",
    ])
}

@Test func validateProbeChecksEachResolvedToken() throws {
  let bin = FileManager.default.temporaryDirectory.appending(path: "coop-cli-probe-\(UUID())").path
  defer { try? FileManager.default.removeItem(atPath: bin) }
  try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
  // Answers by token: the fine-grained one authenticates, the other is 401.
  let curl = """
    #!/bin/sh
    input=$(cat)
    printf '%s\\n' "$*" >> "$(dirname "$0")/argv"
    case "$input" in
      *github_pat_SYNTHETIC*) printf '{"login":"oct\\033cat"}\\n200' ;;
      *) printf '{}\\n401' ;;
    esac
    """
  try Data(curl.utf8).write(to: URL(fileURLWithPath: bin + "/curl"))
  chmod(bin + "/curl", 0o755)
  let value = try ConfigLoader.parse(
    Array(
      #"{"github": {"pat": {"a/fine": {"token": "cmd:printf github_pat_SYNTHETIC"}, "b/classic": {"token": "ghp_SYNTHETIC"}, "c/broken": {"token": "cmd:exit 3"}}}}"#
        .utf8), format: .jsonc, path: "c", limits: .configuration)
  let config = try ConfigLoader.decode(
    value, path: "c", environment: ConfigEnvironment(home: "/nohome", variables: [:]))
  let streams = RecordingStreams()
  let environment = ["PATH": bin + ":/usr/bin:/bin"]
  try ValidateReport.run(
    config: config, resolver: CredentialResolver(environment: environment),
    fileSystem: NoDirectories(), output: streams,
    probe: GitHubAPI(
      tools: HostTools(environment: environment), diagnostics: Diagnostics(verbosity: 0)))
  let lines = streams.stdout
  let fine = try #require(
    lines.firstIndex(of: "  github.pat.\"a/fine\": ok (resolves, fine-grained PAT format)"))
  #expect(lines[fine + 1] == "    probe: /user as 'oct?cat'")
  let classic = try #require(
    lines.firstIndex { $0.hasPrefix("  github.pat.\"b/classic\": warning") })
  #expect(
    lines[classic + 1]
      == "    probe: FAILED (GET /user returned HTTP 401 (token may be invalid or revoked))")
  // A token that does not resolve is not probed.
  let broken = try #require(lines.firstIndex { $0.hasPrefix("  github.pat.\"c/broken\": FAILED") })
  #expect(lines[broken + 1] == "Config OK")
  #expect(!lines.joined().contains("SYNTHETIC"))
  let argv = try String(contentsOfFile: bin + "/argv", encoding: .utf8)
  #expect(!argv.contains("SYNTHETIC"))
}

private struct NoDirectories: ConfigFileSystem {
  func exists(_ path: String) -> Bool { false }
  func isDirectory(_ path: String) -> Bool { false }
}
