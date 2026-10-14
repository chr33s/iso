// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoPolicy

/// Fixed errors carry no input fragments, decoder diagnostics, or credentials.
package enum PolicyError: Error, Sendable {
  case invalidConfig, invalidCapability, invalidTarget, invalidHeader
}

package struct Injection: Sendable, CustomStringConvertible {
  package enum Scheme: String, Decodable, Sendable {
    case xAPIKey = "x_api_key"
    case bearer
  }
  package let scheme: Scheme
  package let credential: Secret

  package init(scheme: Scheme, credential: Secret, provider: Provider) throws {
    guard provider != .openai || scheme == .bearer,
      !credential.expose().isEmpty,
      credential.expose().utf8.allSatisfy({ (33...126).contains($0) })
    else { throw PolicyError.invalidConfig }
    self.scheme = scheme
    self.credential = credential
  }
  package var description: String { "Injection(\(scheme.rawValue), <redacted>)" }
}

package struct LoopbackAddress: Sendable {
  package let host: String
  package let port: Int

  package init(_ text: String) throws {
    let host: String
    let portText: Substring
    if text.hasPrefix("[::1]:") {
      host = "::1"
      portText = text.dropFirst(6)
    } else {
      let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
      guard pieces.count == 2 else { throw PolicyError.invalidConfig }
      host = String(pieces[0])
      portText = pieces[1]
      let octets = host.split(separator: ".", omittingEmptySubsequences: false)
      guard octets.count == 4, octets.first == "127",
        octets.allSatisfy({ part in
          guard let byte = UInt8(part) else { return false }
          return String(byte) == part
        })
      else { throw PolicyError.invalidConfig }
    }
    guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
      let port = UInt16(portText)
    else { throw PolicyError.invalidConfig }
    self.host = host
    self.port = Int(port)
  }
}

package struct ProxyConfig: Sendable {
  package let listen: LoopbackAddress
  package let provider: Provider
  package let capability: Capability
  package let injection: Injection
  package let readiness: BrokerReadiness?
  /// Version 3 only: the host-bound policy this proxy enforces or simulates.
  package let authorization: ProxyAuthorization?

  package init(json: Data) throws {
    guard json.count <= Limits.startupBytesV3 else { throw PolicyError.invalidConfig }
    do {
      let wire = try JSONDecoder().decode(Wire.self, from: json)
      let network = wire.readiness?.bootID != nil || wire.readiness?.policyHash != nil
      switch wire.version {
      case 1:
        guard wire.readiness == nil, wire.authorization == nil else {
          throw PolicyError.invalidConfig
        }
      case 2:
        guard network, wire.authorization == nil else { throw PolicyError.invalidConfig }
      case 3:
        guard wire.readiness != nil, wire.authorization != nil else {
          throw PolicyError.invalidConfig
        }
      default: throw PolicyError.invalidConfig
      }
      // Older protocols keep their original bound.
      guard wire.version == 3 || json.count <= Limits.startupBytes else {
        throw PolicyError.invalidConfig
      }
      authorization = try wire.authorization.map {
        try ProxyAuthorization($0, provider: wire.provider)
      }
      listen = try LoopbackAddress(wire.listen)
      provider = wire.provider
      capability = try Capability(wire.capabilityToken)
      injection = try Injection(
        scheme: wire.injection.scheme,
        credential: Secret(wire.injection.credential), provider: wire.provider)
      let authorization = authorization
      readiness = try wire.readiness.map {
        try BrokerReadiness(
          privateKeyHex: $0.privateKeyHex, provider: wire.provider, bootID: $0.bootID,
          policyHash: $0.policyHash, authorization: authorization)
      }
    } catch {
      // JSONDecoder errors may quote invalid enum values or field names.
      throw PolicyError.invalidConfig
    }
  }
}

private struct AnyKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

private func rejectUnknownFields(_ decoder: Decoder, allowed: Set<String>) throws {
  let container = try decoder.container(keyedBy: AnyKey.self)
  guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
    throw PolicyError.invalidConfig
  }
}

private struct Wire: Decodable {
  let version: Int
  let listen: String
  let provider: Provider
  let capabilityToken: String
  let injection: WireInjection
  let readiness: WireReadiness?
  let authorization: WireAuthorization?
  enum CodingKeys: String, CodingKey, CaseIterable {
    case version, listen, provider, injection, readiness, authorization
    case capabilityToken = "capability_token"
  }
  init(from decoder: Decoder) throws {
    try rejectUnknownFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    version = try c.decode(Int.self, forKey: .version)
    listen = try c.decode(String.self, forKey: .listen)
    provider = try c.decode(Provider.self, forKey: .provider)
    capabilityToken = try c.decode(String.self, forKey: .capabilityToken)
    injection = try c.decode(WireInjection.self, forKey: .injection)
    readiness = try c.decodeIfPresent(WireReadiness.self, forKey: .readiness)
    authorization = try c.decodeIfPresent(WireAuthorization.self, forKey: .authorization)
  }
}

