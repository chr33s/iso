import CoopConfiguration
import CoopCore
import CoopSecrets
import Foundation
import Testing

@testable import CoopHost

private func envNames(_ env: EnvForward) -> [String] { env.names }

// MARK: - Environment forwarding (prepare_env_forwarding)

@Test func proxyAndAccountModesSuppressRawProviderKeysFromEverySource() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let config = try testConfig(
    #"""
    "claude": {"api_key": "sk-ant", "env_forward": ["ANTHROPIC_API_KEY", "EXTRA"]},
    "codex": {"api_key": "sk-oai", "env_forward": ["OPENAI_API_KEY"]},
    "guest_env": {"ANTHROPIC_API_KEY": "x", "OPENAI_API_KEY": "y", "GUEST_VAR": "g"}
    """#)
  var agents = guest.bootstrap(config)
  var env = try agents.prepareEnvForwarding(
    repo: nil, suppressAnthropicKey: true, suppressOpenAIKey: true)
  #expect(!env.contains("ANTHROPIC_API_KEY"))
  #expect(!env.contains("OPENAI_API_KEY"))
  #expect(env.contains("GUEST_VAR"))
  let log = guest.sink.text
  #expect(log.contains("proxy mode: ignoring env_forward entry 'ANTHROPIC_API_KEY'"))
  #expect(log.contains("proxy mode: ignoring guest_env entry 'OPENAI_API_KEY'"))
  #expect(!log.contains("sk-ant") && !log.contains("sk-oai"))

  // ChatGPT account auth suppresses OpenAI even without a proxy.
  let chatgpt = try testConfig(
    #""codex": {"api_key": "sk-oai", "auth": "chatgpt"}, "guest_env": {"OPENAI_API_KEY": "y"}"#)
  agents = guest.bootstrap(chatgpt)
  env = try agents.prepareEnvForwarding(
    repo: nil, suppressAnthropicKey: false, suppressOpenAIKey: false)
  #expect(!env.contains("OPENAI_API_KEY"))
  #expect(guest.sink.text.contains("codex.auth = \"chatgpt\": ignoring guest_env entry"))
}

@Test func keysResolveFromConfigThenProcessEnvironmentAndGuestEnvWins() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let config = try testConfig(
    #"""
    "claude": {"api_key": "cmd:printf resolved-key", "env_forward": ["EXTRA"]},
    "codex": {},
    "guest_env": {"GUEST_VAR": "", "EXTRA": "literal"}
    """#)
  let resolver = CredentialResolver(environment: guest.environment)
  let agents = AgentBootstrap(
    config: config, client: guest.client,
    environment: ["OPENAI_API_KEY": "from-env", "EXTRA": "inherited"], home: nil,
    resolver: resolver, proxies: guest.proxies(resolver), github: NoGitHub(),
    diagnostics: guest.sink.diagnostics)
  let env = try agents.prepareEnvForwarding(
    repo: nil, suppressAnthropicKey: false, suppressOpenAIKey: false)
  #expect(env.names == ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "EXTRA", "GUEST_VAR"])
  // Values travel only in ssh's environment; the stub records them.
  let session = SSHSession(target: guest.target, env: env)
  try guest.client.exec(session, RemoteCommand().literal("true"))
  let seen = guest.log("env.log")
  #expect(seen.contains("ANTHROPIC_API_KEY=resolved-key"))
  #expect(seen.contains("OPENAI_API_KEY=from-env"))
  #expect(seen.contains("GUEST_VAR="))
  #expect(guest.sink.text.contains("guest_env entry 'EXTRA' overrides a previously resolved value"))
  #expect(!guest.log("argv.log").joined().contains("resolved-key"))
  #expect(guest.log("argv.log").joined().contains("SendEnv=ANTHROPIC_API_KEY"))

  let failing = try testConfig(#""claude": {"api_key": "cmd:exit 3"}"#)
  let error = try #require(throws: (any Error).self) {
    try guest.bootstrap(failing).prepareEnvForwarding(
      repo: nil, suppressAnthropicKey: false, suppressOpenAIKey: false)
  }
  #expect("\(error)".contains("Failed to resolve claude.api_key"))
}

@Test func sessionsOverlayRuntimeEnvAndCodexProviderKeys() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  try GuestEnvState(literals: [
    try EnvVarName("OPENAI_API_KEY"): "raw", try EnvVarName("GUEST_VAR"): "runtime",
  ]).save(instance)
  let config = try testConfig(
    #""proxy": {"openai": {"credential": "cmd:printf x", "auth": "bearer"}}"#)
  let agents = guest.bootstrap(config)
  // Proxy mode: the raw key from `--env` is dropped, the capability token forwarded.
  try writeFile(ProxyLauncher.tokenPath(instance, "openai"), "  cap-123\n")
  var session = try agents.prepareSession(instance, target: guest.target, repo: nil)
  #expect(session.env.names.contains("GUEST_VAR"))
  #expect(!session.env.contains("OPENAI_API_KEY"))
  #expect(session.env.contains("COOP_LOCAL_API_KEY"))
  #expect(guest.sink.text.contains("proxy mode: ignoring runtime --env entry 'OPENAI_API_KEY'"))
  try guest.client.exec(session, RemoteCommand().literal("true"))
  #expect(guest.log("env.log").contains("COOP_LOCAL_API_KEY=cap-123"))

  // Local mode: the endpoint's token (or the placeholder) instead.
  var state = ModelState()
  state.mode = .local
  state.codexEndpoint = try LocalModel(hostURL: "http://localhost:1", model: "m", authToken: nil)
  try state.save(instance)
  session = try agents.prepareSession(instance, target: guest.target, repo: nil)
  #expect(session.env.contains("OPENAI_API_KEY"))  // not in proxy mode any more
  try guest.client.exec(session, RemoteCommand().literal("true"))
  #expect(guest.log("env.log").contains("COOP_LOCAL_API_KEY=coop-local"))
}

// MARK: - Claude customization import

private func pluginFixture(_ root: String, _ directory: String, _ manifest: String) throws {
  try writeFile(root + "/skills/" + directory + "/.claude-plugin/plugin.json", manifest)
}

@Test func claudePluginDiscoveryMatchesNativeIdentities() throws {
  let source = try scratchDirectory("src")
  defer { try? FileManager.default.removeItem(atPath: source) }
  #expect(try ClaudeImport.skillsPluginIDs(source).isEmpty)
  for (directory, name) in [
    ("directory", "manifest-name"), ("nested/inner", "nested"), (".hidden", "hidden"),
    ("synced", "sync"), ("SyNcEd. ", "reserved"), ("ſynced", "long-s-reserved"),
    ("s\u{200C}ynced", "format-reserved"), ("unicodé", "unicode-name"),
    ("special", "some/name@source"),
  ] {
    try pluginFixture(source, directory, #"{"name":"\#(name)"}"#)
  }
  try writeFile(source + "/skills/directory/SKILL.md", "---\nname: frontmatter-name\n---\n")
  #expect(
    try ClaudeImport.skillsPluginIDs(source)
      == ["manifest-name@skills-dir", "unicode-name@skills-dir", "some/name@source@skills-dir"])
}

@Test func claudePluginDiscoveryRefusesSyncStateAndInvalidManifests() throws {
  let source = try scratchDirectory("src")
  defer { try? FileManager.default.removeItem(atPath: source) }
  try pluginFixture(source, "plugin", #"{"name":"valid"}"#)
  try writeFile(source + "/skills/manifest.json", #"{"skills":[]}"#)
  let error = try #require(throws: (any Error).self) { try ClaudeImport.skillsPluginIDs(source) }
  #expect("\(error)".contains("sync bookkeeping"))
  try FileManager.default.removeItem(atPath: source + "/skills/manifest.json")
  for manifest in [
    "invalid", "{}", #"{"name":""}"#, #"{"name":"bad name"}"#, #"{"name":"bad\u0001name"}"#,
  ] {
    try pluginFixture(source, "plugin", manifest)
    #expect(throws: (any Error).self, "\(manifest)") { try ClaudeImport.skillsPluginIDs(source) }
  }
}

@Test func claudeImportSelectsOnlyCompanionPreferences() throws {
  let source = try scratchDirectory("src")
  defer { try? FileManager.default.removeItem(atPath: source) }
  try pluginFixture(source, "directory", #"{"name":"identity","defaultEnabled":false}"#)
  let ids = try ClaudeImport.skillsPluginIDs(source)
  let empty = try ClaudeImport.preferences(source: source, pluginIDs: ids)
  #expect(empty.isEmpty)
  for enabled in [true, false] {
    try writeFile(
      source + "/settings.json",
      #"""
      {"disableAllHooks":false,"outputStyle":"host-style",
       "enabledPlugins":{"identity@skills-dir":\#(enabled),"directory@skills-dir":\#(!enabled),
         "IDENTITY@skills-dir":\#(!enabled),"unrelated@market":true},
       "permissions":{"defaultMode":"plan"},"env":{"TOKEN":"secret"},
       "apiKeyHelper":"secret","hooks":{"SessionStart":[]},"extraKnownMarketplaces":{"excluded":{}}}
      """#)
    let selected = try ClaudeImport.preferences(source: source, pluginIDs: ids)
    #expect(
      selected.json.compact
        == #"{"disableAllHooks":false,"outputStyle":"host-style","enabledPlugins":{"identity@skills-dir":\#(enabled)}}"#
    )
  }
  // Removed bundles keep their recorded identity eligible.
  try FileManager.default.removeItem(atPath: source + "/skills")
  #expect(
    try ClaudeImport.preferences(source: source, pluginIDs: ids).enabledPlugins[
      "identity@skills-dir"] == false)
  try FileManager.default.removeItem(atPath: source + "/settings.json")
  #expect(try ClaudeImport.preferences(source: source, pluginIDs: ids).enabledPlugins.isEmpty)

  for body in [
    "broken", "[]", #"{"disableAllHooks":"true"}"#, #"{"disableAllHooks":null}"#,
    #"{"outputStyle":null}"#, #"{"outputStyle":false}"#, #"{"enabledPlugins":[]}"#,
    #"{"enabledPlugins":{"identity@skills-dir":"false"}}"#,
  ] {
    try writeFile(source + "/settings.json", body)
    #expect(throws: (any Error).self, "\(body)") {
      try ClaudeImport.preferences(source: source, pluginIDs: ["identity@skills-dir"])
    }
  }
  #expect(
    ClaudeImport.Snapshot(try OrderedJSON.parse(#"{"preferences":{"env":{"S":"x"}}}"#)) == nil)
  #expect(ClaudeImport.Snapshot(try OrderedJSON.parse("{}")) != nil)
}

@Test func claudeBundlesAreStagedCompletelyAndExclusionsStayOnTheHost() throws {
  let source = try scratchDirectory("src")
  defer { try? FileManager.default.removeItem(atPath: source) }
  let files = [
    "CLAUDE.md", "keybindings.json", "rules/nested/rule.md", "commands/cmd.md", "agents/agent.md",
    "output-styles/style.md", "themes/theme.json", "workflows/flow.js", "skills/tool/SKILL.md",
    "skills/tool/references/nested/data.json", "skills/plugin/.claude-plugin/plugin.json",
    "skills/plugin/hooks/hooks.json", "skills/plugin/.hidden/data",
  ]
  for file in files { try writeFile(source + "/" + file, file) }
  try writeFile(source + "/skills/tool/scripts/run.sh", "#!/bin/sh\nprintf ok", mode: 0o755)
  for file in [
    "settings.json", ".credentials.json", "plugins/installed_plugins.json", "hooks/run.sh",
    "monitors/monitors.json", "routines/routine.json", "coop-import.json",
  ] {
    try writeFile(source + "/" + file, "excluded")
  }
  let staged = try StagingDirectory()
  defer { staged.remove() }
  try staged.stage(
    from: source, files: ClaudeImport.allowedFiles, directories: ClaudeImport.allowedDirectories)
  for file in files { #expect(readFile(staged.path + "/" + file) == file) }
  #expect(access(staged.path + "/skills/tool/scripts/run.sh", X_OK) == 0)
  for file in [
    "settings.json", ".credentials.json", "plugins", "hooks", "monitors", "routines",
    "coop-import.json",
  ] {
    #expect(!FileManager.default.fileExists(atPath: staged.path + "/" + file), "\(file)")
  }
}

@Test func stagingIsAnOverlayThatFollowsSymlinks() throws {
  let source = try scratchDirectory("src")
  let external = try scratchDirectory("ext")
  defer {
    try? FileManager.default.removeItem(atPath: source)
    try? FileManager.default.removeItem(atPath: external)
  }
  let staged = try StagingDirectory()
  defer { staged.remove() }
  try FileManager.default.createDirectory(
    atPath: source + "/skills/example", withIntermediateDirectories: true)
  try writeFile(external + "/support", "external-target")
  try FileManager.default.createSymbolicLink(
    atPath: source + "/skills/example/support", withDestinationPath: external)
  try writeFile(source + "/CLAUDE.md", "first")
  try staged.stage(
    from: source, files: ClaudeImport.allowedFiles, directories: ClaudeImport.allowedDirectories)
  try FileManager.default.removeItem(atPath: source + "/CLAUDE.md")
  try writeFile(external + "/support", "refreshed")
  try staged.stage(
    from: source, files: ClaudeImport.allowedFiles, directories: ClaudeImport.allowedDirectories)
  #expect(readFile(staged.path + "/CLAUDE.md") == "first")
  #expect(readFile(staged.path + "/skills/example/support/support") == "refreshed")
  var status = stat()
  lstat(staged.path + "/skills/example/support", &status)
  #expect((status.st_mode & S_IFMT) == S_IFDIR)
}

private func prefs(_ json: String) throws -> ClaudeImport.Preferences {
  try #require(ClaudeImport.Preferences(try OrderedJSON.parse(json)))
}

@Test func importedPreferencesRefreshAndRestoreGuestValues() throws {
  let guestSettings =
    #"{"outputStyle":"guest-style","disableAllHooks":false,"enabledPlugins":{"copied@skills-dir":true,"guest@market":false},"permissions":{"allow":["Read"],"defaultMode":"bypassPermissions"},"env":{"ANTHROPIC_BASE_URL":"coop-route"},"apiKeyHelper":"guest-auth","extraKnownMarketplaces":{"guest":{}},"unrelated":42}"#
  let imported = try prefs(
    #"{"outputStyle":"host-style","disableAllHooks":true,"enabledPlugins":{"copied@skills-dir":false,"new@skills-dir":true}}"#
  )
  let first = try ClaudeImport.mergePreferences(guestSettings, imported)
  let value = try OrderedJSON.parse(first)
  #expect(value["outputStyle"] == .string("host-style"))
  #expect(value["disableAllHooks"] == .bool(true))
  #expect(value["enabledPlugins"]?["copied@skills-dir"] == .bool(false))
  #expect(value["enabledPlugins"]?["new@skills-dir"] == .bool(true))
  #expect(value["enabledPlugins"]?["guest@market"] == .bool(false))
  let original = try OrderedJSON.parse(guestSettings)
  for key in ["permissions", "env", "apiKeyHelper", "extraKnownMarketplaces", "unrelated"] {
    #expect(value[key] == original[key])
  }
  let again = try ClaudeImport.mergePreferences(first, imported)
  #expect(again == first)
  let cleared = try ClaudeImport.mergePreferences(again, ClaudeImport.Preferences())
  #expect(try OrderedJSON.parse(cleared) == original)
}

@Test func importedPreferencesKeepGuestEditsOnRemoval() throws {
  let imported = try prefs(
    #"{"outputStyle":"host","disableAllHooks":true,"enabledPlugins":{"copied@skills-dir":false}}"#)
  let first = try ClaudeImport.mergePreferences("{}", imported)
  guard case .object(var edited) = try OrderedJSON.parse(first),
    case .object(var plugins)? = edited["enabledPlugins"]
  else { throw HostError("not an object") }
  edited["outputStyle"] = .string("guest-edit")
  plugins["copied@skills-dir"] = .bool(true)
  edited["enabledPlugins"] = .object(plugins)
  let removed = try OrderedJSON.parse(
    ClaudeImport.mergePreferences(OrderedJSON.object(edited).compact, ClaudeImport.Preferences()))
  #expect(removed["outputStyle"] == .string("guest-edit"))
  #expect(removed["enabledPlugins"]?["copied@skills-dir"] == .bool(true))
  #expect(removed["disableAllHooks"] == nil)
  #expect(removed["_coopImportedPreferences"] == nil)
}

@Test func managedSettingsMergeKeepsGuestStateAndRecoversCorruptFiles() throws {
  let sink = LogSink()
  let imported = try prefs(
    #"{"disableAllHooks":true,"outputStyle":"host","enabledPlugins":{"disabled@skills-dir":false}}"#
  )
  for existing in ["", "not json", "[]", #"{"permissions": false}"#] {
    let merged = try OrderedJSON.parse(
      ClaudeSettings.withImport(
        .success(existing), localEnv: [:], imported: imported, diagnostics: sink.diagnostics))
    #expect(merged["disableAllHooks"] == .bool(true))
    #expect(merged["enabledPlugins"]?["disabled@skills-dir"] == .bool(false))
    #expect(merged["permissions"]?["defaultMode"] == .string("bypassPermissions"))
  }
  #expect(sink.text.contains("replacing it with managed defaults"))

  let kept = try OrderedJSON.parse(
    ClaudeSettings.merge(
      #"{"enabledPlugins":{"my-skill@my-market":true},"extraKnownMarketplaces":{"m":{"source":"/srv/m"}},"permissions":{"defaultMode":"default"}}"#,
      localEnv: [:]))
  #expect(kept["enabledPlugins"]?["my-skill@my-market"] == .bool(true))
  #expect(kept["extraKnownMarketplaces"] != nil)
  #expect(kept["permissions"]?["defaultMode"] == .string("bypassPermissions"))
  #expect(kept["permissions"]?["skipDangerousModePermissionPrompt"] == .bool(true))
  #expect(
    try ClaudeSettings.merge(
      #"{"zeta":1,"permissions":{"defaultMode":"default"},"alpha":2}"#, localEnv: [:])
      == #"{"zeta":1,"permissions":{"defaultMode":"bypassPermissions","skipDangerousModePermissionPrompt":true},"alpha":2}"#
  )
  let local = ModelRouting.claudeEnvBlock(
    baseURL: "http://127.0.0.1:11434", model: "q", authToken: "t")
  let replaced = try OrderedJSON.parse(
    ClaudeSettings.merge(#"{"env":{"STALE":"1","ANTHROPIC_MODEL":"old"}}"#, localEnv: local))
  #expect(replaced["env"]?["STALE"] == nil)
  #expect(replaced["env"]?["ANTHROPIC_MODEL"] == .string("q"))
  #expect(
    try OrderedJSON.parse(ClaudeSettings.merge(#"{"env":{"A":"b"}}"#, localEnv: [:]))["env"] == nil)
  for body in ["", "   \n", "{}"] {
    #expect(
      try ClaudeSettings.merge(body, localEnv: [:])
        == #"{"permissions":{"defaultMode":"bypassPermissions","skipDangerousModePermissionPrompt":true}}"#
    )
  }
  for bad in ["not json", "[1, 2, 3]", #"{"permissions": "nope"}"#] {
    #expect(throws: (any Error).self) { try ClaudeSettings.merge(bad, localEnv: [:]) }
  }
  #expect(
    ClaudeSettings.managedDefaults(["B": "2", "A": "1"])
      == #"{"permissions":{"defaultMode":"bypassPermissions","skipDangerousModePermissionPrompt":true},"env":{"A":"1","B":"2"}}"#
  )
}

@Test func onboardingFlagHandling() throws {
  #expect(ClaudeSettings.onboardingComplete(#"{"hasCompletedOnboarding": true, "theme": "dark"}"#))
  for raw in [#"{"theme": "dark"}"#, #"{"hasCompletedOnboarding": false}"#, "not json", "", "[]"] {
    #expect(!ClaudeSettings.onboardingComplete(raw))
  }
  let merged = ClaudeSettings.withOnboardingComplete(#"{"theme": "dark", "userID": "abc"}"#)
  #expect(
    merged
      == "{\n  \"theme\": \"dark\",\n  \"userID\": \"abc\",\n  \"hasCompletedOnboarding\": true\n}\n"
  )
  for raw in [nil, "[1, 2, 3]", "garbage"] {
    #expect(
      ClaudeSettings.withOnboardingComplete(raw) == "{\n  \"hasCompletedOnboarding\": true\n}\n")
  }
}

// MARK: - Codex config staging

private func stageCodex(
  source: String? = nil, mcp: [String: TOMLValue] = [:], local: TOMLTable? = nil,
  managesLocal: Bool = false, preserved: TOMLTable? = nil, proxy: Bool = false,
  proxyMode: ProxyMode = .auto, auth: CodexAuthMode = .apiKey, keyring: Bool = false
) throws -> StagingDirectory {
  try CodexConfigFiles.stage(
    source: source, mcpServers: mcp, local: local, managesLocal: managesLocal,
    preserved: preserved, proxyActive: proxy, proxyMode: proxyMode, auth: auth,
    keyringMaterialized: keyring,
    hasMCPServers: !mcp.isEmpty, diagnostics: LogSink().diagnostics)
}

@Test func codexStagingMergesManagedKeys() throws {
  let source = try scratchDirectory("codex")
  defer { try? FileManager.default.removeItem(atPath: source) }
  try writeFile(source + "/AGENTS.md", "Global instructions")
  try writeFile(
    source + "/config.toml",
    "model = \"gpt-5\"\n\n[mcp_servers.legacy]\ncommand = \"legacy-server\"\n")
  let sentry = MCPServer.http(url: URL(string: "https://mcp.sentry.dev/mcp")!, headers: [:])
  var staged = try stageCodex(source: source, mcp: ["sentry": sentry.toml])
  var config = try #require(readFile(staged.path + "/config.toml"))
  #expect(config.contains("model = \"gpt-5\""))
  #expect(config.contains("[mcp_servers.sentry]"))
  #expect(config.contains("url = \"https://mcp.sentry.dev/mcp\""))
  #expect(!config.contains("legacy"))
  #expect(readFile(staged.path + "/AGENTS.md") == "Global instructions")
  staged.remove()

  let local = ModelRouting.codexLocalConfig(baseURL: "http://127.0.0.1:11434/v1/", model: "qwen")
  staged = try stageCodex(source: source, local: local, managesLocal: true)
  config = try #require(readFile(staged.path + "/config.toml"))
  #expect(config.contains("model = \"qwen\""))
  #expect(!config.contains("gpt-5"))
  #expect(config.contains("model_provider = \"coop_local\""))
  #expect(config.contains("wire_api = \"responses\""))
  staged.remove()

  staged = try stageCodex(managesLocal: true)
  #expect(!(try #require(readFile(staged.path + "/config.toml"))).contains("coop_local"))
  staged.remove()
}

@Test func codexAuthJSONIsStagedOnlyForDirectAPIKeyMode() throws {
  let source = try scratchDirectory("codex")
  defer { try? FileManager.default.removeItem(atPath: source) }
  try writeFile(source + "/auth.json", #"{"access_token":"test"}"#)
  try writeFile(source + "/AGENTS.md", "hi")
  var staged = try stageCodex(source: source)
  #expect(readFile(staged.path + "/auth.json") == #"{"access_token":"test"}"#)
  #expect(!FileManager.default.fileExists(atPath: staged.path + "/config.toml"))
  staged.remove()
  staged = try stageCodex(source: source, proxy: true)
  #expect(!FileManager.default.fileExists(atPath: staged.path + "/auth.json"))
  #expect(FileManager.default.fileExists(atPath: staged.path + "/AGENTS.md"))
  staged.remove()
  // proxy.mode = "required" withholds it even when OpenAI has no proxy:
  // `codex login --with-api-key` stores a raw key there.
  staged = try stageCodex(source: source, proxyMode: .required)
  #expect(!FileManager.default.fileExists(atPath: staged.path + "/auth.json"))
  #expect(FileManager.default.fileExists(atPath: staged.path + "/AGENTS.md"))
  staged.remove()
  staged = try stageCodex(source: source, auth: .chatgpt)
  #expect(!FileManager.default.fileExists(atPath: staged.path + "/auth.json"))
  #expect(
    readFile(staged.path + "/config.toml")?.contains("cli_auth_credentials_store = \"keyring\"")
      == true)
  staged.remove()
}

@Test func codexKeyringSettingIsCoopOwned() throws {
  let source = try scratchDirectory("codex")
  defer { try? FileManager.default.removeItem(atPath: source) }
  try writeFile(
    source + "/config.toml",
    "approval_policy = \"never\"\ninstructions = \"\"\"\n[not-a-table]\n\"\"\"\n")
  var staged = try stageCodex(source: source, auth: .chatgpt)
  var config = try #require(readFile(staged.path + "/config.toml"))
  #expect(config.hasPrefix("cli_auth_credentials_store = \"keyring\"\n"))
  let parsed = try TOMLTable.parse(config)
  #expect(parsed["instructions"] == .string("[not-a-table]\n"))
  staged.remove()

  // Switching back to api_key: a remembered keyring store forces a rewrite that drops it.
  staged = try stageCodex(keyring: true)
  config = try #require(readFile(staged.path + "/config.toml"))
  #expect(!config.contains("cli_auth_credentials_store"))
  staged.remove()
  #expect(
    !CodexConfigFiles.needsRewrite(
      source: nil, mcpServers: [:], local: nil, managesLocal: false, auth: .apiKey,
      keyringMaterialized: false))
  #expect(
    CodexConfigFiles.needsRewrite(
      source: nil, mcpServers: [:], local: nil, managesLocal: false, auth: .apiKey,
      keyringMaterialized: true))

  try writeFile(
    source + "/config.toml", "cli_auth_credentials_store = \"keyring\"\nmodel = \"gpt-5\"\n")
  staged = try stageCodex(source: source)
  config = try #require(readFile(staged.path + "/config.toml"))
  #expect(!config.contains("cli_auth_credentials_store"))
  #expect(config.contains("gpt-5"))
  staged.remove()
}

@Test func guestPluginAndProjectTablesSurviveButHostOnesDoNot() throws {
  let preserved = try #require(
    try CodexConfigFiles.extractPluginState(
      """
      model = "gpt-5"

      [projects."/workspace"]
      trust_level = "trusted"

      [marketplaces.codex-plugins]
      source = "trailofbits/codex-plugins"

      [plugins."my-lsp@codex-plugins"]
      enabled = true
      """))
  #expect(preserved.contains("projects") && preserved.contains("marketplaces"))
  #expect(preserved.contains("plugins") && !preserved.contains("model"))
  #expect(try CodexConfigFiles.extractPluginState("") == nil)
  #expect(try CodexConfigFiles.extractPluginState("model = \"gpt-5\"\n") == nil)
  #expect(throws: (any Error).self) { try CodexConfigFiles.extractPluginState("not = = valid") }

  let source = try scratchDirectory("codex")
  defer { try? FileManager.default.removeItem(atPath: source) }
  try writeFile(
    source + "/config.toml",
    "model = \"gpt-5\"\n[projects.\"/host/secret\"]\ntrust_level = \"trusted\"\n[marketplaces.host-only]\nsource = \"someone/else\"\n[plugins.host-plugin]\nenabled = true\n"
  )
  var staged = try stageCodex(source: source)
  var config = try #require(readFile(staged.path + "/config.toml"))
  #expect(config.contains("model = \"gpt-5\""))
  for leaked in ["/host/secret", "host-only", "host-plugin"] { #expect(!config.contains(leaked)) }
  staged.remove()
  staged = try stageCodex(source: source, preserved: preserved)
  config = try #require(readFile(staged.path + "/config.toml"))
  #expect(config.contains("[marketplaces.codex-plugins]"))
  #expect(config.contains("[plugins.\"my-lsp@codex-plugins\"]"))
  #expect(config.contains("[projects.\"/workspace\"]"))
  #expect(!config.contains("/host/secret"))
  staged.remove()
}

@Test func codexBootstrapNeedAndPluginDelta() throws {
  let source = try scratchDirectory("codex")
  defer { try? FileManager.default.removeItem(atPath: source) }
  #expect(
    !CodexConfigFiles.bootstrapNeeded(
      source: source, mcpServers: [:], hasPlugins: false, auth: .apiKey))
  #expect(
    !CodexConfigFiles.bootstrapNeeded(
      source: nil, mcpServers: [:], hasPlugins: false, auth: .apiKey))
  #expect(
    CodexConfigFiles.bootstrapNeeded(source: nil, mcpServers: [:], hasPlugins: true, auth: .apiKey))
  #expect(
    CodexConfigFiles.bootstrapNeeded(
      source: nil, mcpServers: [:], hasPlugins: false, auth: .chatgpt))
  try writeFile(source + "/auth.json", "{}")
  #expect(
    CodexConfigFiles.bootstrapNeeded(
      source: source, mcpServers: [:], hasPlugins: false, auth: .apiKey))

  let (m, p) = AgentBootstrap.pluginDelta(
    wantedMarketplaces: ["a", "b"], wantedPlugins: ["p1@a", "p2@b"], bakedMarketplaces: ["a"],
    bakedPlugins: ["p1@a"])
  #expect(m == ["b"] && p == ["p2@b"])
  #expect(CodexChecks.missingGuestCLIMessage.contains("--no-agents"))
  #expect(CodexChecks.missingGuestCLIMessage.contains("--no-claude"))
  #expect(CodexChecks.missingGuestCLIMessage.contains("coop setup --rebuild"))
  for part in ["keyring", "coop start", "--no-agents", "auth.json"] {
    #expect(CodexChecks.keyringNotConfiguredMessage.contains(part))
  }
  #expect(
    CodexChecks.launchArguments(ask: false, ["--model", "x"]) == [
      "--dangerously-bypass-approvals-and-sandbox", "--model", "x",
    ])
  #expect(CodexChecks.launchArguments(ask: true, ["--model", "x"]) == ["--model", "x"])
  #expect(
    CodexChecks.launchArguments(ask: false, ["login", "--device-auth"]) == [
      "login", "--device-auth",
    ])
  #expect(CodexChecks.launchArguments(ask: false, ["logout"]) == ["logout"])
}

@Test func mcpDefinitionsSerializeInSerdeOrder() throws {
  let stdio = MCPServer.stdio(
    command: "npx", args: ["-y", "srv"], env: [try EnvVarName("B"): try EnvVarName("HOST_B")])
  #expect(stdio.json.compact == #"{"command":"npx","args":["-y","srv"],"env":{"B":"HOST_B"}}"#)
  let http = MCPServer.http(
    url: URL(string: "https://mcp.example.com")!,
    headers: ["X-B": Secret("2"), "Auth": Secret("cmd:printf tok")])
  let resolved = try http.resolvingHeaders(
    CredentialResolver(environment: ["PATH": "/usr/bin:/bin"]), label: "MCP server", name: "ex")
  #expect(
    resolved.json.compact
      == #"{"type":"http","url":"https://mcp.example.com/","headers":{"Auth":"tok","X-B":"2"}}"#)
  let failing = MCPServer.sse(url: URL(string: "https://x")!, headers: ["A": Secret("cmd:exit 1")])
  let error = try #require(throws: (any Error).self) {
    try failing.resolvingHeaders(
      CredentialResolver(environment: ["PATH": "/usr/bin:/bin"]), label: "MCP server", name: "ex")
  }
  #expect("\(error)".contains("Failed to resolve header 'A' for MCP server 'ex'"))
}

// MARK: - End to end against the fake guest

@Test func firstBootBootstrapConfiguresBothAgents() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let hostClaude = guest.root + "/hosthome/.claude"
  try writeFile(hostClaude + "/CLAUDE.md", "host instructions")
  try writeFile(hostClaude + "/settings.json", #"{"outputStyle":"host","env":{"SECRET":"x"}}"#)
  let market = guest.root + "/market"
  try writeFile(market + "/marketplace.json", "{}")
  let config = try testConfig(
    #"""
    "claude": {"marketplaces": ["\#(market)"], "plugins": ["p@m"],
               "mcp_servers": {"srv": {"command": "run", "args": ["a"]}}},
    "codex": {"auth": "chatgpt", "plugins": ["cp@m"]}
    """#, home: guest.root + "/hosthome")
  let instance = try testInstance(guest.root + "/instance")
  var session = SSHSession(target: guest.target)
  session.env.set("CLAUDE_CODE_OAUTH_TOKEN", Secret("oauth"))
  try guest.bootstrap(config).bootstrapAgents(session, instance: instance, mode: .firstBoot)

  let settings = try OrderedJSON.parse(try #require(guest.guestFile(".claude/settings.json")))
  #expect(settings["permissions"]?["defaultMode"] == .string("bypassPermissions"))
  #expect(settings["outputStyle"] == .string("host"))
  #expect(settings["env"] == nil)
  #expect(guest.guestFile(".claude/CLAUDE.md") == "host instructions")
  #expect(
    guest.guestFile(".claude/coop-import.json")
      == #"{"preferences":{"outputStyle":"host"},"pluginIds":[]}"#)
  #expect(guest.guestFile(".claude.json")?.contains("\"hasCompletedOnboarding\": true") == true)
  #expect(guest.guestFile(".coop/marketplaces/claude/market/marketplace.json") == "{}")
  let calls = guest.log("guest-calls.log")
  #expect(
    calls.contains("claude plugin marketplace add ~/.coop/marketplaces/claude/market --scope user"))
  #expect(calls.contains("claude plugin install p@m -s user"))
  #expect(calls.contains(#"claude mcp add-json -s user srv {"command":"run","args":["a"]}"#))
  // The definition (with any resolved header secrets) reached the guest on
  // stdin, never the host ssh argv.
  #expect(!guest.log("commands.log").contains { $0.contains(#""command":"run""#) })
  #expect(calls.contains("codex plugin add cp@m"))
  #expect(guest.guestFile(".codex/config.toml") == "cli_auth_credentials_store = \"keyring\"\n")
  #expect(guest.log("commands.log").contains("rm -f ~/.codex/auth.json"))
  #expect(try ModelState.tryLoad(instance)?.codexKeyringMaterialized == true)
  #expect(guest.sink.text.contains("Codex bootstrap complete"))
  // A restart refreshes content but installs nothing.
  try FileManager.default.removeItem(atPath: guest.root + "/guest-calls.log")
  try guest.bootstrap(config).bootstrapAgents(session, instance: instance, mode: .restart)
  #expect(!guest.log("guest-calls.log").contains { $0.contains("plugin") })
  #expect(guest.sink.text.contains("Codex bootstrap refreshed"))
}

@Test func missingCLIsAndGuestSupportFailExplicitly() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  try guest.flag("test-x-fails")
  let instance = try testInstance(guest.root + "/instance")
  let claude = try testConfig(#""claude": {"plugins": ["p@m"], "config_dir": false}"#)
  let error = try #require(throws: (any Error).self) {
    try guest.bootstrap(claude).bootstrapAgents(
      SSHSession(target: guest.target), instance: instance, mode: .firstBoot)
  }
  #expect("\(error)".contains("Claude Code CLI is not installed in the guest"))
  let codex = try testConfig(
    #""claude": {"config_dir": false}, "codex": {"plugins": ["p@m"], "config_dir": false}"#)
  let codexError = try #require(throws: (any Error).self) {
    try guest.bootstrap(codex).bootstrapAgents(
      SSHSession(target: guest.target), instance: instance, mode: .firstBoot)
  }
  #expect("\(codexError)".contains("Codex CLI is not installed in the guest"))
  let account = try testConfig(#""claude": {"config_dir": false}, "codex": {"auth": "chatgpt"}"#)
  #expect(throws: (any Error).self) {
    try guest.bootstrap(account).bootstrapAgents(
      SSHSession(target: guest.target), instance: instance, mode: .restart)
  }
  #expect(throws: (any Error).self) {
    try CodexChecks.ensureKeyringConfigured(guest.client, guest.target)
  }
}

@Test func postStartSequenceHonorsNoAgentsAndSwallowsHookFailures() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let config = try testConfig(
    #""post_start": "echo hook > ~/hook.txt; exit 3", "codex": {"auth": "chatgpt"}, "proxy": {"anthropic": {"credential": "cmd:printf k"}}"#
  )
  try FileManager.default.createDirectory(
    atPath: instance.directory, withIntermediateDirectories: true)
  try writeFile(ProxyLauncher.forwardPIDPath(instance, "model-8000"), "0")
  try guest.bootstrap(config).bootstrapAndPostStart(
    instance, target: guest.target, repo: nil, noAgents: true, postStartOverride: nil,
    mode: .restart)
  #expect(guest.guestFile("hook.txt") == "hook\n")
  let log = guest.sink.text
  #expect(log.contains("proxy mode is configured but --no-agents skips agent bootstrap"))
  #expect(log.contains(AgentBootstrap.noAgentsChatGPTWarning))
  #expect(log.contains("post_start hook failed (continuing)"))
  #expect(log.contains("Skipping guest agent bootstrap (--no-agents)"))
  // The previous boot's model tunnels are closed first.
  #expect(ProxyLauncher.recordedModelTunnels(instance).isEmpty)
  #expect(
    AgentBootstrap.noAgentsSkipsCodexKeyring(noAgents: true, auth: .chatgpt) { true } == false)
  #expect(
    AgentBootstrap.noAgentsSkipsCodexKeyring(noAgents: false, auth: .chatgpt) { false } == false)
}

@Test func guestTOMLNestingIsBoundedForDottedKeysToo() {
  // A guest-written ~/.codex/config.toml must fail to parse, not exhaust
  // the host's stack.
  let header = "[projects" + String(repeating: ".a", count: 30_000) + "]\nx = 1\n"
  #expect(throws: (any Error).self) { try TOMLTable.parse(header) }
  let dotted = "projects" + String(repeating: ".a", count: 30_000) + " = 1\n"
  #expect(throws: (any Error).self) { try TOMLTable.parse(dotted) }
  #expect(throws: Never.self) {
    try TOMLTable.parse("[a" + String(repeating: ".b", count: 100) + "]\nx = 1\n")
  }
}

// MARK: - proxy.mode

@Test func requiredModeWithholdsEveryProviderVariableAndRefusesDeclarations() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let quiet = try testConfig(#""proxy": {"mode": "required"}, "guest_env": {"OK": "1"}"#)
  let resolver = CredentialResolver(environment: guest.environment)
  let agents = AgentBootstrap(
    config: quiet, client: guest.client,
    environment: ["ANTHROPIC_API_KEY": "sk-host", "OPENAI_API_KEY": "sk-host2"], home: nil,
    resolver: resolver, proxies: guest.proxies(resolver), github: NoGitHub(),
    diagnostics: guest.sink.diagnostics)
  // Automatic host forwards are withheld without an error.
  let env = try agents.prepareEnvForwarding(
    repo: nil, suppressAnthropicKey: false, suppressOpenAIKey: false)
  #expect(env.names == ["OK"])

  for declaration in [
    #""claude": {"env_forward": ["CLAUDE_CODE_OAUTH_TOKEN"]}"#,
    #""guest_env": {"ANTHROPIC_AUTH_TOKEN": "x"}"#,
    #""codex": {"env_forward": ["OPENAI_API_KEY"]}"#,
  ] {
    let config = try testConfig(#""proxy": {"mode": "required"}, "# + declaration)
    let error = try #require(throws: HostError.self) {
      try guest.bootstrap(config).prepareEnvForwarding(
        repo: nil, suppressAnthropicKey: false, suppressOpenAIKey: false)
    }
    #expect(error.message.contains("proxy.mode = \"required\""))
    #expect(!error.message.contains("\"x\""))
  }
}

@Test func requiredModeRefusesRuntimeEnvProviderVariables() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  try GuestEnvState(literals: [try EnvVarName("ANTHROPIC_API_KEY"): "raw"]).save(instance)
  let agents = guest.bootstrap(try testConfig(#""proxy": {"mode": "required"}"#))
  #expect(throws: HostError.self) {
    try agents.prepareSession(instance, target: guest.target, repo: nil)
  }
}

@Test func proxiedProviderWithholdsAllOfItsVariablesInAutoMode() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let config = try testConfig(
    #""claude": {"env_forward": ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"]}, "codex": {"env_forward": ["OPENAI_API_KEY"]}"#
  )
  let resolver = CredentialResolver(environment: guest.environment)
  let agents = AgentBootstrap(
    config: config, client: guest.client,
    environment: [
      "CLAUDE_CODE_OAUTH_TOKEN": "t", "ANTHROPIC_AUTH_TOKEN": "a", "OPENAI_API_KEY": "o",
    ], home: nil, resolver: resolver, proxies: guest.proxies(resolver), github: NoGitHub(),
    diagnostics: guest.sink.diagnostics)
  let env = try agents.prepareEnvForwarding(
    repo: nil, suppressAnthropicKey: true, suppressOpenAIKey: false)
  #expect(!env.contains("CLAUDE_CODE_OAUTH_TOKEN") && !env.contains("ANTHROPIC_AUTH_TOKEN"))
  // Unproxied OpenAI still forwards the raw key.
  #expect(env.contains("OPENAI_API_KEY"))
  #expect(
    guest.sink.text.contains("proxy mode: ignoring env_forward entry 'CLAUDE_CODE_OAUTH_TOKEN'"))
}

@Test func offModeIgnoresConfiguredUpstreams() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let config = try testConfig(
    #""proxy": {"mode": "off", "anthropic": {"credential": "cmd:printf x"}}"#)
  #expect(config.proxy.mode == .off)
  #expect(try ProxyState.effectiveUpstream(instance, .anthropic, config: config.proxy) == nil)
  #expect(try !guest.bootstrap(config).proxyConfigured(instance, .anthropic))
  let auto = try testConfig(#""proxy": {"anthropic": {"credential": "cmd:printf x"}}"#)
  #expect(auto.proxy.mode == .auto)
  #expect(try ProxyState.effectiveUpstream(instance, .anthropic, config: auto.proxy) != nil)
}

@Test func requiredModeFailsStartWithoutAnyProviderProxy() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let agents = guest.bootstrap(try testConfig(#""proxy": {"mode": "required"}"#))
  let error = try #require(throws: HostError.self) {
    try agents.bootstrapAndPostStart(
      instance, target: guest.target, repo: nil, noAgents: false, postStartOverride: nil,
      mode: .firstBoot)
  }
  #expect(error.message.contains("no provider proxy is configured"))
}

// MARK: - Stored-secret references

private final class FakeSecrets: SecretReferenceResolver, @unchecked Sendable {
  var calls: [Set<SecretName>] = []
  let values: [SecretName: [UInt8]]
  private var cache: [SecretName: Secret<[UInt8]>] = [:]
  init(_ values: [SecretName: [UInt8]]) { self.values = values }
  /// Like the CLI's resolver: only names not yet cached cost an unlock.
  func resolve(_ names: Set<SecretName>) throws -> [SecretName: Secret<[UInt8]>] {
    let missing = names.subtracting(cache.keys)
    if !missing.isEmpty {
      calls.append(missing)
      cache.merge(values.filter { missing.contains($0.key) }.mapValues(Secret.init)) { $1 }
    }
    return cache.filter { names.contains($0.key) }
  }
}

@Test func sessionsResolveReferencesInOneBatchAndNeverPersistValues() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  try GuestEnvState(entries: [
    try EnvVarName("GUEST_VAR"): .secret(try SecretName("db")),
    try EnvVarName("TOKEN"): .secret(try SecretName("tok")),
    try EnvVarName("MODE"): .literal("dev"),
  ]).save(instance)
  let secrets = FakeSecrets([
    try SecretName("db"): Array("canary-db".utf8), try SecretName("tok"): Array("canary-tok".utf8),
  ])
  let resolver = CredentialResolver(environment: guest.environment)
  let agents = AgentBootstrap(
    config: try testConfig(""), client: guest.client, environment: [:], home: nil,
    resolver: resolver, proxies: guest.proxies(resolver), github: NoGitHub(),
    diagnostics: guest.sink.diagnostics, secrets: secrets)
  let session = try agents.prepareSession(instance, target: guest.target, repo: nil)
  #expect(secrets.calls == [[try SecretName("db"), try SecretName("tok")]])
  try guest.client.exec(session, RemoteCommand().literal("true"))
  let seen = guest.log("env.log")
  #expect(seen.contains("GUEST_VAR=canary-db") && session.env.contains("TOKEN"))
  #expect(!guest.log("argv.log").joined().contains("canary"))
  #expect(!guest.sink.text.contains("canary"))
  let persisted = try String(contentsOfFile: instance.guestEnvironmentStatePath, encoding: .utf8)
  #expect(!persisted.contains("canary"))
}

@Test func unresolvableOrInvalidReferencesFailTheSession() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  try GuestEnvState(entries: [try EnvVarName("DB"): .secret(try SecretName("db"))]).save(instance)
  let resolver = CredentialResolver(environment: guest.environment)
  func agents(_ secrets: (any SecretReferenceResolver)?) throws -> AgentBootstrap {
    AgentBootstrap(
      config: try testConfig(""), client: guest.client, environment: [:], home: nil,
      resolver: resolver, proxies: guest.proxies(resolver), github: NoGitHub(),
      diagnostics: guest.sink.diagnostics, secrets: secrets)
  }
  #expect(throws: HostError.self) {
    try agents(nil).prepareSession(instance, target: guest.target, repo: nil)
  }
  let missing = try #require(throws: HostError.self) {
    try agents(FakeSecrets([:])).prepareSession(instance, target: guest.target, repo: nil)
  }
  #expect(missing.message.contains("unable to resolve required secret 'db'"))
  #expect(throws: HostError.self) {
    try agents(FakeSecrets([try SecretName("db"): [0x61, 0x00]])).prepareSession(
      instance, target: guest.target, repo: nil)
  }
}

@Test func sessionUnlocksOnceForEnvReferencesAndTheGitHubPAT() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  try GuestEnvState(entries: [try EnvVarName("DB"): .secret(try SecretName("db"))]).save(instance)
  let secrets = FakeSecrets([
    try SecretName("db"): Array("d".utf8), try SecretName("pat"): Array("github_pat_x".utf8),
  ])
  let resolver = CredentialResolver(environment: guest.environment, secrets: secrets)
  let config = try testConfig(
    #""github": {"mode": "pat", "pat": {"org/repo": {"token": "vault:pat"}, "org/other": {"token": "vault:unused"}}}"#
  )
  let agents = AgentBootstrap(
    config: config, client: guest.client, environment: [:], home: nil, resolver: resolver,
    proxies: guest.proxies(resolver), github: NoGitHub(), diagnostics: guest.sink.diagnostics,
    secrets: secrets)
  _ = try agents.prepareSession(
    instance, target: guest.target, repo: try RepoSlug("org/repo"))
  // One unlock, and only for what this session uses.
  #expect(secrets.calls == [[try SecretName("db"), try SecretName("pat")]])
}

@Test func sessionPrefetchLeavesAMissingStoreToTheLaterError() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let resolver = CredentialResolver(environment: guest.environment)
  let config = try testConfig(
    #""github": {"mode": "pat", "pat": {"org/repo": {"token": "vault:pat"}}}"#)
  let agents = AgentBootstrap(
    config: config, client: guest.client, environment: [:], home: nil, resolver: resolver,
    proxies: guest.proxies(resolver), github: NoGitHub(), diagnostics: guest.sink.diagnostics,
    secrets: nil)
  // No store and nothing that reads the PAT: the prefetch is a no-op.
  _ = try agents.prepareSession(instance, target: guest.target, repo: try RepoSlug("org/repo"))
  // With `--env` references the existing, clearer error still names the cause.
  try GuestEnvState(entries: [try EnvVarName("DB"): .secret(try SecretName("db"))]).save(instance)
  let error = try #require(throws: HostError.self) {
    try agents.prepareSession(instance, target: guest.target, repo: try RepoSlug("org/repo"))
  }
  #expect(error.message.contains("cannot unlock the secret store"))
}

@Test func providerSecretsNeverReachTheGuestAndSelectTheProxy() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  try GuestEnvState(entries: [
    try EnvVarName("OPENAI_API_KEY"): .secret(try SecretName("openai")),
    try EnvVarName("GUEST_VAR"): .secret(try SecretName("db")),
  ]).save(instance)
  let secrets = FakeSecrets([
    try SecretName("openai"): Array("canary-openai".utf8), try SecretName("db"): Array("x".utf8),
  ])
  let resolver = CredentialResolver(environment: guest.environment, secrets: secrets)
  let config = try testConfig(#""proxy": {"openai": {"credential": "cmd:printf default"}}"#)
  let agents = AgentBootstrap(
    config: config, client: guest.client, environment: ["OPENAI_API_KEY": "sk-host"], home: nil,
    resolver: resolver, proxies: guest.proxies(resolver), github: NoGitHub(),
    diagnostics: guest.sink.diagnostics, secrets: secrets)
  let session = try agents.prepareSession(instance, target: guest.target, repo: nil)
  #expect(!session.env.contains("OPENAI_API_KEY"))
  #expect(session.env.contains("GUEST_VAR"))
  // Only the generic reference was resolved for the session.
  #expect(secrets.calls == [[try SecretName("db")]])
  #expect(try agents.proxyConfigured(instance, .openai))
  // The provider secret outranks the configured default and resolves via vault:.
  let upstream = try #require(
    try ProxyState.effectiveUpstream(instance, .openai, config: config.proxy))
  #expect(upstream.credential.command.expose() == "vault:openai" && upstream.auth == .bearer)
  #expect(try resolver.resolve(upstream.credential).expose() == "canary-openai")

  // Under proxy.mode = "required" the routed declaration is legitimate.
  let required = try testConfig(#""proxy": {"mode": "required"}"#)
  let strict = AgentBootstrap(
    config: required, client: guest.client, environment: [:], home: nil, resolver: resolver,
    proxies: guest.proxies(resolver), github: NoGitHub(), diagnostics: guest.sink.diagnostics,
    secrets: secrets)
  #expect(
    !(try strict.prepareSession(instance, target: guest.target, repo: nil)).env.contains(
      "OPENAI_API_KEY"))
  #expect(!guest.sink.text.contains("ignoring runtime --env entry 'OPENAI_API_KEY'"))

  // proxy.mode = "off" makes it unavailable rather than guest-visible.
  let off = try testConfig(#""proxy": {"mode": "off"}"#)
  #expect(throws: HostError.self) {
    try ProxyState.effectiveUpstream(instance, .openai, config: off.proxy)
  }
  #expect(throws: HostError.self) {
    try guest.bootstrap(off).prepareSession(instance, target: guest.target, repo: nil)
  }
}

@Test func vaultCredentialReferencesResolveThroughTheStore() throws {
  let secrets = FakeSecrets([
    try SecretName("ok"): Array("value".utf8), try SecretName("nul"): [0x61, 0x00],
  ])
  let resolver = CredentialResolver(environment: [:], secrets: secrets)
  #expect(try resolver.resolveAllowingStored(Secret("vault:ok")).expose() == "value")
  #expect(throws: HostError.self) { try resolver.resolveAllowingStored(Secret("vault:nul")) }
  #expect(throws: HostError.self) { try resolver.resolveAllowingStored(Secret("vault:missing")) }
  #expect(throws: HostError.self) { try resolver.resolveAllowingStored(Secret("vault:../x")) }
  #expect(throws: HostError.self) {
    try CredentialResolver(environment: [:], secrets: nil).resolveAllowingStored(Secret("vault:ok"))
  }
  #expect(try resolver.resolve(Secret("plain")).expose() == "plain")
}

@Test func vaultIsRefusedForValuesPlacedInTheGuest() throws {
  let secrets = FakeSecrets([try SecretName("anthropic"): Array("canary".utf8)])
  let resolver = CredentialResolver(environment: [:], secrets: secrets)
  let error = try #require(throws: HostError.self) {
    try resolver.resolve(Secret("vault:anthropic"))
  }
  #expect(error.message.contains("would be placed in the guest"))
  #expect(try resolver.resolveAllowingStored(Secret("vault:anthropic")).expose() == "canary")
  #expect(secrets.calls == [[try SecretName("anthropic")]])
  // Errors never echo the reference text, which may be a pasted key.
  let invalid = try #require(throws: HostError.self) {
    try resolver.resolveAllowingStored(Secret("vault:sk ant pasted"))
  }
  #expect(!invalid.message.contains("pasted"))
  let missing = try #require(throws: HostError.self) {
    try resolver.resolveAllowingStored(Secret("vault:sk-ant-api03-xyz"))
  }
  #expect(!missing.message.contains("sk-ant"))
}
