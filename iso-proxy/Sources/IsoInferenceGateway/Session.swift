import Dispatch
import IsoInferenceCore
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import Synchronization

/// One VM boot session: its own listener, capability and grants (§5.2).
/// A request on this session's listener is judged only against this
/// session's state, whatever token it presents.
package final class GatewaySession: Sendable {
  package enum Phase: Sendable, Equatable {
    case inactive
    case active
    case revoked(String)

    var name: String {
      switch self {
      case .inactive: "inactive"
      case .active: "active"
      case .revoked: "revoked"
      }
    }
  }

  struct State {
    var phase: Phase = .inactive
    var transport: TransportBinding?
    var deadline: ContinuousClock.Instant?
    /// Exit watches on the bound process and, for a forward, the owner.
    var watches: [ExitWatch] = []
    var listener: Channel?
    var socket: BoundSocket?
    var channels: [ObjectIdentifier: Channel] = [:]
  }

  package let id: String
  package let instance: ControlProtocol.InstanceKey
  package let boot: BootIdentity
  /// Which process activation may bind (§22).
  package let transportKind: TransportKind
  package let nonce: String
  package let policyDigest: String
  package let grants: [String: ServiceGrant]
  package let apis: Set<FrontendAPI>
  package let registered: ContinuousClock.Instant
  /// The registration's socket file name in the relay directory.
  package let socketName: String
  let capability: Capability
  package let connections = SlotPool(SessionLimits.connections)
  /// This session's share of the gateway's request-buffer budget (§9.1).
  package let buffers = ByteBudget(SessionLimits.requestBufferBytesPerSession)
  let failures: FailureWindow
  let state = Mutex(State())

  init(
    id: String, registration: ControlProtocol.Registration, capability: Capability,
    registered: ContinuousClock.Instant, failures: FailureWindow
  ) {
    self.id = id
    instance = registration.instance
    boot = registration.boot
    transportKind = registration.transport
    nonce = registration.nonce
    policyDigest = registration.policyDigest
    grants = Dictionary(uniqueKeysWithValues: registration.grants.map { ($0.alias, $0) })
    apis = Set(registration.grants.flatMap(\.apis))
    socketName = registration.socket
    self.capability = capability
    self.registered = registered
    self.failures = failures
  }

  package var phase: Phase { state.withLock { $0.phase } }
  /// The bound session socket, until revocation.
  package var socketPath: String? { state.withLock { $0.socket?.path } }

  /// Whether a request may be admitted now.
  func admits(at instant: ContinuousClock.Instant) -> Bool {
    state.withLock { state in
      guard state.phase == .active else { return false }
      if let deadline = state.deadline, instant >= deadline { return false }
      return true
    }
  }

  /// Activates the session bound to `binding` (§12.3, §22.4, §22.9): the
  /// registration's sandbox owner for an `owner` session, another process
  /// (the host's forward) for a `forward` one. It arms an exit watch on the
  /// bound process and, for a forward, on the owner; `onExit` runs once with
  /// the PID of the first to exit. A process that already exited cannot be
  /// watched: nothing is bound and the session stays inactive.
  func bindTransport(
    _ binding: TransportBinding, deadlineSeconds: Int64?,
    onExit: @escaping @Sendable (pid_t) -> Void
  ) throws(InferenceError) {
    try checkTransportKind(binding)
    let ownerPID = boot.ownerPID
    // The host checked these processes' identity; the gateway reads no
    // other process's information, and binds each connection to the
    // transport by its peer token instead.
    let watched = transportKind == .owner ? [binding.pid] : [binding.pid, ownerPID]
    var watches: [ExitWatch] = []
    for pid in watched {
      guard let watch = ExitWatch(pid: pid, onExit: { onExit(pid) }) else {
        for watch in watches { watch.cancel() }
        throw InferenceError(.policyDenied, "the transport process exited")
      }
      watches.append(watch)
    }
    let deadline = deadlineSeconds.map { ContinuousClock.now + .seconds($0) }
    let activated = state.withLock { state -> Bool in
      guard state.phase == .inactive else { return false }
      state.phase = .active
      state.transport = binding
      state.deadline = deadline
      state.watches = watches
      return true
    }
    guard activated else {
      for watch in watches { watch.cancel() }
      throw InferenceError(.sessionRevoked, "the session was revoked")
    }
  }

  /// The registration's sandbox owner for an `owner` session, another
  /// process (the host's forward) for a `forward` one.
  func checkTransportKind(_ binding: TransportBinding) throws(InferenceError) {
    switch transportKind {
    case .owner:
      guard binding.pid == boot.ownerPID else {
        throw InferenceError(.policyDenied, "the transport is not the registered sandbox owner")
      }
    case .forward:
      guard binding.pid != boot.ownerPID else {
        throw InferenceError(.policyDenied, "a forward session's transport is not the owner")
      }
    }
  }

  /// The broker's record of a session its worker activated: no watches here,
  /// the worker holds them. False when the session was revoked meanwhile.
  func markActive(_ binding: TransportBinding, deadlineSeconds: Int64?) -> Bool {
    let deadline = deadlineSeconds.map { ContinuousClock.now + .seconds($0) }
    return state.withLock { state in
      guard state.phase == .inactive else { return false }
      state.phase = .active
      state.transport = binding
      state.deadline = deadline
      return true
    }
  }

  /// Whether a connection's peer is the active session's bound transport,
  /// running as this user (§12.3). Before activation nothing is admitted.
  func admits(_ peer: PeerIdentity) -> Bool {
    state.withLock { state in
      guard state.phase == .active, let binding = state.transport else { return false }
      return peer.isProcess(binding, uid: getuid())
    }
  }

  func track(_ channel: Channel) -> Bool {
    let id = ObjectIdentifier(channel)
    let accepted = state.withLock { state -> Bool in
      guard !isRevoked(state.phase) else { return false }
      state.channels[id] = channel
      return true
    }
    guard accepted else { return false }
    channel.closeFuture.whenComplete { [weak self] _ in
      _ = self?.state.withLock { $0.channels.removeValue(forKey: id) }
    }
    return true
  }

  func grants(for api: FrontendAPI) -> [String: ServiceGrant] {
    grants.filter { $0.value.apis.contains(api) }
  }
}

func isRevoked(_ phase: GatewaySession.Phase) -> Bool {
  if case .revoked = phase { true } else { false }
}
