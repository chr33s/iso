import Foundation
import IsoConfiguration
import IsoCore

/// Whether a VM's agents target the cloud or a host-side local server.
public enum ModelMode: String, Sendable, Equatable {
  case remote
  case local
}

/// `<instance>/model.json`: the per-VM model selection and any endpoints
/// entered at the `iso model` prompt. A missing file is the default
/// (remote, nothing saved); the default is never written.
public struct ModelState: Sendable, Equatable {
  public var mode: ModelMode = .remote
  public var claudeEndpoint: LocalModel?
  public var codexEndpoint: LocalModel?
  /// Set once iso has written a Codex `iso_local` provider block, so a
  /// later switch away still rewrites a clean `config.toml`.
  public var codexMaterialized = false
  /// Set once iso has written the keyring credential store for
  /// `codex.auth = "chatgpt"`, so a switch back to `api_key` drops it.
  public var codexKeyringMaterialized = false

  public init() {}

  var isDefault: Bool {
    mode == .remote && claudeEndpoint == nil && codexEndpoint == nil && !codexMaterialized
      && !codexKeyringMaterialized
  }

  /// Configuration wins over the saved endpoint; independent of `mode`.
  public func resolvedClaude(_ claude: AgentConfig) -> LocalModel? {
    claude.localModel ?? claudeEndpoint
  }

  public func resolvedCodex(_ codex: AgentConfig) -> LocalModel? {
    codex.localModel ?? codexEndpoint
  }

  public static func tryLoad(_ instance: Instance) throws -> ModelState? {
    let path = instance.modelStatePath
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    do {
      return try decode(bytes)
    } catch {
      throw ContextError("Failed to parse model.json", cause: error)
    }
  }

  public static func loadOrDefault(_ instance: Instance) throws -> ModelState {
    try tryLoad(instance) ?? ModelState()
  }

  static func decode(_ bytes: [UInt8]) throws -> ModelState {
    let value = try ConfigLoader.parse(
      bytes, format: .json, path: "model.json", limits: .configuration)
    guard case .object(let members) = value else {
      throw HostError("invalid type: expected struct ModelState")
    }
    var state = ModelState()
    switch members["mode"] {
    case nil: break
    case .string(let raw)?:
      guard let mode = ModelMode(rawValue: raw) else {
        throw HostError("unknown variant `\(raw)`, expected `remote` or `local`")
      }
      state.mode = mode
    default: throw HostError("invalid type for `mode`")
    }
    state.claudeEndpoint = try endpoint(members["claude_endpoint"])
    state.codexEndpoint = try endpoint(members["codex_endpoint"])
    state.codexMaterialized = try flag(members["codex_materialized"], "codex_materialized")
    state.codexKeyringMaterialized = try flag(
      members["codex_keyring_materialized"], "codex_keyring_materialized")
    return state
  }

  static func flag(_ value: JSONValue?, _ name: String) throws -> Bool {
    switch value {
    case nil: false
    case .bool(let flag)?: flag
    default: throw HostError("invalid type for `\(name)`")
    }
  }

  static func endpoint(_ value: JSONValue?) throws -> LocalModel? {
    guard let value, value != .null else { return nil }
    guard case .object(let members) = value, case .string(let url)? = members["host_url"],
      case .string(let model)? = members["model"]
    else { throw HostError("invalid local model endpoint") }
    let token: Secret<String>?
    switch members["auth_token"] {
    case nil, .null?: token = nil
    case .string(let raw)?: token = Secret(raw)
    default: throw HostError("invalid type for `auth_token`")
    }
    return try LocalModel(hostURL: url, model: model, authToken: token)
  }

  /// Owner-only: a prompted `auth_token` is stored here.
  public func save(_ instance: Instance, diagnostics: Diagnostics? = nil) throws {
    let path = instance.modelStatePath
    if isDefault {
      if unlink(path) != 0 && errno != ENOENT {
        diagnostics?.debug(
          "Failed to remove default model state \(path) (non-fatal): \(String(cString: strerror(errno)))"
        )
      }
      return
    }
    do {
      try AtomicFile.write(Array(rendered.utf8), to: path, mode: .atMost(0o600))
    } catch {
      throw ContextError("Failed to write model.json", cause: error)
    }
    diagnostics?.debug("Wrote model state to \(path)")
  }

