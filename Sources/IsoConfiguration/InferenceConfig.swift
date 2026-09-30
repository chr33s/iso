import IsoCore

/// `inference` (secure-local-inference spec §11): host-side local models
/// exposed to VMs through the `iso-inference` gateway. The gateway
/// re-validates everything it receives; these types make an invalid
/// configuration fail at load time.
public struct InferenceConfig: Sendable, Equatable {
  public let mode: InferenceMode
  public let globalLimits: InferenceGlobalLimits
  public let profiles: [String: QualificationProfileConfig]
  public let backends: [String: InferenceBackendConfig]
  public let services: [InferenceServiceName: InferenceServiceConfig]

  public init(
    mode: InferenceMode, globalLimits: InferenceGlobalLimits,
    profiles: [String: QualificationProfileConfig], backends: [String: InferenceBackendConfig],
    services: [InferenceServiceName: InferenceServiceConfig]
  ) {
    self.mode = mode
    self.globalLimits = globalLimits
    self.profiles = profiles
    self.backends = backends
    self.services = services
  }

  public static let off = InferenceConfig(
    mode: .off, globalLimits: .defaults, profiles: [:], backends: [:], services: [:])

  /// A service with its backend and profile resolved; nil when unknown.
  public func resolve(_ name: InferenceServiceName) -> ResolvedInferenceService? {
    guard let service = services[name], let backend = backends[service.backend],
      let profile = profiles[backend.profile]
    else { return nil }
    return ResolvedInferenceService(
      name: name, service: service, backendName: service.backend, backend: backend,
      profile: profile)
  }
}

public enum InferenceMode: String, Sendable, Equatable, CaseIterable {
  /// No gateway; legacy `local_model` endpoints work as raw transport.
  case off
  /// Every agent iso launches uses a guarded service; no raw local endpoint
  /// and no cloud fallback.
  case required
}

public struct InferenceGlobalLimits: Sendable, Equatable {
  public let maxActiveRequests: Int
  public let maxQueuedRequests: Int
  public let maxRequestBufferBytes: Int

  public static let defaults = InferenceGlobalLimits(
    maxActiveRequests: 2, maxQueuedRequests: 32, maxRequestBufferBytes: 64 << 20)
}

/// The wire protocol a backend was qualified for.
public enum InferenceProtocol: String, Sendable, Equatable, CaseIterable {
  case openAIChat = "openai-chat"
  case openAIResponses = "openai-responses"
  case anthropicMessages = "anthropic-messages"
}

/// A guest-facing API a service may grant.
public enum InferenceAPI: String, Sendable, Equatable, Hashable, CaseIterable {
  case openAIChat = "openai-chat"
  case openAIResponses = "openai-responses"
  case anthropicMessages = "anthropic-messages"
  case anthropicCountTokens = "anthropic-count-tokens"
  case modelDiscovery = "model-discovery"

  /// The backend protocol a same-protocol adapter needs.
  public var backendProtocol: InferenceProtocol? {
    switch self {
    case .openAIChat: .openAIChat
    case .openAIResponses: .openAIResponses
    case .anthropicMessages, .anthropicCountTokens: .anthropicMessages
    case .modelDiscovery: nil
    }
  }
}

public enum CompletionEvidenceMode: String, Sendable, Equatable, CaseIterable {
  case drain
  case streamClose = "stream-close"
  case none
}

public enum ContextOverflowMode: String, Sendable, Equatable, CaseIterable {
  case reject
  case truncate
  case accept
}

public enum TokenCounterMode: String, Sendable, Equatable, CaseIterable {
  case none
  case backend
}

/// An owner-controlled qualification profile (§8.5, §11.1).
public struct QualificationProfileConfig: Sendable, Equatable {
  public let name: String
  public let backendProtocol: InferenceProtocol
  public let completionEvidence: CompletionEvidenceMode
  public let streamCloseDrainMilliseconds: Int
  public let contextOverflow: ContextOverflowMode
  public let overheadPerRequestBytes: Int
  public let overheadPerMessageBytes: Int
  public let maxInputBytes: Int
  public let maxRequestBodyBytes: Int
  public let tokenCounter: TokenCounterMode
}

public struct InferenceBackendConfig: Sendable, Equatable {
  /// How the backend is run: attached by the owner, or provisioned by iso.
  public enum Operation: Sendable, Equatable {
    /// An owner-run server, with an optional host-resolved bearer credential
    /// and the account it must run as (spec §20.1).
    case external(credential: CredentialReference?, runAs: String?)
    /// An iso-provisioned, launchd-managed backend (spec §20.2). It runs as
    /// the role account, with a Keychain token (§20.3).
    case managed(ManagedBackendConfig)
  }

  /// `http://127.0.0.1:<port>` only (§10).
  public let port: UInt16
  public let backendProtocol: InferenceProtocol
  public let profile: String
  public let maxActiveRequests: Int
  public let operation: Operation

  public init(
    port: UInt16, backendProtocol: InferenceProtocol, profile: String, maxActiveRequests: Int,
    operation: Operation
  ) {
    self.port = port
    self.backendProtocol = backendProtocol
    self.profile = profile
    self.maxActiveRequests = maxActiveRequests
    self.operation = operation
  }

