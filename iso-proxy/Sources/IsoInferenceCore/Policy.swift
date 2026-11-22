import IsoProxyCore

/// An owner-controlled qualification profile (§8.5, §11.1).
package struct QualificationProfile: Sendable, Equatable {
  package let name: String
  package let backendProtocol: BackendProtocol
  package let evidence: CompletionEvidence
  /// `stream-close` only: how long a closed stream holds its slot.
  package let streamCloseDrainMilliseconds: Int
  package let contextOverflow: ContextOverflow
  package let overheadPerRequestBytes: Int
  package let overheadPerMessageBytes: Int
  package let maxInputBytes: Int
  package let maxRequestBodyBytes: Int
  package let tokenCounter: TokenCounter

  package init(
    name: String, backendProtocol: BackendProtocol, evidence: CompletionEvidence,
    streamCloseDrainMilliseconds: Int, contextOverflow: ContextOverflow,
    overheadPerRequestBytes: Int, overheadPerMessageBytes: Int, maxInputBytes: Int,
    maxRequestBodyBytes: Int, tokenCounter: TokenCounter
  ) {
    self.name = name
    self.backendProtocol = backendProtocol
    self.evidence = evidence
    self.streamCloseDrainMilliseconds = streamCloseDrainMilliseconds
    self.contextOverflow = contextOverflow
    self.overheadPerRequestBytes = overheadPerRequestBytes
    self.overheadPerMessageBytes = overheadPerMessageBytes
    self.maxInputBytes = maxInputBytes
    self.maxRequestBodyBytes = maxRequestBodyBytes
    self.tokenCounter = tokenCounter
  }
}

/// A backend's identity is its loopback port: two configuration entries or
/// aliases naming the same port share one concurrency limit (§9.1).
package struct BackendID: Sendable, Hashable, Comparable, CustomStringConvertible {
  package let port: UInt16
  package init(port: UInt16) { self.port = port }
  package var description: String { "127.0.0.1:\(port)" }
  package static func < (a: BackendID, b: BackendID) -> Bool { a.port < b.port }
}

package struct BackendPolicy: Sendable, Equatable {
  package let id: BackendID
  package let name: String
  package let maxActive: Int
  package let profile: QualificationProfile
  /// A host-resolved bearer credential for the backend, if it needs one.
  package let credential: Secret?

  package init(
    id: BackendID, name: String, maxActive: Int, profile: QualificationProfile, credential: Secret?
  ) {
    self.id = id
    self.name = name
    self.maxActive = maxActive
    self.profile = profile
    self.credential = credential
  }

  package static func == (a: BackendPolicy, b: BackendPolicy) -> Bool {
    a.id == b.id && a.name == b.name && a.maxActive == b.maxActive && a.profile == b.profile
      && a.credential?.expose() == b.credential?.expose()
  }
}

/// One service alias a session may use.
package struct ServiceGrant: Sendable, Equatable {
  package let alias: String
  package let backend: BackendPolicy
  package let upstreamModel: String
  package let apis: Set<FrontendAPI>
  package let maxContextTokens: Int
  package let defaultOutputTokens: Int
  package let maxOutputTokens: Int
  /// Service tightening of the profile's bound; the effective bound is the
  /// smaller.
  package let maxInputBytes: Int?

  package init(
    alias: String, backend: BackendPolicy, upstreamModel: String, apis: Set<FrontendAPI>,
    maxContextTokens: Int, defaultOutputTokens: Int, maxOutputTokens: Int, maxInputBytes: Int?
  ) {
    self.alias = alias
    self.backend = backend
    self.upstreamModel = upstreamModel
    self.apis = apis
    self.maxContextTokens = maxContextTokens
    self.defaultOutputTokens = defaultOutputTokens
    self.maxOutputTokens = maxOutputTokens
    self.maxInputBytes = maxInputBytes
  }

  package var effectiveMaxInputBytes: Int {
    min(maxInputBytes ?? .max, backend.profile.maxInputBytes)
  }
  package var maxRequestBodyBytes: Int { backend.profile.maxRequestBodyBytes }
}

