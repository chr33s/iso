import Foundation
import IsoMacProtocol

/// Who drives one VM's display (docs/design/guest-driven-computer-use.md
/// §5.4): nobody, the guest's one session, or a host hold. The host always
/// wins: a hold ends the guest session and refuses new ones until it is
/// released or expires. Pure, so the arbitration rules are unit-testable.
package struct CUControl: Sendable {
  private(set) var guestSession: String?
  private var holdUntil: Date?

  /// The hold host input takes before it sends anything.
  package static let implicitHold: TimeInterval = 60
  package static let defaultHold = 300
  package static let holdRange = 1...3600

  package init() {}

  private func holding(at now: Date) -> Bool { holdUntil.map { $0 > now } ?? false }

  package func controller(at now: Date) -> GuestCUController {
    if holding(at: now) { return .host }
    return guestSession == nil ? .idle : .guest
  }

  /// Whole seconds left on the host hold, rounded up; 0 without one.
  package func holdRemaining(at now: Date) -> Int {
    guard let holdUntil, holdUntil > now else { return 0 }
    return Int(holdUntil.timeIntervalSince(now).rounded(.up))
  }

  /// Starts or extends a host hold; returns the guest session it ends.
  package mutating func hold(for seconds: TimeInterval, at now: Date) -> String? {
    let until = now.addingTimeInterval(seconds)
    holdUntil = max(holdUntil ?? until, until)
    defer { guestSession = nil }
    return guestSession
  }

  package mutating func release() { holdUntil = nil }

  private static let held = SandboxError("the host holds computer use", refusal: .heldByHost)

  /// Makes `id` the guest's session; returns the one it replaces.
  package mutating func openGuest(_ id: String, at now: Date) throws -> String? {
    guard !holding(at: now) else { throw Self.held }
    defer { guestSession = id }
    return guestSession
  }

  /// Refuses unless `id` is the guest's live session and no hold is active.
  package func requireGuest(_ id: String?, at now: Date) throws {
    guard !holding(at: now) else { throw Self.held }
    guard let id, id == guestSession else {
      throw SandboxError("unknown session", refusal: .unknownSession)
    }
  }
}

/// A token bucket: `rate` tokens a second, up to `rate` saved.
package struct TokenBucket: Sendable {
  package let rate: Double
  private var tokens: Double
  private var last: Date

  package init(rate: Int, now: Date) {
    self.rate = Double(rate)
    tokens = Double(rate)
    last = now
  }

  /// Takes `cost` tokens if there are that many.
  package mutating func take(_ cost: Double, at now: Date) -> Bool {
    tokens = min(rate, tokens + max(0, now.timeIntervalSince(last)) * rate)
    last = now
    guard tokens >= cost else { return false }
    tokens -= cost
    return true
  }

  /// Returns `cost` tokens taken for work that was not done.
  package mutating func give(_ cost: Double) { tokens = min(rate, tokens + cost) }
}

/// The per-sandbox limits on guest requests (§5.3).
package struct GuestCULimits: Sendable {
  private var frames: TokenBucket
  private var actions: TokenBucket
  /// Every request, refused or not: refunds never apply here.
  private var requests: TokenBucket

  package init(frameRate: Int, now: Date) {
    frames = TokenBucket(rate: frameRate, now: now)
    actions = TokenBucket(rate: GuestCUProtocol.actionRate, now: now)
    requests = TokenBucket(rate: GuestCUProtocol.requestRate, now: now)
  }

  /// What `request` costs against the action limit.
  static func actionCost(_ request: GuestCURequest) -> Double {
    guard request.op == .act, request.action?.kind == "type", let text = request.action?.text
    else { return 1 }
    // At most a full second of actions: longer text (up to the 4096
    // characters `type` accepts) would otherwise never fit the bucket.
    let cost = (Double(text.count) / Double(GuestCUProtocol.typeCharactersPerAction)).rounded(.up)
    return min(Double(GuestCUProtocol.actionRate), max(1, cost))
  }

  /// Charges one line, before it is parsed: malformed lines count too.
  package mutating func admitLine(at now: Date) -> Bool { requests.take(1, at: now) }

  package mutating func admit(_ request: GuestCURequest, at now: Date) -> Bool {
    request.op == .frame
      ? frames.take(1, at: now) : actions.take(Self.actionCost(request), at: now)
  }

  /// Gives back the frame or action tokens of a request refused before it
  /// did its work: no frame captured (a blank frame was), no input sent.
  /// Without this, a session reopened after a host hold would find its
  /// retry over the frame limit.
  package mutating func settle(_ request: GuestCURequest, _ response: GuestCUResponse) {
    guard !response.ok, let refusal = response.refusal, refusal != .rateLimited,
      refusal != .blankFrame, request.op != .act || response.beforeInput == true
    else { return }
    if request.op == .frame { frames.give(1) } else { actions.give(Self.actionCost(request)) }
  }
}
