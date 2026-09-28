// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

/// POSIX single-quote escaping (`shlex.quote`'s algorithm): the value
/// reaches a shell as one literal word.
public func shellEscape(_ value: String) -> String {
  var escaped = "'"
  for character in value {
    if character == "'" { escaped += "'\\''" } else { escaped.append(character) }
  }
  return escaped + "'"
}

/// A remote shell command assembled from trusted literal fragments and
/// untrusted values, each escaped exactly once. `ssh` joins its command
/// words and hands them to the guest shell, so this is the only way a
/// dynamic value may reach it: forgetting to escape and escaping twice are
/// both unrepresentable. Parts are concatenated verbatim; literals carry
/// their own spacing.
public struct RemoteCommand: Sendable, Equatable, CustomStringConvertible {
  public private(set) var rendered = ""

  public init() {}

  /// A trusted fragment authored by coop (control flow, fixed flags).
  /// Never pass a dynamic value here.
  public func literal(_ fragment: String) -> RemoteCommand {
    var copy = self
    copy.rendered += fragment
    return copy
  }

  /// An untrusted value, shell-escaped once.
  public func arg(_ value: String) -> RemoteCommand {
    var copy = self
    copy.rendered += shellEscape(value)
    return copy
  }

  public var description: String { rendered }
}

/// An absolute or relative path inside the guest, carried as text.
public struct GuestPath: Hashable, Sendable, CustomStringConvertible, Codable {
  public let rawValue: String

  public init(_ path: String) { rawValue = path }

  public static func absolute(_ path: String) throws(ValidationError) -> GuestPath {
    guard path.hasPrefix("/") else {
      throw ValidationError("Guest path must be absolute: '\(path)'")
    }
    return GuestPath(path)
  }

  public var description: String { rawValue }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
