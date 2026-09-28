import CoopConfiguration
import CoopCore
import CoopSecrets
import Foundation

/// GitHub token handling, ported separately. Bootstrap consults it for the
/// repository an instance works on, the VM's PAT assignment, the token to
/// forward as `GITHUB_TOKEN`, and the guest `gh` credential helper.
public protocol GitHubTokenSource: Sendable {
  /// `detect_instance_repo`: the slug recorded for the instance's workspace.
  func instanceRepo(_ instance: Instance) -> RepoSlug?
  /// `github_assignment::active`: the repo of the VM's active PAT
  /// assignment, if any; fails closed on a broken assignment.
  func activeAssignment(_ instance: Instance) throws -> RepoSlug?
  /// `resolve_github_token`: the token to forward for `repo`, or nil.
  func token(repo: RepoSlug?) throws -> Secret<String>?
  /// `resolve_pat_token`: resolve the `github.pat` entry for `repo`.
  func resolvePAT(_ repo: RepoSlug) throws -> Secret<String>
  /// `setup_github_auth`: run once per bootstrap when a token is forwarded.
  func configureGuest(_ client: SSHClient, _ session: SSHSession) throws
}

/// Whether plugins, MCP servers and `/workspace` still need installing.
public enum BootMode: Sendable, Equatable {
  case firstBoot
  case restart
}

/// Guest locations of the agent launchers.
public enum GuestBinaries {
  /// Stable system link to the guest user's native Codex launcher.
  public static let codex = GuestPath("/usr/local/bin/codex")
  /// Codex under a guest Secret Service session (ChatGPT account auth).
  public static let codexAccount = GuestPath("/usr/local/bin/codex-account")
}

extension GuestUser {
  /// Where the Claude Code installer puts the per-user binary.
  public var claudeBinary: GuestPath { GuestPath("/home/\(rawValue)/.local/bin/claude") }
}

/// Resolves `{vault:}` references for a session. The CLI's implementation
/// unlocks the secret store at most once per command.
public protocol GuestSecretResolver: Sendable {
  func resolve(_ names: Set<SecretName>) throws -> [SecretName: Secret<[UInt8]>]
}

/// Agent bootstrap, guest sessions and post-start hooks for one command.
public struct AgentBootstrap: Sendable {
  public let config: CoopConfig
  let client: SSHClient
  /// The host process environment (`env_forward`, provider key fallbacks).
  let environment: [String: String]
  /// For the default `~/.claude` / `~/.codex` sources.
  let home: String?
  let resolver: CredentialResolver
  public let proxies: ProxyLauncher
  let github: any GitHubTokenSource
  let diagnostics: Diagnostics
  /// For `{vault:}` entries in `guest_env.json`; nil refuses them.
  let secrets: (any GuestSecretResolver)?

  public init(
    config: CoopConfig, client: SSHClient, environment: [String: String], home: String?,
    resolver: CredentialResolver, proxies: ProxyLauncher, github: any GitHubTokenSource,
    diagnostics: Diagnostics, secrets: (any GuestSecretResolver)? = nil
  ) {
    self.secrets = secrets
    self.config = config
    self.client = client
    self.environment = environment
    self.home = home
    self.resolver = resolver
    self.proxies = proxies
    self.github = github
    self.diagnostics = diagnostics
  }

  // MARK: - Environment forwarding

  static let chatgptReason = "codex.auth = \"chatgpt\""

  /// Why a recognized provider variable is withheld from the guest.
  enum WithholdReason: Equatable, CustomStringConvertible {
    /// The provider runs through its proxy.
    case proxied
    /// `proxy.mode = "required"`: an explicit declaration is an error.
    case required(ProxyProvider)
    /// ChatGPT account auth keeps Codex credentials in the guest keyring.
    case chatgptAuth

    var description: String {
      switch self {
      case .proxied: "proxy mode"
      case .required: "proxy.mode = \"required\""
      case .chatgptAuth: AgentBootstrap.chatgptReason
      }
    }
  }

