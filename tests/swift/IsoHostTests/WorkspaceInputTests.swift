import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private func git(_ directory: String, _ arguments: String...) throws {
  let output = try ProcessRunner().capture(
    .init(
      executable: "/usr/bin/git", arguments: ["-C", directory] + arguments,
      environment: [
        "PATH": "/usr/bin:/bin", "HOME": directory, "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@t",
      ], deadline: .seconds(30)))
  guard output.termination.succeeded else {
    throw HostError("git \(arguments): \(String(decoding: output.stderr, as: UTF8.self))")
  }
}

private var hasGit: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/git") }

private func capture(
  _ root: String, _ input: WorkspaceInputConfig = .defaults, wholeRoot: Bool = false,
  budget: InputBudget? = nil
) throws -> InputSnapshot {
  try InputSnapshot.capture(
    root: root, input: input, budget: budget ?? InputBudget(input.limits),
    stateDirectory: try scratchDirectory("inputs"), wholeRoot: wholeRoot)
}

@Test(arguments: ["2", "4"])
func trackedPathsComeFromTheIndexWithoutRunningGit(version: String) throws {
  guard hasGit else { return }
  let root = try scratchDirectory("repo")
  try git(root, "init", "-q")
  try git(root, "config", "index.version", version)
  // `long/…` then `z.txt`: a v4 prefix strip of 128 bytes or more needs
  // a multi-byte varint.
  let long = "long/" + String(repeating: "p", count: 200) + "/x.txt"
  let expected = ["a.txt", "dir/b.txt", "dir/deeper/c.txt", "dir/deeper/d.txt", long, "z.txt"]
  for path in expected {
    try FileManager.default.createDirectory(
      atPath: (root + "/" + path as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true)
    try writeFile(root + "/" + path, path)
  }
  try git(root, "add", ".")
  // A hostile repository: any Git that inspected it would leave a marker.
  let marker = root + "/../git-ran-\(UUID().uuidString)"
  try git(root, "config", "core.fsmonitor", "touch \(marker)")
  let paths = try #require(try GitIndexInventory.trackedPaths(root))
  #expect(paths == expected)
  #expect(!FileManager.default.fileExists(atPath: marker))
  #expect(try GitIndexInventory.trackedPaths(try scratchDirectory("plain")) == nil)
}

@Test func unreadableIndexFormsAreRefusedNotGuessed() throws {
  #expect(throws: GitIndexInventory.Unsupported.self) { try GitIndexInventory.parse([]) }
  var corrupt = Array("DIRC".utf8) + [0, 0, 0, 2, 0, 0, 0, 0] + [UInt8](repeating: 0, count: 20)
  #expect(throws: GitIndexInventory.Unsupported.self) { try GitIndexInventory.parse(corrupt) }
  corrupt[7] = 9
  #expect(throws: GitIndexInventory.Unsupported.self) { try GitIndexInventory.parse(corrupt) }
  guard hasGit else { return }
  // Submodules and unmerged entries need explicit path selection.
  let root = try scratchDirectory("conflict")
  try git(root, "init", "-q")
  try writeFile(root + "/f", "base\n")
  try git(root, "add", "f")
  try git(root, "commit", "-qm", "base")
  try git(root, "checkout", "-qb", "other")
  try writeFile(root + "/f", "other\n")
  try git(root, "commit", "-qam", "other")
  try git(root, "checkout", "-q", "-")
  try writeFile(root + "/f", "main\n")
  try git(root, "commit", "-qam", "main")
  _ = try? git(root, "merge", "-q", "other")
  #expect(throws: GitIndexInventory.Unsupported.self) { try GitIndexInventory.trackedPaths(root) }
  #expect(throws: HostError.self) { try capture(root) }
}

@Test func secretNamesMatchTheFixedTable() {
  for secret in [
    ".env", "sub/.env", ".env.local", "k.pem", "a/b.key", "c.p12", "d.pfx", "e.keystore",
    "id_rsa", "x/id_ed25519.pub", ".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials",
    ".aws/credentials", "a/.ssh/config", ".gnupg", "p/.docker/config.json", ".kube/config",
    "credentials.json", "SUB/.ENV",
  ] {
    #expect(LocalSecretNames.match(secret) != nil, "\(secret)")
  }
  for ordinary in ["env.txt", "keys.md", "docker/config.json", "kube/config", "README"] {
    #expect(LocalSecretNames.match(ordinary) == nil, "\(ordinary)")
  }
}

@Test func aTrackedSnapshotSendsSelectedBytesOnly() throws {
  guard hasGit else { return }
  let root = try scratchDirectory("ws")
  try git(root, "init", "-q")
  for path in ["src/main.c", ".env", "deleted.txt", "keep/notes.md", "keep/old.md", "id_rsa"] {
    try writeFile(root + "/" + path, path)
  }
  try git(root, "add", ".")
  try git(root, "commit", "-qm", "one")
  try writeFile(root + "/src/main.c", "modified")
  try writeFile(root + "/untracked.txt", "u")
  try writeFile(root + "/extra/data.json", "{}")
  // Deleted on the host: only `deleted.txt` is a removal candidate; the
  // excluded and the secret-named deletions are never removed in the guest.
  for path in ["deleted.txt", "keep/old.md", "id_rsa"] {
    try FileManager.default.removeItem(atPath: root + "/" + path)
  }
  let input = WorkspaceInputConfig(
    mode: .tracked, paths: [.init(path: "extra", recursive: true)], exclude: ["keep"],
    secretAllow: [], limits: .ceilings)
  let snapshot = try capture(root, input)
  defer { snapshot.remove() }
  #expect(readFile(snapshot.tree + "/src/main.c") == "modified")
  #expect(readFile(snapshot.tree + "/extra/data.json") == "{}")
  #expect(!FileManager.default.fileExists(atPath: snapshot.tree + "/untracked.txt"))
  #expect(!FileManager.default.fileExists(atPath: snapshot.tree + "/.env"))
  #expect(!FileManager.default.fileExists(atPath: snapshot.tree + "/keep"))
  #expect(!FileManager.default.fileExists(atPath: snapshot.tree + "/.git"))
  #expect(snapshot.report.secrets == [".env"])
  #expect(snapshot.report.deletedTracked == ["deleted.txt"])

  // A named exception sends the one file, nothing more.
  let allowed = try capture(
    root,
    WorkspaceInputConfig(
      mode: .tracked, paths: [], exclude: [], secretAllow: [".env"], limits: .ceilings))
  defer { allowed.remove() }
  #expect(readFile(allowed.tree + "/.env") == ".env")
}

@Test func aNonGitWorkspaceNeedsExplicitPaths() throws {
  let root = try scratchDirectory("plainws")
  try writeFile(root + "/a.txt", "a")
  try writeFile(root + "/node_modules/x.js", "x")
  #expect(throws: HostError.self) { try capture(root) }
  let snapshot = try capture(
    root,
    WorkspaceInputConfig(
      mode: .paths, paths: [.init(path: ".", recursive: true)], exclude: [], secretAllow: [],
      limits: .ceilings))
  defer { snapshot.remove() }
  #expect(readFile(snapshot.tree + "/a.txt") == "a")
  #expect(!FileManager.default.fileExists(atPath: snapshot.tree + "/node_modules"))
}

@Test func linksHardLinksAndSpecialFilesAreNotSent() throws {
  let root = try scratchDirectory("links")
  let outside = try scratchDirectory("outside")
  try writeFile(outside + "/secret", "host")
  try writeFile(root + "/a.txt", "a")
  try FileManager.default.createSymbolicLink(atPath: root + "/ok", withDestinationPath: "a.txt")
  try FileManager.default.createSymbolicLink(
    atPath: root + "/escape", withDestinationPath: outside + "/secret")
  try FileManager.default.createSymbolicLink(atPath: root + "/up", withDestinationPath: "../x")
  try FileManager.default.createSymbolicLink(atPath: root + "/chain", withDestinationPath: "ok")
  try FileManager.default.createSymbolicLink(
    atPath: root + "/admin", withDestinationPath: ".git/config")
  try writeFile(root + "/one", "1")
  #expect(link(root + "/one", root + "/two") == 0)
  #expect(mkfifo(root + "/pipe", 0o600) == 0)
  let snapshot = try capture(root, wholeRoot: true)
  defer { snapshot.remove() }
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: snapshot.tree + "/ok") == "a.txt")
  for gone in ["escape", "up", "chain", "admin", "one", "two", "pipe"] {
    var info = stat()
    #expect(lstat(snapshot.tree + "/" + gone, &info) != 0, "\(gone)")
  }
  #expect(Set(snapshot.report.links) == ["escape", "up", "chain", "admin"])
  #expect(Set(snapshot.report.unsupported) == ["one", "two", "pipe"])
}