/// `bootID` and `policyHash` are the filtered-egress network identity:
/// required in version 2, both or neither in version 3.
private struct WireReadiness: Decodable {
  let privateKeyHex: String
  let bootID: String?
  let policyHash: String?
  enum CodingKeys: String, CodingKey, CaseIterable { case privateKeyHex, bootID, policyHash }
  init(from decoder: Decoder) throws {
    try rejectUnknownFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    privateKeyHex = try c.decode(String.self, forKey: .privateKeyHex)
    bootID = try c.decodeIfPresent(String.self, forKey: .bootID)
    policyHash = try c.decodeIfPresent(String.self, forKey: .policyHash)
    guard (bootID == nil) == (policyHash == nil) else { throw PolicyError.invalidConfig }
  }
}

struct WireAuthorization: Decodable {
  let schemaVersion: Int
  let canonicalizationVersion: Int
  let instanceID: String
  let instanceName: String
  let bootID: String
  let policyEpoch: String
  let proxyGenerationID: String
  let policyDigest: String
  let policy: String
  enum CodingKeys: String, CodingKey, CaseIterable {
    case schemaVersion, canonicalizationVersion, instanceID, instanceName, bootID, policyEpoch
    case proxyGenerationID, policyDigest, policy
  }
  init(from decoder: Decoder) throws {
    try rejectUnknownFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
    canonicalizationVersion = try c.decode(Int.self, forKey: .canonicalizationVersion)
    instanceID = try c.decode(String.self, forKey: .instanceID)
    instanceName = try c.decode(String.self, forKey: .instanceName)
    bootID = try c.decode(String.self, forKey: .bootID)
    policyEpoch = try c.decode(String.self, forKey: .policyEpoch)
    proxyGenerationID = try c.decode(String.self, forKey: .proxyGenerationID)
    policyDigest = try c.decode(String.self, forKey: .policyDigest)
    policy = try c.decode(String.self, forKey: .policy)
  }
}

/// The host-bound identity and policy of a version 3 proxy. The proxy
/// re-validates everything itself: a host-side compile is not trusted.
package struct ProxyAuthorization: Sendable {
  package let instanceID: String
  package let instanceName: String
  package let bootID: String
  package let policyEpoch: String
  package let proxyGenerationID: String
  package let policy: CompiledPolicy
  /// The startup provider, never a URL or guest-supplied alias.
  package let resource: PolicyResource

  init(_ wire: WireAuthorization, provider: Provider) throws {
    guard wire.schemaVersion == 1,
      wire.canonicalizationVersion == PolicySchema.canonicalizationVersion,
      BrokerReadiness.hex(wire.instanceID, count: 16) != nil,
      BrokerReadiness.hex(wire.bootID, count: 16) != nil,
      PolicySchema.isValidInstanceName(wire.instanceName),
      Self.isUUID(wire.policyEpoch), Self.isUUID(wire.proxyGenerationID)
    else { throw PolicyError.invalidConfig }
    let policy: CompiledPolicy
    do {
      policy = try PolicyCanonical.decode(Array(wire.policy.utf8))
    } catch {
      throw PolicyError.invalidConfig
    }
    // Off-mode launches use versions 1 and 2; a policy that does not govern
    // provider actions has nothing for this proxy to decide.
    guard policy.digest == wire.policyDigest, policy.mode != .off, policy.governsProviderActions
    else { throw PolicyError.invalidConfig }
    instanceID = wire.instanceID
    instanceName = wire.instanceName
    bootID = wire.bootID
    policyEpoch = wire.policyEpoch
    proxyGenerationID = wire.proxyGenerationID
    self.policy = policy
    resource = provider == .anthropic ? .anthropic : .openai
  }

  static func isUUID(_ text: String) -> Bool {
    let bytes = Array(text.utf8)
    guard bytes.count == 36 else { return false }
    for (index, byte) in bytes.enumerated() {
      if [8, 13, 18, 23].contains(index) {
        guard byte == 0x2D else { return false }
      } else {
        guard (48...57).contains(byte) || (97...102).contains(byte) else { return false }
      }
    }
    return true
  }
}

private struct WireInjection: Decodable {
  let scheme: Injection.Scheme
  let credential: String
  enum CodingKeys: String, CodingKey, CaseIterable { case scheme, credential }
  init(from decoder: Decoder) throws {
    try rejectUnknownFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let c = try decoder.container(keyedBy: CodingKeys.self)
    scheme = try c.decode(Injection.Scheme.self, forKey: .scheme)
    credential = try c.decode(String.self, forKey: .credential)
  }
}
