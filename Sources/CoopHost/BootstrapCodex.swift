import CoopConfiguration
import CoopCore
import Foundation

/// Codex account-auth and proxy consistency checks shared by bootstrap and
/// `coop codex`.
public enum CodexChecks {
  public static let missingGuestCLIMessage =
    "Codex CLI is not installed in the guest.\nThe golden image may have been built before Codex support was added, or the install failed silently.\nIf you want to skip Codex bootstrap for now, retry with `--no-agents` (the `--no-claude` alias is deprecated).\nOtherwise run `coop setup --rebuild` to rebuild the image."

  public static let chatgptProxyConflictMessage =
    "codex.auth = \"chatgpt\" conflicts with the effective OpenAI proxy for this VM; Codex account auth uses ChatGPT workspace credentials, while the OpenAI proxy uses an API key"

  public static let keyringNotConfiguredMessage =
    "Codex ChatGPT account auth is configured, but this VM's guest ~/.codex/config.toml does not select the keyring credential store.\ncoop writes that setting during agent bootstrap, so a VM started before `auth = \"chatgpt\"` was set (or started with `--no-agents`) has not got it yet, and Codex would write its account credentials to a plaintext ~/.codex/auth.json in the guest instead.\nRun `coop start` (without `--no-agents`) to bootstrap it."

  public static let accountGuestSupportMessage =
    "Codex ChatGPT account auth requires guest Secret Service support, but this VM image does not have it.\nRebuild the image with `coop setup --rebuild` (or `coop setup --image <name> --rebuild` for a named image).\nA rebuild does not touch this VM's existing guest disk, and a restart reuses it. To pick up the rebuilt image, either `coop restore <vm> --image <image> --reprovision` (in place, keeping the instance), or destroy and recreate the VM. Alternatively, install `dbus-user-session`, `gnome-keyring`, and `libsecret-tools` in the running guest by hand."

  /// A per-VM OpenAI proxy override or an OpenAI provider secret cannot pair
  /// with ChatGPT account auth (the configuration check sees neither).
  public static func ensureRemoteAuthConsistent(
    _ config: CoopConfig, instance: Instance, modelState: ModelState
  ) throws {
    guard config.codexAuth == .chatgpt, modelState.mode == .remote else { return }
    let state = try ProxyState.load(instance)
    let routed = try GuestEnvState.tryLoad(instance)?.providerSecrets()[.openai]
    if state.override(for: .openai) != nil || config.proxy.openai != nil || routed != nil {
      throw HostError(chatgptProxyConflictMessage)
    }
  }

  /// The guest wrapper passes through to plain Codex unless the guest's own
  /// config selects the keyring store; refuse rather than let `codex login`
  /// write a plaintext token.
  public static func ensureKeyringConfigured(_ client: SSHClient, _ target: SSHTarget) throws {
    let configured = client.succeeds(
      target,
      RemoteCommand().literal(
        "IFS= read -r first_line < ~/.codex/config.toml && [ \"$first_line\" = 'cli_auth_credentials_store = \"keyring\"' ]"
      ))
    guard configured else { throw HostError(keyringNotConfiguredMessage) }
  }

  public static func ensureAccountGuestSupport(_ client: SSHClient, _ target: SSHTarget) throws {
    let supported = client.succeeds(
      target,
      RemoteCommand().literal("test -x ").arg(GuestBinaries.codexAccount.rawValue)
        .literal(" && command -v dbus-run-session >/dev/null 2>&1")
        .literal(" && command -v gnome-keyring-daemon >/dev/null 2>&1")
        .literal(" && command -v secret-tool >/dev/null 2>&1"))
    guard supported else { throw HostError(accountGuestSupportMessage) }
  }

  /// `coop codex` launch argv: Codex's sandbox and approvals are bypassed
  /// (the VM is the boundary) unless `--ask`; `login`/`logout` never get
  /// the flag.
  public static func launchArguments(ask: Bool, _ arguments: [String]) -> [String] {
    let isAuthSubcommand = ["login", "logout"].contains(arguments.first ?? "")
    return !ask && !isAuthSubcommand
      ? ["--dangerously-bypass-approvals-and-sandbox"] + arguments : arguments
  }
}

