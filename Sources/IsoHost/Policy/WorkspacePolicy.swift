import Foundation
import IsoConfiguration
import IsoCore
import IsoPolicy

/// The policy identity a stage was built under: authoritative only after
/// the manifest is bounded-parsed from host-owned state and compared with
/// the current binding. Never accepted from the guest.
package struct StagePolicyBinding: Codable, Equatable, Sendable {
  package let instanceID: String
  package let bootID: String
  package let policyEpoch: String
  package let policyDigest: String
  package let policyMode: String
  /// The canonical host path of the instance's recorded attached workspace.
  package let workspaceIdentity: String
  /// `device:inode` of the destination directory when the stage was built.
  package let destinationIdentity: String
}

/// Trusted host-terminal confirmation of one rendered stage. Returns true
/// only on an explicit answer from the person at the host terminal.
package typealias StageConfirmation = (StageManifest) throws -> Bool

/// Host-side enforcement for `workspace.pull.apply`
/// (docs/design/iso-policy.md §8).
package enum WorkspacePolicy {
  /// The policy governing applies for this instance, if any; corrupt state
  /// throws, and a boot without a binding refuses requested enforcement.
  static func governing(_ instance: Instance, configured: CompiledPolicy?) throws
    -> (binding: PolicyBinding, policy: CompiledPolicy)?
  {
    governing(
      try ActivePolicy.requireBoundIfRequested(
        instance, configured: configured, .workspacePullApply))
  }

  /// The governing binding and policy within one already-loaded state.
  static func governing(_ active: ActivePolicy) -> (binding: PolicyBinding, policy: CompiledPolicy)?
  {
    guard case .active(let binding, let policy) = active,
      policy.governedActions.contains(.workspacePullApply)
    else { return nil }
    return (binding, policy)
  }

  /// The canonical attached workspace, from host state only.
  static func attachedWorkspace(_ instance: Instance) throws -> String? {
    guard let path = try WorkspaceState.load(instance)?.source.hostPath else { return nil }
    return canonicalPath(path) ?? (path as NSString).standardizingPath
  }

  /// `device:inode` of an open directory.
  static func identity(fd: Int32) -> String? {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    return "\(info.st_dev):\(info.st_ino)"
  }

  static func identity(path: String) -> String? {
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    return identity(fd: fd)
  }

  /// Binds a new stage to the current boot. Under enforcement only the
  /// recorded attached workspace, which must already exist, is supported.
  static func bindStage(
    _ instance: Instance, destination: String, explicitDirectory: Bool,
    configured: CompiledPolicy?, diagnostics: Diagnostics
  ) throws -> StagePolicyBinding? {
    guard let (binding, policy) = try governing(instance, configured: configured) else {
      return nil
    }
    let attached = try attachedWorkspace(instance)
    let enforcing = policy.mode == .enforce
    guard let attached, attached == destination else {
      guard !enforcing else {
        throw HostError(
          "unsupported_path: under an enforcing workspace.pull.apply policy only the attached workspace (workspace:attached) can be staged\(explicitDirectory ? "; --dir names a different directory" : "")"
        )
      }
      diagnostics.warn("policy shadow_unavailable:unsupported_path (not the attached workspace)")
      return nil
    }
    guard let destinationIdentity = identity(path: destination) else {
      guard !enforcing else {
        throw HostError(
          "unsupported_path: the attached workspace \(neutralizeControls(destination)) must exist before a governed stage is built"
        )
      }
      return nil
    }
    return StagePolicyBinding(
      instanceID: binding.instanceID, bootID: binding.bootID, policyEpoch: binding.policyEpoch,
      policyDigest: policy.digest, policyMode: policy.mode.rawValue,
      workspaceIdentity: attached, destinationIdentity: destinationIdentity)
  }

  /// Version 1 of the mutation-plan digest: the stage ID, instance and
  /// policy binding, destination, and every path, operation, old-object
  /// expectation, content hash, mode and link target, length-prefixed so
  /// no two plans encode alike.
  package static func manifestDigest(_ manifest: StageManifest) -> String {
    var lines = ["iso-stage-plan-v1"]
    func field(_ text: String) -> String { "\(text.utf8.count):\(text)" }
    lines.append("id " + field(manifest.id))
    lines.append("instance " + field(manifest.instance))
    lines.append("destination " + field(manifest.destination))
    lines.append("exclude_git \(manifest.excludeGit ? 1 : 0)")
    if let policy = manifest.policy {
      lines.append(
        "binding "
          + [
            policy.instanceID, policy.bootID, policy.policyEpoch, policy.policyDigest,
            policy.policyMode, policy.workspaceIdentity, policy.destinationIdentity,
          ].map(field).joined(separator: " "))
    } else {
      lines.append("binding -")
    }
    func object(_ value: StageObject) -> String {
      switch value {
      case .file(let size, let sha, let mode): "file \(size) \(field(sha)) \(mode)"
      case .directory: "directory"
      case .symlink(let target): "symlink " + field(target)
      }
    }
    func old(_ value: DestinationObject) -> String {
      switch value {
      case .absent: "absent"
      case .file(let size, let sha, let mode): "file \(size) \(field(sha)) \(mode)"
      case .directory: "directory"
      case .symlink(let target): "symlink " + field(target)
      case .other: "other"
      }
    }
    for change in manifest.changes {
      lines.append(
        "change \(field(change.path)) \(change.operation.rawValue) new=\(object(change.new)) old=\(old(change.old))"
      )
    }
    for issue in manifest.issues { lines.append("issue " + field(issue)) }
    return PolicyCanonical.digest(Array(lines.joined(separator: "\n").utf8))
  }

  /// A direct pull bypasses review; it is refused under an enforcing
  /// workspace policy and reported as unevaluated in shadow mode.
  static func checkDirectPull(
    _ instance: Instance, configured: CompiledPolicy?, diagnostics: Diagnostics
  ) throws {
    guard let (_, policy) = try governing(instance, configured: configured) else { return }
    let decisionID = UUID().uuidString.lowercased()
    if policy.mode == .shadow {
      BoundaryAudit.record(
        instance,
        .policyDecision(
          action: .workspacePullApply, outcome: .shadowUnavailable(.notStaged),
          decisionID: decisionID, digest: policy.digest, shadow: true),
        diagnostics: diagnostics)
      diagnostics.warn("policy shadow_unavailable:not_staged (direct pull)")
      return
    }
    BoundaryAudit.record(
      instance,
      .policyDecision(
        action: .workspacePullApply, outcome: .decided(.deny, .unsupportedPath),
        decisionID: decisionID, digest: policy.digest, shadow: false), diagnostics: diagnostics)
    throw HostError(
      "unsupported_path: a direct pull would write the workspace without review under the enforcing workspace.pull.apply policy; use `iso pull \(instance.name) --review`, then `--apply`"
    )
  }

  /// Serializes every iso return into one destination, keyed by the
  /// verified directory identity in host-owned lock storage. Acquired after
  /// the policy lock and before the stage lock.
  static func workspaceLock(_ instance: Instance, identity: String) throws(HostError) -> FileLock {
    let name = identity.replacingOccurrences(of: ":", with: "-")
    let directory = stateRoot(of: instance) + "/workspace-locks"
    try StateStore.ensurePrivateDirectory(directory)
    return try FileLock(path: directory + "/\(name).lock")
  }

  /// The backend state root holding `owner.json`, above both local instances
  /// (`instances/NAME`) and remote-host shadows (`host-workspaces/HOST/ID`),
  /// so every return into one destination shares one lock. Without that
  /// marker (a scratch layout), the directory above `instances/`.
  static func stateRoot(of instance: Instance) -> String {
    var directory = instance.directory as NSString
    for _ in 0..<4 {
      directory = directory.deletingLastPathComponent as NSString
      if FileManager.default.fileExists(atPath: (directory as String) + "/owner.json") {
        return directory as String
      }
    }
    return ((instance.directory as NSString).deletingLastPathComponent as NSString)
      .deletingLastPathComponent
  }

}