  public var baseURL: String { "http://127.0.0.1:\(port)" }

  public var managed: ManagedBackendConfig? {
    if case .managed(let managed) = operation { managed } else { nil }
  }

  /// The account the backend must run as; always the role account when
  /// managed.
  public var runAs: String? {
    switch operation {
    case .external(_, let runAs): runAs
    case .managed: ManagedBackendConfig.roleAccount
    }
  }

  /// Whether requests carry a bearer token the backend should require.
  public var requiresToken: Bool {
    switch operation {
    case .external(let credential, _): credential != nil
    case .managed: true
    }
  }
}

/// `inference.backends.<name>.managed` (spec §20.2).
public struct ManagedBackendConfig: Sendable, Equatable {
  public static let roleAccount = "_isoinference"
  public static let keychainService = "iso-inference-backend"
  /// The `mlx-lm` release lines the launcher is qualified for.
  public static let qualifiedMLXLM = "0.31."

  public enum Runtime: Sendable, Equatable {
    /// An existing interpreter that imports `mlx_lm`.
    case python(HostPath)
    /// Opt-in: install this pinned `mlx-lm` version into a root-owned venv.
    case install(version: String)
  }

  public enum Model: Sendable, Equatable {
    /// A local directory copied in at provisioning.
    case directory(HostPath)
    /// Opt-in: fetch this Hugging Face repository at this commit.
    case fetch(repository: String, revision: String)
  }

  public enum Confinement: String, Sendable, Equatable, CaseIterable {
    case seatbelt
    case none
  }

  public let runtime: Runtime
  public let model: Model
  public let memoryLimitBytes: Int?
  public let confinement: Confinement

  public init(runtime: Runtime, model: Model, memoryLimitBytes: Int?, confinement: Confinement) {
    self.runtime = runtime
    self.model = model
    self.memoryLimitBytes = memoryLimitBytes
    self.confinement = confinement
  }

  // Shared by configuration decoding and the root provisioning step, which
  // re-validates its plan.

  public static let memoryLimitRange = (1 << 30)...(1 << 42)

  /// A numeric version in the qualified `mlx-lm` release line.
  public static func isQualifiedVersion(_ version: String) -> Bool {
    version.hasPrefix(qualifiedMLXLM)
      && version.utf8.allSatisfy { (0x30...0x39).contains($0) || $0 == UInt8(ascii: ".") }
  }

  /// A Hugging Face `OWNER/NAME`: two non-empty parts of letters, digits,
  /// `-`, `_` and `.`, none starting with `.` or containing `..`.
  public static func isRepository(_ repository: String) -> Bool {
    let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
    return parts.count == 2
      && parts.allSatisfy { part in
        !part.isEmpty && part.utf8.count <= 96 && part.first != "." && !part.contains("..")
          && part.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
              || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: ".")
          }
      }
  }

  /// Lowercase hex of exactly `count` characters (a commit is 40).
  public static func isHex(_ text: String, count: Int = 40) -> Bool {
    text.utf8.count == count
      && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }
}

/// A managed backend's name. It becomes a launchd label and a directory
/// under a root-owned tree, so beyond the service-name rule it may not start
/// with `.` (no `.` or `..` path components).
public struct ManagedBackendName: Sendable, Hashable, CustomStringConvertible {
  public let rawValue: String

  public init(_ raw: String) throws(ValidationError) {
    _ = try InferenceServiceName(raw)
    guard !raw.hasPrefix(".") else {
      throw ValidationError("managed backend name '\(raw)' may not start with '.'")
    }
    rawValue = raw
  }

  public var description: String { rawValue }
}

public struct InferenceServiceConfig: Sendable, Equatable {
  public let backend: String
  public let upstreamModel: String
  public let frontendAPIs: [InferenceAPI]
  public let maxContextTokens: Int
  public let defaultOutputTokens: Int
  public let maxOutputTokens: Int
  public let maxInputBytes: Int?
}

public struct ResolvedInferenceService: Sendable, Equatable {
  public let name: InferenceServiceName
  public let service: InferenceServiceConfig
  public let backendName: String
  public let backend: InferenceBackendConfig
  public let profile: QualificationProfileConfig
}

/// A guest-visible service alias: `[A-Za-z0-9._-]{1,128}`.
public struct InferenceServiceName: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let rawValue: String

  public init(_ raw: String) throws(ValidationError) {
    guard (1...128).contains(raw.utf8.count),
      raw.utf8.allSatisfy({
        (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
          || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".")
      })
    else {
      throw ValidationError("inference service name '\(raw)' must match [A-Za-z0-9._-]{1,128}")
    }
    rawValue = raw
  }

  public var description: String { rawValue }
  public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// An agent's `local_model`: the legacy raw endpoint, or a guarded
/// inference service. The two forms cannot be mixed (§11.1).
public enum LocalModelSelection: Sendable, Equatable {
  case endpoint(LocalModel)
  case service(InferenceServiceName)
}
