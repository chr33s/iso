// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct Header: Sendable, Equatable {
  public let name: String
  public let value: String
  public init(_ name: String, _ value: String) {
    self.name = name
    self.value = value
  }
}

public enum HeaderPolicy {
  private static let hopByHop: Set<String> = [
    "connection", "proxy-connection", "keep-alive", "transfer-encoding", "te",
    "trailer", "upgrade", "proxy-authenticate", "proxy-authorization",
  ]

  public static func request(_ headers: [Header], provider: Provider, injection: Injection) throws
    -> [Header]
  {
    var result = try filtered(headers).filter {
      !["authorization", "x-api-key", "host"].contains($0.name.lowercased())
    }
    result.append(Header("host", provider.hostname))
    switch injection.scheme {
    case .xAPIKey: result.append(Header("x-api-key", injection.credential.expose()))
    case .bearer: result.append(Header("authorization", "Bearer " + injection.credential.expose()))
    }
    return result
  }

  public static func response(_ headers: [Header]) throws -> [Header] { try filtered(headers) }

  private static func filtered(_ headers: [Header]) throws -> [Header] {
    var removed = hopByHop
    for header in headers where header.name.lowercased() == "connection" {
      for component in header.value.split(separator: ",", omittingEmptySubsequences: false) {
        let name = component.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty, name.utf8.allSatisfy(isToken) else { throw PolicyError.invalidHeader }
        removed.insert(name)
      }
    }
    return headers.filter { !removed.contains($0.name.lowercased()) }
  }

  private static func isToken(_ byte: UInt8) -> Bool {
    (48...57).contains(byte) || (97...122).contains(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
  }
}
