// Property tests for IsoCore's trust-boundary encoders and parsers; the
// generator and reproduction knobs are in IsoPropertyTesting.

import Foundation
import IsoPropertyTesting
import Testing

@testable import IsoCore

private func expectHolds(
  _ failure: PropertyFailure?, sourceLocation: SourceLocation = #_sourceLocation
) {
  if let failure {
    Issue.record(Comment(rawValue: failure.description), sourceLocation: sourceLocation)
  }
}

// MARK: - Shell quoting

/// A POSIX `sh` word splitter for the subset a quoted command may contain:
/// blanks, single quotes and backslash escapes. Any other unquoted shell
/// metacharacter is reported, since the guest shell would interpret it.
private func shellWords(_ command: String) -> Result<[[UInt8]], ShellModelError> {
  let bytes = Array(command.utf8)
  var words: [[UInt8]] = []
  var current: [UInt8] = []
  var inWord = false
  var index = 0
  while index < bytes.count {
    let byte = bytes[index]
    switch byte {
    case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"):
      if inWord { words.append(current) }
      current = []
      inWord = false
    case UInt8(ascii: "'"):
      guard let close = bytes[(index + 1)...].firstIndex(of: UInt8(ascii: "'")) else {
        return .failure(.unterminatedQuote)
      }
      current += bytes[(index + 1)..<close]
      inWord = true
      index = close
    case UInt8(ascii: "\\"):
      guard index + 1 < bytes.count else { return .failure(.danglingEscape) }
      current.append(bytes[index + 1])
      inWord = true
      index += 1
    default:
      if Array("\"$`;|&<>()*?[]{}~#!".utf8).contains(byte) {
        return .failure(.unquotedMetacharacter(Character(Unicode.Scalar(byte))))
      }
      current.append(byte)
      inWord = true
    }
    index += 1
  }
  if inWord { words.append(current) }
  return .success(words)
}

private enum ShellModelError: Error, Equatable {
  case unterminatedQuote, danglingEscape
  case unquotedMetacharacter(Character)
}

@Test func remoteCommandArgumentsAreExactlyOneLiteralWordEach() {
  expectHolds(
    checkProperty(
      "RemoteCommand words", iterations: 2000,
      generate: { rng in (0..<rng.int(0...4)).map { _ in rng.string(maxScalars: 16) } },
      property: { values in
        var command = RemoteCommand().literal("cmd")
        for value in values { command = command.literal(" ").arg(value) }
        let expected = [Array("cmd".utf8)] + values.map { Array($0.utf8) }
        switch shellWords(command.rendered) {
        case .success(let words) where words == expected: return nil
        case .success(let words):
          return "split into \(words.count) words, expected \(expected.count)"
        case .failure(let error): return "\(error) in \(command.rendered)"
        }
      }))
}

@Test func shellWordIsPlainOnlyForSafeWords() {
  let safe = Set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=".unicodeScalars)
  expectHolds(
    checkProperty(
      "shellWord", iterations: 2000, generate: { $0.string(maxScalars: 10) },
      property: { value in
        let word = shellWord(value)
        let plain = !value.isEmpty && value.unicodeScalars.allSatisfy(safe.contains)
        if plain { return word == value ? nil : "safe word was quoted" }
        guard word == shellEscape(value) else { return "unsafe word was not escaped" }
        return shellWords(word) == .success([Array(value.utf8)]) ? nil : "not one literal word"
      }))
}

/// The model above against the real `/bin/sh`: one shell prints every
/// generated value back NUL-separated. The script goes in on stdin because
/// Foundation's `Process` decomposes (NFD) its arguments; production spawns
/// through `posix_spawn`. NUL cannot reach a shell word, so it is left out.
@Test func shellEscapeRoundTripsGeneratedValuesThroughSh() throws {
  var rng = PropertyRNG(seed: defaultPropertySeed)
  let values = (0..<300).map { _ in
    String(
      String.UnicodeScalarView(rng.string(maxScalars: 24).unicodeScalars.filter { $0 != "\0" }))
  }
  let script = "printf '%s\\0'" + values.map { " " + shellWord($0) }.joined() + "\n"
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-s"]
  process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
  let input = Pipe()
  let pipe = Pipe()
  process.standardInput = input
  process.standardOutput = pipe
  try process.run()
  try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
  try input.fileHandleForWriting.close()
  let output = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)
  let printed = output.split(separator: 0, omittingEmptySubsequences: false).dropLast()
  #expect(printed.count == values.count)
  for (index, (value, bytes)) in zip(values, printed).enumerated()
  where Array(bytes) != Array(value.utf8) {
    let hex = { (bytes: [UInt8]) in bytes.map { String($0, radix: 16) }.joined(separator: " ") }
    Issue.record(
      "value \(index): sh printed [\(hex(Array(bytes)))] for [\(hex(Array(value.utf8)))]")
    break
  }
}

