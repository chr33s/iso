import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy
import Synchronization
import Testing

@testable import IsoHost

/// An instance with an attached workspace, a booted policy, and a stage of
/// one new file, all in scratch directories.
private struct GovernedFixture {
  let instance: Instance
  let destination: String
  let policy: CompiledPolicy
  let sink = LogSink()
  var location: StageLocation { StageLocation(instance) }
  var transfer: WorkspaceTransfer {
    WorkspaceTransfer(client: SSHClient(environment: [:]), diagnostics: sink.diagnostics)
  }

  init(policy: CompiledPolicy? = nil) throws {
    instance = try testInstance(try scratchDirectory("wsp") + "/instances/dev")
    destination = try scratchDirectory("dest")
    self.policy = try policy ?? compiledPolicy()
    try WorkspaceState(
      guestPath: GuestPath("/workspace"), source: .workspace(hostPath: destination)
    )
    .save(instance)
    try PolicyBoot.begin(instance, configured: self.policy, diagnostics: sink.diagnostics)
  }

  @discardableResult
  func stage(_ files: [String: String] = ["new.txt": "hello\n"], id: String = "abcd1234") throws
    -> StageManifest
  {
    try location.prepare()
    for (name, text) in files {
      try writeFile(location.tree + "/" + name, text)
    }
    let binding = try WorkspacePolicy.bindStage(
      instance, destination: destination, explicitDirectory: false, configured: policy,
      diagnostics: sink.diagnostics)
    var builder = StageBuilder(tree: location.tree, destination: destination, limits: .defaults)
    let manifest = try builder.build(
      id: id, instance: instance.name.rawValue, excludeGit: false, policy: binding)
    try location.saveManifest(manifest)
    return manifest
  }

  func apply(force: Bool = true, confirm: StageConfirmation?) throws -> [String] {
    try transfer.applyStage(
      instance, stageID: nil, force: force, configuredPolicy: policy, confirm: confirm
    ).applied
  }

  var destinationEntries: [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: destination)) ?? []
  }

  func events(_ kind: String) throws -> [[String: Any]] {
    try BoundaryAudit.load(instance).filter { $0["event"] as? String == kind }
  }
}

private func denial(_ body: () throws -> Void) -> PolicyReason? {
  do {
    try body()
    return nil
  } catch let error as PolicyDenied {
    return error.reason
  } catch {
    Issue.record("unexpected \(error)")
    return nil
  }
}

@Test func confirmedExactStageAppliesOnceThroughTheVerifiedDirectory() throws {
  let f = try GovernedFixture()
  let manifest = try f.stage()
  #expect(manifest.policy?.destinationIdentity == WorkspacePolicy.identity(path: f.destination))
  let prompts = Mutex(0)
  let applied = try f.apply { shown in
    prompts.withLock { $0 += 1 }
    #expect(shown.id == manifest.id)
    return true
  }
  #expect(applied == ["new.txt"])
  #expect(prompts.withLock { $0 } == 1)
  #expect(readFile(f.destination + "/new.txt") == "hello\n")
  #expect(!f.location.exists)
  #expect(try f.events("approval_issued").count == 1)
  #expect(try f.events("approval_consumed").first?["reason"] as? String == "allowed")
  #expect(try f.events("policy_decision").last?["verdict"] as? String == "allow")
}

@Test func noTerminalMeansApprovalRequiredAndZeroWrites() throws {
  // --force, piped input and machine output all arrive here as no confirmation.
  let f = try GovernedFixture()
  try f.stage()
  #expect(denial { _ = try f.apply(force: true, confirm: nil) } == .approvalRequired)
  #expect(f.destinationEntries.isEmpty)
  #expect(f.location.exists)
}

@Test func declinedConfirmationWritesNothing() throws {
  let f = try GovernedFixture()
  try f.stage()
  #expect(throws: HostError.self) { _ = try f.apply { _ in false } }
  #expect(f.destinationEntries.isEmpty)
}

@Test func aNewBootSupersedesTheStage() throws {
  let f = try GovernedFixture()
  try f.stage()
  try PolicyBoot.begin(f.instance, configured: f.policy, diagnostics: f.sink.diagnostics)
  #expect(denial { _ = try f.apply { _ in true } } == .policyEpochMismatch)
  #expect(f.destinationEntries.isEmpty)
}

@Test func stagedContentChangedDuringReviewIsRefused() throws {
  let f = try GovernedFixture()
  try f.stage()
  #expect(throws: HostError.self) {
    _ = try f.apply { _ in
      try writeFile(f.location.tree + "/new.txt", "swapped\n")
      return true
    }
  }
  #expect(f.destinationEntries.isEmpty)
}

