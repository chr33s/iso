import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

// MARK: - Launch

@Test func antigravityLaunchSkipsPermissionsUnlessAskedOrASubcommand() {
  let bypass = AntigravityChecks.bypassFlag
  #expect(bypass == "--dangerously-skip-permissions")
  #expect(AntigravityChecks.launchArguments(ask: false, []) == [bypass])
  #expect(AntigravityChecks.launchArguments(ask: false, ["-p", "hi"]) == [bypass, "-p", "hi"])
  #expect(AntigravityChecks.launchArguments(ask: true, ["-p", "hi"]) == ["-p", "hi"])
  for subcommand in ["mcp", "update", "plugin", "acp", "install"] {
    #expect(AntigravityChecks.launchArguments(ask: false, [subcommand]) == [subcommand])
  }
  // An explicit flag is not doubled.
  #expect(AntigravityChecks.launchArguments(ask: false, [bypass]) == [bypass])
  #expect(AntigravityChecks.launchArguments(ask: false, [bypass + "=true"]) == [bypass + "=true"])
}

@Test func antigravityIsABuiltinWithAReviewedBinary() throws {
  let id = try AgentDefinitionID("antigravity")
  #expect(id.isReserved)
  let definition = try #require(AgentCatalog.builtin(id))
  #expect(definition.authAdapter == .antigravity)
  let plan = try AgentLaunchPlanner.plan(
    definition: definition, source: .builtin,
    definitionHash: AgentCatalog.definitionHash(definition), cliImage: nil, cliProfiles: [],
    ask: false)
  #expect(plan.adapter.providerName == "google")
  let invocation = try AgentDispatch.invocation(
    plan: plan, passthrough: ["--model", "gemini"], guestUser: .default, codexAccount: false,
    stdinIsTerminal: true, stdoutIsTerminal: true)
  #expect(
    invocation.argv == [
      "/usr/local/bin/agy", "--dangerously-skip-permissions", "--model", "gemini",
    ])
  let asking = try AgentLaunchPlanner.plan(
    definition: definition, source: .builtin, definitionHash: "h", cliImage: nil,
    cliProfiles: [], ask: true)
  #expect(
    try AgentDispatch.invocation(
      plan: asking, passthrough: [], guestUser: .default, codexAccount: false,
      stdinIsTerminal: false, stdoutIsTerminal: false
    ).argv == ["/usr/local/bin/agy"])
  #expect(throws: HostError.self) {
    try AgentDispatch.invocation(
      plan: asking, passthrough: ["--dangerously-skip-permissions"], guestUser: .default,
      codexAccount: false, stdinIsTerminal: true, stdoutIsTerminal: true)
  }
  // A definition cannot set the managed flag or name another executable.
  let bypassing = try AgentDefinitionDecoder.decode(
    Array(
      #"{"schema_version":1,"id":"agy-yolo","display_name":"a","launch":{"argv":["agy","--dangerously-skip-permissions"]},"auth_adapter":"antigravity"}"#
        .utf8), path: "d.json", format: .json)
  #expect(throws: HostError.self) {
    try AgentLaunchPlanner.plan(
      definition: bypassing, source: .installed, definitionHash: "h", cliImage: nil,
      cliProfiles: [], ask: false)
  }
  let other = try AgentDefinitionDecoder.decode(
    Array(
      #"{"schema_version":1,"id":"agy-other","display_name":"a","launch":{"argv":["gemini"]},"auth_adapter":"antigravity"}"#
        .utf8), path: "d.json", format: .json)
  #expect(throws: HostError.self) {
    try AgentLaunchPlanner.plan(
      definition: other, source: .installed, definitionHash: "h", cliImage: nil,
      cliProfiles: [], ask: false)
  }
}

// MARK: - Managed guest files