// MARK: - Display neutralization

private func unsafeForDisplay(_ scalar: Unicode.Scalar) -> Bool {
  let category = scalar.properties.generalCategory
  return (category == .control && scalar != "\n" && scalar != "\t") || category == .format
    || scalar.properties.isBidiControl
}

@Test func neutralizeControlsRemovesEveryTerminalControlAndKeepsTheRest() {
  expectHolds(
    checkProperty(
      "neutralizeControls", iterations: 2000, generate: { $0.string(maxScalars: 24) },
      property: { text in
        let input = Array(text.unicodeScalars)
        let output = Array(neutralizeControls(text).unicodeScalars)
        guard output.count == input.count else { return "scalar count changed" }
        for (before, after) in zip(input, output) {
          if unsafeForDisplay(before) {
            guard after == "?" else { return "kept U+\(String(before.value, radix: 16))" }
          } else if after != before {
            return "changed safe U+\(String(before.value, radix: 16))"
          }
        }
        let display = sanitizeForDisplay(text)
        guard display == neutralizeControls(text.trimmingUnicodeWhitespace()) else {
          return "sanitizeForDisplay is not trim + neutralize"
        }
        return display.unicodeScalars.contains(where: unsafeForDisplay)
          ? "display kept a control" : nil
      }))
}

// MARK: - Parsers

/// Rust `Ipv4Addr::from_str` grammar, written independently of the parser.
private func referenceIPv4(_ text: String) -> [UInt8]? {
  let parts = text.split(separator: ".", omittingEmptySubsequences: false)
  guard parts.count == 4 else { return nil }
  var octets: [UInt8] = []
  for part in parts {
    let digits = Array(part.unicodeScalars)
    guard (1...3).contains(digits.count), digits.allSatisfy({ ("0"..."9").contains($0) }),
      digits.count == 1 || digits.first != "0"
    else { return nil }
    let value = digits.reduce(0) { $0 * 10 + Int($1.value - 48) }
    guard value <= 255 else { return nil }
    octets.append(UInt8(value))
  }
  return octets
}

@Test func ipv4AddressAcceptsExactlyTheDottedQuadGrammar() {
  let pieces = ["0", "1", "9", "00", "01", "10", "99", "255", "256", "300", "999", "1000", ""]
  let noise = ["", " ", "+", "-", "\u{0661}", "\u{FF11}", "x", "\n", "."]
  expectHolds(
    checkProperty(
      "IPv4Address", iterations: 3000,
      generate: { rng in
        var parts = (0..<rng.element([3, 4, 4, 4, 5])).map { _ in rng.element(pieces) }
        if rng.oneIn(4) {
          let at = rng.below(parts.count)
          parts[at].insert(contentsOf: rng.element(noise), at: parts[at].startIndex)
        }
        return parts.joined(separator: ".")
      },
      property: { text in
        let parsed = try? IPv4Address(text)
        switch (parsed, referenceIPv4(text)) {
        case (nil, nil): return nil
        case (let parsed?, let expected?):
          guard parsed.octets == expected else { return "wrong octets" }
          return parsed.description == text ? nil : "description is not the input"
        case (nil, _?): return "rejected a valid address"
        case (_?, nil): return "accepted an invalid address"
        }
      }))
}

