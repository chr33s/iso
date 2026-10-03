import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets
import Testing

@testable import IsoHost

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
  // The complete persisted record stays owner-only.
  #expect(
    try canonicalJSON(readFile(instance.modelStatePath))
      == canonicalJSON(
        """
        {
          "mode": "local",
          "claude_endpoint": {
            "host_url": "http://localhost:11434/",
            "model": "qwen",
            "auth_token": null
          }
        }
        """))
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
  #expect(local["model_provider"] == .string("iso_local"))
  let provider = local["model_providers"]?.tableValue?["iso_local"]?.tableValue
  #expect(provider?["base_url"] == .string("http://127.0.0.1:11434/v1/"))
  #expect(provider?["wire_api"] == .string("responses"))
  #expect(provider?["env_key"] == .string("ISO_LOCAL_API_KEY"))
  for base in ["http://127.0.0.1:9788", "http://127.0.0.1:9788/"] {
    let proxy = ModelRouting.codexProxyConfig(baseURL: base)
    #expect(proxy["model"] == nil)
    let entry = proxy["model_providers"]?.tableValue?["iso_local"]?.tableValue
    #expect(entry?["base_url"] == .string("http://127.0.0.1:9788/v1"))
    #expect(entry?["name"] == .string("iso credential proxy"))
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
  let state = GuestEnvState(literals: [
    try EnvVarName("FOO"): "1", try EnvVarName("BAR"): "2", try EnvVarName("_E"): "",
  ])
  try state.save(instance)
  #expect(try GuestEnvState.tryLoad(instance) == state)
  #expect(
    try canonicalJSON(readFile(instance.guestEnvironmentStatePath))
      == canonicalJSON(
        #"{"version":2,"entries":{"BAR":{"kind":"literal","value":"2"},"FOO":{"kind":"literal","value":"1"},"_E":{"kind":"literal","value":""}}}"#
      ))
  try GuestEnvState().save(instance)
  #expect(!FileManager.default.fileExists(atPath: instance.guestEnvironmentStatePath))

  try FileManager.default.createDirectory(
    atPath: instance.guestEnvironmentStatePath, withIntermediateDirectories: true)
  #expect(throws: (any Error).self) { try GuestEnvState.tryLoad(instance) }
  try FileManager.default.removeItem(atPath: instance.guestEnvironmentStatePath)
  try writeFile(
    instance.guestEnvironmentStatePath,
    #"{"version":2,"entries":{"1FOO":{"kind":"literal","value":"v"}}}"#)
  #expect(throws: (any Error).self) { try GuestEnvState.tryLoad(instance) }
}

@Test func guestEnvMergeAndCLIArguments() throws {
  let k = try EnvVarName("K")
  let d = try EnvVarName("D")
  let f = try EnvVarName("F")
  #expect(
    GuestEnvState.merge(
      devcontainer: [k: .literal("dc"), d: .literal("1"), f: .literal("dc")],
      envFile: [k: .literal("file"), f: .literal("file")], cli: [k: .literal("cli")])
      == [k: .literal("cli"), d: .literal("1"), f: .literal("file")])
  #expect(try GuestEnvState.parseCLIArgument("FOO=1") == (try EnvVarName("FOO"), .literal("1")))
  #expect(try GuestEnvState.parseCLIArgument("EMPTY=").1 == .literal(""))
  #expect(
    try GuestEnvState.parseCLIArgument("URL=https://x?a=b&c=d").1 == .literal("https://x?a=b&c=d"))
  #expect(
    try GuestEnvState.parseCLIArgument("DB={vault:db-pass}").1 == .secret(try SecretName("db-pass"))
  )
  #expect(throws: (any Error).self) { try GuestEnvState.parseCLIArgument("DB=x{vault:db}") }
  let missing = try #require(throws: (any Error).self) {
    try GuestEnvState.parseCLIArgument("BAD")
  }
  #expect("\(missing)".contains("missing '='"))
  #expect(throws: (any Error).self) { try GuestEnvState.parseCLIArgument("1X=v") }
}

