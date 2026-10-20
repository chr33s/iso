import Foundation

/// Chooses the host for one new connected allocation. Injected into the
/// pool reconciler so tests and alternative fairness keys can be supplied;
/// budget and qualification filtering live in `HostPlacement`.
package protocol PlacementPolicy: Sendable {
  func choose(
    candidates: [Name], profile: ResolvedProfile, configuration: CIConfiguration,
    store: ControllerStore, fairnessKey: String, now: EpochSeconds
  ) throws(CIError) -> (choice: Name?, refusals: [PlacementRefusal])
}

/// Delegates to the shared deterministic filter-and-select.
package struct DefaultPlacementPolicy: PlacementPolicy {
  package init() {}

  package func choose(
    candidates: [Name], profile: ResolvedProfile, configuration: CIConfiguration,
    store: ControllerStore, fairnessKey: String, now: EpochSeconds
  ) throws(CIError) -> (choice: Name?, refusals: [PlacementRefusal]) {
    try HostPlacement.select(
      candidates: candidates, profile: profile, configuration: configuration, store: store,
      fairnessKey: fairnessKey, now: now)
  }
}
