import CoopConfiguration
import CoopCore
import Foundation
import Testing

@testable import CoopHost

private func endpoint(_ url: String, _ model: String = "m", token: String? = nil) throws
  -> LocalModel
{
  try LocalModel(hostURL: url, model: model, authToken: token.map(Secret.init))
}

// MARK: - model.json

@Test func modelStateRoundTripsAndTheDefaultIsNeverWritten() throws {
  let root = try scratchDirectory("model")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let instance = try testInstance(root)
  #expect(try ModelState.tryLoad(instance) == nil)
  #expect(try ModelState.loadOrDefault(instance).mode == .remote)

  var state = ModelState()
  state.mode = .local
  state.claudeEndpoint = try endpoint("http://localhost:11434", "qwen")
  try state.save(instance)
  let loaded = try #require(try ModelState.tryLoad(instance))
  #expect(loaded.mode == .local)
  #expect(loaded.claudeEndpoint?.model == "qwen")
  #expect(loaded.codexEndpoint == nil)
  // serde_json pretty form of the Rust record, owner-only.
  #expect(
    readFile(instance.modelStatePath)
      == """
      {
        "mode": "local",
        "claude_endpoint": {
          "host_url": "http://localhost:11434/",
          "model": "qwen",
          "auth_token": null
        }
      }
      """)
  var status = stat()
  stat(instance.modelStatePath, &status)
  #expect(status.st_mode & 0o777 == 0o600)

  try ModelState().save(instance)
  #expect(!FileManager.default.fileExists(atPath: instance.modelStatePath))
  try ModelState().save(instance)  // absent file: still fine
}

@Test func nonDefaultRemoteStatesArePersisted() throws {
  let root = try scratchDirectory("model")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let instance = try testInstance(root)
  for mutate in [
    { (s: inout ModelState) in s.claudeEndpoint = try! endpoint("http://localhost:1234") },
    { (s: inout ModelState) in s.codexMaterialized = true },
    { (s: inout ModelState) in s.codexKeyringMaterialized = true },
  ] {
    var state = ModelState()
    mutate(&state)
    try state.save(instance)
    #expect(try ModelState.tryLoad(instance)?.rendered == state.rendered)
  }
}

