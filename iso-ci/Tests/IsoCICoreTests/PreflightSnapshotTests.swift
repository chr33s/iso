import Darwin
import Foundation
import Testing

@testable import IsoCICore

/// Snapshot capture on temporary git repositories and the synthetic
/// checkout/overlay scripts run locally with bash (C-T10).
@Suite(.serialized) struct PreflightSnapshotTests {
  let root: String

  init() throws {
    root = FileManager.default.temporaryDirectory.path + "/iso-ci-snapshot-" + randomHex(bytes: 6)
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  @discardableResult
  func run(
    _ executable: String, _ arguments: [String], in directory: String, env: [String: String] = [:]
  )
    throws -> Subprocess.Output
  {
    var environment = Subprocess.baseEnvironment()
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    // Isolate from the developer's global git config (signing, hooks).
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_AUTHOR_NAME"] = "t"
    environment["GIT_AUTHOR_EMAIL"] = "t@example.com"
    environment["GIT_COMMITTER_NAME"] = "t"
    environment["GIT_COMMITTER_EMAIL"] = "t@example.com"
    for (key, value) in env { environment[key] = value }
    return try Subprocess.run(
      Subprocess.Request(
        executable: executable, arguments: arguments, environment: environment,
        timeout: .seconds(120), outputLimit: 1 << 20, workingDirectory: directory))
  }

  func git(_ arguments: [String], _ repo: String) throws {
    let output = try run("/usr/bin/git", arguments, in: repo)
    #expect(output.succeeded, "git \(arguments): \(String(decoding: output.stderr, as: UTF8.self))")
  }

  func write(_ path: String, _ text: String, mode: mode_t = 0o644) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, mode)
  }

  /// A repository with a commit, then working-tree changes: a modified
  /// file, a deletion, an untracked file, a mode change, a credential file.
  func makeRepository() throws -> String {
    let repo = root + "/repo"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], repo)
    try write(repo + "/a.txt", "base a\n")
    try write(repo + "/del.txt", "to delete\n")
    try write(repo + "/bin/run.sh", "#!/bin/sh\necho run\n", mode: 0o755)
    try write(repo + "/lib/x.txt", "x\n")
    try write(repo + "/.github/workflows/ci.yml", "on: push\n")
    symlink("a.txt", repo + "/link")
    try git(["add", "-A"], repo)
    try git(["commit", "-q", "-m", "base"], repo)
    try write(repo + "/a.txt", "changed a\n")
    unlink(repo + "/del.txt")
    try write(repo + "/new.txt", "untracked\n")
    try write(repo + "/.env", "SECRET=hunter2\n")
    chmod(repo + "/lib/x.txt", 0o755)
    return repo
  }

  func options() -> SnapshotOptions {
    var options = SnapshotOptions(outputDirectory: root + "/out")
    options.include = ["new.txt", ".env"]
    options.workflowPath = ".github/workflows/ci.yml"
    return options
  }

  @Test func capturesDirtyTreeWithDeletionsModesLinksAndExclusions() throws {
    let repo = try makeRepository()
    let result = try SnapshotCapture.capture(repository: repo, options: options())
    let manifest = result.manifest
    #expect(manifest.isDirty)
    #expect(manifest.baseCommit.utf8.count == 40)
    // v2 has no base checkout: a removed file is simply absent.
    #expect(manifest.deletions.isEmpty)
    #expect(!manifest.files.contains { $0.path == "del.txt" })
    #expect(result.excludedPaths == [".env"])
    #expect(manifest.includedUntracked == ["new.txt"])
    let byPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
    #expect(byPath["a.txt"]?.sha256 == Digest(hashing: "changed a\n"))
    #expect(byPath["bin/run.sh"]?.mode == 0o755)
    #expect(byPath["lib/x.txt"]?.mode == 0o755)
    #expect(byPath["new.txt"] != nil)
    #expect(byPath[".env"] == nil)
    #expect(byPath["link"]?.kind == .symlink)
    #expect(byPath["link"]?.target == "a.txt")
    #expect(manifest.workflowDigest == Digest(hashing: "on: push\n"))
    // The archive digest is the streamed digest of the file.
    let bytes = try Data(contentsOf: URL(fileURLWithPath: result.archivePath))
    #expect(Digest(hashing: bytes) == result.digest)
    #expect(result.size == UInt64(bytes.count))
    #expect(!String(decoding: bytes, as: UTF8.self).contains("hunter2"))
    // The guest-visible manifest does not say which paths were left out.
    let archived = try run("/usr/bin/tar", ["-xOf", result.archivePath, "manifest.json"], in: root)
    let json = try StrictJSON.parse(archived.stdout, limits: JSONLimits(maxBytes: 1 << 20))
    #expect(json["excludedPaths"] == nil)
    #expect(json["includedUntracked"] == ["new.txt"])
  }

  /// A tracked directory replaced by a symlink to a directory outside the
  /// working tree: capture refuses instead of reading through the link.
  @Test func refusesATrackedDirectoryReplacedByASymlink() throws {
    let repo = try makeRepository()
    let outside = root + "/outside"
    try write(outside + "/x.txt", "outside secret\n")
    try FileManager.default.removeItem(atPath: repo + "/lib")
    symlink(outside, repo + "/lib")
    var options = options()
    options.outputDirectory = root + "/out-link"
    #expect {
      try SnapshotCapture.capture(repository: repo, options: options)
    } throws: { error in
      (error as? CIError)?.code == .compatibilityRejected
    }
    // Nothing was left behind, and nothing outside was archived.
    let left = (try? FileManager.default.contentsOfDirectory(atPath: options.outputDirectory)) ?? []
    #expect(left.isEmpty)
    // A relative link that stays inside the tree is refused the same way:
    // the tracked path must be reached through real directories.
    unlink(repo + "/lib")
    try FileManager.default.createDirectory(
      atPath: repo + "/real", withIntermediateDirectories: true)
    try write(repo + "/real/x.txt", "x\n")
    symlink("real", repo + "/lib")
    #expect(throws: CIError.self) {
      try SnapshotCapture.capture(repository: repo, options: options)
    }
  }

  @Test func aSplitIndexIsRefused() throws {
    let repo = root + "/split"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try git(["init", "-q"], repo)
    try write(repo + "/a.txt", "a\n")
    try git(["-c", "core.splitIndex=true", "add", "-A"], repo)
    try write(repo + "/b.txt", "b\n")
    try git(["-c", "core.splitIndex=true", "add", "b.txt"], repo)
    try git(["-c", "core.splitIndex=true", "commit", "-q", "-m", "c"], repo)
    #expect {
      try GitIndex.entries(try GitIndex.layout(containing: repo))
    } throws: { error in
      (error as? CIError)?.message.contains("split index") == true
    }
  }

  @Test func originURLIsReadInertlyFromTheRepositoryConfig() throws {
    func value(_ text: String) -> String? {
      GitConfigFile.lastValue(
        Array(text.utf8), section: "remote", subsection: "origin", key: "url")
    }
    #expect(
      value("[remote \"origin\"]\n\turl = git@github.com:octo/demo.git\n")
        == "git@github.com:octo/demo.git")
    // Case-insensitive section and key, comments, quotes, escapes, CRLF,
    // and the last value wins.
    #expect(
      value(
        "# c\r\n[REMOTE \"origin\"] ; c\r\n  URL = first\r\n\tUrl = \"https://x/o/r\" # trailing\r\n"
      )
        == "https://x/o/r")
    #expect(value("[remote \"origin\"]\nurl = a\\\nb\n") == "ab")
    #expect(value("[remote \"origin\"]\nurl = \"a;b#c\"  \n") == "a;b#c")
    // The subsection is case-sensitive; the legacy dotted form is lowercased.
    #expect(value("[remote \"Origin\"]\nurl = x\n") == nil)
    #expect(value("[remote.Origin]\nurl = x\n") == "x")
    // Other sections and remotes do not count; a key on the header line does.
    #expect(value("[remote \"upstream\"]\nurl = x\n[branch \"main\"]\nremote = origin\n") == nil)
    #expect(value("[remote \"origin\"] url = y\n") == "y")
    // Malformed or valueless content yields nothing rather than a guess.
    #expect(value("[remote \"origin\"\nurl = x\n") == nil)
    #expect(value("[remote \"origin\"]\nurl = \"x\n") == nil)
    #expect(value("[remote \"origin\"]\nurl\n") == nil)
    #expect(value("url = x\n") == nil)
  }

  /// A linked worktree's `.git` file leads to the shared config; include
  /// directives are never followed, though Git itself would honor them.
  @Test func repositoryNameFollowsTheWorktreeGitfileButNotIncludes() throws {
    let repo = try makeRepository()
    try git(["remote", "add", "origin", "git@github.com:octo/inert.git"], repo)
    try write(
      repo + "/.git/included.cfg", "[remote \"origin\"]\n\turl = https://github.com/evil/included\n"
    )
    try write(
      repo + "/.git/config",
      try String(contentsOfFile: repo + "/.git/config", encoding: .utf8)
        + "[include]\n\tpath = included.cfg\n")
    // Witness: Git itself would take the included value.
    let witness = try run("/usr/bin/git", ["config", "--get", "remote.origin.url"], in: repo)
    #expect(String(decoding: witness.stdout, as: UTF8.self).contains("evil/included"))
    #expect(PreflightService.repositoryName(repo) == "octo/inert")
    let worktree = root + "/worktree"
    try git(["worktree", "add", "-q", worktree], repo)
    var status = stat()
    #expect(lstat(worktree + "/.git", &status) == 0 && status.st_mode & S_IFMT == S_IFREG)
    #expect(PreflightService.repositoryName(worktree) == "octo/inert")
    #expect(PreflightService.repositoryName(root + "/clean-none").hasPrefix("local/"))
  }

  @Test func captureIsDeterministic() throws {
    let repo = try makeRepository()
    let first = try SnapshotCapture.capture(repository: repo, options: options())
    let second = try SnapshotCapture.capture(repository: repo, options: options())
    #expect(first.digest == second.digest)
    #expect(first.manifest == second.manifest)
  }

  @Test func cleanTreeIsNotDirty() throws {
    let repo = root + "/clean"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try git(["init", "-q"], repo)
    try write(repo + "/f.txt", "f\n")
    try git(["add", "-A"], repo)
    try git(["commit", "-q", "-m", "c"], repo)
    let result = try SnapshotCapture.capture(repository: repo, options: options())
    #expect(!result.manifest.isDirty)
    #expect(result.manifest.deletions.isEmpty)
    #expect(!result.reference.isDirty)
  }

  @Test(arguments: ["2", "3", "4"]) func indexReaderMatchesGitAcrossVersions(version: String)
    throws
  {
    let repo = root + "/index-v\(version)"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try git(["init", "-q"], repo)
    try git(["config", "index.version", version], repo)
    // A v4 prefix strip of 128 bytes or more needs a multi-byte varint.
    let long = "long/" + String(repeating: "p", count: 200) + "/x.txt"
    let expected = ["a.txt", long, "z.txt"]
    for path in expected { try write(repo + "/" + path, path) }
    try git(["add", "-A"], repo)
    let entries = try GitIndex.entries(try GitIndex.layout(containing: repo))
    #expect(entries.map(\.path) == expected)
  }

  @Test func anUnreadableIndexFailsTheCaptureInsteadOfLookingClean() throws {
    let repo = try makeRepository()
    chmod(repo + "/.git/index", 0)
    defer { chmod(repo + "/.git/index", 0o644) }
    #expect(throws: CIError.self) {
      try SnapshotCapture.capture(repository: repo, options: options())
    }
  }

  @Test func untrackedFilesNeedAnExplicitInclude() throws {
    let repo = try makeRepository()
    var options = options()
    options.include = []
    let manifest = try SnapshotCapture.capture(repository: repo, options: options).manifest
    #expect(manifest.includedUntracked.isEmpty)
    #expect(!manifest.files.contains { $0.path == "new.txt" })
    #expect(manifest.isDirty)
  }

  @Test func stagedOnlyChangesAreDirty() throws {
    let repo = root + "/staged"
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try git(["init", "-q"], repo)
    try write(repo + "/f.txt", "f\n")
    try git(["add", "-A"], repo)
    try git(["commit", "-q", "-m", "c"], repo)
    sleep(1)
    try write(repo + "/f.txt", "g\n")
    try git(["add", "-A"], repo)
    let manifest = try SnapshotCapture.capture(repository: repo, options: options()).manifest
    #expect(manifest.isDirty)
  }

  /// Capture reads the repository as data: a clean filter that any Git
  /// diff of the modified tracked file would run never runs.
  @Test func captureRunsNoGitConfiguration() throws {
    let repo = try makeRepository()
    let marker = root + "/filter-ran"
    try write(repo + "/.git/filter.sh", "#!/bin/sh\ntouch '\(marker)'\ncat\n", mode: 0o755)
    try git(["config", "filter.probe.clean", repo + "/.git/filter.sh"], repo)
    try write(repo + "/.git/info/attributes", "* filter=probe\n")
    _ = try SnapshotCapture.capture(repository: repo, options: options())
    #expect(access(marker, F_OK) != 0)
    // Witness: the filter is live for Git itself.
    try run("/usr/bin/git", ["diff", "--quiet"], in: repo)
    #expect(access(marker, F_OK) == 0)
  }

  @Test func refusesEscapingSymlinks() throws {
    let repo = try makeRepository()
    var options = options()
    options.include = ["escape", "absolute"]
    symlink("../../outside", repo + "/escape")
    #expect(throws: CIError.self) {
      try SnapshotCapture.capture(repository: repo, options: options)
    }
    unlink(repo + "/escape")
    symlink("/etc/hosts", repo + "/absolute")
    #expect(throws: CIError.self) {
      try SnapshotCapture.capture(repository: repo, options: options)
    }
  }

  @Test func exclusionPatterns() {
    let patterns = SnapshotOptions.defaultExcludes
    #expect(SnapshotCapture.excluded(".env", patterns: patterns))
    #expect(SnapshotCapture.excluded("config/.env.local", patterns: patterns))
    #expect(SnapshotCapture.excluded("certs/server.pem", patterns: patterns))
    #expect(SnapshotCapture.excluded("home/.aws/credentials", patterns: patterns))
    #expect(SnapshotCapture.excluded(".docker/config.json", patterns: patterns))
    #expect(SnapshotCapture.excluded("keys/id_ed25519.pub", patterns: patterns))
    // Matching ignores case, as the default macOS file system does.
    #expect(SnapshotCapture.excluded("Config/.ENV", patterns: patterns))
    #expect(SnapshotCapture.excluded("certs/Server.PEM", patterns: patterns))
    #expect(SnapshotCapture.excluded("Home/.AWS/credentials", patterns: patterns))
    #expect(SnapshotCapture.excluded(".Docker/Config.json", patterns: patterns))
    for path in [
      ".gem/credentials", "home/.gem/credentials", ".terraformrc", "terraform.rc",
      "infra/terraform.tfstate", "infra/terraform.tfstate.backup", "keys/release.jks",
      ".pgpass", ".my.cnf", "putty/key.ppk", ".s3cfg", ".boto", ".config/gh/hosts.yml",
      "home/.config/gh/hosts.yml", ".yarnrc.yml",
    ] {
      #expect(SnapshotCapture.excluded(path, patterns: patterns), "\(path)")
    }
    #expect(!SnapshotCapture.excluded("terraform.tf", patterns: patterns))
    #expect(!SnapshotCapture.excluded(".config/gh/config.yml", patterns: patterns))
    #expect(!SnapshotCapture.excluded("src/environment.swift", patterns: patterns))
    #expect(!SnapshotCapture.excluded("README.md", patterns: patterns))
  }

  @Test func detectsConcurrentModificationWhileReading() throws {
    let path = root + "/moving.txt"
    try write(path, "before\n")
    var status = stat()
    lstat(path, &status)
    let observed = SnapshotCapture.Observed(status)
    try write(path, "after, and longer\n")
    var writer = try TarWriter(path: root + "/t.tar")
    defer { writer.close() }
    let directory = open(root, O_RDONLY | O_DIRECTORY)
    defer { close(directory) }
    #expect(throws: SnapshotCapture.ConcurrentChange.self) {
      _ = try writer.addFile(
        name: "tree/moving.txt", mode: 0o644, directory: directory, source: "moving.txt",
        expectedSize: UInt64(status.st_size), expected: observed)
    }
  }

  @Test func paxRecordsAreSelfDescribingLengths() {
    let record = TarWriter.paxRecord("path", String(repeating: "x", count: 120))
    let length = Int(record.split(separator: " ").first!)!
    #expect(length == record.utf8.count)
  }

  // MARK: Overlay scripts

  struct Guest {
    let workspace: String
    let temp: String
    let endpoint: String
  }

  func guest(serving result: SnapshotCaptureResult) throws -> Guest {
    let endpoint = root + "/endpoint"
    let route = endpoint + OverlayScripts.route(result.digest)
    try FileManager.default.createDirectory(
      atPath: (route as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.copyItem(atPath: result.archivePath, toPath: route)
    let workspace = root + "/workspace"
    let temp = root + "/runner-temp"
    try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
    return Guest(workspace: workspace, temp: temp, endpoint: "file://" + endpoint)
  }

  func step(_ script: String, _ guest: Guest, path: String? = nil) throws -> Subprocess.Output {
    var env = [
      "GITHUB_WORKSPACE": guest.workspace, "RUNNER_TEMP": guest.temp,
      "ISO_CI_ENDPOINT": guest.endpoint, "ISO_CI_TOKEN": "test-token",
    ]
    if let path { env["PATH"] = path }
    return try run("/bin/" + OverlayScripts.shell, ["-c", script], in: guest.workspace, env: env)
  }

  /// A PATH with every tool in /bin and /usr/bin except git (a minimal job
  /// container).
  func pathWithoutGit() throws -> String {
    let bin = root + "/nogit-bin"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    for directory in ["/bin", "/usr/bin"] {
      for name in try FileManager.default.contentsOfDirectory(atPath: directory)
      where name != "git" && !FileManager.default.fileExists(atPath: bin + "/" + name) {
        try FileManager.default.createSymbolicLink(
          atPath: bin + "/" + name, withDestinationPath: directory + "/" + name)
      }
    }
    return bin
  }

  func text(_ output: Subprocess.Output) -> String {
    String(decoding: output.stdout + output.stderr, as: UTF8.self)
  }

  @Test func checkoutThenOverlayMaterializesAndVerifiesTheSnapshot() throws {
    let repo = try makeRepository()
    let result = try SnapshotCapture.capture(repository: repo, options: options())
    let guest = try guest(serving: result)
    let reference = result.reference
    let checkout = try step(OverlayScripts.checkout(snapshot: reference, path: "."), guest)
    #expect(checkout.succeeded, "\(text(checkout))")
    // CI-01: the checkout carries no base commit or history; the snapshot
    // has no bundle at all.
    #expect(!FileManager.default.fileExists(atPath: guest.workspace + "/a.txt"))
    #expect(!FileManager.default.fileExists(atPath: guest.workspace + "/del.txt"))
    #expect(result.manifest.schema == "iso-ci.snapshot/v2")
    let overlay = try step(OverlayScripts.overlay(snapshot: reference, path: "."), guest)
    #expect(overlay.succeeded, "\(text(overlay))")
    #expect(
      try String(contentsOfFile: guest.workspace + "/a.txt", encoding: .utf8) == "changed a\n")
    #expect(!FileManager.default.fileExists(atPath: guest.workspace + "/del.txt"))
    #expect(FileManager.default.fileExists(atPath: guest.workspace + "/new.txt"))
    #expect(!FileManager.default.fileExists(atPath: guest.workspace + "/.env"))
    #expect(FileManager.default.isExecutableFile(atPath: guest.workspace + "/lib/x.txt"))
    #expect(
      try FileManager.default.destinationOfSymbolicLink(atPath: guest.workspace + "/link")
        == "a.txt")
    #expect(text(overlay).contains("applied and verified"))
    #expect(text(overlay).contains("synthetic commit"))
    #expect(!text(overlay).contains("test-token"))

    // Regression: a later user step mutating the workspace does not change
    // the recorded snapshot provenance, and a fresh overlay re-verifies.
    try write(guest.workspace + "/a.txt", "mutated by a later step\n")
    #expect(result.reference == reference)
    #expect(
      result.manifest.files.first { $0.path == "a.txt" }?.sha256 == Digest(hashing: "changed a\n"))
    let again = try step(OverlayScripts.overlay(snapshot: reference, path: "."), guest)
    #expect(again.succeeded, "\(text(again))")
  }

  /// A job container without git: the checkout leaves no `.git` and the
  /// overlay still materializes and verifies the whole snapshot.
  @Test func checkoutWithoutGitLeavesTheOverlayToMaterializeTheSnapshot() throws {
    let repo = try makeRepository()
    let result = try SnapshotCapture.capture(repository: repo, options: options())
    let guest = try guest(serving: result)
    let path = try pathWithoutGit()
    let checkout = try step(
      OverlayScripts.checkout(snapshot: result.reference, path: "."), guest, path: path)
    #expect(checkout.succeeded, "\(text(checkout))")
    #expect(text(checkout).contains("history is not included"))
    #expect(!FileManager.default.fileExists(atPath: guest.workspace + "/.git"))
    let overlay = try step(
      OverlayScripts.overlay(snapshot: result.reference, path: "."), guest, path: path)
    #expect(overlay.succeeded, "\(text(overlay))")
    #expect(
      try String(contentsOfFile: guest.workspace + "/a.txt", encoding: .utf8) == "changed a\n")
    #expect(!FileManager.default.fileExists(atPath: guest.workspace + "/del.txt"))
    #expect(FileManager.default.isExecutableFile(atPath: guest.workspace + "/lib/x.txt"))
  }

  @Test func overlayWithoutCheckoutAndMismatchFailures() throws {
    let repo = try makeRepository()
    let result = try SnapshotCapture.capture(repository: repo, options: options())
    let guest = try guest(serving: result)
    let reference = result.reference
    let overlay = try step(OverlayScripts.overlay(snapshot: reference, path: "sub"), guest)
    #expect(overlay.succeeded, "\(text(overlay))")
    #expect(FileManager.default.fileExists(atPath: guest.workspace + "/sub/new.txt"))
    // A corrupted materialization source fails verification loudly.
    let cache = guest.temp + "/iso-ci-snapshot-" + result.digest.rawValue
    try write(cache + "/x/tree/a.txt", "tampered\n")
    let tampered = try step(OverlayScripts.overlay(snapshot: reference, path: "sub"), guest)
    #expect(!tampered.succeeded)
    #expect(text(tampered).contains("verification failed"))
    // A snapshot whose bytes do not match the digest is refused.
    try FileManager.default.removeItem(atPath: cache)
    try write(
      root + "/endpoint" + OverlayScripts.route(result.digest), "not the snapshot")
    let wrong = try step(OverlayScripts.overlay(snapshot: reference, path: "sub"), guest)
    #expect(!wrong.succeeded)
    #expect(text(wrong).contains("digest mismatch"))
  }

  @Test func syntheticScriptsOnlyForSyntheticKinds() {
    let reference = SnapshotReference(
      baseCommit: String(repeating: "c", count: 40), digest: Digest(hashing: "x"), isDirty: false)
    #expect(OverlayScripts.script(for: .syntheticCheckout(path: "."), snapshot: reference) != nil)
    #expect(
      OverlayScripts.script(for: .snapshotOverlay(path: "a b"), snapshot: reference)?.contains(
        "'a b'") == true)
    #expect(
      OverlayScripts.script(
        for: .run(script: .string("x"), shell: nil, workingDirectory: nil), snapshot: reference)
        == nil)
  }
}
