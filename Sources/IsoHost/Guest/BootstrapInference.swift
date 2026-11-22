import Foundation
import IsoConfiguration
import IsoCore

/// Guest configuration for `inference.mode = "required"` (spec §12.1–12.2):
/// agents point at the instance's gateway session; nothing points at a raw
/// model endpoint or a cloud provider.
extension AgentBootstrap {
  /// Guest variables an `iso inference attach` grant exposes.
  package static let attachVariables = (
    baseURL: "ISO_INFERENCE_BASE_URL", model: "ISO_INFERENCE_MODEL", token: "ISO_INFERENCE_TOKEN"
  )

  /// The instance's gateway session, established or reused. nil when no
  /// agent or grant requests a service (or it was revoked by hand). A new
  /// session is activated only after the guest's bridge and agent
  /// configuration carry it (§12.2), so a `--no-agents` boot gets its Codex
  /// and Claude configuration with its first session.
  func inferenceSession(_ instance: Instance, target: SSHTarget) throws -> (
    session: InferenceSession, fresh: Bool
  )? {
    guard let inference else {
      guard inferenceRequired else { return nil }
      throw HostError(
        "inference.mode = \"required\" but this command has no inference controller (fail-closed)")
    }
    return try inference.ensureSession(instance, target: target) { session in
      try installInferenceBridge(target)
      try writeManagedClaudeSettings(target, localEnv: claudeInferenceEnv(session))
      if config.codex.localService != nil {
        try writeCodexInferenceConfig(instance, target: target, session: session)
      }
    }
  }

  /// `inferenceSession` where a missing session must not stop the command
  /// (shells, hooks, bootstrap): the failure is a warning and the session
  /// carries no inference variables, so agents still reach no model. An
  /// agent launch (`strictInference`) fails instead.
  func optionalInferenceSession(_ instance: Instance, target: SSHTarget) throws -> (
    session: InferenceSession, fresh: Bool
  )? {
    guard !strictInference else { return try inferenceSession(instance, target: target) }
    do { return try inferenceSession(instance, target: target) } catch {
      guard inferenceRequired else { throw error }
      diagnostics.warn(
        "No inference session for '\(instance.name)' (\(oneLine(error))); continuing without model access: agents in this session reach no model"
      )
      return nil
    }
  }

  /// A changed `inference.mode` disables what the old mode admitted first
  /// (§12.4), before any handoff (which refuses a boot whose relay no longer
  /// matches): under `off`, a recorded gateway session is revoked; under
  /// `required`, credential proxies and raw model tunnels are stopped.
  func reconcileInferenceMode(_ instances: [Instance]) {
    for instance in instances {
      if inferenceRequired {
        let running = ProxyProvider.allCases.filter {
          FileManager.default.fileExists(atPath: ProxyLauncher.pidPath(instance, $0.rawValue))
        }
        guard !running.isEmpty || !ProxyLauncher.recordedModelTunnels(instance).isEmpty else {
          continue
        }
        diagnostics.warn(
          "inference.mode = \"required\": stopping the credential proxies and model tunnels of '\(instance.name)'; restart it to apply the mode"
        )
        for provider in ProxyProvider.allCases { proxies.stop(instance, provider: provider) }
        proxies.stopModelTunnels(instance)
      } else if let inference,
        FileManager.default.fileExists(atPath: InferenceController.statePath(instance))
      {
        do { try inference.revoke(instance) } catch {
          diagnostics.warn(
            "inference.mode is \"off\" but the gateway session of '\(instance.name)' could not be revoked: \(oneLine(error)); run `iso inference revoke \(instance.name)`"
          )
        }
      }
    }
  }

  /// Codex's managed config for a session: the gateway provider table, and
  /// no cloud `auth.json`.
  func writeCodexInferenceConfig(
    _ instance: Instance, target: SSHTarget, session: InferenceSession?
  )
    throws
  {
    var modelState = try ModelState.loadOrDefault(instance)
    try copyCodexConfig(
      target,
      source: configSourceDirectory(
        config.codex.configDirectory, defaultName: ".codex", label: "codex.config_dir"),
      local: codexInferenceTable(session), managesLocal: true, proxyActive: true,
      keyringMaterialized: modelState.codexKeyringMaterialized)
    try removeGuestCodexAuthJSON(target)
    if !modelState.codexMaterialized {
      modelState.codexMaterialized = true
      try modelState.save(instance, diagnostics: diagnostics)
    }
  }

  /// `127.0.0.1:11788` in the guest, bridged by systemd to the relayed
  /// gateway socket (§22).
  func installInferenceBridge(_ target: SSHTarget) throws {
    do {
      try client.exec(
        target, RemoteCommand().literal("sudo bash -s"),
        stdin: Array(EmbeddedResources.guestScript("inference-bridge.sh").utf8))
    } catch {
      throw ContextError(
        "Failed to install the guest's inference bridge (fail-closed)", cause: error)
    }
  }