@Test func restagingDuringReviewInvalidatesTheApproval() throws {
  let f = try GovernedFixture()
  try f.stage()
  #expect(
    denial {
      _ = try f.apply { _ in
        try f.stage(id: "ffff0000")
        return true
      }
    } == .approvalMismatch)
  #expect(f.destinationEntries.isEmpty)
}

@Test func replacedDestinationRootIsRefused() throws {
  let f = try GovernedFixture()
  try f.stage()
  let moved = f.destination + ".moved"
  #expect(
    denial {
      _ = try f.apply { _ in
        try FileManager.default.moveItem(atPath: f.destination, toPath: moved)
        try FileManager.default.createDirectory(
          atPath: f.destination, withIntermediateDirectories: false)
        return true
      }
    } == .approvalMismatch)
  #expect(f.destinationEntries.isEmpty)
  #expect(((try? FileManager.default.contentsOfDirectory(atPath: moved)) ?? []).isEmpty)
}

@Test func forbiddenApplyIsRefusedBeforePrompting() throws {
  let policy = try compiledPolicy(
    rules:
      #"{"id":"apply","effect":"permit","action":"workspace.pull.apply","resources":["workspace:attached"]},{"id":"never","effect":"forbid","action":"workspace.pull.apply","resources":["workspace:attached"]}"#
  )
  let f = try GovernedFixture(policy: policy)
  try f.stage()
  let prompted = Mutex(false)
  #expect(
    denial {
      _ = try f.apply { _ in
        prompted.withLock { $0 = true }
        return true
      }
    } == .explicitForbid)
  #expect(!prompted.withLock { $0 })
}

@Test func withoutAnApprovalGuardNoPromptIsNeeded() throws {
  let f = try GovernedFixture(policy: try compiledPolicy(guards: ""))
  try f.stage()
  #expect(try f.apply(confirm: nil) == ["new.txt"])
}

@Test func onlyTheAttachedWorkspaceCanBeStaged() throws {
  let f = try GovernedFixture()
  let other = try scratchDirectory("other")
  #expect(throws: HostError.self) {
    try WorkspacePolicy.bindStage(
      f.instance, destination: other, explicitDirectory: true, configured: f.policy,
      diagnostics: f.sink.diagnostics)
  }
  try FileManager.default.removeItem(atPath: f.destination)
  #expect(throws: HostError.self) {
    try WorkspacePolicy.bindStage(
      f.instance, destination: f.destination, explicitDirectory: false, configured: f.policy,
      diagnostics: f.sink.diagnostics)
  }
}

@Test func directPullIsRefusedUnderEnforcementAndUnevaluatedInShadow() throws {
  let f = try GovernedFixture()
  #expect(throws: HostError.self) {
    try WorkspacePolicy.checkDirectPull(
      f.instance, configured: f.policy, diagnostics: f.sink.diagnostics)
  }
  let shadow = try GovernedFixture(policy: try compiledPolicy(mode: "shadow"))
  try WorkspacePolicy.checkDirectPull(
    shadow.instance, configured: shadow.policy, diagnostics: shadow.sink.diagnostics)
  #expect(try shadow.events("policy_decision").last?["reason"] as? String == "not_staged")
}

@Test func shadowApplyReportsWithoutPromptingOrBlocking() throws {
  let f = try GovernedFixture(policy: try compiledPolicy(mode: "shadow"))
  try f.stage()
  #expect(try f.apply(confirm: nil) == ["new.txt"])
  let decision = try #require(try f.events("policy_decision").last)
  #expect(decision["shadow"] as? Bool == true)
  #expect(decision["reason"] as? String == "approval_required")
  #expect(try f.events("approval_issued").isEmpty)
}

@Test func unboundBootRefusesRequestedEnforcementButKeepsLegacyApply() throws {
  let instance = try testInstance(try scratchDirectory("legacy") + "/instances/dev")
  let destination = try scratchDirectory("legacydest")
  let sink = LogSink()
  let location = StageLocation(instance)
  try location.prepare()
  try writeFile(location.tree + "/a.txt", "a")
  var builder = StageBuilder(tree: location.tree, destination: destination, limits: .defaults)
  try location.saveManifest(
    try builder.build(id: "abcd1234", instance: "dev", excludeGit: false))
  let transfer = WorkspaceTransfer(
    client: SSHClient(environment: [:]), diagnostics: sink.diagnostics)
  #expect(throws: HostError.self) {
    try transfer.applyStage(
      instance, stageID: nil, force: true, configuredPolicy: try compiledPolicy())
  }
  #expect(
    try transfer.applyStage(instance, stageID: nil, force: true, configuredPolicy: nil).applied
      == ["a.txt"])
}

