import CoopCore
import Foundation
import Testing

@testable import CoopConfiguration

private func load(_ text: String, environment: ConfigEnvironment = fixtureHome) throws(ConfigError)
  -> CoopConfig
{
  try ConfigLoader.load(bytes: text, environment: environment)
}

private func fieldError(_ text: String) -> (field: String, reason: String)? {
  do {
    _ = try load(text)
    return nil
  } catch {
    if case .invalidField(_, let field, let reason) = error { return (field, reason) }
    Issue.record("unexpected error \(error)")
    return nil
  }
}

// MARK: - Selection (section 3.4)

private func select(_ explicit: String?, existing: Set<String>) throws(ConfigError)
  -> ConfigSelection
{
  try ConfigLoader.select(explicitPath: explicit, home: "/h", fileExists: { existing.contains($0) })
}

@Test func explicitPathsSelectFormatByExtension() throws {
  #expect(try select("/x/c.jsonc", existing: []) == .file(path: "/x/c.jsonc", format: .jsonc))
  #expect(try select("/x/c.json", existing: []) == .file(path: "/x/c.json", format: .json))
  #expect(throws: ConfigError.migrationRequired(tomlPath: "/x/c.toml", jsoncPath: "/x/c.jsonc")) {
    try select("/x/c.toml", existing: ["/x/c.toml"])
  }
  #expect(throws: ConfigError.unsupportedExtension(path: "/x/config")) {
    try select("/x/config", existing: [])
  }
  #expect(throws: ConfigError.unsupportedExtension(path: "/x/c.yaml")) {
    try select("/x/c.yaml", existing: [])
  }
}

@Test func defaultSelectionNeverFallsBackAcrossFormats() throws {
  #expect(
    try select(nil, existing: ["/h/.coop/config.jsonc", "/h/.coop/config.toml"])
      == .file(path: "/h/.coop/config.jsonc", format: .jsonc))
  #expect(
    throws: ConfigError.migrationRequired(
      tomlPath: "/h/.coop/config.toml", jsoncPath: "/h/.coop/config.jsonc")
  ) {
    try select(nil, existing: ["/h/.coop/config.toml"])
  }
  // No automatic config.json search.
  #expect(
    try select(nil, existing: ["/h/.coop/config.json"])
      == .defaultsOnly(defaultPath: "/h/.coop/config.jsonc"))
  #expect(try select(nil, existing: []) == .defaultsOnly(defaultPath: "/h/.coop/config.jsonc"))
}

@Test func malformedOrUnreadableFilesNeverBecomeDefaults() throws {
  let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let bad = directory.appending(path: "config.jsonc")
  try Data("{ \"ssh_port\": ".utf8).write(to: bad)
  #expect(throws: ConfigError.self) {
    try ConfigLoader.load(.file(path: bad.path, format: .jsonc), environment: fixtureHome)
  }
  let unreadable = directory.appending(path: "locked.jsonc")
  try Data("{}".utf8).write(to: unreadable)
  chmod(unreadable.path, 0)
  defer { chmod(unreadable.path, 0o600) }
  if getuid() != 0 {
    #expect(throws: ConfigError.self) {
      try ConfigLoader.load(.file(path: unreadable.path, format: .jsonc), environment: fixtureHome)
    }
  }
  let dir = directory.appending(path: "dir.jsonc")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  #expect(throws: ConfigError.unreadable(path: dir.path, reason: "not a regular file")) {
    try ConfigLoader.load(.file(path: dir.path, format: .jsonc), environment: fixtureHome)
  }
  // A missing explicit file keeps the baseline "use defaults" behavior.
  let missing = try ConfigLoader.load(
    .file(path: directory.appending(path: "none.jsonc").path, format: .jsonc),
    environment: fixtureHome)
  #expect(missing.sshPort == 22)
}