/// The Codex `~/.codex` content coop manages.
enum CodexConfigFiles {
  static let allowedFiles = ["AGENTS.md", "auth.json"]
  static let allowedDirectories = ["prompts"]
  static let configFile = "config.toml"
  /// Guest-owned tables carried across coop's rewrite of `config.toml`.
  static let preservedGuestTables = ["marketplaces", "plugins", "projects"]

  /// `auth.json` is dropped in proxy mode (the capability token replaces
  /// it), under `proxy.mode = "required"` (it can hold a raw OpenAI key even
  /// when OpenAI has no proxy), and in ChatGPT account mode (the guest keyring
  /// holds credentials).
  static func allowedFiles(proxyActive: Bool, proxyMode: ProxyMode, auth: CodexAuthMode)
    -> [String]
  {
    proxyActive || proxyMode == .required || auth == .chatgpt
      ? allowedFiles.filter { $0 != "auth.json" } : allowedFiles
  }

  static func sourceHasBootstrapContent(_ source: String?) -> Bool {
    guard let source else { return false }
    return allowedFiles.contains { HostFiles.isFile(source + "/" + $0) }
      || HostFiles.isFile(source + "/" + configFile)
      || allowedDirectories.contains { HostFiles.isDirectory(source + "/" + $0) }
  }

  static func bootstrapNeeded(
    source: String?, mcpServers: [String: MCPServer], hasPlugins: Bool, auth: CodexAuthMode
  ) -> Bool {
    sourceHasBootstrapContent(source) || !mcpServers.isEmpty || hasPlugins || auth == .chatgpt
  }

  /// Whether this boot rewrites the guest `config.toml` (and so must first
  /// read the guest's plugin tables to carry them over).
  static func needsRewrite(
    source: String?, mcpServers: [String: MCPServer], local: TOMLTable?, managesLocal: Bool,
    auth: CodexAuthMode, keyringMaterialized: Bool
  ) -> Bool {
    (source.map { HostFiles.isFile($0 + "/" + configFile) } ?? false) || !mcpServers.isEmpty
      || local != nil || managesLocal || auth == .chatgpt || keyringMaterialized
  }

  /// The guest's own plugin/project tables; nil when there are none, an
  /// error when the file is present but not TOML.
  static func extractPluginState(_ configTOML: String) throws -> TOMLTable? {
    let parsed: TOMLTable
    do { parsed = try TOMLTable.parse(configTOML) } catch {
      throw ContextError("guest ~/.codex/config.toml is not valid TOML", cause: error)
    }
    var preserved = TOMLTable()
    for key in preservedGuestTables {
      if let value = parsed[key] { preserved[key] = value }
    }
    return preserved.isEmpty ? nil : preserved
  }

  /// Stage allowlisted files and, when a rewrite is due, the merged
  /// `config.toml`: host base, managed MCP servers, the local/proxy
  /// provider block, the coop-owned keyring key, and the guest's own
  /// plugin tables (host copies of those are dropped).
  static func stage(
    source: String?, mcpServers: [String: TOMLValue], local: TOMLTable?, managesLocal: Bool,
    preserved: TOMLTable?, proxyActive: Bool, proxyMode: ProxyMode, auth: CodexAuthMode,
    keyringMaterialized: Bool,
    hasMCPServers: Bool, diagnostics: Diagnostics
  ) throws -> StagingDirectory {
    let staging = try StagingDirectory()
    do {
      var config = TOMLTable()
      if let source {
        do {
          try staging.stage(
            from: source,
            files: allowedFiles(proxyActive: proxyActive, proxyMode: proxyMode, auth: auth),
            directories: allowedDirectories)
        } catch {
          throw ContextError("Failed to stage Codex allowlisted files", cause: error)
        }
        let path = source + "/" + configFile
        if HostFiles.isFile(path) {
          guard let data = FileManager.default.contents(atPath: path),
            let text = String(validating: Array(data), as: UTF8.self)
          else { throw HostError("Failed to read \(configFile)") }
          do { config = try TOMLTable.parse(text) } catch {
            throw ContextError("Failed to parse Codex \(configFile)", cause: error)
          }
        }
      }
      if !mcpServers.isEmpty {
        if config.contains("mcp_servers") {
          diagnostics.warn(
            "Replacing existing [mcp_servers] in Codex \(configFile) with servers from coop config")
        }
        config["mcp_servers"] = .table(TOMLTable(mcpServers.map { ($0, $1) }))
      }
      if let local {
        for key in local.sortedKeys { config[key] = local[key] }
      }
      config.remove("cli_auth_credentials_store")
      for key in preservedGuestTables { config.remove(key) }
      if let preserved {
        for key in preserved.sortedKeys { config[key] = preserved[key] }
      }
      let rewrite =
        (source.map { HostFiles.isFile($0 + "/" + configFile) } ?? false) || hasMCPServers
        || local != nil || managesLocal || auth == .chatgpt || keyringMaterialized
      if rewrite {
        var serialized = config.document
        if auth == .chatgpt {
          serialized = "cli_auth_credentials_store = \"keyring\"\n" + serialized
        }
        do {
          try AtomicFile.write(
            Array(serialized.utf8), to: staging.path + "/" + configFile,
            mode: .preserveExisting(default: 0o644))
        } catch {
          throw ContextError("Failed to stage Codex \(configFile)", cause: error)
        }
      }
      return staging
    } catch {
      staging.remove()
      throw error
    }
  }
}

