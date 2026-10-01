import Foundation
import IsoCore

/// Renews one filtered-egress companion until the recorded sandbox identity
/// changes. This is not a protocol-5 boot id: a restored disk that keeps the
/// same machine id and owner PID is not distinguished.
public enum EgressLease {
  public static func stillOwns(directory: String, machineID: String, ownerPID: Int32) -> Bool {
    guard let instance = try? Instance.load(directory: directory),
      let sidecar = try? MachineSidecar.loadIfPresent(instance)
    else { return false }
    return sidecar.machineID.rawValue == machineID && sidecar.lastObservedOwnerPID == ownerPID
  }

  public static func run(directory: String, machineID: String, ownerPID: Int32) {
    let fd: Int32 = 3
    while stillOwns(directory: directory, machineID: machineID, ownerPID: ownerPID) {
      var byte: UInt8 = 1
      if write(fd, &byte, 1) != 1 { return }
      usleep(1_000_000)
    }
  }
}