@Test func repoSlugParsesEveryGitHubURLFormOfAValidSlug() {
  let urlPrefixes = [
    "https://github.com/", "http://github.com/", "ssh://git@github.com/", "git@github.com:",
  ]
  func segment(_ rng: inout PropertyRNG) -> String {
    while true {
      let value = rng.string(maxScalars: 8, [.asciiWord])
      if !value.isEmpty, value != ".", value != ".." { return value }
    }
  }
  expectHolds(
    checkProperty(
      "RepoSlug.parse valid", iterations: 2000,
      generate: { rng in
        let slug = segment(&rng) + "/" + segment(&rng)
        var url = rng.element(urlPrefixes) + slug
        let suffixed = slug.hasSuffix(".git") || !rng.oneIn(2)
        if suffixed { url += ".git" }
        url += String(repeating: "/", count: rng.int(0...3))
        let padding = { (rng: inout PropertyRNG) in rng.string(maxScalars: 2, [.whitespace]) }
        return (slug, padding(&rng) + url + padding(&rng))
      },
      property: { (slug: String, url: String) -> String? in
        RepoSlug.parse(url: url)?.rawValue == slug ? nil : "did not parse back to " + slug
      }))

  let hostile: [ScalarClass] = [
    .shellMeta, .whitespace, .c0Control, .c1Control, .format, .bidi, .combining, .nonASCII, .astral,
  ]
  expectHolds(
    checkProperty(
      "RepoSlug.parse hostile", iterations: 2000,
      generate: { rng in
        var slug = Array((segment(&rng) + "/" + segment(&rng)).unicodeScalars)
        let bad = rng.oneIn(8) ? "/" : rng.scalar(hostile)
        slug.insert(bad, at: rng.below(slug.count + 1))
        return rng.element(urlPrefixes) + String(String.UnicodeScalarView(slug)) + ".git"
      },
      property: { url in
        RepoSlug.parse(url: url).map { "accepted \($0.rawValue)" }
      }))
}

// MARK: - Machine output

private func expectedDecode(_ value: GeneratedJSON) -> GeneratedJSON {
  switch value {
  case .double(let number) where number == number.rounded() && abs(number) < 0x1p63:
    return .int(Int64(number))
  case .array(let values): return .array(values.map(expectedDecode))
  case .object(let members): return .object(members.map { ($0.0, expectedDecode($0.1)) })
  default: return value
  }
}

private func outputJSON(_ value: GeneratedJSON) -> OutputJSON {
  switch value {
  case .null: .null
  case .bool(let value): .bool(value)
  case .int(let value): .int(value)
  case .uint(let value): .uint(value)
  case .double(let value): .double(value)
  case .string(let value): .string(value)
  case .array(let values): .array(values.map(outputJSON))
  case .object(let members): .object(members.map { ($0.0, outputJSON($0.1)) })
  }
}

/// Structural, scalar-exact difference: `String ==` would hide a change of
/// normalization, and `OutputJSON ==` compares rendered text.
private func difference(_ decoded: OutputJSON, _ expected: GeneratedJSON) -> String? {
  switch (decoded, expected) {
  case (.null, .null): return nil
  case (.bool(let a), .bool(let b)): return a == b ? nil : "bool"
  case (.int(let a), .int(let b)): return a == b ? nil : "int \(a) != \(b)"
  case (.uint(let a), .uint(let b)): return a == b ? nil : "uint"
  case (.double(let a), .double(let b)): return a == b ? nil : "double \(a) != \(b)"
  case (.string(let a), .string(let b)):
    return Array(a.unicodeScalars) == Array(b.unicodeScalars) ? nil : "string scalars changed"
  case (.array(let a), .array(let b)):
    guard a.count == b.count else { return "array length" }
    return zip(a, b).lazy.compactMap(difference).first
  case (.object(let a), .object(let b)):
    guard a.count == b.count else { return "object size" }
    for (key, value) in b {
      guard let match = a.first(where: { Array($0.0.unicodeScalars) == Array(key.unicodeScalars) })
      else { return "key scalars changed or missing" }
      if let diff = difference(match.1, value) { return diff }
    }
    return nil
  default: return "type changed: \(decoded.compactRendered()) for \(expected)"
  }
}

@Test func outputJSONRoundTripsGuestShapedValuesExactly() {
  expectHolds(
    checkProperty(
      "OutputJSON round trip", iterations: 1000, generate: { $0.json(depth: 3) },
      property: { generated in
        let value = outputJSON(generated)
        for text in [value.compactRendered(), value.rendered()] {
          let bytes = Array(text.utf8)
          let layout = text == value.rendered() ? [UInt8(ascii: "\n")] : []
          if let raw = bytes.first(where: { $0 < 0x20 && !layout.contains($0) }) {
            return "raw control byte 0x\(String(raw, radix: 16)) in output"
          }
          guard let decoded = try? JSONDecoder().decode(OutputJSON.self, from: Data(bytes)) else {
            return "output is not decodable JSON"
          }
          if let diff = difference(decoded, expectedDecode(generated)) { return diff }
        }
        return nil
      }))
}