@Test func strictJSONRejectsComments() {
  #expect(throws: ConfigError.self) {
    try ConfigLoader.load(bytes: "{} // c", format: .json)
  }
  #expect(throws: Never.self) { try ConfigLoader.load(bytes: "{} // c", format: .jsonc) }
}

@Test func oldInstallationDirectoryHasNoSpecialDataDirectory() throws {
  let env = ConfigEnvironment(home: "/h", variables: [:])
  let config = try ConfigLoader.load(
    .file(path: "/h/.coop-apple/config.jsonc", format: .jsonc), environment: env)
  #expect(config.dataDirectory.path == "/h/.coop")
}

// MARK: - Absent / null / false / wrong type

@Test func defaultsMatchTheBaseline() throws {
  let c = try load("{}")
  #expect(c.dataDirectory.path == "/home/fixture/.coop")
  #expect(c.stateRoot.path == "/home/fixture/.coop/backends/apple-container-v1")
  #expect(c.sshPort == 22)
  #expect(c.vm == .defaults)
  #expect(c.github == nil)
  #expect(c.setup.promptForPAT)
  #expect(c.updates == UpdateConfig(mode: .notify, checkIntervalHours: 24))
  #expect(c.appleContainer == .defaults)
  #expect(c.codexAuth == .apiKey)
}

@Test func nullIsAbsentOnlyForOptionalFields() throws {
  #expect(try load(#"{"github": null, "post_start": null}"#).github == nil)
  #expect(try load(#"{"claude": {"config_dir": null}}"#).claude.configDirectory == .default)
  #expect(try load(#"{"claude": {"local_model": null, "api_key": null}}"#).claude.apiKey == nil)
  for field in [
    "ssh_port", "vm", "data_dir", "setup", "guest_env", "profiles", "forward_ports", "updates",
  ] {
    #expect(fieldError("{\"\(field)\": null}")?.field == field, "\(field)")
  }
  #expect(fieldError(#"{"codex": {"auth": null}}"#)?.field == "codex.auth")
  #expect(
    fieldError(#"{"forward_ports": [{"guest": 1, "label": null}]}"#)?.field
      == "forward_ports[0].label")
}

@Test func configDirectoryDistinguishesFalseTrueAndPaths() throws {
  #expect(try load(#"{"claude": {"config_dir": false}}"#).claude.configDirectory == .disabled)
  #expect(
    try load(#"{"codex": {"config_dir": "~/x"}}"#).codex.configDirectory
      == .custom(HostPath(absolute: "/home/fixture/x")))
  #expect(fieldError(#"{"claude": {"config_dir": true}}"#)?.field == "claude.config_dir")
  #expect(fieldError(#"{"claude": {"config_dir": 0}}"#)?.field == "claude.config_dir")
}

@Test func integersAreExactAndBounded() throws {
  #expect(
    try load(#"{"updates": {"check_interval_hours": 9223372036854775808}}"#).updates
      .checkIntervalHours == 1 << 63)
  #expect(
    try load(#"{"updates": {"check_interval_hours": 18446744073709551615}}"#).updates
      .checkIntervalHours == .max)
  #expect(fieldError(#"{"updates": {"check_interval_hours": 18446744073709551616}}"#) != nil)
  #expect(fieldError(#"{"ssh_port": 65536}"#)?.field == "ssh_port")
  #expect(fieldError(#"{"ssh_port": -1}"#)?.field == "ssh_port")
  #expect(fieldError(#"{"vm": {"vcpu_count": 256}}"#)?.field == "vm.vcpu_count")
  #expect(fieldError(#"{"vm": {"vcpu_count": 0}}"#)?.reason == "must be > 0")
  #expect(
    fieldError(#"{"vm": {"mem_size_mib": 127}}"#)?.reason
      == "mem_size_mib=127 is too low (minimum 128)")
  #expect(try load(#"{"vm": {"mem_size_mib": 128}}"#).vm.memory.mib.value == 128)
  #expect(fieldError(#"{"apple_container": {"boot_timeout_seconds": 86401}}"#) != nil)
  #expect(fieldError(#"{"apple_container": {"boot_timeout_seconds": 0}}"#) != nil)
}