  /// Recognized provider variables withheld from the guest. A proxied
  /// provider withholds all of its variables; `proxy.mode = "required"`
  /// withholds every provider's; ChatGPT account auth withholds
  /// `OPENAI_API_KEY`.
  func withheldVariables(proxyAnthropic: Bool, proxyOpenAI: Bool) -> [String: WithholdReason] {
    let required = config.proxy.mode == .required
    var out: [String: WithholdReason] = [:]
    for (provider, proxied) in [(ProxyProvider.anthropic, proxyAnthropic), (.openai, proxyOpenAI)] {
      guard proxied || required else { continue }
      for name in provider.recognizedVariables {
        out[name] = required ? .required(provider) : .proxied
      }
    }
    if config.codexAuth == .chatgpt && out["OPENAI_API_KEY"] == nil {
      out["OPENAI_API_KEY"] = .chatgptAuth
    }
    return out
  }

  /// An explicit declaration of a withheld variable: under `required` an
  /// error, otherwise a warning (the historical proxy-mode behavior).
  func refuse(_ name: String, from source: String, reason: WithholdReason) throws {
    if case .required(let provider) = reason {
      throw HostError(
        "\(reason): \(source) entry '\(name)' would put a provider credential in the guest; remove it or configure `proxy.\(provider.rawValue)`"
      )
    }
    diagnostics.warn("\(reason): ignoring \(source) entry '\(name)'")
  }

  /// Values forwarded with `SendEnv`. Recognized provider variables are
  /// withheld per `withheldVariables`; `cmd:` keys are resolved here, when a
  /// session needs them.
  public func prepareEnvForwarding(
    repo: RepoSlug?, suppressAnthropicKey: Bool, suppressOpenAIKey: Bool
  ) throws -> EnvForward {
    let withheld = withheldVariables(
      proxyAnthropic: suppressAnthropicKey, proxyOpenAI: suppressOpenAIKey)
    var env = EnvForward()

    if let reason = withheld["ANTHROPIC_API_KEY"] {
      diagnostics.debug("\(reason): not forwarding ANTHROPIC_API_KEY into the guest")
    } else if let key = config.claude.apiKey {
      do { env.set("ANTHROPIC_API_KEY", try resolver.resolve(key)) } catch {
        throw ContextError("Failed to resolve claude.api_key", cause: error)
      }
    } else if let key = environment["ANTHROPIC_API_KEY"] {
      env.set("ANTHROPIC_API_KEY", Secret(key))
    }

    if let reason = withheld["OPENAI_API_KEY"] {
      diagnostics.debug("\(reason): not forwarding OPENAI_API_KEY into the guest")
    } else if let key = config.codex.apiKey {
      do { env.set("OPENAI_API_KEY", try resolver.resolve(key)) } catch {
        throw ContextError("Failed to resolve codex.api_key", cause: error)
      }
    } else if let key = environment["OPENAI_API_KEY"] {
      env.set("OPENAI_API_KEY", Secret(key))
    }

    if let token = try github.token(repo: repo) {
      env.set("GITHUB_TOKEN", token)
    } else {
      diagnostics.debug("no GITHUB_TOKEN forwarded to guest")
    }

    for name in config.claude.envForward + config.codex.envForward {
      if let reason = withheld[name.rawValue] {
        try refuse(name.rawValue, from: "env_forward", reason: reason)
        continue
      }
      if !env.contains(name.rawValue), let value = environment[name.rawValue] {
        env.set(name.rawValue, Secret(value))
      }
    }
    for variable in config.guestEnvironment {
      let name = variable.name.rawValue
      if let reason = withheld[name] {
        try refuse(name, from: "guest_env", reason: reason)
        continue
      }
      if env.contains(name) {
        diagnostics.warn("guest_env entry '\(name)' overrides a previously resolved value")
      }
      env.set(name, Secret(variable.value))
    }
    return env
  }

  /// Whether a provider has a proxy upstream for this VM (a stored literal
  /// override counts: its key must still be suppressed). Never under
  /// `proxy.mode = "off"`.
  func proxyConfigured(_ instance: Instance, _ provider: ProxyProvider) throws -> Bool {
    guard config.proxy.mode != .off else { return false }
    return try ProxyState.load(instance).override(for: provider) != nil
      || config.proxy.upstream(for: provider) != nil
  }

