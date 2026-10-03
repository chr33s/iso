import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

// MARK: - SSH config blocks

@Test func removeAllBlocksKeepsEverythingElse() {
  let input =
    ("Host other\n    HostName 1.2.3.4\n# iso START iso-0\nHost iso-0\n    HostName 172.16.0.2\n# iso END\nHost another\n    HostName 5.6.7.8\n# iso START iso-1\nHost iso-1\n    HostName 172.16.0.3\n# iso END\n")
  #expect(
    SSHConfigBlocks.removeMarkerBlocks(input)
      == "Host other\n    HostName 1.2.3.4\nHost another\n    HostName 5.6.7.8\n")
  #expect(
    SSHConfigBlocks.removeMarkerBlocks(("# iso START iso-a\nHost iso-a\n# iso END\n"))
      == "")
  // CRLF files keep their other lines; trailing blank lines collapse to one newline.
  #expect(SSHConfigBlocks.removeMarkerBlocks("Host k\r\n\n\n") == "Host k\n")
}

@Test func namedRemovalLeavesOtherBlocks() {
  let input =
    ("# iso START iso-a\nHost iso-a\n    HostName 172.16.0.2\n# iso END\n# iso START iso-b\nHost iso-b\n    HostName 172.16.0.3\n# iso END\n")
  let result = SSHConfigBlocks.removeNamedMarkerBlock(input, host: "iso-a")
  #expect(!result.contains("Host iso-a"))
  #expect(result.contains("Host iso-b"))
  #expect(result.contains("172.16.0.3"))
  let plain = "Host something\n    HostName 1.2.3.4\n"
  #expect(SSHConfigBlocks.removeNamedMarkerBlock(plain, host: "iso-x") == plain)
  // An END marker outside the named block is kept.
  let stray = ("Host k\n# iso END\n")
  #expect(SSHConfigBlocks.removeNamedMarkerBlock(stray, host: "iso-x") == stray)
}

@Test func explicitUserAliasIsRefused() throws {
  for declaration in ["Host iso-test", "Host other iso-test", "HOST ISO-TEST"] {
    #expect(throws: (any Error).self) {
      try SSHConfigBlocks.checkAliasAvailable(declaration, host: "iso-test")
    }
  }
  #expect(throws: Never.self) {
    try SSHConfigBlocks.checkAliasAvailable("Host other\nHost *\n", host: "iso-test")
    try SSHConfigBlocks.checkAliasAvailable(
      "# iso START iso-test\nHost iso-test\n# iso END\n", host: "iso-test")
  }
  #expect(SSHConfigBlocks.host(for: try InstanceName("test")) == "iso-test")
}

@Test func fileCleanupRewritesOnlyWhenSomethingWasRemoved() throws {
  let directory = try temporaryDirectory("ssh")
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/config"
  let log = DiagnosticsLog()
  // Missing file: no-op.
  try SSHConfigBlocks.removeAll(at: path, diagnostics: log.diagnostics)
  #expect(!pathExists(path))
  let unrelated = "Host keep\n    HostName 9.9.9.9\n"
  try writeUpdateFile(path, unrelated, mode: 0o640)
  var before = stat()
  stat(path, &before)
  try SSHConfigBlocks.removeAll(at: path, diagnostics: log.diagnostics)
  var after = stat()
  stat(path, &after)
  #expect(readText(path) == unrelated)
  #expect(before.st_ino == after.st_ino)
  #expect(log.all.isEmpty)

  try writeUpdateFile(
    path,
    unrelated
      + ("# iso START iso-test\nHost iso-test\n# iso END\n# iso START iso-other\nHost iso-other\n    HostName 172.16.0.3\n# iso END\n"),
    mode: 0o640)
  try SSHConfigBlocks.remove(
    host: "iso-test", instanceName: "test", at: path, diagnostics: log.diagnostics)
  #expect(!(readText(path) ?? "").contains("iso-test"))
  #expect((readText(path) ?? "").contains(("# iso START iso-other")))
  #expect(log.all == ["Removed SSH config block for instance 'test'"])
  try SSHConfigBlocks.removeAll(at: path, diagnostics: log.diagnostics)
  #expect(readText(path) == unrelated)
  stat(path, &after)
  #expect(after.st_mode & 0o777 == 0o640)
  #expect(log.all.last == "Removed iso SSH config blocks")
}

// MARK: - Decisions and guards