/// A selected path below a selected link is never copied: reading or
/// writing through the link could leave the root or the snapshot tree.
@Test func pathsBelowASelectedLinkAreNotCopiedThroughIt() throws {
  let root = try scratchDirectory("through-link")
  try writeFile(root + "/a/f", "host")
  try FileManager.default.createSymbolicLink(atPath: root + "/a/lnk", withDestinationPath: ".")
  let input = WorkspaceInputConfig(
    mode: .paths,
    paths: [.init(path: "a/lnk", recursive: false), .init(path: "a/lnk/f", recursive: false)],
    exclude: [], secretAllow: [], limits: .ceilings)
  let snapshot = try capture(root, input)
  defer { snapshot.remove() }
  #expect(
    try FileManager.default.destinationOfSymbolicLink(atPath: snapshot.tree + "/a/lnk") == ".")
  var info = stat()
  #expect(lstat(snapshot.tree + "/a/f", &info) != 0)
  #expect(snapshot.report.links.contains("a/lnk/f"))
}

@Test func limitsAreSharedAcrossRootsAndNeverUnlimited() throws {
  let first = try scratchDirectory("r1")
  let second = try scratchDirectory("r2")
  for i in 0..<3 {
    try writeFile(first + "/f\(i)", "x")
    try writeFile(second + "/g\(i)", "x")
  }
  let limits = WorkspaceInputConfig.Limits(maxEntries: 5, maxFileBytes: 10, maxTotalBytes: 100)
  let input = WorkspaceInputConfig(
    mode: .paths, paths: [.init(path: ".", recursive: true)], exclude: [], secretAllow: [],
    limits: limits)
  let budget = InputBudget(limits)
  let a = try capture(first, input, budget: budget)
  defer { a.remove() }
  #expect(throws: HostError.self) { try capture(second, input, budget: budget) }
  try writeFile(first + "/big", String(repeating: "y", count: 11))
  #expect(throws: HostError.self) { try capture(first, input) }
  // Each file fits, but together they exceed the total.
  let total = try scratchDirectory("r3")
  for i in 0..<2 { try writeFile(total + "/h\(i)", String(repeating: "z", count: 10)) }
  let narrow = WorkspaceInputConfig(
    mode: .paths, paths: [.init(path: ".", recursive: true)], exclude: [], secretAllow: [],
    limits: .init(maxEntries: 100, maxFileBytes: 10, maxTotalBytes: 15))
  let error = try #require(throws: HostError.self) { try capture(total, narrow) }
  #expect(error.message.contains("max_total_bytes"))
}

