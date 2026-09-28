import CoopCore
import Testing

@testable import CoopSecrets

private func parse(_ text: String) throws -> [String: EnvValue] {
  Dictionary(
    try EnvFile.parse(text).map { ($0.0.rawValue, $0.1) }, uniquingKeysWith: { $1 })
}

@Test func envFileGrammar() throws {
  let entries = try parse(
    [
      "A=x",
      #"B="x y""#,
      "C='x # y'",
      "export D=z",
      "E=x # comment",
      "F=https://example.com/#frag",
      "G=",
      "H=  padded  ",
      "# full comment",
      "   # indented comment",
      "",
      #"I="quoted" # trailing"#,
      #"J={"json":true}"#,
      "K=a=b",
    ].joined(separator: "\n"))
  #expect(entries["A"] == .literal("x"))
  #expect(entries["B"] == .literal("x y"))
  #expect(entries["C"] == .literal("x # y"))
  #expect(entries["D"] == .literal("z"))
  #expect(entries["E"] == .literal("x"))
  #expect(entries["F"] == .literal("https://example.com/#frag"))
  #expect(entries["G"] == .literal(""))
  #expect(entries["H"] == .literal("  padded"))
  #expect(entries["I"] == .literal("quoted"))
  #expect(entries["J"] == .literal(#"{"json":true}"#))
  #expect(entries["K"] == .literal("a=b"))
  #expect(entries.count == 11)
}

@Test func envFileNeverExpandsOrExecutes() throws {
  let entries = try parse("A=$(id)\nB=`id`\nC=$HOME\nD=\"$HOME\"")
  #expect(entries["A"] == .literal("$(id)"))
  #expect(entries["B"] == .literal("`id`"))
  #expect(entries["C"] == .literal("$HOME"))
  #expect(entries["D"] == .literal("$HOME"))
}

@Test func envFileRejectsMalformedLines() {
  for bad in [
    "NOEQUALS", "1A=x", "A-B=x", "A=\"open", "A='open", "A=\"x\" trailing", "=x", "A B=x",
  ] {
    #expect(throws: ValidationError.self, "\(bad)") { try EnvFile.parse(bad) }
  }
}

@Test func secretReferencesAreWholeValuesOnly() throws {
  #expect(try EnvValue.parse("{vault:secret}") == .secret(try SecretName("secret")))
  #expect(try parse("S={vault:db-pass}")["S"] == .secret(try SecretName("db-pass")))
  #expect(try parse("S=\"{vault:db}\"")["S"] == .secret(try SecretName("db")))
  for bad in [
    "{vault:}", "{vault:../../x}", "prefix-{vault:secret}", "{vault:secret}-suffix",
    "postgres://u:{vault:pw}@h/db", "{vault:a}{vault:b}", "{vault:a b}",
  ] {
    #expect(throws: ValidationError.self, "\(bad)") { try EnvValue.parse(bad) }
  }
  #expect(try EnvValue.parse("{notvault:x}") == .literal("{notvault:x}"))
}

@Test func crlfFilesSplitIntoLinesAndStrayCarriageReturnsFail() throws {
  let entries = try parse("# c\r\nDB={vault:db}\r\nFOO=1\r\n")
  #expect(entries["DB"] == .secret(try SecretName("db")))
  #expect(entries["FOO"] == .literal("1"))
  #expect(entries.count == 2)
  #expect(throws: ValidationError.self) { try EnvFile.parse("A=1\rB=2") }
  #expect(throws: ValidationError.self) { try EnvFile.parse("A=1\u{2028}B=2") }
}
