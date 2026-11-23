import IsoCore

/// `inference` (secure-local-inference spec §11): host-side local models
/// exposed to VMs through the `iso-inference` gateway. The gateway
/// re-validates everything it receives; these types make an invalid
/// configuration fail at load time.
package struct InferenceConfig: Sendable, Equatable {
  package let mode: InferenceMode
  package let globalLimits: InferenceGlobalLimits
  package let profiles: [String: QualificationProfileConfig]
  package let backends: [String: InferenceBackendConfig]
  package let services: [InferenceServiceName: InferenceServiceConfig]

  package init(
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

  package static let off = InferenceConfig(
    mode: .off, globalLimits: .defaults, profiles: [:], backends: [:], services: [:])

  /// A service with its backend and profile resolved; nil when unknown.
  package func resolve(_ name: InferenceServiceName) -> ResolvedInferenceService? {
    guard let service = services[name], let backend = backends[service.backend],
      let profile = profiles[backend.profile]
    else { return nil }
    return ResolvedInferenceService(
      name: name, service: service, backendName: service.backend, backend: backend,
      profile: profile)
  }
}

package enum InferenceMode: String, Sendable, Equatable, CaseIterable {
  /// No gateway; legacy `local_model` endpoints work as raw transport.
  case off
  /// Every agent iso launches uses a guarded service; no raw local endpoint
  /// and no cloud fallback.
  case required
}

package struct InferenceGlobalLimits: Sendable, Equatable {
  package let maxActiveRequests: Int
  package let maxQueuedRequests: Int
  package let maxRequestBufferBytes: Int

  package static let defaults = InferenceGlobalLimits(
    maxActiveRequests: 2, maxQueuedRequests: 32, maxRequestBufferBytes: 64 << 20)
}

/// The wire protocol a backend was qualified for.
package enum InferenceProtocol: String, Sendable, Equatable, CaseIterable {
  case openAIChat = "openai-chat"
  case openAIResponses = "openai-responses"
  case anthropicMessages = "anthropic-messages"
}

/// A guest-facing API a service may grant.
package enum InferenceAPI: String, Sendable, Equatable, Hashable, CaseIterable {
  case openAIChat = "openai-chat"
  case openAIResponses = "openai-responses"
  case anthropicMessages = "anthropic-messages"
  case anthropicCountTokens = "anthropic-count-tokens"
  case modelDiscovery = "model-discovery"

  /// The backend protocol a same-protocol adapter needs.
  package var backendProtocol: InferenceProtocol? {
    switch self {
    case .openAIChat: .openAIChat
    case .openAIResponses: .openAIResponses
    case .anthropicMessages, .anthropicCountTokens: .anthropicMessages
    case .modelDiscovery: nil
    }
  }
}

package enum CompletionEvidenceMode: String, Sendable, Equatable, CaseIterable {
  case drain
  case streamClose = "stream-close"
  case none
}

package enum ContextOverflowMode: String, Sendable, Equatable, CaseIterable {
  case reject
  case truncate
  case accept
}

package enum TokenCounterMode: String, Sendable, Equatable, CaseIterable {
  case none
  case backend
}

/// An owner-controlled qualification profile (§8.5, §11.1).
package struct QualificationProfileConfig: Sendable, Equatable {
  package let name: String
  package let backendProtocol: InferenceProtocol
  package let completionEvidence: CompletionEvidenceMode
  package let streamCloseDrainMilliseconds: Int
  package let contextOverflow: ContextOverflowMode
  package let overheadPerRequestBytes: Int
  package let overheadPerMessageBytes: Int
  package let maxInputBytes: Int
  package let maxRequestBodyBytes: Int
  package let tokenCounter: TokenCounterMode
}

/// Whether iso must verify a backend's isolation before a session uses it
/// (spec §10, §20).
package enum BackendIsolation: String, Sendable, Equatable, CaseIterable {
  /// The default: the backend runs as another account, refuses requests
  /// without its token, proves it is the listener and is sandboxed. Only a
  /// managed backend under Seatbelt can pass.
  case verified
  /// The owner accepts a backend iso cannot verify (an attached server, or
  /// a managed one with `confinement: "none"`) in the trusted computing base.
  case unverified
}

package struct InferenceBackendConfig: Sendable, Equatable {
  /// How the backend is run: attached by the owner, or provisioned by iso.
  package enum Operation: Sendable, Equatable {
    /// An owner-run server, with an optional host-resolved bearer credential
    /// and the account it must run as (spec §20.1).
    case external(credential: CredentialReference?, runAs: String?)
    /// An iso-provisioned, launchd-managed backend (spec §20.2). It runs as
    /// the role account, with a Keychain token (§20.3).
    case managed(ManagedBackendConfig)
  }

  /// `http://127.0.0.1:<port>` only (§10).
  package let port: UInt16
  package let backendProtocol: InferenceProtocol
  package let profile: String
  package let maxActiveRequests: Int
  package let operation: Operation
  package let isolation: BackendIsolation

  package init(
    port: UInt16, backendProtocol: InferenceProtocol, profile: String, maxActiveRequests: Int,
    operation: Operation, isolation: BackendIsolation = .verified
  ) {
    self.port = port
    self.backendProtocol = backendProtocol
    self.profile = profile
    self.maxActiveRequests = maxActiveRequests
    self.operation = operation
    self.isolation = isolation
  }

  package var baseURL: String { "http://127.0.0.1:\(port)" }

  package var managed: ManagedBackendConfig? {
    if case .managed(let managed) = operation { managed } else { nil }
  }

  /// The account the backend must run as; always the role account when
  /// managed.
  package var runAs: String? {
    switch operation {
    case .external(_, let runAs): runAs
    case .managed: ManagedBackendConfig.roleAccount
    }
  }

  /// Whether requests carry a bearer token the backend should require.
  package var requiresToken: Bool {
    switch operation {
    case .external(let credential, _): credential != nil
    case .managed: true
    }
  }
}

/// `inference.backends.<name>.managed` (spec §20.2).
package struct ManagedBackendConfig: Sendable, Equatable {
  package static let roleAccount = "_isoinference"
  package static let keychainService = "iso-inference-backend"
  /// The `mlx-lm` release lines the launcher is qualified for.
  package static let qualifiedMLXLM = "0.31."

  package enum Runtime: Sendable, Equatable {
    /// An existing interpreter that imports `mlx_lm`.
    case python(HostPath)
    /// Opt-in: install this pinned `mlx-lm` version into a root-owned venv.
    case install(version: String)
  }

  package enum Model: Sendable, Equatable {
    /// A local directory copied in at provisioning.
    case directory(HostPath)
    /// Opt-in: fetch this Hugging Face repository at this commit.
    case fetch(repository: String, revision: String)
  }

  package enum Confinement: String, Sendable, Equatable, CaseIterable {
    case seatbelt
    case none
  }

  package let runtime: Runtime
  package let model: Model
  package let memoryLimitBytes: Int?
  package let confinement: Confinement

  package init(runtime: Runtime, model: Model, memoryLimitBytes: Int?, confinement: Confinement) {
    self.runtime = runtime
    self.model = model
    self.memoryLimitBytes = memoryLimitBytes
    self.confinement = confinement
  }

  // Shared by configuration decoding and the root provisioning step, which
  // re-validates its plan.

  package static let memoryLimitRange = (1 << 30)...(1 << 42)

  /// A numeric version in the qualified `mlx-lm` release line.
  package static func isQualifiedVersion(_ version: String) -> Bool {
    version.hasPrefix(qualifiedMLXLM)
      && version.utf8.allSatisfy { (0x30...0x39).contains($0) || $0 == UInt8(ascii: ".") }
  }

  /// A Hugging Face `OWNER/NAME`: two non-empty parts of letters, digits,
  /// `-`, `_` and `.`, none starting with `.` or containing `..`.
  package static func isRepository(_ repository: String) -> Bool {
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
  package static func isHex(_ text: String, count: Int = 40) -> Bool {
    text.utf8.count == count
      && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }
}

/// A managed backend's name. It becomes a launchd label and a directory
/// under a root-owned tree, so beyond the service-name rule it may not start
/// with `.` (no `.` or `..` path components).
package struct ManagedBackendName: Sendable, Hashable, CustomStringConvertible {
  package let rawValue: String

  package init(_ raw: String) throws(ValidationError) {
    _ = try InferenceServiceName(raw)
    guard !raw.hasPrefix(".") else {
      throw ValidationError("managed backend name '\(raw)' may not start with '.'")
    }
    rawValue = raw
  }

  package var description: String { rawValue }
}

package struct InferenceServiceConfig: Sendable, Equatable {
  package let backend: String
  package let upstreamModel: String
  package let frontendAPIs: [InferenceAPI]
  package let maxContextTokens: Int
  package let defaultOutputTokens: Int
  package let maxOutputTokens: Int
  package let maxInputBytes: Int?
}

package struct ResolvedInferenceService: Sendable, Equatable {
  package let name: InferenceServiceName
  package let service: InferenceServiceConfig
  package let backendName: String
  package let backend: InferenceBackendConfig
  package let profile: QualificationProfileConfig
}

/// A guest-visible service alias: `[A-Za-z0-9._-]{1,128}`.
package struct InferenceServiceName: Sendable, Hashable, Comparable, CustomStringConvertible {
  package let rawValue: String

  package init(_ raw: String) throws(ValidationError) {
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

  package var description: String { rawValue }
  package static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// An agent's `local_model`: the legacy raw endpoint, or a guarded
/// inference service. The two forms cannot be mixed (§11.1).
package enum LocalModelSelection: Sendable, Equatable {
  case endpoint(LocalModel)
  case service(InferenceServiceName)
}
