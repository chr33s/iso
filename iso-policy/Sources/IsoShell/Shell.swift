// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

/// `text` with each Unicode scalar for which `replacement` returns a string
/// replaced by it. Quoting must work per scalar: `String.replacingOccurrences`
/// compares `Character`s, so an apostrophe followed by a combining mark (one
/// `Character`) escapes unchanged, yet a shell, YAML or expression parser
/// still reads it as a closing quote. `scripts/hygiene.py` refuses that idiom.
public func replacingScalars(
  _ text: String, _ replacement: (Unicode.Scalar) -> String?
) -> String {
  var out = String.UnicodeScalarView()
  for scalar in text.unicodeScalars {
    if let replaced = replacement(scalar) {
      out.append(contentsOf: replaced.unicodeScalars)
    } else {
      out.append(scalar)
    }
  }
  return String(out)
}

/// POSIX single-quote escaping (`shlex.quote`'s algorithm): the value
/// reaches a shell as one literal word.
public func shellEscape(_ value: String) -> String {
  "'" + replacingScalars(value) { $0 == "'" ? "'\\''" : nil } + "'"
}

/// A plain word (`[A-Za-z0-9_./:=-]`, non-empty) as is, anything else
/// through `shellEscape`.
public func shellWord(_ value: String) -> String {
  let plain = value.unicodeScalars.allSatisfy { scalar in
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".", "/", ":", "=": true
    default: false
    }
  }
  return !value.isEmpty && plain ? value : shellEscape(value)
}

/// YAML single-quoted scalar (`'` doubles).
public func yamlSingleQuoted(_ text: String) -> String {
  "'" + replacingScalars(text) { $0 == "'" ? "''" : nil } + "'"
}

/// A remote shell command from trusted literals and untrusted values, each
/// escaped exactly once (`ssh` hands the joined words to the guest shell), so
/// missing or double escaping is unrepresentable. Literals carry their own spacing.
public struct RemoteCommand: Sendable, Equatable, CustomStringConvertible {
  public private(set) var rendered = ""

  public init() {}

  /// A trusted fragment authored by iso (control flow, fixed flags).
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
