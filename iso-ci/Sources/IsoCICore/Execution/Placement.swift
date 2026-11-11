import Foundation

/// Resource use attributed to one host from the controller's own records.
/// Starting, ready, assigned, retained, exporting, uncertain and
/// cleanup-debt allocations all count until cleanup is verified.
package struct HostLoad: Sendable, Equatable {
  package var vms: UInt32 = 0
  package var cpus: UInt32 = 0
  package var memoryMiB: UInt64 = 0
  package var diskGiB: UInt64 = 0
  package var uncertain: UInt32 = 0

  package init() {}

  package mutating func add(_ reservation: ResourceReservation) {
    vms += 1
    cpus += reservation.cpus
    memoryMiB += reservation.memoryMiB
    diskGiB += reservation.diskGiB
  }

  package static func of(_ allocations: [AllocationRecord]) -> HostLoad {
    var usage = HostLoad()
    for allocation in allocations where allocation.holdsResources {
      usage.add(allocation.reservation)
      if allocation.uncertainty != nil || allocation.vmCleanup == .debt { usage.uncertain += 1 }
    }
    return usage
  }

  package func admits(_ reservation: ResourceReservation, budget: HostBudget?, slots: UInt64)
    -> Bool
  {
    if slots > 0, UInt64(vms) + 1 > slots { return false }
    guard let budget else { return true }
    return vms + 1 <= budget.maxVMs && cpus + reservation.cpus <= budget.cpus
      && memoryMiB + reservation.memoryMiB <= budget.memoryMiB
      && diskGiB + reservation.diskGiB <= budget.diskGiB
  }
}

package struct PlacementRefusal: Sendable, Equatable {
  package let host: Name
  package let reason: String
  /// True when only capacity is missing (budgets or slots); false when the
  /// host is not eligible at all (disabled, unqualified, no handoff).
  package var capacity = false
}

/// Deterministic filter-and-select across enrolled hosts (spec section 5):
/// require enablement, current NET-HANDOFF-1 advertisement and
/// qualification, and budgets; prefer observable image locality; then a
/// stable fair order. The host still admits physically and atomically.
package enum HostEligibility: Sendable, Equatable {
  case eligible(HostCapabilitiesSnapshot)
  case refused(PlacementRefusal)
}

package enum HostPlacement {
  /// Whether `host` may take new CI work at all (capacity aside): enabled,
  /// NET-HANDOFF-1 currently advertised, and qualified.
  package static func eligibility(_ host: Name, store: ControllerStore, now: EpochSeconds)
    throws(CIError) -> HostEligibility
  {
    guard let record = try store.host(host) else {
      return .refused(PlacementRefusal(host: host, reason: "not enabled"))
    }
    guard record.state == .enabled else {
      return .refused(
        PlacementRefusal(
          host: host, reason: record.state.rawValue, capacity: record.state == .quarantined))
    }
    guard let snapshot = record.capabilities,
      snapshot.advertised.contains(HostCapabilityName.netHandoff1.rawValue),
      snapshot.qualificationStatus == HostCapabilities.QualificationStatus.qualified.rawValue
    else {
      return .refused(
        PlacementRefusal(host: host, reason: "NET-HANDOFF-1 not currently advertised"))
    }
    if let expires = snapshot.qualificationExpiresAt, expires <= now {
      return .refused(PlacementRefusal(host: host, reason: "qualification expired"))
    }
    return .eligible(snapshot)
  }

  /// The budget CI admission uses on `host`: its configured ceiling less
  /// the owner reservation and the external use the board last observed.
  package static func effectiveBudget(
    _ host: Name, configuration: CIConfiguration, board: SchedulerBoard?
  ) -> HostBudget? {
    configuration.hosts[host].map {
      HostCapacity(budget: $0, external: board?.snapshot.external[host] ?? .none).effectiveBudget
    }
  }

  package static func select(
    candidates: [Name], profile: ResolvedProfile, configuration: CIConfiguration,
    store: ControllerStore, fairnessKey: String, now: EpochSeconds, board: SchedulerBoard? = nil
  ) throws(CIError) -> (choice: Name?, refusals: [PlacementRefusal]) {
    var eligible: [(host: Name, usage: HostLoad, budget: HostBudget?, local: Bool)] = []
    var refusals: [PlacementRefusal] = []
    let open = try store.openAllocations()
    for host in candidates {
      let snapshot: HostCapabilitiesSnapshot
      switch try eligibility(host, store: store, now: now) {
      case .eligible(let value): snapshot = value
      case .refused(let refusal):
        refusals.append(refusal)
        continue
      }
      let usage = HostLoad.of(open.filter { $0.host == host })
      let budget = effectiveBudget(host, configuration: configuration, board: board)
      guard usage.admits(profile.limits.reservation, budget: budget, slots: snapshot.retentionSlots)
      else {
        refusals.append(PlacementRefusal(host: host, reason: "budget exhausted", capacity: true))
        continue
      }
      // Reservations and drains from the shared queue bind work placed
      // outside it too.
      if let board, let budget,
        let reason = board.refusal(
          host: host, adding: profile.limits.reservation, load: usage, budget: budget)
      {
        refusals.append(PlacementRefusal(host: host, reason: reason, capacity: true))
        continue
      }
      let local = open.contains {
        $0.host == host && $0.readyAt != nil
          && $0.provenance.imageReference == profile.image.isoImage
      }
      eligible.append((host, usage, budget, local))
    }
    let ordered = eligible.sorted { a, b in
      if a.local != b.local { return a.local }
      let ra = ratio(a.usage, a.budget)
      let rb = ratio(b.usage, b.budget)
      if ra != rb { return ra < rb }
      return Digest(hashing: fairnessKey + "/" + a.host.rawValue)
        < Digest(hashing: fairnessKey + "/" + b.host.rawValue)
    }
    return (ordered.first?.host, refusals)
  }

  private static func ratio(_ usage: HostLoad, _ budget: HostBudget?) -> Double {
    guard let budget, budget.maxVMs > 0 else { return Double(usage.vms) }
    return Double(usage.vms) / Double(budget.maxVMs)
  }
}
