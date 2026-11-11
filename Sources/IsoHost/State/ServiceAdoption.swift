import Darwin
import Foundation
import IsoCore

/// The marker that hands a legacy instance directory to the host service.
/// Once present, only the service's backend may mutate the instance.
package enum ServiceAdoption {
  struct Marker: Codable {
    var schema = 1
    let instanceID: InstanceID
  }

  package static func path(_ instance: Instance) -> String {
    instance.directory + "/host-control.json"
  }

  /// The service identity of an adopted instance, or nil when there is no
  /// marker. A marker that cannot be read or decoded is an error, never nil:
  /// nil would let a direct `iso` command mutate a service-managed instance.
  package static func load(_ instance: Instance) throws(HostError) -> InstanceID? {
    guard let bytes = try StateStore.readControlFile(path(instance)) else { return nil }
    let marker = try StateStore.decode(Marker.self, bytes, path: path(instance))
    guard marker.schema == 1 else {
      throw HostError(
        "unsupported host-control marker schema \(marker.schema) at \(path(instance))")
    }
    return marker.instanceID
  }

  package static func write(_ instance: Instance, _ id: InstanceID) throws(HostError) {
    try StateStore.writeControlFile(Marker(instanceID: id), to: path(instance))
  }

  package static func remove(_ instance: Instance) { unlink(path(instance)) }
}
