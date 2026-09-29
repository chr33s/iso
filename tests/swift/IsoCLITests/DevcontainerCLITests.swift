import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import Testing

@testable import IsoCLI

private func temporaryDirectory() throws -> String {
  let path = FileManager.default.temporaryDirectory.appending(
    path: "iso-cli-dc-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
  return String(cString: realpath(path, &resolved))
}

@Test func devcontainerSubcommandsParse() throws {
  let check = try #require(
    try IsoCommand.parseAsRoot(["devcontainer", "check", ".devcontainer/devcontainer.json"])
      as? DevcontainerCheck)
  #expect(check.path == ".devcontainer/devcontainer.json")
  #expect(check.stage == .both && !check.json)
  let json = try #require(
    try IsoCommand.parseAsRoot(["devcontainer", "check", "x.json", "--json", "--stage", "start"])
      as? DevcontainerCheck)
  #expect(json.json && json.stage == .start)
  #expect(try IsoCommand.parseAsRoot(["devcontainer", "ignore", "."]) is DevcontainerIgnore)
  #expect(
    (try IsoCommand.parseAsRoot(["devcontainer", "status"]) as? DevcontainerStatus)?.project == nil
  )
  #expect(
    (try IsoCommand.parseAsRoot(["devcontainer", "status", "."]) as? DevcontainerStatus)?.project
      == ".")
  #expect(try IsoCommand.parseAsRoot(["devcontainer", "clear", "."]) is DevcontainerClear)
  #expect(try IsoCommand.parseAsRoot(["devcontainer"]) is DevcontainerCommand)
  #expect(throws: (any Error).self) { try IsoCommand.parseAsRoot(["devcontainer", "check"]) }
  #expect(throws: (any Error).self) {
    try IsoCommand.parseAsRoot(["devcontainer", "check", "x", "--stage", "later"])
  }
}

@Test func bareDevcontainerIsAUsageError() throws {
  #expect(throws: ExitCode(2)) { try DevcontainerCommand().run() }
}

@Test func setupDevcontainerFlagsAreExclusive() throws {
  #expect(throws: (any Error).self) {
    try IsoCommand.parseAsRoot(["setup", "--devcontainer", "x", "--no-devcontainer"])
  }
  let setup = try #require(
    try IsoCommand.parseAsRoot(["setup", "--workspace", "/w", "--dry-run"]) as? Setup)
  #expect(setup.workspace == "/w" && setup.dryRun)
}

@Test func checkBothReusesTheSetupGuestUser() throws {
  var translation = DevcontainerTranslation()
  translation.guestUser = try GuestUser("vscode")
  #expect(DevcontainerCheck.assumedGuestUser(translation).rawValue == "vscode")
  #expect(DevcontainerCheck.assumedGuestUser(nil).rawValue == "ubuntu")
}

@Test func checkWritesJSONToStdoutAndReportsToStderr() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let file = directory + "/devcontainer.json"
  try Data(#"{"remoteUser": "vscode", "containerEnv": {"A": "1"}}"#.utf8).write(
    to: URL(fileURLWithPath: file))
  final class Captured: @unchecked Sendable {
    var text = ""
  }
  let captured = Captured()
  let resolver = DevcontainerResolver(
    environment: [:], diagnostics: Diagnostics(verbosity: 0) { _ in },
    errorSink: { captured.text += $0 })

  let streams = RecordingStreams()
  try DevcontainerCheck.run(
    path: file, stage: .both, json: true, resolver: resolver, output: streams)
  let json = streams.stdout.joined(separator: "\n")
  #expect(json.hasPrefix("{\n  \"setup\": {"))
  // Start assumes the image was built with the setup-stage `remoteUser`,
  // so `containerEnv` applies.
  #expect(json.contains("\"note\": \"A\""))
  #expect(captured.text.isEmpty)

  let text = RecordingStreams()
  try DevcontainerCheck.run(path: file, stage: .both, json: false, resolver: resolver, output: text)
  #expect(text.stdout.isEmpty)
  #expect(text.stderr == ["setup-stage translation:", "", "start-stage translation:"])
  #expect(captured.text.contains("baked into the image at setup time"))
  #expect(captured.text.contains("matches the image's persisted guest user"))

  #expect(throws: (any Error).self) {
    try DevcontainerCheck.run(
      path: directory + "/missing.json", stage: .setup, json: false, resolver: resolver,
      output: RecordingStreams())
  }
}

@Test func preferenceCommandsMatchTheBaselineText() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let project = directory + "/project"
  try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
  let preferences = directory + "/state/devcontainer_preferences.json"
  let streams = RecordingStreams()
  try DevcontainerStatus.run(project: nil, preferencePath: preferences, output: streams)
  try DevcontainerIgnore.run(project: project, preferencePath: preferences, output: streams)
  try DevcontainerStatus.run(project: nil, preferencePath: preferences, output: streams)
  try DevcontainerStatus.run(project: project, preferencePath: preferences, output: streams)
  try DevcontainerStatus.run(project: directory, preferencePath: preferences, output: streams)
  try DevcontainerClear.run(project: project, preferencePath: preferences, output: streams)
  try DevcontainerClear.run(project: project, preferencePath: preferences, output: streams)
  #expect(
    streams.stdout == [
      "No persistent devcontainer opt-outs recorded.",
      "Devcontainer discovery disabled for project \(project)",
      "Persistent devcontainer opt-outs:",
      "  \(project)",
      "Devcontainer discovery disabled for project \(project)",
      "Devcontainer discovery enabled for project \(directory)",
      "Cleared devcontainer opt-out for project \(project)",
      "No persistent devcontainer opt-out recorded for project \(project)",
    ])
  #expect(!FileManager.default.fileExists(atPath: preferences))
  do {
    try DevcontainerIgnore.run(
      project: directory + "/missing", preferencePath: preferences, output: streams)
    Issue.record("expected an error")
  } catch {
    #expect(
      "\(error)"
        == "Failed to resolve project directory \(directory)/missing for devcontainer preference\n\nCaused by:\n    No such file or directory (os error 2)"
    )
  }
}
