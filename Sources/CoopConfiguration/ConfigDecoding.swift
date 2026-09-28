// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopCore
import Foundation

/// A field failure inside the document; `ConfigLoader` adds the file path.
struct FieldError: Error {
  let field: String
  let reason: String

  init(_ path: [JSONPathComponent], _ reason: String) {
    field = renderPath(path)
    self.reason = reason
  }
}

/// Reads one JSON object with explicit absent / null / wrong-type handling.
/// Mirrors the baseline serde policy per field: optional fields treat `null`
/// as absent; defaulted and required fields reject `null`.
struct ObjectReader {
  let path: [JSONPathComponent]
  let members: [String: JSONValue]

  init(_ value: JSONValue, at path: [JSONPathComponent]) throws(FieldError) {
    guard case .object(let members) = value else {
      throw FieldError(path, "expected an object, found \(value.typeName)")
    }
    self.path = path
    self.members = members
  }

  func child(_ key: String) -> [JSONPathComponent] { path + [.key(key)] }

  /// Absent or `null` → nil.
  func optional<T>(_ key: String, _ parse: (JSONValue, [JSONPathComponent]) throws(FieldError) -> T)
    throws(FieldError) -> T?
  {
    guard let value = members[key], value != .null else { return nil }
    return try parse(value, child(key))
  }

  /// Absent → `fallback`; `null` is a type error.
  func defaulted<T>(
    _ key: String, _ fallback: @autoclosure () throws(FieldError) -> T,
    _ parse: (JSONValue, [JSONPathComponent]) throws(FieldError) -> T
  ) throws(FieldError) -> T {
    guard let value = members[key] else { return try fallback() }
    return try parse(value, child(key))
  }

  /// Absent → "missing field"; `null` is a type error.
  func required<T>(_ key: String, _ parse: (JSONValue, [JSONPathComponent]) throws(FieldError) -> T)
    throws(FieldError) -> T
  {
    guard let value = members[key] else { throw FieldError(child(key), "missing required field") }
    return try parse(value, child(key))
  }

  func rejectUnknown(allowing allowed: Set<String>) throws(FieldError) {
    if let unknown = members.keys.filter({ !allowed.contains($0) }).sorted().first {
      throw FieldError(child(unknown), "unknown field")
    }
  }
}

enum Parse {
  static func string(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError) -> String {
    guard case .string(let string) = value else {
      throw FieldError(path, "expected a string, found \(value.typeName)")
    }
    return string
  }

  /// Secret-bearing string: errors never describe the value.
  static func secret(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError) -> Secret<
    String
  > {
    Secret(try string(value, path))
  }

  static func bool(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError) -> Bool {
    guard case .bool(let bool) = value else {
      throw FieldError(path, "expected a boolean, found \(value.typeName)")
    }
    return bool
  }

  static func unsigned<T: FixedWidthInteger & UnsignedInteger>(
    _ value: JSONValue, _ path: [JSONPathComponent], as _: T.Type = T.self
  ) throws(FieldError) -> T {
    let result: T?
    switch value {
    case .number(.integer(let n)): result = n >= 0 ? T(exactly: n) : nil
    case .number(.unsigned(let n)): result = T(exactly: n)
    case .number(.decimal): throw FieldError(path, "expected an integer, found a fractional number")
    default: throw FieldError(path, "expected an integer, found \(value.typeName)")
    }
    guard let result else {
      throw FieldError(path, "integer \(value.numberDescription) is out of range 0..=\(T.max)")
    }
    return result
  }

  static func nonZero<T: FixedWidthInteger & UnsignedInteger>(
    _ value: JSONValue, _ path: [JSONPathComponent], as type: T.Type = T.self
  ) throws(FieldError) -> T {
    let result = try unsigned(value, path, as: type)
    guard result != 0 else { throw FieldError(path, "must be > 0") }
    return result
  }

  static func array<T>(
    _ value: JSONValue, _ path: [JSONPathComponent],
    _ element: (JSONValue, [JSONPathComponent]) throws(FieldError) -> T
  ) throws(FieldError) -> [T] {
    guard case .array(let elements) = value else {
      throw FieldError(path, "expected an array, found \(value.typeName)")
    }
    var out: [T] = []
    out.reserveCapacity(elements.count)
    for (index, item) in elements.enumerated() {
      out.append(try element(item, path + [.index(index)]))
    }
    return out
  }

