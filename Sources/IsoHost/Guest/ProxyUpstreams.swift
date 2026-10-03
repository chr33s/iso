// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

extension ProxyProvider {
  /// 1000 apart so the per-instance ranges (index 0...252) never overlap.
  var basePort: UInt16 {
    switch self {
    case .anthropic: 8788
    case .openai: 9788
    }
  }

  /// Host-loopback listen port: base + instance index.
  func port(_ instance: Instance) -> UInt16 {
    basePort &+ instance.index.value
  }

  /// Codex forwards the capability token through `SendEnv` on later
  /// sessions, so it is kept on host disk; Claude's rides in the guest
  /// `settings.json` and stays in memory.
  var persistsToken: Bool { self == .openai }

  /// Keychain service name used by `iso proxy setup`.
  package var keychainService: String {
    switch self {
    case .anthropic: "iso-anthropic"
    case .openai: "iso-openai"
    }
  }
}

/// The upstream a VM's proxy uses for one provider.
package struct EffectiveUpstream: Sendable, Equatable {
  package let credential: CredentialReference
  package let auth: ProxyAuthScheme

  package init(credential: CredentialReference, auth: ProxyAuthScheme) {
    self.credential = credential
    self.auth = auth
  }
}

extension ProxyState {
  /// `proxy.mode = "off"` → none; otherwise override → configuration
  /// default → off. Stored overrides contain validated credential references.
  package func effective(_ provider: ProxyProvider, config: ProxyConfig)
    -> EffectiveUpstream?
  {
    guard config.mode != .off else { return nil }
    if let stored = override(for: provider) {
      return EffectiveUpstream(credential: stored.credential, auth: stored.auth)
    }
    return config.upstream(for: provider).map {
      EffectiveUpstream(credential: $0.credential, auth: $0.auth)
    }
  }

  /// A `--env`/`--env-file` provider secret for this instance first, then
  /// the per-VM override and the configuration default (D-003).
  package static func effectiveUpstream(
    _ instance: Instance, _ provider: ProxyProvider, config: ProxyConfig
  ) throws -> EffectiveUpstream? {
    if let routed = try GuestEnvState.tryLoad(instance)?.providerSecrets()[provider] {
      guard config.mode != .off else { throw unavailable(routed) }
      return EffectiveUpstream(
        credential: CredentialReference("vault:\(routed.name)")!, auth: routed.auth)
    }
    return try load(instance).effective(provider, config: config)
  }

  /// A provider secret under `proxy.mode = "off"`: unavailable, never
  /// forwarded into the guest instead.
  package static func unavailable(_ routed: GuestEnvState.ProviderSecret) -> HostError {
    HostError(
      "\(routed.variable)={vault:\(routed.name)} is a provider credential for iso-proxy, but proxy.mode is \"off\"; it is not forwarded into the guest. Set proxy.mode to \"auto\" or remove it."
    )
  }

  /// Record a per-VM override. The other provider's member is carried over
  /// as stored (it may be a literal awaiting remediation, which is neither
  /// read into a credential nor printed); unknown members are dropped, as
  /// the Rust round trip did. Owner-only.
  package static func setOverride(
    _ instance: Instance, provider: ProxyProvider, credential: CredentialReference,
    auth: ProxyAuthScheme
  ) throws {
    _ = try load(instance)  // refuse to rewrite a malformed file
    var raw: [String: JSONValue] = [:]
    if let bytes = try StateStore.readControlFile(instance.proxyStatePath),
      case .object(let members) = try ConfigLoader.parse(
        bytes, format: .json, path: instance.proxyStatePath, limits: .configuration)
    {
      raw = members
    }
    raw[provider.rawValue] = .object([
      "credential": .string(credential.command.expose()), "auth": .string(auth.rawValue),
    ])
    var members: [(String, OutputJSON)] = []
    for provider in ProxyProvider.allCases {
      guard case .object(let entry)? = raw[provider.rawValue] else { continue }
      var fields: [(String, OutputJSON)] = []
      if case .string(let credential)? = entry["credential"] {
        fields.append(("credential", .string(credential)))
      }
      if case .string(let auth)? = entry["auth"] { fields.append(("auth", .string(auth))) }
      members.append((provider.rawValue, .object(fields)))
    }
    do {
      try AtomicFile.write(
        Array(OutputJSON.object(members).rendered().dropLast().utf8), to: instance.proxyStatePath,
        mode: .atMost(0o600))
    } catch {
      throw ContextError("Failed to write proxy.json", cause: error)
    }
  }
}

/// A running proxy: the guest-facing URL and the capability token the
/// guest presents. The token is not a provider credential.