@Test func antigravitySettingsOwnOnlyTheGeminiProviderKey() throws {
  let fresh = try AntigravityFiles.settings(nil, apiKeyAuth: true)
  #expect(try OrderedJSON.parse(fresh)["modelProvider"] == .string("gemini"))
  let kept = try AntigravityFiles.settings(#"{"theme":"dark"}"#, apiKeyAuth: true)
  #expect(try OrderedJSON.parse(kept)["theme"] == .string("dark"))
  // Without a key the CLI would refuse to start, so iso's setting is removed.
  let removed = try AntigravityFiles.settings(
    #"{"theme":"dark","modelProvider":"gemini"}"#, apiKeyAuth: false)
  #expect(try OrderedJSON.parse(removed)["modelProvider"] == nil)
  #expect(try OrderedJSON.parse(removed)["theme"] == .string("dark"))
  #expect(throws: AntigravityFileError.self) {
    try AntigravityFiles.settings("[1]", apiKeyAuth: true)
  }
  #expect(throws: AntigravityFileError.self) {
    try AntigravityFiles.settings("{\"a\": 1, // jsonc\n}", apiKeyAuth: true)
  }
}

@Test func antigravityMCPConfigUpsertsIsoServersAndKeepsOthers() throws {
  let existing = #"{"mcpServers":{"mine":{"command":"m"},"s":{"command":"old"}},"x":1}"#
  let out = try AntigravityFiles.mcpConfig(
    existing,
    servers: [
      ("s", .stdio(command: "new", args: ["a"], env: [:])),
      (
        "h",
        .http(url: URL(string: "https://h.example/mcp")!, headers: ["Authorization": Secret("t")])
      ),
    ])
  let json = try OrderedJSON.parse(out)
  #expect(json["x"] != nil)
  let pruned = try OrderedJSON.parse(
    AntigravityFiles.mcpConfig(out, servers: [], removing: ["h", "s"]))
  #expect(pruned["mcpServers"]?.objectMembers?.pairs.map(\.0) == ["mine"])
  let servers = try #require(json["mcpServers"]?.objectMembers)
  #expect(servers["mine"]?["command"] == .string("m"))
  #expect(servers["s"]?["command"] == .string("new"))
  #expect(servers["s"]?["args"] == .array([.string("a")]))
  #expect(servers["h"]?["url"] == .string("https://h.example/mcp"))
  #expect(servers["h"]?["headers"]?["Authorization"] == .string("t"))
}

