import Foundation
import IsoShell
import Testing

/// Runs `printf '%s' WORD` through `/bin/sh` and returns what it printed.
private func shellPrints(_ word: String) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = ["-c", "printf '%s' " + word]
  let output = Pipe()
  process.standardOutput = output
  try process.run()
  let bytes = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return String(decoding: bytes, as: UTF8.self)
}

@Test func shellEscapeQuotesOneLiteralWord() throws {
  #expect(shellEscape("it's") == "'it'\\''s'")
  #expect(shellEscape("") == "''")
  #expect(shellWord("a-b_c./:=") == "a-b_c./:=")
  #expect(shellWord("a b") == "'a b'")
  #expect(shellWord("") == "''")
  #expect(RemoteCommand().literal("ls ").arg("$HOME").rendered == "ls '$HOME'")
}

/// An apostrophe followed by a combining mark is one `Character` but still
/// closes a quoted shell word, so escaping must work per scalar.
@Test func shellEscapeSurvivesACombiningMarkAfterAnApostrophe() throws {
  let value = "x'\u{301}; echo injected #"
  for word in [shellEscape(value), shellWord(value), RemoteCommand().arg(value).rendered] {
    #expect(try shellPrints(word) == value)
  }
}

@Test func yamlAndScalarReplacementWorkPerScalar() {
  #expect(yamlSingleQuoted("it's") == "'it''s'")
  #expect(yamlSingleQuoted("x'\u{301}") == "'x''\u{301}'")
  #expect(replacingScalars("{'\u{301}}") { $0 == "'" ? "''" : nil } == "{''\u{301}}")
}
