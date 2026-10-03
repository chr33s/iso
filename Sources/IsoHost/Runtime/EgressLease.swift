import Darwin
import Foundation
import IsoCore

/// Renews one filtered-egress companion while the recorded sandbox and the
/// runtime's live boot id still match. A restored disk does not restore
/// `bootId`; the next owner writes a new one.
package enum EgressLease {
  package static func stillOwns(directory: String, machineID: String, ownerPID: Int32) -> Bool {
    guard let instance = try? Instance.load(directory: directory),
      let sidecar = try? MachineSidecar.loadIfPresent(instance)
    else { return false }
    return sidecar.machineID.rawValue == machineID && sidecar.lastObservedOwnerPID == ownerPID
  }

  private struct LiveIdentity: Decodable {
    let bootId: String
    let pid: Int32
  }

  private struct SessionRecord: Decodable {
    let expiresAt: Date?
  }

  package static func liveIdentity(at path: String) -> (bootID: String, pid: Int32)? {
    guard let bytes = try? StateStore.readControlFile(path),
      let live = try? JSONDecoder().decode(LiveIdentity.self, from: Data(bytes)),
      live.pid > 0, !live.bootId.isEmpty
    else { return nil }
    return (live.bootId, live.pid)
  }

  /// A missing/unreadable record or invalid deadline is closed. Only an
  /// absent or null `expiresAt` means the session has no TTL.
  package static func sessionOpen(recordPath: String, now: Date) -> Bool {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let bytes = try? StateStore.readControlFile(recordPath),
      let record = try? decoder.decode(SessionRecord.self, from: Data(bytes))
    else { return false }
    guard let deadline = record.expiresAt else { return true }
    return now < deadline
  }

  /// Only non-blocking lock contention proves an owner may hold the lock;
  /// successful acquisition, open failure, or any other probe error is closed.
  package static func ownerLockHeld(at path: String) -> Bool {
    let fd = open(path, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
      _ = flock(fd, LOCK_UN)
      return false
    }
    return errno == EWOULDBLOCK || errno == EAGAIN
  }

  /// The recorded identity, live boot, session deadline, and owner lock must
  /// all still match. A leftover `live.json` is not enough.
  package static func renewalAllowed(
    ownsRecordedIdentity: Bool, liveBootID: String?, expectedBootID: String, livePID: Int32?,
    expectedPID: Int32, sessionOpen: Bool, ownerAlive: Bool
  ) -> Bool {
    ownsRecordedIdentity && liveBootID == expectedBootID && !expectedBootID.isEmpty
      && livePID == expectedPID && sessionOpen && ownerAlive
  }

  package static func run(
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