@Test func devTargetPathsNeedConsecutiveComponents() {
  for path in [
    "/home/u/repo/target/debug/iso", "/home/u/repo/target/release/iso",
    "/src/iso/.build/debug/iso", "/src/iso/.build/arm64-apple-macosx/release/iso",
  ] {
    #expect(Uninstaller.isDevTargetPath(path), "\(path)")
  }
  for path in [
    "/home/u/.local/bin/iso", "/usr/local/bin/iso", "/opt/release/target/bin/iso",
    "/home/u/target-foo/release/iso", "/srv/debug/lib/target/iso", "/opt/.build/x/y/release/iso",
  ] {
    #expect(!Uninstaller.isDevTargetPath(path), "\(path)")
  }
}

@Test func configPathContainment() throws {
  let root = try temporaryDirectory("contain")
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeUpdateFile(root + "/data/config.jsonc", "")
  try writeUpdateFile(root + "/elsewhere/config.jsonc", "")
  #expect(Uninstaller.configPathIsUnderDataDirectory(root + "/data/config.jsonc", root + "/data"))
  #expect(
    !Uninstaller.configPathIsUnderDataDirectory(root + "/elsewhere/config.jsonc", root + "/data"))
  // Neither side exists: lexical, by whole components.
  #expect(
    Uninstaller.configPathIsUnderDataDirectory("/nonexistent/data/config.toml", "/nonexistent/data")
  )
  #expect(
    !Uninstaller.configPathIsUnderDataDirectory(
      "/nonexistent/other/config.toml", "/nonexistent/data"))
  #expect(
    !Uninstaller.configPathIsUnderDataDirectory("/nonexistent/database/c", "/nonexistent/data"))
  // Only one side resolves: can't tell, so the notice is suppressed.
  #expect(Uninstaller.configPathIsUnderDataDirectory("/nonexistent/path/config.toml", root))
}

// MARK: - End to end

/// A private HOME with owned state, config, an unrelated file, update-check
/// state and SSH config, plus a removable binary.
private struct UninstallFixture {
  let root: String
  var home: String { root + "/home" }
  var state: String { home + "/.iso/backends/apple-container-v1" }
  var binary: String { root + "/bin/iso" }
  var stateFile: String { UpdateCheck.statePath(home: home)! }
  var sshConfig: String { home + "/.ssh/config" }

  init() throws {
    root = try temporaryDirectory("uninstall")
    for directory in [state + "/images", state + "/instances"] {
      try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
    try writeUpdateFile(state + "/vm_key", "key", mode: 0o600)
    try writeUpdateFile(home + "/.iso/config.jsonc", "{}")
    try writeUpdateFile(home + "/.iso/unrelated/sentinel", "unrelated")
    try writeUpdateFile(stateFile, #"{"last_checked_at": 0, "latest_known_version": "v9.9.9"}"#)
    try writeUpdateFile(
      sshConfig,
      "# iso START iso-uninstall-test\nHost iso-uninstall-test\n    HostName 172.16.0.42\n# iso END\n\n# unrelated user block\nHost github.com\n    User git\n",
      mode: 0o600)
    try writeUpdateFile(binary, "binary", mode: 0o755)
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }

  func uninstaller(
    binary: String? = nil, terminal: Bool = false, log: DiagnosticsLog,
    confirm: @escaping (String) throws -> Bool = { _ in
      Issue.record("prompted")
      return false
    }
  ) throws -> Uninstaller {
    let environment = ConfigEnvironment(home: home, variables: ["HOME": home])
    let config = try ConfigLoader.load(
      .defaultsOnly(defaultPath: home + "/.iso/config.jsonc"), environment: environment)
    let backend = AppleBackend(
      config: config, environment: ["PATH": root + "/no-bin"], executable: nil,
      diagnostics: log.diagnostics)
    return Uninstaller(
      backend: backend, configPath: home + "/.iso/config.jsonc", home: home,
      binaryPath: binary ?? self.binary, environment: ["PATH": root + "/no-bin"],
      stdinIsTerminal: terminal, confirm: confirm)
  }
}

@Suite(.serialized) struct UninstallEndToEnd {
  @Test func keepDataRemovesTheBinaryAndStripsSSHBlocksOnly() throws {
    let fixture = try UninstallFixture()
    defer { fixture.remove() }
    let log = DiagnosticsLog()
    try fixture.uninstaller(log: log).run(.init(yes: true, keepData: true))
    #expect(!pathExists(fixture.binary))
    #expect(pathExists(fixture.state + "/vm_key"))
    #expect(pathExists(fixture.stateFile))
    #expect(
      readText(fixture.sshConfig) == "\n# unrelated user block\nHost github.com\n    User git\n")
    #expect(
      log.all.filter { !$0.hasPrefix("Resolved binary path") } == [
        "This will remove:", "  binary:    \(fixture.binary)",
        "  data dir:  \(fixture.state) (0 instance(s), 0 image(s))",
        "Removed iso SSH config blocks",
        "Keeping \(fixture.state); reinstall iso to manage existing instances.",
        "iso uninstalled. To reinstall: curl -fsSL https://raw.githubusercontent.com/chr33s/iso/main/install.sh | sh",
      ])
  }

