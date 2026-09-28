import CoopCore

/// A guest environment value: a literal, or a whole-value reference to a
/// stored secret (`{vault:<name>}`, embedded-secrets spec §27). Only the
/// reference is ever persisted; the value is resolved when a session needs it.
public enum EnvValue: Hashable, Sendable {
  case literal(String)
  case secret(SecretName)

  static let prefix = "{vault:"

  /// `{vault:name}` as the entire value is a reference. Any other use of
  /// `{vault:` (a prefix, suffix or embedded reference) is rejected rather
  /// than passed through as a literal.
  public static func parse(_ text: String) throws(ValidationError) -> EnvValue {
    guard text.contains(prefix) else { return .literal(text) }
    // The name grammar excludes `{`, `}` and `:`, so a second reference or
    // trailing text cannot hide inside the name.
    guard text.hasPrefix(prefix), text.hasSuffix("}") else {
      throw ValidationError(
        "a secret reference must be the whole value, `{vault:<name>}`; interpolation is not supported"
      )
    }
    let name = String(text.dropFirst(prefix.count).dropLast())
    do {
      return .secret(try SecretName(name))
    } catch {
      throw ValidationError("invalid secret reference: \(error.message)")
    }
  }

  public var reference: SecretName? {
    if case .secret(let name) = self { name } else { nil }
  }
}

/// A strict `.env` reader (spec §26): `KEY=value`, quoted values, `export`,
/// comments. It never runs a shell, expands variables or joins lines; any
/// malformed line fails the whole file.
public enum EnvFile {
  public static let maxBytes = 1 << 20

  /// Entries in file order; a later duplicate of a key wins.
  public static func parse(_ text: String) throws(ValidationError) -> [(EnvVarName, EnvValue)] {
    var out: [(EnvVarName, EnvValue)] = []
    // Split on LF scalars: "\r\n" is a single Character, so a Character
    // split would read a CRLF file as one line.
    for (index, rawLine) in text.unicodeScalars.split(
      separator: "\n", omittingEmptySubsequences: false
    ).enumerated() {
      var scalars = Substring.UnicodeScalarView(rawLine)
      if scalars.last == "\r" { scalars.removeLast() }
      let line = Substring(scalars)
      let lineNumber = index + 1
      guard
        !line.unicodeScalars.contains(where: {
          ["\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"].contains($0)
        })
      else {
        throw ValidationError("line \(lineNumber): stray carriage return or line separator")
      }
      do {
        if let entry = try parseLine(line) { out.append(entry) }
      } catch {
        throw ValidationError("line \(lineNumber): \(error.message)")
      }
    }
    return out
  }

  static func parseLine(_ line: Substring) throws(ValidationError) -> (EnvVarName, EnvValue)? {
    var rest = line.drop(while: { $0 == " " || $0 == "\t" })
    if rest.isEmpty || rest.first == "#" { return nil }
    if rest.hasPrefix("export ") || rest.hasPrefix("export\t") {
      rest = rest.dropFirst("export".count).drop(while: { $0 == " " || $0 == "\t" })
    }
    guard let equals = rest.firstIndex(of: "=") else { throw ValidationError("expected KEY=value") }
    let key = String(rest[..<equals])
    let name: EnvVarName
    do {
      name = try EnvVarName(key)
    } catch {
      throw ValidationError("invalid key '\(sanitizeForDisplay(key))'")
    }
    let raw = try value(rest[rest.index(after: equals)...])
    return (name, try EnvValue.parse(raw))
  }

  /// The value after `=`: single- or double-quoted (no escapes, no
  /// expansion), or unquoted up to a `#` that follows whitespace.
  static func value(_ text: Substring) throws(ValidationError) -> String {
    guard let quote = text.first, quote == "\"" || quote == "'" else {
      var value = text
      if let hash = commentStart(text) { value = text[..<hash] }
      let trimmed = value.reversed().drop(while: { $0 == " " || $0 == "\t" })
      return String(trimmed.reversed())
    }
    let body = text.dropFirst()
    guard let close = body.firstIndex(of: quote) else {
      throw ValidationError("unterminated \(quote == "\"" ? "double" : "single") quote")
    }
    let after = body[body.index(after: close)...].drop(while: { $0 == " " || $0 == "\t" })
    guard after.isEmpty || after.first == "#" else {
      throw ValidationError("unexpected text after the closing quote")
    }
    return String(body[..<close])
  }

  /// A `#` preceded by a space or tab starts a comment.
  static func commentStart(_ text: Substring) -> Substring.Index? {
    var previous: Character?
    for index in text.indices {
      if text[index] == "#", previous == " " || previous == "\t" { return index }
      previous = text[index]
    }
    return nil
  }
}
