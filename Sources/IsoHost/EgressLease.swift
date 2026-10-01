import Darwin
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

  /// A missing or unreadable record, or an unparseable deadline, is closed.
  /// No `expiresAt` means the session has no TTL.
  public static func sessionOpen(recordPath: String, now: Date) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: recordPath)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    guard let text = object["expiresAt"] as? String else { return true }
    guard let deadline = ISO8601DateFormatter().date(from: text) else { return false }
    return now < deadline
  }

  /// A missing or unreadable lock is not held. An exclusive non-blocking
  /// flock that succeeds means no owner process holds it.
  public static func ownerLockHeld(at path: String) -> Bool {
    let fd = open(path, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      _ = flock(fd, LOCK_UN)
      return false
    }
    return true
  }

  /// The recorded identity, live boot, session deadline, and owner lock must
  /// all still match. A leftover `live.json` is not enough.
  public static func renewalAllowed(
    ownsRecordedIdentity: Bool, liveBootID: String?, expectedBootID: String, livePID: Int32?,
    expectedPID: Int32, sessionOpen: Bool, ownerAlive: Bool
  ) -> Bool {
    ownsRecordedIdentity && liveBootID == expectedBootID && !expectedBootID.isEmpty
      && livePID == expectedPID && sessionOpen && ownerAlive
  }

  public static func run(
    directory: String, machineID: String, ownerPID: Int32, bootID: String, livePath: String
  ) {
    let fd: Int32 = 3
    while true {
      let live = liveIdentity(at: livePath)
      let directoryURL = (livePath as NSString).deletingLastPathComponent
      let recordPath = directoryURL + "/record.json"
      guard
        renewalAllowed(
          ownsRecordedIdentity: stillOwns(
            directory: directory, machineID: machineID, ownerPID: ownerPID),
          liveBootID: live?.bootID, expectedBootID: bootID, livePID: live?.pid,
          expectedPID: ownerPID,
          sessionOpen: sessionOpen(recordPath: recordPath, now: Date()),
          ownerAlive: ownerLockHeld(at: directoryURL + "/owner.lock"))
      else { return }
      var byte: UInt8 = 1
      if write(fd, &byte, 1) != 1 { return }
      usleep(1_000_000)
    }
  }
}