@Test func unreadableOrMalformedModelStateIsAnError() throws {
  let root = try scratchDirectory("model")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let instance = try testInstance(root)
  try FileManager.default.createDirectory(
    atPath: instance.modelStatePath, withIntermediateDirectories: true)
  #expect(throws: (any Error).self) { try ModelState.tryLoad(instance) }
  try FileManager.default.removeItem(atPath: instance.modelStatePath)
  try writeFile(instance.modelStatePath, #"{"mode": "sideways"}"#)
  let error = try #require(throws: (any Error).self) { try ModelState.tryLoad(instance) }
  #expect("\(error)".contains("Failed to parse model.json"))
  // Unknown fields are ignored, as serde did.
  try writeFile(instance.modelStatePath, #"{"mode": "local", "extra": 1}"#)
  #expect(try ModelState.tryLoad(instance)?.mode == .local)
}

@Test func configuredEndpointsWinOverSavedOnes() throws {
  let config = try testConfig(
    #""claude": {"local_model": {"host_url": "http://localhost:1/", "model": "from-config"}}"#)
  var state = ModelState()
  state.mode = .local
  state.claudeEndpoint = try endpoint("http://localhost:2/", "from-saved")
  #expect(state.resolvedClaude(config.claude)?.model == "from-config")
  #expect(state.resolvedClaude(try testConfig().claude)?.model == "from-saved")
  #expect(ModelState().resolvedCodex(try testConfig().codex) == nil)
}

// MARK: - Materialized routing

@Test func claudeEnvBlocksPinLocalModelsAndKeepProxyModeTransparent() {
  let env = ModelRouting.claudeEnvBlock(
    baseURL: "http://127.0.0.1:11434", model: "qwen2.5-coder", authToken: "tok")
  #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:11434")
  #expect(env["ANTHROPIC_AUTH_TOKEN"] == "tok")
  for tier in [
    "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
  ] {
    #expect(env[tier] == "qwen2.5-coder")
  }
  #expect(env["CLAUDE_CODE_ATTRIBUTION_HEADER"] == "0")
  #expect(env["CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS"] == "1")
  let proxy = ModelRouting.claudeProxyEnvBlock(
    baseURL: "http://127.0.0.1:8788", capabilityToken: "cap")
  #expect(proxy == ["ANTHROPIC_BASE_URL": "http://127.0.0.1:8788", "ANTHROPIC_AUTH_TOKEN": "cap"])
}

@Test func codexProviderBlocks() {
  let local = ModelRouting.codexLocalConfig(baseURL: "http://127.0.0.1:11434/v1/", model: "gpt-oss")
  #expect(local["model"] == .string("gpt-oss"))
  #expect(local["model_provider"] == .string("coop_local"))
  let provider = local["model_providers"]?.tableValue?["coop_local"]?.tableValue
  #expect(provider?["base_url"] == .string("http://127.0.0.1:11434/v1/"))
  #expect(provider?["wire_api"] == .string("responses"))
  #expect(provider?["env_key"] == .string("COOP_LOCAL_API_KEY"))
  for base in ["http://127.0.0.1:9788", "http://127.0.0.1:9788/"] {
    let proxy = ModelRouting.codexProxyConfig(baseURL: base)
    #expect(proxy["model"] == nil)
    let entry = proxy["model_providers"]?.tableValue?["coop_local"]?.tableValue
    #expect(entry?["base_url"] == .string("http://127.0.0.1:9788/v1"))
    #expect(entry?["name"] == .string("coop credential proxy"))
  }
}

// MARK: - Local endpoint planning (ported from endpoint_plan.rs)

private func plan(_ url: String) throws -> LocalEndpointPlan {
  try LocalEndpoints.plan(URL(string: url)!)
}

private func tunnel(_ guest: UInt16, _ host: String, _ port: UInt16) -> ReverseTunnel {
  ReverseTunnel(guestPort: guest, hostAddress: try! IPv4Address(host), hostPort: port)
}

@Test func reverseTunnelPlansKeepLoopbackNamesAndMovePrivilegedPorts() throws {
  for url in ["http://localhost:11434/v1", "https://127.0.0.1:8443/api"] {
    #expect(try plan(url).guestURL == url)
  }
  #expect(try plan("http://localhost:11434/v1").tunnel == tunnel(11434, "127.0.0.1", 11434))
  #expect(try plan("http://localhost:11434").guestURL == "http://localhost:11434/")
  let privileged = try plan("https://localhost/v1")
  #expect(privileged.guestURL == "https://localhost:40443/v1")
  #expect(privileged.tunnel == tunnel(40443, "127.0.0.1", 443))
  #expect(try plan("http://localhost:1024/").tunnel == tunnel(1024, "127.0.0.1", 1024))
  #expect(try plan("http://localhost:1023/").tunnel == tunnel(41023, "127.0.0.1", 1023))
}

@Test func otherLoopbackAddressesAreRewrittenOnlyForPlainHTTP() throws {
  let rewritten = try plan("http://127.0.0.2:8000/x?y=1")
  #expect(rewritten.guestURL == "http://127.0.0.1:8000/x?y=1")
  #expect(rewritten.tunnel == tunnel(8000, "127.0.0.2", 8000))
  #expect(throws: (any Error).self) { try plan("https://127.0.0.2:8000/") }
}

@Test func ipv6LoopbackIsRefusedAndRemoteEndpointsPassThrough() throws {
  let error = try #require(throws: (any Error).self) { try plan("http://[::1]:8000/") }
  #expect("\(error)".contains("IPv6 loopback"))
  for remote in [
    "https://models.example.com/v1", "http://192.168.1.5:8000/", "http://[2001:db8::1]:8000/",
  ] {
    let result = try plan(remote)
    #expect(result.guestURL == remote)
    #expect(result.tunnel == nil)
  }
}

@Test func endpointTunnelsAreSharedAcrossAgentsAndConflictsRejected() throws {
  let config = try testConfig()
  var shared = ModelState()
  shared.mode = .local
  shared.claudeEndpoint = try endpoint("http://localhost:11434")
  shared.codexEndpoint = try endpoint("http://127.0.0.1:11434/v1/")
  #expect(try LocalEndpoints.tunnels(shared, config: config).count == 1)
  var clash = shared
  clash.claudeEndpoint = try endpoint("http://127.0.0.1:8000")
  clash.codexEndpoint = try endpoint("http://127.0.0.2:8000/v1/")
  #expect(throws: (any Error).self) { try LocalEndpoints.tunnels(clash, config: config) }
  #expect(try LocalEndpoints.tunnels(ModelState(), config: config).isEmpty)
}

// MARK: - guest_env.json

@Test func guestEnvStateRoundTripsAndEmptyRemovesTheFile() throws {
  let root = try scratchDirectory("genv")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let instance = try testInstance(root)
  #expect(try GuestEnvState.tryLoad(instance) == nil)
  let state = GuestEnvState(entries: [
    try EnvVarName("FOO"): "1", try EnvVarName("BAR"): "2", try EnvVarName("_E"): "",
  ])
  try state.save(instance)
  #expect(try GuestEnvState.tryLoad(instance) == state)
  #expect(
    readFile(instance.guestEnvironmentStatePath)
      == "{\n  \"entries\": {\n    \"BAR\": \"2\",\n    \"FOO\": \"1\",\n    \"_E\": \"\"\n  }\n}")
  try GuestEnvState().save(instance)
  #expect(!FileManager.default.fileExists(atPath: instance.guestEnvironmentStatePath))

  try FileManager.default.createDirectory(
    atPath: instance.guestEnvironmentStatePath, withIntermediateDirectories: true)
  #expect(throws: (any Error).self) { try GuestEnvState.tryLoad(instance) }
  try FileManager.default.removeItem(atPath: instance.guestEnvironmentStatePath)
  try writeFile(instance.guestEnvironmentStatePath, #"{"entries": {"1FOO": "v"}}"#)
  #expect(throws: (any Error).self) { try GuestEnvState.tryLoad(instance) }
}

@Test func guestEnvMergeAndCLIArguments() throws {
  let k = try EnvVarName("K")
  #expect(
    GuestEnvState.merge(devcontainer: [k: "dc", try EnvVarName("D"): "1"], cli: [k: "cli"])
      == [k: "cli", try EnvVarName("D"): "1"])
  #expect(try GuestEnvState.parseCLIArgument("FOO=1") == (try EnvVarName("FOO"), "1"))
  #expect(try GuestEnvState.parseCLIArgument("EMPTY=").1 == "")
  #expect(try GuestEnvState.parseCLIArgument("URL=https://x?a=b&c=d").1 == "https://x?a=b&c=d")
  let missing = try #require(throws: (any Error).self) {
    try GuestEnvState.parseCLIArgument("BAD")
  }
  #expect("\(missing)".contains("missing '='"))
  #expect(throws: (any Error).self) { try GuestEnvState.parseCLIArgument("1X=v") }
}

// MARK: - Codex TOML

@Test func tomlPrintsLikeTheRustCrate() throws {
  let input = """
    model = "gpt-5"
    zeta = 1
    arr = [1, "a", {x = 1}]
    aot = [{a=1},{b=2}]
    f = 1.5
    e = 1e10
    b = true
    d = 1979-05-27T07:32:00Z
    [mcp_servers.sentry]
    url = "https://x"
    headers = {Authorization = "Bearer x"}
    [plugins."my-lsp@codex"]
    enabled = true
    [[arrt]]
    k = 1
    [[arrt]]
    k = 2
    [a.b.c]
    x = [ [1,2], [3] ]
    empty = {}
    "key with space" = 1

    """
  let expected = """
    arr = [1, "a", { x = 1 }]
    b = true
    d = 1979-05-27T07:32:00Z
    e = 10000000000.0
    f = 1.5
    model = "gpt-5"
    zeta = 1

    [a.b.c]
    "key with space" = 1
    x = [[1, 2], [3]]

    [a.b.c.empty]

    [[aot]]
    a = 1

    [[aot]]
    b = 2

    [[arrt]]
    k = 1

    [[arrt]]
    k = 2

    [mcp_servers.sentry]
    url = "https://x"

    [mcp_servers.sentry.headers]
    Authorization = "Bearer x"

    [plugins."my-lsp@codex"]
    enabled = true

    """
  #expect(try TOMLTable.parse(input).document == expected)
}

@Test func tomlParsesStringsNumbersAndDates() throws {
  let table = try TOMLTable.parse(
    #"""
    instructions = """
    [not-a-table]
    """
    lit = 'x"y'
    esc = "a\"b\\c\u00e9\e"
    ml = '''
    raw\n'''
    cont = """a \
      b"""
    hex = 0x1F
    under = 1_000
    neg = -17
    inf = -inf
    local = 1979-05-27 07:32:00
    date = 1979-05-27
    time = 07:32
    off = 1979-05-27T00:32:00.999999-07:00
    inline = { a.b = 1, c = [1,
      2,], }
    """#)
  #expect(table["instructions"] == .string("[not-a-table]\n"))
  #expect(table["lit"] == .string("x\"y"))
  #expect(table["esc"] == .string("a\"b\\cé\u{1B}"))
  #expect(table["ml"] == .string("raw\\n"))
  #expect(table["cont"] == .string("a b"))
  #expect(table["hex"] == .integer(31))
  #expect(table["under"] == .integer(1000))
  #expect(table["neg"] == .integer(-17))
  #expect(table["inf"] == .float(-.infinity))
  #expect(table["local"] == .datetime("1979-05-27T07:32:00"))
  #expect(table["date"] == .datetime("1979-05-27"))
  #expect(table["time"] == .datetime("07:32"))
  #expect(table["off"] == .datetime("1979-05-27T00:32:00.999999-07:00"))
  #expect(
    table["inline"]
      == .table(
        TOMLTable([
          ("a", .table(TOMLTable([("b", .integer(1))]))),
          ("c", .array([.integer(1), .integer(2)])),
        ])))
  // Round trip through the printer keeps the values.
  #expect(try TOMLTable.parse(table.document) == table)
}

@Test func tomlRejectsInvalidDocuments() {
  for bad in [
    "not = = valid", "a = 1\na = 2", "[t]\n[t]", "a = 01", "a = 1__0", "a = \"unterminated",
    "a = {b = 1}\n[a]", "[a]\nb=1\n[a.b]", "a = [1 2]", "x", "a = 1 b = 2", "a = \"\u{01}\"",
    "a.b = 1\n[a]", "a = 1979-13",
  ] {
    #expect(throws: TOMLParseError.self, "\(bad)") { try TOMLTable.parse(bad) }
  }
  let deep = "a = " + String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
  #expect(throws: TOMLParseError.self) { try TOMLTable.parse(deep) }
}

@Test func tomlStringsAndKeysAreQuotedSafely() throws {
  let table = TOMLTable([
    ("plain", .string("tab\there \"q\" \\ \u{7F}")), ("/workspace", .boolean(true)),
    ("bare-key_1", .integer(1)),
  ])
  let text = table.document
  #expect(text.contains(#""/workspace" = true"#))
  #expect(text.contains("bare-key_1 = 1"))
  #expect(text.contains(#"plain = "tab\there \"q\" \\ \u007F""#))
  #expect(try TOMLTable.parse(text) == table)
}

// MARK: - Ordered JSON

@Test func orderedJSONKeepsOrderAndPrintsLikeSerdeJSON() throws {
  let value = try OrderedJSON.parse(
    #"{"zeta":1,"a":1e16,"b":1.5e-7,"c":-0,"d":18446744073709551616,"f":0.1,"g":1.0,"i":"\u00e9\u2028/","j":1E2,"k":-5,"z":{"y":[]}}"#
  )
  #expect(
    value.compact
      == #"{"zeta":1,"a":1e+16,"b":1.5e-7,"c":-0.0,"d":1.8446744073709552e+19,"f":0.1,"g":1.0,"i":"é\#u{2028}/","j":100.0,"k":-5,"z":{"y":[]}}"#
  )
  #expect(
    try OrderedJSON.parse(#"{"a":{"b":[1,{}],"c":{}},"d":[]}"#).pretty
      == "{\n  \"a\": {\n    \"b\": [\n      1,\n      {}\n    ],\n    \"c\": {}\n  },\n  \"d\": []\n}"
  )
  for bad in ["", "[1,]", "{\"a\":1,}", "01", "\"\\ud800\"", "nul", "[1] x", "{'a':1}"] {
    #expect(throws: OrderedJSON.ParseError.self, "\(bad)") { try OrderedJSON.parse(bad) }
  }
  let deep = String(repeating: "[", count: 129) + String(repeating: "]", count: 129)
  #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(deep) }
  #expect(throws: Never.self) {
    try OrderedJSON.parse(String(repeating: "[", count: 128) + String(repeating: "]", count: 128))
  }
}

@Test func orderedJSONRemovalSwapsTheLastMemberIn() {
  var members = OrderedJSON.Members([("a", .int(-1)), ("b", .bool(true)), ("c", .null)])
  members.remove("a")
  #expect(members.keys == ["c", "b"])
  members.insert("b", .bool(false))
  members.insert("d", .null)
  #expect(members.keys == ["c", "b", "d"])
}

// MARK: - Agent update

@Test func agentSelectionsAndVersions() throws {
  #expect(AgentUpdate.Selection(claude: true, codex: false) == .claude)
  #expect(AgentUpdate.Selection(claude: false, codex: true) == .codex)
  #expect(AgentUpdate.Selection(claude: false, codex: false) == .both)
  #expect(AgentUpdate.Selection(claude: true, codex: true) == .both)
  #expect(AgentUpdate.Selection.both.agents == [.claude, .codex])
  #expect(AgentUpdate.Selection.both.phrase == "Claude Code and Codex")

  let v = { (text: String) in SemanticVersion.first(in: text) }
  #expect(v("1.2.3") == v("v1.2.3"))
  #expect(v("codex-cli 0.5.0") == v("0.5.0"))
  #expect(v("claude 1.2.3 (Claude Code)") == v("1.2.3"))
  #expect(v("rust-v0.42.0") == v("0.42.0"))
  #expect(v("1.0.0-rc.1")?.description == "1.0.0-rc.1")
  #expect(v("1.0.0")! > v("1.0.0-rc.1")!)
  #expect(v("0.10.0")! > v("0.9.0")!)
  #expect(v("1.0.0")! > v("0.42.0")!)
  for garbage in ["no version here", "", "v1", "01.2.3", "1.2"] { #expect(v(garbage) == nil) }
}

@Test func agentCheckReportLines() {
  let old = SemanticVersion("0.4.1")
  let new = SemanticVersion("0.5.0")
  #expect(AgentUpdate.checkStatus(.claude, installed: nil, latest: nil) == .autoUpdates)
  #expect(AgentUpdate.checkStatus(.codex, installed: old, latest: new) == .updateAvailable)
  #expect(AgentUpdate.checkStatus(.codex, installed: new, latest: new) == .upToDate)
  #expect(AgentUpdate.checkStatus(.codex, installed: new, latest: old) == .upToDate)
  #expect(AgentUpdate.checkStatus(.codex, installed: nil, latest: new) == .unknown)
  let available = AgentUpdate.checkLine(
    .init(agent: .codex, installed: old, latest: new, status: .updateAvailable))
  #expect(
    available == "Codex        0.4.1 → 0.5.0    update available — run: coop agent update --codex")
  let claude = AgentUpdate.checkLine(
    .init(agent: .claude, installed: SemanticVersion("1.2.3"), latest: nil, status: .autoUpdates))
  #expect(claude == "Claude Code  1.2.3            up to date (auto-updates in background)")
  let unknown = AgentUpdate.checkLine(
    .init(agent: .codex, installed: nil, latest: nil, status: .unknown))
  #expect(unknown.contains("?") && unknown.contains("could not determine"))
  #expect(
    AgentUpdate.outcomeLine(.codex, .updated(from: old, to: new!))
      == "Codex: updated 0.4.1 → 0.5.0")
  #expect(
    AgentUpdate.outcomeLine(.codex, .updated(from: nil, to: new!)) == "Codex: updated to 0.5.0")
  #expect(
    AgentUpdate.outcomeLine(.claude, .alreadyCurrent(new!))
      == "Claude Code: already at the latest version (0.5.0)")
}

@Test func agentUpdateReinstallsCodexFromStdinAndRunsClaudeUpdate() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let session = SSHSession(target: guest.target)
  var lines: [String] = []
  try AgentUpdate.run(guest.client, session, .both) { lines.append($0) }
  #expect(lines[0] == "Claude Code: already at the latest version (2.1.0)")
  #expect(lines[1] == "  note: Claude Code also auto-updates in the background.")
  #expect(lines[2] == "Codex: already at the latest version (0.50.0)")
  let commands = guest.log("commands.log")
  #expect(commands.contains("'/home/ubuntu/.local/bin/claude' update"))
  #expect(commands.contains("sudo env GUEST_USER='ubuntu' COOP_FORCE_INSTALL=1 bash -s"))
  #expect(readFile(guest.root + "/sudo-stdin") == EmbeddedResources.guestScript("codex.sh"))

  let check = AgentUpdate.check(
    guest.client, session, .codex, latestCodexTag: { "rust-v0.51.0" },
    diagnostics: guest.sink.diagnostics)
  #expect(
    check == ["Codex        0.50.0 → 0.51.0  update available — run: coop agent update --codex"])
  let offline = AgentUpdate.check(
    guest.client, session, .codex, latestCodexTag: { throw HostError("offline") },
    diagnostics: guest.sink.diagnostics)
  #expect(offline[0].contains("could not determine latest version"))
}
