import Foundation
import IsoCore
import Testing

@testable import IsoConfiguration

/// H-01 differential evidence. Each `Fixtures/parity/<name>.toml` was loaded
/// by the baseline Rust loader (`tests/baseline/config-normalize`, synthetic
/// HOME, no provider variables) into `<name>.baseline.json`, and converted by
/// `scripts/migrate-config-to-jsonc.py` into `<name>.jsonc`. The Swift loader
/// must produce the same domain values from the JSONC file, except for the C-01
/// retired fields and the differences enumerated in `expectedDifferences`.
let fixtureHome = ConfigEnvironment(home: "/home/fixture", variables: [:])

func fixtureURL(_ name: String) -> URL {
  Bundle.module.url(forResource: "Fixtures/parity/\(name)", withExtension: nil)!
}

func parityFixtureNames() -> [String] {
  let directory = Bundle.module.url(forResource: "Fixtures/parity", withExtension: nil)!
  let names = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
  return names.filter { $0.hasSuffix(".toml") }.map { String($0.dropLast(5)) }.sorted()
}

/// Known, recorded baseline differences: (fixture, JSON path, Swift value).
/// Rust's `url` crate serializes WHATWG-normalized URLs (an empty path
/// becomes `/`); Foundation keeps the configured spelling. Tracked as an open
/// H-01 item for local-model routing and MCP registration.
let expectedDifferences: [String: [([String], JSONValue)]] = [
  "url-normalization": [
    (["claude", "local_model", "host_url"], .string("http://localhost:11434")),
    (["claude", "mcp_servers", "remote", "url"], .string("https://mcp.example.com")),
  ]
]

@Test(arguments: parityFixtureNames())
func swiftLoaderMatchesBaseline(_ name: String) throws {
  let config = try ConfigLoader.load(
    .file(path: fixtureURL("\(name).jsonc").path, format: .jsonc), environment: fixtureHome)
  let baselineBytes = try Data(contentsOf: fixtureURL("\(name).baseline.json"))
  var expected = try JSONDecoder().decode(JSONValue.self, from: baselineBytes)
  expected = removingRetired(expected)
  for (path, value) in expectedDifferences[name] ?? [] {
    expected = expected.replacing(path, with: value)
  }
  let actual = normalized(config)
  #expect(actual.semanticallyEquals(expected), "\(name): \(diff(actual, expected))")
}

@Test func baselineAcceptsRetiredFieldsButSwiftRejectsThem() throws {
  let toml = try String(contentsOf: fixtureURL("retired.toml"), encoding: .utf8)
  let converted = """
    { "firecracker_bin": "/x", "vm": { "kernel_path": "/k", "boot_args": "b", "vcpu_count": 4 },
      "network": { "host_ip": "172.16.0.1" } }
    """
  #expect(toml.contains("firecracker_bin"))
  #expect(
    throws: ConfigError.retiredFields(
      path: "retired", fields: ["firecracker_bin", "network", "vm.kernel_path", "vm.boot_args"])
  ) {
    try ConfigLoader.load(bytes: converted, path: "retired")
  }
}

func removingRetired(_ value: JSONValue) -> JSONValue {
  guard case .object(var top) = value else { return value }
  top["firecracker_bin"] = nil
  top["network"] = nil
  if case .object(var vm)? = top["vm"] {
    vm["kernel_path"] = nil
    vm["boot_args"] = nil
    top["vm"] = .object(vm)
  }
  return .object(top)
}

extension JSONValue {
  func replacing(_ path: [String], with replacement: JSONValue) -> JSONValue {
    guard let first = path.first else { return replacement }
    guard case .object(var members) = self, let child = members[first] else { return self }
    members[first] = child.replacing(Array(path.dropFirst()), with: replacement)
    return .object(members)
  }
}

func diff(_ a: JSONValue, _ b: JSONValue, path: String = "") -> String {
  switch (a, b) {
  case (.object(let x), .object(let y)):
    for key in Set(x.keys).union(y.keys).sorted() {
      guard let xv = x[key], let yv = y[key] else {
        return "\(path).\(key): present on one side only"
      }
      if !xv.semanticallyEquals(yv) { return diff(xv, yv, path: "\(path).\(key)") }
    }
    return "equal"
  case (.array(let x), .array(let y)) where x.count == y.count:
    for (index, pair) in zip(x, y).enumerated() where !pair.0.semanticallyEquals(pair.1) {
      return diff(pair.0, pair.1, path: "\(path)[\(index)]")
    }
    return "equal"
  default: return "\(path): swift=\(a) baseline=\(b)"
  }
}

