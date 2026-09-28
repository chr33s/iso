import Foundation
import Testing

@testable import CoopConfiguration

private func check(_ text: String, limits: JSONLimits = .configuration) throws(JSONPreflightError)
  -> JSONPreflightResult
{
  try JSONPreflight.check(Array(text.utf8), limits: limits)
}

private func kind(_ text: String, limits: JSONLimits = .configuration) -> JSONPreflightError.Kind? {
  do {
    _ = try check(text, limits: limits)
    return nil
  } catch {
    return error.kind
  }
}

@Test func acceptsRFC8259Documents() throws {
  for text in [
    "{}", "[]", "0", "-0", "1.5e-3", "\"s\"", "true", "null", " \t\r\n{\"a\": [1, {\"b\": null}]} ",
    #"{"k": "\u00e9\ud83d\ude00\n"}"#,
  ] {
    #expect(throws: Never.self) { try check(text) }
  }
}

@Test func rejectsJSON5AndTrailingCommas() {
  for text in [
    "{\"a\": 1,}", "[1,]", "{a: 1}", "{'a': 1}", "[+1]", "[.5]", "[01]", "[0x10]", "[NaN]",
    "[Infinity]",
    "[-Infinity]", "[1.]", "[1e]", "{\"a\" 1}", "{\"a\": 1 \"b\": 2}", "[\"\\x41\"]", "[\"\\u12\"]",
    "[\"tab\tinside\"]", "{} {}", "", "[", "{\"a\":",
  ] {
    guard case .syntax? = kind(text) else {
      Issue.record(
        "expected syntax error for \(text.debugDescription), got \(String(describing: kind(text)))")
      continue
    }
  }
}

@Test func foundationAloneWouldAcceptTheseSoPreflightMustNot() throws {
  // Evidence for why the preflight exists: Foundation's decoder accepts a
  // trailing comma and a byte-order mark, and silently drops a duplicate key.
  let trailing = Data("{\"a\": 1,}".utf8)
  #expect((try? JSONDecoder().decode([String: Int].self, from: trailing)) != nil)
  let duplicate = Data("{\"a\": 1, \"a\": 2}".utf8)
  #expect((try? JSONDecoder().decode([String: Int].self, from: duplicate))?.count == 1)
  #expect(kind("{\"a\": 1,}") != nil)
  #expect(kind("\u{FEFF}{}") == .byteOrderMark)
}

@Test func duplicateKeysAreDetectedAfterDecoding() {
  #expect(kind(#"{"a": 1, "a": 2}"#) == .duplicateKey(path: "a"))
  #expect(kind(#"{"a": 1, "\u0061": 2}"#) == .duplicateKey(path: "a"))
  #expect(kind(#"{"x": {"k\/": 1, "k/": 2}}"#) == .duplicateKey(path: #"x["k/"]"#))
  // NFC and NFD spellings are one key to Foundation, so one key here too.
  #expect(kind("{\"\u{E9}\": 1, \"e\u{301}\": 2}") != nil)
  #expect(kind(#"{"\ud83d\ude00": 1, "😀": 2}"#) != nil)
  // Same key in different objects is fine.
  #expect(kind(#"{"a": {"k": 1}, "b": {"k": 2}}"#) == nil)
}

@Test func literalDottedKeysStayDistinctFromNesting() throws {
  let value = try ConfigLoader.parse(
    Array(#"{"a.b": 1, "a": {"b": 2}}"#.utf8), format: .json, path: "p", limits: .configuration)
  #expect(value["a.b"] == .number(.integer(1)))
  #expect(value["a"]?["b"] == .number(.integer(2)))
  #expect(renderPath([.key("a.b")]) == #"["a.b"]"#)
  #expect(renderPath([.key("a"), .key("b")]) == "a.b")
}

@Test func unpairedSurrogatesAreRejected() {
  for text in [#"["\ud800"]"#, #"["\udc00"]"#, #"["\ud800\u0041"]"#, #"{"\ud800": 1}"#] {
    guard case .syntax? = kind(text) else {
      Issue.record("expected rejection of \(text)")
      continue
    }
  }
}

@Test func resourceLimitsAreEnforcedBeforeDecoding() {
  let small = JSONLimits(
    maxBytes: 64, maxDepth: 3, maxKeys: 3, maxArrayElements: 2, maxNumberLength: 5,
    maxStringBytes: 8)
  #expect(kind(String(repeating: " ", count: 65), limits: small) == .tooLarge(limit: 64))
  #expect(kind("[[[1]]]", limits: small) == nil)
  #expect(kind("[[[[1]]]]", limits: small) == .tooDeep(limit: 3))
  #expect(kind(#"{"a":1,"b":2,"c":3}"#, limits: small) == nil)
  #expect(kind(#"{"a":1,"b":2,"c":3,"d":4}"#, limits: small) == .tooManyKeys(limit: 3))
  #expect(kind("[1,2]", limits: small) == nil)
  #expect(kind("[1,2,3]", limits: small) == .arrayTooLong(path: "<root>", limit: 2))
  #expect(kind("[12345]", limits: small) == nil)
  #expect(kind("[123456]", limits: small) == .numberTooLong(path: "[0]", limit: 5))
  #expect(kind(#"["1234567"]"#, limits: small) == nil)
  #expect(kind(#"["12345678"]"#, limits: small) == .stringTooLong(path: "[0]", limit: 8))
}

@Test func hostileNestingDoesNotExhaustTheStack() {
  let deep = String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000)
  let limits = JSONLimits(
    maxBytes: 1 << 20, maxDepth: 32, maxKeys: 10, maxArrayElements: 10, maxNumberLength: 10,
    maxStringBytes: 10)
  #expect(kind(deep, limits: limits) == .tooDeep(limit: 32))
}

@Test func fractionalLiteralsAreRecordedByPath() throws {
  let result = try check(#"{"a": 1, "b": 1.0, "c": [2, 3e0], "d": {"e": -0.5}}"#)
  #expect(
    result.fractionalNumberPaths == [[.key("b")], [.key("c"), .index(1)], [.key("d"), .key("e")]])
}

@Test func syntaxErrorsReportLineAndColumnWithoutContent() {
  do {
    _ = try check("{\n  \"token\": sk-secret\n}")
    Issue.record("expected failure")
  } catch {
    #expect(error.location == SourceLocation(line: 2, column: 12))
    #expect(!error.description.contains("sk-secret"))
  }
}