@Test func antigravityBootstrapWritesSettingsAndMCPConfigThroughStdin() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let config = try testConfig(
    #"""
    "antigravity": {"api_key": "cmd:printf gem-key",
      "mcp_servers": {"h": {"type": "http", "url": "https://h.example/mcp",
                            "headers": {"X-Token": "cmd:printf header-secret"}}}}
    """#)
  let agents = guest.bootstrap(config)
  let session = try agents.prepareSession(instance, target: guest.target, repo: nil)
  #expect(session.env.contains("GEMINI_API_KEY"))
  try agents.bootstrapAntigravity(session, instance: instance, mode: .firstBoot)
  let settings = try #require(
    readFile(guest.root + "/home/.gemini/antigravity-cli/settings.json"))
  #expect(try OrderedJSON.parse(settings)["modelProvider"] == .string("gemini"))
  let mcp = try #require(readFile(guest.root + "/home/.gemini/config/mcp_config.json"))
  #expect(mcp.contains("header-secret"))
  // Resolved header values travel on stdin, never on the host's ssh argv.
  #expect(!guest.log("argv.log").joined().contains("header-secret"))
  #expect(!guest.log("argv.log").joined().contains("gem-key"))
  #expect(!guest.sink.text.contains("header-secret"))

  // No key and no proxy: iso's provider setting is withdrawn.
  let unkeyed = guest.bootstrap(try testConfig(#""antigravity": {}"#))
  try unkeyed.bootstrapAntigravity(
    try unkeyed.prepareSession(instance, target: guest.target, repo: nil), instance: instance,
    mode: .restart)
  let after = try #require(readFile(guest.root + "/home/.gemini/antigravity-cli/settings.json"))
  #expect(try OrderedJSON.parse(after)["modelProvider"] == nil)
}

@Test func antigravityBootstrapRemovesServersItNoLongerConfigures() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let mcpPath = guest.root + "/home/.gemini/config/mcp_config.json"
  try writeFile(mcpPath, #"{"mcpServers":{"mine":{"command":"m"}}}"#)
  let configured = guest.bootstrap(
    try testConfig(
      #"""
      "antigravity": {"mcp_servers": {"h": {"type": "http", "url": "https://h.example/",
                                            "headers": {"A": "cmd:printf revoked-secret"}}}}
      """#))
  try configured.bootstrapAntigravity(
    SSHSession(target: guest.target), instance: instance, mode: .firstBoot)
  #expect(readFile(mcpPath)?.contains("revoked-secret") == true)
  // Removing every server still rewrites the file, deleting only iso's.
  let removed = guest.bootstrap(try testConfig(#""antigravity": {}"#))
  try removed.bootstrapAntigravity(
    SSHSession(target: guest.target), instance: instance, mode: .restart)
  let after = try #require(readFile(mcpPath))
  #expect(!after.contains("revoked-secret"))
  #expect(try OrderedJSON.parse(after)["mcpServers"]?["mine"] != nil)
  #expect(try AntigravityFiles.loadManagedNames(instance).isEmpty)
}

/// `modelProvider` follows the configuration, not the boot shell, so later
/// sessions agree with it.
@Test func antigravityProviderSettingFollowsConfigurationNotTheBootShell() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let settingsPath = guest.root + "/home/.gemini/antigravity-cli/settings.json"
  let keyed = guest.bootstrap(try testConfig(#""antigravity": {"api_key": "cmd:printf k"}"#))
  try keyed.bootstrapAntigravity(
    SSHSession(target: guest.target), instance: instance, mode: .firstBoot)
  #expect(try OrderedJSON.parse(readFile(settingsPath)!)["modelProvider"] == .string("gemini"))
  // Forwarded by name: declared, so set too.
  let forwarded = guest.bootstrap(
    try testConfig(#""claude": {"env_forward": ["GEMINI_API_KEY"]}"#))
  #expect(try forwarded.geminiKeyDeclared(instance))
  // Withheld under `required`: not declared, so removed.
  let required = guest.bootstrap(
    try testConfig(#""antigravity": {"api_key": "cmd:printf k"}, "proxy": {"mode": "required"}"#))
  #expect(try !required.geminiKeyDeclared(instance))
  try required.bootstrapAntigravity(
    SSHSession(target: guest.target), instance: instance, mode: .restart)
  #expect(try OrderedJSON.parse(readFile(settingsPath)!)["modelProvider"] == nil)
  // An unreadable settings file is warned about and left alone.
  try writeFile(settingsPath, "{\"theme\": \"dark\", // mine\n}")
  try keyed.bootstrapAntigravity(
    SSHSession(target: guest.target), instance: instance, mode: .restart)
  #expect(readFile(settingsPath) == "{\"theme\": \"dark\", // mine\n}")
  #expect(guest.sink.text.contains("antigravity-cli/settings.json in the guest is not valid JSON"))
}

@Test func antigravityBootstrapRequiresTheCLIOnlyWhenConfigured() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  try guest.flag("test-x-fails")
  let plain = guest.bootstrap(try testConfig())
  try plain.bootstrapAntigravity(
    SSHSession(target: guest.target), instance: instance, mode: .firstBoot)
  #expect(readFile(guest.root + "/home/.gemini/antigravity-cli/settings.json") == nil)
  // The computer-use server alone does not require agy.
  let computerUse = guest.bootstrap(
    try testConfig().addingMCPServer(
      AgentBootstrap.computerUseServer, .stdio(command: "cu", args: [], env: [:])))
  try computerUse.bootstrapAntigravity(
    SSHSession(target: guest.target), instance: instance, mode: .firstBoot)
  let withProxy = guest.bootstrap(
    try testConfig(#""proxy": {"google": {"credential": "cmd:printf k"}}"#))
  #expect(throws: HostError(AntigravityChecks.missingGuestCLIMessage)) {
    try withProxy.bootstrapAntigravity(
      SSHSession(target: guest.target), instance: instance, mode: .firstBoot)
  }
  let withMCP = guest.bootstrap(
    try testConfig(#""antigravity": {"mcp_servers": {"s": {"command": "x"}}}"#))
  #expect(throws: HostError(AntigravityChecks.missingGuestCLIMessage)) {
    try withMCP.bootstrapAntigravity(
      SSHSession(target: guest.target), instance: instance, mode: .firstBoot)
  }
}

// MARK: - Credentials

@Test func geminiKeyIsWithheldWhenProxiedAndReplacedByTheCapability() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance", index: 3)
  try GuestEnvState(literals: [try EnvVarName("GEMINI_API_KEY"): "raw-gemini"]).saveGranted(
    instance)
  let config = try testConfig(
    #"""
    "antigravity": {"api_key": "cmd:printf configured-gemini"},
    "proxy": {"google": {"credential": "cmd:printf upstream-gemini"}}
    """#)
  let agents = guest.bootstrap(config)
  try writeFile(ProxyLauncher.tokenPath(instance, "google"), "cap-gemini\n")
  let session = try agents.prepareSession(instance, target: guest.target, repo: nil)
  #expect(guest.sink.text.contains("proxy mode: ignoring runtime --env entry 'GEMINI_API_KEY'"))
  try guest.client.exec(session, RemoteCommand().literal("true"))
  let seen = guest.log("env.log")
  #expect(seen.contains("GEMINI_API_KEY=cap-gemini"))
  #expect(seen.contains("GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:11791"))
  #expect(!seen.joined().contains("raw-gemini") && !seen.joined().contains("configured-gemini"))
  #expect(guest.log("host-env.log").isEmpty)

  // `proxy.mode = "required"` withholds a raw key even without a proxy.
  let required = try testConfig(
    #""antigravity": {"api_key": "cmd:printf configured-gemini"}, "proxy": {"mode": "required"}"#)
  let env = try guest.bootstrap(required).prepareEnvForwarding(repo: nil, suppressing: [])
  #expect(!env.contains("GEMINI_API_KEY"))
}

@Test func googleProxyProvisioningAndPerVMOverride() throws {
  #expect(ProxyProvisioning.auth(for: .google, apiKey: false) == .googAPIKey)
  #expect(ProxyProvisioning.auth(for: .google, apiKey: true) == .googAPIKey)
  #expect(ProxyProvisioning.service(for: .google, vm: nil) == "iso-google")
  #expect(ProxyProvider.google.basePort == 11788)
  let ports = ProxyProvider.allCases.map(\.basePort) + [EgressPorts.base]
  #expect(Set(ports).count == ports.count)
  let directory = try scratchDirectory("google-proxy")
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let instance = try testInstance(directory)
  let reference = try #require(CredentialReference("cmd:printf k"))
  try ProxyState.setOverride(instance, provider: .google, credential: reference, auth: .googAPIKey)
  try ProxyState.setOverride(instance, provider: .openai, credential: reference, auth: .bearer)
  let state = try ProxyState.load(instance)
  #expect(state.override(for: .google) == StoredUpstream(credential: reference, auth: .googAPIKey))
  #expect(state.override(for: .openai)?.auth == .bearer)
  #expect(state.override(for: .anthropic) == nil)
}

/// The Gemini capability rides in `GEMINI_API_KEY`; a proxied boot must not
/// report it as a raw provider key.
@Test func geminiCapabilityIsNotAuditedAsARawForward() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let agents = guest.bootstrap(
    try testConfig(#""proxy": {"google": {"credential": "cmd:printf upstream"}}"#))
  try writeFile(ProxyLauncher.tokenPath(instance, "google"), "cap-gemini\n")
  #expect(try agents.proxiedProviders(instance) == [.google])
  let session = try agents.prepareSession(instance, target: guest.target, repo: nil)
  #expect(session.env.contains("GEMINI_API_KEY"))
  #expect(AgentBootstrap.rawProviderVariables(session.env, proxied: [.google]).isEmpty)
  #expect(AgentBootstrap.rawProviderVariables(session.env, proxied: []) == ["GEMINI_API_KEY"])
  var state = ModelState()
  state.mode = .local
  try state.save(instance)
  #expect(try agents.proxiedProviders(instance).isEmpty)
}
