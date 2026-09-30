import IsoProxyCore

/// An owner-controlled qualification profile (§8.5, §11.1).
public struct QualificationProfile: Sendable, Equatable {
  public let name: String
  public let backendProtocol: BackendProtocol
  public let evidence: CompletionEvidence
  /// `stream-close` only: how long a closed stream holds its slot.
  public let streamCloseDrainMilliseconds: Int
  public let contextOverflow: ContextOverflow
  public let overheadPerRequestBytes: Int
  public let overheadPerMessageBytes: Int
  public let maxInputBytes: Int
  public let maxRequestBodyBytes: Int
  public let tokenCounter: TokenCounter

  public init(
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
public struct BackendID: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let port: UInt16
  public init(port: UInt16) { self.port = port }
  public var description: String { "127.0.0.1:\(port)" }
  public static func < (a: BackendID, b: BackendID) -> Bool { a.port < b.port }
}

public struct BackendPolicy: Sendable, Equatable {
  public let id: BackendID
  public let name: String
  public let maxActive: Int
  public let profile: QualificationProfile
  /// A host-resolved bearer credential for the backend, if it needs one.
  public let credential: Secret?

  public init(
    id: BackendID, name: String, maxActive: Int, profile: QualificationProfile, credential: Secret?
  ) {
    self.id = id
    self.name = name
    self.maxActive = maxActive
    self.profile = profile
    self.credential = credential
  }

  public static func == (a: BackendPolicy, b: BackendPolicy) -> Bool {
    a.id == b.id && a.name == b.name && a.maxActive == b.maxActive && a.profile == b.profile
      && a.credential?.expose() == b.credential?.expose()
  }
}

/// One service alias a session may use.
public struct ServiceGrant: Sendable, Equatable {
  public let alias: String
  public let backend: BackendPolicy
  public let upstreamModel: String
  public let apis: Set<FrontendAPI>
  public let maxContextTokens: Int
  public let defaultOutputTokens: Int
  public let maxOutputTokens: Int
  /// Service tightening of the profile's bound; the effective bound is the
  /// smaller.
  public let maxInputBytes: Int?

  public init(
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

  public var effectiveMaxInputBytes: Int {
    min(maxInputBytes ?? .max, backend.profile.maxInputBytes)
  }
  public var maxRequestBodyBytes: Int { backend.profile.maxRequestBodyBytes }
}

/// Gateway-wide budgets. A registration may tighten, never loosen, the
/// running gateway's values.
public struct GlobalLimits: Sendable, Equatable {
  public var maxActiveRequests: Int
  public var maxQueuedRequests: Int
  public var maxRequestBufferBytes: Int

  public init(maxActiveRequests: Int, maxQueuedRequests: Int, maxRequestBufferBytes: Int) {
    self.maxActiveRequests = maxActiveRequests
    self.maxQueuedRequests = maxQueuedRequests
    self.maxRequestBufferBytes = maxRequestBufferBytes
  }

  public static let defaults = GlobalLimits(
    maxActiveRequests: 2, maxQueuedRequests: 32, maxRequestBufferBytes: 64 << 20)

  public func tightened(by other: GlobalLimits) -> GlobalLimits {
    GlobalLimits(
      maxActiveRequests: min(maxActiveRequests, other.maxActiveRequests),
      maxQueuedRequests: min(maxQueuedRequests, other.maxQueuedRequests),
      maxRequestBufferBytes: min(maxRequestBufferBytes, other.maxRequestBufferBytes))
  }
}

/// Fixed per-session and timing budgets (§9.1). Not configurable in this
/// release; status reports them.
public enum SessionLimits {
  public static let connections = 16
  public static let sharedConnections = 128
  public static let headerBytes = 32 * 1024
  public static let headerFields = 64
  public static let jsonDepth = 32
  public static let queuedPerSession = 8
  public static let requestsPerMinute = 30
  public static let requestBurst = 8
  public static let generatedTokensPerMinute = 32_768
  public static let queueWaitSeconds = 300
  public static let headerReadSeconds = 5
  public static let bodyReadSeconds = 15
  public static let firstOutputSeconds = 120
  public static let generationSeconds = 300
  public static let responseBytes = 16 << 20
  public static let cancellationGraceSeconds = 5
  /// Queued streaming clients get a keep-alive comment this often.
  public static let keepAliveSeconds = 10
  /// Failed authentications per listener per minute before new
  /// connections are closed unread.
  public static let authFailuresPerMinute = 20
}

/// A boot of one VM: the sandbox owner process and its start time.
public struct BootIdentity: Sendable, Equatable {
  public let ownerPID: Int32
  public let ownerStart: ProcessStart

  public init(ownerPID: Int32, ownerStart: ProcessStart) {
    self.ownerPID = ownerPID
    self.ownerStart = ownerStart
  }
}

/// A process start time as the kernel reports it; with the PID it names one
/// process, even after the PID is reused.
public struct ProcessStart: Sendable, Equatable, CustomStringConvertible {
  public let seconds: UInt64
  public let microseconds: UInt64

  public init(seconds: UInt64, microseconds: UInt64) {
    self.seconds = seconds
    self.microseconds = microseconds
  }

  public var description: String { "\(seconds).\(microseconds)" }
}

/// The transport process a session is bound to at activation (§12.3).
public struct TransportBinding: Sendable, Equatable {
  public let pid: Int32
  public let start: ProcessStart

  public init(pid: Int32, start: ProcessStart) {
    self.pid = pid
    self.start = start
  }
}