extension AgentBootstrap {
  /// Codex: auth consistency, proxy (fail closed), `~/.codex` content and
  /// managed `config.toml`, keyring bookkeeping, stale `auth.json` cleanup,
  /// then — on first boot — marketplaces and plugins. A proxy started here
  /// is torn down if a later step fails.
  func bootstrapCodex(_ session: SSHSession, instance: Instance, mode: BootMode) throws {
    var modelState = try ModelState.loadOrDefault(instance)
    try CodexChecks.ensureRemoteAuthConsistent(config, instance: instance, modelState: modelState)
    let proxy = try startAgentProxy(
      instance, provider: .openai, modelState: modelState, target: session.target)
    do {
      let codex = config.codex
      let source = configSourceDirectory(
        codex.configDirectory, defaultName: ".codex", label: "codex.config_dir")
      let local = try codexProviderTable(modelState, proxy: proxy)
      if local != nil && !modelState.codexMaterialized {
        modelState.codexMaterialized = true
        try modelState.save(instance, diagnostics: diagnostics)
      }
      let managesLocal =
        local != nil || modelState.resolvedCodex(codex) != nil || modelState.codexMaterialized
      let hasPlugins = !codex.marketplaces.isEmpty || !codex.plugins.isEmpty
      let needsCodex =
        CodexConfigFiles.bootstrapNeeded(
          source: source, mcpServers: codex.mcpServers, hasPlugins: hasPlugins,
          auth: config.codexAuth)
        || managesLocal || modelState.codexKeyringMaterialized
      guard needsCodex else { return }

      if config.codexAuth == .chatgpt {
        try CodexChecks.ensureAccountGuestSupport(client, session.target)
      }
      guard
        client.succeeds(
          session.target, RemoteCommand().literal("test -x ").arg(GuestBinaries.codex.rawValue))
      else { throw HostError(CodexChecks.missingGuestCLIMessage) }

      try copyCodexConfig(
        session.target, source: source, local: local, managesLocal: managesLocal,
        proxyActive: proxy != nil, keyringMaterialized: modelState.codexKeyringMaterialized)

      // Recorded only once the guest actually has (or has lost) the key.
      let wantsKeyring = config.codexAuth == .chatgpt
      if wantsKeyring != modelState.codexKeyringMaterialized {
        modelState.codexKeyringMaterialized = wantsKeyring
        try modelState.save(instance, diagnostics: diagnostics)
      }

      if proxy != nil {
        try removeGuestCodexAuthJSON(session.target)
      } else if wantsKeyring {
        do { try removeGuestCodexAuthJSON(session.target) } catch {
          diagnostics.warn(
            "Could not remove a possible stale plaintext ~/.codex/auth.json from the guest; Codex account auth stores credentials in the guest keyring, so any such file is unused but still readable: \(oneLineError(error))"
          )
        }
      }

      if mode == .firstBoot {
        let (marketplaces, plugins) = codexPluginDelta(instance.image)
        if !marketplaces.isEmpty { try installCodexMarketplaces(session, marketplaces) }
        if !plugins.isEmpty { try installCodexPlugins(session, plugins) }
      }
      diagnostics.log(
        .info, mode == .restart ? "Codex bootstrap refreshed" : "Codex bootstrap complete")
    } catch {
      if proxy != nil { proxies.stop(instance, provider: .openai) }
      throw error
    }
  }

