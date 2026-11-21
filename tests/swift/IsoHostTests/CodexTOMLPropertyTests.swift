// Property tests for the Codex `config.toml` printer and parser over
// generated documents; the generator and reproduction knobs are in
// IsoPropertyTesting.

import Foundation
import IsoPropertyTesting
import Testing

@testable import IsoHost

private func expectHolds(
  _ failure: PropertyFailure?, sourceLocation: SourceLocation = #_sourceLocation
) {
  if let failure {
    Issue.record(Comment(rawValue: failure.description), sourceLocation: sourceLocation)
  }
}

// MARK: - Generators

/// Text weighted toward what breaks TOML quoting: quotes and quote runs,
/// backslashes and escape lookalikes, comment and key syntax, controls,
/// newlines, and an occasional long run.
private func tomlText(_ rng: inout PropertyRNG) -> String {
  if rng.oneIn(50) { return String(repeating: rng.string(maxScalars: 3), count: 300) }
  var out = ""
  for _ in 0..<rng.int(0...3) {
    out +=
      rng.oneIn(3)
      ? rng.element([
        "\"", "\"\"", "\"\"\"", "'", "'''", "\\", "\\u0041", "\\n", "#", "=", "[", "]]", "{", ".",
        "\n", "\r\n", "\r", "\t", "\u{7F}", "\u{1B}", "\u{0}", "\u{FEFF}",
      ])
      : rng.string(maxScalars: 6)
  }
  return out
}

private func tomlKey(_ rng: inout PropertyRNG) -> String {
  rng.oneIn(3)
    ? tomlText(&rng)
    : rng.element(["model", "mcp_servers", "a", "A-b_9", "", "a.b", "x y", "1", "true", "é", "#"])
}

private let datetimes = [
  "1979-05-27T07:32:00Z", "1979-05-27T00:32:00.999999-07:00", "1979-05-27T07:32:00",
  "1979-05-27T07:32:00+05:30", "1979-05-27", "07:32:00", "00:32:00.5", "23:59",
]

private func tomlFloat(_ rng: inout PropertyRNG) -> Double {
  switch rng.below(4) {
  case 0:
    return rng.element([
      .infinity, -.infinity, .nan, -0.0, 0.0, 1e16, 1e15, -1e16, 1e-300, 5e-324,
      .greatestFiniteMagnitude, 0.1, 123_456_789.0, 9_007_199_254_740_992, -2.5e-7,
    ])
  case 1: return Double(Int32(truncatingIfNeeded: rng.next())) / 8
  default:
    let bits = Double(bitPattern: rng.next())
    return bits.isFinite ? bits : 2.5
  }
}

private func tomlValue(_ rng: inout PropertyRNG, depth: Int) -> TOMLValue {
  let leaf = depth <= 0 || rng.oneIn(2)
  switch leaf ? rng.below(6) : 6 + rng.below(3) {
  case 0: return .string(tomlText(&rng))
  case 1:
    return .integer(
      rng.oneIn(3)
        ? rng.element([.min, .max, 0, -1, 1000]) : Int64(bitPattern: rng.next()) >> rng.below(64))
  case 2: return .float(tomlFloat(&rng))
  case 3: return .boolean(rng.oneIn(2))
  case 4: return .datetime(rng.element(datetimes))
  case 5: return .string(rng.element(["", "plain", "it's", "a\"b", "C:\\path"]))
  case 6: return .array((0..<rng.below(4)).map { _ in tomlValue(&rng, depth: depth - 1) })
  case 7:
    // An array of tables: printed as `[[path]]` sections.
    return .array((0..<rng.int(1...3)).map { _ in .table(tomlTable(&rng, depth: depth - 1)) })
  default: return .table(tomlTable(&rng, depth: depth - 1))
  }
}

private func tomlTable(_ rng: inout PropertyRNG, depth: Int) -> TOMLTable {
  TOMLTable((0..<rng.below(4)).map { _ in (tomlKey(&rng), tomlValue(&rng, depth: depth)) })
}

// MARK: - Exact comparison

/// Scalar-exact equality: `TOMLValue ==` compares strings and keys by
/// canonical equivalence, which would hide a normalizing trip. Floats compare
/// by bit pattern so `-0.0` keeps its sign; every NaN is equal.
private func exactlyEqual(_ a: TOMLValue, _ b: TOMLValue) -> Bool {
  switch (a, b) {
  case (.string(let x), .string(let y)), (.datetime(let x), .datetime(let y)):
    return x.unicodeScalars.elementsEqual(y.unicodeScalars)
  case (.integer(let x), .integer(let y)): return x == y
  case (.float(let x), .float(let y)):
    return (x.isNaN && y.isNaN) || x.bitPattern == y.bitPattern
  case (.boolean(let x), .boolean(let y)): return x == y
  case (.array(let x), .array(let y)):
    return x.count == y.count && zip(x, y).allSatisfy(exactlyEqual)
  case (.table(let x), .table(let y)): return exactlyEqual(x, y)
  default: return false
  }
}

