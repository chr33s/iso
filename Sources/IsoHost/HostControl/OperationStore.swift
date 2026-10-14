import Foundation
import IsoConfiguration
import IsoCore

/// Versioned host-control records under `<data_dir>/host-control` (spec 7.1).
/// Every write goes through `StateStore`/`AtomicFile`; reads never follow a
/// symlink and are size-bounded. Callers serialize writers: the supervisor
/// holds the service-ownership lock for its lifetime, and offline tools
/// (migration) hold the installation mutation lock.
package struct OperationStore: Sendable {
  package static let schema = 1
  /// Every record fits one slot; ordinary capacity and reservations count slots.
  package static let slotBytes = 4_096

  package struct Limits: Sendable, Equatable {
    package var maxReceipts: Int
    package var maxBytes: UInt64

    package static let standard = Limits(maxReceipts: 100_000, maxBytes: 256 << 20)

    package var maxSlots: Int {
      min(maxReceipts, Int(clamping: maxBytes / UInt64(OperationStore.slotBytes)))
    }
  }

  package let root: String
  package let limits: Limits

  package init(root: String, limits: Limits = .standard) throws(HostError) {
    self.root = root
    self.limits = limits
    for directory in [
      root, operationsDirectory, instancesDirectory, tombstonesDirectory, reservationsDirectory,
      locksDirectory,
    ] {
      try StateStore.ensurePrivateDirectory(directory)
    }
  }

  var operationsDirectory: String { root + "/operations" }
  var instancesDirectory: String { root + "/instances" }
  var tombstonesDirectory: String { root + "/tombstones" }
  var reservationsDirectory: String { root + "/reservations" }
  package var locksDirectory: String { root + "/locks" }
  package var installationPath: String { root + "/installation.json" }

  package var serviceLockPath: String { locksDirectory + "/service.lock" }
  package var mutationLockPath: String { locksDirectory + "/installation.lock" }

  // MARK: - Installation

  package enum ActivationState: String, Codable, Sendable {
    /// Normal dispatch.
    case active
    /// A migration handoff is prepared; only activation may run.
    case prepared
  }

  package struct InstallationRecord: Codable, Sendable, Equatable {
    package var schema = OperationStore.schema
    package let hostID: HostID
    package let ownerID: OwnerID
    package var state: ActivationState
    package let createdAt: UInt64
  }

  package func loadInstallation() throws(HostError) -> InstallationRecord? {
    try read(InstallationRecord.self, installationPath)
  }

  /// Loads the installation identity, creating it once for a fresh root.
  package func installation(owner: OwnerID, now: WireTime) throws(HostError) -> InstallationRecord {
    if let existing = try loadInstallation() {
      guard existing.ownerID == owner else {
        throw HostError("host-control installation belongs to a different owner")
      }
      return existing
    }
    let record = InstallationRecord(
      hostID: .generate(), ownerID: owner, state: .active, createdAt: now.seconds)
    let bytes = try StateStore.encode(record, path: installationPath)
    try AtomicFile.createExclusive(bytes, at: installationPath, mode: 0o600)
    // A concurrent creator may have won; its record is authoritative.
    guard let stored = try loadInstallation() else {
      throw HostError("host-control installation record disappeared")
    }
    return stored
  }

  package func saveInstallation(_ record: InstallationRecord) throws(HostError) {
    try StateStore.writeControlFile(record, to: installationPath)
  }

  // MARK: - Operations

  package struct OperationRecord: Codable, Sendable, Equatable {
    package var schema = OperationStore.schema
    package let operationID: HostOperationID
    package let method: String
    package let digest: SHA256Hex
    /// Canonical typed params; the operation is re-decoded from these.
    package let params: String
    package let transport: String
    package let acceptedAt: UInt64
    package var state: OperationState
    /// Last persisted progress boundary; nil before any external effect.
    package var substep: String?
    package var cancelRequested: Bool
    package var instanceID: InstanceID?
    package var runtimeID: MachineName?
    package var deadline: UInt64?
    package var bootID: BootID?
    package var generation: UInt64?
    package var outcome: String?
    package var completedAt: UInt64?
    /// The run this operation belongs to, when it is a run child.
    package var runID: RunID?
  }

  func operationPath(_ id: HostOperationID) -> String {
    operationsDirectory + "/" + id.rawValue + ".json"
  }

  package func loadOperation(_ id: HostOperationID) throws(HostError) -> OperationRecord? {
    try read(OperationRecord.self, operationPath(id))
  }

  package func saveOperation(_ record: OperationRecord) throws(HostError) {
    try write(record, operationPath(record.operationID))
  }

  package func operationIDs() -> [HostOperationID] {
    list(operationsDirectory, suffix: ".json").compactMap { try? HostOperationID($0) }
  }

  // MARK: - Instances

  package struct InstanceRecord: Codable, Sendable, Equatable {
    package var schema = OperationStore.schema
    package let hostID: HostID
    package let ownerID: OwnerID
    package let instanceID: InstanceID
    package let runtimeID: MachineName
    package let guestOS: GuestOS
    package let name: InstanceName
    /// Canonical `vm.create` params this instance was created from.
    package let spec: String
    package let createdBy: HostOperationID
    package var generation: UInt64
    package var lifecycle: VMLifecycle
    package var bootID: BootID?
    package var policyHash: SHA256Hex?
    package var expiresAt: UInt64?
    package var activeOperation: HostOperationID?
    package var lastObservedAt: UInt64?
    /// Set for a disposable run's child VM.
    package var runID: RunID?

    /// The same record with a new create shape (after resize or restore).
    package func replacingSpec(_ spec: String, policy: SHA256Hex) -> InstanceRecord {
      InstanceRecord(
        hostID: hostID, ownerID: ownerID, instanceID: instanceID, runtimeID: runtimeID,
        guestOS: guestOS, name: name, spec: spec, createdBy: createdBy, generation: generation,
        lifecycle: lifecycle, bootID: bootID, policyHash: policy, expiresAt: expiresAt,
        activeOperation: activeOperation, lastObservedAt: lastObservedAt, runID: runID)
    }

    package var qualified: QualifiedInstance {
      QualifiedInstance(
        hostID: hostID, ownerID: ownerID, instanceID: instanceID, runtimeID: runtimeID,
        guestOS: guestOS)
    }
  }

  func instancePath(_ id: InstanceID) -> String { instancesDirectory + "/" + id.rawValue + ".json" }

  package func loadInstance(_ id: InstanceID) throws(HostError) -> InstanceRecord? {
    try read(InstanceRecord.self, instancePath(id))
  }

  package func saveInstance(_ record: InstanceRecord) throws(HostError) {
    try write(record, instancePath(record.instanceID))
  }

  package func instanceIDs() -> [InstanceID] {
    list(instancesDirectory, suffix: ".json").compactMap { try? InstanceID($0) }.sorted()
  }

  package func removeInstance(_ id: InstanceID) throws(HostError) {
    try StateStore.removeIfPresent(instancePath(id))
  }

  /// Only for a run child whose run was never accepted: it never executed,
  /// since a run child executes only from its run's operation.
  package func removeOperation(_ id: HostOperationID) throws(HostError) {
    try StateStore.removeIfPresent(operationPath(id))
  }

  // MARK: - Tombstones

  package struct Tombstone: Codable, Sendable, Equatable {
    package var schema = OperationStore.schema
    package let hostID: HostID
    package let ownerID: OwnerID
    package let instanceID: InstanceID
    package let runtimeID: MachineName
    package let guestOS: GuestOS
    package let name: InstanceName
    package let terminalGeneration: UInt64
    package let destroyedBy: HostOperationID
    package let destroyedAt: UInt64
    package let createdBy: HostOperationID
    package let disposition: String
  }

  func tombstonePath(_ id: InstanceID) -> String {
    tombstonesDirectory + "/" + id.rawValue + ".json"
  }

  package func loadTombstone(_ id: InstanceID) throws(HostError) -> Tombstone? {
    try read(Tombstone.self, tombstonePath(id))
  }

  package func saveTombstone(_ record: Tombstone) throws(HostError) {
    try write(record, tombstonePath(record.instanceID))
  }

  // MARK: - Reservations

  /// Physically allocated space for work an admission promises to finish.
  package enum Reservation: Sendable, Hashable {
    /// Rewriting one operation record at completion (atomic-replace scratch).
    case finalize(HostOperationID)
    /// One stop record (+ scratch) for the instance's current boot.
    case stop(InstanceID)
    /// The destroy record, its scratch, and the tombstone.
    case destroy(InstanceID)
    /// A disposable run's later transitions (complete, recover, ack/discard).
    case run(RunID)

    var name: String {
      switch self {
      case .finalize(let id): "finalize-" + id.rawValue
      case .stop(let id): "stop-" + id.rawValue
      case .destroy(let id): "destroy-" + id.rawValue
      case .run(let id): "run-" + id.rawValue
      }
    }

    package var slots: Int {
      switch self {
      case .finalize: 1
      case .stop: 2
      case .destroy: 3
      case .run: 6
      }
    }
  }

  func reservationPath(_ reservation: Reservation) -> String {
    reservationsDirectory + "/" + reservation.name
  }

  package func hasReservation(_ reservation: Reservation) -> Bool {
    access(reservationPath(reservation), F_OK) == 0
  }

  /// Writes and fsyncs a zero-filled file of the reservation's size.
  package func reserve(_ reservation: Reservation) throws(HostError) {
    guard !hasReservation(reservation) else { return }
    let bytes = [UInt8](repeating: 0, count: reservation.slots * Self.slotBytes)
    try AtomicFile.write(bytes, to: reservationPath(reservation), mode: .atMost(0o600))
  }

  /// Frees the reservation's space for the record about to use it.
  package func consume(_ reservation: Reservation) throws(HostError) {
    try StateStore.removeIfPresent(reservationPath(reservation))
  }

  /// Gives back `slots` of a multi-step reservation for the record about to
  /// use them; removes it when nothing remains.
  package func shrink(_ reservation: Reservation, by slots: Int) throws(HostError) {
    let remaining = reservedSlots(reservationPath(reservation)) - slots
    guard remaining > 0 else { return try consume(reservation) }
    try AtomicFile.write(
      [UInt8](repeating: 0, count: remaining * Self.slotBytes), to: reservationPath(reservation),
      mode: .atMost(0o600))
  }

  private func reservedSlots(_ path: String) -> Int {
    var status = stat()
    guard lstat(path, &status) == 0 else { return 0 }
    return Int((status.st_size + off_t(Self.slotBytes) - 1) / off_t(Self.slotBytes))
  }

  // MARK: - Capacity

  /// Slots in use: every record is one slot, reservations their declared size.
  package func usedSlots() -> Int {
    var used = 0
    for directory in [operationsDirectory, instancesDirectory, tombstonesDirectory] {
      used += list(directory, suffix: ".json").count
    }
    for name in list(reservationsDirectory, suffix: "") {
      used += reservedSlots(reservationsDirectory + "/" + name)
    }
    return used
  }

  // MARK: - Primitives

  private func read<T: Decodable>(_ type: T.Type, _ path: String) throws(HostError) -> T? {
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    let record = try StateStore.decode(T.self, bytes, path: path)
    if let versioned = record as? any VersionedRecord, versioned.schema != Self.schema {
      throw HostError("\(path) has unsupported schema \(versioned.schema)")
    }
    return record
  }

  private func write(_ record: some Encodable, _ path: String) throws(HostError) {
    let bytes = try StateStore.encode(record, path: path)
    guard bytes.count <= Self.slotBytes else {
      throw HostError("host-control record \(path) exceeds its \(Self.slotBytes)-byte slot")
    }
    try AtomicFile.write(bytes, to: path, mode: .atMost(0o600))
  }

  private func list(_ directory: String, suffix: String) -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return names.compactMap { name in
      guard !name.hasPrefix("."), name.hasSuffix(suffix) else { return nil }
      return String(name.dropLast(suffix.count))
    }
  }
}

protocol VersionedRecord { var schema: Int { get } }
extension OperationStore.InstallationRecord: VersionedRecord {}
extension OperationStore.OperationRecord: VersionedRecord {}
extension OperationStore.InstanceRecord: VersionedRecord {}
extension OperationStore.Tombstone: VersionedRecord {}

extension OperationStore.OperationRecord {
  package func receipt(disposition: AdmissionDisposition, instance: QualifiedInstance?)
    -> OperationReceipt
  {
    OperationReceipt(
      operationID: operationID, method: HostMethod(rawValue: method) ?? .operationGet, state: state,
      disposition: disposition, acceptedAt: WireTime(seconds: acceptedAt),
      completedAt: completedAt.map(WireTime.init(seconds:)), instance: instance,
      generation: generation, bootID: bootID, expiresAt: deadline.map(WireTime.init(seconds:)),
      outcome: outcome, cancelRequested: cancelRequested)
  }
}
