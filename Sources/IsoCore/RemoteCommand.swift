// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

// Quoting lives in iso-policy's IsoShell, shared with iso-ci; every IsoCore
// client keeps `shellEscape` and `RemoteCommand` through this re-export.
@_exported import IsoShell

/// An absolute or relative path inside the guest, carried as text.
package struct GuestPath: Hashable, Sendable, CustomStringConvertible, Codable {
  package let rawValue: String

  package init(_ path: String) { rawValue = path }

  package static func absolute(_ path: String) throws(ValidationError) -> GuestPath {
    guard path.hasPrefix("/") else {
      throw ValidationError("Guest path must be absolute: '\(path)'")
    }
    return GuestPath(path)
  }

  package var description: String { rawValue }

  package init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  package func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