  /// A session for `target`. With an instance, proxy-mode key suppression,
  /// the persisted `--env` snapshot and the Codex provider key apply.
  public func prepareSession(_ instance: Instance?, target: SSHTarget, repo: RepoSlug?) throws
    -> SSHSession
  {
    let model = try instance.map(ModelState.loadOrDefault)
    var proxyAnthropic = false
    var proxyOpenAI = false
    if let instance, model?.mode == .remote {
      proxyAnthropic = try proxyConfigured(instance, .anthropic)
      proxyOpenAI = try proxyConfigured(instance, .openai)
    }
    let codexAccount = config.codexAuth == .chatgpt
    if codexAccount && proxyOpenAI { diagnostics.warn(CodexChecks.chatgptProxyConflictMessage) }

    let assigned = try instance.flatMap { try github.activeAssignment($0) }
    var env = try prepareEnvForwarding(
      repo: assigned ?? repo, suppressAnthropicKey: proxyAnthropic,
      suppressOpenAIKey: proxyOpenAI)
    if let instance {
      if let state = try GuestEnvState.tryLoad(instance) {
        try GuestEnvState.rejectProviderReferences(state.entries)
        let withheld = withheldVariables(proxyAnthropic: proxyAnthropic, proxyOpenAI: proxyOpenAI)
        let resolved = try resolveReferences(state)
        for (name, value) in state.sortedEntries {
          if let reason = withheld[name.rawValue] {
            try refuse(name.rawValue, from: "runtime --env", reason: reason)
            continue
          }
          switch value {
          case .literal(let text): env.set(name.rawValue, Secret(text))
          case .secret(let secret): env.set(name.rawValue, resolved[secret]!)
          }
        }
      }
      if let model {
        if model.mode == .local, let endpoint = model.resolvedCodex(config.codex) {
          env.set(ModelRouting.codexLocalEnvKey, Secret(endpoint.authTokenOrDefault))
        } else if proxyOpenAI,
          let token = ProxyLauncher.capabilityToken(instance, provider: .openai)
        {
          env.set(ModelRouting.codexLocalEnvKey, token)
        }
      }
    }
    return SSHSession(target: target, env: env)
  }

  /// One batch resolution for every reference in `state`, each checked to
  /// be a usable environment value (UTF-8, no NUL). Values are guest-visible
  /// by design; they are never persisted or logged on the host.
  func resolveReferences(_ state: GuestEnvState) throws -> [SecretName: Secret<String>] {
    let names = Set(state.entries.values.compactMap(\.reference))
    guard !names.isEmpty else { return [:] }
    guard let secrets else {
      throw HostError(
        "guest_env.json references stored secrets, but this command cannot unlock the secret store")
    }
    let values = try secrets.resolve(names)
    var out: [SecretName: Secret<String>] = [:]
    for name in names {
      guard let bytes = values[name]?.expose() else {
        throw HostError("unable to resolve required secret '\(name)'")
      }
      guard !bytes.contains(0), let text = String(validating: bytes, as: UTF8.self) else {
        throw HostError("secret '\(name)' is not a valid environment value (UTF-8 without NUL)")
      }
      diagnostics.debug("resolved secret reference '\(name)' for the guest environment")
      out[name] = Secret(text)
    }
    return out
  }

  /// `open_ssh_session`: the running instance (named, or the only one
  /// running) and a session with forwarding and the `--env` overlay.
  public func openSession(
    _ backend: AppleBackend, name: InstanceName?, instances: [Instance]
  ) throws -> (AppleBackend.Running, SSHSession) {
    let running = try backend.resolveRunning(name, instances: instances)
    return (running, try session(for: running))
  }

  /// A session for an already-resolved running instance.
  public func session(for running: AppleBackend.Running) throws -> SSHSession {
    try prepareSession(
      running.instance, target: running.target, repo: github.instanceRepo(running.instance))
  }

  // MARK: - Post-boot sequence

  public static let noAgentsChatGPTWarning =
    "codex.auth = \"chatgpt\" is configured but --no-agents skips agent bootstrap; the guest keyring credential store will not be set up, so `coop codex -- login` would store credentials in a plaintext ~/.codex/auth.json in the guest"

  /// Whether `--no-agents` leaves this VM's Codex writing plaintext
  /// credentials. `keyringMaterialized` is read only when needed.
  public static func noAgentsSkipsCodexKeyring(
    noAgents: Bool, auth: CodexAuthMode, keyringMaterialized: () -> Bool
  ) -> Bool {
    noAgents && auth == .chatgpt && !keyringMaterialized()
  }

