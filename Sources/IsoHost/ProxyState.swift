// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// A per-VM override as stored in `<instance>/proxy.json`. A literal
/// credential written by an older host is recognized but its value is not
/// kept: it cannot be used until replaced with a `cmd:` reference (C-04).
public enum StoredCredential: Sendable, Equatable {
  case reference(CredentialReference)
  case literal
}

public struct StoredUpstream: Sendable, Equatable {
  public let credential: StoredCredential
  public let auth: ProxyAuthScheme
}

/// `<instance>/proxy.json`: per-VM credential overrides. Resolution per
/// provider is override → configuration default → off.
public struct ProxyState: Sendable, Equatable {
  public var anthropic: StoredUpstream?
  public var openai: StoredUpstream?

  public static let empty = ProxyState(anthropic: nil, openai: nil)

  public func override(for provider: ProxyProvider) -> StoredUpstream? {
    provider == .anthropic ? anthropic : openai
  }

  public var isEmpty: Bool { anthropic == nil && openai == nil }

  /// Secret-store names the credential proxy reads: the configured upstreams
  /// plus this VM's overrides. Empty under `proxy.mode = "off"`. A corrupt
  /// `proxy.json` throws, so the separation check never runs on a partial set.
  public static func storedCredentialNames(
    _ proxy: ProxyConfig, instance: Instance?
  ) throws -> Set<SecretName> {
    guard proxy.mode != .off else { return [] }
    var names = proxy.storedCredentialNames
    guard let instance else { return names }
    let state = try load(instance)
    for provider in ProxyProvider.allCases {
      if case .reference(let reference)? = state.override(for: provider)?.credential,
        let name = SecretName.vaultReference(reference.command.expose())
      {
        names.insert(name)
      }
    }
    return names
  }

  /// Missing file → empty. Unknown members are ignored, as in the baseline.
  public static func load(_ instance: Instance) throws -> ProxyState {
    let path = instance.proxyStatePath
    guard let data = FileManager.default.contents(atPath: path) else {
      if FileManager.default.fileExists(atPath: path) { throw HostError("Failed to read \(path)") }
      return .empty
    }
    do {
      let value = try ConfigLoader.parse(
        Array(data), format: .json, path: path, limits: .configuration)
      guard case .object(let members) = value else { throw HostError("Failed to parse proxy.json") }
      return ProxyState(
        anthropic: try upstream(members["anthropic"]), openai: try upstream(members["openai"]))
    } catch {
      throw HostError("Failed to parse proxy.json")
    }
  }

  static func upstream(_ value: JSONValue?) throws -> StoredUpstream? {
    guard let value, value != .null else { return nil }
    guard case .object(let members) = value, case .string(let credential)? = members["credential"]
    else {
      throw HostError("Failed to parse proxy.json")
    }
    let auth: ProxyAuthScheme
    switch members["auth"] {
    case nil: auth = .apiKey
    case .string(let raw)?:
      guard let parsed = ProxyAuthScheme(rawValue: raw) else {
        throw HostError("Failed to parse proxy.json")
      }
      auth = parsed
    default: throw HostError("Failed to parse proxy.json")
    }
    return StoredUpstream(
      credential: CredentialReference(credential).map(StoredCredential.reference) ?? .literal,
      auth: auth)
  }
}

/// `iso proxy status` resolution, with credentials redacted.
public enum ProxyResolution: Sendable, Equatable {
  case off
  case override(ProxyAuthScheme, String)
  case configured(ProxyAuthScheme, String)

  public static func resolve(_ provider: ProxyProvider, state: ProxyState?, config: ProxyConfig)
    -> ProxyResolution
  {
    if let stored = state?.override(for: provider) {
      switch stored.credential {
      case .reference(let reference): return .override(stored.auth, reference.command.expose())
      case .literal: return .override(stored.auth, "<literal credential, redacted>")
      }
    }
    if let upstream = config.upstream(for: provider) {
      return .configured(upstream.auth, upstream.credential.command.expose())
    }
    return .off
  }

  public var description: String {
    switch self {
    case .off: "off (no default, no override)"
    case .override(let auth, let credential): "override — \(auth.rawValue), \(credential)"
    case .configured(let auth, let credential): "default — \(auth.rawValue), \(credential)"
    }
  }
}
