import Darwin
import Foundation

/// A private renewal pipe, shared by the listener and tunnel workers. The
/// caller owns the descriptor and must keep it open for this lease's lifetime.
public final class ControlLease: @unchecked Sendable {
  private let descriptor: Int32
  private let lock = NSLock()
  private var lastRenewal: UInt64
  private var revoked = false
  private let limit = Monotonic.nanoseconds(EgressBudgets.lease)

  public convenience init(descriptor: Int32) {
    self.init(descriptor: descriptor, startedAt: Monotonic.now())
  }

  init(descriptor: Int32, startedAt: UInt64) {
    self.descriptor = descriptor
    lastRenewal = startedAt
  }

  public func alive() -> Bool {
    lock.withLock { probe(at: Monotonic.now()) }
  }

  func alive(at now: UInt64) -> Bool {
    lock.withLock { probe(at: now) }
  }

  private func probe(at now: UInt64) -> Bool {
    // A queued byte cannot revive an expired grant after a scheduling pause.
    guard !revoked, descriptor >= 0,
      Monotonic.within(lastRenewal, now: now, limit: limit)
    else {
      revoked = true
      return false
    }
    var events = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let ready = poll(&events, 1, 0)
    if ready < 0 {
      if errno == EINTR { return true }
      revoked = true
      return false
    }
    if events.revents & (Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)) != 0 {
      revoked = true
      return false
    }
    if events.revents & Int16(POLLIN) != 0 {
      var byte: UInt8 = 0
      let count = read(descriptor, &byte, 1)
      if count < 0 && errno == EINTR { return true }
      guard count == 1, byte == 1 else {
        revoked = true
        return false
      }
      lastRenewal = now
    }
    return true
  }
}
