import Foundation
import IsoConfiguration
import IsoCore

/// Host-owned cleanup intent for one disposable `iso run`. The record lives
/// outside the instance directory so it survives instance deletion. A missing
/// or mismatched record is not permission to destroy a name.
package struct RunSessionRecord: Sendable, Equatable, Codable {
  package static let schemaVersion: UInt32 = 3
  package var schemaVersion: UInt32
  package var backend: String
  package var sessionID: RunSessionID
  package var ownerID: OwnerID
  package var intendedName: InstanceName
  package var creationOperationID: HexID
  package var workspace: String?
  package var state: State
  package var sandboxID: String?
  package var agentOutcome: String?
  package var cleanupOutcome: String?

  package enum State: String, Sendable, Equatable, Codable {
    case planned
    case creating
    case ready
    case running
    case finalizing
    case completed
    case retained
    case cleanupPending = "cleanup_pending"
  }

  package enum CodingKeys: String, CodingKey {
    case backend, state, workspace
    case schemaVersion = "schema_version"
    case sessionID = "session_id"
    case ownerID = "owner_id"
    case intendedName = "intended_name"
    case creationOperationID = "creation_operation_id"
    case sandboxID = "sandbox_id"
    case agentOutcome = "agent_outcome"
    case cleanupOutcome = "cleanup_outcome"
  }
}

/// Marker written into an instance directory before the VM is started, so
/// project affinity will not adopt the disposable instance.
package struct DisposableMarker: Sendable, Equatable, Codable {
  package var schemaVersion: UInt32
  package var backend: String
  package var lifecycle: InstanceLifecycle
  package var sessionID: RunSessionID
  package var ownerID: OwnerID
  package var creationOperationID: HexID
  package var intendedName: InstanceName

  package enum CodingKeys: String, CodingKey {
    case backend, lifecycle
    case schemaVersion = "schema_version"
    case sessionID = "session_id"
    case ownerID = "owner_id"
    case creationOperationID = "creation_operation_id"
    case intendedName = "intended_name"
  }

  package static func path(_ instance: Instance) -> String {
    instance.directory + "/lifecycle.json"
  }
}

package enum InstanceAffinity {
  /// Project affinity must not adopt a disposable run. Unreadable lifecycle
  /// state is also ineligible: unknown records are not treated as persistent.
  package static func eligibility(_ instance: Instance) -> Eligibility {
    let markerPath = DisposableMarker.path(instance)
    if FileManager.default.fileExists(atPath: markerPath) {
      do {
        guard let bytes = try StateStore.readControlFile(markerPath) else { return .eligible }
        let marker = try StateStore.decode(DisposableMarker.self, bytes, path: markerPath)
        guard marker.schemaVersion == RunSessionRecord.schemaVersion,
          marker.backend == StateSchema.backend,
          marker.lifecycle == .disposable
        else {
          return .unreadable(
            "lifecycle record for '\(instance.name)' is not a known disposable marker")
        }
        return .disposable
      } catch {
        return .unreadable(neutralizeControls("\(error)"))
      }
    }
    do {
      if try MachineSidecar.loadIfPresent(instance)?.isDisposableRun == true { return .disposable }
    } catch {
      return .unreadable(neutralizeControls("\(error)"))
    }
    return .eligible
  }

  package enum Eligibility: Equatable {
    case eligible
    case disposable
    case unreadable(String)
  }
}

