import Foundation
import IsoCore

/// Renews one filtered-egress companion while the recorded sandbox and the
/// runtime's live boot id still match. A restored disk does not restore
/// `bootId`; the next owner writes a new one.
public enum EgressLease {
  public static func stillOwns(directory: String, machineID: String, ownerPID: Int32) -> Bool {
    guard let instance = try? Instance.load(directory: directory),
      let sidecar = try? MachineSidecar.loadIfPresent(instance)
    else { return false }
    return sidecar.machineID.rawValue == machineID && sidecar.lastObservedOwnerPID == ownerPID
  }

  public static func liveIdentity(at path: String) -> (bootID: String, pid: Int32)? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let bootID = object["bootId"] as? String,
      let pid = object["pid"] as? Int
    else { return nil }
    return (bootID, Int32(pid))
  }

  /// Both the host record and the runtime's current boot must match.
  public static func renewalAllowed(
    ownsRecordedIdentity: Bool, liveBootID: String?, expectedBootID: String, livePID: Int32?,
    expectedPID: Int32
  ) -> Bool {
    ownsRecordedIdentity && liveBootID == expectedBootID && !expectedBootID.isEmpty
      && livePID == expectedPID
  }

  public static func run(
    directory: String, machineID: String, ownerPID: Int32, bootID: String, livePath: String
  ) {
    let fd: Int32 = 3
    while true {
      let live = liveIdentity(at: livePath)
      guard
        renewalAllowed(
          ownsRecordedIdentity: stillOwns(
            directory: directory, machineID: machineID, ownerPID: ownerPID),
          liveBootID: live?.bootID, expectedBootID: bootID, livePID: live?.pid,
          expectedPID: ownerPID)
      else { return }
      var byte: UInt8 = 1
      if write(fd, &byte, 1) != 1 { return }
      usleep(1_000_000)
    }
  }
}