/// Gateway-wide budgets. A registration may tighten, never loosen, the
/// running gateway's values.
package struct GlobalLimits: Sendable, Equatable {
  package var maxActiveRequests: Int
  package var maxQueuedRequests: Int
  package var maxRequestBufferBytes: Int

  package init(maxActiveRequests: Int, maxQueuedRequests: Int, maxRequestBufferBytes: Int) {
    self.maxActiveRequests = maxActiveRequests
    self.maxQueuedRequests = maxQueuedRequests
    self.maxRequestBufferBytes = maxRequestBufferBytes
  }

  package static let defaults = GlobalLimits(
    maxActiveRequests: 2, maxQueuedRequests: 32, maxRequestBufferBytes: 64 << 20)

  package func tightened(by other: GlobalLimits) -> GlobalLimits {
    GlobalLimits(
      maxActiveRequests: min(maxActiveRequests, other.maxActiveRequests),
      maxQueuedRequests: min(maxQueuedRequests, other.maxQueuedRequests),
      maxRequestBufferBytes: min(maxRequestBufferBytes, other.maxRequestBufferBytes))
  }
}

/// Fixed per-session and timing budgets (§9.1). Not configurable in this
/// release; status reports them.
package enum SessionLimits {
  package static let connections = 16
  /// Each session's share of the shared request-buffer budget; also the
  /// largest request body a grant may declare, so one request always fits.
  package static let requestBufferBytesPerSession = 16 << 20
  /// A finished response's socket closes after this long, flushed or not.
  package static let closeSeconds = 10
  /// Open descriptors the gateway may need: every shared connection and its
  /// upstream socket, session listeners, the control socket, the journal,
  /// the audit log and a reserve.
  package static let descriptors = 1024
  package static let sharedConnections = 128
  /// Guest connections the sandbox runtime relays to one session at once.
  package static let relayedConnections = 32
  /// Guest connections one brokered forward session may hold at once,
  /// accepted or pending (§22.9), the relay's cap: the session's own
  /// `connections` accepted, and a listen backlog of the rest. Neither the
  /// host `ssh` nor the gateway holds more for one forward.
  package static let forwardedConnections = 32
  package static let headerBytes = 32 * 1024
  package static let headerFields = 64
  package static let jsonDepth = 32
  package static let queuedPerSession = 8
  package static let requestsPerMinute = 30
  package static let requestBurst = 8
  package static let generatedTokensPerMinute = 32_768
  package static let queueWaitSeconds = 300
  package static let headerReadSeconds = 5
  package static let bodyReadSeconds = 15
  package static let firstOutputSeconds = 120
  package static let generationSeconds = 300
  package static let responseBytes = 16 << 20
  package static let cancellationGraceSeconds = 5
  /// Queued streaming clients get a keep-alive comment this often.
  package static let keepAliveSeconds = 10
  /// Failed authentications per listener per minute before new
  /// connections are closed unread.
  package static let authFailuresPerMinute = 20
}

/// A boot of one VM: the sandbox owner process and its start time.
package struct BootIdentity: Sendable, Equatable {
  package let ownerPID: Int32
  package let ownerStart: ProcessStart

  package init(ownerPID: Int32, ownerStart: ProcessStart) {
    self.ownerPID = ownerPID
    self.ownerStart = ownerStart
  }
}

/// A process start time as the kernel reports it; with the PID it names one
/// process, even after the PID is reused.
package struct ProcessStart: Sendable, Equatable, CustomStringConvertible {
  package let seconds: UInt64
  package let microseconds: UInt64

  package init(seconds: UInt64, microseconds: UInt64) {
    self.seconds = seconds
    self.microseconds = microseconds
  }

  package var description: String { "\(seconds).\(microseconds)" }
}

/// Which process carries a session's guest connections to its socket
/// (§22), declared at registration: it fixes the process activation may bind.
package enum TransportKind: String, Sendable, Equatable, CaseIterable {
  /// The sandbox owner relays the socket into the guest over vsock (the vmnet
  /// transport): activation binds the registration's boot identity itself.
  case owner
  /// The host's `ssh` reverse forward connects guest connections to the
  /// socket (the brokered transport): activation binds that forward process,
  /// and the registration's sandbox owner must still be running.
  case forward
}

/// The transport process a session is bound to at activation (§12.3).
package struct TransportBinding: Sendable, Equatable {
  package let pid: Int32
  package let start: ProcessStart

  package init(pid: Int32, start: ProcessStart) {
    self.pid = pid
    self.start = start
  }
}