@Test func fractionalLiteralsDoNotSatisfyIntegerFields() {
  // Foundation decodes 2.0 and 2e0 as Int64; the baseline rejected both.
  #expect(
    fieldError(#"{"vm": {"vcpu_count": 2.0}}"#)?.reason
      == "expected an integer, found a fractional number")
  #expect(fieldError(#"{"ssh_port": 22e0}"#) != nil)
  #expect(fieldError(#"{"forward_ports": [3000.0]}"#) != nil)
}

@Test func wrongTypesAreReportedByPath() {
  #expect(fieldError(#"{"vm": []}"#)?.field == "vm")
  #expect(fieldError(#"{"ssh_port": "22"}"#)?.reason == "expected an integer, found string")
  #expect(fieldError(#"{"setup": {"prompt_for_pat": "yes"}}"#)?.field == "setup.prompt_for_pat")
  #expect(fieldError(#"{"claude": {"plugins": "x"}}"#)?.field == "claude.plugins")
  #expect(fieldError(#"{"claude": {"env_forward": ["1BAD"]}}"#)?.field == "claude.env_forward[0]")
  #expect(fieldError(#"{"guest_env": {"BAD-NAME": "x"}}"#)?.field == "guest_env.BAD-NAME")
  #expect(
    fieldError(#"{"updates": {"mode": "loud"}}"#)?.reason
      == "unknown variant 'loud', expected one of 'off', 'notify'")
  #expect(throws: ConfigError.rootNotObject(path: "config.jsonc")) { try load("[]") }
}

// MARK: - Sections

@Test func githubModesAndImpliedPat() throws {
  #expect(try load(#"{"github": "auto"}"#).github == .auto)
  #expect(try load(#"{"github": {}}"#).github == .off)
  #expect(try load(#"{"github": {"mode": null}}"#).github == .off)
  #expect(try load(#"{"github": {"skip": []}}"#).github == .pat(PATConfig(entries: [:], skip: [])))
  #expect(try load(#"{"github": {"pat": {}}}"#).github == .off)
  #expect(try load(#"{"github": {"mode": "env", "pat": {"o/r": {"token": "t"}}}}"#).github == .env)
  #expect(fieldError(#"{"github": "sometimes"}"#)?.field == "github")
  #expect(
    fieldError(#"{"github": {"pat": {"no-slash": {"token": "t"}}}}"#)?.field
      == "github.pat.no-slash")
  #expect(fieldError(#"{"github": {"pat": {"o/r": {}}}}"#)?.field == #"github.pat["o/r"].token"#)
  #expect(fieldError(#"{"github": 1}"#)?.field == "github")
}

@Test func mcpServerVariantsAreExclusive() throws {
  let c = try load(
    #"{"claude": {"mcp_servers": {"a.b": {"command": "x"}, "h": {"type": "http", "url": "https://h.example/"}}}}"#
  )
  #expect(c.claude.mcpServers["a.b"] == .stdio(command: "x", args: [], env: [:]))
  #expect(c.claude.mcpServers["a"] == nil)
  for bad in [
    #"{"type": "stdio", "url": "https://x"}"#, #"{"command": "x", "headers": {"A": "b"}}"#,
    #"{"type": "http", "command": "x", "url": "https://x"}"#,
    #"{"type": "sse", "args": ["a"], "url": "https://x"}"#,
    #"{"type": "http"}"#, #"{}"#, #"{"type": "ws", "url": "https://x"}"#,
    #"{"type": "http", "url": "not a url"}"#,
  ] {
    #expect(fieldError("{\"codex\": {\"mcp_servers\": {\"s\": \(bad)}}}") != nil, "\(bad)")
  }
}

