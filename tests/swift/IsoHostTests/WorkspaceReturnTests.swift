import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

/// Scratch layout for return tests: an instance under `state/` (its control
/// roots), a destination beside it, and an `outside` sentinel tree.
private struct ReturnFixture {
  let root: String
  let instance: Instance
  var destination: String { root + "/dest" }
  var outside: String { root + "/outside" }
  var location: StageLocation { StageLocation(instance) }
  let transfer = WorkspaceTransfer(
    client: SSHClient(environment: ["PATH": "/usr/bin:/bin"], tools: .searchPath),
    diagnostics: Diagnostics(verbosity: 0, sink: { _ in }))

  init(createDestination: Bool = true) throws {
    root = try scratchDirectory("ret")
    instance = try testInstance(root + "/state/instances/dev")
    try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
    try writeFile(outside + "/sentinel", "untouched")
    if createDestination {
      try FileManager.default.createDirectory(
        atPath: destination, withIntermediateDirectories: true)
    }
  }

  @discardableResult
  func stage(_ files: [String: String], links: [String: String] = [:]) throws -> StageManifest {
    try makeSelectedStage(location, destination: destination, instance: "dev") { tree in
      try populate(tree, files)
      for (path, target) in links {
        try FileManager.default.createSymbolicLink(
          atPath: tree + "/" + path, withDestinationPath: target)
      }
    }.manifest
  }

  func apply(
    _ id: String, replace: Bool = true, sensitive: [String] = [], direct: Bool = false
  ) throws -> [String] {
    try transfer.applyStage(
      instance, .init(stageID: id, replace: replace, sensitive: sensitive, direct: direct)
    ).applied
  }

  var sentinelIntact: Bool {
    (try? String(contentsOfFile: outside + "/sentinel", encoding: .utf8)) == "untouched"
      && (try? FileManager.default.contentsOfDirectory(atPath: outside)) == ["sentinel"]
  }
}

private func returnError(_ body: () throws -> Void) -> ReturnError? {
  do {
    try body()
    return nil
  } catch let error as ReturnError {
    return error
  } catch {
    Issue.record("unexpected \(error)")
    return nil
  }
}

// MARK: - R1/R2: no host Git, protected administration

@Test func returnNeverRunsHostGitEvenWithAHostileRepository() throws {
  let f = try ReturnFixture()
  // A destination repository whose config would run a command if any Git
  // inspected it, plus a PATH git that would leave a marker.
  let marker = f.root + "/git-ran"
  try writeFile(f.destination + "/.git/config", "[core]\n\tfsmonitor = touch \(marker)\n")
  try writeFile(f.destination + "/tracked.txt", "host\n")
  let bin = f.root + "/bin"
  try writeFile(bin + "/git", "#!/bin/sh\ntouch \(marker)\n")
  chmod(bin + "/git", 0o755)
  let manifest = try f.stage(["tracked.txt": "guest\n", "new.txt": "n"])
  // Positive control: the fake git does leave a marker when run.
  _ = try ProcessRunner().capture(
    .init(executable: bin + "/git", arguments: [], environment: [:], deadline: .seconds(5)))
  #expect(FileManager.default.fileExists(atPath: marker))
  try FileManager.default.removeItem(atPath: marker)
  _ = try f.apply(manifest.id)
  #expect(!FileManager.default.fileExists(atPath: marker))
  #expect(readFile(f.destination + "/tracked.txt") == "guest\n")
}

@Test func gitAdministrationIsNeverInstalledInAnyForm() throws {
  let f = try ReturnFixture()
  try writeFile(f.destination + "/.git/HEAD", "ref: refs/heads/host\n")
  let manifest = try f.stage(
    [
      ".git/HEAD": "ref: refs/heads/guest\n", ".git/hooks/post-checkout": "#!/bin/sh\n",
      "sub/.git": "gitdir: /tmp/evil\n", ".GIT/config": "x", "ok.txt": "ok",
      ".g\u{200C}it/config": "y",
    ])
  #expect(manifest.applicable)
  #expect(manifest.changes.map(\.path) == ["ok.txt", "sub"])
  // A case-insensitive staging volume may already merge `.GIT` into `.git`.
  #expect(manifest.excludedCount >= 3)
  _ = try f.apply(manifest.id)
  #expect(readFile(f.destination + "/.git/HEAD") == "ref: refs/heads/host\n")
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/.git/hooks"))
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/sub/.git"))
}