  /// Local mode wins over proxy mode; nil when neither applies.
  func codexProviderTable(_ state: ModelState, proxy: ProxyHandle?) throws -> TOMLTable? {
    if let endpoint = LocalEndpoints.active(state, state.resolvedCodex(config.codex)) {
      let plan = try LocalEndpoints.plan(endpoint.hostURL)
      return ModelRouting.codexLocalConfig(baseURL: plan.guestURL, model: endpoint.model)
    }
    if let proxy { return ModelRouting.codexProxyConfig(baseURL: proxy.baseURL) }
    return nil
  }

  func removeGuestCodexAuthJSON(_ target: SSHTarget) throws {
    do {
      try client.exec(target, RemoteCommand().literal("rm -f ~/.codex/auth.json"))
    } catch {
      throw ContextError("Failed to remove stale guest ~/.codex/auth.json", cause: error)
    }
  }

  /// The guest's plugin tables, read only when a rewrite will happen. A
  /// failed read or parse warns: the rewrite drops those tables.
  func readCodexPluginState(_ target: SSHTarget) -> TOMLTable? {
    do {
      let existing = try client.captureChecked(
        target, RemoteCommand().literal("cat ~/.codex/config.toml 2>/dev/null || true"))
      do {
        return try CodexConfigFiles.extractPluginState(existing)
      } catch {
        diagnostics.warn(
          "Could not parse guest ~/.codex/config.toml to preserve installed Codex marketplaces/plugins across the config refresh; they may be dropped and need reinstalling: \(oneLineError(error))"
        )
        return nil
      }
    } catch {
      diagnostics.warn(
        "Could not read guest ~/.codex/config.toml to preserve installed Codex marketplaces/plugins across the config refresh: \(oneLineError(error))"
      )
      return nil
    }
  }

  func codexMCPTables() throws -> [String: TOMLValue] {
    var tables: [String: TOMLValue] = [:]
    for (name, server) in MCPServer.sorted(config.codex.mcpServers) {
      tables[name] = try server.resolvingHeaders(resolver, label: "Codex MCP server", name: name)
        .toml
    }
    return tables
  }

  func copyCodexConfig(
    _ target: SSHTarget, source: String?, local: TOMLTable?, managesLocal: Bool,
    proxyActive: Bool, keyringMaterialized: Bool
  ) throws {
    let codex = config.codex
    let rewrite = CodexConfigFiles.needsRewrite(
      source: source, mcpServers: codex.mcpServers, local: local, managesLocal: managesLocal,
      auth: config.codexAuth, keyringMaterialized: keyringMaterialized)
    let preserved = rewrite ? readCodexPluginState(target) : nil
    let staging: StagingDirectory
    do {
      staging = try CodexConfigFiles.stage(
        source: source, mcpServers: try codexMCPTables(), local: local, managesLocal: managesLocal,
        preserved: preserved, proxyActive: proxyActive, proxyMode: config.proxy.mode,
        auth: config.codexAuth,
        keyringMaterialized: keyringMaterialized, hasMCPServers: !codex.mcpServers.isEmpty,
        diagnostics: diagnostics)
    } catch {
      throw ContextError("Failed to stage Codex config files", cause: error)
    }
    defer { staging.remove() }
    try copyStaged(staging, target: target, to: ".codex", label: "Codex")
  }

  func installCodexMarketplaces(_ session: SSHSession, _ marketplaces: [String]) throws {
    var madeDirectory = false
    for source in marketplaces {
      let guestSource = try stageMarketplaceSource(
        session, tool: "codex", source: source, madeDirectory: &madeDirectory)
      diagnostics.log(.info, "Adding Codex marketplace: \(guestSource)")
      do {
        try client.exec(
          session,
          RemoteCommand().arg(GuestBinaries.codex.rawValue).literal(" plugin marketplace add ")
            .arg(guestSource))
      } catch {
        throw ContextError("Failed to add Codex marketplace '\(source)'", cause: error)
      }
    }
  }

  func installCodexPlugins(_ session: SSHSession, _ plugins: [String]) throws {
    for plugin in plugins {
      diagnostics.log(.info, "Installing Codex plugin: \(plugin)")
      do {
        try client.exec(
          session,
          RemoteCommand().arg(GuestBinaries.codex.rawValue).literal(" plugin add ").arg(plugin))
      } catch {
        throw ContextError("Failed to install Codex plugin '\(plugin)'", cause: error)
      }
    }
  }
}
