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

  /// What the lease has observed of its companion and egress tunnel. Each
  /// is required only once seen alive: startup spawns the lease first.
  package struct Supervision: Equatable, Sendable {
    package private(set) var companionSeen = false
    package private(set) var tunnelSeen = false

    package init() {}

    /// False once a component that was seen alive is gone.
    package mutating func holds(companionAlive: Bool, tunnelAlive: Bool) -> Bool {
      if (companionSeen && !companionAlive) || (tunnelSeen && !tunnelAlive) { return false }
      companionSeen = companionSeen || companionAlive
      tunnelSeen = tunnelSeen || tunnelAlive
      return true
    }
  }

  /// Closes the instance's persistent `ssh -L` forward master, if any, so no
  /// host-to-guest forward outlives the boot's readiness.
  package static func closeForwards(directory: String) {
    let control = directory + "/forwards.sock"
    guard FileManager.default.fileExists(atPath: control) else { return }
    _ = try? ProcessRunner().capture(
      .init(
        executable: "/usr/bin/ssh",
        arguments: ["-O", "exit", "-o", "ControlPath=\(control)", "iso-forwards"],
        environment: [:], deadline: .seconds(5), outputLimit: 64 << 10, overflow: .drain))
  }

  package static func run(
    directory: String, machineID: String, ownerPID: Int32, bootID: String, livePath: String
  ) {
    let fd: Int32 = 3
    var supervision = Supervision()
    defer { closeForwards(directory: directory) }
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
      if let instance = try? Instance.load(directory: directory),
        !supervision.holds(
          companionAlive: ProxyLauncher.recordedProcessAlive(
            ProxyLauncher.pidPath(instance, "egress"), expect: .egress),
          tunnelAlive: TunnelIdentity.verify(instance, "egress", address: nil))
      {
        return
      }
      var byte: UInt8 = 1
      if write(fd, &byte, 1) != 1 { return }
      usleep(1_000_000)
    }
  }
}
