// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoCore

/// A host filesystem path from configuration with a leading `~` component
/// expanded at construction, so every path field is expanded on every load.
public struct HostPath: Hashable, Sendable, CustomStringConvertible {
  public let path: String

  public init(expanding raw: String, home: String?) {
    if let home, raw == "~" || raw.hasPrefix("~/") {
      let rest = raw.dropFirst().drop(while: { $0 == "/" })
      path = rest.isEmpty ? home : (home.hasSuffix("/") ? home + rest : home + "/" + rest)
    } else {
      path = raw
    }
  }

  public init(absolute path: String) { self.path = path }

  public func appending(_ component: String) -> HostPath {
    HostPath(absolute: path.hasSuffix("/") ? path + component : path + "/" + component)
  }

  public var parent: HostPath? {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent().path
    return parent == path ? nil : HostPath(absolute: parent)
  }

  public var description: String { path }
}

/// Host facts configuration loading may read. Injected so tests and fuzzing
/// never observe the developer's home directory or environment.
public struct ConfigEnvironment: Sendable {
  public var home: String?
  public var variables: [String: String]

  public init(home: String?, variables: [String: String]) {
    self.home = home
    self.variables = variables
  }

  public static var process: ConfigEnvironment {
    let variables = ProcessInfo.processInfo.environment
    let home = variables["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    return ConfigEnvironment(home: home, variables: variables)
  }

  public static let empty = ConfigEnvironment(home: nil, variables: [:])
}

/// The validated, immutable configuration a command runs with (S-02).
/// Credential references are carried unresolved; nothing here executes them.
public struct IsoConfig: Sendable, Equatable {
  public let dataDirectory: HostPath
  public let vm: VMConfig
  public let sshPort: UInt16
  public let github: GitHubAuth?
  public let setup: SetupConfig
  public let claude: AgentConfig
  public let codex: AgentConfig
  public let codexAuth: CodexAuthMode
  public let proxy: ProxyConfig
  /// Literal guest variables in byte order of name (Rust `BTreeMap` order).
  public let guestEnvironment: [GuestVariable]
  public let profiles: [String: CustomProfile]
  public let postStart: String?
  public let forwardPorts: [PortForward]
  public let updates: UpdateConfig
  public let appleContainer: AppleContainerConfig
  public let workspacePull: WorkspacePullConfig
  public let egress: EgressMode
  /// Empty unless `egress` is `filtered`.
  public let egressFilter: EgressFilter
  public let limits: LimitsConfig
  /// The preset whose defaults this configuration was decoded with.
  public let securityPreset: SecurityPreset?

  public init(
    dataDirectory: HostPath, vm: VMConfig, sshPort: UInt16, github: GitHubAuth?,
    setup: SetupConfig, claude: AgentConfig, codex: AgentConfig, codexAuth: CodexAuthMode,
    proxy: ProxyConfig, guestEnvironment: [GuestVariable], profiles: [String: CustomProfile],
    postStart: String?, forwardPorts: [PortForward], updates: UpdateConfig,
    appleContainer: AppleContainerConfig, workspacePull: WorkspacePullConfig, egress: EgressMode,
    egressFilter: EgressFilter = .empty, limits: LimitsConfig, securityPreset: SecurityPreset?
  ) {
    self.dataDirectory = dataDirectory
    self.vm = vm
    self.sshPort = sshPort
    self.github = github
    self.setup = setup
    self.claude = claude
    self.codex = codex
    self.codexAuth = codexAuth
    self.proxy = proxy
    self.guestEnvironment = guestEnvironment
    self.profiles = profiles
    self.postStart = postStart
    self.forwardPorts = forwardPorts
    self.updates = updates
    self.appleContainer = appleContainer
    self.workspacePull = workspacePull
    self.egress = egress
    self.egressFilter = egressFilter
    self.limits = limits
    self.securityPreset = securityPreset
  }

  /// Subdirectory of `data_dir` owned by the Apple backend.
  public static let backendRoot = "backends/apple-container-v1"

  public var stateRoot: HostPath { dataDirectory.appending(Self.backendRoot) }
  public var imagesDirectory: HostPath { stateRoot.appending("images") }
  public var instancesDirectory: HostPath { stateRoot.appending("instances") }
  public var sshKeyPath: HostPath { stateRoot.appending("vm_key") }
}

public struct GuestVariable: Sendable, Equatable {
  public let name: EnvVarName
  public let value: String
}

public struct VMConfig: Sendable, Equatable {
  public let vcpuCount: UInt8
  public let memory: VmMemory
  public let templateSize: GiB

