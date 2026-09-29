// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

extension OutputJSON {
  /// Compact text as `serde_json::to_string` writes it: no whitespace,
  /// members in order, the same string escaping and float text as the
  /// pretty form. No trailing newline.
  public func compactRendered() -> String {
    var out = ""
    writeCompact(to: &out)
    return out
  }

  func writeCompact(to out: inout String) {
    switch self {
    case .array(let elements):
      out += "["
      for (index, element) in elements.enumerated() {
        if index > 0 { out += "," }
        element.writeCompact(to: &out)
      }
      out += "]"
    case .object(let members):
      out += "{"
      for (index, (key, value)) in members.enumerated() {
        if index > 0 { out += "," }
        out += Self.quote(key) + ":"
        value.writeCompact(to: &out)
      }
      out += "}"
    default: write(to: &out, indent: 0)
    }
  }

  /// serde_json's text for a finite `f64` (`1.0`, `1e+16`, `-0.0`).
  public static func floatText(_ value: Double) -> String { formatDouble(value) }
}
