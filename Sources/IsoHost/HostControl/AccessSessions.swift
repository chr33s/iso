import Foundation
import IsoCore
import Synchronization

/// The volatile live-access registry for one supervisor epoch (spec 9.2–9.4).
/// Nothing here is persisted: a restart creates a new epoch and every grant
/// from the previous one is gone. Only a SHA-256 verifier of each client
/// bearer is retained.
package final class AccessSessions: Sendable {
  package struct Limits: Sendable, Equatable {
    package var leaseSeconds: UInt64
    package var maxLive: Int
    package var maxIssued: Int

    package static let standard = Limits(leaseSeconds: 30, maxLive: 64, maxIssued: 65_536)
  }

  /// What the grant was issued against; compared on every use.
  package struct Binding: Sendable, Equatable {
    package let instance: QualifiedInstance
    package let bootID: BootID
    package let policyHash: SHA256Hex
    package let generation: UInt64
    package let client: ClientLabel
    package let clientKey: SHA256Hex
    package let purpose: AccessPurpose
    package let guestHostKey: String
    package let guestUser: GuestUser
    /// The authorized key itself (public), for best-effort removal on close.
    package let clientPublicKey: ClientPublicKey
    package let filteredPolicy: FilteredGrantPolicy?
  }

  enum Phase: Sendable, Equatable {
    case live
    case closed
    case expired
  }

  struct Entry: Sendable {
    let binding: Binding
    let verifier: SHA256Hex
    let issuedAt: WireTime
    var leaseDeadline: ContinuousClock.Instant
    var leaseExpiresAt: WireTime
    let vmExpiresAt: WireTime?
    var phase: Phase
  }

  struct State: Sendable {
    var sessions: [SessionID: Entry] = [:]
  }

  package let epoch: DaemonEpoch
  private let limits: Limits
  private let clock: any HostClock
  private let state = Mutex(State())
  /// Called (outside the registry lock) with sessions whose streams must close.
  private let revoked: @Sendable ([SessionID]) -> Void

  package init(
    epoch: DaemonEpoch, clock: any HostClock, limits: Limits = .standard,
    revoked: @escaping @Sendable ([SessionID]) -> Void
  ) {
    self.epoch = epoch
    self.clock = clock
    self.limits = limits
    self.revoked = revoked
  }

  private func check(epoch expected: DaemonEpoch) throws(HostControlError) {
    guard expected == epoch else {
      throw HostControlError(
        .sessionExpired, "daemon epoch changed; open a new session after a fresh hello")
    }
  }

  /// Admits or idempotently returns a grant. `binding` was derived by the
  /// supervisor from fresh native proof, never from the request alone.
  package func open(
    _ request: AccessOpenRequest, binding: Binding, vmExpiresAt: WireTime?
  ) throws(HostControlError) -> AccessGrant {
    try check(epoch: request.expectedEpoch)
    sweep()
    let verifier = request.bearer.verifier
    let now = clock.now()
    if let expiry = vmExpiresAt, WireTime(now) >= expiry {
      throw HostControlError(.sessionExpired, "the VM's deadline has passed")
    }
    let result = state.withLock { (state) -> Result<AccessGrant, HostControlError> in
      expireLocked(&state)
      if let existing = state.sessions[request.session] {
        guard existing.binding == binding, existing.verifier == verifier else {
          return .failure(
            HostControlError(
              .sessionIdentityChanged, "session id is already bound to a different grant",
              details: ["session_id": request.session.rawValue]))
        }
        guard existing.phase == .live else {
          return .failure(
            HostControlError(
              .sessionExpired, "session is closed or expired; use a new session id",
              details: ["session_id": request.session.rawValue]))
        }
        return .success(grant(request.session, existing))
      }
      guard state.sessions.count < limits.maxIssued else {
        return .failure(
          HostControlError(.limitExceeded, "this daemon epoch has issued its maximum session ids"))
      }
      let live = state.sessions.values.filter { $0.phase == .live }
      guard live.count < limits.maxLive else {
        return .failure(HostControlError(.limitExceeded, "too many live access sessions"))
      }
      if let controller = live.first(where: {
        $0.binding.instance.instanceID == binding.instance.instanceID
          && $0.binding.bootID == binding.bootID && $0.binding.clientKey != binding.clientKey
      }) {
        return .failure(
          HostControlError(
            .sessionInUse, "another client controls this boot",
            details: ["client": controller.binding.client.rawValue]))
      }
      let entry = makeEntry(binding: binding, verifier: verifier, vmExpiresAt: vmExpiresAt)
      state.sessions[request.session] = entry
      return .success(grant(request.session, entry))
    }
    return try result.get()
  }

  /// Extends a live grant; cannot revive, move boots, change policy, or pass VM expiry.
  package func renew(
    session: SessionID, bearer: AccessBearer, epoch expected: DaemonEpoch, boot: BootID,
    policy: SHA256Hex
  ) throws(HostControlError) -> AccessGrant {
    try check(epoch: expected)
    sweep()
    let result = state.withLock { (state) -> Result<AccessGrant, HostControlError> in
      expireLocked(&state)
      guard var entry = state.sessions[session], entry.verifier == bearer.verifier else {
        return .failure(HostControlError(.sessionExpired, "unknown session"))
      }
      guard entry.binding.bootID == boot, entry.binding.policyHash == policy else {
        return .failure(
          HostControlError(.sessionIdentityChanged, "session boot or policy does not match"))
      }
      guard entry.phase == .live else {
        return .failure(HostControlError(.sessionExpired, "session is closed or expired"))
      }
      let (deadline, expiresAt) = lease(vmExpiresAt: entry.vmExpiresAt)
      entry.leaseDeadline = deadline
      entry.leaseExpiresAt = expiresAt
      state.sessions[session] = entry
      return .success(grant(session, entry))
    }
    return try result.get()
  }

  /// Idempotent close. A closed id stays recorded until the epoch ends.
  /// Returns the closed grant's binding.
  @discardableResult
  package func close(session: SessionID, bearer: AccessBearer, epoch expected: DaemonEpoch)
    throws(HostControlError) -> Binding
  {
    try check(epoch: expected)
    let result = state.withLock { (state) -> Result<(Bool, Binding), HostControlError> in
      guard var entry = state.sessions[session], entry.verifier == bearer.verifier else {
        return .failure(HostControlError(.sessionExpired, "unknown session"))
      }
      let wasLive = entry.phase == .live
      entry.phase = .closed
      state.sessions[session] = entry
      return .success((wasLive, entry.binding))
    }
    let (wasLive, binding) = try result.get()
    if wasLive { revoked([session]) }
    return binding
  }

  /// Whether a live grant on `instance` still uses `key`.
  package func keyInUse(instance: InstanceID, key: SHA256Hex) -> Bool {
    sweep()
    return state.withLock { state in
      state.sessions.values.contains {
        $0.phase == .live && $0.binding.instance.instanceID == instance
          && $0.binding.clientKey == key
      }
    }
  }

  /// Validates a relay preamble against a live grant; returns its binding.
  package func admitRelay(session: SessionID, bearer: AccessBearer, epoch expected: DaemonEpoch)
    throws(HostControlError) -> Binding
  {
    try check(epoch: expected)
    sweep()
    let result = state.withLock { (state) -> Result<Binding, HostControlError> in
      expireLocked(&state)
      guard let entry = state.sessions[session], entry.verifier == bearer.verifier,
        entry.phase == .live
      else { return .failure(HostControlError(.sessionExpired, "no live grant for this session")) }
      return .success(entry.binding)
    }
    return try result.get()
  }

  /// Whether any live grant controls `instance` (disposable-run lease).
  package func hasLiveSession(instance: InstanceID) -> Bool {
    sweep()
    return state.withLock { state in
      state.sessions.values.contains {
        $0.phase == .live && $0.binding.instance.instanceID == instance
      }
    }
  }

  package func isLive(_ session: SessionID) -> Bool {
    sweep()
    return state.withLock { state in state.sessions[session]?.phase == .live }
  }

  /// Revokes every live grant on `instance` (stop, destroy, policy loss).
  package func revoke(instance: InstanceID) {
    let ids = state.withLock { state in
      var ids: [SessionID] = []
      for (id, entry) in state.sessions
      where entry.phase == .live && entry.binding.instance.instanceID == instance {
        state.sessions[id]?.phase = .closed
        ids.append(id)
      }
      return ids
    }
    if !ids.isEmpty { revoked(ids) }
  }

  /// Marks lapsed leases expired and reports them; the supervisor calls this
  /// at sub-second cadence so relays close within the two-second budget.
  @discardableResult
  package func sweep() -> [SessionID] {
    let ids = state.withLock { state in expireLocked(&state) }
    if !ids.isEmpty { revoked(ids) }
    return ids
  }

  package var counts: (live: Int, issued: Int) {
    state.withLock { state in
      (state.sessions.values.filter { $0.phase == .live }.count, state.sessions.count)
    }
  }

  // MARK: - Locked helpers

  @discardableResult
  private func expireLocked(_ state: inout State) -> [SessionID] {
    let now = clock.monotonic()
    let wall = WireTime(clock.now())
    var expired: [SessionID] = []
    for (id, entry) in state.sessions where entry.phase == .live {
      let vmExpired = entry.vmExpiresAt.map { wall >= $0 } ?? false
      if entry.leaseDeadline <= now || vmExpired {
        state.sessions[id]?.phase = .expired
        expired.append(id)
      }
    }
    return expired
  }

  private func lease(vmExpiresAt: WireTime?) -> (ContinuousClock.Instant, WireTime) {
    let wall = WireTime(clock.now())
    var seconds = limits.leaseSeconds
    if let vmExpiresAt {
      seconds = min(
        seconds, vmExpiresAt.seconds > wall.seconds ? vmExpiresAt.seconds - wall.seconds : 0)
    }
    return (clock.monotonic() + .seconds(Int64(seconds)), wall.adding(seconds: seconds))
  }

  private func makeEntry(binding: Binding, verifier: SHA256Hex, vmExpiresAt: WireTime?) -> Entry {
    let (deadline, expiresAt) = lease(vmExpiresAt: vmExpiresAt)
    return Entry(
      binding: binding, verifier: verifier, issuedAt: WireTime(clock.now()),
      leaseDeadline: deadline, leaseExpiresAt: expiresAt, vmExpiresAt: vmExpiresAt, phase: .live)
  }

  private func grant(_ session: SessionID, _ entry: Entry) -> AccessGrant {
    AccessGrant(
      session: session, epoch: epoch, instance: entry.binding.instance,
      bootID: entry.binding.bootID, policyHash: entry.binding.policyHash,
      generation: entry.binding.generation, purpose: entry.binding.purpose,
      issuedAt: entry.issuedAt, leaseExpiresAt: entry.leaseExpiresAt,
      vmExpiresAt: entry.vmExpiresAt, guestHostKey: entry.binding.guestHostKey,
      guestUser: entry.binding.guestUser, filteredPolicy: entry.binding.filteredPolicy)
  }
}
