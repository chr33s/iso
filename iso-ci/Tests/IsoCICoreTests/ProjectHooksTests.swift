import Darwin
import Foundation
import Testing

@testable import IsoCICore

/// Staged snapshots and the project Git hooks that run local preflight
/// before commits or pushes, on temporary repositories with real Git.
@Suite(.serialized) struct ProjectHooksTests {
  let root: String

  init() throws {
    root = FileManager.default.temporaryDirectory.path + "/iso-ci-hooks-" + randomHex(bytes: 6)
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  func cleanup() { try? FileManager.default.removeItem(atPath: root) }

  var gitEnvironment: [String: String] {
    var environment = Subprocess.baseEnvironment()
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_AUTHOR_NAME"] = "t"
    environment["GIT_AUTHOR_EMAIL"] = "t@example.com"
    environment["GIT_COMMITTER_NAME"] = "t"
    environment["GIT_COMMITTER_EMAIL"] = "t@example.com"
    return environment
  }

  @discardableResult
  func git(_ arguments: [String], _ repo: String, env: [String: String] = [:]) throws
    -> Subprocess.Output
  {
    var environment = gitEnvironment
    for (key, value) in env { environment[key] = value }
    return try Subprocess.run(
      .init(
        executable: "/usr/bin/git", arguments: arguments, environment: environment,
        timeout: .seconds(120), workingDirectory: repo))
  }

  func write(_ path: String, _ text: String, mode: mode_t = 0o644) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    chmod(path, mode)
  }

  func makeRepository(_ name: String = "repo") throws -> String {
    let repo = root + "/" + name
    try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"], repo)
    try write(repo + "/a.txt", "base a\n")
    try write(repo + "/bin/run.sh", "#!/bin/sh\necho run\n", mode: 0o755)
    try write(repo + "/.github/workflows/ci.yml", "on: push\n")
    try FileManager.default.createSymbolicLink(
      atPath: repo + "/link", withDestinationPath: "a.txt")
    try git(["add", "-A"], repo)
    try git(["commit", "-qm", "base"], repo)
    return repo
  }

  func capture(_ repo: String, source: SnapshotSource, include: [String] = []) throws(CIError)
    -> SnapshotCaptureResult
  {
    var options = SnapshotOptions(outputDirectory: root + "/out")
    options.source = source
    options.include = include
    return try SnapshotCapture.capture(repository: repo, options: options)
  }

  // MARK: Staged snapshots

  @Test func stagedSnapshotCapturesExactlyTheIndex() throws {
    defer { cleanup() }
    let repo = try makeRepository()
    try write(repo + "/a.txt", "staged a\n")
    try write(repo + "/new.txt", "new\n")
    try write(repo + "/untracked.txt", "never\n")
    try git(["add", "a.txt", "new.txt"], repo)
    try git(["rm", "-q", "--cached", "bin/run.sh"], repo)
    let result = try capture(repo, source: .staged)
    let files = Dictionary(uniqueKeysWithValues: result.manifest.files.map { ($0.path, $0) })
    #expect(Set(files.keys) == [".github/workflows/ci.yml", "a.txt", "link", "new.txt"])
    #expect(files["a.txt"]?.sha256 == Digest(hashing: Array("staged a\n".utf8)))
    #expect(files["link"]?.target == "a.txt")
  }

