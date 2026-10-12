import Darwin
import Foundation
import IsoConfiguration
import IsoCore

/// The marker that hands a legacy instance directory to the host service.
/// Once present, only the service's backend may mutate the instance.
package enum ServiceAdoption {
  struct Marker: Codable {
    var schema = 1
    let instanceID: InstanceID
  }

  static func path(_ instance: Instance) -> String { instance.directory + "/host-control.json" }

  /// The service identity of an adopted instance, or nil.
  package static func load(_ instance: Instance) -> InstanceID? {
    guard let bytes = try? StateStore.readControlFile(path(instance)),
      let marker = try? JSONDecoder().decode(Marker.self, from: Data(bytes)), marker.schema == 1
    else { return nil }
    return marker.instanceID
  }

  static func write(_ instance: Instance, _ id: InstanceID) throws(HostError) {
    try StateStore.writeControlFile(Marker(instanceID: id), to: path(instance))
  }

  static func remove(_ instance: Instance) { unlink(path(instance)) }
}

/// `iso host migrate local` (spec 14): a stopped-boundary, one-time move of a
/// local data root under the host service. The command previews, then
/// prepares a durable handoff and releases its locks; the service (holding
/// its ownership lock) rechecks everything and completes activation before it
/// dispatches any work. Migration never stops a VM.
package enum HostMigration {
  package struct LegacyInstance: Sendable, Equatable {
    package let name: InstanceName
    package let running: Bool
    package let pendingJournal: String?
    package let guestOS: GuestOS
    package let disposable: Bool

    /// Linux, reusable instances are adopted; macOS guests stay on the
    /// legacy path (the service does not manage macOS guests).
    package var adoptable: Bool { guestOS == .linux && !disposable }
  }

  package struct Preview: Sendable, Equatable {
    package let legacyInstances: [LegacyInstance]
    package let otherWriters: [pid_t]
    package let blockers: [String]
    package let installation: OperationStore.InstallationRecord?
    package let migration: MigrationRecord?

    package var eligible: Bool { blockers.isEmpty }
  }

  /// The durable handoff between the migrate command and the service.
  package struct MigrationRecord: Codable, Sendable, Equatable {
    package enum State: String, Codable, Sendable {
      case prepared
      case active
      case rolledBack = "rolled_back"
    }

    package struct Adoption: Codable, Sendable, Equatable {
      package let name: InstanceName
      package let instanceID: InstanceID
      package let runtimeID: MachineName
    }

    package var schema = 1
    package var state: State
    package let operation: HostOperationID
    package let preparedAt: UInt64
    package let adoptions: [Adoption]
  }

  static func recordPath(_ config: IsoConfig) -> String {
    HostService.root(config) + "/migration.json"
  }

  package static func loadRecord(_ config: IsoConfig) throws(HostError) -> MigrationRecord? {
    guard let bytes = try StateStore.readControlFile(recordPath(config)) else { return nil }
    return try StateStore.decode(MigrationRecord.self, bytes, path: recordPath(config))
  }

  // MARK: - Preview

  package static func preview(
    config: IsoConfig, backend: AppleBackend, diagnostics: Diagnostics
  ) throws -> Preview {
    var legacy: [LegacyInstance] = []
    let instances = try InstanceStore.list(config) { path, error in
      diagnostics.warn("Skipping unreadable instance \(path): \(error)")
    }
    for instance in instances
    where !instance.name.rawValue.hasPrefix("hc-") && ServiceAdoption.load(instance) == nil {
      let journal = try? Journal.loadIfPresent(instance)
      let sidecar = try? MachineSidecar.loadIfPresent(instance)
      legacy.append(
        LegacyInstance(
          name: instance.name, running: backend.isRunning(instance),
          pendingJournal: journal.map { $0.op.describe }, guestOS: sidecar?.kind ?? .linux,
          disposable: sidecar?.isDisposableRun ?? false))
    }
    let writers = otherIsoProcesses()
    var blockers: [String] = []
    for instance in legacy {
      if let journal = instance.pendingJournal {
        blockers.append("instance '\(instance.name)' has an unfinished \(journal)")
      }
      if instance.running {
        blockers.append(
          "instance '\(instance.name)' is running; stop it yourself (migration never stops VMs)")
      }
      if instance.disposable {
        blockers.append(
          "instance '\(instance.name)' belongs to a disposable run; finish it with `iso run-cleanup`"
        )
      }
    }
    if !writers.isEmpty {
      blockers.append(
        "other iso processes are running (pids \(writers.map(String.init).joined(separator: ", "))); let them exit first"
      )
    }
    let store = try OperationStore(root: HostService.root(config))
    let record = try loadRecord(config)
    // An active root may migrate again: legacy instances made since are
    // adopted by the same stopped-boundary handoff.
    return Preview(
      legacyInstances: legacy, otherWriters: writers, blockers: blockers,
      installation: try store.loadInstallation(), migration: record)
  }

  // MARK: - Prepare (the command)

  /// Writes the prepared handoff under the installation mutation lock, then
  /// releases it. Refuses while a host service holds the data root.
  package static func prepare(config: IsoConfig, preview: Preview) throws -> MigrationRecord {
    guard preview.eligible else {
      throw HostControlError(
        .migrationRequired, "activation is blocked: " + preview.blockers.joined(separator: "; "))
    }
    let owner = try Owner.load(config)
    let store = try OperationStore(root: HostService.root(config))
    // A running service would see a half-prepared root: require it stopped.
    guard let probe = try FileLock.attempt(path: store.serviceLockPath) else {
      throw HostControlError(
        .migrationRequired, "a host service is running for this data root; stop it before migrating"
      )
    }
    probe.release()
    let mutation = try FileLock(path: store.mutationLockPath)
    defer { mutation.release() }
    var installation = try store.installation(owner: owner.id, now: WireTime(Date()))
    let adoptions = try plan(config: config, preview: preview, owner: owner)
    let record = MigrationRecord(
      state: .prepared, operation: .generate(), preparedAt: WireTime(Date()).seconds,
      adoptions: adoptions)
    // The prepared record is the handoff: written before the installation
    // leaves the active state, so every crash point has a recorded owner.
    try StateStore.writeControlFile(record, to: recordPath(config))
    installation.state = .prepared
    try store.saveInstallation(installation)
    return record
  }

  private static func plan(config: IsoConfig, preview: Preview, owner: Owner) throws
    -> [MigrationRecord.Adoption]
  {
    let names = Set(preview.legacyInstances.filter(\.adoptable).map(\.name))
    var adoptions: [MigrationRecord.Adoption] = []
    for instance in try InstanceStore.list(config, skipped: { _, _ in })
    where names.contains(instance.name) {
      let sidecar = try MachineSidecar.load(instance)
      try sidecar.checkOwner(owner)
      adoptions.append(
        .init(name: instance.name, instanceID: .generate(), runtimeID: sidecar.machineID))
    }
    return adoptions.sorted { $0.name < $1.name }
  }

  // MARK: - Complete (the service, activation-only)

  /// Completes a prepared migration. The caller holds the service-ownership
  /// lock; this takes the mutation lock, rechecks the stopped boundary, the
  /// writers and every planned identity, then adopts each instance, fences
  /// the owner record against older binaries, and commits active. Each step
  /// is idempotent, so a crash at any point resumes here.
  package static func complete(config: IsoConfig, backend: AppleBackend, diagnostics: Diagnostics)
    throws
  {
    guard var record = try loadRecord(config), record.state == .prepared else { return }
    let owner = try Owner.load(config)
    let store = try OperationStore(root: HostService.root(config))
    let mutation = try FileLock(path: store.mutationLockPath)
    defer { mutation.release() }
    guard var installation = try store.loadInstallation(), installation.ownerID == owner.id else {
      throw HostControlError(.migrationRequired, "the installation record does not match the owner")
    }
    let writers = otherIsoProcesses()
    guard writers.isEmpty else {
      throw HostControlError(
        .migrationRequired,
        "other iso processes are running (pids \(writers.map(String.init).joined(separator: ", ")))"
      )
    }
    let instances = try InstanceStore.list(config, skipped: { _, _ in })
    for adoption in record.adoptions {
      guard let instance = instances.first(where: { $0.name == adoption.name }) else {
        throw HostControlError(.migrationRequired, "instance '\(adoption.name)' disappeared")
      }
      if let existing = ServiceAdoption.load(instance) {
        guard existing == adoption.instanceID else {
          throw HostControlError(
            .migrationRequired, "instance '\(adoption.name)' was adopted under another identity")
        }
        continue
      }
      let sidecar = try MachineSidecar.load(instance)
      try sidecar.checkOwner(owner)
      guard sidecar.machineID == adoption.runtimeID, try Journal.loadIfPresent(instance) == nil
      else {
        throw HostControlError(
          .migrationRequired, "instance '\(adoption.name)' changed since the migration was prepared"
        )
      }
      guard !backend.isRunning(instance) else {
        throw HostControlError(
          .migrationRequired, "instance '\(adoption.name)' is running; stop it to finish migration")
      }
      try adopt(
        instance, sidecar: sidecar, adoption: adoption, installation: installation,
        operation: record.operation, store: store, config: config, backend: backend)
    }
    try Owner.setFence(config, fenced: true)
    record.state = .active
    try StateStore.writeControlFile(record, to: recordPath(config))
    installation.state = .active
    try store.saveInstallation(installation)
    diagnostics.log(
      .info, "Host-control migration complete: \(record.adoptions.count) instance(s) adopted")
  }

  private static func adopt(
    _ instance: Instance, sidecar: MachineSidecar, adoption: MigrationRecord.Adoption,
    installation: OperationStore.InstallationRecord, operation: HostOperationID,
    store: OperationStore, config: IsoConfig, backend: AppleBackend
  ) throws {
    guard let policy = try NetworkPolicy.load(instance),
      let egress = EgressMode(rawValue: policy.mode)
    else {
      throw HostControlError(
        .migrationRequired, "instance '\(instance.name)' has no recorded network policy")
    }
    let writer = backend.asServiceWriter()
    let disk = try writer.currentDiskGiB(try writer.asStopped(instance))
    let spec = try VMSpec.make(
      name: instance.name, image: instance.image, imageDigest: nil, cpus: sidecar.requestedCPUs,
      memoryMiB: sidecar.requestedMemoryBytes >> 20, diskGiB: max(1, disk), guestOS: .linux,
      egress: egress)
    if try store.loadInstance(adoption.instanceID) == nil {
      try store.reserve(.destroy(adoption.instanceID))
      try store.saveInstance(
        OperationStore.InstanceRecord(
          hostID: installation.hostID, ownerID: installation.ownerID,
          instanceID: adoption.instanceID, runtimeID: adoption.runtimeID, guestOS: .linux,
          name: instance.name, spec: String(decoding: HostWire.canonical(spec.wire), as: UTF8.self),
          createdBy: operation, generation: 1, lifecycle: .stopped, bootID: nil,
          policyHash: spec.policyHash, expiresAt: nil, activeOperation: nil,
          lastObservedAt: WireTime(Date()).seconds, runID: nil))
    }
    // The client side addresses it as `local NAME`.
    try ClientBindingStore(config: config).save(
      ClientBinding(
        host: .local, hostID: installation.hostID, ownerID: installation.ownerID,
        instanceID: adoption.instanceID, runtimeID: adoption.runtimeID, guestOS: .linux,
        name: instance.name, policyHash: spec.policyHash, createdBy: operation,
        lastState: ObservedState.stopped.rawValue, lastObservedAt: nil))
    // The marker is written last: until then the legacy path still owns it.
    try ServiceAdoption.write(instance, adoption.instanceID)
  }

  // MARK: - Rollback (before active only)

  /// Undoes a prepared, not yet active migration under the same locks.
  /// After activation there is no automatic rewind (forward-fix only).
  package static func rollback(config: IsoConfig) throws {
    guard var record = try loadRecord(config) else {
      throw HostError("no host-control migration is prepared")
    }
    guard record.state == .prepared else {
      throw HostError(
        "the migration is \(record.state.rawValue); an activated root is not rolled back automatically"
      )
    }
    let store = try OperationStore(root: HostService.root(config))
    guard let probe = try FileLock.attempt(path: store.serviceLockPath) else {
      throw HostError("stop the host service before rolling back")
    }
    defer { probe.release() }
    let mutation = try FileLock(path: store.mutationLockPath)
    defer { mutation.release() }
    let instances = try InstanceStore.list(config, skipped: { _, _ in })
    for adoption in record.adoptions {
      if let instance = instances.first(where: { $0.name == adoption.name }),
        ServiceAdoption.load(instance) == adoption.instanceID
      {
        ServiceAdoption.remove(instance)
      }
      try? store.removeInstance(adoption.instanceID)
      try? store.consume(.destroy(adoption.instanceID))
      if let installation = try store.loadInstallation() {
        try? ClientBindingStore(config: config).remove(installation.hostID, adoption.name)
      }
    }
    try Owner.setFence(config, fenced: false)
    if var installation = try store.loadInstallation() {
      installation.state = .active
      try store.saveInstallation(installation)
    }
    record.state = .rolledBack
    try StateStore.writeControlFile(record, to: recordPath(config))
  }

  // MARK: - Writers

  /// Same-user processes running an `iso` executable, other than this one,
  /// the host service and its frontends, and the migrate command itself.
  static func otherIsoProcesses() -> [pid_t] {
    let me = getpid()
    let uid = getuid()
    var pids = [pid_t](repeating: 0, count: 4_096)
    let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard count > 0 else { return [] }
    var found: [pid_t] = []
    for pid in pids.prefix(Int(count)) where pid > 0 && pid != me && pid != getppid() {
      var info = proc_bsdinfo()
      let size = proc_pidinfo(
        pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
      guard size == MemoryLayout<proc_bsdinfo>.size, info.pbi_uid == uid else { continue }
      var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
      let executable = String(
        decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      guard (executable as NSString).lastPathComponent == "iso" else { continue }
      let arguments = arguments(of: pid) ?? ""
      // New-format writers: the service, its frontends, and migration itself.
      if arguments.contains(" host-agent ") || arguments.contains(" host migrate ") { continue }
      found.append(pid)
    }
    return found
  }

  /// A process's executable and arguments, NUL-separated words joined by
  /// spaces; nil when unreadable.
  static func arguments(of pid: pid_t) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size < 1 << 20 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix(size).map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self) + " "
  }
}