@Test func linksIntoGitAdministrationAreRefused() throws {
  let f = try ReturnFixture()
  let manifest = try f.stage(["a": "a"], links: ["hook": ".git/hooks/pre-commit"])
  #expect(!manifest.applicable)
  #expect(manifest.issues.contains { $0.contains("git administration") })
}

@Test func standardGitfilesAreProtectedAndCustomTargetsRefused() throws {
  // A linked worktree whose git directory is outside the destination.
  let f = try ReturnFixture()
  try writeFile(f.destination + "/.git", "gitdir: \(f.outside)/repo/.git/worktrees/wt\n")
  let manifest = try f.stage(["a.txt": "a"])
  #expect(manifest.applicable)
  #expect(manifest.gitfiles.map(\.path) == [".git"])
  // A gitfile rewritten after review is drift.
  try writeFile(f.destination + "/.git", "gitdir: elsewhere\n")
  #expect(returnError { _ = try f.apply(manifest.id) }?.kind == .drift)
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/a.txt"))

  // A submodule's gitfile pointing beneath the protected .git is supported.
  let g = try ReturnFixture()
  try writeFile(g.destination + "/sub/.git", "gitdir: ../.git/modules/sub\n")
  #expect(try g.stage(["sub/x": "x"]).applicable)

  // A custom git directory inside the destination is not.
  let h = try ReturnFixture()
  try writeFile(h.destination + "/.git", "gitdir: admin\n")
  let custom = try h.stage(["a.txt": "a"])
  #expect(!custom.applicable)
  #expect(returnError { _ = try h.apply(custom.id) } != nil)
  #expect(!FileManager.default.fileExists(atPath: h.destination + "/a.txt"))
}

@Test func anExistingGitSymlinkMakesTheDestinationInapplicable() throws {
  let f = try ReturnFixture()
  try FileManager.default.createSymbolicLink(
    atPath: f.destination + "/.git", withDestinationPath: f.outside)
  let manifest = try f.stage(["a.txt": "a"])
  #expect(!manifest.applicable)
  #expect(manifest.issues.contains { $0.contains(".git symlink") })
}

@Test func aDestinationInsideGitAdministrationIsRefused() throws {
  let f = try ReturnFixture()
  try FileManager.default.createDirectory(
    atPath: f.destination + "/.git/x", withIntermediateDirectories: true)
  let error = try #require(throws: ReturnError.self) {
    try ReturnDestination.resolve(f.destination + "/.git/x", controlRoots: [])
  }
  #expect(error.kind == .unsupportedLayout)
}

// MARK: - R2: names and links against the final tree

@Test func spellingDifferencesFromHostEntriesAreRefused() throws {
  let f = try ReturnFixture()
  guard pathconf(f.destination, _PC_CASE_SENSITIVE) == 0 else { return }
  try writeFile(f.destination + "/README.md", "host")
  let manifest = try f.stage(["readme.md": "guest"])
  #expect(!manifest.applicable)
  #expect(manifest.issues.contains { $0.contains("differs only in case") })
}

@Test func aLinkWhoseFinalComponentIsALinkIsAChain() throws {
  let f = try ReturnFixture()
  try FileManager.default.createSymbolicLink(
    atPath: f.destination + "/hostlink", withDestinationPath: f.outside + "/sentinel")
  let manifest = try f.stage(["a": "a"], links: ["l": "hostlink", "m": "a"])
  #expect(!manifest.applicable)
  #expect(manifest.issues.contains { $0.hasPrefix("l:") && $0.contains("(hostlink)") })
  #expect(!manifest.issues.contains { $0.hasPrefix("m:") })
}

