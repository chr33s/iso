// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets

/// GitHub token handling, ported separately. Bootstrap consults it for the
/// repository an instance works on, the VM's PAT assignment, the token to
/// forward as `GITHUB_TOKEN`, and the guest `gh` credential helper.
package protocol GitHubTokenSource: Sendable {
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
package enum BootMode: Sendable, Equatable {
  case firstBoot
  case restart
}

/// Guest locations of the agent launchers.
package enum GuestBinaries {
  /// Stable system link to the guest user's native Codex launcher.
  package static let codex = GuestPath("/usr/local/bin/codex")
  /// Codex under a guest Secret Service session (ChatGPT account auth).
  package static let codexAccount = GuestPath("/usr/local/bin/codex-account")
}

extension GuestUser {
  /// Where the Claude Code installer puts the per-user binary.
  package var claudeBinary: GuestPath { GuestPath("/home/\(rawValue)/.local/bin/claude") }
}

/// Agent bootstrap, guest sessions and post-start hooks for one command.
package struct AgentBootstrap: Sendable {
  package let config: IsoConfig
  let client: SSHClient
  /// The host process environment (`env_forward`, provider key fallbacks).
  let environment: [String: String]
  /// For the default `~/.claude` / `~/.codex` sources.
  let home: String?
  let resolver: CredentialResolver
  package let proxies: ProxyLauncher
  let github: any GitHubTokenSource
  let diagnostics: Diagnostics
  /// For `{vault:}` entries in `guest_env.json`; nil refuses them.
  let secrets: (any SecretReferenceResolver)?

  package init(
    config: IsoConfig, client: SSHClient, environment: [String: String], home: String?,
    resolver: CredentialResolver, proxies: ProxyLauncher, github: any GitHubTokenSource,
    diagnostics: Diagnostics, secrets: (any SecretReferenceResolver)? = nil
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
    /// `egress = "none"`: a raw key has no use in the guest and is only a
    /// liability; an explicit declaration is an error.
    case noEgress(ProxyProvider)
    /// ChatGPT account auth keeps Codex credentials in the guest keyring.
    case chatgptAuth

    var description: String {
      switch self {
      case .proxied: "proxy mode"
      case .required: "proxy.mode = \"required\""
      case .noEgress: "egress = \"none\""
      case .chatgptAuth: AgentBootstrap.chatgptReason
      }
    }
  }

  /// Recognized provider variables withheld from the guest. A proxied
  /// provider withholds all of its variables; `proxy.mode = "required"` and
  /// `egress = "none"` withhold every provider's; ChatGPT account auth
  /// withholds `OPENAI_API_KEY`.
  func withheldVariables(proxyAnthropic: Bool, proxyOpenAI: Bool) -> [String: WithholdReason] {
    let required = config.proxy.mode == .required
    let noEgress = config.egress == .none
    var out: [String: WithholdReason] = [:]
    for (provider, proxied) in [(ProxyProvider.anthropic, proxyAnthropic), (.openai, proxyOpenAI)] {
      guard proxied || required || noEgress else { continue }
      for name in provider.recognizedVariables {
        out[name] =
          required ? .required(provider) : noEgress ? .noEgress(provider) : .proxied
      }
    }
    if config.codexAuth == .chatgpt && out["OPENAI_API_KEY"] == nil {
      out["OPENAI_API_KEY"] = .chatgptAuth
    }
    return out
  }

  /// An explicit declaration of a withheld variable: under `required` or
  /// `egress = "none"` an error, otherwise a warning (the historical
  /// proxy-mode behavior).
  func refuse(_ name: String, from source: String, reason: WithholdReason) throws {
    switch reason {
    case .required(let provider), .noEgress(let provider):
      throw HostError(
        "\(reason): \(source) entry '\(name)' would put a provider credential in the guest; remove it or configure `proxy.\(provider.rawValue)`"
      )
    case .proxied, .chatgptAuth: break
    }
    diagnostics.warn("\(reason): ignoring \(source) entry '\(name)'")
  }

  /// Values forwarded with `SendEnv`. Recognized provider variables are
  /// withheld per `withheldVariables`; `cmd:` keys are resolved here, when a
  /// session needs them.
  package func prepareEnvForwarding(
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
    try proxyConfigured(
      instance, provider, entries: GuestEnvState.tryLoad(instance)?.entries ?? [:])
  }

  /// `proxyConfigured` for guest variables that may not be persisted yet.
  func proxyConfigured(
    _ instance: Instance, _ provider: ProxyProvider, entries: [EnvVarName: EnvValue]
  ) throws -> Bool {
    let routed = try GuestEnvState.providerSecrets(entries)[provider]
    guard config.proxy.mode != .off else {
      if let routed { throw ProxyState.unavailable(routed) }
      return false
    }
    return try routed != nil || ProxyState.load(instance).override(for: provider) != nil
      || config.proxy.upstream(for: provider) != nil
  }

  /// Refuses a remote-model VM that `proxy.mode = "required"` or
  /// `egress = "none"` would leave without a provider proxy. `guestEnvironment`
  /// is the variable set the VM will run with, which is not persisted yet
  /// before any VM work. Under `proxy.mode = "off"` no proxy can exist, so
  /// only a local model (or `--no-agents`) passes with `egress = "none"`.
  package func requireProviderProxy(
    _ instance: Instance, noAgents: Bool, guestEnvironment: [EnvVarName: EnvValue]
  ) throws {
    guard !noAgents, config.proxy.mode == .required || config.egress == .none,
      try ModelState.loadOrDefault(instance).mode == .remote
    else { return }
    let configured =
      try proxyConfigured(instance, .anthropic, entries: guestEnvironment)
      || proxyConfigured(instance, .openai, entries: guestEnvironment)
    guard !configured else { return }
    if config.proxy.mode == .off {
      throw HostError(
        "egress = \"none\" with proxy.mode = \"off\" leaves a remote model unreachable in '\(instance.name)'; use a local model (`iso model \(instance.name) local`) or pass --no-agents"
      )
    }
    throw HostError(
      config.proxy.mode == .required
        ? "proxy.mode = \"required\" but no provider proxy is configured for '\(instance.name)'; run `iso proxy setup` (or set proxy.mode to \"auto\")"
        : "egress = \"none\" leaves a remote model reachable only through the credential proxy, and none is configured for '\(instance.name)'; run `iso proxy setup`, or `iso model \(instance.name) local`"
    )
  }

  /// Every stored secret this session reads (the persisted `--env`
  /// references and the GitHub PAT for `repo`), resolved in one unlock so the
  /// resolutions that follow are cache hits and the user is asked once.
  func prefetchSessionSecrets(_ instance: Instance?, repo: RepoSlug?) throws {
    var names = Set<SecretName>()
    if let instance, let state = try GuestEnvState.tryLoad(instance) {
      let routed = Set(try state.providerSecrets().values.map(\.variable))
      names.formUnion(
        state.entries.filter { !routed.contains($0.key) }.values.compactMap(\.reference))
    }
    if let name = GitHubAssignment.vaultName(config, slug: repo) { names.insert(name) }
    guard !names.isEmpty, let secrets else { return }
    _ = try secrets.resolve(names)
  }

  /// A session for `target`. With an instance, proxy-mode key suppression,
  /// the persisted `--env` snapshot and the Codex provider key apply.
  package func prepareSession(_ instance: Instance?, target: SSHTarget, repo: RepoSlug?) throws
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
    try prefetchSessionSecrets(instance, repo: assigned ?? repo)
    var env = try prepareEnvForwarding(
      repo: assigned ?? repo, suppressAnthropicKey: proxyAnthropic,
      suppressOpenAIKey: proxyOpenAI)
    if let instance {
      if let state = try GuestEnvState.tryLoad(instance) {
        let proxyNames = try ProxyState.storedCredentialNames(config.proxy, instance: instance)
        try GuestEnvState.checkCredentialSeparation(state.entries, proxyCredentialNames: proxyNames)
        let routed = Set(try state.providerSecrets().values.map(\.variable))
        let withheld = withheldVariables(proxyAnthropic: proxyAnthropic, proxyOpenAI: proxyOpenAI)
        let resolved = try resolveReferences(state, excluding: routed)
        for (name, value) in state.sortedEntries {
          // A provider secret feeds that provider's proxy, never the guest.
          if routed.contains(name) { continue }
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
    if config.egress == .filtered, let instance {
      try applyFilteredProxy(&env, instance)
    }
    return SSHSession(target: target, env: env)
  }

  /// Managed proxy variables for a filtered boot. User config cannot override
  /// them. The capability is guest-visible by design and is not logged.
  func applyFilteredProxy(_ env: inout EnvForward, _ instance: Instance) throws {
    guard let bytes = try StateStore.readControlFile(EgressPorts.capabilityPath(instance)),
      let capability = String(validating: bytes, as: UTF8.self), !capability.isEmpty
    else {
      throw HostError(
        "filtered egress has no capability for '\(instance.name)'; restart the instance"
      )
    }
    let port = EgressPorts.port(instance)
    let value = Secret("http://iso:\(capability)@127.0.0.1:\(port)")
    for name in ["http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"] {
      env.set(name, value)
    }
    env.set("NO_PROXY", Secret("localhost,127.0.0.1"))
    env.set("no_proxy", Secret("localhost,127.0.0.1"))
  }

  /// One batch resolution for every reference in `state`, each checked to
  /// be a usable environment value (UTF-8, no NUL). Values are guest-visible
  /// by design; they are never persisted or logged on the host.
  func resolveReferences(_ state: GuestEnvState, excluding routed: Set<EnvVarName> = [])
    throws -> [SecretName: Secret<String>]
  {
    let names = Set(
      state.entries.filter { !routed.contains($0.key) }.values.compactMap(\.reference))
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
  package func openSession(
    _ backend: AppleBackend, name: InstanceName?, instances: [Instance]
  ) throws -> (AppleBackend.Running, WorkloadSession) {
    let running = try backend.resolveRunning(name, instances: instances)
    return (running, try workloadSession(for: running, backend: backend))
  }

  /// Preparation may unlock secrets or otherwise outlive the original proof.
  /// Recheck afterwards and retain the same check for the final workload launch.
  package func workloadSession(for running: AppleBackend.Running, backend: AppleBackend) throws
    -> WorkloadSession
  {
    let session = try self.session(for: running)
    let revalidate: @Sendable () throws -> Void = {
      try WorkloadHandoff.require(running) { try backend.asRunning(running.instance) }
    }
    return try WorkloadSession(session: session, revalidate: revalidate)
  }

  /// Retains the running target's proof across host-side environment preparation.
  package func session(for running: AppleBackend.Running) throws -> SSHSession {
    let session = try prepareSession(
      running.instance, target: running.target, repo: github.instanceRepo(running.instance))
    try session.target.requireHandoff()
    return session
  }

  // MARK: - Post-boot sequence

  package static let noAgentsChatGPTWarning =
    "codex.auth = \"chatgpt\" is configured but --no-agents skips agent bootstrap; the guest keyring credential store will not be set up, so `iso codex -- login` would store credentials in a plaintext ~/.codex/auth.json in the guest"

  /// Whether `--no-agents` leaves this VM's Codex writing plaintext
  /// credentials. `keyringMaterialized` is read only when needed.
  package static func noAgentsSkipsCodexKeyring(
    noAgents: Bool, auth: CodexAuthMode, keyringMaterialized: () -> Bool
  ) -> Bool {
    noAgents && auth == .chatgpt && !keyringMaterialized()
  }

  /// After a fresh or restarted boot: close the previous boot's model
  /// tunnels, bootstrap the agents (unless `noAgents`), then run the
  /// post-start hook. `up`/`start` call this once SSH is ready.
  @discardableResult
  package func bootstrapAndPostStart(
    _ instance: Instance, target: SSHTarget, repo: RepoSlug?, noAgents: Bool,
    postStartOverride: String?, mode: BootMode, skipAgentBootstrap: Bool = false,
    runtime: SandboxRuntime? = nil
  ) throws -> SSHTarget {
    proxies.stopModelTunnels(instance)
    try proxies.startEgress(instance, config: config, target: target, runtime: runtime)
    let preparation = try bootstrapRunning(instance, fallback: target, runtime: runtime)
    let preparationTarget = preparation?.target ?? target
    recordBoot(instance)
    let postStart = postStartOverride ?? config.postStart
    let proxyConfigured =
      try proxyConfigured(instance, .anthropic) || proxyConfigured(instance, .openai)
    if noAgents && proxyConfigured {
      diagnostics.warn(
        "proxy mode is configured but --no-agents skips agent bootstrap; agents will not be able to authenticate in this VM"
      )
    }
    try requireProviderProxy(
      instance, noAgents: noAgents,
      guestEnvironment: GuestEnvState.tryLoad(instance)?.entries ?? [:])
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
      try preparationTarget.requireHandoff()
      return try requireFilteredHandoff(instance, runtime: runtime, preparation: preparation)
        ?? preparationTarget
    }
    let session = try prepareSession(instance, target: preparationTarget, repo: repo)
    try preparationTarget.requireHandoff()
    let raw = ProxyProvider.allCases.flatMap(\.recognizedVariables).filter(session.env.contains)
    if !raw.isEmpty {
      BoundaryAudit.record(instance, .rawProviderForward(raw), diagnostics: diagnostics)
      diagnostics.warn(
        "forwarding \(raw.joined(separator: ", ")) into the guest in plain text; `iso proxy setup` keeps provider credentials on the host"
      )
    }
    if noAgents || skipAgentBootstrap {
      diagnostics.log(
        .info,
        noAgents
          ? "Skipping guest agent bootstrap (--no-agents)"
          : "Skipping unrelated Claude/Codex bootstrap for a no-auth launch")
    } else {
      try bootstrapAgents(session, instance: instance, mode: mode)
    }
    try preparationTarget.requireHandoff()
    let hookTarget =
      try requireFilteredHandoff(instance, runtime: runtime, preparation: preparation)
      ?? preparationTarget
    if let postStart {
      // Capture composite identity before preparing the hook's environment.
      let hookSession =
        noAgents
        ? SSHSession(target: hookTarget, env: session.env)
        : try prepareSession(instance, target: hookTarget, repo: repo)
      try hookTarget.requireHandoff()
      try runPostStart(hookSession, command: postStart)
    }
    return hookTarget
  }

  func bootstrapRunning(_ instance: Instance, fallback: SSHTarget, runtime: SandboxRuntime?) throws
    -> AppleBackend.Running?
  {
    guard config.egress == .filtered else { return nil }
    guard let runtime else {
      throw HostError("FILTERED_EGRESS_NOT_READY: missing runtime for bootstrap")
    }
    let backend = AppleBackend(
      config: config, environment: environment, runtime: { () throws(RuntimeError) in runtime })
    guard let running = try backend.asBootstrapRunning(instance), running.target == fallback else {
      throw HostError("FILTERED_HANDOFF_CHANGED: bootstrap target changed or stopped")
    }
    return running
  }

  @discardableResult
  func requireFilteredHandoff(
    _ instance: Instance, runtime: SandboxRuntime?, preparation: AppleBackend.Running? = nil
  ) throws -> SSHTarget? {
    guard config.egress == .filtered else { return nil }
    guard let runtime else {
      throw HostError("FILTERED_EGRESS_NOT_READY: missing runtime for handoff")
    }
    let backend = AppleBackend(
      config: config, environment: environment, runtime: { () throws(RuntimeError) in runtime })
    if let preparation { return try backend.completeBootstrap(preparation).target }
    guard let running = try backend.asRunning(instance) else {
      throw HostError("FILTERED_EGRESS_NOT_READY: sandbox stopped during bootstrap")
    }
    return running.target
  }

  /// The boot's boundary policy, for `iso audit` (names and modes only).
  func recordBoot(_ instance: Instance) {
    let state = try? GuestEnvState.tryLoad(instance)
    let routed = (try? state?.providerSecrets()) ?? [:]
    let routedNames = Set(routed.values.map(\.variable))
    let references =
      state?.entries.filter { !routedNames.contains($0.key) && $0.value.reference != nil }.count
      ?? 0
    let proxied = ProxyProvider.allCases.filter { (try? proxyConfigured(instance, $0)) == true }
    BoundaryAudit.record(
      instance,
      .boot(
        egress: config.egress, proxyMode: config.proxy.mode, proxied: proxied,
        providerSecrets: routedNames.map(\.rawValue), guestReferences: references,
        sessionTTL: config.limits.sessionTTL), diagnostics: diagnostics)
  }

  /// Ordinary guest-command failures warn; readiness refusals abort the handoff.
  package func runPostStart(_ session: SSHSession, command: String) throws {
    diagnostics.log(.info, "Running post_start hook in guest")
    diagnostics.debug("post_start: \(command)")
    do {
      try client.exec(session, RemoteCommand().literal(command))
      diagnostics.debug("post_start hook completed")
    } catch let failure as GuestHandoffFailure {
      throw failure
    } catch {
      diagnostics.warn("post_start hook failed (continuing): \(error)")
    }
  }

  /// GitHub auth, local-model tunnels, then Claude and Codex.
  package func bootstrapAgents(_ session: SSHSession, instance: Instance, mode: BootMode) throws {
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
  package func persistedGuestUser(_ image: ImageName) -> GuestUser {
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
  package func startAgentProxy(
    _ instance: Instance, provider: ProxyProvider, modelState: ModelState, target: SSHTarget
  ) throws -> ProxyHandle? {
    let upstream =
      modelState.mode == .remote
      ? try ProxyState.effectiveUpstream(instance, provider, config: config.proxy) : nil
    guard let upstream else {
      proxies.stop(instance, provider: provider)
      return nil
    }
    let policy: FilteredHandoff.BootPolicy?
    if config.egress == .filtered {
      guard let recorded = try FilteredHandoff.recordedPolicy(instance) else {
        throw HostError(
          "FILTERED_BROKER_NOT_READY: missing filtered boot policy; restart the instance")
      }
      policy = recorded
    } else {
      policy = nil
    }
    return try proxies.start(
      instance, provider: provider, upstream: upstream, target: target, readinessPolicy: policy)
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
    let toolDirectory = "~/.iso/marketplaces/\(tool)"
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
