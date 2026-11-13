import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

extension HostSupervisor {
  package func inspect(_ target: QualifiedInstance) throws(HostControlError) -> VMObservation {
    if let tombstone = try? store.loadTombstone(target.instanceID) {
      try checkIdentity(
        target, hostID: tombstone.hostID, ownerID: tombstone.ownerID,
        runtime: tombstone.runtimeID, guestOS: tombstone.guestOS)
      return VMObservation(
        instance: target, name: tombstone.name, generation: tombstone.terminalGeneration,
        state: .destroyed, bootID: nil, policyHash: nil, expiresAt: nil, observedAt: now,
        activeOperation: nil)
    }
    let instance = try authoritative(target)
    return observation(instance)
  }

  func observation(_ instance: OperationStore.InstanceRecord) -> VMObservation {
    let spec = decodeSpec(instance.spec)
    var state: ObservedState
    var boot = instance.bootID
    switch try? native.observe(instance.instanceID, runtime: instance.runtimeID) {
    case .running(let observed, _, _)?:
      state = .running
      boot = observed
    case .stopped?: state = instance.lifecycle == .creating ? .unknown : .stopped
    case .unhealthy?: state = .unhealthy
    case .absent?: state = instance.lifecycle == .creating ? .unknown : .unhealthy
    case nil: state = .unknown
    }
    // A brokered boot that fails a fresh gate pass, or whose proof names
    // another boot, is not reported as running.
    var network: NetworkProof?
    if state == .running {
      do {
        network = try native.networkProof(instance.instanceID, runtime: instance.runtimeID)
        if let proof = network, proof.bootID != boot {
          state = .unhealthy
          network = nil
        }
      } catch {
        state = .unhealthy
      }
    }
    return VMObservation(
      instance: instance.qualified, name: instance.name, generation: instance.generation,
      state: state, bootID: state == .running ? boot : nil, policyHash: instance.policyHash,
      expiresAt: instance.expiresAt.map(WireTime.init(seconds:)), observedAt: now,
      activeOperation: instance.activeOperation, image: spec?.image, egress: spec?.egress,
      network: network)
  }

  func list(cursor: InstanceID?, limit: UInt32) -> JSONValue {
    let ids = store.instanceIDs().filter { cursor == nil || $0 > cursor! }
    let page = ids.prefix(Int(limit))
    var items: [JSONValue] = []
    for id in page {
      guard let instance = try? store.loadInstance(id) else { continue }
      items.append(observation(instance).wire)
    }
    var b = WireBuilder()
    b.set("instances", .array(items))
    if ids.count > page.count, let last = page.last { b.set("next_cursor", last) }
    return b.value
  }
}
