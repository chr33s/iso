import IsoInferenceCore

/// The gateway's per-request deadlines (§9.1). Production uses `standard`,
/// from `SessionLimits`; tests shorten them.
package struct GatewayTiming: Sendable {
  package var headerRead: Duration = .seconds(SessionLimits.headerReadSeconds)
  package var bodyRead: Duration = .seconds(SessionLimits.bodyReadSeconds)
  package var queueWait: Duration = .seconds(SessionLimits.queueWaitSeconds)
  package var firstOutput: Duration = .seconds(SessionLimits.firstOutputSeconds)
  package var backendProof: Duration = .seconds(SessionLimits.backendProofSeconds)
  package var generation: Duration = .seconds(SessionLimits.generationSeconds)
  package var cancellationGrace: Duration = .seconds(SessionLimits.cancellationGraceSeconds)
  package var keepAlive: Duration = .seconds(SessionLimits.keepAliveSeconds)
  /// How long a finished response may take to flush before its socket is
  /// closed anyway.
  package var close: Duration = .seconds(SessionLimits.closeSeconds)

  package init() {}

  package static let standard = GatewayTiming()
}
