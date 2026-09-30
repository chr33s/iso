import Foundation
import IsoConfiguration
import IsoCore

/// Claude customization import: complete bundles copied as files, plus the
/// few host preferences that have a companion in that content.
enum ClaudeImport {
  /// Top-level content copied verbatim; settings are merged narrowly.
  static let allowedFiles = ["CLAUDE.md", "keybindings.json"]
  /// Complete recursive bundles (plugin-local hooks and monitors included).
  static let allowedDirectories = [
    "rules", "commands", "skills", "agents", "output-styles", "themes", "workflows",
  ]
  static let stateKey = "_isoImportedPreferences"

  /// Only preferences with a companion in the copied content.
  struct Preferences: Equatable {
    var disableAllHooks: Bool?
    var outputStyle: String?
    var enabledPlugins: [String: Bool] = [:]

    var isEmpty: Bool { disableAllHooks == nil && outputStyle == nil && enabledPlugins.isEmpty }

    var json: OrderedJSON {
      var members = OrderedJSON.Members()
      if let disableAllHooks { members["disableAllHooks"] = .bool(disableAllHooks) }
      if let outputStyle { members["outputStyle"] = .string(outputStyle) }
      if !enabledPlugins.isEmpty {
        members["enabledPlugins"] = .object(
          .init(MCPServer.sorted(enabledPlugins).map { ($0, .bool($1)) }))
      }
      return .object(members)
    }

    /// serde `deny_unknown_fields`: only the three keys, strictly typed.
    init?(_ value: OrderedJSON) {
      guard case .object(let members) = value else { return nil }
      for (key, value) in members.pairs {
        switch key {
        case "disableAllHooks":
          switch value {
          case .null: disableAllHooks = nil
          case .bool(let flag): disableAllHooks = flag
          default: return nil
          }
        case "outputStyle":
          switch value {
          case .null: outputStyle = nil
          case .string(let style): outputStyle = style
          default: return nil
          }
        case "enabledPlugins":
          guard case .object(let plugins) = value else { return nil }
          for (id, enabled) in plugins.pairs {
            guard case .bool(let flag) = enabled else { return nil }
            enabledPlugins[id] = flag
          }
        default: return nil
        }
      }
    }

    init() {}
  }

  /// `~/.claude/iso-import.json`: the last imported preferences and every
  /// bundle identity ever copied (copied bundles outlive their source).
  struct Snapshot: Equatable {
    var preferences = Preferences()
    var pluginIDs: Set<String> = []

    init() {}

    init?(_ value: OrderedJSON) {
      guard case .object(let members) = value else { return nil }
      for (key, value) in members.pairs {
        switch key {
        case "preferences":
          guard let preferences = Preferences(value) else { return nil }
          self.preferences = preferences
        case "pluginIds":
          guard case .array(let ids) = value else { return nil }
          for id in ids {
            guard case .string(let text) = id else { return nil }
            pluginIDs.insert(text)
          }
        default: return nil
        }
      }
    }

