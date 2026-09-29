/// `--json` output with the baseline's exact shape: members in declaration
/// order, `serde_json::to_writer_pretty` formatting (two-space indent,
/// `"key": value`), `null` rather than omission, and floats always written
/// with a fraction or exponent (`0.0`, `0.12`). Foundation's `JSONEncoder`
/// orders keys arbitrarily and writes `1.0` as `1`, so output contracts use
/// this instead.
public indirect enum OutputJSON: Equatable, Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case string(String)
  case array([OutputJSON])
  case object([(String, OutputJSON)])

  public static func == (a: OutputJSON, b: OutputJSON) -> Bool { a.rendered() == b.rendered() }

  public static func optional(_ value: String?) -> OutputJSON {
    value.map(OutputJSON.string) ?? .null
  }

  /// Pretty text plus the trailing newline `render_json` writes.
  public func rendered() -> String {
    var out = ""
    write(to: &out, indent: 0)
    return out + "\n"
  }

  func write(to out: inout String, indent: Int) {
    switch self {
    case .null: out += "null"
    case .bool(let value): out += value ? "true" : "false"
    case .int(let value): out += String(value)
    case .uint(let value): out += String(value)
    case .double(let value): out += Self.formatDouble(value)
    case .string(let value): out += Self.quote(value)
    case .array(let elements):
      guard !elements.isEmpty else {
        out += "[]"
        return
      }
      out += "[\n"
      for (index, element) in elements.enumerated() {
        out += String(repeating: "  ", count: indent + 1)
        element.write(to: &out, indent: indent + 1)
        out += index + 1 < elements.count ? ",\n" : "\n"
      }
      out += String(repeating: "  ", count: indent) + "]"
    case .object(let members):
      guard !members.isEmpty else {
        out += "{}"
        return
      }
      out += "{\n"
      for (index, (key, value)) in members.enumerated() {
        out += String(repeating: "  ", count: indent + 1) + Self.quote(key) + ": "
        value.write(to: &out, indent: indent + 1)
        out += index + 1 < members.count ? ",\n" : "\n"
      }
      out += String(repeating: "  ", count: indent) + "}"
    }
  }

  /// serde_json string escaping: `"`, `\`, the short control escapes, and
  /// `\u00XX` (lowercase hex) for other control characters; nothing else.
  static func quote(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\u{08}": out += "\\b"
      case "\u{0C}": out += "\\f"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case _ where scalar.value < 0x20:
        let hex = String(scalar.value, radix: 16)
        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
      default: out.unicodeScalars.append(scalar)
      }
    }
    return out + "\""
  }

  /// serde_json (ryu) float text: shortest round-trip digits; fixed notation
  /// for decimal exponents in [-5, 16) with at least one fractional digit,
  /// otherwise `1e+16` / `1.5e-7`. Non-finite values are `null`.
  static func formatDouble(_ value: Double) -> String {
    guard value.isFinite else { return "null" }
    if value == 0 { return value.sign == .minus ? "-0.0" : "0.0" }
    let (negative, digits, exponent) = shortestDigits(value)
    let sign = negative ? "-" : ""
    // `exponent` is the power of ten of the first digit.
    let length = digits.count
    if exponent >= -5 && exponent < 16 {
      if exponent < 0 {
        return sign + "0." + String(repeating: "0", count: -exponent - 1) + digits
      }
      if exponent + 1 >= length {
        return sign + digits + String(repeating: "0", count: exponent + 1 - length) + ".0"
      }
      let split = digits.index(digits.startIndex, offsetBy: exponent + 1)
      return sign + digits[..<split] + "." + digits[split...]
    }
    let mantissa = length == 1 ? digits : String(digits.first!) + "." + digits.dropFirst()
    return sign + mantissa + "e" + (exponent > 0 ? "+" : "") + String(exponent)
  }

  /// Decimal digits (no leading/trailing zeros) and exponent of the first
  /// digit, from Swift's shortest round-trip description.
  static func shortestDigits(_ value: Double) -> (Bool, String, Int) {
    var text = value.magnitude.description
    var exponent = 0
    if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
      exponent = Int(text[text.index(after: e)...].filter { $0 != "+" })!
      text = String(text[..<e])
    }
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    let integer = String(parts[0])
    let fraction = parts.count > 1 ? String(parts[1]) : ""
    var digits = integer + fraction
    var firstExponent = exponent + integer.count - 1
    while digits.first == "0" {
      digits.removeFirst()
      firstExponent -= 1
    }
    while digits.count > 1 && digits.last == "0" { digits.removeLast() }
    return (value.sign == .minus, digits, firstExponent)
  }
}
