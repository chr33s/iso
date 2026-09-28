import CoopCore
import Foundation

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
public struct CoopConfig: Sendable, Equatable {
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

  public static let authFallback = "coop-local"

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
}

public enum ProxyProvider: String, Sendable, CaseIterable {
  case anthropic
  case openai
}

/// A provider credential reference. Literal credentials are not
/// representable: construction requires a `cmd:` reference (C-04).
public struct CredentialReference: Sendable, Equatable, CustomStringConvertible {
  public let command: Secret<String>

  public init?(_ value: String) {
    guard value.hasPrefix("cmd:") else { return nil }
    command = Secret(value)
  }

  public var description: String { "cmd:<redacted>" }
}

public struct ProxyUpstream: Sendable, Equatable {
  public let credential: CredentialReference
  public let auth: ProxyAuthScheme
}

public struct ProxyConfig: Sendable, Equatable {
  public let anthropic: ProxyUpstream?
  public let openai: ProxyUpstream?

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

extension CoopConfig {
  /// One command's CLI overrides of `vm`; the file is never rewritten.
  public func overridingVM(vcpus: UInt8?, memory: VmMemory?, templateSize: GiB?) -> CoopConfig {
    let vm = VMConfig(
      vcpuCount: vcpus ?? self.vm.vcpuCount, memory: memory ?? self.vm.memory,
      templateSize: templateSize ?? self.vm.templateSize)
    return CoopConfig(
      dataDirectory: dataDirectory, vm: vm,
      sshPort: sshPort,
      github: github, setup: setup, claude: claude, codex: codex, codexAuth: codexAuth,
      proxy: proxy,
      guestEnvironment: guestEnvironment, profiles: profiles, postStart: postStart,
      forwardPorts: forwardPorts,
      updates: updates, appleContainer: appleContainer)
  }
}