@Test func localModelInvariants() throws {
  let c = try load(
    #"{"codex": {"local_model": {"host_url": "https://lan.example:8443/v1/", "model": "m"}}}"#)
  #expect(c.codex.localModel?.model == "m")
  #expect(c.codex.localModel?.authToken == nil)
  #expect(fieldError(#"{"claude": {"local_model": {"host_url": "ftp://x", "model": "m"}}}"#) != nil)
  #expect(
    fieldError(#"{"claude": {"local_model": {"host_url": "http://x", "model": "  "}}}"#) != nil)
  #expect(
    fieldError(#"{"claude": {"local_model": {"model": "m"}}}"#)?.field
      == "claude.local_model.host_url")
}

@Test func forwardPortForms() throws {
  let c = try load(
    #"{"forward_ports": [1, "2:3", {"guest": 4, "host": 5, "label": "x", "extra": true}, {"guest": 6}]}"#
  )
  #expect(c.forwardPorts.map(\.guest) == [1, 2, 4, 6])
  #expect(c.forwardPorts.map(\.host) == [1, 3, 5, 6])
  #expect(c.forwardPorts[2].label == "x")
  for bad in [#"[0]"#, #"["0"]"#, #"["1:0"]"#, #"[{"host": 1}]"#, #"[true]"#, #"[70000]"#] {
    #expect(fieldError("{\"forward_ports\": \(bad)}") != nil, "\(bad)")
  }
}

@Test func unknownKeysFollowPerSectionPolicy() throws {
  // Ignored everywhere except apple_container, as in the baseline.
  #expect(throws: Never.self) {
    try load(
      #"{"future": 1, "vm": {"x": 1}, "claude": {"x": 1}, "proxy": {"x": 1}, "updates": {"x": 1}}"#)
  }
  #expect(fieldError(#"{"apple_container": {"binray": "/x"}}"#)?.field == "apple_container.binray")
  #expect(fieldError(#"{"apple_container": {"binray": "/x"}}"#)?.reason == "unknown field")
}

@Test func retiredFirecrackerFieldsAreRejectedByName() {
  for (text, fields) in [
    (#"{"firecracker_bin": "/x"}"#, ["firecracker_bin"]),
    (#"{"network": {}}"#, ["network"]),
    (#"{"network": null}"#, ["network"]),
    (#"{"vm": {"kernel_path": "/k"}}"#, ["vm.kernel_path"]),
    (#"{"vm": {"boot_args": ""}}"#, ["vm.boot_args"]),
  ] {
    #expect(throws: ConfigError.retiredFields(path: "config.jsonc", fields: fields)) {
      try load(text)
    }
  }
}

// MARK: - Credentials (C-04) and redaction

@Test func proxyCredentialsMustBeCommandReferences() throws {
  let c = try load(
    #"{"proxy": {"anthropic": {"credential": "cmd:security find x", "auth": "bearer"}}}"#)
  #expect(c.proxy.anthropic?.auth == .bearer)
  #expect(c.proxy.openai == nil)
  #expect(c.proxy.anthropic?.credential.description == "cmd:<redacted>")
  for provider in ["anthropic", "openai"] {
    let text = "{\"proxy\": {\"\(provider)\": {\"credential\": \"sk-SYNTHETIC-LITERAL\"}}}"
    do {
      _ = try load(text)
      Issue.record("literal accepted")
    } catch {
      #expect(!error.description.contains("sk-SYNTHETIC-LITERAL"))
      #expect(error.description.contains("proxy.\(provider).credential"))
      #expect(error.description.contains("coop proxy setup"))
    }
  }
  #expect(fieldError(#"{"proxy": {"openai": {}}}"#)?.field == "proxy.openai.credential")
  #expect(
    fieldError(#"{"proxy": {"openai": {"credential": 5}}}"#)?.field == "proxy.openai.credential")
}

@Test func errorsNeverContainSecretBearingValues() {
  let secret = "SYNTHETIC-SECRET-VALUE"
  let documents = [
    "{\"proxy\": {\"anthropic\": {\"credential\": \"\(secret)\"}}}",
    "{\"claude\": {\"api_key\": [\"\(secret)\"]}}",
    "{\"github\": {\"pat\": {\"o/r\": {\"token\": {\"v\": \"\(secret)\"}}}}}",
    "{\"claude\": {\"mcp_servers\": {\"s\": {\"command\": \"x\", \"headers\": {\"A\": \"\(secret)\"}}}}}",
    "{\"claude\": {\"local_model\": {\"host_url\": \"ftp://h\", \"model\": \"m\", \"auth_token\": \"\(secret)\"}}}",
    "{\"claude\": {\"api_key\": \"\(secret)\"} \"x\": 1}",
    "{\"a\": \"\(secret)\", \"a\": 1}",
    "{\"claude\": {\"api_key\": \"\(secret)\"}, }",
  ]
  for text in documents {
    do {
      _ = try load(text)
      Issue.record("accepted: \(text.count) bytes")
    } catch {
      #expect(!error.description.contains(secret))
    }
  }
}

@Test func secretsAreRedactedInDescriptions() throws {
  let c = try load(
    #"{"claude": {"api_key": "SYNTHETIC-KEY"}, "github": {"pat": {"o/r": {"token": "SYNTHETIC-PAT"}}}}"#
  )
  let rendered =
    String(describing: c) + String(reflecting: c) + "\(c.claude)"
    + "\(String(describing: c.github))"
  #expect(!rendered.contains("SYNTHETIC-KEY"))
  #expect(!rendered.contains("SYNTHETIC-PAT"))
  #expect(c.claude.apiKey?.expose() == "SYNTHETIC-KEY")
}

@Test func apiKeyEnvironmentFallbackOnlyForAbsentSections() throws {
  let env = ConfigEnvironment(
    home: "/h", variables: ["ANTHROPIC_API_KEY": "env-a", "OPENAI_API_KEY": "env-o"])
  let absent = try load("{}", environment: env)
  #expect(absent.claude.apiKey?.expose() == "env-a")
  #expect(absent.codex.apiKey?.expose() == "env-o")
  let present = try load(#"{"claude": {}, "codex": {"api_key": "cfg"}}"#, environment: env)
  #expect(present.claude.apiKey == nil)
  #expect(present.codex.apiKey?.expose() == "cfg")
}

@Test func loadingNeverExecutesCredentialCommands() throws {
  let marker = FileManager.default.temporaryDirectory.appending(
    path: "coop-exec-\(UUID().uuidString)")
  let command = "cmd:touch \(marker.path)"
  _ = try load(
    """
    {"claude": {"api_key": "\(command)"}, "proxy": {"openai": {"credential": "\(command)"}},
     "github": {"pat": {"o/r": {"token": "\(command)"}}}}
    """)
  #expect(!FileManager.default.fileExists(atPath: marker.path))
}

// MARK: - Template and validation

@Test func templateMatchesRepositoryExampleAndLoads() throws {
  let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../config.example.jsonc").standardized
  #expect(try String(contentsOf: example, encoding: .utf8) == ConfigTemplate.jsonc)
  let config = try load(ConfigTemplate.jsonc)
  #expect(config.sshPort == 22)
}

struct FakeFileSystem: ConfigFileSystem {
  var files: Set<String> = []
  var directories: Set<String> = []
  func exists(_ path: String) -> Bool { files.contains(path) || directories.contains(path) }
  func isDirectory(_ path: String) -> Bool { directories.contains(path) }
}

@Test func environmentalValidation() throws {
  let c = try load(
    #"{"claude": {"config_dir": "/missing", "marketplaces": ["/nope", "owner/repo", "https://x/y"]}, "codex": {"auth": "chatgpt"}, "proxy": {"openai": {"credential": "cmd:x"}}}"#
  )
  let report = c.validate(fileSystem: FakeFileSystem())
  #expect(report.errors.count == 3)
  #expect(report.errors.contains { $0.hasPrefix("claude.config_dir '/missing'") })
  #expect(report.errors.contains { $0.contains("claude.marketplaces entry '/nope'") })
  #expect(report.errors.contains { $0.contains("chatgpt") })
  #expect(
    report.warnings == ["data_dir parent '/home/fixture' does not exist (will be created on setup)"]
  )
  let ok = try load("{}").validate(fileSystem: FakeFileSystem(directories: ["/home/fixture"]))
  #expect(ok == ConfigValidationReport(warnings: [], errors: []))
}

// MARK: - workspace.pull

@Test func workspacePullDefaultsToDirectWithStageBudgets() throws {
  let c = try load("{}")
  #expect(c.workspacePull == .defaults)
  #expect(c.workspacePull.mode == .direct)
  #expect(c.workspacePull.limits.maxBytes.description == "1GiB")
}

@Test func workspacePullParsesModeAndBudgets() throws {
  let c = try load(
    #"{"workspace": {"pull": {"mode": "stage", "max_files": 10, "max_bytes": "200MiB", "max_file_bytes": 4096}}}"#
  )
  #expect(c.workspacePull.mode == .stage)
  #expect(c.workspacePull.limits.maxFiles == 10)
  #expect(c.workspacePull.limits.maxBytes.bytes == 200 << 20)
  #expect(c.workspacePull.limits.maxFileBytes.bytes == 4096)
}

@Test func workspacePullRejectsUnknownKeysAndBadValues() {
  #expect(fieldError(#"{"workspace": {"push": {}}}"#)?.field == "workspace.push")
  #expect(
    fieldError(#"{"workspace": {"pull": {"max_delets": 1}}}"#)?.field == "workspace.pull.max_delets"
  )
  #expect(fieldError(#"{"workspace": {"pull": {"mode": "yolo"}}}"#)?.field == "workspace.pull.mode")
  #expect(fieldError(#"{"workspace": {"pull": {"max_files": 0}}}"#) != nil)
  #expect(
    fieldError(#"{"workspace": {"pull": {"max_bytes": "1TB"}}}"#)?.field
      == "workspace.pull.max_bytes")
  #expect(fieldError(#"{"workspace": {"pull": {"max_bytes": 0}}}"#) != nil)
}

@Test func proxyModeDefaultsToAutoAndRejectsUnknownModes() throws {
  #expect(try load("{}").proxy.mode == .auto)
  #expect(try load(#"{"proxy": {"mode": "required"}}"#).proxy.mode == .required)
  #expect(try load(#"{"proxy": {"mode": "off"}}"#).proxy.mode == .off)
  #expect(fieldError(#"{"proxy": {"mode": "strict"}}"#)?.field == "proxy.mode")
}

@Test func proxyCredentialsAcceptVaultReferences() throws {
  let c = try load(#"{"proxy": {"anthropic": {"credential": "vault:anthropic"}}}"#)
  #expect(c.proxy.anthropic?.credential.command.expose() == "vault:anthropic")
  #expect(c.proxy.anthropic?.credential.description == "vault:anthropic")
  #expect(
    fieldError(#"{"proxy": {"anthropic": {"credential": "vault:../x"}}}"#)?.field
      == "proxy.anthropic.credential")
  #expect(fieldError(#"{"proxy": {"anthropic": {"credential": "sk-literal"}}}"#) != nil)
}

@Test func storedProxyCredentialNamesAreCollected() throws {
  let c = try load(
    #"{"proxy": {"anthropic": {"credential": "vault:anthropic"}, "openai": {"credential": "cmd:printf x"}}}"#
  )
  #expect(c.proxy.storedCredentialNames == [try SecretName("anthropic")])
  #expect(ProxyProvider.route(forVariable: "CLAUDE_CODE_OAUTH_TOKEN")! == (.anthropic, .bearer))
  #expect(ProxyProvider.route(forVariable: "PATH") == nil)
  #expect(
    ProxyAuthScheme.apiKey.wireName == "x_api_key" && ProxyAuthScheme.bearer.wireName == "bearer")
}
