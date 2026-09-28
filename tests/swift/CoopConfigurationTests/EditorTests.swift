import Foundation
import Testing

@testable import CoopConfiguration

private let reference = CredentialReference(
  "cmd:security find-generic-password -s coop-openai -a openai -w")!

private func upsert(
  _ text: String?, format: ConfigFormat = .jsonc, provider: ProxyProvider = .openai
) throws
  -> JSONValue
{
  let bytes = try ConfigEditor.upsertProxy(
    existing: text.map { Array($0.utf8) }, format: format, path: "c", provider: provider,
    credential: reference,
    auth: .bearer, environment: fixtureHome)
  return try ConfigLoader.parse(bytes, format: .json, path: "c", limits: .configuration)
}

@Test func proxyUpsertPreservesUnrelatedAndUnmodeledValues() throws {
  let original = """
    // comment is dropped
    {
      "future_feature": {"nested": [1, 2.5, "x", null, true, {"deep": 9007199254740993}]},
      "profiles": {"a.b": {"plugins": ["p"]}, "a": {"apt_packages": []}},
      "proxy": {"anthropic": {"credential": "cmd:a", "auth": "api_key"}, "openai": {"credential": "cmd:old", "extra": 1}},
      "vm": {"vcpu_count": 4}
    }
    """
  let result = try upsert(original)
  let before = try ConfigLoader.parse(
    Array(original.utf8), format: .jsonc, path: "c", limits: .configuration)
  #expect(result["future_feature"] == before["future_feature"])
  #expect(result["future_feature"]?["nested"] == before["future_feature"]?["nested"])
  #expect(result["profiles"] == before["profiles"])
  #expect(result["vm"] == before["vm"])
  #expect(result["proxy"]?["anthropic"] == before["proxy"]?["anthropic"])
  #expect(result["proxy"]?["openai"]?["extra"] == .number(.integer(1)))
  #expect(result["proxy"]?["openai"]?["credential"] == .string(reference.command.expose()))
  #expect(result["proxy"]?["openai"]?["auth"] == .string("bearer"))
  // Exact integer above 2^53 survives the edit.
  guard case .array(let nested)? = result["future_feature"]?["nested"],
    case .object(let deep) = nested[5]
  else {
    Issue.record("shape")
    return
  }
  #expect(deep["deep"] == .number(.integer(9_007_199_254_740_993)))
}

@Test func proxyUpsertCreatesMissingDocument() throws {
  let result = try upsert(nil)
  #expect(
    result
      == .object([
        "proxy": .object([
          "openai": .object([
            "credential": .string(reference.command.expose()), "auth": .string("bearer"),
          ])
        ])
      ]))
}

@Test func proxyUpsertRefusesInvalidInputs() {
  #expect(throws: ConfigError.self) { try upsert(#"{"proxy": []}"#) }
  #expect(throws: ConfigError.self) { try upsert(#"{"proxy": {"openai": "x"}}"#) }
  #expect(throws: ConfigError.self) { try upsert(#"{"a": 1,}"#) }
  // The edit result must itself be a valid configuration.
  #expect(throws: ConfigError.self) { try upsert(#"{"firecracker_bin": "/x"}"#) }
  #expect(throws: ConfigError.self) {
    try upsert(#"{"proxy": {"anthropic": {"credential": "literal"}}}"#)
  }
  // An invalid integer spelling is not silently normalized into a valid one.
  #expect(throws: ConfigError.self) { try upsert(#"{"ssh_port": 2.2e1}"#) }
}

@Test func strictJSONFilesStayStrictJSON() throws {
  let bytes = try ConfigEditor.upsertProxy(
    existing: Array(#"{"ssh_port": 22}"#.utf8), format: .json, path: "c.json", provider: .anthropic,
    credential: reference, auth: .apiKey, environment: fixtureHome)
  let text = String(decoding: bytes, as: UTF8.self)
  #expect(!text.contains("//"))
  #expect(try ConfigLoader.load(bytes: text, format: .json).proxy.anthropic?.auth == .apiKey)
}

@Test func semanticEqualityComparesNumbersByValue() {
  #expect(JSONValue.number(.decimal(100)).semanticallyEquals(.number(.integer(100))))
  #expect(
    !JSONValue.number(.decimal(Decimal(string: "0.5")!)).semanticallyEquals(.number(.integer(0))))
  #expect(!JSONValue.object(["a": .null]).semanticallyEquals(.object([:])))
}

@Test func decodedNumbersKeepTheirKind() throws {
  let value = try ConfigLoader.parse(
    Array(
      #"[1, 1.0, 9223372036854775807, 9223372036854775808, 18446744073709551616, -5, 0.1]"#.utf8),
    format: .json, path: "p", limits: .configuration)
  #expect(
    value
      == .array([
        .number(.integer(1)), .number(.decimal(1)), .number(.integer(.max)),
        .number(.unsigned(1 << 63)),
        .number(.decimal(Decimal(string: "18446744073709551616")!)), .number(.integer(-5)),
        .number(.decimal(Decimal(string: "0.1")!)),
      ]))
}
