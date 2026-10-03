// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoCore

/// A host filesystem path from configuration with a leading `~` component
/// expanded at construction, so every path field is expanded on every load.
package struct HostPath: Hashable, Sendable, CustomStringConvertible {
  package let path: String

  package init(expanding raw: String, home: String?) {
    if let home, raw == "~" || raw.hasPrefix("~/") {
      let rest = raw.dropFirst().drop(while: { $0 == "/" })
      path = rest.isEmpty ? home : (home.hasSuffix("/") ? home + rest : home + "/" + rest)
    } else {
      path = raw
    }
  }

  package init(absolute path: String) { self.path = path }

  package func appending(_ component: String) -> HostPath {
    HostPath(absolute: path.hasSuffix("/") ? path + component : path + "/" + component)
  }

  package var parent: HostPath? {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent().path
    return parent == path ? nil : HostPath(absolute: parent)
  }

  package var description: String { path }
}

/// Host facts configuration loading may read. Injected so tests and fuzzing
/// never observe the developer's home directory or environment.
package struct ConfigEnvironment: Sendable {
  package var home: String?
  package var variables: [String: String]

  package init(home: String?, variables: [String: String]) {
    self.home = home
    self.variables = variables
  }

  package static var process: ConfigEnvironment {
    let variables = ProcessInfo.processInfo.environment
    let home = variables["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    return ConfigEnvironment(home: home, variables: variables)
  }

  package static let empty = ConfigEnvironment(home: nil, variables: [:])
}

/// The validated, immutable configuration a command runs with (S-02).
/// Credential references are carried unresolved; nothing here executes them.
package struct IsoConfig: Sendable, Equatable {
  package let dataDirectory: HostPath
  package let vm: VMConfig
  package let sshPort: UInt16
  package let github: GitHubAuth?
  package let setup: SetupConfig
  package let claude: AgentConfig
  package let codex: AgentConfig
  package let codexAuth: CodexAuthMode
  package let proxy: ProxyConfig
  /// Literal guest variables in byte order of name (Rust `BTreeMap` order).
  package let guestEnvironment: [GuestVariable]
  package let profiles: [String: CustomProfile]
  package let postStart: String?
  package let forwardPorts: [PortForward]
  package let updates: UpdateConfig
  package let appleContainer: AppleContainerConfig
  package let workspacePull: WorkspacePullConfig
  package let egress: EgressMode
  /// Empty unless `egress` is `filtered`.
  package let egressFilter: EgressFilter
  package let limits: LimitsConfig
  /// The preset whose defaults this configuration was decoded with.
  package let securityPreset: SecurityPreset?

  package init(
    dataDirectory: HostPath, vm: VMConfig, sshPort: UInt16, github: GitHubAuth?,
    setup: SetupConfig, claude: AgentConfig, codex: AgentConfig, codexAuth: CodexAuthMode,
    proxy: ProxyConfig, guestEnvironment: [GuestVariable], profiles: [String: CustomProfile],
    postStart: String?, forwardPorts: [PortForward], updates: UpdateConfig,
    appleContainer: AppleContainerConfig, workspacePull: WorkspacePullConfig, egress: EgressMode,
    egressFilter: EgressFilter, limits: LimitsConfig, securityPreset: SecurityPreset?
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
  package static let backendRoot = "backends/apple-container-v1"

  package var stateRoot: HostPath { dataDirectory.appending(Self.backendRoot) }
  package var imagesDirectory: HostPath { stateRoot.appending("images") }
  package var instancesDirectory: HostPath { stateRoot.appending("instances") }
  package var sshKeyPath: HostPath { stateRoot.appending("vm_key") }
}

package struct GuestVariable: Sendable, Equatable {
  package let name: EnvVarName
  package let value: String
}

package struct VMConfig: Sendable, Equatable {
  package let vcpuCount: UInt8
  package let memory: VmMemory
  package let templateSize: GiB

  package static let defaults = VMConfig(
    vcpuCount: 2, memory: try! VmMemory(MiB(4096)!), templateSize: GiB(8)!)
}

package struct SetupConfig: Sendable, Equatable {
  package let promptForPAT: Bool
}

package enum GitHubAuth: Sendable, Equatable {
  case auto
  case env
  case off
  case pat(PATConfig)

  package var modeName: String {
    switch self {
    case .auto: "auto"
    case .env: "env"
    case .off: "off"
    case .pat: "pat"
    }
  }
}

package struct PATConfig: Sendable, Equatable {
  /// Per-repo tokens: a literal or a `cmd:` reference, resolved on use.
  package let entries: [RepoSlug: Secret<String>]
  package let skip: [RepoSlug]
}

package enum ConfigDirectory: Sendable, Equatable {
  case `default`
  case custom(HostPath)
  case disabled
}

package enum MCPServer: Sendable, Equatable {
  case stdio(command: String, args: [String], env: [EnvVarName: EnvVarName])
  case http(url: URL, headers: [String: Secret<String>])
  case sse(url: URL, headers: [String: Secret<String>])
}

package struct LocalModel: Sendable, Equatable {
  package let hostURL: URL
  package let model: String
  package let authToken: Secret<String>?

  package static let authFallback = "iso-local"

  package init(hostURL: String, model: String, authToken: Secret<String>?) throws(ValidationError) {
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
package struct AgentConfig: Sendable, Equatable {
  /// Configured key, or for an absent section the provider's environment
  /// variable (the baseline default). A `cmd:` value is resolved on use.
  package let apiKey: Secret<String>?
  package let envForward: [EnvVarName]
  package let marketplaces: [String]
  package let plugins: [String]
  package let mcpServers: [String: MCPServer]
  package let configDirectory: ConfigDirectory
  package let localModel: LocalModel?
}

package enum CodexAuthMode: String, Sendable, Equatable {
  case apiKey = "api_key"
  case chatgpt
}

package enum ProxyAuthScheme: String, Sendable, Equatable {
  case apiKey = "api_key"
  case bearer

  /// The injection name in iso-proxy's startup document and guest_env.json.
  package var wireName: String { self == .apiKey ? "x_api_key" : "bearer" }
}

package enum ProxyProvider: String, Sendable, CaseIterable {
  case anthropic
  case openai

  /// Guest variables that carry this provider's credential, with the
  /// injection scheme each one's value uses. The one table for both
  /// withholding (none reaches the guest raw with a proxy or under
  /// `proxy.mode = "required"`) and routing stored secrets to the proxy.
  package var credentialVariables: [(name: String, auth: ProxyAuthScheme)] {
    switch self {
    case .anthropic:
      [
        ("ANTHROPIC_API_KEY", .apiKey), ("ANTHROPIC_AUTH_TOKEN", .bearer),
        ("CLAUDE_CODE_OAUTH_TOKEN", .bearer),
      ]
    case .openai: [("OPENAI_API_KEY", .bearer)]
    }
  }

  package var recognizedVariables: [String] { credentialVariables.map(\.name) }

  /// The provider and scheme a credential variable routes to, if any.
  package static func route(forVariable name: String) -> (ProxyProvider, ProxyAuthScheme)? {
    for provider in allCases {
      if let entry = provider.credentialVariables.first(where: { $0.name == name }) {
        return (provider, entry.auth)
      }
    }
    return nil
  }
}

/// `proxy.mode` (selective-hardening spec §7.5).
package enum ProxyMode: String, Sendable, Equatable {
  /// A configured provider runs through its proxy; other providers use
  /// direct credential forwarding.
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
package struct CredentialReference: Sendable, Equatable, CustomStringConvertible {
  /// The reference text (`cmd:…` or `vault:…`), never a secret itself.
  package let command: Secret<String>

  package init?(_ value: String) {
    guard value.hasPrefix("cmd:") || value.hasPrefix("vault:") else { return nil }
    command = Secret(value)
  }

  package var description: String {
    command.expose().hasPrefix("vault:") ? command.expose() : "cmd:<redacted>"
  }
}

package struct ProxyUpstream: Sendable, Equatable {
  package let credential: CredentialReference
  package let auth: ProxyAuthScheme
}

package struct ProxyConfig: Sendable, Equatable {
  package let anthropic: ProxyUpstream?
  package let openai: ProxyUpstream?
  package let mode: ProxyMode

  package init(anthropic: ProxyUpstream?, openai: ProxyUpstream?, mode: ProxyMode = .auto) {
    self.anthropic = anthropic
    self.openai = openai
    self.mode = mode
  }

  /// Secret-store names the configured upstreams read (`vault:NAME`).
  package var storedCredentialNames: Set<SecretName> {
    Set(
      [anthropic, openai].compactMap {
        SecretName.vaultReference($0?.credential.command.expose() ?? "")
      })
  }

  package func upstream(for provider: ProxyProvider) -> ProxyUpstream? {
    switch provider {
    case .anthropic: anthropic
    case .openai: openai
    }
  }
}

package struct CustomProfile: Sendable, Equatable {
  package let aptPackages: [String]
  package let preInstall: String?
  package let postInstall: String?
  package let marketplaces: [String]
  package let plugins: [String]
}

package enum UpdateMode: String, Sendable, Equatable {
  case off
  case notify
}

package struct UpdateConfig: Sendable, Equatable {
  package let mode: UpdateMode
  package let checkIntervalHours: UInt64
}

package struct AppleContainerConfig: Sendable, Equatable {
  package let binary: HostPath?
  package let builder: HostPath?
  package let kernel: HostPath?
  package let probeTimeout: TimeoutSecs
  package let operationTimeout: TimeoutSecs
  package let createTimeout: TimeoutSecs
  package let bootTimeout: TimeoutSecs
  package let stopTimeout: TimeoutSecs
  package let buildTimeout: TimeoutSecs
}

/// Guest network reach beyond the host (selective-hardening spec §6). Fixed
/// per instance when its sandbox is created.
package enum EgressMode: String, Sendable, Equatable {
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
  package var requiresHostOnlyNetwork: Bool { self != .open }
}

/// Approved exact hostnames for `egress: filtered`. Empty means no general
/// destinations. Hints from an agent definition are not part of this set.
package struct EgressFilter: Sendable, Equatable {
  package static let maxHosts = 256
  package let allowedHosts: [ExactHostname]

  package init(allowedHosts: [ExactHostname]) {
    var seen: Set<String> = []
    var ordered: [ExactHostname] = []
    for host in allowedHosts where seen.insert(host.rawValue).inserted {
      ordered.append(host)
    }
    self.allowedHosts = ordered.sorted { $0.rawValue < $1.rawValue }
  }

  package static let empty = EgressFilter(allowedHosts: [])

  package func allowing(_ extra: [ExactHostname]) -> EgressFilter {
    EgressFilter(allowedHosts: allowedHosts + extra)
  }
}

/// `security.preset` (selective-hardening spec §10): defaults for the
/// hardening settings. A field written explicitly always wins.
package enum SecurityPreset: String, Sendable, Equatable, CaseIterable {
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
package struct LimitsConfig: Sendable, Equatable {
  /// Each boot ends this long after it starts, enforced by the sandbox owner
  /// on the host clock. nil: no limit.
  package let sessionTTL: SessionTTL?

  package init(sessionTTL: SessionTTL?) { self.sessionTTL = sessionTTL }

  package static let none = LimitsConfig(sessionTTL: nil)
}

/// How `iso pull` returns guest files: straight into the destination
/// (`direct`, the historical behavior) or through a reviewed stage.
package enum WorkspacePullMode: String, Sendable, Equatable {
  case direct
  case stage
}

/// Hard budgets a stage must fit before it can be applied.
package struct StageLimits: Sendable, Equatable {
  /// Staged entries of any type.
  package let maxFiles: UInt64
  /// Total regular-file bytes.
  package let maxBytes: ByteCount
  /// Largest single regular file.
  package let maxFileBytes: ByteCount

  package init(maxFiles: UInt64, maxBytes: ByteCount, maxFileBytes: ByteCount) {
    self.maxFiles = maxFiles
    self.maxBytes = maxBytes
    self.maxFileBytes = maxFileBytes
  }

  package static let defaults = StageLimits(
    maxFiles: 50_000, maxBytes: ByteCount(bytes: 1 << 30)!,
    maxFileBytes: ByteCount(bytes: 256 << 20)!)
}

/// `workspace.pull`.
package struct WorkspacePullConfig: Sendable, Equatable {
  package let mode: WorkspacePullMode
  package let limits: StageLimits

  package init(mode: WorkspacePullMode, limits: StageLimits) {
    self.mode = mode
    self.limits = limits
  }

  package static let defaults = WorkspacePullConfig(mode: .direct, limits: .defaults)
}

extension IsoConfig {
  /// One command's CLI overrides of `vm`; the file is never rewritten.
  package func overridingVM(vcpus: UInt8?, memory: VmMemory?, templateSize: GiB?) -> IsoConfig {
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
  package func overridingEgress(_ mode: EgressMode, extraHosts: [ExactHostname] = []) -> IsoConfig {
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
