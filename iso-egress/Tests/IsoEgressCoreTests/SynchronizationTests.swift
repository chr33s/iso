import Dispatch
import Synchronization
import Testing

@testable import IsoEgressCore

private enum AdmissionKind: Sendable, CaseIterable {
  case socket, tunnel, dns

  var cap: Int {
    switch self {
    case .socket: EgressBudgets.maxSockets
    case .tunnel: EgressBudgets.maxTunnels
    case .dns: EgressBudgets.maxDNS
    }
  }

  func admit(_ admission: Admission) -> Bool {
    switch self {
    case .socket: admission.trySocket()
    case .tunnel: admission.tryTunnel()
    case .dns: admission.tryDNS()
    }
  }

  func release(_ admission: Admission) {
    switch self {
    case .socket: admission.endSocket()
    case .tunnel: admission.endTunnel()
    case .dns: admission.endDNS()
    }
  }
}

@Test(arguments: AdmissionKind.allCases)
private func concurrentAdmissionEnforcesAndRefillsEachLimit(kind: AdmissionKind) {
  let admission = Admission()
  for _ in 0..<3 {
    let accepted = Mutex(0)
    DispatchQueue.concurrentPerform(iterations: kind.cap * 4) { _ in
      if kind.admit(admission) { accepted.withLock { $0 += 1 } }
    }
    #expect(accepted.withLock { $0 } == kind.cap)
    #expect(!kind.admit(admission))
    DispatchQueue.concurrentPerform(iterations: kind.cap) { _ in kind.release(admission) }
  }
}

@Test func concurrentRelayReservationsNeverExceedTheAggregateBudget() {
  let budget = RelayBudget(cap: 1024)
  for _ in 0..<3 {
    let reservations = Mutex<[Int]>([])
    DispatchQueue.concurrentPerform(iterations: 1024) { _ in
      let reserved = budget.reserve(3)
      reservations.withLock { $0.append(reserved) }
    }
    let held = reservations.withLock { $0 }
    #expect(held.reduce(0, +) == budget.cap)
    #expect(held.allSatisfy { (0...3).contains($0) })
    #expect(budget.available == 0)
    DispatchQueue.concurrentPerform(iterations: held.count) { index in budget.release(held[index]) }
    #expect(budget.available == budget.cap)
  }
}