  public static let defaults = VMConfig(
    vcpuCount: 2, memory: try! VmMemory(MiB(4096)!), templateSize: GiB(8)!)
}

public struct SetupConfig: Sendable, Equatable {
  public let promptForPAT: Bool
}

public enum GitHubAuth: Sendable, Equatable {
  case auto
  case env
  case off
  case pat(PATConfig)

  public var modeName: String {
    switch self {
    case .auto: "auto"
    case .env: "env"
    case .off: "off"
    case .pat: "pat"
    }
  }
}

public struct PATConfig: Sendable, Equatable {
  /// Per-repo tokens: a literal or a `cmd:` reference, resolved on use.
  public let entries: [RepoSlug: Secret<String>]
  public let skip: [RepoSlug]
}

public enum ConfigDirectory: Sendable, Equatable {
  case `default`
  case custom(HostPath)
  case disabled
}

public enum MCPServer: Sendable, Equatable {
  case stdio(command: String, args: [String], env: [EnvVarName: EnvVarName])
  case http(url: URL, headers: [String: Secret<String>])
  case sse(url: URL, headers: [String: Secret<String>])
}

public struct LocalModel: Sendable, Equatable {
  public let hostURL: URL
  public let model: String
  public let authToken: Secret<String>?

  public static let authFallback = "iso-local"

  public init(hostURL: String, model: String, authToken: Secret<String>?) throws(ValidationError) {
    guard !model.trimmingUnicodeWhitespace().isEmpty else {
      throw ValidationError("local model 'model' must not be empty")
    }
    guard let url = URL(string: hostURL), let scheme = url.scheme?.lowercased() else {
      throw ValidationError("local model host_url '\(hostURL)' is not a valid URL")
    }
    guard scheme == "http" || scheme == "https" else {
      throw ValidationError("local model host_url '\(hostURL)' must use http or https")
    }
    guard let host = url.host(percentEncoded: true), !host.isEmpty else {
      throw ValidationError("local model host_url '\(hostURL)' has no host")
    }
    self.hostURL = url
    self.model = model
    self.authToken = authToken
  }
}

/// Settings shared by the `claude` and `codex` sections.
public struct AgentConfig: Sendable, Equatable {
  /// Configured key, or for an absent section the provider's environment
  /// variable (the baseline default). A `cmd:` value is resolved on use.
  public let apiKey: Secret<String>?
  public let envForward: [EnvVarName]
  public let marketplaces: [String]
  public let plugins: [String]
  public let mcpServers: [String: MCPServer]
  public let configDirectory: ConfigDirectory
  public let localModel: LocalModel?
}

public enum CodexAuthMode: String, Sendable, Equatable {
  case apiKey = "api_key"
  case chatgpt
}

public enum ProxyAuthScheme: String, Sendable, Equatable {
  case apiKey = "api_key"
  case bearer

  /// The injection name in iso-proxy's startup document and guest_env.json.
  public var wireName: String { self == .apiKey ? "x_api_key" : "bearer" }
}

public enum ProxyProvider: String, Sendable, CaseIterable {
  case anthropic
  case openai

  /// Guest variables that carry this provider's credential, with the
  /// injection scheme each one's value uses. The one table for both
  /// withholding (none reaches the guest raw with a proxy or under
  /// `proxy.mode = "required"`) and routing stored secrets to the proxy.
  public var credentialVariables: [(name: String, auth: ProxyAuthScheme)] {
    switch self {
    case .anthropic:
      [
        ("ANTHROPIC_API_KEY", .apiKey), ("ANTHROPIC_AUTH_TOKEN", .bearer),
        ("CLAUDE_CODE_OAUTH_TOKEN", .bearer),
      ]
    case .openai: [("OPENAI_API_KEY", .bearer)]
    }
  }

  public var recognizedVariables: [String] { credentialVariables.map(\.name) }

