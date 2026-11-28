// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

package struct StoredUpstream: Sendable, Equatable {
  package let credential: CredentialReference
  package let auth: ProxyAuthScheme
}

/// `<instance>/proxy.json`: per-VM credential overrides. Resolution per
/// provider is override → configuration default → off.
package struct ProxyState: Sendable, Equatable {
  package var anthropic: StoredUpstream?
  package var openai: StoredUpstream?
  package var google: StoredUpstream?

  package static let empty = ProxyState(anthropic: nil, openai: nil, google: nil)

  package func override(for provider: ProxyProvider) -> StoredUpstream? {
    switch provider {
    case .anthropic: anthropic
    case .openai: openai
    case .google: google
    }
  }

  package var isEmpty: Bool { anthropic == nil && openai == nil && google == nil }

  /// Secret-store names the credential proxy reads: the configured upstreams
  /// plus this VM's overrides. Empty under `proxy.mode = "off"`. A corrupt
  /// `proxy.json` throws, so the separation check never runs on a partial set.
  package static func storedCredentialNames(
    _ proxy: ProxyConfig, instance: Instance?
  ) throws -> Set<SecretName> {
    guard proxy.mode != .off else { return [] }
    var names = proxy.storedCredentialNames
    guard let instance else { return names }
    let state = try load(instance)
    for provider in ProxyProvider.allCases {
      if let reference = state.override(for: provider)?.credential,
        let name = SecretName.vaultReference(reference.command.expose())
      {
        names.insert(name)
      }
    }
    return names
  }

  package static func load(_ instance: Instance) throws -> ProxyState {
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
        anthropic: try upstream(members["anthropic"]), openai: try upstream(members["openai"]),
        google: try upstream(members["google"]))
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
    guard let reference = CredentialReference(credential) else {
      throw HostError("Failed to parse proxy.json")
    }
    return StoredUpstream(credential: reference, auth: auth)
  }
}

extension ProxyState {
  /// The Keychain items `iso proxy setup --vm` wrote for `instance` that its
  /// `proxy.json` still names: exactly service `iso-<provider>-<vm>` and
  /// account `<provider>`. Any other reference is the user's own. Read
  /// before destroy removes the instance directory; an unreadable file
  /// names none.
  package static func ownedKeychainItems(_ instance: Instance) -> [KeychainReference] {
    guard let bytes = try? StateStore.readControlFile(instance.proxyStatePath),
      case .object(let members)? = try? ConfigLoader.parse(
        bytes, format: .json, path: instance.proxyStatePath, limits: .configuration)
    else { return [] }
    return ProxyProvider.allCases.compactMap { provider in
      guard case .object(let entry)? = members[provider.rawValue],
        case .string(let credential)? = entry["credential"],
        let item = KeychainReference.parse(credential),
        item.service == ProxyProvisioning.service(for: provider, vm: instance.name),
        item.account == provider.rawValue
      else { return nil }
      return item
    }
  }

  /// Delete `items` once their instance is destroyed. A failure is a
  /// warning naming the manual command, never a reason to keep the VM.
  package static func forget(
    _ items: [KeychainReference], keychain: Keychain, diagnostics: Diagnostics
  ) {
    for item in items {
      switch keychain.delete(item) {
      case .deleted:
        diagnostics.log(
          .info, "Removed the per-VM proxy credential \(item.service) from the Keychain")
      case .missing: break
      case .failed(let reason):
        diagnostics.warn(
          "Could not remove the per-VM proxy credential \(item.service) from the Keychain (\(reason)); delete it with `\(item.deleteCommand)`"
        )
      }
    }
  }
}

/// `iso proxy status` resolution, with credentials redacted.
package enum ProxyResolution: Sendable, Equatable {
  case off
  case override(ProxyAuthScheme, String)
  case configured(ProxyAuthScheme, String)

  package static func resolve(_ provider: ProxyProvider, state: ProxyState?, config: ProxyConfig)
    -> ProxyResolution
  {
    if let stored = state?.override(for: provider) {
      return .override(stored.auth, stored.credential.command.expose())
    }
    if let upstream = config.upstream(for: provider) {
      return .configured(upstream.auth, upstream.credential.command.expose())
    }
    return .off
  }

  package var description: String {
    switch self {
    case .off: "off (no default, no override)"
    case .override(let auth, let credential): "override — \(auth.rawValue), \(credential)"
    case .configured(let auth, let credential): "default — \(auth.rawValue), \(credential)"
    }
  }
}