// MARK: - R3: hostile receiver input through the qualified tar

/// A tar archive with one hostile member, built with Python's tarfile.
private func hostileArchive(_ path: String, _ script: String) throws {
  let python = """
    import io, sys, tarfile
    t = tarfile.open(sys.argv[1], "w", format=tarfile.PAX_FORMAT)
    def f(name, data=b"x", **kw):
        info = tarfile.TarInfo(name); info.size = len(data)
        for k, v in kw.items(): setattr(info, k, v)
        t.addfile(info, io.BytesIO(data))
    def l(name, target, kind=tarfile.SYMTYPE):
        info = tarfile.TarInfo(name); info.type = kind; info.linkname = target; t.addfile(info)
    def d(name):
        info = tarfile.TarInfo(name); info.type = tarfile.DIRTYPE; info.mode = 0o755; t.addfile(info)
    \(script)
    t.close()
    """
  let output = try ProcessRunner().capture(
    .init(
      executable: "/usr/bin/python3", arguments: ["-I", "-c", python, path],
      environment: ["PATH": "/usr/bin:/bin"], deadline: .seconds(30)))
  guard output.termination.succeeded else {
    throw HostError("archive: \(String(decoding: output.stderr, as: UTF8.self))")
  }
}

@Test(arguments: [
  ("parent", #"f("../escape")"#),
  ("absolute", #"f("/tmp/iso-abs-escape-\#(UUID().uuidString)")"#),
  ("link-then-file", "l(\"l\", \"OUTSIDE\"); f(\"l/escape\")"),
  ("hardlink-out", "l(\"h\", \"OUTSIDE/sentinel\", tarfile.LNKTYPE)"),
  ("dir-link-swap", "d(\"d\"); l(\"d2\", \"OUTSIDE\"); f(\"d2/escape\")"),
  ("dup", #"f("a", b"one"); f("a", b"two")"#),
])
func hostileArchivesStayInsideTheReceiveTree(name: String, script: String) throws {
  guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return }
  let f = try ReturnFixture()
  let archive = f.root + "/hostile.tar"
  try hostileArchive(archive, script.replacingOccurrences(of: "OUTSIDE", with: f.outside))
  let guest = f.root + "/guest"
  try FileManager.default.createDirectory(atPath: guest, withIntermediateDirectories: true)
  // The fake guest "tar cf" emits the hostile archive instead.
  let bin = f.root + "/bin"
  try writeFile(bin + "/tar", "#!/bin/sh\nexec /bin/cat \(archive)\n")
  chmod(bin + "/tar", 0o755)
  let fakeSSH = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../fixtures/fake-ssh").standardized.path
  let transfer = WorkspaceTransfer(
    client: SSHClient(environment: ["PATH": "\(bin):/usr/bin:/bin"], tools: .searchPath),
    diagnostics: Diagnostics(verbosity: 0, sink: { _ in }))
  let attempt = try ReceiveAttempt(f.location)
  let target = SSHTarget(
    host: "127.0.0.1", port: 22, user: .default, keyPath: "/k", knownHosts: "/kh", alias: "g")
  _ = try? transfer.tarReceive(
    target, guest: GuestPath(guest), into: attempt,
    receivers: InboundReceivers(
      tar: "/usr/bin/bsdtar", rsync: "/usr/bin/rsync", ssh: fakeSSH + "/ssh",
      requireSystemOwnership: false))
  // Checked before inventory, and again after the writers are reaped.
  #expect(f.sentinelIntact, "\(name)")
  #expect(!FileManager.default.fileExists(atPath: f.root + "/escape"), "\(name)")
  let hold = try attempt.awaitQuiescence(timeout: .seconds(5))
  #expect(hold != nil)
  #expect(f.sentinelIntact, "\(name)")
  try attempt.checkLayout()
  // Whatever did land is validated like any stage: links out are issues.
  var builder = try StageBuilder(tree: attempt.tree, destination: f.destination, limits: .defaults)
  let manifest = try builder.build(id: attempt.id, instance: "dev")
  for change in manifest.changes {
    if case .symlink(let target) = change.new {
      #expect(StageBuilder.staysInside(link: change.path, target: target))
    }
  }
}

@Test func receiversAreQualifiedSystemTools() throws {
  try InboundReceivers.system.qualify(ProcessRunner())
  let impostor = InboundReceivers(
    tar: "/bin/cat", rsync: "/usr/bin/rsync", ssh: "/usr/bin/ssh", requireSystemOwnership: true)
  #expect(throws: HostError.self) { try impostor.qualify(ProcessRunner()) }
  let scratch = try scratchDirectory("tools")
  try writeFile(scratch + "/tar", "#!/bin/sh\n")
  chmod(scratch + "/tar", 0o755)
  let userOwned = InboundReceivers(
    tar: scratch + "/tar", rsync: "/usr/bin/rsync", ssh: "/usr/bin/ssh",
    requireSystemOwnership: true)
  #expect(throws: HostError.self) { try userOwned.qualify(ProcessRunner()) }
  #expect(
    InboundReceivers.system.environment(["PATH": "/evil", "HOME": "/h"])["PATH"]
      == "/usr/bin:/bin:/usr/sbin:/sbin")
}

// MARK: - R4: destination authority

@Test func destinationsOverlappingControlStateAreRefused() throws {
  let f = try ReturnFixture()
  let roots = WorkspaceTransfer.controlRoots(f.instance)
  for bad in [f.instance.directory, f.root + "/state", f.root, f.instance.directory + "/returns"] {
    try FileManager.default.createDirectory(atPath: bad, withIntermediateDirectories: true)
    let error = try #require(throws: ReturnError.self, "\(bad)") {
      try ReturnDestination.resolve(bad, controlRoots: roots)
    }
    #expect(error.kind == .overlap)
  }
  // A symlinked spelling of a control root is the same directory.
  let alias = f.root + "/alias"
  try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: f.root + "/state")
  #expect(throws: ReturnError.self) { try ReturnDestination.resolve(alias, controlRoots: roots) }
  _ = try ReturnDestination.resolve(f.destination, controlRoots: roots)
}

