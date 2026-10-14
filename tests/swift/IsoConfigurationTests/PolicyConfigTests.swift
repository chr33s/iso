import Foundation
import IsoCore
import IsoPolicy
import Testing

@testable import IsoConfiguration

private func policyError(_ text: String) -> (field: String, reason: String)? {
  do {
    _ = try ConfigLoader.load(bytes: text, environment: fixtureHome)
    return nil
  } catch {
    if case .invalidField(_, let field, let reason) = error { return (field, reason) }
    Issue.record("unexpected error \(error)")
    return nil
  }
}

/// The exact-byte fixtures shared with IsoPolicy and iso-proxy.
private func sharedFixture(_ name: String) throws -> String {
  let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let path = root.appendingPathComponent("iso-policy/Tests/IsoPolicyTests/Fixtures/" + name).path
  var text = try String(contentsOfFile: path, encoding: .utf8)
  if text.hasSuffix("\n") { text.removeLast() }
  return text
}

private let anthropicOnly = """
  "security": { "preset": "provider-only" },
  "proxy": { "mode": "required", "anthropic": { "credential": "vault:anthropic", "auth": "api_key" } },
  "workspace": { "pull": { "mode": "stage" } },
  """

@Test func absentPolicyKeepsExistingBehavior() throws {
  #expect(try ConfigLoader.load(bytes: "{}", environment: fixtureHome).policy == nil)
}

@Test func specificationExampleMatchesTheSharedCanonicalFixture() throws {
  let policy = try sharedFixture("example-policy.json")
  let config = try ConfigLoader.load(
    bytes: "{\(anthropicOnly) // JSONC comments are fine\n \"policy\": \(policy)}",
    environment: fixtureHome)
  let compiled = try #require(config.policy)
  #expect(compiled.canonicalJSON == (try sharedFixture("example-policy.canonical.json")))
  #expect(compiled.digest == (try sharedFixture("example-policy.digest")))
  #expect(compiled.enforcesProviderActions)
  #expect(compiled.enforces(.workspacePullApply))
}

@Test func templateDocumentsAValidPolicy() throws {
  // The commented example in the template must stay a valid policy.
  let template = ConfigTemplate.jsonc
  let start = try #require(template.range(of: "// \"policy\": {"))
  let end = try #require(template.range(of: "// },", range: start.upperBound..<template.endIndex))
  let body = template[start.lowerBound..<end.upperBound].split(separator: "\n").map {
    $0.trimmingCharacters(in: .whitespaces).dropFirst(3)
  }.joined(separator: "\n").dropLast()
  let config = try ConfigLoader.load(bytes: "{\(anthropicOnly) \(body)}", environment: fixtureHome)
  #expect(config.policy?.mode == .enforce)
}

@Test func structuralAndNumericErrorsUseTheExistingPipeline() throws {
  let valid =
    #"{"version": 1, "mode": "shadow", "actions": ["proxy.request"], "rules": [], "guards": []}"#
  #expect(policyError("{\"policy\": \(valid)}") == nil)
  let cases: [(String, String, String)] = [
    (#"{"policy": null}"#, "policy", "must not be null"),
    (
      "{\"policy\": \(valid.replacingOccurrences(of: "\"guards\"", with: "\"when\": 1, \"guards\""))}",
      "policy.when", "unknown field"
    ),
    (
      "{\"policy\": \(valid.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 1.0"))}",
      "policy.version", "integer literal"
    ),
    (
      "{\"policy\": \(valid.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 1e0"))}",
      "policy.version", "integer literal"
    ),
    (
      "{\"policy\": \(valid.replacingOccurrences(of: "\"version\": 1", with: "\"version\": true"))}",
      "policy.version", "expected an integer"
    ),
    (
      "{\"policy\": \(valid.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 99999999999999999999"))}",
      "policy.version", "integer literal"
    ),
    (
      "{\"policy\": \(valid.replacingOccurrences(of: "\"mode\": \"shadow\"", with: "\"mode\": null"))}",
      "policy.mode", "must not be null"
    ),
  ]
  for (text, field, reason) in cases {
    let error = policyError(text)
    #expect(error?.field == field, "\(text)")
    #expect(error?.reason.contains(reason) == true, "\(String(describing: error))")
  }
  // Duplicate keys are refused by the existing preflight, inside policy too.
  #expect(throws: ConfigError.self) {
    try ConfigLoader.load(
      bytes:
        "{\"policy\": {\"version\": 1, \"version\": 1, \"mode\": \"off\", \"actions\": [], \"rules\": [], \"guards\": []}}",
      environment: fixtureHome)
  }
}

@Test func enforcingCombinationsAreRefusedNotRewritten() throws {
  let providers =
    #"{"version": 1, "mode": "enforce", "actions": ["proxy.request"], "rules": [], "guards": []}"#
  let workspace =
    #"{"version": 1, "mode": "enforce", "actions": ["workspace.pull.apply"], "rules": [], "guards": []}"#
  let auto = policyError("{\"proxy\": {\"mode\": \"auto\"}, \"policy\": \(providers)}")
  #expect(auto?.field == "policy.mode")
  #expect(auto?.reason.contains("proxy.mode \"required\"") == true)
  #expect(policyError("{\"proxy\": {\"mode\": \"off\"}, \"policy\": \(providers)}") != nil)
  let chatgpt = policyError(
    "{\"proxy\": {\"mode\": \"required\"}, \"codex\": {\"auth\": \"chatgpt\"}, \"policy\": \(providers)}"
  )
  #expect(chatgpt?.reason.contains("chatgpt") == true)
  #expect(policyError("{\"proxy\": {\"mode\": \"required\"}, \"policy\": \(providers)}") == nil)
  let direct = policyError(
    "{\"workspace\": {\"pull\": {\"mode\": \"direct\"}}, \"policy\": \(workspace)}")
  #expect(direct?.reason.contains("workspace.pull.mode \"stage\"") == true)
  #expect(
    policyError("{\"workspace\": {\"pull\": {\"mode\": \"stage\"}}, \"policy\": \(workspace)}")
      == nil)
  // Shadow observes; it does not require the enforcing combinations.
  let shadow = providers.replacingOccurrences(of: "enforce", with: "shadow")
  #expect(policyError("{\"proxy\": {\"mode\": \"auto\"}, \"policy\": \(shadow)}") == nil)
}

@Test func everyConfigurationCopyKeepsThePolicy() throws {
  // A copy that drops `policy` would record an `off` binding at boot.
  let policy = try sharedFixture("example-policy.json")
  let config = try ConfigLoader.load(
    bytes: "{\(anthropicOnly) \"policy\": \(policy)}", environment: fixtureHome)
  let compiled = try #require(config.policy)
  let copies = [
    config.applyingDevcontainer(vcpus: 4, memory: nil, postStart: "true", guestEnvironment: []),
    config.overridingVM(vcpus: 4, memory: nil, templateSize: nil),
    config.overridingEgress(.none),
    config.replacingGitHub(nil),
    config.disablingGitHub(),
  ]
  for copy in copies { #expect(copy.policy == compiled) }
}