  /// Dynamic map: keys are literal, never split on `.` or case-converted.
  static func map<T>(
    _ value: JSONValue, _ path: [JSONPathComponent],
    _ element: (JSONValue, [JSONPathComponent]) throws(FieldError) -> T
  ) throws(FieldError) -> [String: T] {
    guard case .object(let members) = value else {
      throw FieldError(path, "expected an object, found \(value.typeName)")
    }
    var out: [String: T] = [:]
    for key in members.keys.sorted() { out[key] = try element(members[key]!, path + [.key(key)]) }
    return out
  }

  static func domain<T>(_ path: [JSONPathComponent], _ body: () throws(ValidationError) -> T)
    throws(FieldError) -> T
  {
    do { return try body() } catch { throw FieldError(path, error.message) }
  }

  static func envVarName(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> EnvVarName
  {
    let raw = try string(value, path)
    return try domain(path) { () throws(ValidationError) in try EnvVarName(raw) }
  }

  static func envVarKey(_ key: String, _ path: [JSONPathComponent]) throws(FieldError) -> EnvVarName
  {
    try domain(path) { () throws(ValidationError) in try EnvVarName(key) }
  }

  static func repoSlug(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> RepoSlug
  {
    let raw = try string(value, path)
    return try domain(path) { () throws(ValidationError) in try RepoSlug(raw) }
  }

  static func timeout(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> TimeoutSecs
  {
    let seconds = try unsigned(value, path, as: UInt32.self)
    return try domain(path) { () throws(ValidationError) in try TimeoutSecs(seconds) }
  }

  /// An integer byte count, or a string with a binary suffix (`"256MiB"`).
  static func byteCount(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> ByteCount
  {
    if case .string(let text) = value {
      return try domain(path) { () throws(ValidationError) in try ByteCount(parsing: text) }
    }
    let bytes = try nonZero(value, path, as: UInt64.self)
    return ByteCount(bytes: bytes)!
  }

  static func stringEnum<T: RawRepresentable<String>>(
    _ value: JSONValue, _ path: [JSONPathComponent], _ allowed: [T]
  ) throws(FieldError) -> T {
    let raw = try string(value, path)
    guard let result = allowed.first(where: { $0.rawValue == raw }) else {
      let names = allowed.map { "'\($0.rawValue)'" }.joined(separator: ", ")
      throw FieldError(path, "unknown variant '\(raw)', expected one of \(names)")
    }
    return result
  }
}

extension JSONValue {
  var numberDescription: String {
    if case .number(let number) = self { number.description } else { typeName }
  }
}

/// Maps a decoded document onto the typed model. Pure: reads only the value
/// and the injected environment; never touches the filesystem or runs a
/// credential command.
enum ConfigDecoder {
  /// Firecracker host settings removed by C-01. Rejected by name even where
  /// unknown keys are otherwise ignored.
  static let retiredTopLevel = ["firecracker_bin", "network"]
  static let retiredVM = ["kernel_path", "boot_args"]

  static func decode(_ root: JSONValue, environment: ConfigEnvironment) throws(ConfigDecodeFailure)
    -> CoopConfig
  {
    guard case .object(let top) = root else { throw .rootNotObject }
    var retired = retiredTopLevel.filter { top[$0] != nil }
    if case .object(let vm)? = top["vm"] {
      retired += retiredVM.filter { vm[$0] != nil }.map { "vm.\($0)" }
    }
    if !retired.isEmpty { throw .retired(retired) }
    do {
      return try decodeFields(ObjectReader(root, at: []), environment: environment)
    } catch {
      throw .field(error)
    }
  }

  private static func decodeFields(_ r: ObjectReader, environment env: ConfigEnvironment)
    throws(FieldError)
    -> CoopConfig
  {
    let defaultDataDir = HostPath(expanding: "~/.coop", home: env.home ?? ".")
    let dataDir = try r.defaulted("data_dir", defaultDataDir) { v, p throws(FieldError) in
      HostPath(expanding: try Parse.string(v, p), home: env.home)
    }
    return CoopConfig(
      dataDirectory: dataDir,
      vm: try r.defaulted("vm", .defaults, vm),
      sshPort: try r.defaulted("ssh_port", 22) { v, p throws(FieldError) in
        try Parse.nonZero(v, p, as: UInt16.self)
      },
      github: try r.optional("github", github),
      setup: try r.defaulted("setup", SetupConfig(promptForPAT: true)) { v, p throws(FieldError) in
        let s = try ObjectReader(v, at: p)
        return SetupConfig(promptForPAT: try s.defaulted("prompt_for_pat", true, Parse.bool))
      },
      claude: try agent(r, "claude", env: env, apiKeyVariable: "ANTHROPIC_API_KEY"),
      codex: try agent(r, "codex", env: env, apiKeyVariable: "OPENAI_API_KEY"),
      codexAuth: try r.defaulted("codex", .apiKey) { v, p throws(FieldError) in
        try ObjectReader(v, at: p).defaulted("auth", .apiKey) { v, p throws(FieldError) in
          try Parse.stringEnum(v, p, [CodexAuthMode.apiKey, .chatgpt])
        }
      },
      proxy: try r.defaulted("proxy", ProxyConfig(anthropic: nil, openai: nil), proxy),
      guestEnvironment: try r.defaulted("guest_env", []) { v, p throws(FieldError) in
        let values = try Parse.map(v, p, Parse.string)
        var out: [GuestVariable] = []
        for key in values.keys.sorted(by: utf8Less) {
          out.append(
            GuestVariable(name: try Parse.envVarKey(key, p + [.key(key)]), value: values[key]!))
        }
        return out
      },
      profiles: try r.defaulted("profiles", [:]) { v, p throws(FieldError) in
        try Parse.map(v, p) { v, p throws(FieldError) in try profile(v, p, env: env) }
      },
      postStart: try r.optional("post_start", Parse.string),
      forwardPorts: try r.defaulted("forward_ports", []) { v, p throws(FieldError) in
        try Parse.array(v, p, portForward)
      },
      updates: try r.defaulted("updates", UpdateConfig(mode: .notify, checkIntervalHours: 24)) {
        v, p throws(FieldError) in
        let u = try ObjectReader(v, at: p)
        return UpdateConfig(
          mode: try u.defaulted("mode", .notify) { v, p throws(FieldError) in
            try Parse.stringEnum(v, p, [UpdateMode.off, .notify])
          },
          checkIntervalHours: try u.defaulted("check_interval_hours", 24) {
            v, p throws(FieldError) in
            try Parse.unsigned(v, p, as: UInt64.self)
          })
      },
      appleContainer: try r.defaulted("apple_container", AppleContainerConfig.defaults) {
        v, p throws(FieldError) in try appleContainer(v, p, env: env)
      },
      workspacePull: try r.defaulted("workspace", .defaults) { v, p throws(FieldError) in
        let w = try ObjectReader(v, at: p)
        try w.rejectUnknown(allowing: ["pull"])
        return try w.defaulted("pull", .defaults, workspacePull)
      })
  }

  static func workspacePull(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> WorkspacePullConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: ["mode", "max_files", "max_bytes", "max_file_bytes"])
    let d = StageLimits.defaults
    return WorkspacePullConfig(
      mode: try r.defaulted("mode", .direct) { v, p throws(FieldError) in
        try Parse.stringEnum(v, p, [WorkspacePullMode.direct, .stage])
      },
      limits: StageLimits(
        maxFiles: try r.defaulted("max_files", d.maxFiles) { v, p throws(FieldError) in
          try Parse.nonZero(v, p, as: UInt64.self)
        },
        maxBytes: try r.defaulted("max_bytes", d.maxBytes, Parse.byteCount),
        maxFileBytes: try r.defaulted("max_file_bytes", d.maxFileBytes, Parse.byteCount)))
  }

  static func vm(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError) -> VMConfig {
    let r = try ObjectReader(value, at: path)
    let defaults = VMConfig.defaults
    return VMConfig(
      vcpuCount: try r.defaulted("vcpu_count", defaults.vcpuCount) { v, p throws(FieldError) in
        try Parse.nonZero(v, p, as: UInt8.self)
      },
      memory: try r.defaulted("mem_size_mib", defaults.memory) { v, p throws(FieldError) in
        let mib = MiB(try Parse.nonZero(v, p, as: UInt32.self))!
        return try Parse.domain(p) { () throws(ValidationError) in try VmMemory(mib) }
      },
      templateSize: try r.defaulted("template_size_gib", defaults.templateSize) {
        v, p throws(FieldError) in
        GiB(try Parse.nonZero(v, p, as: UInt32.self))!
      })
  }

  static func github(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> GitHubAuth
  {
    func mode(_ name: String, entries: [RepoSlug: Secret<String>], skip: [RepoSlug])
      throws(FieldError)
      -> GitHubAuth
    {
      switch name {
      case "auto": return .auto
      case "env": return .env
      case "off": return .off
      case "pat": return .pat(PATConfig(entries: entries, skip: skip))
      default:
        throw FieldError(path, "unknown github mode '\(name)' (expected auto, env, off, or pat)")
      }
    }
    if case .string(let name) = value { return try mode(name, entries: [:], skip: []) }
    guard case .object = value else {
      throw FieldError(
        path, "expected a string (\"auto\" / \"env\" / \"off\" / \"pat\") or an object")
    }
    let r = try ObjectReader(value, at: path)
    let explicitMode = try r.optional("mode", Parse.string)
    let entries = try r.optional("pat") { v, p throws(FieldError) -> [RepoSlug: Secret<String>] in
      let raw = try Parse.map(v, p) { v, p throws(FieldError) in
        try ObjectReader(v, at: p).required("token", Parse.secret)
      }
      var out: [RepoSlug: Secret<String>] = [:]
      for (key, token) in raw {
        let slug = try Parse.domain(p + [.key(key)]) { () throws(ValidationError) in
          try RepoSlug(key)
        }
        out[slug] = token
      }
      return out
    }
    let skip = try r.optional("skip") { v, p throws(FieldError) in
      try Parse.array(v, p, Parse.repoSlug)
    }
    // Without `mode`, per-repo data implies "pat"; otherwise "off".
    let implied = (entries.map { !$0.isEmpty } ?? false) || skip != nil ? "pat" : "off"
    return try mode(explicitMode ?? implied, entries: entries ?? [:], skip: skip ?? [])
  }

  static func agent(
    _ r: ObjectReader, _ key: String, env: ConfigEnvironment, apiKeyVariable: String
  ) throws(FieldError) -> AgentConfig {
    // An absent section takes the key from the environment; a present
    // section without `api_key` does not (baseline serde default semantics).
    guard let value = r.members[key] else {
      return AgentConfig(
        apiKey: env.variables[apiKeyVariable].map(Secret.init), envForward: [], marketplaces: [],
        plugins: [], mcpServers: [:], configDirectory: .default, localModel: nil)
    }
    let path = r.child(key)
    let a = try ObjectReader(value, at: path)
    return AgentConfig(
      apiKey: try a.optional("api_key", Parse.secret),
      envForward: try a.defaulted("env_forward", []) { v, p throws(FieldError) in
        try Parse.array(v, p, Parse.envVarName)
      },
      marketplaces: expandMarketplaces(
        try a.defaulted("marketplaces", []) { v, p throws(FieldError) in
          try Parse.array(v, p, Parse.string)
        },
        env: env),
      plugins: try a.defaulted("plugins", []) { v, p throws(FieldError) in
        try Parse.array(v, p, Parse.string)
      },
      mcpServers: try a.defaulted("mcp_servers", [:]) { v, p throws(FieldError) in
        try Parse.map(v, p, mcpServer)
      },
      configDirectory: try a.defaulted("config_dir", .default) { v, p throws(FieldError) in
        switch v {
        case .null: return .default
        case .bool(false): return .disabled
        case .bool(true):
          throw FieldError(p, "config_dir does not accept true — use a path string or false")
        case .string(let raw): return .custom(HostPath(expanding: raw, home: env.home))
        default: throw FieldError(p, "expected a path string, false, or null, found \(v.typeName)")
        }
      },
      localModel: try a.optional("local_model", localModel))
  }

  /// Marketplace entries mix URLs, GitHub slugs and host paths; only entries
  /// that start with `~` are paths to expand.
  static func expandMarketplaces(_ entries: [String], env: ConfigEnvironment) -> [String] {
    entries.map { $0.hasPrefix("~") ? HostPath(expanding: $0, home: env.home).path : $0 }
  }

  static func localModel(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> LocalModel
  {
    let r = try ObjectReader(value, at: path)
    let hostURL = try r.required("host_url", Parse.string)
    let model = try r.required("model", Parse.string)
    let token = try r.optional("auth_token", Parse.secret)
    return try Parse.domain(path) { () throws(ValidationError) in
      try LocalModel(hostURL: hostURL, model: model, authToken: token)
    }
  }

  static func mcpServer(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> MCPServer
  {
    let r = try ObjectReader(value, at: path)
    let command = try r.optional("command", Parse.string)
    let args = try r.defaulted("args", []) { v, p throws(FieldError) in
      try Parse.array(v, p, Parse.string)
    }
    let transport = try r.optional("type", Parse.string)
    let url = try r.optional("url", Parse.string)
    let env = try r.defaulted("env", [:]) { v, p throws(FieldError) -> [EnvVarName: EnvVarName] in
      let raw = try Parse.map(v, p, Parse.envVarName)
      var out: [EnvVarName: EnvVarName] = [:]
      for (key, target) in raw { out[try Parse.envVarKey(key, p + [.key(key)])] = target }
      return out
    }
    let headers = try r.defaulted("headers", [:]) { v, p throws(FieldError) in
      try Parse.map(v, p, Parse.secret)
    }
    switch transport {
    case nil, "stdio":
      guard url == nil else {
        throw FieldError(path, "stdio MCP server must not have a `url` field")
      }
      guard headers.isEmpty else {
        throw FieldError(path, "stdio MCP server must not have a `headers` field")
      }
      guard let command else { throw FieldError(r.child("command"), "missing required field") }
      return .stdio(command: command, args: args, env: env)
    case let kind? where kind == "http" || kind == "sse":
      guard command == nil else {
        throw FieldError(path, "\(kind) MCP server must not have a `command` field")
      }
      guard args.isEmpty else {
        throw FieldError(path, "\(kind) MCP server must not have an `args` field")
      }
      guard env.isEmpty else {
        throw FieldError(path, "\(kind) MCP server must not have an `env` field")
      }
      guard let url else { throw FieldError(r.child("url"), "missing required field") }
      guard let parsed = URL(string: url), parsed.scheme != nil else {
        throw FieldError(r.child("url"), "invalid url '\(url)'")
      }
      return kind == "http"
        ? .http(url: parsed, headers: headers) : .sse(url: parsed, headers: headers)
    case let other?:
      throw FieldError(
        r.child("type"), "unknown MCP server type '\(other)' (expected 'stdio', 'http', or 'sse')")
    }
  }

  static func proxy(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> ProxyConfig
  {
    let r = try ObjectReader(value, at: path)
    func upstream(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
      -> ProxyUpstream
    {
      let u = try ObjectReader(value, at: path)
      let raw = try u.required("credential", Parse.secret)
      guard let credential = CredentialReference(raw.expose()) else {
        throw FieldError(
          u.child("credential"),
          "literal credentials are not accepted; run `coop proxy setup` to store the credential in the macOS Keychain, or write a `cmd:` reference to a command that prints it"
        )
      }
      return ProxyUpstream(
        credential: credential,
        auth: try u.defaulted("auth", .apiKey) { v, p throws(FieldError) in
          try Parse.stringEnum(v, p, [ProxyAuthScheme.apiKey, .bearer])
        })
    }
    return ProxyConfig(
      anthropic: try r.optional("anthropic", upstream), openai: try r.optional("openai", upstream),
      mode: try r.defaulted("mode", .auto) { v, p throws(FieldError) in
        try Parse.stringEnum(v, p, [ProxyMode.auto, .required, .off])
      })
  }

  static func profile(_ value: JSONValue, _ path: [JSONPathComponent], env: ConfigEnvironment)
    throws(FieldError) -> CustomProfile
  {
    let r = try ObjectReader(value, at: path)
    let strings = { (v: JSONValue, p: [JSONPathComponent]) throws(FieldError) in
      try Parse.array(v, p, Parse.string)
    }
    return CustomProfile(
      aptPackages: try r.defaulted("apt_packages", [], strings),
      preInstall: try r.optional("pre_install", Parse.string),
      postInstall: try r.optional("post_install", Parse.string),
      marketplaces: expandMarketplaces(try r.defaulted("marketplaces", [], strings), env: env),
      plugins: try r.defaulted("plugins", [], strings))
  }

  /// `forward_ports` entry: a port number, a `"GUEST[:HOST]"` string, or an
  /// object `{ guest, host?, label? }` (unknown members ignored).
  static func portForward(_ value: JSONValue, _ path: [JSONPathComponent]) throws(FieldError)
    -> PortForward
  {
    switch value {
    case .number:
      let port = try Parse.nonZero(value, path, as: UInt16.self)
      return try Parse.domain(path) { () throws(ValidationError) in try PortForward(guest: port) }
    case .string(let spec):
      return try Parse.domain(path) { () throws(ValidationError) in try PortForward.parse(spec) }
    case .object:
      let r = try ObjectReader(value, at: path)
      let port = { (v: JSONValue, p: [JSONPathComponent]) throws(FieldError) in
        try Parse.nonZero(v, p, as: UInt16.self)
      }
      guard r.members["guest"] != nil else {
        throw FieldError(path, "forward_ports entry missing 'guest'")
      }
      let guest = try r.required("guest", port)
      let host = try r.defaulted("host", guest, port)
      let label = try r.defaulted("label", nil) { v, p throws(FieldError) -> String? in
        try Parse.string(v, p)
      }
      return try Parse.domain(path) { () throws(ValidationError) in
        try PortForward(guest: guest, host: host, label: label)
      }
    default:
      throw FieldError(
        path, "expected a port number, a 'GUEST[:HOST]' string, or a { guest, host, label } object")
    }
  }

  static let appleContainerKeys: Set<String> = [
    "binary", "builder", "kernel", "probe_timeout_seconds", "operation_timeout_seconds",
    "create_timeout_seconds", "boot_timeout_seconds", "stop_timeout_seconds",
    "build_timeout_seconds",
  ]

  static func appleContainer(
    _ value: JSONValue, _ path: [JSONPathComponent], env: ConfigEnvironment
  )
    throws(FieldError) -> AppleContainerConfig
  {
    let r = try ObjectReader(value, at: path)
    try r.rejectUnknown(allowing: appleContainerKeys)
    let hostPath = { (v: JSONValue, p: [JSONPathComponent]) throws(FieldError) in
      HostPath(expanding: try Parse.string(v, p), home: env.home)
    }
    let d = AppleContainerConfig.defaults
    return AppleContainerConfig(
      binary: try r.optional("binary", hostPath),
      builder: try r.optional("builder", hostPath),
      kernel: try r.optional("kernel", hostPath),
      probeTimeout: try r.defaulted("probe_timeout_seconds", d.probeTimeout, Parse.timeout),
      operationTimeout: try r.defaulted(
        "operation_timeout_seconds", d.operationTimeout, Parse.timeout),
      createTimeout: try r.defaulted("create_timeout_seconds", d.createTimeout, Parse.timeout),
      bootTimeout: try r.defaulted("boot_timeout_seconds", d.bootTimeout, Parse.timeout),
      stopTimeout: try r.defaulted("stop_timeout_seconds", d.stopTimeout, Parse.timeout),
      buildTimeout: try r.defaulted("build_timeout_seconds", d.buildTimeout, Parse.timeout))
  }
}

enum ConfigDecodeFailure: Error {
  case rootNotObject
  case retired([String])
  case field(FieldError)
}

/// Byte-wise ordering, matching Rust `BTreeMap<String, _>` iteration.
func utf8Less(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

extension AppleContainerConfig {
  public static let defaults = AppleContainerConfig(
    binary: nil, builder: nil, kernel: nil, probeTimeout: try! TimeoutSecs(10),
    operationTimeout: try! TimeoutSecs(60), createTimeout: try! TimeoutSecs(600),
    bootTimeout: try! TimeoutSecs(120), stopTimeout: try! TimeoutSecs(90),
    buildTimeout: try! TimeoutSecs(3600))
}