private func exactlyEqual(_ a: TOMLTable, _ b: TOMLTable) -> Bool {
  let keys = a.sortedKeys
  return keys.map { Array($0.unicodeScalars) } == b.sortedKeys.map { Array($0.unicodeScalars) }
    && keys.allSatisfy { exactlyEqual(a[$0]!, b[$0]!) }
}

// MARK: - Printer round trip

@Test func codexTOMLPrintsGeneratedDocumentsThatParseBackExactly() {
  expectHolds(
    checkProperty(
      "TOMLTable print/parse", iterations: 600,
      generate: { tomlTable(&$0, depth: 3) },
      property: { table in
        let document = table.document
        // TOML forbids raw controls other than tab and newline anywhere.
        if let raw = document.unicodeScalars.first(where: {
          ($0.value < 0x20 && $0 != "\t" && $0 != "\n") || $0.value == 0x7F
        }) {
          return "raw control U+\(String(raw.value, radix: 16)) in the document"
        }
        let parsed: TOMLTable
        do { parsed = try TOMLTable.parse(document) } catch {
          return "printed document refused: \(error)\n  document: \(printable(document))"
        }
        guard exactlyEqual(parsed, table) else {
          return "parsed table differs\n  document: \(printable(document))"
        }
        guard Array(parsed.document.utf8) == Array(document.utf8) else {
          return "printing is not canonical"
        }
        return nil
      }))
}

@Test func codexTOMLQuotesEveryStringAndKeyScalarExactly() {
  expectHolds(
    checkProperty(
      "TOMLWriter.string/key", iterations: 2000,
      generate: { rng in (tomlKey(&rng), tomlText(&rng)) },
      property: { (key: String, value: String) -> String? in
        let line = TOMLWriter.key(key) + " = " + TOMLWriter.string(value) + "\n"
        guard let parsed = try? TOMLTable.parse(line) else {
          return "refused \(printable(line))"
        }
        guard exactlyEqual(parsed, TOMLTable([(key, .string(value))])) else {
          return "\(printable(line)) parsed to a different key or value"
        }
        return nil
      }))
}

// MARK: - Equivalent spellings

/// Spells a table the way a person might: any key quoting, literal and
/// multi-line strings, signed, underscored and radix integers, `t`/space/`z`
/// datetimes, headers, dotted keys or inline tables, comments, blank lines
/// and CRLF. The parser must read every spelling as the same table.
private struct TOMLSpeller {
  var rng: PropertyRNG
  var out = ""

  mutating func lineEnd() {
    if rng.oneIn(4) { out += rng.element([" ", "\t"]) + "# " + comment() }
    out += rng.oneIn(3) ? "\r\n" : "\n"
    if rng.oneIn(5) { out += rng.element(["\n", "# " + comment() + "\n", "  \n"]) }
  }

  /// Comment text: anything but controls other than tab.
  mutating func comment() -> String {
    String(
      String.UnicodeScalarView(
        tomlText(&rng).unicodeScalars.filter {
          $0 == "\t" || ($0.value >= 0x20 && $0.value != 0x7F)
        }
      ))
  }

