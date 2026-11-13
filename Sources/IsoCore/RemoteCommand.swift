// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

/// POSIX single-quote escaping (`shlex.quote`'s algorithm): the value
/// reaches a shell as one literal word. Escapes per Unicode scalar: an
/// apostrophe followed by a combining mark is one `Character` but still
/// ends a quoted word in the shell.
package func shellEscape(_ value: String) -> String {
  var escaped = String.UnicodeScalarView()
  escaped.append("'")
  for scalar in value.unicodeScalars {
    if scalar == "'" {
      escaped.append(contentsOf: "'\\''".unicodeScalars)
    } else {
      escaped.append(scalar)
    }
  }
  escaped.append("'")
  return String(escaped)
}

/// A remote shell command from trusted literals and untrusted values, each
/// escaped exactly once (`ssh` hands the joined words to the guest shell), so
/// missing or double escaping is unrepresentable. Literals carry their own spacing.
package struct RemoteCommand: Sendable, Equatable, CustomStringConvertible {
  package private(set) var rendered = ""

  package init() {}

  /// A trusted fragment authored by iso (control flow, fixed flags).
  /// Never pass a dynamic value here.
  package func literal(_ fragment: String) -> RemoteCommand {
    var copy = self
    copy.rendered += fragment
    return copy
  }

  /// An untrusted value, shell-escaped once.
  package func arg(_ value: String) -> RemoteCommand {
    var copy = self
    copy.rendered += shellEscape(value)
    return copy
  }

  package var description: String { rendered }
}

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
