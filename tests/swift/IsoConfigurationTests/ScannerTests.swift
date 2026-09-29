import Foundation
import Testing

@testable import IsoConfiguration

private func strip(_ text: String, _ policy: JSONCSyntaxPolicy = .configuration) throws -> String {
  String(decoding: try JSONCScanner.strip(Array(text.utf8), policy: policy), as: UTF8.self)
}

@Test func lineAndBlockCommentsBecomeSpaces() throws {
  #expect(try strip("{\"a\": 1} // tail") == "{\"a\": 1}        ")
  #expect(try strip("a/* c */b") == "a       b")
  #expect(try strip("a/** b **/c") == "a         c")
}

@Test func commentsSeparateAdjacentTokens() throws {
  // Baseline removed comments outright ("1/**/2" -> "12"); spaces keep the
  // tokens apart, so the result is rejected instead of silently merged.
  #expect(try strip("[1/**/2]") == "[1    2]")
  #expect(throws: ConfigError.self) { try ConfigLoader.load(bytes: "{\"ssh_port\": 2/**/2}") }
}

@Test func commentMarkersInsideStringsAreData() throws {
  let text = #"{"url": "https://example.com/a//b", "glob": "/* not a comment */"}"#
  #expect(try strip(text) == text)
}

@Test func escapedQuotesAndBackslashRunsKeepStringState() throws {
  let quote = #"{"a": "x\"// still string", "b": 1}"#
  #expect(try strip(quote) == quote)
  let evenRun = #"{"a": "x\\"} // comment"#
  #expect(try strip(evenRun) == #"{"a": "x\\"}           "#)
  let oddRun = #"{"a": "x\\\"//y"}"#
  #expect(try strip(oddRun) == oddRun)
}

@Test func unicodeAndLineEndingsArePreserved() throws {
  #expect(
    try strip("{\"é\": \"日本\"} // ✓ comment") == "{\"é\": \"日本\"}"
      + String(repeating: " ", count: 15))
  #expect(try strip("{\r\n// c\r\n\"a\": 1\r\n}") == "{\r\n    \r\n\"a\": 1\r\n}")
  #expect(try strip("{/* a\nb */}") == "{    \n    }")
}

@Test func commentAtEndOfInput() throws {
  #expect(try strip("{} //") == "{}   ")
  #expect(try strip("{} /**/") == "{}     ")
  #expect(try strip("{} /") == "{} /")
}

@Test func unterminatedBlockCommentIsRejectedForConfiguration() {
  #expect(
    throws: JSONCScanError(
      kind: .unterminatedBlockComment, location: SourceLocation(line: 2, column: 3))
  ) {
    try strip("{\n  /* open")
  }
  #expect(throws: JSONCScanError.self) { try strip("{} /* *") }
}

@Test func devcontainerPolicyKeepsBaselineLeniency() throws {
  #expect(try strip("{\"a\": [1, 2,], }", .devcontainer) == "{\"a\": [1, 2 ]  }")
  #expect(
    try strip("[1, /* c */ ]", .devcontainer) == "[1" + String(repeating: " ", count: 10) + "]")
  #expect(try strip("{\"a\": \",}\"}", .devcontainer) == "{\"a\": \",}\"}")
  #expect(try strip("{} /* open", .devcontainer) == "{}" + String(repeating: " ", count: 8))
  // A run of trailing commas is all blanked (fuzz regression; baseline behavior).
  #expect(try strip("[2, ,]", .devcontainer) == "[2   ]")
  // Configuration policy leaves trailing commas for the preflight to reject.
  #expect(try strip("[1,]") == "[1,]")
}

@Test func invalidUTF8IsRejected() {
  #expect(throws: JSONCScanError(kind: .invalidUTF8, location: nil)) {
    try JSONCScanner.strip([0x7B, 0xFF, 0x7D], policy: .configuration)
  }
  #expect(throws: ConfigError.self) {
    try ConfigLoader.parse(
      [0x7B, 0xC3, 0x7D], format: .json, path: "c.json", limits: .configuration)
  }
}

@Test func outputLengthAlwaysMatchesInput() throws {
  var generator = SystemRandomNumberGenerator()
  let alphabet = Array("{}[],:\"\\/*\n\r ab1".utf8)
  for _ in 0..<2_000 {
    let length = Int.random(in: 0..<64, using: &generator)
    let bytes = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }
    for policy in [JSONCSyntaxPolicy.configuration, .devcontainer] {
      if let out = try? JSONCScanner.strip(bytes, policy: policy) {
        #expect(out.count == bytes.count)
        #expect(zip(bytes, out).allSatisfy { $0 == $1 || $1 == UInt8(ascii: " ") })
      }
    }
  }
}