@Test func inputConfigurationIsLiteralAndBounded() throws {
  func load(_ json: String) throws -> WorkspaceInputConfig {
    try ConfigLoader.decode(
      try ConfigLoader.parse(Array(json.utf8), format: .json, path: "t", limits: .configuration),
      path: "t", environment: ConfigEnvironment(home: "/h", variables: [:])
    ).workspaceInput
  }
  #expect(try load("{}") == .defaults)
  let parsed = try load(
    #"{"workspace": {"input": {"mode": "paths", "paths": [{"path": "src", "recursive": true}], "exclude": ["src/gen"], "secret_allow": ["src/.env"], "limits": {"max_entries": 10}}}}"#
  )
  #expect(parsed.mode == .paths && parsed.paths == [.init(path: "src", recursive: true)])
  #expect(parsed.limits.maxEntries == 10 && parsed.limits.maxFileBytes == 1 << 30)
  for bad in [
    #"{"workspace": {"input": {"mode": "paths"}}}"#,
    #"{"workspace": {"input": {"paths": [{"path": "../x"}]}}}"#,
    #"{"workspace": {"input": {"paths": [{"path": "/abs"}]}}}"#,
    #"{"workspace": {"input": {"paths": [{"path": "."}]}}}"#,
    #"{"workspace": {"input": {"exclude": ["a", "a"]}}}"#,
    #"{"workspace": {"input": {"exclude": ["a"], "secret_allow": ["a"]}}}"#,
    #"{"workspace": {"input": {"limits": {"max_entries": 100001}}}}"#,
    #"{"workspace": {"input": {"limits": {"max_total_bytes": 0}}}}"#,
    #"{"workspace": {"input": {"unknown": 1}}}"#,
  ] {
    #expect(throws: (any Error).self, "\(bad)") { try load(bad) }
  }
}

/// AUD-01/INPUT-01: a sent snapshot is audited by counts only; no selected
/// or omitted path name reaches the audit log.
@Test func aSentSnapshotIsAuditedWithCountsAndNoPathNames() throws {
  let root = try scratchDirectory("audited")
  try writeFile(root + "/visible-name.txt", "abc")
  try writeFile(root + "/sub/other-name.txt", "de")
  try writeFile(root + "/.env", "TOKEN=hunter2")
  let instance = try testInstance(try scratchDirectory("audit-instance") + "/instances/dev")
  let input = WorkspaceInputConfig(
    mode: .paths, paths: [.init(path: ".", recursive: true)], exclude: [], secretAllow: [],
    limits: .ceilings)
  // No ssh is reachable, so the send itself fails after the audit record.
  let transfer = WorkspaceTransfer(
    client: SSHClient(environment: ["PATH": root + "/no-bin"], tools: .searchPath),
    diagnostics: Diagnostics(verbosity: 0) { _ in })
  let target = SSHTarget(
    host: "10.231.1.2", port: 22, user: .default, keyPath: root + "/key",
    knownHosts: root + "/known_hosts", alias: "iso-test.iso")
  _ = try? transfer.sendSnapshot(
    target, root: root, to: GuestPath("/home/ubuntu/w"), input: input,
    budget: InputBudget(input.limits), stateDirectory: try scratchDirectory("audit-inputs"),
    audit: instance)
  let record = try #require(
    try BoundaryAudit.load(instance).last { $0["event"] as? String == "input_snapshot" })
  #expect(record["selected"] as? Int == 2)
  #expect(record["bytes"] as? Int == 5)
  #expect(record["secrets_omitted"] as? Int == 1)
  #expect(record["other_omitted"] as? Int == 0)
  #expect(record["deleted_tracked"] as? Int == 0)
  #expect((record["snapshot_id"] as? String)?.isEmpty == false)
  let text = try #require(readFile(BoundaryAudit.path(instance)))
  for name in [".env", "visible-name", "other-name", "sub", "hunter2", root] {
    #expect(!text.contains(name), "\(name)")
  }
}
