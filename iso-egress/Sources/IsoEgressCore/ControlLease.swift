import Darwin
import Synchronization

/// A private renewal pipe, shared by the listener and tunnel workers. The
/// caller owns the descriptor and must keep it open for this lease's lifetime.
public final class ControlLease: Sendable {
  private struct State: Sendable {
    var lastRenewal: UInt64
    var revoked = false
  }

  private let descriptor: Int32
  private let state: Mutex<State>
  private let limit = Monotonic.nanoseconds(EgressBudgets.lease)

  public convenience init(descriptor: Int32) {
    self.init(descriptor: descriptor, startedAt: Monotonic.now())
  }

  init(descriptor: Int32, startedAt: UInt64) {
    self.descriptor = descriptor
    state = Mutex(State(lastRenewal: startedAt))
  }

  public func alive() -> Bool {
    state.withLock { probe(at: Monotonic.now(), state: &$0) }
  }

  func alive(at now: UInt64) -> Bool {
    state.withLock { probe(at: now, state: &$0) }
  }

  private func probe(at now: UInt64, state: inout State) -> Bool {
    // A queued byte cannot revive an expired grant after a scheduling pause.
    guard !state.revoked, descriptor >= 0,
      Monotonic.within(state.lastRenewal, now: now, limit: limit)
    else {
      state.revoked = true
      return false
    }
    var events = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
    let ready = poll(&events, 1, 0)
    if ready < 0 {
      if errno == EINTR { return true }
      state.revoked = true
      return false
    }
    if events.revents & (Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)) != 0 {
      state.revoked = true
      return false
    }
    if events.revents & Int16(POLLIN) != 0 {
      var byte: UInt8 = 0
      let count = read(descriptor, &byte, 1)
      if count < 0 && errno == EINTR { return true }
      guard count == 1, byte == 1 else {
        state.revoked = true
        return false
      }
      state.lastRenewal = now
    }
    return true
  }
}