/// Raised for a refused governed apply; carries the decision's reason.
package struct PolicyDenied: Error, CustomStringConvertible {
  package let reason: PolicyReason
  package let detail: String
  package var description: String { "\(reason.rawValue): \(detail)" }
}

extension WorkspaceTransfer {
  /// An enforcing `workspace.pull.apply` (docs/design/iso-policy.md §8.2):
  /// verify the stage against the current boot, render and confirm it at
  /// the host terminal without holding a lock, then take the policy,
  /// workspace and stage locks in that order, re-verify everything, consume
  /// the single-use receipt, and apply through the verified directory
  /// descriptor. A denial writes nothing.
  func applyGovernedStage(
    _ instance: Instance, stageID: String?, force: Bool, binding: PolicyBinding,
    policy: CompiledPolicy, confirm: StageConfirmation?
  ) throws -> (manifest: StageManifest, applied: [String]) {
    let location = StageLocation(instance)
    let name = instance.name.rawValue
    let clock = SystemMonotonicClock()
    func deny(_ reason: PolicyReason, _ detail: String) -> PolicyDenied {
      BoundaryAudit.record(
        instance,
        .policyDecision(
          action: .workspacePullApply, outcome: .decided(.deny, reason),
          decisionID: UUID().uuidString.lowercased(), digest: policy.digest, shadow: false),
        diagnostics: diagnostics)
      return PolicyDenied(reason: reason, detail: detail)
    }
    func approval(_ manifest: StageManifest, destination: String, workspace: String)
      -> ApprovalBinding
    {
      ApprovalBinding(
        instanceID: binding.instanceID, bootID: binding.bootID, policyEpoch: binding.policyEpoch,
        policyDigest: policy.digest, workspaceIdentity: workspace,
        destinationIdentity: destination, stageID: manifest.id,
        manifestDigest: WorkspacePolicy.manifestDigest(manifest))
    }

    // 1. Prepare and confirm. No lifecycle, workspace or stage lock is held
    // while waiting for a person.
    let manifest = try location.locked { () throws(HostError) in try location.loadManifest() }
    if let stageID, stageID != manifest.id {
      throw HostError(
        "The current stage is \(manifest.id), not \(stageID); review it with `iso diff` before applying"
      )
    }
    guard let staged = manifest.policy, staged.instanceID == binding.instanceID,
      staged.bootID == binding.bootID, staged.policyEpoch == binding.policyEpoch,
      staged.policyDigest == policy.digest
    else {
      throw deny(
        .policyEpochMismatch,
        "stage \(manifest.id) was not built under this boot's policy; re-stage with `iso pull \(name) --review`"
      )
    }
    guard let attached = try WorkspacePolicy.attachedWorkspace(instance),
      attached == staged.workspaceIdentity, manifest.destination == attached,
      WorkspacePolicy.identity(path: manifest.destination) == staged.destinationIdentity
    else {
      throw deny(
        .approvalMismatch,
        "the attached workspace or its directory changed since stage \(manifest.id) was built; re-stage"
      )
    }
    let applier = StageApplier(manifest: manifest, tree: location.tree)
    try applier.preflight()
    try applier.verifyStage()
    let evaluation = ApprovalCheck.evaluate(policy, instance: name)
    if case .denied(let reason) = evaluation.outcome {
      throw deny(reason, "the policy does not permit applying to workspace:attached in '\(name)'")
    }
    let needsApproval = evaluation.requiresApproval
    var receipt: ApprovalReceipt? = nil
    if needsApproval {
      guard let confirm else {
        throw deny(
          .approvalRequired,
          "confirm the reviewed stage at an interactive host terminal; --force, piped input and --output json cannot approve it"
        )
      }
      guard try confirm(manifest) else {
        _ = deny(.approvalRequired, "declined at the terminal")
        throw HostError("Apply of stage \(manifest.id) declined; nothing was written")
      }
      guard let now = clock.nanoseconds() else {
        throw deny(.internalError, "the host monotonic clock is unavailable")
      }
      let issued = ApprovalReceipt(
        approvalID: UUID().uuidString.lowercased(),
        binding: approval(manifest, destination: staged.destinationIdentity, workspace: attached),
        issuedAt: now)
      receipt = issued
      BoundaryAudit.record(
        instance, .approvalIssued(approvalID: issued.approvalID, stageID: manifest.id),
        diagnostics: diagnostics)
    }

    // 2. Locks in order, then re-verify under them.
    let policyLock = try PolicyBinding.lock(instance)
    defer { policyLock.release() }
    guard case .active(let current, let currentPolicy) = try ActivePolicy.load(instance),
      current.policyEpoch == binding.policyEpoch, currentPolicy.digest == policy.digest
    else {
      throw deny(
        .policyEpochMismatch, "'\(name)' started a new boot since review; re-stage and review again"
      )
    }
    let destination = open(manifest.destination, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard destination >= 0 else { throw HostError.posix("Failed to open", manifest.destination) }
    defer { close(destination) }
    guard let identity = WorkspacePolicy.identity(fd: destination),
      identity == staged.destinationIdentity
    else {
      throw deny(.approvalMismatch, "the destination directory was replaced since review; re-stage")
    }
    let workspaceLock = try WorkspacePolicy.workspaceLock(instance, identity: identity)
    defer { workspaceLock.release() }
    let stageLock = try location.lock()
    defer { stageLock.release() }
    let reread = try location.loadManifest()
    guard WorkspacePolicy.manifestDigest(reread) == WorkspacePolicy.manifestDigest(manifest) else {
      throw deny(.approvalMismatch, "the stage changed since review; review it again")
    }
    if !force && FileManager.default.fileExists(atPath: manifest.destination + "/.git") {
      try checkLocalClean(manifest.destination)
    }
    try applier.preflight()
    try applier.verifyStage()

    // 3. Authorize and consume immediately before the first mutation.
    let workspace = try WorkspacePolicy.attachedWorkspace(instance) ?? ""
    let decision = ApprovalCheck.authorizeAndConsume(
      &receipt, expected: approval(reread, destination: identity, workspace: workspace),
      policy: currentPolicy, instance: name, now: clock.nanoseconds(),
      decisionID: UUID().uuidString.lowercased())
    if let receipt {
      BoundaryAudit.record(
        instance,
        .approvalConsumed(approvalID: receipt.approvalID, reason: decision.reason),
        diagnostics: diagnostics)
    }
    BoundaryAudit.record(
      instance,
      .policyDecision(
        action: .workspacePullApply, outcome: .decided(decision.verdict, decision.reason),
        decisionID: decision.decisionID, digest: decision.policyDigest, shadow: false),
      diagnostics: diagnostics)
    guard decision.allows else {
      throw PolicyDenied(
        reason: decision.reason, detail: "stage \(manifest.id) was not applied; review it again")
    }

    // 4. Apply through the verified descriptor. A partial failure stays
    // visible and the receipt stays consumed.
    let applied: [String]
    do {
      applied = try applier.apply(destination: destination)
    } catch let partial as StageApplyError {
      BoundaryAudit.record(
        instance, .pullApplyPartial(applied: partial.applied.count), diagnostics: diagnostics)
      throw partial
    }
    BoundaryAudit.record(instance, .pullApply(applied: applied.count), diagnostics: diagnostics)
    try location.remove()
    return (manifest, applied)
  }
}
