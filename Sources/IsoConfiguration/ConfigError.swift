// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

/// Configuration failures. Every message is built from field paths, error
/// categories and non-secret domain diagnostics; none embeds the source
/// document, a decoded secret-bearing value, or Foundation's raw error text.
package enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
  case missingFile(path: String)
  case unsupportedExtension(path: String)
  case unreadable(path: String, reason: String)
  case scan(path: String, JSONCScanError)
  case preflight(path: String, JSONPreflightError)
  /// Foundation rejected bytes the preflight accepted; details withheld.
  case undecodable(path: String)
  case rootNotObject(path: String)
  case invalidField(path: String, field: String, reason: String)
  case validation(errors: [String])

  package var description: String {
    switch self {
    case .missingFile(let path): "Configuration file does not exist: \(path)"
    case .unsupportedExtension(let path):
      "Unsupported configuration format for \(path): use a .jsonc or .json file"
    case .unreadable(let path, let reason): "Failed to read \(path): \(reason)"
    case .scan(let path, let error): "Failed to parse \(path): \(error)"
    case .preflight(let path, let error): "Failed to parse \(path): \(error)"
    case .undecodable(let path): "Failed to parse \(path): invalid JSON"
    case .rootNotObject(let path): "Failed to parse \(path): the top level must be an object"
    case .invalidField(let path, let field, let reason):
      "Invalid configuration in \(path): \(field): \(reason)"
    case .validation(let errors):
      "Config validation failed:\n  - " + errors.joined(separator: "\n  - ")
    }
  }
}