@Test func anAbsentDestinationIsCreatedOnlyByAnAuthorizedApply() throws {
  let f = try ReturnFixture(createDestination: false)
  let manifest = try f.stage(["a.txt": "a", ".envrc": "x"])
  guard case .create = manifest.binding else {
    Issue.record("expected a create binding")
    return
  }
  // Missing authorization: no root, no ancestors.
  #expect(returnError { _ = try f.apply(manifest.id) }?.kind == .missingSensitiveGrant)
  #expect(!FileManager.default.fileExists(atPath: f.destination))
  #expect(try f.apply(manifest.id, sensitive: [".envrc"]).sorted() == [".envrc", "a.txt"])
  #expect(readFile(f.destination + "/a.txt") == "a")

  // A destination that appears after review is drift, not overwritten.
  let g = try ReturnFixture(createDestination: false)
  let second = try g.stage(["a.txt": "a"])
  try FileManager.default.createDirectory(atPath: g.destination, withIntermediateDirectories: true)
  #expect(returnError { _ = try g.apply(second.id) }?.kind == .drift)
  #expect(!FileManager.default.fileExists(atPath: g.destination + "/a.txt"))

  // No implicit ancestors.
  #expect(throws: HostError.self) {
    try ReturnDestination.resolve(f.root + "/missing/parent/dest", controlRoots: [])
  }
}

@Test func aRenamedDestinationRootIsDrift() throws {
  let f = try ReturnFixture()
  let manifest = try f.stage(["a.txt": "a"])
  try FileManager.default.moveItem(atPath: f.destination, toPath: f.root + "/moved")
  try FileManager.default.createDirectory(atPath: f.destination, withIntermediateDirectories: true)
  #expect(returnError { _ = try f.apply(manifest.id) }?.kind == .drift)
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/a.txt"))
  #expect(!FileManager.default.fileExists(atPath: f.root + "/moved/a.txt"))
}