    var json: OrderedJSON {
      .object(
        .init([
          ("preferences", preferences.json),
          (
            "pluginIds",
            .array(
              pluginIDs.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }.map(
                OrderedJSON.string))
          ),
        ]))
    }
  }

  static func isFormatting(_ scalar: Unicode.Scalar) -> Bool {
    (0x200C...0x200F).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
      || (0x206A...0x206F).contains(scalar.value) || scalar.value == 0xFEFF
  }

  /// Claude's identities for the immediate, non-hidden `skills/` bundles
  /// that carry a plugin manifest: `<manifest name>@skills-dir`. Claude's
  /// sync bookkeeping is refused rather than partially imported.
  static func skillsPluginIDs(_ root: String) throws -> Set<String> {
    let skills = root + "/skills"
    var status = stat()
    if stat(skills, &status) != 0 && errno == ENOENT { return [] }
    let names: [String]
    do { names = try FileManager.default.contentsOfDirectory(atPath: skills) } catch {
      throw HostError("Failed to read \(skills)")
    }
    if lstat(skills + "/manifest.json", &status) == 0 {
      throw HostError(
        "Claude skills sync bookkeeping is not supported by customization import; use a custom config_dir without skills/manifest.json"
      )
    }
    var ids: Set<String> = []
    for name in names {
      var visible = String.UnicodeScalarView()
      visible.append(contentsOf: name.unicodeScalars.filter { !isFormatting($0) })
      if String(visible).hasPrefix(".") { continue }
      var trimmed = Substring(name)
      while trimmed.hasSuffix(".") || trimmed.hasSuffix(" ") { trimmed = trimmed.dropLast() }
      var reserved = String.UnicodeScalarView()
      reserved.append(contentsOf: trimmed.unicodeScalars.filter { !isFormatting($0) })
      if String(reserved).uppercased().lowercased() == "synced" { continue }
      let directory = skills + "/" + name
      guard HostFiles.isDirectory(directory) else { continue }
      let manifestPath = directory + "/.claude-plugin/plugin.json"
      let descriptor = open(manifestPath, O_RDONLY | O_CLOEXEC)
      if descriptor < 0 {
        if errno == ENOENT || errno == ENOTDIR { continue }
        throw HostError.posix("Failed to read", manifestPath)
      }
      close(descriptor)
      guard let data = FileManager.default.contents(atPath: manifestPath),
        let text = String(validating: Array(data), as: UTF8.self)
      else { throw HostError("Failed to read \(manifestPath)") }
      let manifest: OrderedJSON
      do { manifest = try OrderedJSON.parse(text) } catch { throw HostError("\(error)") }
      guard case .string(let pluginName)? = manifest["name"] else {
        throw HostError("Claude plugin manifest must contain a string name")
      }
      let invalid = pluginName.unicodeScalars.contains {
        let v = $0.value
        return v <= 0x1F || (0x7F...0x9F).contains(v) || (0x200E...0x200F).contains(v)
          || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
      }
      if pluginName.isEmpty || pluginName.contains(" ") || invalid {
        throw HostError(
          "Claude plugin manifest name is invalid; fix the plugin manifest in the configured source"
        )
      }
      ids.insert(pluginName + "@skills-dir")
    }
    return ids
  }

  /// The host settings read as data (host Claude is never run). Invalid
  /// relevant preferences stop the bootstrap rather than enable anything.
  static func preferences(source: String, pluginIDs: Set<String>) throws -> Preferences {
    let path = source + "/settings.json"
    let body: String
    if let data = FileManager.default.contents(atPath: path) {
      guard let text = String(validating: Array(data), as: UTF8.self) else {
        throw HostError("Failed to read host Claude settings")
      }
      body = text
    } else if FileManager.default.fileExists(atPath: path) {
      throw HostError("Failed to read host Claude settings")
    } else {
      body = "{}"
    }
    let host: OrderedJSON
    do { host = try OrderedJSON.parse(body) } catch {
      throw ContextError("Host Claude settings must be valid JSON", cause: error)
    }
    guard host.objectMembers != nil else {
      throw HostError("Host Claude settings must be an object")
    }
    var selected = Preferences()
    if let value = host["disableAllHooks"] {
      guard case .bool(let flag) = value else {
        throw HostError("Invalid host Claude companion preference type for disableAllHooks")
      }
      selected.disableAllHooks = flag
    }
    if let value = host["outputStyle"] {
      guard case .string(let style) = value else {
        throw HostError("Invalid host Claude companion preference type for outputStyle")
      }
      selected.outputStyle = style
    }
    if let enabled = host["enabledPlugins"] {
      guard case .object(let plugins) = enabled else {
        throw HostError("Host enabledPlugins must be an object")
      }
      for id in pluginIDs {
        guard let value = plugins[id] else { continue }
        guard case .bool(let flag) = value else {
          throw HostError("Invalid host Claude plugin preference type")
        }
        selected.enabledPlugins[id] = flag
      }
    }
    return selected
  }

  /// Restore a guest value only while the previously imported one is still
  /// there; returns the guest values the incoming ones displace.
  static func mergeImportedValues(
    _ target: inout OrderedJSON.Members, incoming: OrderedJSON.Members,
    applied: OrderedJSON.Members, previous: OrderedJSON.Members
  ) -> OrderedJSON.Members {
    for (key, value) in applied.pairs where target[key] == value {
      if let original = previous[key] {
        target.insert(key, original)
      } else {
        target.remove(key)
      }
    }
    var baseline = OrderedJSON.Members()
    for (key, value) in incoming.pairs {
      if let original = target.insert(key, value) { baseline.insert(key, original) }
    }
    return baseline
  }

  /// Apply `imported` to a settings body, recording ownership so a later
  /// refresh can undo it without deleting guest preferences.
  static func mergePreferences(_ existing: String, _ imported: Preferences) throws -> String {
    var root: OrderedJSON.Members
    do {
      guard case .object(let members) = try OrderedJSON.parse(existing) else {
        throw HostError("Claude settings must be an object")
      }
      root = members
    } catch let error as HostError {
      throw error
    } catch {
      throw HostError("\(error)")
    }
    let state = root.remove(stateKey) ?? .null
    guard let applied = Preferences(state["applied"] ?? .object(.init())) else {
      throw HostError("Invalid Claude import ownership metadata")
    }
    let previous = state["previous"]?.objectMembers ?? .init()
    var incoming = imported.json.objectMembers!
    var appliedMembers = applied.json.objectMembers!
    let incomingPlugins = incoming.remove("enabledPlugins")?.objectMembers ?? .init()
    let appliedPlugins = appliedMembers.remove("enabledPlugins")?.objectMembers ?? .init()
    var baseline = mergeImportedValues(
      &root, incoming: incoming, applied: appliedMembers, previous: previous)
    if !incomingPlugins.isEmpty || !appliedPlugins.isEmpty {
      if root["enabledPlugins"] == nil { root["enabledPlugins"] = .object(.init()) }
      guard case .object(var plugins)? = root["enabledPlugins"] else {
        throw HostError("Guest enabledPlugins must be an object")
      }
      let pluginBaseline = mergeImportedValues(
        &plugins, incoming: incomingPlugins, applied: appliedPlugins,
        previous: previous["enabledPlugins"]?.objectMembers ?? .init())
      root["enabledPlugins"] = .object(plugins)
      baseline.insert("enabledPlugins", .object(pluginBaseline))
    }
    if !imported.isEmpty {
      root.insert(
        stateKey, .object(.init([("applied", imported.json), ("previous", .object(baseline))])))
    }
    return OrderedJSON.object(root).compact
  }
}

