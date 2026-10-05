import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private func parse(_ text: String) throws -> ParsedDevcontainer {
  try ParsedDevcontainer(path: "test.json", text: text)
}

private func translate(
  _ text: String, _ inputs: DevcontainerTranslatorInputs = .init(),
  _ stage: DevcontainerStage = .start
) throws -> DevcontainerTranslation {
  Devcontainer.translate(try parse(text), inputs: inputs, stage: stage)
}

private func rows(_ t: DevcontainerTranslation, _ key: String) -> [DevcontainerReport.Entry] {
  t.report.entries.filter { $0.key == key }
}

private func temporaryDirectory() throws -> String {
  let path = FileManager.default.temporaryDirectory.appending(
    path: "iso-dc-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return canonicalPath(path)!
}

private func write(_ text: String, _ path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try Data(text.utf8).write(to: URL(fileURLWithPath: path))
}

private func sha256(_ text: String) -> String { sha256Hex(Array(text.utf8)) }

private let sampleDigest =
  "sha256:b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"

// MARK: - Parsing and translation

@Test func parseSupportedSubset() throws {
  let file = try parse(
    #"""
    {
      "name": "demo",
      "image": "ignored",
      "hostRequirements": { "cpus": 4, "memory": "4GiB", "storage": "16GiB" },
      "containerEnv": { "FOO": "bar" },
      "forwardPorts": [3000, "8080:8081"],
      "postStartCommand": "echo hi",
      "features": { "ghcr.io/devcontainers/features/rust:1": {} },
      "remoteUser": "root"
    }
    """#)
  #expect(file.raw.name == "demo")
  #expect(file.raw.hostRequirements?.cpus == 4)
}

@Test func cliWinsOverDevcontainerCpusAndPostStart() throws {
  let text = #"{ "hostRequirements": { "cpus": 4 }, "postStartCommand": "x" }"#
  let defaults = try translate(text)
  #expect(defaults.vcpus == 4)
  #expect(defaults.postStart == "x")
  let overridden = try translate(text, .init(cliVcpus: 8, cliPostStart: "y"))
  #expect(overridden.vcpus == nil)
  #expect(overridden.postStart == nil)
  #expect(
    rows(overridden, "postStartCommand").first?.note
      == #"CLI --post-start overrides devcontainer value "x""#)
}

@Test func storageSizesDiskOnlyAtStart() throws {
  let text = #"{ "hostRequirements": { "storage": "16GiB" } }"#
  #expect(try translate(text, .init(), .setup).disk == nil)
  #expect(try translate(text).disk == GiB(16))
}

@Test func featuresMapToProfilesOrOCIRequests() throws {
  let t = try translate(
    #"""
    { "features": {
      "ghcr.io/devcontainers/features/rust:1": {},
      "node": {},
      "ghcr.io/devcontainers/features/docker-in-docker:2": {}
    } }
    """#, .init(), .setup)
  #expect(t.profiles.contains("rust"))
  #expect(t.profiles.contains("node"))
  #expect(
    t.ociFeatureRequests.contains { $0.rawID.hasPrefix("ghcr.io/devcontainers/features/docker") })
}

@Test func featuresCollectSupportedOCIRequests() throws {
  let t = try translate(
    #"{ "features": { "ghcr.io/devcontainers/features/github-cli:1": { "version": "latest" } } }"#,
    .init(), .setup)
  #expect(t.ociFeatureRequests.count == 1)
  #expect(t.ociFeatureRequests[0].reference.repository == "devcontainers/features/github-cli")
  #expect(t.ociFeatureRequests[0].options.first { $0.key == "version" }?.value == "latest")
}

@Test func cliProfileOverridesMatchingFeature() throws {
  let t = try translate(#"{ "features": { "rust": {} } }"#, .init(cliProfiles: ["rust"]), .setup)
  #expect(t.profiles.isEmpty)
  #expect(rows(t, "features.rust").first?.status == .overridden)
}

@Test func remoteUserRules() throws {
  #expect(try rows(translate(#"{ "remoteUser": "root" }"#), "remoteUser").first?.status == .invalid)
  #expect(
    try rows(translate(#"{ "remoteUser": "ubuntu" }"#), "remoteUser").first?.status == .applied)
  #expect(
    try translate(#"{ "remoteUser": "vscode" }"#, .init(), .setup).guestUser?.rawValue == "vscode")

  let overridden = try translate(
    #"{ "remoteUser": "vscode" }"#, .init(cliGuestUser: try GuestUser("ubuntu")), .setup)
  #expect(overridden.guestUser == nil)
  let row = try #require(rows(overridden, "remoteUser").first)
  #expect(row.status == .overridden && row.source == .cli)

  let mismatch = try translate(
    #"{ "remoteUser": "vscode" }"#, .init(persistedGuestUser: try GuestUser("ubuntu")))
  let note = try #require(rows(mismatch, "remoteUser").first).note
  #expect(rows(mismatch, "remoteUser").first?.status == .unsupported)
  #expect(note.contains("ubuntu") && note.contains("vscode"))

  let match = try translate(
    #"{ "remoteUser": "vscode" }"#, .init(persistedGuestUser: try GuestUser("vscode")))
  #expect(rows(match, "remoteUser").first?.status == .applied)
}

@Test func remoteUserMismatchSkipsContainerEnv() throws {
  let t = try translate(
    #"""
    { "remoteUser": "vscode",
      "containerEnv": { "GIT_CONFIG_GLOBAL": "/home/vscode/.gitconfig.local" } }
    """#, .init(persistedGuestUser: try GuestUser("ubuntu")))
  #expect(t.guestEnvironment.isEmpty)
  #expect(rows(t, "containerEnv").first?.status == .unsupported)
}

@Test func unknownKeysAreReported() throws {
  let t = try translate(#"{ "name": "x", "wackyKey": 1, "image": "ignored" }"#)
  #expect(rows(t, "wackyKey").first?.status == .unsupported)
  #expect(!rows(t, "image").isEmpty)
}

@Test func forwardPortsNumbersAndStrings() throws {
  let t = try translate(#"{ "forwardPorts": [3000, "8080:9090"] }"#)
  #expect(t.forwardPorts.map(\.guest) == [3000, 8080])
  #expect(t.forwardPorts[1].host == 9090)
  // Equal ports render bare; different ones as `guest:host`.
  #expect(rows(t, "forwardPorts").first { $0.status == .applied }?.value == "3000,8080:9090")
}

@Test func postStartArrayJoins() throws {
  #expect(
    try translate(#"{ "postStartCommand": ["echo a", "echo b"] }"#).postStart
      == "echo a && echo b")
}

@Test func zeroCpusAreInvalid() throws {
  let t = try translate(#"{ "hostRequirements": { "cpus": 0 } }"#)
  #expect(rows(t, "hostRequirements.cpus").first?.status == .invalid)
  #expect(t.vcpus == nil)
}

@Test func containerEnvOverriddenInvalidAndEmptyBuckets() throws {
  let overridden = try translate(
    #"{ "containerEnv": { "FOO": "x", "BAR": "y" } }"#,
    .init(cliGuestEnvKeys: [try EnvVarName("FOO")]))
  #expect(overridden.guestEnvironment.map(\.name.rawValue) == ["BAR"])
  #expect(rows(overridden, "containerEnv").contains { $0.status == .overridden })

  let invalid = try translate(#"{ "containerEnv": { "GOOD": "1", "1BAD": "2", "AL SO": "3" } }"#)
  #expect(invalid.guestEnvironment.map(\.value) == ["1"])
  let note = try #require(rows(invalid, "containerEnv").first { $0.status == .invalid }).note
  #expect(note.contains("1BAD") && note.contains("AL SO"))

  // All keys overridden: no zero-count applied/invalid rows.
  let all = try translate(
    #"{ "containerEnv": { "FOO": "x" } }"#, .init(cliGuestEnvKeys: [try EnvVarName("FOO")]))
  #expect(rows(all, "containerEnv").map(\.status) == [.overridden])
}

@Test func forwardPortsAndMountsSuppressZeroCountRows() throws {
  let ports = try translate(
    #"{ "forwardPorts": [3000] }"#, .init(cliForwardPorts: [try PortForward.parse("3000")]))
  #expect(rows(ports, "forwardPorts").map(\.status) == [.overridden])
  let mounts = try translate(
    #"{ "mounts": [{ "type": "volume", "source": "v", "target": "/b" }] }"#)
  #expect(rows(mounts, "mounts").map(\.status) == [.invalid])
}

@Test func mountsUnsupportedWithWorkspaceFlag() throws {
  let t = try translate(
    #"{ "mounts": [{ "type": "bind", "source": "/a", "target": "/b" }] }"#,
    .init(cliWorkspaceOrGitRepo: true))
  #expect(rows(t, "mounts").first?.status == .unsupported)
  #expect(t.mounts.isEmpty)
}

@Test func translationRecordsAppliedPathAndHash() throws {
  let text = #"{ "containerEnv": { "GOOD": "1" } }"#
  let applied = try #require(try translate(text).applied)
  #expect(applied.path == "test.json")
  #expect(applied.source == .localFile)
  #expect(applied.contentHash == sha256(text))
}

@Test func renderValueFormsPreserveJSONValues() throws {
  let t = try translate(
    #"{ "wackyNum": 1, "wackyStr": "hello", "o": {"b": [1, 2.5, -0, 1e16, "x\ty"], "a": null, "b": 3} }"#
  )
  #expect(rows(t, "wackyNum").first?.value == "1")
  #expect(rows(t, "wackyStr").first?.value == "hello")
  // A repeated object key keeps its last value.
  #expect(try canonicalJSON(rows(t, "o").first?.value) == canonicalJSON(#"{"b":3,"a":null}"#))
  let floats = try translate(
    #"{ "f": [2.5, -0, 1e16, 1e-7, 100.0, 123456789012345678901234567890] }"#)
  let values = try #require(rows(floats, "f").first?.value)
  #expect(
    try JSONDecoder().decode([Double].self, from: Data(values.utf8))
      == [2.5, -0.0, 1e16, 1e-7, 100.0, 1.2345678901234568e29])
  #expect(try rows(translate(#"{ "image": "ignored" }"#), "image").first?.value == "ignored")
}

// MARK: - Decoding errors (serde messages and positions)

private func parseError(_ text: String) -> String? {
  do {
    _ = try parse(text)
    return nil
  } catch let error as ContextError {
    #expect(error.context == "Failed to parse test.json")
    return "\(error.cause)"
  } catch {
    return "\(error)"
  }
}

@Test func typedFieldErrorsMatchTheBaseline() {
  let cases: [(String, String)] = [
    (#"{"name":1}"#, "invalid type: integer `1`, expected a string at line 1 column 9"),
    (#"{"name":[]}"#, "invalid type: sequence, expected a string at line 1 column 8"),
    (
      #"{"containerEnv":{"A":1}}"#,
      "invalid type: integer `1`, expected a string at line 1 column 22"
    ),
    (#"{"forwardPorts":{}}"#, "invalid type: map, expected a sequence at line 1 column 16"),
    (
      #"{"hostRequirements":[]}"#,
      "invalid type: sequence, expected struct RawHostRequirements at line 1 column 20"
    ),
    (#""x""#, #"invalid type: string "x", expected struct RawDevcontainer at line 1 column 3"#),
    ("[]", "invalid type: sequence, expected struct RawDevcontainer at line 1 column 0"),
    (
      #"{"hostRequirements":{"cpus":-1}}"#,
      "invalid value: integer `-1`, expected u32 at line 1 column 30"
    ),
    (
      #"{"hostRequirements":{"cpus":5000000000}}"#,
      "invalid value: integer `5000000000`, expected u32 at line 1 column 38"
    ),
    (
      #"{"hostRequirements":{"cpus":2.0}}"#,
      "invalid type: floating point `2.0`, expected u32 at line 1 column 31"
    ),
    (
      #"{"hostRequirements":{"memory":"0"}}"#,
      "size '0' must be greater than zero at line 1 column 34"
    ),
    (
      #"{"hostRequirements":{"memory":"abc"}}"#,
      "expected a unit suffix (B, KB, MB, GB, TB; KiB/MiB/GiB/TiB also accepted): 'abc' at line 1 column 36"
    ),
    (#"{"name":"a","name":"b"}"#, "duplicate field `name` at line 1 column 18"),
    (#"{"a": }"#, "expected value at line 1 column 7"),
    (#"{"a":1} x"#, "trailing characters at line 1 column 9"),
    (#"{"a":1e400}"#, "number out of range at line 1 column 10"),
  ]
  for (text, expected) in cases { #expect(parseError(text) == expected, "\(text)") }
}

@Test func repeatedUnmodeledKeysKeepFirstPositionAndLastValue() throws {
  let t = try translate(#"{"x":1,"y":2,"x":3}"#)
  #expect(t.report.entries.map(\.key) == ["x", "y"])
  #expect(t.report.entries.map(\.value) == ["3", "2"])
  #expect(
    try translate(#"{"image":null,"features":null,"hostRequirements":{"cpus":null}}"#).report
      .entries.isEmpty)
}

// MARK: - JSONC through the shared scanner

@Test func jsoncCommentsTrailingCommasAndStrings() throws {
  let t = try translate(
    """
    {
      // a comment
      "name": "demo", // trailing
      /* block */ "k": /* inline */ 1,
      "b": [1, 2, 3,],
      "s": "a, b, c",
      "u": "https://example.com/a",
      "j": "/* not a comment */",
      "q": "v\\"",
    }
    """)
  let values = Dictionary(uniqueKeysWithValues: t.report.entries.map { ($0.key, $0.value) })
  #expect(values["name"] == "demo")
  #expect(values["k"] == "1")
  #expect(values["b"] == "[1,2,3]")
  #expect(values["s"] == "a, b, c")
  #expect(values["u"] == "https://example.com/a")
  #expect(values["j"] == "/* not a comment */")
  #expect(values["q"] == "v\"")
}

@Test func malformedJSONCIsAnErrorNotACrash() {
  #expect(parseError("{ \"k\": 1 /* dangling comment never closed") != nil)
  #expect(parseError("{ \"k\": \"oops\\") != nil)
  #expect(parseError("{ }/") != nil)
  #expect(parseError(String(repeating: "[", count: 5000)) != nil)
  #expect(parseError("") == "EOF while parsing a value at line 1 column 0")
}

// MARK: - Sizes

@Test func memorySpecUnits() throws {
  #expect(try MemorySpec.parse("4GiB").mib.value == 4096)
  #expect(try MemorySpec.parse("4096MiB").mib.value == 4096)
  #expect(try MemorySpec.parse("512MiB").mib.value == 512)
  #expect(try MemorySpec.parse("8GiB").gib.value == 8)
  #expect(try MemorySpec.parse("1g").mib.value == 954)
  #expect(try MemorySpec.parse("512mb").mib.value == 489)
  #expect(try MemorySpec.parse("4GB").mib.value == 3815)
  #expect(try MemorySpec.parse("1024").mib.value == 1)
  #expect(try MemorySpec.parse(String(2 * 1024 * 1024)).mib.value == 2)
  #expect(try MemorySpec.parse("1TiB").mib.value == 1024 * 1024)
  #expect(try MemorySpec.parse("2048KiB").mib.value == 2)
  let spec = try MemorySpec.parse("1500MiB")
  #expect(spec.mib.value == 1500 && spec.gib.value == 2)
  #expect(try MemorySpec.parse(" 1.5 g ").mib.value == 1431)
}

@Test func memorySpecRejectsGarbage() throws {
  for text in ["abc", "4 lemons", "", "0MiB", "0", "0x10GB", "GB"] {
    #expect(throws: ValidationError.self, "\(text)") { try MemorySpec.parse(text) }
  }
  #expect(throws: ValidationError.self) { try parseSizeBytes("-1GB") }
  #expect(throws: ValidationError.self) { try parseSizeBytes("infGB") }
  #expect(try parseSizeBytes("0GB") == 0)
  do {
    _ = try MemorySpec.parse("GB")
    Issue.record("expected an error")
  } catch {
    #expect(
      error.message
        == "expected '<decimal><unit>' (e.g. '4GB') or bare bytes; got 'GB': cannot parse float from empty string"
    )
  }
}

// MARK: - Mounts

@Test func mountStringAndObjectForms() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  #expect(
    try Devcontainer.parseMountString("type=bind,source=\(directory),target=/b").guestPath.rawValue
      == "/b")
  #expect(
    try Devcontainer.parseMountString("source=\(directory),target=/b,readonly").guestPath.rawValue
      == "/b")
  #expect(throws: (any Error).self) {
    try Devcontainer.parseMountString("type=volume,source=v,target=/b")
  }
  #expect(try Devcontainer.parseMountString("\(directory):/g").guestPath.rawValue == "/g")
  let object = try DevcontainerJSON.parse(
    #"{"type": "bind", "source": "\#(directory)", "target": "/b"}"#)
  #expect(try Devcontainer.parseMountEntry(object).hostPath == directory)
  let volume = try DevcontainerJSON.parse(#"{"type": "volume", "source": "/v", "target": "/b"}"#)
  #expect(throws: (any Error).self) { try Devcontainer.parseMountEntry(volume) }
  do { _ = try Devcontainer.parseMountEntry(volume) } catch {
    #expect(topMessage(error).contains("unsupported mount type"))
  }
  let string = DevcontainerJSON(.string("\(directory):/g"))
  #expect(try Devcontainer.parseMountEntry(string).guestPath.rawValue == "/g")
}

@Test func missingMountHostReportsTopLevelMessage() throws {
  let t = try translate(#"{ "mounts": ["/nonexistent-iso-dc:/x"] }"#)
  #expect(rows(t, "mounts").first?.note == "Mount host path does not exist: /nonexistent-iso-dc")
}

// MARK: - Report

@Test func reportRendersColumnsWithTwoSpaces() throws {
  let rendered = try translate(#"{ "hostRequirements": { "cpus": 4 } }"#).report.render()
  #expect(rendered.contains("test.json"))
  #expect(rendered.contains("hostRequirements.cpus"))
  #expect(rendered.contains("applied"))
  var report = DevcontainerReport()
  report.push("name", .invalid, .cli, "v", "x")
  let row = try #require(report.render().split(separator: "\n").first { $0.hasPrefix("name") })
  #expect(row.trimmingCharacters(in: .whitespaces) == "name  invalid  CLI     v      x")
  #expect(DevcontainerReport().render() == "  (no recognised keys)\n")
}

@Test func reportRenderNeutralizesControlCharacters() throws {
  let t = try translate("{ \"a\": \"\\u001b[31mred\\u202e\" }")
  #expect(t.report.render().contains("?[31mred?"))
  // JSON keeps the exact value.
  #expect(try JSONOutput.render(t.report).contains("\\u001b[31mred"))
}

@Test func reportJSONShape() throws {
  var report = DevcontainerReport()
  report.push("hostRequirements.cpus", .applied, .devcontainer, "4")
  report.sourcePath = "/p"
  report.ignoredPaths = ["/q"]
  #expect(
    try canonicalJSON(JSONOutput.render(report))
      == canonicalJSON(
        #"{"entries":[{"key":"hostRequirements.cpus","status":"applied","source":"devcontainer","value":"4","note":""}],"source_path":"/p","ignored_paths":["/q"]}"#
      ))
}

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().deletingLastPathComponent().appending(
    path: "fixtures/devcontainer")

/// Expected `iso devcontainer check` output for
/// `sample.jsonc`, with its canonical path replaced by `{PATH}`.
@Test(arguments: ["both", "setup", "start"])
func reportMatchesFixtures(_ stage: String) throws {
  let sample = canonicalPath(fixtures.appending(path: "sample.jsonc").path)!
  let file = try ParsedDevcontainer.load(sample)
  let start = { (user: GuestUser) in DevcontainerTranslatorInputs(persistedGuestUser: user) }
  let setupT = Devcontainer.translate(file, inputs: .init(), stage: .setup)
  let startT = Devcontainer.translate(
    file, inputs: start(stage == "both" ? setupT.guestUser ?? .default : .default), stage: .start)
  var text: String
  let json: String
  switch stage {
  case "setup":
    text = setupT.report.render() + "\n"
    json = try JSONOutput.render(setupT.report)
  case "start":
    text = startT.report.render() + "\n"
    json = try JSONOutput.render(startT.report)
  default:
    text =
      "setup-stage translation:\n" + setupT.report.render() + "\n\nstart-stage translation:\n"
      + startT.report.render() + "\n"
    struct Reports: Encodable {
      let setup: DevcontainerReport
      let start: DevcontainerReport
    }
    json = try JSONOutput.render(Reports(setup: setupT.report, start: startT.report))
  }
  text = text.replacingOccurrences(of: sample, with: "{PATH}")
  let marked = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
    .map { $0 + "$\n" }.joined()
  let expectedText = try String(
    contentsOf: fixtures.appending(path: "check-\(stage).stderr.txt"), encoding: .utf8)
  #expect(marked == expectedText)
  let expectedJSON = try String(
    contentsOf: fixtures.appending(path: "check-\(stage).json"), encoding: .utf8)
  #expect(
    try canonicalJSON(json.replacingOccurrences(of: sample, with: "{PATH}"))
      == canonicalJSON(expectedJSON))
}

// MARK: - Discovery

@Test func pickWinnerPrefersWorkspaceThenFirstMount() throws {
  let found: [Devcontainer.Discovered] = [
    .init(path: "/ws/.devcontainer/devcontainer.json", origin: .workspace),
    .init(path: "/m1/.devcontainer/devcontainer.json", origin: .mount),
    .init(path: "/m2/.devcontainer/devcontainer.json", origin: .mount),
  ]
  let (winner, losers) = try #require(Devcontainer.pickWinner(found))
  #expect(winner.origin == .workspace && losers.count == 2)
  let (first, rest) = try #require(Devcontainer.pickWinner(Array(found.dropFirst())))
  #expect(first.path == "/m1/.devcontainer/devcontainer.json")
  #expect(rest == ["/m2/.devcontainer/devcontainer.json"])
  #expect(Devcontainer.pickWinner([]) == nil)
}

@Test func discoverFindsWorkspaceFirstThenMounts() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  for directory in ["ws", "mnt"] {
    try write("{}", "\(root)/\(directory)/.devcontainer/devcontainer.json")
  }
  let mount = try Mount(host: "\(root)/mnt", guest: GuestPath.absolute("/m"))
  let found = Devcontainer.discover(workspace: "\(root)/ws", mounts: [mount])
  #expect(found.map(\.origin) == [.workspace, .mount])
  #expect(found[0].path == "\(root)/ws/.devcontainer/devcontainer.json")
  #expect(found[1].path == "\(mount.hostPath)/.devcontainer/devcontainer.json")
}

// MARK: - Application

@Test func applyToConfigWritesEveryField() throws {
  let config = try ConfigLoader.decode(
    ConfigLoader.parse(
      Array(#"{"guest_env": {"ZED": "1", "FOO": "old"}}"#.utf8), format: .jsonc, path: "c",
      limits: .configuration), path: "c", environment: .empty)
  var t = DevcontainerTranslation()
  t.vcpus = 6
  t.memory = MiB(2048)
  t.postStart = "echo go"
  t.guestEnvironment = [(try EnvVarName("FOO"), "bar"), (try EnvVarName("AAA"), "x")]
  let applied = try Devcontainer.applyToConfig(config, t)
  #expect(applied.vm.vcpuCount == 6)
  #expect(applied.vm.memory.mib.value == 2048)
  #expect(applied.postStart == "echo go")
  #expect(applied.guestEnvironment.map(\.name.rawValue) == ["AAA", "FOO", "ZED"])
  #expect(applied.guestEnvironment.first { $0.name.rawValue == "FOO" }?.value == "bar")
}

@Test func applyToConfigRejectsBelowFloorMemory() throws {
  var t = DevcontainerTranslation()
  t.memory = MiB(16)
  let config = try ConfigLoader.decode(
    ConfigLoader.parse(Array("{}".utf8), format: .jsonc, path: "c", limits: .configuration),
    path: "c", environment: .empty)
  do {
    _ = try Devcontainer.applyToConfig(config, t)
    Issue.record("expected an error")
  } catch let error as ContextError {
    #expect(error.context.contains("hostRequirements.memory"))
    #expect(oneLine(error).contains("is too low"))
  }
}

@Test func effectiveDiskAndForwardMerge() throws {
  var t = DevcontainerTranslation()
  t.disk = GiB(10)
  #expect(Devcontainer.effectiveDisk(cli: GiB(20), t) == GiB(20))
  #expect(Devcontainer.effectiveDisk(cli: nil, t) == GiB(10))
  #expect(Devcontainer.effectiveDisk(cli: nil, DevcontainerTranslation()) == nil)
  let merged = Devcontainer.mergeIntoForwardPorts(
    config: [try PortForward.parse("3000"), try PortForward.parse("4000")],
    translation: [try PortForward.parse("4000:5000"), try PortForward.parse("6000")])
  #expect(merged.map(\.guest) == [3000, 4000, 6000])
  #expect(merged[1].host == 5000)
}

// MARK: - State and preferences

private func instance(_ directory: String) throws -> Instance {
  Instance(
    name: try InstanceName("demo"), index: InstanceIndex(0)!, directory: directory,
    image: .default)
}

@Test func devcontainerStateWarnsOnChangeAndDisappearance() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/devcontainer.json"
  try write(#"{ "name": "old" }"#, path)
  let state = DevcontainerState(
    applied: AppliedDevcontainer(
      path: path, contentHash: sha256(#"{ "name": "old" }"#), source: .localFile))
  #expect(try state.changedWarning(instanceName: "demo") == nil)
  try write(#"{ "name": "new" }"#, path)
  let warning = try #require(try state.changedWarning(instanceName: "demo"))
  for part in [
    "devcontainer.json changed", "features", "hostRequirements", "remoteUser",
    "not re-applied automatically",
  ] {
    #expect(warning.contains(part))
  }
  try FileManager.default.removeItem(atPath: path)
  let gone = try #require(try state.changedWarning(instanceName: "demo"))
  #expect(gone.contains("no longer readable") && gone.contains("Destroy and recreate"))
  let remote = DevcontainerState(
    applied: AppliedDevcontainer(
      path: "github.com/owner/repo/.devcontainer/devcontainer.json", contentHash: sha256("{}"),
      source: .remoteContents))
  #expect(try remote.changedWarning(instanceName: "demo") == nil)
}

@Test func devcontainerStateRoundTrips() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let inst = try instance(directory)
  let state = DevcontainerState(
    applied: AppliedDevcontainer(
      path: "/p/devcontainer.json", contentHash: sha256("{}"), source: .remoteContents))
  try state.save(inst)
  let text = try String(contentsOfFile: inst.devcontainerStatePath, encoding: .utf8)
  #expect(
    try canonicalJSON(text)
      == canonicalJSON(
        "{\n  \"applied\": {\n    \"path\": \"/p/devcontainer.json\",\n    \"content_hash\": \"\(sha256("{}"))\",\n    \"source\": \"remote_contents\"\n  }\n}"
      ))
  #expect(try DevcontainerState.load(inst) == state)
  // A pre-`source` record defaults to a local file.
  try write(
    "{\"applied\":{\"path\":\"/p\",\"content_hash\":\"\(sha256("x"))\"}}",
    inst.devcontainerStatePath)
  #expect(try DevcontainerState.load(inst)?.applied.source == .localFile)
}

@Test func preferencesRoundTripClearAndMissingFile() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let project = directory + "/project"
  try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
  let path = directory + "/prefs.json"
  #expect(try DevcontainerPreferences.load(directory + "/missing.json").ignoredProjects.isEmpty)
  var preferences = DevcontainerPreferences()
  let key = try preferences.setIgnored(project)
  try preferences.save(path)
  #expect(
    try canonicalJSON(String(contentsOfFile: path, encoding: .utf8))
      == canonicalJSON(
        "{\n  \"projects\": {\n    \"\(key)\": {\n      \"ignore\": true\n    }\n  }\n}"))
  var loaded = try DevcontainerPreferences.load(path)
  #expect(try loaded.ignoredProject(project) == key)
  #expect(loaded.ignoredProjects == [key])
  #expect(try loaded.clear(project))
  try loaded.save(path)
  #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func preferencesClearDeletedProjectByStoredKeyAndSymlinkedPrefix() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let project = directory + "/project"
  try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
  var preferences = DevcontainerPreferences()
  let key = try preferences.setIgnored(project)
  try FileManager.default.removeItem(atPath: project)
  #expect(try preferences.ignoredProject(key) == key)
  #expect(try preferences.clear(key))

  let real = directory + "/real"
  try FileManager.default.createDirectory(
    atPath: real + "/project", withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(atPath: directory + "/link", withDestinationPath: real)
  let linked = directory + "/link/project"
  let stored = try preferences.setIgnored(linked)
  #expect(stored == real + "/project")
  try FileManager.default.removeItem(atPath: real + "/project")
  #expect(try preferences.clear(linked))
  #expect(preferences.ignoredProjects.isEmpty)
}

@Test func relativeMissingProjectLookupIsAnError() {
  #expect(throws: ContextError.self) {
    try DevcontainerPreferences.lookupKey("iso-nonexistent-relative-xyzzy/sub")
  }
}

// MARK: - OCI Features

@Test func featureReferenceParsing() throws {
  let latest = try #require(
    try FeatureRequest.parse(
      rawID: "ghcr.io/devcontainers/features/github-cli", options: DevcontainerJSON(.object([]))))
  #expect(latest.reference.repository == "devcontainers/features/github-cli")
  #expect(latest.reference.reference == .tag("latest"))

  let tagged = try #require(
    try FeatureRequest.parse(
      rawID: "ghcr.io/devcontainers/features/go:1.2.3",
      options: DevcontainerJSON.parse(#"{ "version": "1.24", "moby": true, "n": 1.5, "z": null }"#))
  )
  #expect(tagged.reference.reference == .tag("1.2.3"))
  #expect(tagged.options.map(\.key) == ["moby", "n", "version", "z"])
  #expect(tagged.options.map(\.value) == ["true", "1.5", "1.24", ""])

  let digest = try #require(
    try FeatureRequest.parse(
      rawID: "ghcr.io/devcontainers/features/go@\(sampleDigest)",
      options: DevcontainerJSON(.object([]))))
  #expect(digest.reference.reference == .digest(try OCIDigest(sampleDigest)))
  #expect(digest.reference.reference.description == sampleDigest)

  #expect(
    try FeatureRequest.parse(rawID: "ghcr.io/other/x:1", options: DevcontainerJSON(.object([])))
      == nil)
  #expect(try FeatureRequest.parse(rawID: "rust", options: DevcontainerJSON(.object([]))) == nil)
}

@Test func featureReferenceErrors() throws {
  func message(_ rawID: String, _ options: String = "{}") -> String? {
    do {
      _ = try FeatureRequest.parse(rawID: rawID, options: DevcontainerJSON.parse(options))
      return nil
    } catch { return topMessage(error) }
  }
  #expect(
    message("ghcr.io/devcontainers/features/go@sha256:nope")
      == #"invalid feature digest in "ghcr.io/devcontainers/features/go@sha256:nope""#)
  #expect(
    message("ghcr.io/devcontainers/features/go:")
      == "expected ghcr.io/devcontainers/features/<name>[:tag|@digest]")
  #expect(
    message("ghcr.io/devcontainers/features/a b:1")
      == "feature name contains unsupported characters")
  #expect(message("ghcr.io/devcontainers/features/go:1", "5") == "expected feature options object")
  #expect(
    message("ghcr.io/devcontainers/features/go:1", #"{"version": {"nested": true}}"#)?.contains(
      "must be a string") == true)
  #expect(
    message("ghcr.io/devcontainers/features/go:1", #"{"a b": 1}"#)
      == #"feature option "a b" contains unsupported characters"#)
  #expect(throws: (any Error).self) { try OCIDigest(String(sampleDigest.dropFirst(7))) }
  #expect(throws: (any Error).self) { try OCIDigest("sha256:not-hex") }
}

private func sampleFeature(archive: [UInt8] = Array("archive-bytes".utf8)) throws -> ResolvedFeature
{
  ResolvedFeature(
    installed: InstalledFeature(
      id: "github-cli", reference: "ghcr.io/devcontainers/features/github-cli:1",
      digest: try OCIDigest(sampleDigest), installScriptHash: try SHA256Hex(sha256("echo install"))),
    installScript: "echo \"$VERSION\"", archive: archive,
    options: [("version", "latest"), ("it's", "a'b")])
}

@Test func installSnippetMatchesTheBaselineText() throws {
  let feature = try sampleFeature()
  let delimiter = "ISO_FEATURE_ARCHIVE_\(sha256("echo install").prefix(16))"
  #expect(
    feature.installSnippet == """

      echo '  [guest] Installing devcontainer Feature 'ghcr.io/devcontainers/features/github-cli:1''
      (
      feature_dir=$(mktemp -d)
      trap 'rm -rf "$feature_dir"' EXIT
      archive="$feature_dir/feature.tgz"
      base64 -d > "$archive" <<'\(delimiter)'
      YXJjaGl2ZS1ieXRlcw==
      \(delimiter)
      tar -xzf "$archive" -C "$feature_dir"
      chmod +x "$feature_dir/install.sh"
      export _REMOTE_USER="$GUEST_USER"
      export _REMOTE_USER_HOME="/home/$GUEST_USER"
      export VERSION='latest'
      export IT_S='a'\\''b'
      cd "$feature_dir"
      ./install.sh
      )

      """)
}

@Test func provisioningPlacesFeaturesAfterGuestConfiguration() throws {
  let user = GuestUser.default
  let plain = Provisioning.script(publicKey: "ssh-ed25519 AAAA", profiles: [], guestUser: user)
  let feature = try sampleFeature()
  let withFeature = Provisioning.script(
    publicKey: "ssh-ed25519 AAAA", profiles: [], guestUser: user, ociFeatures: [feature])
  let guest = Provisioning.guestConfig(publicKey: "ssh-ed25519 AAAA", guestUser: user)
  #expect(
    withFeature
      == plain.replacingOccurrences(of: guest, with: guest + feature.installSnippet))
  // No features: the build context (and so the image identity) is unchanged.
  #expect(
    BuildContext.render(publicKey: "k", profiles: [], guestUser: user)
      == BuildContext.render(publicKey: "k", profiles: [], guestUser: user, ociFeatures: []))
}

@Test func manifestFieldsAndHeaderDigest() throws {
  let manifest = try JSONDecoder().decode(
    OCIManifest.self,
    from: Data(
      #"""
      {"config": {"digest": "sha256:config"},
       "layers": [{"digest": "sha256:plain"},
                  {"digest": "sha256:layer", "annotations": {"org.opencontainers.image.title": "devcontainer-feature-go.tgz"}}],
       "annotations": {"dev.containers.metadata": "{\"id\":\"go\",\"name\":\"Go\"}"}}
      """#.utf8))
  #expect(try manifest.digest() == "sha256:config")
  #expect(try manifest.featureBlob().digest == "sha256:layer")
  #expect(manifest.metadata?.id == "go")
  #expect(
    FeatureResolver.contentDigest("HTTP/2 200\r\ndocker-content-digest: sha256:manifest\r\n\r\n")
      == "sha256:manifest")
}

private func makeArchive(_ root: String, files: [String: String]) throws -> String {
  let feature = root + "/feature-src"
  for (name, content) in files { try write(content, feature + "/" + name) }
  let archive = root + "/feature.tgz"
  let output = try ProcessRunner().capture(
    .init(
      executable: "/usr/bin/tar", arguments: ["-czf", archive, "-C", feature, "."],
      environment: ["PATH": "/usr/bin:/bin"], deadline: .seconds(30)))
  #expect(output.termination == .exited(0))
  return archive
}

@Test func resolvesSampleFeatureArchive() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let archive = try makeArchive(
    root,
    files: [
      "devcontainer-feature.json": #"{ "id": "sample", "name": "Sample" }"#,
      "helper.sh": "echo helper\n", "install.sh": "#!/bin/sh\n. ./helper.sh\n",
    ])
  let request = try #require(
    try FeatureRequest.parse(
      rawID: "ghcr.io/devcontainers/features/sample:1", options: DevcontainerJSON(.object([]))))
  let resolver = FeatureResolver(environment: ["PATH": "/usr/bin:/bin"])
  let resolved = try resolver.resolvedFeature(
    request, manifestDigest: sampleDigest,
    metadata: try JSONDecoder().decode(
      OCIManifest.FeatureMetadata.self, from: Data(#"{"id":"sample"}"#.utf8)),
    blobPath: archive)
  #expect(resolved.installed.id == "sample")
  #expect(resolved.installed.digest == (try OCIDigest(sampleDigest)))
  #expect(resolved.installScript.contains("./helper.sh"))
  #expect(resolved.archive == Array(FileManager.default.contents(atPath: archive)!))
  #expect(resolved.installSnippet.contains(Data(resolved.archive).base64EncodedString()))

  let missing = try makeArchive(root + "/b", files: ["install.sh": "echo\n"])
  #expect(throws: (any Error).self) {
    try resolver.resolvedFeature(
      request, manifestDigest: sampleDigest, metadata: nil, blobPath: missing)
  }
}

// MARK: - Registry and GitHub fetches through stub executables

/// A `curl` stand-in that logs its argv (and stdin) and answers by URL.
private func stubCurl(_ directory: String, script: String) throws {
  let path = directory + "/curl"
  try write(
    """
    #!/bin/sh
    printf '%s\\n' "$*" >> "$STUB_LOG"
    \(script)
    """, path)
  chmod(path, 0o755)
}

@Test func resolverFetchesOCIFeaturesWithBaselineArgv() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let archive = try makeArchive(
    root, files: ["devcontainer-feature.json": "{}", "install.sh": "echo hi\n"])
  // Real digests: the manifest names the layer by its hash and is itself
  // identified by the hash of its bytes.
  let layerDigest = "sha256:" + sha256Hex(Array(FileManager.default.contents(atPath: archive)!))
  let manifest = #"{"layers":[{"digest":""# + layerDigest + #""}]}"#
  let manifestDigest = "sha256:" + sha256Hex(Array(manifest.utf8))
  try write(manifest, root + "/manifest.json")
  try stubCurl(
    root,
    script: """
      out=""; hdr=""; prev=""
      for a in "$@"; do
        case "$prev" in -o) out="$a";; -D) hdr="$a";; esac
        prev="$a"
      done
      case "$*" in
        *token*) printf '{"token":"SYNTHETIC"}';;
        */manifests/*) printf 'Docker-Content-Digest: \(manifestDigest)\\r\\n' > "$hdr"
          cp '\(root)/manifest.json' "$out";;
        */blobs/*) cp '\(archive)' "$out"; [ -f '\(root)/tamper' ] && printf x >> "$out"; true;;
      esac
      """)
  try write(
    #"{"features": {"ghcr.io/devcontainers/features/hello:1": {"greeting": "hi"}}}"#,
    root + "/devcontainer.json")
  let resolver = DevcontainerResolver(
    environment: ["PATH": root + ":/usr/bin:/bin", "STUB_LOG": root + "/log"],
    diagnostics: Diagnostics(verbosity: 0) { _ in }, prompter: FakePrompter(interactive: false),
    errorSink: { _ in })
  let t = try #require(
    try resolver.collect(
      DevcontainerOptions(input: .explicit(root + "/devcontainer.json"), dryRun: false),
      inputs: .init(), stage: .setup))
  #expect(t.ociFeatures.count == 1)
  #expect(t.ociFeatures[0].options.map(\.value) == ["hi"])
  let row = try #require(rows(t, "features.ghcr.io/devcontainers/features/hello:1").first)
  #expect(row.status == .applied && row.value == manifestDigest)
  #expect(
    row.note.hasPrefix("OCI feature 'ghcr.io/devcontainers/features/hello:1' install.sh sha256 "))
  let log = try String(contentsOfFile: root + "/log", encoding: .utf8).split(separator: "\n")
  #expect(log.count == 3)
  #expect(
    log[0]
      == "-fsSL https://ghcr.io/token?scope=repository:devcontainers/features/hello:pull&service=ghcr.io"
  )
  #expect(log[1].hasPrefix("-fsSL -D /"))
  #expect(
    log[1].hasSuffix(
      "-H Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.oci.artifact.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json -H Authorization: Bearer SYNTHETIC https://ghcr.io/v2/devcontainers/features/hello/manifests/1"
    ))
  #expect(
    log[2].hasPrefix(
      "-fsSL -H Authorization: Bearer SYNTHETIC https://ghcr.io/v2/devcontainers/features/hello/blobs/\(layerDigest) -o /"
    ))

  // A layer that does not hash to its descriptor is refused.
  try write("", root + "/tamper")
  let tampered = try #require(
    try resolver.collect(
      DevcontainerOptions(input: .explicit(root + "/devcontainer.json"), dryRun: false),
      inputs: .init(), stage: .setup))
  #expect(tampered.ociFeatures.isEmpty)
  #expect(
    rows(tampered, "features.ghcr.io/devcontainers/features/hello:1").first?.status != .applied)
}

@Test func failedFeatureResolutionIsAnInvalidRowWithRedactedArgv() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try stubCurl(
    root, script: #"case "$*" in *token*) printf '{"token":"SYNTHETIC"}';; *) exit 22;; esac"#)
  let resolver = FeatureResolver(environment: ["PATH": root, "STUB_LOG": root + "/log"])
  let request = try #require(
    try FeatureRequest.parse(
      rawID: "ghcr.io/devcontainers/features/x", options: DevcontainerJSON(.object([]))))
  let result = resolver.resolve([request])
  guard case .failure(let error) = result[0] else {
    Issue.record("expected failure")
    return
  }
  let text = oneLine(error)
  #expect(
    text.hasPrefix(
      "Failed to fetch feature manifest for ghcr.io/devcontainers/features/x/latest: curl -fsSL -D "
    ))
  #expect(
    text.contains(
      "<redacted> <redacted> https://ghcr.io/v2/devcontainers/features/x/manifests/latest exited with exit status: 22"
    ))
  #expect(!text.contains("SYNTHETIC"))
}

@Test func gitRepoDiscoverySendsTokenOnStdin() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try stubCurl(
    root,
    script: """
      /bin/cat > "$STUB_LOG.stdin"
      printf '{"name":"remote"}\\n200'
      """)
  let discovery = GitRepoDevcontainerDiscovery(
    environment: ["PATH": root, "STUB_LOG": root + "/log", "GITHUB_TOKEN": " ghp_SYNTHETIC \n"])
  let file = try #require(try discovery.discover("https://github.com/owner/repo.git", auth: nil))
  #expect(file.displayPath == "github.com/owner/repo/.devcontainer/devcontainer.json")
  #expect(file.contents == #"{"name":"remote"}"#)
  #expect(
    try String(contentsOfFile: root + "/log", encoding: .utf8)
      == "-sSL --connect-timeout 5 --max-time 15 -H User-Agent: iso -H Accept: application/vnd.github.raw+json -w \n%{http_code} -H @- https://api.github.com/repos/owner/repo/contents/.devcontainer/devcontainer.json\n"
  )
  #expect(
    try String(contentsOfFile: root + "/log.stdin", encoding: .utf8)
      == "Authorization: token ghp_SYNTHETIC\n")
  #expect(try discovery.discover("https://gitlab.com/owner/repo", auth: nil) == nil)
}

@Test func gitRepoDiscoveryHelpers() throws {
  let slug = try RepoSlug("owner/repo")
  #expect(
    GitRepoDevcontainerDiscovery.contentsURL(slug)
      == "https://api.github.com/repos/owner/repo/contents/.devcontainer/devcontainer.json")
  let (status, body) = try GitRepoDevcontainerDiscovery.statusAndBody("{\"name\":\"x\"}\n200")
  #expect(status == 200 && body == "{\"name\":\"x\"}")
  #expect(
    GitRepoDevcontainerDiscovery.selectHostToken(gh: " ghp_abc \n", env: "ghp_env") == "ghp_abc")
  #expect(GitRepoDevcontainerDiscovery.selectHostToken(gh: "   ", env: " ghp_env\n") == "ghp_env")
  #expect(GitRepoDevcontainerDiscovery.selectHostToken(gh: "", env: " ") == nil)
}

// MARK: - Resolution flow

private struct FakePrompter: DevcontainerPrompter {
  var interactive: Bool
  var useFile = true
  var alwaysIgnore = false
  var isInteractive: Bool { interactive }
  func confirm(_ prompt: String) throws -> Bool { alwaysIgnore }
  func confirmDefaultYes(_ prompt: String) throws -> Bool { useFile }
}

private final class Sink: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""
  func append(_ value: String) { lock.withLock { text += value } }
  var value: String { lock.withLock { text } }
}

private func resolver(_ prompter: FakePrompter, _ sink: Sink) -> DevcontainerResolver {
  DevcontainerResolver(
    environment: ["PATH": "/nonexistent"], diagnostics: Diagnostics(verbosity: 0) { _ in },
    prompter: prompter, errorSink: { sink.append($0) })
}

@Test func devcontainerInputFlagPrecedence() {
  #expect(
    DevcontainerInput.fromFlags(path: "/d.json", noDevcontainer: false) == .explicit("/d.json"))
  #expect(DevcontainerInput.fromFlags(path: nil, noDevcontainer: false) == .discover)
  #expect(DevcontainerInput.fromFlags(path: nil, noDevcontainer: true) == .disabled)
  #expect(DevcontainerInput.fromFlags(path: "/d.json", noDevcontainer: true) == .disabled)
}

@Test func discoveryRequiresATTYUnlessDryRun() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let file = root + "/.devcontainer/devcontainer.json"
  try write(#"{"hostRequirements": {"cpus": 3}}"#, file)
  let sink = Sink()
  let quiet = resolver(FakePrompter(interactive: false), sink)
  do {
    _ = try quiet.collect(
      DevcontainerOptions(input: .discover, dryRun: false, workspace: root), inputs: .init(),
      stage: .setup)
    Issue.record("expected the non-TTY error")
  } catch {
    #expect(
      "\(error)"
        == "Found \(file) but stdin is not a TTY.\nPass --devcontainer \(file) to apply it, or --no-devcontainer to ignore.\niso reads a subset of devcontainer.json — see docs/devcontainer.md for the supported keys."
    )
  }
  let dry = try #require(
    try quiet.resolve(
      DevcontainerOptions(input: .discover, dryRun: true, workspace: root), inputs: .init(),
      stage: .setup))
  #expect(dry.vcpus == 3)
  #expect(sink.value == dry.report.render() + "\n")
  #expect(
    try quiet.collect(
      DevcontainerOptions(input: .disabled, dryRun: false, workspace: root), inputs: .init(),
      stage: .setup) == nil)
  #expect(
    try quiet.collect(
      DevcontainerOptions(input: .discover, dryRun: false, workspace: root + "/none"),
      inputs: .init(), stage: .setup) == nil)
}

@Test func declinedPromptRecordsOptOutAndLaterSkips() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let project = root + "/project"
  let file = project + "/.devcontainer/devcontainer.json"
  try write("{}", file)
  let preferences = root + "/prefs.json"
  let options = DevcontainerOptions(
    input: .discover, dryRun: false, workspace: project, preferencePath: preferences)
  let sink = Sink()
  let declining = resolver(
    FakePrompter(interactive: true, useFile: false, alwaysIgnore: true), sink)
  #expect(try declining.collect(options, inputs: .init(), stage: .setup) == nil)
  #expect(try DevcontainerPreferences.load(preferences).ignoredProjects == [project])

  let accepting = resolver(FakePrompter(interactive: true), sink)
  #expect(try accepting.collect(options, inputs: .init(), stage: .setup) == nil)
  #expect(
    sink.value
      == "Skipping \(file) because a stored devcontainer opt-out is set for project \(project).\nRun `iso devcontainer clear \(project)` to re-enable discovery, or pass --devcontainer \(file) to apply this file once.\n"
  )
  // An explicit path bypasses the stored opt-out.
  var explicit = options
  explicit.input = .explicit(file)
  #expect(try accepting.collect(explicit, inputs: .init(), stage: .setup) != nil)
}

@Test func workspaceWinsAndMountLosersAreListed() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write("{}", root + "/ws/.devcontainer/devcontainer.json")
  try write("{}", root + "/m/.devcontainer/devcontainer.json")
  let mount = try Mount(host: root + "/m", guest: GuestPath.absolute("/m"))
  let t = try #require(
    try resolver(FakePrompter(interactive: false), Sink()).collect(
      DevcontainerOptions(input: .discover, dryRun: true, workspace: root + "/ws", mounts: [mount]),
      inputs: .init(), stage: .start))
  #expect(t.report.sourcePath == root + "/ws/.devcontainer/devcontainer.json")
  #expect(t.report.ignoredPaths == [root + "/m/.devcontainer/devcontainer.json"])
  #expect(
    t.report.render().contains(
      "  ignored: \(root)/m/.devcontainer/devcontainer.json (workspace's takes precedence)\n"))
}

@Test func dryRunPlanJSONShape() throws {
  var report = DevcontainerReport()
  report.push("hostRequirements.cpus", .applied, .devcontainer, "4")
  let empty = DevcontainerDryRunPlan(
    report: nil, profiles: ["node"], guestUser: .default, vcpus: 4, memory: MiB(2048), disk: GiB(50)
  )
  #expect(
    try canonicalJSON(JSONOutput.render(empty))
      == canonicalJSON(
        #"{"report":null,"profiles":["node"],"guest_user":"ubuntu","vm":{"vcpus":4,"mem_mib":2048,"disk_gib":50}}"#
      ))
  let full = DevcontainerDryRunPlan(
    report: report, profiles: [], guestUser: .default, vcpus: nil, memory: nil, disk: nil)
  #expect(
    try canonicalJSON(JSONOutput.render(full))
      == canonicalJSON(
        #"{"report":{"entries":[{"key":"hostRequirements.cpus","status":"applied","source":"devcontainer","value":"4","note":""}],"source_path":null,"ignored_paths":[]},"profiles":[],"guest_user":"ubuntu","vm":{"vcpus":null,"mem_mib":null,"disk_gib":null}}"#
      ))
}

@Test func featureFilesAreReadOnlyAsBoundedRegularFiles() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: root) }
  try write("echo hi\n", root + "/install.sh")
  #expect(
    try FeatureResolver.readBounded(root + "/install.sh", limit: 64, what: "x")
      == Array("echo hi\n".utf8))
  try FileManager.default.createSymbolicLink(
    atPath: root + "/link.sh", withDestinationPath: "/etc/hosts")
  #expect(throws: (any Error).self) {
    try FeatureResolver.readBounded(root + "/link.sh", limit: 1 << 20, what: "x")
  }
  mkfifo(root + "/fifo.sh", 0o600)
  #expect(throws: (any Error).self) {
    try FeatureResolver.readBounded(root + "/fifo.sh", limit: 1 << 20, what: "x")
  }
  #expect(throws: (any Error).self) {
    try FeatureResolver.readBounded(root + "/install.sh", limit: 4, what: "x")
  }
}
