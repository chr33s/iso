import Foundation
import IsoConfiguration
import IsoCore

package enum AntigravityChecks {
  package static let bypassFlag = "--dangerously-skip-permissions"
  /// `agy` subcommands that are not agent sessions and take no permission flag.
  static let subcommands: Set<String> = ["acp", "install", "mcp", "plugin", "update"]

  package static let missingGuestCLIMessage =
    "Antigravity CLI (agy) is not installed in the guest.\nThe golden image may have been built before Antigravity support was added, or the install failed.\nIf you want to skip agent bootstrap for now, retry with `--no-agents`.\nOtherwise run `iso setup --rebuild` to rebuild the image."

  /// iso skips permission prompts unless `--ask`; a subcommand or an explicit
  /// bypass flag is passed through unchanged.
  package static func launchArguments(ask: Bool, _ arguments: [String]) -> [String] {
    let isSubcommand = subcommands.contains(arguments.first ?? "")
    let explicit = arguments.contains { AgentDispatch.flagName($0) == bypassFlag }
    return !ask && !isSubcommand && !explicit ? [bypassFlag] + arguments : arguments
  }
}

/// A guest Antigravity file iso cannot read as a JSON object.
struct AntigravityFileError: Error, CustomStringConvertible {
  let description: String
}

/// The Antigravity files iso manages in the guest.
enum AntigravityFiles {
  static let settingsDirectory = ".gemini/antigravity-cli"
  static let settingsPath = settingsDirectory + "/settings.json"
  static let mcpDirectory = ".gemini/config"
  static let mcpPath = mcpDirectory + "/mcp_config.json"

  /// The guest file as a JSON object; a missing or blank file is empty.
  static func object(_ existing: String?, path: String) throws -> OrderedJSON.Members {
    guard let existing, !existing.trimmingUnicodeWhitespace().isEmpty else { return .init() }
    let parsed: OrderedJSON
    do { parsed = try OrderedJSON.parse(existing) } catch {
      throw AntigravityFileError(description: "~/\(path) in the guest is not valid JSON (\(error))")
    }
    guard case .object(let members) = parsed else {
      throw AntigravityFileError(description: "~/\(path) in the guest is not a JSON object")
    }
    return members
  }

  /// `modelProvider = "gemini"` selects `GEMINI_API_KEY` auth. The CLI refuses
  /// to start with it set and no key, so iso sets it only when a key (or the
  /// proxy's capability) reaches the guest, and otherwise removes it.
  static func settings(_ existing: String?, apiKeyAuth: Bool) throws -> String {
    var members = try object(existing, path: settingsPath)
    if apiKeyAuth {
      members.insert("modelProvider", .string("gemini"))
    } else if members["modelProvider"]?.stringValue == "gemini" {
      members.remove("modelProvider")
    }
    return OrderedJSON.object(members).pretty + "\n"
  }

  /// `mcp_config.json` with iso's servers upserted and the ones iso wrote
  /// before but no longer configures (`removing`) deleted; others are kept.
  static func mcpConfig(
    _ existing: String?, servers: [(String, MCPServer)], removing: Set<String> = []
  ) throws -> String {
    var root = try object(existing, path: mcpPath)
    var entries = root["mcpServers"]?.objectMembers ?? OrderedJSON.Members()
    for name in removing.sorted() { entries.remove(name) }
    for (name, server) in servers { entries.insert(name, json(server)) }
    root.insert("mcpServers", .object(entries))
    return OrderedJSON.object(root).pretty + "\n"
  }

  /// Host-side record of the MCP server names iso last wrote to this guest,
  /// so a server removed from the configuration (and its header values) is
  /// deleted rather than left behind.
  static func managedNamesPath(_ instance: Instance) -> String {
    instance.directory + "/antigravity-mcp.json"
  }

  static func loadManagedNames(_ instance: Instance) throws -> Set<String> {
    guard let bytes = try StateStore.readControlFile(managedNamesPath(instance)) else { return [] }
    do { return Set(try JSONDecoder().decode([String].self, from: Data(bytes))) } catch {
      throw ContextError("Failed to parse \(managedNamesPath(instance))", cause: error)
    }
  }

  static func saveManagedNames(_ names: Set<String>, _ instance: Instance) throws {
    try StateStore.writeControlFile(names.sorted(), to: managedNamesPath(instance))
  }

  /// Antigravity's server shape: `command`/`args` for stdio, `url`/`headers`
  /// for streamable HTTP. Configuration refuses SSE and stdio `env`.
  static func json(_ server: MCPServer) -> OrderedJSON {
    switch server {
    case .stdio(let command, let args, _):
      var members: [(String, OrderedJSON)] = [("command", .string(command))]
      if !args.isEmpty { members.append(("args", .array(args.map(OrderedJSON.string)))) }
      return .object(.init(members))
    case .http(let url, let headers), .sse(let url, let headers):
      var members: [(String, OrderedJSON)] = [("url", .string(MCPServer.urlText(url)))]
      if !headers.isEmpty {
        members.append(
          (
            "headers",
            .object(.init(MCPServer.sorted(headers).map { ($0, .string($1.expose())) }))
          ))
      }
      return .object(.init(members))
    }
  }
}