/// Iso's managed `~/.claude/settings.json` keys: bypass mode pre-accepted
/// (the VM is the boundary) and, in local or proxy mode, the `env` block.
enum ClaudeSettings {
  static func envJSON(_ env: [String: String]) -> OrderedJSON {
    .object(.init(MCPServer.sorted(env).map { ($0, .string($1)) }))
  }

  static func managedDefaults(_ localEnv: [String: String]) -> String {
    var members = OrderedJSON.Members([
      (
        "permissions",
        .object(
          .init([
            ("defaultMode", .string("bypassPermissions")),
            ("skipDangerousModePermissionPrompt", .bool(true)),
          ]))
      )
    ])
    if !localEnv.isEmpty { members["env"] = envJSON(localEnv) }
    return OrderedJSON.object(members).compact
  }

  /// Force the managed keys into an existing body, keeping every other key
  /// (plugin and marketplace state) and its order. The `env` block is
  /// iso's: replaced in local/proxy mode, removed otherwise.
  static func merge(_ existing: String, localEnv: [String: String]) throws -> String {
    var root: OrderedJSON.Members
    if existing.trimmingUnicodeWhitespace().isEmpty {
      root = .init()
    } else {
      let parsed: OrderedJSON
      do { parsed = try OrderedJSON.parse(existing) } catch {
        throw ContextError("existing ~/.claude/settings.json is not valid JSON", cause: error)
      }
      guard case .object(let members) = parsed else {
        throw HostError("existing ~/.claude/settings.json is not a JSON object")
      }
      root = members
    }
    if root["permissions"] == nil { root["permissions"] = .object(.init()) }
    guard case .object(var permissions)? = root["permissions"] else {
      throw HostError("`permissions` in ~/.claude/settings.json is not a JSON object")
    }
    permissions.insert("defaultMode", .string("bypassPermissions"))
    permissions.insert("skipDangerousModePermissionPrompt", .bool(true))
    root["permissions"] = .object(permissions)
    if localEnv.isEmpty {
      root.remove("env")
    } else {
      root.insert("env", envJSON(localEnv))
    }
    return OrderedJSON.object(root).compact
  }