  @Test func purgeRemovesOwnedStateAndPreservesConfig() throws {
    let fixture = try UninstallFixture()
    defer { fixture.remove() }
    let log = DiagnosticsLog()
    try fixture.uninstaller(log: log).run(.init(yes: true, purge: true))
    #expect(!pathExists(fixture.binary))
    #expect(!pathExists(fixture.state))
    #expect(!pathExists(fixture.stateFile))
    #expect(!pathExists((fixture.stateFile as NSString).deletingLastPathComponent))
    #expect(readText(fixture.home + "/.iso/config.jsonc") == "{}")
    #expect(readText(fixture.home + "/.iso/unrelated/sentinel") == "unrelated")
    #expect(!(readText(fixture.sshConfig) ?? "").contains("iso"))
    #expect((readText(fixture.sshConfig) ?? "").contains("Host github.com"))
    // Baseline quirk: the check runs after the owned root is gone, so only the
    // config canonicalizes and the "can't tell" branch suppresses the notice.
    #expect(!log.contains("is outside the data directory"))
  }

  @Test func nonInteractiveWithoutYesRefuses() throws {
    let fixture = try UninstallFixture()
    defer { fixture.remove() }
    #expect(
      throws: HostError(
        "stdin is not a TTY; pass --yes (and optionally --keep-data or --purge) for non-interactive uninstall."
      )
    ) { try fixture.uninstaller(log: DiagnosticsLog()).run(.init()) }
    #expect(pathExists(fixture.binary))
    #expect(pathExists(fixture.state))
  }

  @Test func interactiveAnswersDecideEachStep() throws {
    let fixture = try UninstallFixture()
    defer { fixture.remove() }
    let asked = Mutex<[String]>([])
    // Decline the binary: nothing changes.
    let log = DiagnosticsLog()
    try fixture.uninstaller(terminal: true, log: log) { prompt in
      asked.withLock { $0.append(prompt) }
      return false
    }.run(.init())
    #expect(asked.withLock { $0 } == ["Remove iso binary at \(fixture.binary)?"])
    #expect(log.contains("Uninstall cancelled"))
    #expect(pathExists(fixture.binary))
    // Accept the binary, decline the data.
    asked.withLock { $0 = [] }
    try fixture.uninstaller(terminal: true, log: DiagnosticsLog()) { prompt in
      asked.withLock { $0.append(prompt) }
      return prompt.hasPrefix("Remove iso binary")
    }.run(.init())
    #expect(
      asked.withLock { $0 }.last
        == "Also remove data directory \(fixture.state) (0 instance(s), 0 image(s))?")
    #expect(!pathExists(fixture.binary))
    #expect(pathExists(fixture.state))
  }

  @Test func flagsDecideDataRemovalWithoutPrompting() throws {
    let fixture = try UninstallFixture()
    defer { fixture.remove() }
    let uninstaller = try fixture.uninstaller(log: DiagnosticsLog())
    #expect(try !uninstaller.decideRemoveData(.init(yes: true, keepData: true)))
    #expect(try !uninstaller.decideRemoveData(.init(keepData: true)))
    #expect(try uninstaller.decideRemoveData(.init(yes: true)))
    #expect(try uninstaller.decideRemoveData(.init(purge: true)))
    #expect(try uninstaller.decideRemoveData(.init(yes: true, purge: true)))
    let answering = try fixture.uninstaller(log: DiagnosticsLog()) { _ in true }
    #expect(try answering.decideRemoveData(.init()))
  }

  @Test func buildArtifactsAreNeverDeleted() throws {
    let fixture = try UninstallFixture()
    defer { fixture.remove() }
    let artifact = fixture.root + "/repo/.build/debug/iso"
    try writeUpdateFile(artifact, "dev")
    let log = DiagnosticsLog()
    try fixture.uninstaller(binary: artifact, log: log).run(.init(yes: true, keepData: true))
    #expect(pathExists(artifact))
    #expect(log.contains("Refusing to remove \(artifact) — looks like a build artifact"))
  }
}
