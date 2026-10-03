import Synchronization

/// Accepted sockets, established tunnels, and in-flight DNS lookups. A full
/// counter refuses the new work; nothing is queued past the cap.
package struct AdmissionState: Equatable, Sendable {
  package var sockets = 0
  package var tunnels = 0
  package var dns = 0

  package func admitSocket() -> AdmissionState? { admit(\.sockets, cap: EgressBudgets.maxSockets) }
  package func admitTunnel() -> AdmissionState? { admit(\.tunnels, cap: EgressBudgets.maxTunnels) }
  package func admitDNS() -> AdmissionState? { admit(\.dns, cap: EgressBudgets.maxDNS) }

  package func releaseSocket() -> AdmissionState { release(\.sockets) }
  package func releaseTunnel() -> AdmissionState { release(\.tunnels) }
  package func releaseDNS() -> AdmissionState { release(\.dns) }

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

package final class Admission: Sendable {
  private let state = Mutex(AdmissionState())

  package init() {}

  package func trySocket() -> Bool { change { $0.admitSocket() } }
  package func endSocket() { replace { $0.releaseSocket() } }
  package func tryTunnel() -> Bool { change { $0.admitTunnel() } }
  package func endTunnel() { replace { $0.releaseTunnel() } }
  package func tryDNS() -> Bool { change { $0.admitDNS() } }
  package func endDNS() { replace { $0.releaseDNS() } }

  private func change(_ step: (AdmissionState) -> AdmissionState?) -> Bool {
    state.withLock { state in
      guard let next = step(state) else { return false }
      state = next
      return true
    }
  }

  private func replace(_ step: (AdmissionState) -> AdmissionState) {
    state.withLock { $0 = step($0) }
  }
}