  @Test func stagedSnapshotRefusesWhatTheCommitWouldNotContain() throws {
    defer { cleanup() }
    let repo = try makeRepository()
    func refusal(_ prepare: () throws -> Void, undo: () throws -> Void) throws -> String? {
      try prepare()
      defer { try? undo() }
      do {
        _ = try capture(repo, source: .staged)
        return nil
      } catch {
        #expect(error.code == .conflict)
        return error.message
      }
    }
    func restore() throws { try git(["checkout", "-q", "--", "."], repo) }
    // An unstaged edit, deletion, mode change and retargeted link.
    #expect(
      try refusal({ try write(repo + "/a.txt", "unstaged\n") }, undo: restore)?.contains("a.txt")
        == true)
    #expect(
      try refusal({ try FileManager.default.removeItem(atPath: repo + "/a.txt") }, undo: restore)?
        .contains("a.txt") == true)
    #expect(
      try refusal(
        { chmod(repo + "/bin/run.sh", 0o644) }, undo: { chmod(repo + "/bin/run.sh", 0o755) })?
        .contains("bin/run.sh") == true)
    #expect(
      try refusal(
        {
          try FileManager.default.removeItem(atPath: repo + "/link")
          try FileManager.default.createSymbolicLink(
            atPath: repo + "/link", withDestinationPath: "bin/run.sh")
        }, undo: restore)?.contains("link") == true)
    try write(repo + "/later.txt", "later\n")
    #expect(
      try refusal(
        { try git(["add", "-N", "later.txt"], repo) },
        undo: {
          try git(["rm", "-q", "--cached", "later.txt"], repo)
        })?.contains("later.txt") == true)
    #expect(throws: CIError.self) { try capture(repo, source: .staged, include: ["later.txt"]) }
    try write(repo + "/a.txt", "unstaged\n")
    #expect(try capture(repo, source: .workingTree).manifest.isDirty)
  }

  // MARK: Hook script

  @Test func hookScriptsRoundTripTheirSettingsAndAreValidShell() throws {
    defer { cleanup() }
    for hook in GitHookKind.allCases {
      let settings = ManagedHookSettings(
        hook: hook, branch: "release/v1", workflow: ".github/workflows/ci.yml",
        timeoutSeconds: 600)
      let text = GitHooks.script(settings)
      #expect(GitHooks.settings(fromScript: text) == settings)
      let path = root + "/" + hook.rawValue
      try write(path, text, mode: 0o755)
      let check = try Subprocess.run(.init(executable: "/bin/sh", arguments: ["-n", path]))
      #expect(check.status == 0, "\(hook): \(String(decoding: check.stderr, as: UTF8.self))")
    }
    #expect(GitHooks.settings(fromScript: "#!/bin/sh\necho hi\n") == nil)
  }

  @Test func hookSettingsRefuseUnusualValues() {
    for settings in [
      ManagedHookSettings(hook: .preCommit, branch: "-x"),
      ManagedHookSettings(hook: .preCommit, branch: "a..b"),
      ManagedHookSettings(hook: .preCommit, branch: "main'; rm -rf ~"),
      ManagedHookSettings(hook: .preCommit, workflow: "../ci.yml"),
      ManagedHookSettings(hook: .preCommit, workflow: "/etc/ci.yml"),
      ManagedHookSettings(hook: .preCommit, workflow: ".github/workflows/ci.sh"),
      ManagedHookSettings(hook: .preCommit, event: "push;x"),
      ManagedHookSettings(hook: .preCommit, timeoutSeconds: 0),
    ] {
      #expect(throws: CIError.self, "\(settings)") { try settings.validate() }
    }
  }

  // MARK: Install, status, uninstall

  @Test func installRefusesToOverwriteOrDisableExistingHooks() throws {
    defer { cleanup() }
    let repo = try makeRepository()
    let writer = try GitCommandConfigWriter(root: repo)
    let settings = ManagedHookSettings(hook: .preCommit)
    // An active hook in .git/hooks would stop running once core.hooksPath moves.
    try write(repo + "/.git/hooks/pre-push", "#!/bin/sh\nexit 0\n", mode: 0o755)
    var repository = try GitHooks.repository(containing: repo)
    #expect(throws: CIError.self) {
      try GitHooks.planInstall(
        repository: repository, settings: settings, directory: nil, force: false)
    }
    try FileManager.default.removeItem(atPath: repo + "/.git/hooks/pre-push")

    // A hook that iso-ci did not write is kept unless forced, then backed up.
    try write(repo + "/.githooks/pre-commit", "#!/bin/sh\necho mine\n", mode: 0o755)
    repository = try GitHooks.repository(containing: repo)
    #expect(throws: CIError.self) {
      try GitHooks.planInstall(
        repository: repository, settings: settings, directory: nil, force: false)
    }
    let forced = try GitHooks.planInstall(
      repository: repository, settings: settings, directory: nil, force: true)
    #expect(forced.existing == .unmanaged)
    #expect(forced.setsHooksPath == ".githooks")
    try GitHooks.install(forced, git: writer)
    repository = try GitHooks.repository(containing: repo)
    #expect(repository.hooksPathSource == .local)
    #expect(repository.hooksPath == ".githooks")
    let statuses = try GitHooks.status(repository)
    let preCommit = try #require(statuses.first { $0.hook == .preCommit })
    #expect(preCommit.state == .managed && preCommit.hasBackup && preCommit.settings == settings)

    // Reinstalling a managed hook updates it in place.
    let again = try GitHooks.planInstall(
      repository: repository,
      settings: ManagedHookSettings(hook: .preCommit, timeoutSeconds: 60), directory: nil,
      force: false)
    #expect(again.existing == .managed && again.setsHooksPath == nil && again.backupPath == nil)

    // Uninstall restores the replaced hook; the directory still holds a
    // hook, so the core.hooksPath iso-ci set stays.
    let removed = try GitHooks.uninstall(repository, hooks: GitHookKind.allCases, git: writer)
    #expect(removed.removed == [repo + "/.githooks/pre-commit"])
    #expect(removed.restored == [repo + "/.githooks/pre-commit"])
    #expect(!removed.unsetHooksPath)
    #expect(
      try String(contentsOfFile: repo + "/.githooks/pre-commit", encoding: .utf8).contains("mine"))
  }

  @Test func uninstallUnsetsOnlyTheHooksPathIsoCISet() throws {
    defer { cleanup() }
    let repo = try makeRepository()
    let writer = try GitCommandConfigWriter(root: repo)
    var repository = try GitHooks.repository(containing: repo)
    try GitHooks.install(
      try GitHooks.planInstall(
        repository: repository, settings: ManagedHookSettings(hook: .prePush), directory: nil,
        force: false), git: writer)
    repository = try GitHooks.repository(containing: repo)
    #expect(repository.ownedHooksPath == ".githooks")
    let result = try GitHooks.uninstall(repository, hooks: GitHookKind.allCases, git: writer)
    #expect(result.unsetHooksPath)
    let after = try GitHooks.repository(containing: repo)
    #expect(after.hooksPathSource == .none && after.ownedHooksPath == nil)
    #expect(!FileManager.default.fileExists(atPath: repo + "/.githooks"))
  }

  @Test func aUserHooksPathIsNotBypassedSilently() throws {
    defer { cleanup() }
    let repo = try makeRepository()
    let home = root + "/home"
    try write(home + "/.gitconfig", "[core]\n\thooksPath = ~/.company-hooks\n")
    let repository = try GitHooks.repository(containing: repo, environment: ["HOME": home])
    #expect(repository.hooksPathSource == .global)
    #expect(throws: CIError.self) {
      try GitHooks.planInstall(
        repository: repository, settings: ManagedHookSettings(hook: .preCommit), directory: nil,
        force: false)
    }
  }

  // MARK: The hook in Git

  /// A fake `iso-ci` that records its arguments and exits with `status`.
  func fakeIsoCI(status: Int32) throws -> (bin: String, log: String) {
    let bin = root + "/bin-\(status)"
    let log = root + "/iso-ci-\(status).log"
    try write(
      bin + "/iso-ci", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log)'\nexit \(status)\n", mode: 0o755
    )
    return (bin, log)
  }

  func installed(_ repo: String, _ settings: ManagedHookSettings) throws {
    let repository = try GitHooks.repository(containing: repo)
    try GitHooks.install(
      try GitHooks.planInstall(
        repository: repository, settings: settings, directory: nil, force: false),
      git: try GitCommandConfigWriter(root: repo))
  }

  @Test func preCommitGatesOnlyTheProtectedBranch() throws {
    defer { cleanup() }
    let repo = try makeRepository()
    try installed(repo, ManagedHookSettings(hook: .preCommit, timeoutSeconds: 90))
    let passing = try fakeIsoCI(status: 0)
    let failing = try fakeIsoCI(status: 1)
    func commit(_ bin: String?, _ message: String) throws -> Subprocess.Output {
      try write(repo + "/a.txt", message + "\n")
      try git(["add", "a.txt"], repo)
      let path = (bin.map { $0 + ":" } ?? "") + "/usr/bin:/bin"
      return try git(["commit", "-qm", message], repo, env: ["PATH": path])
    }
    #expect(try commit(passing.bin, "one").status == 0)
    #expect(
      try String(contentsOfFile: passing.log, encoding: .utf8)
        == "run .github/workflows/ci.yml --event push --snapshot staged --follow --timeout 90\n")
    #expect(try commit(failing.bin, "two").status != 0)
    let missing = try commit(nil, "three")
    #expect(missing.status != 0)
    #expect(String(decoding: missing.stderr, as: UTF8.self).contains("iso-ci is required"))
    try git(["checkout", "-q", "-b", "feature"], repo)
    #expect(try commit(nil, "four").status == 0)
    #expect(try commit(failing.bin, "five").status == 0)
    #expect(
      try String(contentsOfFile: failing.log, encoding: .utf8).split(separator: "\n").count == 1)
  }

  @Test func prePushChecksTheCheckedOutCommitPushedToTheBranch() throws {
    defer { cleanup() }
    let remote = root + "/remote.git"
    try FileManager.default.createDirectory(atPath: remote, withIntermediateDirectories: true)
    try git(["init", "-q", "--bare", "-b", "main"], remote)
    let repo = try makeRepository()
    try git(["remote", "add", "origin", remote], repo)
    try installed(repo, ManagedHookSettings(hook: .prePush))
    let passing = try fakeIsoCI(status: 0)
    let env = ["PATH": passing.bin + ":/usr/bin:/bin"]
    #expect(try git(["push", "-q", "origin", "main"], repo, env: env).status == 0)
    #expect(try String(contentsOfFile: passing.log, encoding: .utf8).contains("--snapshot staged"))
    // Staged changes are not part of the pushed commit.
    try write(repo + "/a.txt", "next\n")
    try git(["commit", "-qam", "next"], repo)
    try write(repo + "/a.txt", "staged only\n")
    try git(["add", "a.txt"], repo)
    #expect(try git(["push", "-q", "origin", "main"], repo, env: env).status != 0)
    try git(["reset", "-q", "--hard"], repo)
    // A commit other than the checkout cannot be checked.
    try git(["checkout", "-q", "-b", "other", "HEAD~1"], repo)
    #expect(try git(["push", "-q", "origin", "main:main"], repo, env: env).status != 0)
    #expect(
      try git(["push", "-q", "origin", "other"], repo, env: ["PATH": "/usr/bin:/bin"]).status == 0)
  }
}