@Test func guestEnvStateRequiresCurrentVersionAndTypedEntries() throws {
  let root = try scratchDirectory("genv2")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let instance = try testInstance(root)
  let state = GuestEnvState(entries: [
    try EnvVarName("DB"): .secret(try SecretName("db")), try EnvVarName("MODE"): .literal("dev"),
  ])
  try state.save(instance)
  let text = try #require(readFile(instance.guestEnvironmentStatePath))
  #expect(
    try canonicalJSON(text)
      == canonicalJSON(
        #"{"version":2,"entries":{"DB":{"kind":"secret","name":"db"},"MODE":{"kind":"literal","value":"dev"}}}"#
      ))
  #expect(try GuestEnvState.tryLoad(instance) == state)
  for invalid in [
    #"{"entries":{"A":{"kind":"literal","value":"x"}}}"#,
    #"{"version":1,"entries":{}}"#,
    #"{"version":3,"entries":{}}"#,
    #"{"version":"2","entries":{}}"#,
    #"{"version":2,"entries":{"A":"x"}}"#,
    #"{"version":2,"entries":{"A":{"kind":"unknown","value":"x"}}}"#,
  ] {
    try writeFile(instance.guestEnvironmentStatePath, invalid)
    #expect(throws: (any Error).self) { try GuestEnvState.tryLoad(instance) }
  }
}

@Test func providerVariableReferencesAreRoutedToTheProxy() throws {
  let routed = try GuestEnvState.providerSecrets([
    try EnvVarName("CLAUDE_CODE_OAUTH_TOKEN"): .secret(try SecretName("setup")),
    try EnvVarName("OPENAI_API_KEY"): .secret(try SecretName("openai")),
    try EnvVarName("ANTHROPIC_API_KEY"): .literal("legacy"),
    try EnvVarName("DB"): .secret(try SecretName("db")),
  ])
  #expect(routed.count == 2)
  #expect(routed[.anthropic]?.auth == .bearer && routed[.anthropic]?.name.rawValue == "setup")
  #expect(routed[.openai]?.auth == .bearer)
  // Two stored credentials for one provider are ambiguous.
  #expect(throws: HostError.self) {
    try GuestEnvState.providerSecrets([
      try EnvVarName("ANTHROPIC_API_KEY"): .secret(try SecretName("a")),
      try EnvVarName("ANTHROPIC_AUTH_TOKEN"): .secret(try SecretName("b")),
    ])
  }
}

@Test func providerSecretsPersistAsTypedDeclarations() throws {
  let root = try scratchDirectory("genv3")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let instance = try testInstance(root)
  let state = GuestEnvState(entries: [
    try EnvVarName("ANTHROPIC_API_KEY"): .secret(try SecretName("anthropic"))
  ])
  try state.save(instance)
  let text = try #require(readFile(instance.guestEnvironmentStatePath))
  #expect(
    try canonicalJSON(text)
      == canonicalJSON(
        #"{"version":2,"entries":{"ANTHROPIC_API_KEY":{"kind":"provider_secret","provider":"anthropic","injection":"x_api_key","name":"anthropic"}}}"#
      ))
  #expect(try GuestEnvState.tryLoad(instance) == state)
  try writeFile(
    instance.guestEnvironmentStatePath,
    #"{"version": 2, "entries": {"OPENAI_API_KEY": {"kind": "provider_secret", "provider": "anthropic", "injection": "bearer", "name": "x"}}}"#
  )
  #expect(throws: (any Error).self) { try GuestEnvState.tryLoad(instance) }
}

@Test func envFilesAreReadStrictlyFromRegularFiles() throws {
  let root = try scratchDirectory("envfile")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let path = root + "/.env"
  try writeFile(path, "# c\nexport A=1\nB=\"x y\" # note\nC={vault:c}\nA=2\n")
  let entries = try GuestEnvState.readEnvFile(path)
  #expect(entries[try EnvVarName("A")] == .literal("2"))
  #expect(entries[try EnvVarName("B")] == .literal("x y"))
  #expect(entries[try EnvVarName("C")] == .secret(try SecretName("c")))
  #expect(throws: (any Error).self) { try GuestEnvState.readEnvFile(root) }
  try writeFile(path, "A=$(touch /tmp/x)\nB\n")
  let error = try #require(throws: (any Error).self) { try GuestEnvState.readEnvFile(path) }
  #expect("\(error)".contains("line 2"))
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

@Test func orderedJSONPreservesDocumentOrderAndBounds() throws {
  let value = try OrderedJSON.parse(
    #"{"zeta":1,"a":1e16,"b":1.5e-7,"c":-0,"d":18446744073709551616,"f":0.1,"g":1.0,"i":"\u00e9\u2028/","j":1E2,"k":-5,"z":{"y":[]}}"#
  )
  for text in [value.compact, value.pretty] {
    let decoded = try OrderedJSON.parse(text)
    #expect(decoded.objectMembers?.keys == value.objectMembers?.keys)
    #expect(decoded["i"]?.stringValue == "é\u{2028}/")
    let numbers = try #require(
      JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect((numbers["a"] as? NSNumber)?.doubleValue == 1e16)
    #expect((numbers["b"] as? NSNumber)?.doubleValue == 1.5e-7)
    #expect((numbers["g"] as? NSNumber)?.doubleValue == 1)
    #expect((numbers["k"] as? NSNumber)?.intValue == -5)
  }
  for bad in ["", "[1,]", "{\"a\":1,}", "01", "\"\\ud800\"", "nul", "[1] x", "{'a':1}"] {
    #expect(throws: OrderedJSON.ParseError.self, "\(bad)") { try OrderedJSON.parse(bad) }
  }
  for (opening, closing) in [("[", "]"), ("{\"x\":", "}")] {
    let deep = String(repeating: opening, count: 129) + "0" + String(repeating: closing, count: 129)
    #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(deep) }
    #expect(throws: Never.self) {
      try OrderedJSON.parse(
        String(repeating: opening, count: 128) + "0" + String(repeating: closing, count: 128))
    }
  }
}

