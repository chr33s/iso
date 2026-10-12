import Foundation
import IsoConfiguration
import IsoCore

/// Worker-owned disposable runs (spec 12). A run record exists before its VM
/// is created, names its reserved child operations, and holds one of the
/// installation's result-retention slots until verified cleanup.
package struct RunStore: Sendable {
  package static let retentionSlots = 4
  package static let retentionSeconds: UInt64 = 3_600
  package static let recoveryTTLSeconds: UInt64 = 300
  /// Results are captured in memory before commit, so they are bounded tightly.
  package static let maxOutputBytes: UInt64 = 256 << 20
  /// How long a running run may lack a live controlling session before the
  /// worker stops it.
  package static let controllerGraceSeconds: UInt64 = 60

  package enum Phase: String, Codable, Sendable, CaseIterable {
    case reserved
    case creating
    case running
    case exporting
    case stopping
    case resultsPending = "results_pending"
    case stoppedDiskPendingExport = "stopped_disk_pending_export"
    case recovering
    case destroyed
    case failedWithResources = "failed_with_resources"

    /// Phases that still hold a retention slot.
    package var holdsSlot: Bool { self != .destroyed }
  }

  package struct Record: Codable, Sendable, Equatable {
    package var schema = OperationStore.schema
    package let runID: RunID
    package let createdBy: HostOperationID
    package var generation: UInt64
    package var phase: Phase
    package let outputLimit: UInt64
    package let ttlSeconds: UInt64
    package let createOperation: HostOperationID
    package let startOperation: HostOperationID
    package var instanceID: InstanceID?
    package var runtimeID: MachineName?
    package var startedAt: UInt64?
    package var artifact: ArtifactHandle?
    package var artifactDigest: SHA256Hex?
    package var firstStopAt: UInt64?
    package var retentionDeadline: UInt64?
    package var recoveryUsed: Bool
    package var recoveryDeadline: UInt64?
    package var exitStatus: Int32?
    package var disposition: String?
    package var deliveredStage: StageID?
    /// The run transition currently executing, if any.
    package var activeOperation: HostOperationID?
  }

  let root: String

  package init(root: String) throws(HostError) {
    self.root = root
    try StateStore.ensurePrivateDirectory(root)
  }

  func path(_ id: RunID) -> String { root + "/" + id.rawValue + ".json" }

  package func load(_ id: RunID) throws(HostError) -> Record? {
    guard let bytes = try StateStore.readControlFile(path(id)) else { return nil }
    let record = try StateStore.decode(Record.self, bytes, path: path(id))
    guard record.schema == OperationStore.schema else {
      throw HostError("\(path(id)) has unsupported schema \(record.schema)")
    }
    return record
  }

  package func save(_ record: Record) throws(HostError) {
    try StateStore.writeControlFile(record, to: path(record.runID))
  }

  package func runIDs() -> [RunID] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
    return names.compactMap { name in
      guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
      return try? RunID(String(name.dropLast(5)))
    }.sorted()
  }

  /// Runs holding a retention slot.
  package func slotsInUse() -> Int {
    runIDs().filter { (try? load($0))?.phase.holdsSlot ?? true }.count
  }

  /// Releases a reservation whose creation was cancelled before any effect.
  func cancelReserved(_ id: RunID) {
    guard var record = try? load(id), record.phase == .reserved else { return }
    record.phase = .destroyed
    record.disposition = "cancelled"
    record.generation += 1
    try? save(record)
  }

  package func inspect(_ id: RunID, host: HostID, owner: OwnerID) throws(HostControlError)
    -> RunObservation
  {
    let record: Record?
    do { record = try load(id) } catch {
      throw HostControlError(.operationUncertain, "run record is unreadable")
    }
    guard let record else {
      throw HostControlError(.resultsUnavailable, "unknown run", details: ["run_id": id.rawValue])
    }
    return RunObservation(record: record)
  }
}

/// `run.inspect` result.
package struct RunObservation: Sendable, Equatable {
  package let runID: RunID
  package let generation: UInt64
  package let phase: RunStore.Phase
  package let instanceID: InstanceID?
  package let runtimeID: MachineName?
  package let artifact: ArtifactHandle?
  package let artifactDigest: SHA256Hex?
  package let retentionDeadline: WireTime?
  package let recoveryUsed: Bool
  package let disposition: String?

  init(record: RunStore.Record) {
    runID = record.runID
    generation = record.generation
    phase = record.phase
    instanceID = record.instanceID
    runtimeID = record.runtimeID
    artifact = record.artifact
    artifactDigest = record.artifactDigest
    retentionDeadline = record.retentionDeadline.map(WireTime.init(seconds:))
    recoveryUsed = record.recoveryUsed
    disposition = record.disposition
  }

  package var wire: JSONValue {
    var b = WireBuilder()
    b.set("run_id", runID)
    b.set("generation", generation)
    b.set("phase", phase.rawValue)
    b.setIfPresent("instance_id", instanceID)
    b.setIfPresent("runtime_id", runtimeID)
    b.setIfPresent("artifact", artifact)
    b.setIfPresent("artifact_digest", artifactDigest)
    b.setIfPresent("retention_deadline", retentionDeadline?.seconds)
    b.set("recovery_used", recoveryUsed)
    if let disposition { b.set("disposition", disposition) }
    return b.value
  }

  package init(wire value: JSONValue) throws(HostControlError) {
    var r = try WireObject(value, field: "run")
    runID = try r.parsed("run_id", RunID.init)
    generation = try r.unsigned("generation")
    guard let phase = RunStore.Phase(rawValue: try r.string("phase")) else {
      throw .invalidRequest("invalid run.phase")
    }
    self.phase = phase
    instanceID = try r.optionalParsed("instance_id", InstanceID.init)
    runtimeID = try r.optionalParsed("runtime_id", MachineName.init)
    artifact = try r.optionalParsed("artifact", ArtifactHandle.init)
    artifactDigest = try r.optionalParsed("artifact_digest", SHA256Hex.init)
    retentionDeadline = try r.optionalUnsigned("retention_deadline", as: UInt64.self).map(
      WireTime.init(seconds:))
    recoveryUsed = try r.bool("recovery_used")
    disposition = try r.optionalString("disposition")
    try r.finish()
  }
}