  /// SSH-session variables: the Codex provider key and an attach grant's
  /// endpoint. A freshly registered session also refreshes Claude's managed
  /// settings, whose capability belonged to the previous session.
  func inferenceEnvironment(_ instance: Instance, target: SSHTarget, into env: inout EnvForward)
    throws
  {
    guard let (session, _) = try optionalInferenceSession(instance, target: target) else { return }
    if config.codex.localService != nil {
      env.set(ModelRouting.codexLocalEnvKey, session.token)
    }
    if let grant = try InferenceAttachGrant.load(instance) {
      env.set(Self.attachVariables.baseURL, Secret(Self.attachBaseURL(grant.api, session)))
      env.set(Self.attachVariables.model, Secret(grant.service.rawValue))
      env.set(Self.attachVariables.token, session.token)
    }
  }

  /// The base URL an SDK for `api` appends its own paths to: the Anthropic
  /// SDKs add `/v1/messages` (and `/v1/messages/count_tokens`), the OpenAI
  /// ones `/chat/completions`, `/responses` and `/models`.
  static func attachBaseURL(_ api: InferenceAPI, _ session: InferenceSession) -> String {
    switch api {
    case .anthropicMessages, .anthropicCountTokens: session.guestBaseURL
    case .openAIChat, .openAIResponses, .modelDiscovery: session.guestBaseURL + "/v1"
    }
  }

  /// Claude's managed settings for `session`, written once per command.
  func writeClaudeInferenceSettings(
    _ instance: Instance, target: SSHTarget, session: InferenceSession,
    imported: ClaudeImport.Preferences? = nil
  ) throws {
    guard inference?.sessions.markClaudeSettings(instance, session: session) ?? true else {
      return
    }
    try writeManagedClaudeSettings(
      target, localEnv: claudeInferenceEnv(session), imported: imported)
  }

  /// A `{vault:}` provider secret given for the credential proxy, which
  /// `required` never starts.
  static func inferenceRefusesProviderSecret(_ routed: GuestEnvState.ProviderSecret) -> HostError {
    HostError(
      "\(routed.variable)={vault:\(routed.name)} is a provider credential, but inference.mode = \"required\" starts no provider proxy and forwards no provider credential; remove it"
    )
  }

  /// The token agents get without a session: the gateway refuses it, so
  /// an agent reaches no model rather than the cloud defaults (INV-08).
  static let noSessionToken = "iso-inference-no-session"
  static let guestBridgeURL = "http://127.0.0.1:\(InferenceController.guestPort)"

  /// Claude's managed `env`: the gateway alias for every tier and the
  /// service's context window. Without a session, or with no Claude service,
  /// the same gateway URL with a token it refuses: an empty `env` would put
  /// Claude back on Anthropic's cloud defaults.
  func claudeInferenceEnv(_ session: InferenceSession?) -> [String: String] {
    let name = config.claude.localService
    let service = name.flatMap(config.inference.resolve)
    guard let session, let name, let service else {
      return ModelRouting.claudeEnvBlock(
        baseURL: Self.guestBridgeURL, model: name?.rawValue ?? Self.noSessionToken,
        authToken: Self.noSessionToken)
    }
    var env = ModelRouting.claudeEnvBlock(
      baseURL: session.guestBaseURL, model: name.rawValue, authToken: session.token.expose())
    env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(service.service.maxContextTokens)
    return env
  }

  /// Codex's provider table: the gateway's Responses route and the alias.
  /// Without a session or service it still names the gateway, never the
  /// OpenAI default provider; the session's token is what authorizes it.
  func codexInferenceTable(_ session: InferenceSession?) -> TOMLTable {
    ModelRouting.codexLocalConfig(
      baseURL: (session?.guestBaseURL ?? Self.guestBridgeURL) + "/v1",
      model: config.codex.localService?.rawValue ?? Self.noSessionToken)
  }

  /// Before any VM work: the gateway binary exists and every requested
  /// backend listens on 127.0.0.1 and nowhere else (§10), so a failure costs
  /// no boot and leaves nothing half-started.
  package func preflightInference(_ instance: Instance, noAgents: Bool) throws {
    guard inferenceRequired, !noAgents else { return }
    guard let inference else {
      throw HostError(
        "inference.mode = \"required\" but this command has no inference controller (fail-closed)")
    }
    if try MachineSidecar.loadIfPresent(instance)?.kind == .macos {
      throw HostError(
        "inference.mode = \"required\" is supported for Linux guests only; '\(instance.name)' is a macOS guest"
      )
    }
    let services = try inference.requestedServices(instance)
    guard !services.isEmpty else { return }
    _ = try inference.locateBinary()
    try inference.enforceBackends(try services.map(inference.resolved))
  }

  /// Launching an agent under `required` needs a guarded service: an
  /// unconfigured agent fails locally instead of reaching a cloud endpoint.
  package func requireInferenceService(forClaude: Bool) throws {
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
