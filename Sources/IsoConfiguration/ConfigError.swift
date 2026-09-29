// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

/// Configuration failures. Every message is built from field paths, error
/// categories and non-secret domain diagnostics; none embeds the source
/// document, a decoded secret-bearing value, or Foundation's raw error text.
public enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
  /// `.toml` selected explicitly, or only a legacy `config.toml` exists.
  case migrationRequired(tomlPath: String, jsoncPath: String)
  case unsupportedExtension(path: String)
  case unreadable(path: String, reason: String)
  case scan(path: String, JSONCScanError)
  case preflight(path: String, JSONPreflightError)
  /// Foundation rejected bytes the preflight accepted; details withheld.
  case undecodable(path: String)
  case rootNotObject(path: String)
  case invalidField(path: String, field: String, reason: String)
  case retiredFields(path: String, fields: [String])
  case validation(errors: [String])

  public var description: String {
    switch self {
    case .migrationRequired(let toml, let jsonc):
      """
      \(toml) is a TOML configuration, which this version of iso no longer reads.
      Convert it once with:
        python3 scripts/migrate-config-to-jsonc.py --input \(toml) --output \(jsonc)
      then run iso again. The TOML file is left untouched.
      """
    case .unsupportedExtension(let path):
      "Unsupported configuration format for \(path): use a .jsonc or .json file"
    case .unreadable(let path, let reason): "Failed to read \(path): \(reason)"
    case .scan(let path, let error): "Failed to parse \(path): \(error)"
    case .preflight(let path, let error): "Failed to parse \(path): \(error)"
    case .undecodable(let path): "Failed to parse \(path): invalid JSON"
    case .rootNotObject(let path): "Failed to parse \(path): the top level must be an object"
    case .invalidField(let path, let field, let reason):
      "Invalid configuration in \(path): \(field): \(reason)"
    case .retiredFields(let path, let fields):
      """
      \(path) contains settings for the retired Firecracker host backend: \(fields.joined(separator: ", ")).
      Remove them (they have no effect on the Apple backend), or re-run
      scripts/migrate-config-to-jsonc.py with --drop-retired-fields.
      """
    case .validation(let errors):
      "Config validation failed:\n  - " + errors.joined(separator: "\n  - ")
    }
  }
}