@Test func manifestDigestCoversTheWholeMutationPlan() throws {
  let f = try GovernedFixture()
  let manifest = try f.stage(["a.txt": "a", "b.txt": "b"])
  let digest = WorkspacePolicy.manifestDigest(manifest)
  #expect(digest.hasPrefix("sha256:"))
  var variants: [StageManifest] = []
  var other = manifest
  other.policy = nil
  variants.append(other)
  variants.append(
    StageManifest(
      version: manifest.version, id: "00000000", instance: manifest.instance,
      destination: manifest.destination, createdAt: manifest.createdAt,
      excludeGit: manifest.excludeGit, stagedEntries: manifest.stagedEntries,
      stagedBytes: manifest.stagedBytes, changes: manifest.changes, issues: manifest.issues,
      policy: manifest.policy))
  let changed = manifest.changes.map { change in
    StageChange(
      path: change.path, operation: change.operation,
      new: .file(size: 1, sha256: String(repeating: "0", count: 64), mode: 0o755),
      old: change.old)
  }
  variants.append(
    StageManifest(
      version: manifest.version, id: manifest.id, instance: manifest.instance,
      destination: manifest.destination, createdAt: manifest.createdAt,
      excludeGit: manifest.excludeGit, stagedEntries: manifest.stagedEntries,
      stagedBytes: manifest.stagedBytes, changes: changed, issues: manifest.issues,
      policy: manifest.policy))
  for variant in variants { #expect(WorkspacePolicy.manifestDigest(variant) != digest) }
  // Creation time is not part of the plan.
  #expect(
    WorkspacePolicy.manifestDigest(
      StageManifest(
        version: manifest.version, id: manifest.id, instance: manifest.instance,
        destination: manifest.destination, createdAt: "later", excludeGit: manifest.excludeGit,
        stagedEntries: manifest.stagedEntries, stagedBytes: manifest.stagedBytes,
        changes: manifest.changes, issues: manifest.issues, policy: manifest.policy)) == digest)
}

@Test func workspaceLocksStayOutOfTheInstancesDirectory() throws {
  let f = try GovernedFixture()
  try f.stage()
  _ = try f.apply { _ in true }
  let instances = (f.instance.directory as NSString).deletingLastPathComponent
  #expect(try FileManager.default.contentsOfDirectory(atPath: instances) == ["dev"])
  let root = (instances as NSString).deletingLastPathComponent
  #expect(FileManager.default.fileExists(atPath: root + "/workspace-locks"))
}

@Test func approvalReviewMarksEveryOmittedDiff() throws {
  let f = try GovernedFixture()
  let manifest = try f.stage(["text.txt": "visible\n", "binary.bin": "a\u{0}b"])
  let review = StageReview(manifest: manifest, location: f.location)
  let plain = review.textDiffs()
  #expect(!plain.contains { $0.contains("diff omitted") })
  let marked = review.textDiffs(markOmitted: true)
  #expect(marked.contains { $0.contains("diff omitted for binary.bin") })
  #expect(marked.contains("+++ b/text.txt"))
}

@Test func localAndRemoteReturnsShareTheStateRootsLockDirectory() throws {
  let root = try scratchDirectory("lockroot")
  try writeFile(root + "/owner.json", "{}")
  let local = try testInstance(root + "/instances/dev")
  let remote = try testInstance(root + "/host-workspaces/host-1/instance-1")
  #expect(WorkspacePolicy.stateRoot(of: local) == root)
  #expect(WorkspacePolicy.stateRoot(of: remote) == root)
  let lock = try WorkspacePolicy.workspaceLock(remote, identity: "1:2")
  lock.release()
  #expect(FileManager.default.fileExists(atPath: root + "/workspace-locks/1-2.lock"))
  var info = stat()
  #expect(stat(root + "/workspace-locks", &info) == 0 && info.st_mode & 0o077 == 0)
}

@Test func shadowReportsAStaleStageAsEnforcementWould() throws {
  let f = try GovernedFixture(policy: try compiledPolicy(mode: "shadow", guards: ""))
  try f.stage()
  try PolicyBoot.begin(f.instance, configured: f.policy, diagnostics: f.sink.diagnostics)
  #expect(try f.apply(confirm: nil) == ["new.txt"])
  let decision = try #require(try f.events("policy_decision").last)
  #expect(decision["reason"] as? String == "policy_epoch_mismatch")
  #expect(decision["verdict"] as? String == "deny")
}
