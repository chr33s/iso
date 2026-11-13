/// `text` with each Unicode scalar for which `replacement` returns a string
/// replaced by it. Quoting must work per scalar: `String.replacingOccurrences`
/// compares `Character`s, so an apostrophe followed by a combining mark (one
/// `Character`) escapes unchanged, yet a shell, YAML or expression parser
/// still reads it as a closing quote. `scripts/hygiene.py` refuses that idiom.
package func replacingScalars(
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

/// POSIX single-quoted shell word: the value reaches a shell as one literal word.
package func shellSingleQuoted(_ word: String) -> String {
  "'" + replacingScalars(word) { $0 == "'" ? "'\\''" : nil } + "'"
}

/// YAML single-quoted scalar (`'` doubles).
package func yamlSingleQuoted(_ text: String) -> String {
  "'" + replacingScalars(text) { $0 == "'" ? "''" : nil } + "'"
}
