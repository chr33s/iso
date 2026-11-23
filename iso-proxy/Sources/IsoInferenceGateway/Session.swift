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
