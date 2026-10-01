import Foundation

/// Accepted sockets, established tunnels, and in-flight DNS lookups. A full
/// counter refuses the new work; nothing is queued past the cap.
public struct AdmissionState: Equatable, Sendable {
  public var sockets = 0
  public var tunnels = 0
  public var dns = 0

  public func admitSocket() -> AdmissionState? { admit(\.sockets, cap: EgressBudgets.maxSockets) }
  public func admitTunnel() -> AdmissionState? { admit(\.tunnels, cap: EgressBudgets.maxTunnels) }
  public func admitDNS() -> AdmissionState? { admit(\.dns, cap: EgressBudgets.maxDNS) }

  public func releaseSocket() -> AdmissionState { release(\.sockets) }
  public func releaseTunnel() -> AdmissionState { release(\.tunnels) }
  public func releaseDNS() -> AdmissionState { release(\.dns) }

  private func admit(_ key: WritableKeyPath<AdmissionState, Int>, cap: Int) -> AdmissionState? {
    guard self[keyPath: key] < cap else { return nil }
    var copy = self
    copy[keyPath: key] += 1
    return copy
  }

  private func release(_ key: WritableKeyPath<AdmissionState, Int>) -> AdmissionState {
    var copy = self
    copy[keyPath: key] = max(0, copy[keyPath: key] - 1)
    return copy
  }
}

public final class Admission: @unchecked Sendable {
  private let lock = NSLock()
  private var state = AdmissionState()

  public init() {}

  public func trySocket() -> Bool { change { $0.admitSocket() } }
  public func endSocket() { replace { $0.releaseSocket() } }
  public func tryTunnel() -> Bool { change { $0.admitTunnel() } }
  public func endTunnel() { replace { $0.releaseTunnel() } }
  public func tryDNS() -> Bool { change { $0.admitDNS() } }
  public func endDNS() { replace { $0.releaseDNS() } }

  private func change(_ step: (AdmissionState) -> AdmissionState?) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let next = step(state) else { return false }
    state = next
    return true
  }

  private func replace(_ step: (AdmissionState) -> AdmissionState) {
    lock.lock()
    state = step(state)
    lock.unlock()
  }
}