  /// `serde_json::to_string_pretty` of the Rust record.
  var rendered: String {
    var members: [(String, OutputJSON)] = [("mode", .string(mode.rawValue))]
    if let claudeEndpoint { members.append(("claude_endpoint", Self.json(claudeEndpoint))) }
    if let codexEndpoint { members.append(("codex_endpoint", Self.json(codexEndpoint))) }
    if codexMaterialized { members.append(("codex_materialized", .bool(true))) }
    if codexKeyringMaterialized { members.append(("codex_keyring_materialized", .bool(true))) }
    return String(OutputJSON.object(members).rendered().dropLast())
  }

  static func json(_ endpoint: LocalModel) -> OutputJSON {
    .object([
      ("host_url", .string(EndpointURL(endpoint.hostURL).serialized)),
      ("model", .string(endpoint.model)),
      ("auth_token", endpoint.authToken.map { .string($0.expose()) } ?? .null),
    ])
  }
}

extension LocalModel {
  /// The configured token, or the shared placeholder for permissive servers.
  public var authTokenOrDefault: String { authToken?.expose() ?? LocalModel.authFallback }
}

// MARK: - Materialized agent configuration

public enum ModelRouting {
  /// Codex `model_provider` id iso writes.
  public static let codexLocalProvider = "iso_local"
  /// The variable Codex reads the `iso_local` provider key from.
  public static let codexLocalEnvKey = "ISO_LOCAL_API_KEY"

  /// Claude `settings.json` `env` for a local endpoint: every model tier is
  /// pinned to the local model, and the two per-request prompt mutators are
  /// disabled so a local server's prefix cache stays warm.
  public static func claudeEnvBlock(baseURL: String, model: String, authToken: String)
    -> [String: String]
  {
    var env = [
      "ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_AUTH_TOKEN": authToken,
      "CLAUDE_CODE_ATTRIBUTION_HEADER": "0", "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS": "1",
    ]
    for tier in [
      "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
      "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    ] {
      env[tier] = model
    }
    return env
  }

  /// Proxy mode is transparent: only the base URL and the capability token.
  public static func claudeProxyEnvBlock(baseURL: String, capabilityToken: String) -> [String:
    String]
  {
    ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_AUTH_TOKEN": capabilityToken]
  }

  static func codexLocalConfig(baseURL: String, model: String) -> TOMLTable {
    TOMLTable([
      ("model", .string(model)), ("model_provider", .string(codexLocalProvider)),
      (
        "model_providers",
        .table(
          TOMLTable([
            (
              codexLocalProvider,
              .table(
                TOMLTable([
                  ("name", .string("iso local model")), ("base_url", .string(baseURL)),
                  ("wire_api", .string("responses")), ("env_key", .string(codexLocalEnvKey)),
                ]))
            )
          ]))
      ),
    ])
  }

  /// No model pin; Codex forms `{base_url}/responses`, so `/v1` is added.
  static func codexProxyConfig(baseURL: String) -> TOMLTable {
    var base = Substring(baseURL)
    while base.hasSuffix("/") { base = base.dropLast() }
    return TOMLTable([
      ("model_provider", .string(codexLocalProvider)),
      (
        "model_providers",
        .table(
          TOMLTable([
            (
              codexLocalProvider,
              .table(
                TOMLTable([
                  ("name", .string("iso credential proxy")), ("base_url", .string(base + "/v1")),
                  ("wire_api", .string("responses")), ("env_key", .string(codexLocalEnvKey)),
                ]))
            )
          ]))
      ),
    ])
  }
}

// MARK: - Local endpoint routing

/// `ssh -R 127.0.0.1:<guestPort>:<hostAddress>:<hostPort>`: a host-loopback
/// model server carried onto the guest's own loopback.
public struct ReverseTunnel: Sendable, Equatable {
  public let guestPort: UInt16
  public let hostAddress: IPv4Address
  public let hostPort: UInt16
}

public struct LocalEndpointPlan: Sendable, Equatable {
  /// Written into the guest agent's configuration.
  public let guestURL: String
  public let tunnel: ReverseTunnel?
}

/// Apple guests have no route to the host's loopback, so every loopback
/// endpoint goes over a per-instance reverse tunnel.
public enum LocalEndpoints {
  static let privilegedPortOffset: UInt16 = 40_000

