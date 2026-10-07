import Foundation
import IsoMacProtocol
import Virtualization

package struct MacInspectOutput: Encodable, Sendable {
  package var record: MacSandboxRecord
  package var status: SandboxStatus
  package var live: MacLiveState?
  package var effective: MacEffectiveConfig?
  package var runtime: MacStatus?
  package var sshHostKey: String?
}

/// macOS sandbox lifecycle. Mutations run under the sandbox's mutation guard
/// and require it to be stopped, as for Linux sandboxes.
package enum MacSandboxes {
  static func mutating<T>(_ paths: MacSandboxPaths, _ body: () async throws -> T) async throws -> T
  {
    let guarded = try await FileLock.acquire(
      paths.mutationLock, .exclusive, polling: .milliseconds(50))
    defer { withExtendedLifetime(guarded) {} }
    return try await body()
  }

  static func ownerHoldsLock(_ paths: MacSandboxPaths) -> Bool {
    let fd = open(paths.lock.path, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { return errno != ENOENT }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      flock(fd, LOCK_UN)
      return false
    }
    return true
  }

  package static func status(_ paths: MacSandboxPaths) -> SandboxStatus {
    guard paths.loadLive() != nil else { return ownerHoldsLock(paths) ? .booting : .stopped }
    guard ownerHoldsLock(paths) else { return .crashed }
    return (try? call(paths, .init(op: .ping), timeout: 5))?.ok == true ? .running : .booting
  }

  static func call(_ paths: MacSandboxPaths, _ req: MacControlRequest, timeout: TimeInterval? = 30)
    throws -> MacControlResponse
  {
    try ControlSocket.callJSON(paths.control, req, as: MacControlResponse.self, timeout: timeout)
  }

  /// Sandbox identifiers are one namespace across Linux and macOS guests.
  static func requireFreeID(_ root: SandboxRoot, _ id: SandboxID) throws {
    for dir in [root.sandbox(id).dir, root.macSandbox(id).dir]
    where FileManager.default.fileExists(atPath: dir.path) {
      throw SandboxError("\(id) already exists")
    }
  }

  // MARK: create (Gate L)

  package static func create(
    root: SandboxRoot, id: SandboxID, owner: String, template: SandboxID, cpus: Int,
    memoryBytes: UInt64, network: NetworkMode, authorizedKey: String
  ) async throws -> MacSandboxRecord {
    try root.createMacDirectories()
    guard SSHPublicKey.isEd25519(authorizedKey) else {
      throw SandboxError("--authorized-key must be one ssh-ed25519 public key")
    }
    let t = root.macTemplate(template)
    let meta = try t.load()
    guard cpus >= meta.minimumCPUs, memoryBytes >= meta.minimumMemoryBytes else {
      throw SandboxError(
        "template \(template) needs at least \(meta.minimumCPUs) CPUs and \(meta.minimumMemoryBytes >> 20) MiB"
      )
    }
    let lock = try OperationLock.shared(root)
    defer { withExtendedLifetime(lock) {} }
    let paths = root.macSandbox(id)
    return try await mutating(paths) {
      try requireFreeID(root, id)
      // Until the record is committed, a template delete must wait; the
      // template may have gone while this create waited for its locks.
      let templateLock = try FileLock.acquire(root.macTemplateLock(template), .shared)
      defer { withExtendedLifetime(templateLock) {} }
      _ = try t.load()
      try FileManager.default.createDirectory(
        at: paths.dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      do {
        // Copy-on-write clones: writes in one sandbox never reach another.
        try clone(t.disk, to: paths.disk)
        try clone(t.aux, to: paths.aux)
        try VZMacMachineIdentifier().dataRepresentation.write(to: paths.machineID, options: .atomic)
        chmod(paths.machineID.path, 0o600)
        var record: MacSandboxRecord?
        try SubnetAllocator(root: root).allocate(for: id) { index in
          let r = MacSandboxRecord(
            id: id, owner: owner, template: template, templateBuild: meta.build, cpus: cpus,
            memoryBytes: memoryBytes,
            macAddress: VZMACAddress.randomLocallyAdministered().string.lowercased(),
            subnetIndex: index, network: network, enrollment: .pending,
            authorizedKey: SSHPublicKey.canonical(authorizedKey), createdAt: Date(), expiresAt: nil)
          // Writing the record commits the create.
          try paths.save(r)
          record = r
        }
        guard let record else { throw SandboxError("allocation did not commit") }
        return record
      } catch {
        try? FileManager.default.removeItem(at: paths.dir)
        throw error
      }
    }
  }

  // MARK: start / stop (Gates D, K)

  package static func start(
    root: SandboxRoot, id: SandboxID, executable: String, wait: TimeInterval, expiresAt: Date?
  ) async throws -> MacLiveState {
    if let expiresAt, expiresAt <= Date() { throw SandboxError("--expires-at is in the past") }
    let paths = root.macSandbox(id)
    try await mutating(paths) {
      var record = try paths.loadRecord()
      guard record.enrollment != .identityMismatch else {
        throw SandboxError("\(id) has an identity mismatch; delete and recreate it")
      }
      if status(paths) == .crashed {
        Launchd.bootout(paths.launchdLabel)
        try? FileManager.default.removeItem(at: paths.live)
      }
      let s = status(paths)
      guard s == .stopped else { throw SandboxError("\(id) is \(s.rawValue); stop it first") }
      if record.expiresAt != expiresAt {
        record.expiresAt = expiresAt
        try paths.save(record)
      }
      Launchd.bootout(paths.launchdLabel)
      var plist = Launchd.plist(
        label: paths.launchdLabel, executable: executable,
        arguments: ["macos", "run", id.rawValue, "--root", root.root.path], log: paths.ownerLog)
      // The stop sequence can take requestStop's 15 s plus the helper's 120 s.
      plist["ExitTimeOut"] = 200
      try Launchd.write(plist, to: paths.launchdPlist)
      guard unlink(paths.ownerFailed.path) == 0 || errno == ENOENT else {
        throw SandboxError("remove \(paths.ownerFailed.path): errno \(errno)")
      }
      try Launchd.bootstrap(
        plist: paths.launchdPlist, domain: Launchd.domain(), label: paths.launchdLabel)
    }
    let deadline = Date().addingTimeInterval(wait)
    while Date() < deadline {
      if let live = paths.loadLive(), (try? call(paths, .init(op: .ping), timeout: 5))?.ok == true {
        return live
      }
      if let failure = try? String(contentsOf: paths.ownerFailed, encoding: .utf8) {
        Launchd.bootout(paths.launchdLabel)
        throw SandboxError("\(id) failed to start: \(failure)")
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    Launchd.bootout(paths.launchdLabel)
    throw SandboxError(
      "\(id) did not become ready within \(Int(wait))s; owner log:\n\(Sandboxes.logTail(paths.ownerLog, lines: 20))"
    )
  }

  /// Graceful stop, then wait for the owner to exit, then unload its job.
  package static func stop(root: SandboxRoot, id: SandboxID, timeout: TimeInterval) async throws
    -> String
  {
    let paths = root.macSandbox(id)
    _ = try paths.loadRecord()
    var path = "none (stopped)"
    if status(paths) == .running {
      path = (try? call(paths, .init(op: .stop), timeout: timeout))?.stopPath ?? "unconfirmed"
      let deadline = Date().addingTimeInterval(timeout)
      while ownerHoldsLock(paths), Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
      }
    } else if ownerHoldsLock(paths) {
      // Booting or wedged: launchd's SIGTERM runs the owner's stop sequence.
      path = "launchd"
    }
    Launchd.bootout(paths.launchdLabel)
    let hard = Date().addingTimeInterval(220)
    while ownerHoldsLock(paths), Date() < hard { try await Task.sleep(for: .milliseconds(100)) }
    guard !ownerHoldsLock(paths) else { throw SandboxError("\(id) owner did not exit") }
    try? FileManager.default.removeItem(at: paths.live)
    return path
  }

  // MARK: inspect / list / delete

  package static func inspect(root: SandboxRoot, id: SandboxID) throws -> MacInspectOutput {
    let paths = root.macSandbox(id)
    let record = try paths.loadRecord()
    let s = status(paths)
    var effective: MacEffectiveConfig?
    var runtime: MacStatus?
    if s == .running {
      effective = try? call(paths, .init(op: .inspect), timeout: 10).inspect
      runtime = try? call(paths, .init(op: .status), timeout: 20).status
    }
    return MacInspectOutput(
      record: record, status: s, live: s == .stopped ? nil : paths.loadLive(), effective: effective,
      runtime: runtime,
      sshHostKey: record.enrollment == .enrolled ? paths.loadPinnedHostKey() : nil)
  }

  package static func list(root: SandboxRoot) throws -> [[String: String]] {
    try root.allMacRecords().map {
      [
        "id": $0.id.rawValue, "status": status(root.macSandbox($0.id)).rawValue, "owner": $0.owner,
        "template": $0.template.rawValue, "enrollment": $0.enrollment.rawValue,
      ]
    }
  }

  package static func delete(root: SandboxRoot, id: SandboxID, owner: String) async throws {
    let paths = root.macSandbox(id)
    try await mutating(paths) {
      let record = try paths.loadRecord()
      guard record.owner == owner else { throw SandboxError("\(id) is owned by \(record.owner)") }
      let s = status(paths)
      guard s == .stopped else { throw SandboxError("\(id) is \(s.rawValue); stop it first") }
      Launchd.bootout(paths.launchdLabel)
      // Removing the record first makes a half-finished delete an
      // uncommitted directory, which reconcile removes.
      try FileManager.default.removeItem(at: paths.record)
      try FileManager.default.removeItem(at: paths.dir)
    }
  }

  /// Removes abandoned template builds and uncommitted creates.
  package static func reconcile(root: SandboxRoot) throws -> [ReconcileAction] {
    guard let lock = OperationLock.tryExclusive(root) else {
      throw SandboxError("an operation is in progress; try again")
    }
    defer { withExtendedLifetime(lock) {} }
    var actions: [ReconcileAction] = []
    for name in (try? FileManager.default.contentsOfDirectory(atPath: root.macTemplates.path)) ?? []
    where name.hasPrefix(".build-") {
      try? FileManager.default.removeItem(at: root.macTemplates.appendingPathComponent(name))
      actions.append(.init(id: name, status: "abandoned build", action: "removed"))
    }
    for name in (try? FileManager.default.contentsOfDirectory(atPath: root.macSandboxes.path)) ?? []
    {
      guard let id = try? SandboxID(name) else { continue }
      let paths = root.macSandbox(id)
      if !FileManager.default.fileExists(atPath: paths.record.path), !ownerHoldsLock(paths) {
        try? FileManager.default.removeItem(at: paths.dir)
        actions.append(.init(id: name, status: "uncommitted", action: "removed"))
      } else if paths.loadLive() != nil, !ownerHoldsLock(paths) {
        Launchd.bootout(paths.launchdLabel)
        try? FileManager.default.removeItem(at: paths.live)
        actions.append(.init(id: name, status: "crashed", action: "cleared"))
      }
    }
    return actions
  }

  // MARK: computer use (client side)

  package static func cu(root: SandboxRoot, id: SandboxID, _ req: MacControlRequest) throws
    -> MacControlResponse
  {
    let paths = root.macSandbox(id)
    _ = try paths.loadRecord()
    return try call(paths, req, timeout: 120)
  }
}
