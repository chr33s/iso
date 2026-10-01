import Dispatch
import IsoInferenceCore
import IsoProxyCore
import NIOConcurrencyHelpers
import NIOCore
import Synchronization

/// One VM boot session: its own listener, capability and grants (§5.2).
/// A request on this session's listener is judged only against this
/// session's state, whatever token it presents.
public final class GatewaySession: Sendable {
  public enum Phase: Sendable, Equatable {
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
    var watch: DispatchSourceProcess?
    var listener: Channel?
    var socketPath: String?
    var channels: [ObjectIdentifier: Channel] = [:]
  }

  public let id: String
  public let instance: ControlProtocol.InstanceKey
  public let boot: BootIdentity
  public let nonce: String
  public let policyDigest: String
  public let grants: [String: ServiceGrant]
  public let apis: Set<FrontendAPI>
  public let registered: ContinuousClock.Instant
  let capability: Capability
  let connections = SlotPool(SessionLimits.connections)
  let failures = FailureWindow(limit: SessionLimits.authFailuresPerMinute)
  let state = Mutex(State())

  init(
    id: String, registration: ControlProtocol.Registration, capability: Capability,
    registered: ContinuousClock.Instant
  ) {
    self.id = id
    instance = registration.instance
    boot = registration.boot
    nonce = registration.nonce
    policyDigest = registration.policyDigest
    grants = Dictionary(uniqueKeysWithValues: registration.grants.map { ($0.alias, $0) })
    apis = Set(registration.grants.flatMap(\.apis))
    self.capability = capability
    self.registered = registered
  }

  public var phase: Phase { state.withLock { $0.phase } }
  /// The bound session socket, until revocation.
  public var socketPath: String? { state.withLock { $0.socketPath } }

  /// Whether a request may be admitted now.
  func admits(at instant: ContinuousClock.Instant) -> Bool {
    state.withLock { state in
      guard state.phase == .active else { return false }
      if let deadline = state.deadline, instant >= deadline { return false }
      return true
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