  /// The normal merge and corrupt-settings recovery share the import step.
  static func withImport(
    _ existing: Result<String, any Error>, localEnv: [String: String],
    imported: ClaudeImport.Preferences, diagnostics: Diagnostics
  ) throws -> String {
    let merged: String
    do {
      merged = try merge(try existing.get(), localEnv: localEnv)
    } catch {
      diagnostics.warn(
        "Could not read or merge existing ~/.claude/settings.json (\(oneLineError(error))); replacing it with managed defaults"
      )
      merged = managedDefaults(localEnv)
    }
    return try ClaudeImport.mergePreferences(merged, imported)
  }

  /// `~/.claude.json` reads as onboarded only with a `true` flag.
  static func onboardingComplete(_ claudeJSON: String) -> Bool {
    (try? OrderedJSON.parse(claudeJSON))?["hasCompletedOnboarding"]?.boolValue ?? false
  }

  /// Keeps an existing object's keys; otherwise starts fresh.
  static func withOnboardingComplete(_ current: String?) -> String {
    var members = current.flatMap { try? OrderedJSON.parse($0) }?.objectMembers ?? .init()
    members.insert("hasCompletedOnboarding", .bool(true))
    return OrderedJSON.object(members).pretty + "\n"
  }
}

/// anyhow `{:#}`.
func oneLineError(_ error: any Error) -> String {
  (error as? ContextError)?.alternate ?? "\(error)"
}

extension AgentBootstrap {
  /// Claude Code: customizations and preferences, managed settings (the
  /// proxy or local-model `env`), onboarding, then — on first boot —
  /// marketplaces, plugins and MCP servers. A proxy started here is torn
  /// down if a later step fails.
  func bootstrapClaude(_ session: SSHSession, instance: Instance, mode: BootMode) throws {
    let claude = config.claude
    let claudeBinary = persistedGuestUser(instance.image).claudeBinary
    if mode == .firstBoot {
      let needsCLI =
        !claude.marketplaces.isEmpty || !claude.plugins.isEmpty || !claude.mcpServers.isEmpty
      if needsCLI
        && !client.succeeds(
          session.target, RemoteCommand().literal("test -x ").arg(claudeBinary.rawValue))
      {
        throw HostError(
          "Claude Code CLI is not installed in the guest.\nThe golden image may have been built before the installer was added, or the install failed silently.\nRun `iso setup --rebuild` to rebuild the image."
        )
      }
    }

    let staged = try prepareClaudeImport(session.target)
    defer { staged?.remove() }
    let modelState = try ModelState.loadOrDefault(instance)
    let proxy = try startAgentProxy(
      instance, provider: .anthropic, modelState: modelState, target: session.target)
    do {
      if inferenceRequired {
        if let (current, _) = try inferenceSession(instance, target: session.target) {
          try writeClaudeInferenceSettings(instance, target: session.target, session: current)
        } else {
          try writeManagedClaudeSettings(session.target, localEnv: [:])
        }
      } else {
        try writeManagedClaudeSettings(
          session.target, localEnv: try claudeLocalEnv(modelState, proxy: proxy))
      }
      if let staged {
        try copyStaged(staged, target: session.target, to: ".claude", label: "Claude")
      }
      try seedClaudeOnboarding(session, claudeBinary: claudeBinary)
      if mode == .firstBoot {
        let (marketplaces, plugins) = claudePluginDelta(instance.image)
        if !marketplaces.isEmpty {
          try installClaudeMarketplaces(session, claudeBinary, marketplaces)
        }
        if !plugins.isEmpty { try installClaudePlugins(session, claudeBinary, plugins) }
        if !claude.mcpServers.isEmpty { try registerMCPServers(session, claudeBinary) }
      }
      diagnostics.log(.info, "Claude Code bootstrap complete")
    } catch {
      if proxy != nil { proxies.stop(instance, provider: .anthropic) }
      throw error
    }
  }