// MARK: - R5/R6: receive lifetime

@Test func aLingeringWriterKeepsTheIncomingTreeBusy() throws {
  let f = try ReturnFixture()
  let lock = try f.location.lock()
  defer { lock.release() }
  let attempt = try ReceiveAttempt(f.location)
  // A writer that inherited the lease and outlives the receive call.
  var request = ProcessRunner.Request(
    executable: "/bin/sleep", arguments: ["3"], environment: [:], deadline: .seconds(10))
  request.inheritedDescriptors = [attempt.writerDescriptor]
  let writer = try ProcessRunner().piped(request)
  defer { writer.terminate() }
  #expect(try attempt.awaitQuiescence(timeout: .milliseconds(300)) == nil)
  // Busy trees are never reclaimed, reused or deleted.
  #expect(throws: ReturnError.self) { try f.location.reclaimIncoming() }
  #expect(FileManager.default.fileExists(atPath: attempt.tree))
  #expect(throws: ReturnError.self) { try f.location.remove() }
  #expect(FileManager.default.fileExists(atPath: attempt.tree))
  writer.terminate()
  #expect(try attempt.awaitQuiescence(timeout: .seconds(5)) != nil)
  try f.location.reclaimIncoming()
  #expect(!FileManager.default.fileExists(atPath: attempt.directory))
}

@Test func aFailedReceiveKeepsThePreviouslySelectedStage() throws {
  let f = try ReturnFixture()
  let first = try f.stage(["a.txt": "a"])
  let lock = try f.location.lock()
  let attempt = try ReceiveAttempt(f.location)
  try writeFile(attempt.tree + "/partial", "p")
  attempt.abandon()
  lock.release()
  #expect(try f.location.loadSelected().manifest.id == first.id)
  #expect(try f.location.incomingAttempts().isEmpty)
}

@Test func writesOutsideTheReceiveTreeRejectTheAttempt() throws {
  let f = try ReturnFixture()
  let lock = try f.location.lock()
  defer { lock.release() }
  let attempt = try ReceiveAttempt(f.location)
  try writeFile(attempt.directory + "/manifest.json", "{}")
  #expect(throws: HostError.self) { try attempt.checkLayout() }
}

@Test func pipelineCancellationOutlivesAClosedStderr() throws {
  // The consumer closes its stderr, then keeps running; cancellation must
  // still end it instead of waiting forever after EOF.
  let producer = ProcessRunner.Request(
    executable: "/bin/sh", arguments: ["-c", "exec 2>&-; sleep 30"], environment: [:],
    deadline: .seconds(60))
  var consumer = ProcessRunner.Request(
    executable: "/bin/sh", arguments: ["-c", "exec 2>&-; sleep 30"], environment: [:],
    deadline: .seconds(60))
  let start = ContinuousClock.now
  consumer.isCancelled = { ContinuousClock.now - start > .milliseconds(300) }
  #expect(throws: ProcessRunner.Failure.cancelled) {
    _ = try ProcessRunner().pipeline(producer, consumer)
  }
  #expect(ContinuousClock.now - start < .seconds(10))
}

@Test func growthInspectionFailureStopsTheTransfer() throws {
  let guardian = StageGrowthGuard(tree: "/nonexistent/iso-tree", limits: .defaults)
  #expect(guardian.shouldCancel())
  #expect(guardian.breachDescription?.contains("Failed to inspect") == true)
}

// MARK: - R7/R8: preflight, consumption and partial outcomes

@Test func lateStageTamperIsCaughtBeforeTheFirstWrite() throws {
  let f = try ReturnFixture()
  let manifest = try f.stage(["a.txt": "a", "z.txt": "reviewed"])
  try writeFile(try f.location.loadSelected().stage.tree + "/z.txt", "swapped")
  #expect(returnError { _ = try f.apply(manifest.id) }?.kind == .drift)
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/a.txt"))
}