  /// After a fresh or restarted boot: close the previous boot's model
  /// tunnels, bootstrap the agents (unless `noAgents`), then run the
  /// post-start hook. `up`/`start` call this once SSH is ready.
  public func bootstrapAndPostStart(
    _ instance: Instance, target: SSHTarget, repo: RepoSlug?, noAgents: Bool,
    postStartOverride: String?, mode: BootMode
  ) throws {
    proxies.stopModelTunnels(instance)
    let postStart = postStartOverride ?? config.postStart
    let proxyConfigured =
      try proxyConfigured(instance, .anthropic) || proxyConfigured(instance, .openai)
    if noAgents && proxyConfigured {
      diagnostics.warn(
        "proxy mode is configured but --no-agents skips agent bootstrap; agents will not be able to authenticate in this VM"
      )
    }
    if !noAgents, config.proxy.mode == .required,
      try ModelState.loadOrDefault(instance).mode == .remote,
      !proxyConfigured
    {
      throw HostError(
        "proxy.mode = \"required\" but no provider proxy is configured for '\(instance.name)'; run `coop proxy setup` (or set proxy.mode to \"auto\")"
      )
    }
    if Self.noAgentsSkipsCodexKeyring(
      noAgents: noAgents, auth: config.codexAuth,
      keyringMaterialized: {
        ((try? ModelState.tryLoad(instance)) ?? nil)?.codexKeyringMaterialized ?? false
      })
    {
      diagnostics.warn(Self.noAgentsChatGPTWarning)
    }
    if noAgents && postStart == nil {
      if let assigned = try github.activeAssignment(instance) {
        _ = try github.resolvePAT(assigned)
      }
      diagnostics.log(.info, "Skipping guest agent bootstrap (--no-agents)")
      return
    }
    let session = try prepareSession(instance, target: target, repo: repo)
    let raw = ProxyProvider.allCases.flatMap(\.recognizedVariables).filter(session.env.contains)
    if !raw.isEmpty {
      diagnostics.warn(
        "forwarding \(raw.joined(separator: ", ")) into the guest in plain text; `coop proxy setup` keeps provider credentials on the host"
      )
    }
    if noAgents {
      diagnostics.log(.info, "Skipping guest agent bootstrap (--no-agents)")
    } else {
      try bootstrapAgents(session, instance: instance, mode: mode)
    }
    if let postStart {
      // Bootstrap may have just minted the Codex capability token.
      let hookSession =
        noAgents ? session : try prepareSession(instance, target: target, repo: repo)
      runPostStart(hookSession, command: postStart)
    }
  }

  /// The user's hook, evaluated by the guest shell; a failure only warns.
  public func runPostStart(_ session: SSHSession, command: String) {
    diagnostics.log(.info, "Running post_start hook in guest")
    diagnostics.debug("post_start: \(command)")
    do {
      try client.exec(session, RemoteCommand().literal(command))
      diagnostics.debug("post_start hook completed")
    } catch {
      diagnostics.warn("post_start hook failed (continuing): \(error)")
    }
  }

  /// GitHub auth, local-model tunnels, then Claude and Codex.
  public func bootstrapAgents(_ session: SSHSession, instance: Instance, mode: BootMode) throws {
    if session.env.contains("GITHUB_TOKEN") {
      diagnostics.log(.info, "Configuring GitHub auth in guest")
      try github.configureGuest(client, session)
    }
    let tunnels = try LocalEndpoints.tunnels(ModelState.loadOrDefault(instance), config: config)
    try proxies.syncModelTunnels(instance, target: session.target, wanted: tunnels)
    try bootstrapClaude(session, instance: instance, mode: mode)
    try bootstrapCodex(session, instance: instance, mode: mode)
  }

  // MARK: - Shared helpers

  /// The guest user baked into the image, `ubuntu` when unrecorded.
  public func persistedGuestUser(_ image: ImageName) -> GuestUser {
    (try? TemplateStore.load(config, image))?.guestUser ?? .default
  }

  /// Wanted minus what the image already has baked in.
  static func pluginDelta(
    wantedMarketplaces: [String], wantedPlugins: [String], bakedMarketplaces: [String],
    bakedPlugins: [String]
  ) -> ([String], [String]) {
    (
      wantedMarketplaces.filter { !bakedMarketplaces.contains($0) },
      wantedPlugins.filter { !bakedPlugins.contains($0) }
    )
  }