  static func hasControl(_ text: String, allowing: Set<Unicode.Scalar> = []) -> Bool {
    text.unicodeScalars.contains {
      !allowing.contains($0) && (($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F)
    }
  }

  mutating func key(_ key: String) -> String {
    let bare =
      !key.isEmpty
      && key.unicodeScalars.allSatisfy {
        $0.isASCII && (TOMLParser.isBareKey(UInt8($0.value)))
      }
    if bare, rng.oneIn(2) { return key }
    if !key.contains("'"), !Self.hasControl(key), rng.oneIn(2) { return "'" + key + "'" }
    return TOMLWriter.string(key)
  }

  mutating func string(_ text: String) -> String {
    switch rng.below(4) {
    case 0 where !text.unicodeScalars.contains("'") && !Self.hasControl(text):
      return "'" + text + "'"
    case 1:
      // Multi-line basic: raw newlines, every quote escaped.
      var body = ""
      for scalar in text.unicodeScalars {
        switch scalar {
        case "\n": body += "\n"
        case "\"": body += "\\\""
        case "\\": body += "\\\\"
        case _ where scalar.value < 0x20 && scalar != "\t" || scalar.value == 0x7F:
          body += String(format: "\\U%08X", scalar.value)
        default: body.unicodeScalars.append(scalar)
        }
      }
      // The newline right after the opening delimiter is not content.
      return "\"\"\"\n" + body + "\"\"\""
    case 2
    where !text.unicodeScalars.contains("'") && !Self.hasControl(text, allowing: ["\n"]):
      return "'''\n" + text + "'''"
    default: return TOMLWriter.string(text)
    }
  }

  mutating func integer(_ value: Int64) -> String {
    switch rng.below(4) {
    case 0 where value >= 0:
      let (prefix, radix) = rng.element([("0x", 16), ("0o", 8), ("0b", 2)])
      let digits = String(value, radix: radix, uppercase: rng.oneIn(2))
      return prefix + digits
    case 1 where value > 0: return "+" + String(value)
    case 2:
      // Underscores between every group of three digits.
      let digits = Array(String(value.magnitude))
      var grouped = ""
      for (index, digit) in digits.enumerated() {
        if index > 0, (digits.count - index) % 3 == 0 { grouped += "_" }
        grouped.append(digit)
      }
      return (value < 0 ? "-" : "") + grouped
    default: return String(value)
    }
  }

  mutating func datetime(_ text: String) -> String {
    var bytes = Array(text.utf8)
    if bytes.count > 10, bytes[10] == UInt8(ascii: "T") {
      bytes[10] = rng.element([UInt8(ascii: "T"), UInt8(ascii: "t"), UInt8(ascii: " ")])
    }
    if bytes.last == UInt8(ascii: "Z"), rng.oneIn(2) { bytes[bytes.count - 1] = UInt8(ascii: "z") }
    return String(decoding: bytes, as: UTF8.self)
  }

  mutating func value(_ value: TOMLValue) -> String {
    switch value {
    case .string(let text): return string(text)
    case .integer(let number): return integer(number)
    case .datetime(let text): return datetime(text)
    case .array(let elements) where !elements.isEmpty && rng.oneIn(2):
      // Multi-line array with comments and a trailing comma.
      var text = "["
      for element in elements {
        text += rng.oneIn(2) ? "\n  " : " "
        text += self.value(element) + ","
        if rng.oneIn(3) { text += " # " + comment() + "\n" }
      }
      return text + "\n]"
    case .array(let elements):
      return "[" + elements.map { self.value($0) }.joined(separator: ", ") + "]"
    case .table(let table):
      return "{"
        + table.sortedKeys.map { key($0) + " = " + self.value(table[$0]!) }
        .joined(separator: ", ") + "}"
    default: return TOMLWriter.inline(value)
    }
  }

  /// `table`'s entries in the current section, each subtable as a dotted
  /// prefix, inline, or a header after the section's own entries.
  mutating func body(_ table: TOMLTable, path: [String], prefix: [String]) -> [(
    [String], TOMLTable
  )] {
    var deferred: [([String], TOMLTable)] = []
    for name in table.sortedKeys {
      let entry = table[name]!
      if case .table(let child) = entry {
        switch rng.below(3) {
        case 0 where !child.isEmpty:
          deferred += body(child, path: path, prefix: prefix + [name])
          continue
        case 1:
          deferred.append((path + prefix + [name], child))
          continue
        default: break
        }
      }
      out += (prefix + [name]).map { key($0) }.joined(separator: rng.element([".", " . "]))
      out += rng.element([" = ", "=", " =\t"]) + value(entry)
      lineEnd()
    }
    return deferred
  }

  mutating func document(_ table: TOMLTable) -> String {
    var pending = body(table, path: [], prefix: [])
    while !pending.isEmpty {
      let (path, child) = pending.removeFirst()
      out += "[" + path.map { key($0) }.joined(separator: ".") + "]"
      lineEnd()
      pending = body(child, path: path, prefix: []) + pending
    }
    return out
  }
}

@Test func codexTOMLReadsEveryEquivalentSpellingAsTheSameTable() {
  expectHolds(
    checkProperty(
      "TOMLTable.parse equivalent spellings", iterations: 600,
      generate: { rng -> (TOMLTable, String) in
        let table = tomlTable(&rng, depth: 3)
        var speller = TOMLSpeller(rng: PropertyRNG(seed: rng.next()))
        return (table, speller.document(table))
      },
      property: { (table: TOMLTable, document: String) -> String? in
        let parsed: TOMLTable
        do { parsed = try TOMLTable.parse(document) } catch {
          return "refused: \(error)\n  document: \(printable(document))"
        }
        return exactlyEqual(parsed, table)
          ? nil : "parsed table differs\n  document: \(printable(document))"
      }))
}
