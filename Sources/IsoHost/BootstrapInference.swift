import Foundation
import IsoConfiguration
import IsoCore

/// Guest configuration for `inference.mode = "required"` (spec §12.1–12.2):
/// agents point at the instance's gateway session; nothing points at a raw
/// model endpoint or a cloud provider.
extension AgentBootstrap {
  /// Guest variables an `iso inference attach` grant exposes.
  public static let attachVariables = (
    baseURL: "ISO_INFERENCE_BASE_URL", model: "ISO_INFERENCE_MODEL", token: "ISO_INFERENCE_TOKEN"
  )

  /// The instance's gateway session, established or reused. nil when no
  /// agent or grant requests a service.
  func inferenceSession(_ instance: Instance, target: SSHTarget) throws -> (
    session: InferenceSession, fresh: Bool
  )? {
    guard inferenceRequired else { return nil }
    guard let inference else {
      throw HostError(
        "inference.mode = \"required\" but this command has no inference controller (fail-closed)")
    }
    return try inference.ensureSession(instance, target: target)
  }

  /// SSH-session variables: the Codex provider key and an attach grant's
  /// endpoint. A freshly registered session also refreshes Claude's managed
  /// settings, whose capability belonged to the previous session.
  func inferenceEnvironment(_ instance: Instance, target: SSHTarget, into env: inout EnvForward)
    throws
  {
    guard let (session, fresh) = try inferenceSession(instance, target: target) else { return }
    if config.codex.localService != nil {
      env.set(ModelRouting.codexLocalEnvKey, session.token)
    }
    if let grant = try InferenceAttachGrant.load(instance) {
      let base =
        grant.api == .anthropicMessages ? session.guestBaseURL : session.guestBaseURL + "/v1"
      env.set(Self.attachVariables.baseURL, Secret(base))
      env.set(Self.attachVariables.model, Secret(grant.service.rawValue))
      env.set(Self.attachVariables.token, session.token)
    }
    if fresh, config.claude.localService != nil {
      try writeClaudeInferenceSettings(instance, target: target, session: session)
    }
  }

  /// Claude's managed settings for `session`, written once per command.
  func writeClaudeInferenceSettings(
    _ instance: Instance, target: SSHTarget, session: InferenceSession
  ) throws {
    guard inference?.sessions.markClaudeSettings(instance, session: session) ?? true else {
      return
    }
    try writeManagedClaudeSettings(target, localEnv: claudeInferenceEnv(session))
  }

  /// Claude's managed `env`: the gateway alias for every tier and the
  /// service's context window.
  func claudeInferenceEnv(_ session: InferenceSession) -> [String: String] {
    guard let name = config.claude.localService,
      let service = config.inference.resolve(name)
    else { return [:] }
    var env = ModelRouting.claudeEnvBlock(
      baseURL: session.guestBaseURL, model: name.rawValue, authToken: session.token.expose())
    env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(service.service.maxContextTokens)
    return env
  }

  /// Codex's provider table: the gateway's Responses route and the alias.
  func codexInferenceTable(_ session: InferenceSession) -> TOMLTable? {
    guard let name = config.codex.localService else { return nil }
    return ModelRouting.codexLocalConfig(
      baseURL: session.guestBaseURL + "/v1", model: name.rawValue)
  }

  /// Before any VM work: the gateway binary exists and every requested
  /// backend listens on 127.0.0.1 and nowhere else (§10), so a failure costs
  /// no boot and leaves nothing half-started.
  public func preflightInference(_ instance: Instance, noAgents: Bool) throws {
    guard inferenceRequired, !noAgents else { return }
    guard let inference else {
      throw HostError(
        "inference.mode = \"required\" but this command has no inference controller (fail-closed)")
    }
    let services = try inference.requestedServices(instance)
    guard !services.isEmpty else { return }
    _ = try inference.locateBinary()
    let backends = Set(try services.map { try inference.resolved($0).backendName })
    for name in backends.sorted() {
      guard let backend = config.inference.backends[name] else { continue }
      try BackendChecks.enforce(name: name, backend: backend)
    }
  }

  /// Launching an agent under `required` needs a guarded service: an
  /// unconfigured agent fails locally instead of reaching a cloud endpoint.
  public func requireInferenceService(forClaude: Bool) throws {
    guard inferenceRequired else { return }
    let (label, service) =
      forClaude ? ("claude", config.claude.localService) : ("codex", config.codex.localService)
    guard service != nil else {
      throw HostError(
        "inference.mode = \"required\": \(label) has no guarded inference service; set \(label).local_model to { \"service\": NAME }"
      )
    }
  }
}