  /// Non-loopback URLs pass through. `localhost` and `127.0.0.1` keep their
  /// host (and so the TLS name); another 127/8 address becomes `127.0.0.1`
  /// only for plain HTTP. A privileged port moves up by 40000. IPv6
  /// loopback is refused (the tunnel listens on IPv4).
  public static func plan(_ hostURL: URL) throws -> LocalEndpointPlan {
    let url = EndpointURL(hostURL)
    let shown = url.serialized
    let hostAddress: IPv4Address
    let needsRewrite: Bool
    if url.host.lowercased() == "localhost" {
      hostAddress = try! IPv4Address("127.0.0.1")
      needsRewrite = false
    } else if let ipv4 = try? IPv4Address(url.host), ipv4.octets[0] == 127 {
      hostAddress = ipv4
      needsRewrite = ipv4.description != "127.0.0.1"
    } else if url.isIPv6Loopback {
      throw HostError(
        "Local model endpoint \(shown) uses IPv6 loopback, which this backend cannot tunnel into the guest; use http://127.0.0.1:<port> instead"
      )
    } else {
      return LocalEndpointPlan(guestURL: shown, tunnel: nil)
    }
    guard let hostPort = url.port ?? url.defaultPort else {
      throw HostError("Local model endpoint \(shown) has no port")
    }
    let guestPort = hostPort < 1024 ? hostPort + privilegedPortOffset : hostPort
    var guest = url
    if needsRewrite {
      guard url.scheme == "http" else {
        throw HostError(
          "Local model endpoint \(shown) would need its host rewritten to 127.0.0.1, which changes the TLS server name; use https://localhost:\(hostPort) or https://127.0.0.1:\(hostPort) instead"
        )
      }
      guest.host = "127.0.0.1"
    }
    if guestPort != hostPort { guest.port = guestPort }
    return LocalEndpointPlan(
      guestURL: guest.serialized,
      tunnel: ReverseTunnel(guestPort: guestPort, hostAddress: hostAddress, hostPort: hostPort))
  }

  /// Gate a resolved endpoint on local mode.
  public static func active(_ state: ModelState, _ resolved: LocalModel?) -> LocalModel? {
    state.mode == .local ? resolved : nil
  }

  /// Every tunnel the current model configuration needs, keyed by guest
  /// port. Two endpoints on one guest port must share a destination.
  public static func tunnels(_ state: ModelState, config: IsoConfig) throws -> [UInt16:
    ReverseTunnel]
  {
    var tunnels: [UInt16: ReverseTunnel] = [:]
    for endpoint in [
      active(state, state.resolvedClaude(config.claude)),
      active(state, state.resolvedCodex(config.codex)),
    ] {
      guard let endpoint, let tunnel = try plan(endpoint.hostURL).tunnel else { continue }
      if let other = tunnels[tunnel.guestPort], other != tunnel {
        throw HostError(
          "Local model endpoints \(other.hostAddress):\(other.hostPort) and \(tunnel.hostAddress):\(tunnel.hostPort) both need guest port \(tunnel.guestPort); use distinct ports"
        )
      }
      tunnels[tunnel.guestPort] = tunnel
    }
    return tunnels
  }
}

/// An http(s) URL printed as the Rust `url` crate does: lowercase scheme
/// and host, default port omitted, empty path as `/`.
struct EndpointURL: Sendable, Equatable {
  var scheme: String
  var userinfo: String?
  var host: String
  var port: UInt16?
  var path: String
  var query: String?
  var fragment: String?

  init(_ url: URL) {
    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    scheme = (components?.scheme ?? url.scheme ?? "").lowercased()
    var host = components?.percentEncodedHost ?? url.host(percentEncoded: true) ?? ""
    if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    self.host = host.lowercased()
    if let user = components?.percentEncodedUser {
      userinfo = user + (components?.percentEncodedPassword.map { ":" + $0 } ?? "")
    }
    port = components?.port.flatMap { UInt16(exactly: $0) }
    path = components?.percentEncodedPath ?? ""
    query = components?.percentEncodedQuery
    fragment = components?.percentEncodedFragment
    if port == defaultPort { port = nil }
  }

  var defaultPort: UInt16? {
    switch scheme {
    case "http": 80
    case "https": 443
    default: nil
    }
  }

  var isIPv6Loopback: Bool {
    guard host.contains(":") else { return false }
    var address = in6_addr()
    guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
    return withUnsafeBytes(of: &address) {
      $0.elementsEqual([UInt8](repeating: 0, count: 15) + [1])
    }
  }

  var serialized: String {
    var out = scheme + "://"
    if let userinfo { out += userinfo + "@" }
    out += host.contains(":") ? "[\(host)]" : host
    if let port { out += ":\(port)" }
    out += path.isEmpty ? "/" : path
    if let query { out += "?" + query }
    if let fragment { out += "#" + fragment }
    return out
  }
}