  /// The provider and scheme a credential variable routes to, if any.
  public static func route(forVariable name: String) -> (ProxyProvider, ProxyAuthScheme)? {
    for provider in allCases {
      if let entry = provider.credentialVariables.first(where: { $0.name == name }) {
        return (provider, entry.auth)
      }
    }
    return nil
  }
}

/// `proxy.mode` (selective-hardening spec §7.5).
public enum ProxyMode: String, Sendable, Equatable {
  /// A configured provider runs through its proxy; others keep the legacy
  /// raw forwarding.
  case auto
  /// No recognized provider variable reaches the guest by any path, and a
  /// remote-model VM must have at least one provider proxy.
  case required
  /// No proxy starts; configured upstreams are ignored.
  case off
}

/// A provider credential reference. Literal credentials are not
/// representable: construction requires a `cmd:` command or a `vault:<name>`
/// reference to the local secret store (C-04, embedded-secrets D-003).
public struct CredentialReference: Sendable, Equatable, CustomStringConvertible {
  /// The reference text (`cmd:…` or `vault:…`), never a secret itself.
  public let command: Secret<String>

  public init?(_ value: String) {
    guard value.hasPrefix("cmd:") || value.hasPrefix("vault:") else { return nil }
    command = Secret(value)
  }

  public var description: String {
    command.expose().hasPrefix("vault:") ? command.expose() : "cmd:<redacted>"
  }
}

public struct ProxyUpstream: Sendable, Equatable {
  public let credential: CredentialReference
  public let auth: ProxyAuthScheme
}

public struct ProxyConfig: Sendable, Equatable {
  public let anthropic: ProxyUpstream?
  public let openai: ProxyUpstream?
  public let mode: ProxyMode

  public init(anthropic: ProxyUpstream?, openai: ProxyUpstream?, mode: ProxyMode = .auto) {
    self.anthropic = anthropic
    self.openai = openai
    self.mode = mode
  }

  /// Secret-store names the configured upstreams read (`vault:NAME`).
  public var storedCredentialNames: Set<SecretName> {
    Set(
      [anthropic, openai].compactMap {
        SecretName.vaultReference($0?.credential.command.expose() ?? "")
      })
  }

  public func upstream(for provider: ProxyProvider) -> ProxyUpstream? {
    switch provider {
    case .anthropic: anthropic
    case .openai: openai
    }
  }
}

public struct CustomProfile: Sendable, Equatable {
  public let aptPackages: [String]
  public let preInstall: String?
  public let postInstall: String?
  public let marketplaces: [String]
  public let plugins: [String]
}

public enum UpdateMode: String, Sendable, Equatable {
  case off
  case notify
}

public struct UpdateConfig: Sendable, Equatable {
  public let mode: UpdateMode
  public let checkIntervalHours: UInt64
}

public struct AppleContainerConfig: Sendable, Equatable {
  public let binary: HostPath?
  public let builder: HostPath?
  public let kernel: HostPath?
  public let probeTimeout: TimeoutSecs
  public let operationTimeout: TimeoutSecs
  public let createTimeout: TimeoutSecs
  public let bootTimeout: TimeoutSecs
  public let stopTimeout: TimeoutSecs
  public let buildTimeout: TimeoutSecs
}

/// Guest network reach beyond the host (selective-hardening spec §6). Fixed
/// per instance when its sandbox is created.
public enum EgressMode: String, Sendable, Equatable {
  /// NAT to the host's uplinks, as before.
  case open
  /// vmnet host mode: no route beyond the host and no DNS. Host→guest SSH
  /// and iso's SSH tunnels (credential proxy, local models, port forwards)
  /// still work; the guest can still reach services on the host itself.
  case none
  /// Host-only VM plus a separate CONNECT companion. Not a credential
  /// control: provider keys still follow `proxy.mode`.
  case filtered

  /// `none` and `filtered` both use the runtime's host-only network.
  public var requiresHostOnlyNetwork: Bool { self != .open }
}

/// Approved exact hostnames for `egress: filtered`. Empty means no general
/// destinations. Hints from an agent definition are not part of this set.
public struct EgressFilter: Sendable, Equatable {
  public static let maxHosts = 256
  public let allowedHosts: [ExactHostname]

  public init(allowedHosts: [ExactHostname]) {
    var seen: Set<String> = []
    var ordered: [ExactHostname] = []
    for host in allowedHosts where seen.insert(host.rawValue).inserted {
      ordered.append(host)
    }
    self.allowedHosts = ordered.sorted { $0.rawValue < $1.rawValue }
  }

  public static let empty = EgressFilter(allowedHosts: [])