@Test(arguments: [1, 8192])
func orderedJSONBorrowsBridgedUTF8AndReturnsOwnedStrings(repetitions: Int) throws {
  let payload = String(repeating: "é🐓中", count: repetitions)
  let parsed = try autoreleasepool {
    let document: NSString =
      "{\"text\":\"\(payload)\",\"escaped\":\"\\uD83D\\uDC13\",\"values\":[true,false,null,-1,0.25]}"
      as NSString
    return try OrderedJSON.parse(document as String)
  }
  #expect(parsed["text"]?.stringValue == payload)
  #expect(parsed["escaped"]?.stringValue == "🐓")
  #expect(parsed["values"] == .array([.bool(true), .bool(false), .null, .int(-1), .double(0.25)]))
}

@Test func orderedJSONRemovalPreservesRemainingOrder() {
  var members = OrderedJSON.Members([("a", .int(-1)), ("b", .bool(true)), ("c", .null)])
  members.remove("a")
  #expect(members.keys == ["b", "c"])
  members.insert("b", .bool(false))
  members.insert("d", .null)
  #expect(members.keys == ["b", "c", "d"])
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
    available == "Codex        0.4.1 → 0.5.0    update available — run: iso agent update --codex")
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
  #expect(commands.contains("sudo env GUEST_USER='ubuntu' ISO_FORCE_INSTALL=1 bash -s"))
  #expect(readFile(guest.root + "/sudo-stdin") == EmbeddedResources.guestScript("codex.sh"))

  let check = try AgentUpdate.check(
    guest.client, session, .codex, latestCodexTag: { "rust-v0.51.0" },
    diagnostics: guest.sink.diagnostics)
  #expect(
    check == ["Codex        0.50.0 → 0.51.0  update available — run: iso agent update --codex"])
  let offline = try AgentUpdate.check(
    guest.client, session, .codex, latestCodexTag: { throw HostError("offline") },
    diagnostics: guest.sink.diagnostics)
  #expect(offline[0].contains("could not determine latest version"))
}

@Test func aStoredSecretIsEitherAProxyCredentialOrGuestVisible() throws {
  let db = try SecretName("db")
  let anthropic = try SecretName("anthropic")
  // Distinct names: fine.
  try GuestEnvState.checkCredentialSeparation(
    [
      try EnvVarName("ANTHROPIC_API_KEY"): .secret(anthropic), try EnvVarName("DB"): .secret(db),
    ], proxyCredentialNames: [])
  // A generic reference to a configured proxy credential is refused.
  let configured = try #require(throws: HostError.self) {
    try GuestEnvState.checkCredentialSeparation(
      [try EnvVarName("FOO"): .secret(anthropic)], proxyCredentialNames: [anthropic])
  }
  #expect(configured.message.contains("FOO={vault:anthropic}"))
  // ...and so is one naming a routed provider secret's store entry.
  #expect(throws: HostError.self) {
    try GuestEnvState.checkCredentialSeparation(
      [
        try EnvVarName("ANTHROPIC_API_KEY"): .secret(anthropic),
        try EnvVarName("FOO"): .secret(anthropic),
      ], proxyCredentialNames: [])
  }
}