package enum RunSessionStore {
  package static func directory(_ config: IsoConfig) -> String {
    config.stateRoot.appending("run-sessions").path
  }

  package static func path(_ config: IsoConfig, _ id: RunSessionID) -> String {
    directory(config) + "/\(id.rawValue).json"
  }

  package static func create(
    _ config: IsoConfig, name: InstanceName, workspace: String?, owner: Owner
  ) throws -> RunSessionRecord {
    try StateStore.ensurePrivateDirectory(directory(config))
    let record = RunSessionRecord(
      schemaVersion: RunSessionRecord.schemaVersion, backend: StateSchema.backend,
      sessionID: try HexID(randomHex(16)), ownerID: owner.id, intendedName: name,
      creationOperationID: try HexID(randomHex(16)), workspace: workspace, state: .planned,
      sandboxID: nil, agentOutcome: nil, cleanupOutcome: nil)
    try save(record, config: config)
    return record
  }

  package static func save(_ record: RunSessionRecord, config: IsoConfig) throws {
    try StateStore.ensurePrivateDirectory(directory(config))
    try StateStore.writeControlFile(record, to: path(config, record.sessionID))
  }

  package static func load(_ config: IsoConfig, _ id: RunSessionID) throws -> RunSessionRecord? {
    let path = path(config, id)
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    let record = try StateStore.decode(RunSessionRecord.self, bytes, path: path)
    guard record.schemaVersion == RunSessionRecord.schemaVersion,
      record.backend == StateSchema.backend,
      record.sessionID == id
    else {
      throw HostError("\(path) is not a version-\(RunSessionRecord.schemaVersion) run session")
    }
    return record
  }

  package static func list(_ config: IsoConfig) throws -> [RunSessionRecord] {
    let root = directory(config)
    let names: [String]
    do { names = try FileManager.default.contentsOfDirectory(atPath: root) } catch { return [] }
    var records: [RunSessionRecord] = []
    for name in names where name.hasSuffix(".json") {
      let stem = String(name.dropLast(5))
      guard let id = try? RunSessionID(stem), let record = try load(config, id) else { continue }
      records.append(record)
    }
    return records
  }

  package static func writeMarker(_ instance: Instance, _ record: RunSessionRecord) throws {
    let marker = DisposableMarker(
      schemaVersion: RunSessionRecord.schemaVersion, backend: StateSchema.backend,
      lifecycle: .disposable, sessionID: record.sessionID,
      ownerID: record.ownerID, creationOperationID: record.creationOperationID,
      intendedName: record.intendedName)
    try StateStore.writeControlFile(marker, to: DisposableMarker.path(instance))
  }

  package enum CleanupDecision: Equatable {
    case leave(String)
    case destroy(InstanceName)
  }

  /// Decide whether a disposable instance may be destroyed. Does not delete.
  /// A pending stage, a mismatched identity, or an active session is left.
  package static func reconcile(
    _ config: IsoConfig, session: RunSessionRecord, dryRun: Bool
  ) throws -> CleanupDecision {
    let owner = try Owner.load(config)
    guard session.ownerID == owner.id else {
      throw HostError("run session \(session.sessionID) is not owned by this installation")
    }
    guard session.state != .running && session.state != .creating && session.state != .ready else {
      return .leave("session \(session.sessionID) is still active; not deleted")
    }
    let instance = try? Instance.load(
      directory: config.instancesDirectory.appending(session.intendedName.rawValue).path)
    guard let instance, instance.name == session.intendedName else {
      if !dryRun {
        var done = session
        done.state = .completed
        done.cleanupOutcome = "no instance"
        try save(done, config: config)
      }
      return .leave("no instance named \(session.intendedName); nothing to delete")
    }
    guard let bytes = try StateStore.readControlFile(DisposableMarker.path(instance)) else {
      return .leave("instance '\(instance.name)' has no disposable marker; not deleted")
    }
    let marker = try StateStore.decode(
      DisposableMarker.self, bytes, path: DisposableMarker.path(instance))
    guard marker.sessionID == session.sessionID, marker.ownerID == session.ownerID,
      marker.creationOperationID == session.creationOperationID,
      marker.lifecycle == .disposable
    else {
      return .leave(
        "instance '\(instance.name)' marker does not match session \(session.sessionID); not deleted"
      )
    }
    if let sidecar = try MachineSidecar.loadIfPresent(instance) {
      guard sidecar.ownerID == owner.id else {
        return .leave(
          "instance '\(instance.name)' sandbox is not owned by this installation; not deleted")
      }
      if let recorded = session.sandboxID, recorded != sidecar.machineID.rawValue {
        return .leave(
          "instance '\(instance.name)' sandbox id does not match the session; not deleted")
      }
    } else if session.sandboxID != nil {
      return .leave(
        "instance '\(instance.name)' has no sandbox record to match the session; not deleted")
    }
    if StageLocation(instance).exists {
      return .leave("instance '\(instance.name)' has a pending staged pull; retained")
    }
    if dryRun {
      return .leave("would destroy instance '\(instance.name)' for session \(session.sessionID)")
    }
    return .destroy(instance.name)
  }
}