@Test func anAttemptConsumesItsStageEvenAfterAPartialFailure() throws {
  let f = try ReturnFixture()
  try writeFile(f.destination + "/ro/.keep", "")
  let manifest = try f.stage(["a.txt": "a", "ro/.keep": "", "ro/x.txt": "x"])
  chmod(f.destination + "/ro", 0o500)
  defer { chmod(f.destination + "/ro", 0o700) }
  let partial = try #require(throws: StageApplyError.self) { _ = try f.apply(manifest.id) }
  #expect(partial.applied == ["a.txt"] && partial.failed == "ro/x.txt")
  #expect(partial.effect == .unchanged && partial.stageID == manifest.id)
  // The stage is kept, but its approval is never replayed.
  #expect(f.location.exists)
  let consumed = returnError { _ = try f.apply(manifest.id) }
  #expect(consumed?.kind == .consumed)
  let progress = ApplyAttemptRecord.progress(f.location, stageID: manifest.id)
  #expect(progress.finished == [0] && progress.started == [0, 1] && progress.outcome == "partial")
  // The retry classifies the recorded effects instead of guessing.
  let text = consumed.map { "\($0)" } ?? ""
  #expect(text.contains("outcome partial; 1 of 2 change(s) finished"))
  #expect(text.contains("interrupted, check by hand: ro/x.txt"))
}

@Test func aFailedCreateReportsTheCreatedRoot() throws {
  let f = try ReturnFixture(createDestination: false)
  let manifest = try f.stage(["a.txt": "a", "b.txt": "b"])
  try writeFile(try f.location.loadSelected().stage.tree + "/b.txt", "swapped")
  let selected = try f.location.loadSelected()
  let applier = StageApplier(manifest: selected.manifest, tree: selected.stage.tree)
  let partial = try #require(throws: StageApplyError.self) {
    _ = try applier.apply(try applier.destination.open())
  }
  #expect(partial.createdRoot == f.destination)
  #expect(partial.applied == ["a.txt"])
  #expect(partial.description.contains("Created"))
  _ = manifest
}

// MARK: - R9/R10: authority

@Test func directModeAppliesAdditionsButHoldsReplacements() throws {
  let f = try ReturnFixture()
  try writeFile(f.destination + "/kept.txt", "host")
  let additions = try f.stage(["new.txt": "n"])
  #expect(try f.apply(additions.id, replace: false, direct: true) == ["new.txt"])

  let replacing = try f.stage(["kept.txt": "guest", "other.txt": "o"])
  let held = returnError { _ = try f.apply(replacing.id, replace: false, direct: true) }
  #expect(held?.kind == .missingOverwriteAuthority)
  #expect(held?.message.contains("--force") == true)
  #expect(readFile(f.destination + "/kept.txt") == "host")
  #expect(!FileManager.default.fileExists(atPath: f.destination + "/other.txt"))
  #expect(try f.location.loadSelected().manifest.id == replacing.id)
  // AUD-01: the hold is recorded with its stage and reason, no paths.
  let recorded = try BoundaryAudit.load(f.instance).last { $0["event"] as? String == "pull_held" }
  #expect(recorded?["stage_id"] as? String == replacing.id)
  #expect(recorded?["reason"] as? String == "missing_overwrite_authority")
}