extension AgentBootstrap {
  /// Writes the guest's managed Antigravity settings and MCP servers, starting
  /// the Google proxy first when one is configured (torn down if a later step
  /// fails). Images without `agy` are skipped unless the configuration needs it.
  package func bootstrapAntigravity(_ session: SSHSession, instance: Instance, mode: BootMode)
    throws
  {
    let modelState = try ModelState.loadOrDefault(instance)
    let wantsProxy =
      try modelState.mode == .remote
      && ProxyState.effectiveUpstream(instance, .google, config: config.proxy) != nil
    // The computer-use server is added for every agent; only servers the user
    // configured make `agy` required.
    let userServers = config.antigravity.mcpServers.keys.filter { $0 != Self.computerUseServer }
    let installed = client.succeeds(
      session.target, RemoteCommand().literal("test -x ").arg(GuestBinaries.agy.rawValue))
    guard installed else {
      proxies.stop(instance, provider: .google)
      if wantsProxy || !userServers.isEmpty {
        throw HostError(AntigravityChecks.missingGuestCLIMessage)
      }
      diagnostics.debug("Antigravity CLI not installed in the guest; skipping its bootstrap")
      return
    }
    let proxy = try startAgentProxy(
      instance, provider: .google, modelState: modelState, target: session.target)
    do {
      let apiKeyAuth = try proxy != nil || geminiKeyDeclared(instance)
      do {
        try writeManagedFile(
          session.target, directory: AntigravityFiles.settingsDirectory,
          path: AntigravityFiles.settingsPath, label: "Antigravity settings"
        ) { try AntigravityFiles.settings($0, apiKeyAuth: apiKeyAuth) }
      } catch let error as AntigravityFileError {
        // An unreadable settings file (agy may write JSONC) is the user's;
        // it costs this boot only the modelProvider setting.
        diagnostics.warn("\(error); leaving it unchanged, so iso does not manage modelProvider")
      }
      try syncMCPServers(session.target, instance: instance)
      diagnostics.log(
        .info,
        mode == .restart ? "Antigravity bootstrap refreshed" : "Antigravity bootstrap complete")
    } catch {
      if proxy != nil { proxies.stop(instance, provider: .google) }
      throw error
    }
  }

  /// Whether this configuration sends a raw `GEMINI_API_KEY` to the guest's
  /// sessions: declared by `api_key`, an `env_forward`, `guest_env` or saved
  /// `--env` entry, and not withheld. Decided from configuration, so every
  /// session agrees with the `modelProvider` setting a boot wrote.
  func geminiKeyDeclared(_ instance: Instance) throws -> Bool {
    let name = "GEMINI_API_KEY"
    let enforced = try ActivePolicy.load(instance).policy?.enforcesProviderActions ?? false
    guard withheldVariables(proxied: [], policyEnforced: enforced)[name] == nil else {
      return false
    }
    if config.antigravity.apiKey != nil { return true }
    if config.agents.contains(where: { $0.config.envForward.contains { $0.rawValue == name } }) {
      return true
    }
    if config.guestEnvironment.contains(where: { $0.name.rawValue == name }) { return true }
    guard let state = try GuestEnvState.tryLoad(instance) else { return false }
    let routed = Set(try state.providerSecrets().values.map(\.variable))
    return state.entries.keys.contains { $0.rawValue == name && !routed.contains($0) }
  }

  /// Upserts the configured servers and deletes the ones iso wrote before but
  /// no longer configures. Header values are resolved here and sent on stdin.
  func syncMCPServers(_ target: SSHTarget, instance: Instance) throws {
    let previous = try AntigravityFiles.loadManagedNames(instance)
    let configured = config.antigravity.mcpServers
    guard !configured.isEmpty || !previous.isEmpty else { return }
    var servers: [(String, MCPServer)] = []
    for (name, server) in MCPServer.sorted(configured) {
      diagnostics.log(.info, "Registering Antigravity MCP server: \(name)")
      servers.append((name, try server.resolvingHeaders(resolver, label: "MCP server", name: name)))
    }
    let current = Set(configured.keys)
    try writeManagedFile(
      target, directory: AntigravityFiles.mcpDirectory, path: AntigravityFiles.mcpPath,
      label: "Antigravity MCP configuration"
    ) {
      try AntigravityFiles.mcpConfig($0, servers: servers, removing: previous.subtracting(current))
    }
    try AntigravityFiles.saveManagedNames(current, instance)
  }

  /// Read-modify-write of a guest file under `~`. The new content travels on
  /// stdin (it may hold resolved MCP header values) and replaces the file
  /// atomically with mode 0600.
  func writeManagedFile(
    _ target: SSHTarget, directory: String, path: String, label: String,
    update: (String?) throws -> String
  ) throws {
    let existing = try client.captureChecked(
      target, RemoteCommand().literal("cat ~/\(path) 2>/dev/null || true"))
    let content = try update(existing)
    do {
      try client.exec(
        target,
        RemoteCommand().literal(
          "mkdir -p ~/\(directory) && t=\"$(mktemp ~/\(path).XXXXXX)\" && chmod 600 \"$t\" && cat > \"$t\" && mv \"$t\" ~/\(path)"
        ), stdin: Array(content.utf8))
    } catch {
      throw ContextError("Failed to write \(label) (~/\(path)) in guest", cause: error)
    }
    diagnostics.debug("Wrote ~/\(path) to guest")
  }
}