  func claudePluginDelta(_ image: ImageName) -> ([String], [String]) {
    let template = try? TemplateStore.load(config, image)
    return Self.pluginDelta(
      wantedMarketplaces: config.claude.marketplaces, wantedPlugins: config.claude.plugins,
      bakedMarketplaces: template?.marketplaces ?? [], bakedPlugins: template?.plugins ?? [])
  }

  func codexPluginDelta(_ image: ImageName) -> ([String], [String]) {
    let template = try? TemplateStore.load(config, image)
    return Self.pluginDelta(
      wantedMarketplaces: config.codex.marketplaces, wantedPlugins: config.codex.plugins,
      bakedMarketplaces: template?.codexMarketplaces ?? [],
      bakedPlugins: template?.codexPlugins ?? [])
  }

  /// The host directory a `config_dir` names, if it exists.
  func configSourceDirectory(_ directory: ConfigDirectory, defaultName: String, label: String)
    -> String?
  {
    let path: String
    switch directory {
    case .disabled:
      diagnostics.debug("\(label) is disabled, skipping")
      return nil
    case .default:
      guard let home else {
        diagnostics.debug("Could not determine home directory, skipping config copy")
        return nil
      }
      path = HostPath(absolute: home).appending(defaultName).path
    case .custom(let custom): path = custom.path
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      if case .custom = directory {
        diagnostics.warn("\(label) '\(path)' does not exist, skipping")
      } else {
        diagnostics.debug("Default config dir \(path) does not exist, skipping")
      }
      return nil
    }
    return path
  }

  /// Start (or, when proxy mode does not apply, stop) one provider's
  /// proxy. Proxy mode is remote model mode plus an effective upstream.
  public func startAgentProxy(
    _ instance: Instance, provider: ProxyProvider, modelState: ModelState, target: SSHTarget
  ) throws -> ProxyHandle? {
    let upstream =
      modelState.mode == .remote
      ? try ProxyState.effectiveUpstream(instance, provider, config: config.proxy) : nil
    guard let upstream else {
      proxies.stop(instance, provider: provider)
      return nil
    }
    return try proxies.start(instance, provider: provider, upstream: upstream, target: target)
  }

  /// Copy a local marketplace directory into the guest; other sources pass
  /// through unchanged.
  func stageMarketplaceSource(
    _ session: SSHSession, tool: String, source: String, madeDirectory: inout Bool
  ) throws -> String {
    var isDirectory: ObjCBool = false
    guard source.hasPrefix("/"),
      FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return source }
    let toolDirectory = "~/.coop/marketplaces/\(tool)"
    if !madeDirectory {
      try client.exec(session.target, RemoteCommand().literal("mkdir -p \(toolDirectory)"))
      madeDirectory = true
    }
    let name = (source as NSString).lastPathComponent
    guard !name.isEmpty, name != "/" else {
      throw HostError("marketplace path has no directory name")
    }
    let remote = GuestPath("\(toolDirectory)/\(name)")
    diagnostics.log(.info, "Copying local marketplace to guest: \(source) -> \(remote)")
    do {
      try client.copy(session.target, local: source, remote: remote, recursive: true)
    } catch {
      throw ContextError("Failed to copy marketplace '\(source)' to guest", cause: error)
    }
    return remote.rawValue
  }

  /// Every entry of a staging directory into `~/<subdirectory>`.
  func copyStaged(
    _ staging: StagingDirectory, target: SSHTarget, to subdirectory: String, label: String
  ) throws {
    let entries = try staging.entries()
    guard !entries.isEmpty else {
      diagnostics.debug("No \(label) config content to copy")
      return
    }
    try client.exec(target, RemoteCommand().literal("mkdir -p ~/\(subdirectory)"))
    let guestDirectory = GuestPath("./\(subdirectory)")
    for entry in entries {
      let path = staging.path + "/" + entry
      var isDirectory: ObjCBool = false
      _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      do {
        try client.copy(
          target, local: path, remote: guestDirectory, recursive: isDirectory.boolValue)
      } catch {
        throw ContextError("Failed to copy \(path) to guest", cause: error)
      }
    }
    diagnostics.log(.info, "Copied \(label) config into guest")
  }
}