/// The baseline serde shape of `IsoConfig` (minus retired fields).
func normalized(_ c: IsoConfig) -> JSONValue {
  func string(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }
  func strings(_ s: [String]) -> JSONValue { .array(s.map(JSONValue.string)) }
  func int(_ n: some BinaryInteger) -> JSONValue { .number(.integer(Int64(n))) }
  func secret(_ s: Secret<String>?) -> JSONValue { string(s?.expose()) }
  func configDir(_ d: ConfigDirectory) -> JSONValue {
    switch d {
    case .default: .null
    case .disabled: .bool(false)
    case .custom(let path): .string(path.path)
    }
  }
  func mcp(_ server: MCPServer) -> JSONValue {
    switch server {
    case .stdio(let command, let args, let env):
      var out: [String: JSONValue] = ["command": .string(command)]
      if !args.isEmpty { out["args"] = strings(args) }
      if !env.isEmpty {
        out["env"] = .object(
          Dictionary(
            uniqueKeysWithValues: env.map { ($0.key.rawValue, .string($0.value.rawValue)) }))
      }
      return .object(out)
    case .http(let url, let headers), .sse(let url, let headers):
      var out: [String: JSONValue] = ["url": .string(url.absoluteString)]
      if case .http = server { out["type"] = .string("http") } else { out["type"] = .string("sse") }
      if !headers.isEmpty { out["headers"] = .object(headers.mapValues { .string($0.expose()) }) }
      return .object(out)
    }
  }
  func local(_ model: LocalModel?) -> JSONValue {
    guard let model else { return .null }
    return .object([
      "host_url": .string(model.hostURL.absoluteString), "model": .string(model.model),
      "auth_token": secret(model.authToken),
    ])
  }
  func agent(_ a: AgentConfig) -> [String: JSONValue] {
    [
      "api_key": secret(a.apiKey), "env_forward": strings(a.envForward.map(\.rawValue)),
      "marketplaces": strings(a.marketplaces), "plugins": strings(a.plugins),
      "mcp_servers": .object(a.mcpServers.mapValues(mcp)),
      "config_dir": configDir(a.configDirectory),
      "local_model": local(a.localModel),
    ]
  }
  func upstream(_ u: ProxyUpstream?) -> JSONValue {
    guard let u else { return .null }
    return .object([
      "credential": .string(u.credential.command.expose()), "auth": .string(u.auth.rawValue),
    ])
  }
  func github(_ g: GitHubAuth?) -> JSONValue {
    switch g {
    case nil: return .null
    case .auto?, .env?, .off?: return .string(g!.modeName)
    case .pat(let pat)?:
      var out: [String: JSONValue] = ["mode": .string("pat")]
      if !pat.entries.isEmpty {
        out["pat"] = .object(
          Dictionary(
            uniqueKeysWithValues: pat.entries.map {
              ($0.key.rawValue, .object(["token": .string($0.value.expose())]))
            }))
      }
      if !pat.skip.isEmpty { out["skip"] = strings(pat.skip.map(\.rawValue)) }
      return .object(out)
    }
  }
  var codex = agent(c.codex)
  codex["auth"] = .string(c.codexAuth.rawValue)
  let a = c.appleContainer
  return .object([
    "data_dir": .string(c.dataDirectory.path),
    "vm": .object([
      "vcpu_count": int(c.vm.vcpuCount), "mem_size_mib": int(c.vm.memory.mib.value),
      "template_size_gib": int(c.vm.templateSize.value),
    ]),
    "ssh_port": int(c.sshPort),
    "github": github(c.github),
    "setup": .object(["prompt_for_pat": .bool(c.setup.promptForPAT)]),
    "claude": .object(agent(c.claude)),
    "codex": .object(codex),
    "proxy": .object(["anthropic": upstream(c.proxy.anthropic), "openai": upstream(c.proxy.openai)]
    ),
    "guest_env": .object(
      Dictionary(
        uniqueKeysWithValues: c.guestEnvironment.map { ($0.name.rawValue, .string($0.value)) })),
    "profiles": .object(
      c.profiles.mapValues {
        .object([
          "apt_packages": strings($0.aptPackages), "pre_install": string($0.preInstall),
          "post_install": string($0.postInstall), "marketplaces": strings($0.marketplaces),
          "plugins": strings($0.plugins),
        ])
      }),
    "post_start": string(c.postStart),
    "forward_ports": .array(
      c.forwardPorts.map { f in
        var out: [String: JSONValue] = ["guest": int(f.guest)]
        if f.host != f.guest { out["host"] = int(f.host) }
        if let label = f.label { out["label"] = .string(label) }
        return .object(out)
      }),
    "updates": .object([
      "mode": .string(c.updates.mode.rawValue),
      "check_interval_hours": int(c.updates.checkIntervalHours),
    ]),
    "apple_container": .object([
      "binary": string(a.binary?.path), "builder": string(a.builder?.path),
      "kernel": string(a.kernel?.path),
      "probe_timeout_seconds": int(a.probeTimeout.seconds),
      "operation_timeout_seconds": int(a.operationTimeout.seconds),
      "create_timeout_seconds": int(a.createTimeout.seconds),
      "boot_timeout_seconds": int(a.bootTimeout.seconds),
      "stop_timeout_seconds": int(a.stopTimeout.seconds),
      "build_timeout_seconds": int(a.buildTimeout.seconds),
    ]),
  ])
}

extension ConfigLoader {
  /// Test helper: the full pipeline over an in-memory JSONC document.
  static func load(
    bytes text: String, path: String = "config.jsonc", format: ConfigFormat = .jsonc,
    environment: ConfigEnvironment = fixtureHome
  ) throws(ConfigError) -> IsoConfig {
    let value = try parse(Array(text.utf8), format: format, path: path, limits: .configuration)
    return try decode(value, path: path, environment: environment)
  }
}
