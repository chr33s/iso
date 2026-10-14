import Foundation
import IsoPolicy
import IsoProxyCore
import NIOHTTP1
import Synchronization

/// The policy check for every admitted provider request (startup version 3).
/// One per proxy process, shared by every connection and event loop: the
/// clock read, the static check, and the quota check-and-insert happen in
/// one short critical section with no I/O, logging or suspension inside it.
package final class ProviderAuthorizer: Sendable {
  package enum Disposition: Sendable, Equatable {
    case forward
    case refuse(HTTPResponseStatus, retryAfter: Int?)
  }

  private let mode: PolicyMode
  private let state: Mutex<ProviderAdmissions>
  private let clock: any MonotonicClock
  private let diagnostics: PolicyDiagnostics

  /// Nil when the startup document carries no authorization block.
  package convenience init?(config: ProxyConfig) {
    self.init(config: config, clock: SystemMonotonicClock(), log: PolicyDiagnostics.standardError)
  }

  init?(
    config: ProxyConfig, clock: any MonotonicClock, log: @escaping @Sendable (String) -> Void
  ) {
    guard let authorization = config.authorization else { return nil }
    mode = authorization.policy.mode
    // Shadow mode simulates on this state only; it never changes a request.
    state = Mutex(
      ProviderAdmissions(
        policy: authorization.policy, provider: authorization.resource,
        instance: authorization.instanceName, epoch: authorization.policyEpoch))
    self.clock = clock
    diagnostics = PolicyDiagnostics(clock: clock, log: log)
  }

  /// Called after authentication, hard request checks and capacity
  /// admission, before `100 Continue` or forwarding the head.
  package func authorize() -> Disposition {
    let decisionID = UUID().uuidString.lowercased()
    let decision = state.withLock { admissions in
      admissions.checkAndAdmit(now: clock.nanoseconds(), decisionID: decisionID)
    }
    diagnostics.record(decision, shadow: mode == .shadow)
    guard mode == .enforce else { return .forward }
    switch decision.verdict {
    case .allow, .notGoverned: return .forward
    case .deny:
      switch decision.reason {
      case .explicitForbid, .noPermit: return .refuse(.forbidden, retryAfter: nil)
      case .quotaExceeded: return .refuse(.tooManyRequests, retryAfter: decision.retryAfterSeconds)
      default: return .refuse(.serviceUnavailable, retryAfter: nil)
      }
    }
  }
}

/// Bounded denial diagnostics on the host-owned proxy log (stderr). Lines
/// carry host-configured rule/guard IDs and reasons, never request content.
/// Past the budget, lines are dropped and the count is reported later.
final class PolicyDiagnostics: Sendable {
  static let linesPerMinute = 60
  private struct Budget {
    var windowStart: UInt64 = 0
    var lines = 0
    var dropped = 0
  }
  private let budget = Mutex(Budget())
  private let clock: any MonotonicClock
  private let log: @Sendable (String) -> Void

  init(clock: any MonotonicClock, log: @escaping @Sendable (String) -> Void) {
    self.clock = clock
    self.log = log
  }

  static let standardError: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  func record(_ decision: PolicyDecision, shadow: Bool) {
    guard decision.verdict == .deny else { return }
    let now = clock.nanoseconds() ?? 0
    let (emit, dropped) = budget.withLock { budget -> (Bool, Int) in
      if now &- budget.windowStart >= 60_000_000_000 || now < budget.windowStart {
        let dropped = budget.dropped
        budget = Budget(windowStart: now, lines: 1, dropped: 0)
        return (true, dropped)
      }
      guard budget.lines < Self.linesPerMinute else {
        budget.dropped += 1
        return (false, 0)
      }
      budget.lines += 1
      return (true, 0)
    }
    if dropped > 0 {
      log("iso-proxy policy: \(dropped) decision lines dropped (degraded diagnostics)")
    }
    guard emit else { return }
    var line =
      "iso-proxy policy\(shadow ? " shadow (hypothetical)" : ""): decision=\(decision.decisionID) verdict=\(decision.verdict.rawValue) reason=\(decision.reason.rawValue) digest=\(decision.policyDigest)"
    if !decision.failedGuardIDs.isEmpty {
      line += " failed_guards=\(decision.failedGuardIDs.joined(separator: ","))"
    }
    if !decision.matchedForbidIDs.isEmpty {
      line += " forbids=\(decision.matchedForbidIDs.joined(separator: ","))"
    }
    log(line)
  }
}
