// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CryptoKit

/// CryptoKit verifies an HMAC of the decoded capability using its constant-time
/// authentication primitive. The random, process-local key never leaves memory.
public struct Capability: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
  private let key: SymmetricKey
  private let tag: HMAC<SHA256>.MAC

  public init(_ encoded: String) throws {
    guard let bytes = Self.decode(encoded) else { throw PolicyError.invalidCapability }
    key = SymmetricKey(size: .bits256)
    tag = HMAC<SHA256>.authenticationCode(for: bytes, using: key)
  }

  public func verifies(_ encoded: String) -> Bool {
    guard let bytes = Self.decode(encoded) else { return false }
    return HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: bytes, using: key)
  }

  public func authorizes(_ headers: [Header]) -> Bool {
    let authorization = headers.filter { $0.name.lowercased() == "authorization" }
    let apiKeys = headers.filter { $0.name.lowercased() == "x-api-key" }
    guard authorization.count <= 1, apiKeys.count <= 1,
      !authorization.isEmpty || !apiKeys.isEmpty
    else { return false }
    if let value = authorization.first?.value {
      guard value.hasPrefix("Bearer "), verifies(String(value.dropFirst(7))) else { return false }
    }
    if let value = apiKeys.first?.value, !verifies(value) { return false }
    return true
  }

  private static func decode(_ encoded: String) -> [UInt8]? {
    let bytes = Array(encoded.utf8)
    guard bytes.count == 64 else { return nil }
    var result: [UInt8] = []
    result.reserveCapacity(32)
    func nibble(_ byte: UInt8) -> UInt8? {
      switch byte {
      case 48...57: byte - 48
      case 97...102: byte - 87
      default: nil
      }
    }
    for i in stride(from: 0, to: 64, by: 2) {
      guard let high = nibble(bytes[i]), let low = nibble(bytes[i + 1]) else { return nil }
      result.append(high * 16 + low)
    }
    return result
  }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "Capability(<redacted>)" }
}