  /// Local mode wins over proxy mode; empty when neither applies.
  func claudeLocalEnv(_ state: ModelState, proxy: ProxyHandle?) throws -> [String: String] {
    if let endpoint = LocalEndpoints.active(state, state.resolvedClaude(config.claude)) {
      let plan = try LocalEndpoints.plan(endpoint.hostURL)
      return ModelRouting.claudeEnvBlock(
        baseURL: plan.guestURL, model: endpoint.model, authToken: endpoint.authTokenOrDefault)
    }
    if let proxy {
      return ModelRouting.claudeProxyEnvBlock(
        baseURL: proxy.baseURL, capabilityToken: proxy.capabilityToken.expose())
    }
    return [:]
  }

  static let importSnapshotCommand =
    "if test -e ~/.claude/iso-import.json; then cat ~/.claude/iso-import.json; else printf '{}'; fi"

  func readImportSnapshot(_ target: SSHTarget) throws -> ClaudeImport.Snapshot {
    let body = try client.captureChecked(
      target, RemoteCommand().literal(Self.importSnapshotCommand))
    guard let parsed = try? OrderedJSON.parse(body), let snapshot = ClaudeImport.Snapshot(parsed)
    else { throw HostError("Invalid Claude import preference snapshot") }
    return snapshot
  }

  /// Stage the allowlisted host content and store its preference snapshot
  /// in the guest; the caller copies the files after settings are written.
  func prepareClaudeImport(_ target: SSHTarget) throws -> StagingDirectory? {
    guard
      let source = configSourceDirectory(
        config.claude.configDirectory, defaultName: ".claude", label: "claude.config_dir")
    else { return nil }
    let staged: StagingDirectory
    do {
      staged = try StagingDirectory()
      do {
        try staged.stage(
          from: source, files: ClaudeImport.allowedFiles,
          directories: ClaudeImport.allowedDirectories)
      } catch {
        staged.remove()
        throw error
      }
    } catch {
      throw ContextError("Failed to stage Claude config files", cause: error)
    }
    do {
      var snapshot = try readImportSnapshot(target)
      snapshot.pluginIDs.formUnion(try ClaudeImport.skillsPluginIDs(staged.path))
      snapshot.preferences = try ClaudeImport.preferences(
        source: source, pluginIDs: snapshot.pluginIDs)
      try client.exec(target, RemoteCommand().literal("mkdir -p ~/.claude"))
      try client.exec(
        target,
        RemoteCommand().literal(
          "t=\"$(mktemp ~/.claude/iso-import.json.XXXXXX)\" && cat > \"$t\" && mv \"$t\" ~/.claude/iso-import.json"
        ), stdin: Array(snapshot.json.compact.utf8))
    } catch {
      staged.remove()
      throw error
    }
    return staged
  }

  /// Merge (or, for an unusable file, reset) the guest settings, then write
  /// them atomically through a temporary file.
  func writeManagedClaudeSettings(_ target: SSHTarget, localEnv: [String: String]) throws {
    try client.exec(target, RemoteCommand().literal("mkdir -p ~/.claude"))
    let imported = try readImportSnapshot(target).preferences
    let existing = Result<String, any Error> {
      try client.captureChecked(
        target, RemoteCommand().literal("cat ~/.claude/settings.json 2>/dev/null || true"))
    }
    let merged = try ClaudeSettings.withImport(
      existing, localEnv: localEnv, imported: imported, diagnostics: diagnostics)
    do {
      try client.exec(
        target,
        RemoteCommand().literal(
          "t=\"$(mktemp ~/.claude/settings.json.XXXXXX)\" && cat > \"$t\" && mv \"$t\" ~/.claude/settings.json"
        ), stdin: Array(merged.utf8))
    } catch {
      throw ContextError("Failed to write managed ~/.claude/settings.json in guest", cause: error)
    }
    diagnostics.debug("Wrote managed ~/.claude/settings.json to guest")
  }

