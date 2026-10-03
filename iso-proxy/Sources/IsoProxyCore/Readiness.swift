import CryptoKit
import Foundation

/// Local proof of broker identity, not provider authorization or upstream health.
/// The signing seed stays in memory; the guest capability cannot sign replies.
package struct BrokerReadiness: Sendable {
  package static let path = "/__iso/broker-ready"
  private let key: Curve25519.Signing.PrivateKey
  private let provider: Provider
  private let bootID: String
  private let policyHash: String

  package init(privateKeyHex: String, provider: Provider, bootID: String, policyHash: String) throws
  {
    guard let seed = Self.hex(privateKeyHex, count: 32), Self.hex(bootID, count: 16) != nil,
      policyHash.hasPrefix("sha256:"), Self.hex(String(policyHash.dropFirst(7)), count: 32) != nil
    else { throw PolicyError.invalidConfig }
    key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    self.provider = provider
    self.bootID = bootID
    self.policyHash = policyHash
  }

  static func hex(_ text: String, count: Int) -> [UInt8]? {
    let bytes = Array(text.utf8)
    guard bytes.count == count * 2 else { return nil }
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: byte - 48
      case 97...102: byte - 87
      default: nil
      }
    }
    var result: [UInt8] = []
    for index in stride(from: 0, to: bytes.count, by: 2) {
      guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
      result.append(high * 16 + low)
    }
    return result
  }

  /// No credentials, body, query, or selectable destination on this route.
  package static func challenge(method: String, uri: String, headers: [Header]) -> String? {
    guard method == "GET", uri == path, headers.count == 3 else { return nil }
    let hosts = headers.filter { $0.name.lowercased() == "host" }
    let connections = headers.filter { $0.name.lowercased() == "connection" }
    let nonces = headers.filter { $0.name.lowercased() == "x-iso-nonce" }
    guard hosts.count == 1, hosts[0].value == "localhost",
      connections.count == 1, connections[0].value == "close",
      nonces.count == 1, Self.hex(nonces[0].value, count: 16) != nil
    else { return nil }
    return nonces[0].value
  }

  package func response(nonce: String) throws -> Data {
    guard Self.hex(nonce, count: 16) != nil else { throw PolicyError.invalidHeader }
    let message =
      "iso-broker-readiness-v1\n\(nonce)\n\(provider.rawValue)\n\(bootID)\n\(policyHash)\n"
    return try JSONEncoder().encode(
      Reply(
        version: 1, nonce: nonce, provider: provider.rawValue, bootID: bootID,
        policyHash: policyHash,
        signature: try key.signature(for: Data(message.utf8)).base64EncodedString()))
  }

  private struct Reply: Encodable {
    let version: Int
    let nonce: String
    let provider: String
    let bootID: String
    let policyHash: String
    let signature: String
  }
}
