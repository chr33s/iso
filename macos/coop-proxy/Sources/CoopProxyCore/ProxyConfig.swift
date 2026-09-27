import Foundation

/// Fixed errors carry no input fragments, decoder diagnostics, or credentials.
public enum PolicyError: Error, Sendable {
  case invalidConfig, invalidCapability, invalidTarget, invalidHeader
}

public struct Injection: Sendable, CustomStringConvertible {
  public enum Scheme: String, Decodable, Sendable {
    case xAPIKey = "x_api_key"
    case bearer
  }
  public let scheme: Scheme
  public let credential: Secret

  public init(scheme: Scheme, credential: Secret, provider: Provider) throws {
    guard provider != .openai || scheme == .bearer,
      !credential.expose().isEmpty,
      credential.expose().utf8.allSatisfy({ (33...126).contains($0) })
    else { throw PolicyError.invalidConfig }
    self.scheme = scheme
    self.credential = credential
  }
  public var description: String { "Injection(\(scheme.rawValue), <redacted>)" }
}

public struct LoopbackAddress: Sendable {
  public let host: String
  public let port: Int

  public init(_ text: String) throws {
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

public struct ProxyConfig: Sendable {
  public let listen: LoopbackAddress
  public let provider: Provider
  public let capability: Capability
  public let injection: Injection

  public init(json: Data) throws {
    guard json.count <= Limits.startupBytes else { throw PolicyError.invalidConfig }
    do {
      let wire = try JSONDecoder().decode(Wire.self, from: json)
      guard wire.version == 1 else { throw PolicyError.invalidConfig }
      listen = try LoopbackAddress(wire.listen)
      provider = wire.provider
      capability = try Capability(wire.capabilityToken)
      injection = try Injection(
        scheme: wire.injection.scheme,
        credential: Secret(wire.injection.credential), provider: wire.provider)
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
  enum CodingKeys: String, CodingKey, CaseIterable {
    case version, listen, provider, injection
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