  func readClaudeJSON(_ target: SSHTarget) -> String? {
    do {
      let raw = try client.captureChecked(
        target, RemoteCommand().literal("cat ~/.claude.json 2>/dev/null || true"))
      return raw.trimmingUnicodeWhitespace().isEmpty ? nil : raw
    } catch {
      diagnostics.debug(
        "Could not read ~/.claude.json (\(oneLineError(error))); treating as absent")
      return nil
    }
  }

  /// Claude's onboarding wizard ignores a forwarded OAuth token
  /// (anthropics/claude-code#8938): mark onboarding complete when one is
  /// forwarded. Idempotent.
  func seedClaudeOnboarding(_ session: SSHSession, claudeBinary: GuestPath) throws {
    guard session.env.contains("CLAUDE_CODE_OAUTH_TOKEN") else { return }
    if let current = readClaudeJSON(session.target), ClaudeSettings.onboardingComplete(current) {
      diagnostics.debug("Claude onboarding already marked complete; skipping seed")
      return
    }
    diagnostics.debug("Seeding ~/.claude.json via `claude -p` to mark onboarding complete")
    do {
      try client.exec(
        session,
        RemoteCommand().literal("timeout 30 ").arg(claudeBinary.rawValue).literal(
          " -p ok >/dev/null 2>&1 || true"))
    } catch {
      diagnostics.debug("claude -p seed did not complete cleanly (continuing): \(error)")
    }
    let merged = ClaudeSettings.withOnboardingComplete(readClaudeJSON(session.target))
    do {
      try client.exec(
        session.target,
        RemoteCommand().literal(
          "t=\"$(mktemp ~/.claude.json.XXXXXX)\" && cat > \"$t\" && mv \"$t\" ~/.claude.json"),
        stdin: Array(merged.utf8))
    } catch {
      throw ContextError("Failed to write ~/.claude.json in guest", cause: error)
    }
    diagnostics.log(.info, "Marked Claude onboarding complete in guest (~/.claude.json)")
  }

  func installClaudeMarketplaces(
    _ session: SSHSession, _ binary: GuestPath, _ marketplaces: [String]
  ) throws {
    var madeDirectory = false
    for source in marketplaces {
      let guestSource = try stageMarketplaceSource(
        session, tool: "claude", source: source, madeDirectory: &madeDirectory)
      diagnostics.log(.info, "Adding marketplace: \(guestSource)")
      do {
        try client.exec(
          session,
          RemoteCommand().arg(binary.rawValue).literal(" plugin marketplace add ").arg(guestSource)
            .literal(" --scope user"))
      } catch {
        throw ContextError("Failed to add marketplace '\(source)'", cause: error)
      }
    }
  }

  func installClaudePlugins(_ session: SSHSession, _ binary: GuestPath, _ plugins: [String]) throws
  {
    for plugin in plugins {
      diagnostics.log(.info, "Installing plugin: \(plugin)")
      do {
        try client.exec(
          session,
          RemoteCommand().arg(binary.rawValue).literal(" plugin install ").arg(plugin).literal(
            " -s user"))
      } catch {
        throw ContextError("Failed to install plugin '\(plugin)'", cause: error)
      }
    }
  }

  /// `claude mcp add-json` per server, with header secrets resolved. The
  /// definition travels on stdin, so resolved headers never appear on the
  /// host's ssh argv or in an error (the baseline put it in the command).
  func registerMCPServers(_ session: SSHSession, _ binary: GuestPath) throws {
    for (name, server) in MCPServer.sorted(config.claude.mcpServers) {
      diagnostics.log(.info, "Registering MCP server: \(name)")
      let resolved = try server.resolvingHeaders(resolver, label: "MCP server", name: name)
      do {
        try client.exec(
          session,
          RemoteCommand().arg(binary.rawValue).literal(" mcp add-json -s user ").arg(name).literal(
            " \"$(cat)\""),
          stdin: Array(resolved.json.compact.utf8))
      } catch {
        throw ContextError("Failed to register MCP server '\(name)'", cause: error)
      }
    }
  }
}