@Test func sensitivePathsNeedExactNamedGrants() throws {
  let f = try ReturnFixture()
  let manifest = try f.stage(
    [
      ".envrc": "export A=1\n", "app/.husky/pre-commit": "#!/bin/sh\n",
      "x/.vscode/tasks.json": "{}", "plain.txt": "p",
    ], links: ["trap": ".envrc"])
  #expect(
    manifest.sensitivePaths == [
      ".envrc", "app/.husky", "app/.husky/pre-commit", "trap", "x/.vscode/tasks.json",
    ])
  for (operands, kind) in [
    ([] as [String], ReturnError.Kind.missingSensitiveGrant),
    ([".envrc", "app/.husky", "app/.husky/pre-commit", "trap"], .missingSensitiveGrant),
  ] {
    #expect(returnError { _ = try f.apply(manifest.id, sensitive: operands) }?.kind == kind)
  }
  // Each bad operand travels with every real grant, so only the operand
  // check itself can refuse it.
  for bad in [["plain.txt"], ["/abs"], ["../x"], [".envrc", ".envrc"], ["app/.husky/*"], ["app"]] {
    let error = #expect(throws: HostError.self, "\(bad)") {
      _ = try f.apply(manifest.id, sensitive: bad + manifest.sensitivePaths)
    }
    #expect(error?.message.contains("--approve-sensitive") == true, "\(bad)")
  }
  #expect((try? FileManager.default.contentsOfDirectory(atPath: f.destination)) == [])
  // --force-style replace authority never grants a sensitive path.
  #expect(
    returnError { _ = try f.apply(manifest.id, replace: true) }?.kind == .missingSensitiveGrant)
  let applied = try f.apply(manifest.id, sensitive: manifest.sensitivePaths)
  #expect(applied.contains(".envrc") && applied.contains("plain.txt"))
}

@Test func manifestValidationRejectsTamperedPlans() throws {
  let f = try ReturnFixture()
  let manifest = try f.stage(["a.txt": "a", ".envrc": "x"])
  let path = try f.location.loadSelected().stage.manifestPath
  let original = try String(contentsOfFile: path, encoding: .utf8)
  for (from, to) in [
    (#""sensitive" : "direnv runs .envrc on the host""#, #""sensitive" : null"#),
    (#""path" : "a.txt""#, #""path" : ".git\/config""#),
    (#""path" : "a.txt""#, #""path" : "..\/a.txt""#),
    (#""id" : "\#(manifest.id)""#, #""id" : "..\/..\/x""#),
  ] {
    try original.replacingOccurrences(of: from, with: to).write(
      toFile: path, atomically: true, encoding: .utf8)
    #expect(throws: HostError.self, "\(to)") { try f.location.loadSelected() }
  }
}

@Test func discardNeverDeletesALiveReceive() throws {
  let f = try ReturnFixture()
  try f.stage(["a.txt": "a"])
  let lock = try f.location.lock()
  let attempt = try ReceiveAttempt(f.location)
  lock.release()
  var request = ProcessRunner.Request(
    executable: "/bin/sleep", arguments: ["3"], environment: [:], deadline: .seconds(10))
  request.inheritedDescriptors = [attempt.writerDescriptor]
  let writer = try ProcessRunner().piped(request)
  defer { writer.terminate() }
  _ = try attempt.awaitQuiescence(timeout: .milliseconds(10))
  #expect(throws: ReturnError.self) { _ = try f.transfer.discardStage(f.instance) }
  #expect(FileManager.default.fileExists(atPath: attempt.tree))
}

/// A second `terminate` (an explicit one plus a `defer`) must not close the
/// descriptor numbers again: by then another thread may own them.
@Test func terminatingAPipedChildTwiceClosesNothingElse() throws {
  let child = try ProcessRunner().piped(
    .init(executable: "/bin/sleep", arguments: ["5"], environment: [:], deadline: .seconds(10)))
  let numbers = [child.input, child.output]
  child.terminate()
  // Take the freed numbers, as a concurrent test would (unless a parallel
  // test took them first, which leaves nothing to check).
  var reused: [Int32] = []
  while reused.count < 64, !Set(numbers).isSubset(of: Set(reused)) {
    var pair: [Int32] = [0, 0]
    guard pipe(&pair) == 0 else { break }
    reused += pair
  }
  defer { for fd in reused { close(fd) } }
  guard Set(numbers).isSubset(of: Set(reused)) else { return }
  child.terminate()
  for fd in reused {
    #expect(fcntl(fd, F_GETFD) >= 0, "fd \(fd) was closed by the second terminate")
  }
}