  public func allowing(_ extra: [ExactHostname]) -> EgressFilter {
    EgressFilter(allowedHosts: allowedHosts + extra)
  }
}

/// `security.preset` (selective-hardening spec §10): defaults for the
/// hardening settings. A field written explicitly always wins.
public enum SecurityPreset: String, Sendable, Equatable, CaseIterable {
  /// Today's defaults: open egress, `proxy.mode` auto, direct pulls.
  case networked
  /// No egress, provider credentials only through the proxy, staged pulls.
  case providerOnly = "provider-only"
  /// No egress, no provider proxy, staged pulls.
  case offline

  var egress: EgressMode { self == .networked ? .open : .none }
  var proxyMode: ProxyMode {
    switch self {
    case .networked: .auto
    case .providerOnly: .required
    case .offline: .off
    }
  }
  var pullMode: WorkspacePullMode { self == .networked ? .direct : .stage }
}

/// `limits` (selective-hardening spec §8).
public struct LimitsConfig: Sendable, Equatable {
  /// Each boot ends this long after it starts, enforced by the sandbox owner
  /// on the host clock. nil: no limit.
  public let sessionTTL: SessionTTL?

  public init(sessionTTL: SessionTTL?) { self.sessionTTL = sessionTTL }

  public static let none = LimitsConfig(sessionTTL: nil)
}

/// How `iso pull` returns guest files: straight into the destination
/// (`direct`, the historical behavior) or through a reviewed stage.
public enum WorkspacePullMode: String, Sendable, Equatable {
  case direct
  case stage
}

/// Hard budgets a stage must fit before it can be applied.
public struct StageLimits: Sendable, Equatable {
  /// Staged entries of any type.
  public let maxFiles: UInt64
  /// Total regular-file bytes.
  public let maxBytes: ByteCount
  /// Largest single regular file.
  public let maxFileBytes: ByteCount

  public init(maxFiles: UInt64, maxBytes: ByteCount, maxFileBytes: ByteCount) {
    self.maxFiles = maxFiles
    self.maxBytes = maxBytes
    self.maxFileBytes = maxFileBytes
  }

  public static let defaults = StageLimits(
    maxFiles: 50_000, maxBytes: ByteCount(bytes: 1 << 30)!,
    maxFileBytes: ByteCount(bytes: 256 << 20)!)
}

/// `workspace.pull`.
public struct WorkspacePullConfig: Sendable, Equatable {
  public let mode: WorkspacePullMode
  public let limits: StageLimits

  public init(mode: WorkspacePullMode, limits: StageLimits) {
    self.mode = mode
    self.limits = limits
  }

  public static let defaults = WorkspacePullConfig(mode: .direct, limits: .defaults)
}

extension IsoConfig {
  /// One command's CLI overrides of `vm`; the file is never rewritten.
  public func overridingVM(vcpus: UInt8?, memory: VmMemory?, templateSize: GiB?) -> IsoConfig {
    let vm = VMConfig(
      vcpuCount: vcpus ?? self.vm.vcpuCount, memory: memory ?? self.vm.memory,
      templateSize: templateSize ?? self.vm.templateSize)
    return IsoConfig(
      dataDirectory: dataDirectory, vm: vm,
      sshPort: sshPort,
      github: github, setup: setup, claude: claude, codex: codex, codexAuth: codexAuth,
      proxy: proxy,
      guestEnvironment: guestEnvironment, profiles: profiles, postStart: postStart,
      forwardPorts: forwardPorts,
      updates: updates, appleContainer: appleContainer, workspacePull: workspacePull,
      egress: egress, egressFilter: egressFilter, limits: limits, securityPreset: securityPreset
    )
  }

  /// This command's egress override. Does not rewrite the config file.
  public func overridingEgress(_ mode: EgressMode, extraHosts: [ExactHostname] = []) -> IsoConfig {
    let filter = mode == .filtered ? egressFilter.allowing(extraHosts) : .empty
    return IsoConfig(
      dataDirectory: dataDirectory, vm: vm, sshPort: sshPort, github: github, setup: setup,
      claude: claude, codex: codex, codexAuth: codexAuth, proxy: proxy,
      guestEnvironment: guestEnvironment, profiles: profiles, postStart: postStart,
      forwardPorts: forwardPorts, updates: updates, appleContainer: appleContainer,
      workspacePull: workspacePull, egress: mode, egressFilter: filter, limits: limits,
      securityPreset: securityPreset)
  }
}
