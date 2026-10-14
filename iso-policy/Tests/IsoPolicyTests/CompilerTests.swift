import Foundation
import Testing

@testable import IsoPolicy

@Test func exampleCanonicalizesToTheSharedFixture() throws {
  let source = String(decoding: try fixture("example-policy.json"), as: UTF8.self)
  let compiled = try compile(source)
  #expect(compiled.canonicalBytes == (try fixture("example-policy.canonical.json")))
  #expect(compiled.digest == String(decoding: try fixture("example-policy.digest"), as: UTF8.self))
  // Canonical bytes decode to the same compiled policy, byte for byte.
  #expect(try PolicyCanonical.decode(compiled.canonicalBytes) == compiled)
}

@Test func digestIsStableUnderReorderingButNotUnderMeaningfulChange() throws {
  let a = try compile(
    policyJSON(
      actions: ["proxy.request", "credential.use"],
      rules: rule("b", "permit", "proxy.request", ["provider:openai", "provider:anthropic"]) + ","
        + rule("a", "permit", "credential.use", ["provider:anthropic"], instances: ["z", "a"])))
  let b = try compile(
    policyJSON(
      actions: ["credential.use", "proxy.request"],
      rules: rule("a", "permit", "credential.use", ["provider:anthropic"], instances: ["a", "z"])
        + "," + rule("b", "permit", "proxy.request", ["provider:anthropic", "provider:openai"])))
  #expect(a.digest == b.digest)
  #expect(a.canonicalBytes == b.canonicalBytes)
  let shadow = try compile(
    policyJSON(
      mode: "shadow", actions: ["credential.use", "proxy.request"],
      rules: rule("a", "permit", "credential.use", ["provider:anthropic"], instances: ["a", "z"])
        + "," + rule("b", "permit", "proxy.request", ["provider:anthropic", "provider:openai"])))
  #expect(shadow.digest != a.digest)
}

@Test func canonicalDecodeRefusesAlternativeSpellings() throws {
  let canonical = try fixture("example-policy.canonical.json")
  let text = String(decoding: canonical, as: UTF8.self)
  for variant in [
    text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
    text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1e0"),
    text.replacingOccurrences(of: "{\"actions\"", with: "{ \"actions\""),
    text.replacingOccurrences(of: "\"version\":1}", with: "\"version\":1,\"version\":1}"),
    text.replacingOccurrences(of: "\"seconds\":900", with: "\"seconds\":true"),
    String(decoding: try fixture("example-policy.json"), as: UTF8.self),
  ] {
    #expect(throws: PolicyError.self) { try PolicyCanonical.decode(Array(variant.utf8)) }
  }
  #expect(throws: PolicyError.self) {
    try PolicyCanonical.decode([UInt8](repeating: 0x20, count: 64 * 1024 + 1))
  }
}

@Test func structuralErrorsNameTheField() throws {
  func reason(_ json: String) -> String? { compileError(json)?.description }
  #expect(reason("{}")?.contains("policy.version: missing required field") == true)
  #expect(
    reason(policyJSON().replacingOccurrences(of: "\"guards\"", with: "\"extra\":1,\"guards\""))
      == "policy.extra: unknown field")
  #expect(
    reason(policyJSON().replacingOccurrences(of: "\"guards\":[]", with: "\"guards\":null"))
      == "policy.guards: must not be null")
  #expect(reason(policyJSON(mode: "audit"))?.hasPrefix("policy.mode: unsupported value") == true)
  #expect(
    reason(policyJSON(actions: ["network.connect"]))?.hasPrefix(
      "policy.actions[0]: unsupported value") == true)
  #expect(
    reason(policyJSON(rules: rule("a", "permit", "proxy.request", ["provider:*"])))?.hasPrefix(
      "policy.rules[0].resources[0]: unsupported value") == true)
  #expect(
    reason(
      policyJSON(rules: rule("a", "permit", "proxy.request", ["provider:anthropic"]))
        .replacingOccurrences(
          of: "\"resources\"", with: "\"when\":{},\"resources\""))
      == "policy.rules[0].when: unknown field")
  // A hostile key is not echoed.
  #expect(
    reason(
      policyJSON().replacingOccurrences(of: "\"guards\"", with: "\"\\u001b[31m\":1,\"guards\""))
      == "policy.<unrecognized>: unknown field")
}

@Test func numericFormsAreStrict() throws {
  var document = try #require(
    try tree(policyJSON(guards: rateGuard("g", max: 5, within: 60))).objectMembers)
  // A fraction, exponent or overflowing literal reaches the parser as number(nil).
  var guards = try #require(document["guards"]?.arrayItems)
  var entry = try #require(guards[0].objectMembers)
  entry["require"] = .object([
    "rate_limit": .object(["max_requests": .number(nil), "within_seconds": .number(60)])
  ])
  guards[0] = .object(entry)
  document["guards"] = .array(guards)
  #expect(throws: PolicyError.self) { try PolicyDocument.parse(.object(document)) }
  entry["require"] = .object([
    "rate_limit": .object(["max_requests": .bool(true), "within_seconds": .number(60)])
  ])
  guards[0] = .object(entry)
  document["guards"] = .array(guards)
  #expect(throws: PolicyError.self) { try PolicyDocument.parse(.object(document)) }
}

@Test func semanticValidation() throws {
  let request = "proxy.request"
  let cases: [(String, String)] = [
    (policyJSON(mode: "enforce", actions: []), "policy.actions: must not be empty"),
    (policyJSON(actions: ["proxy.request", "proxy.request"]), "policy.actions: duplicate action"),
    (
      policyJSON(
        actions: ["credential.use"], rules: rule("a", "permit", request, ["provider:anthropic"])),
      "not listed in policy.actions"
    ),
    (policyJSON(rules: rule("A", "permit", request, ["provider:anthropic"])), "rules[0].id"),
    (policyJSON(rules: rule("9a", "permit", request, ["provider:anthropic"])), "rules[0].id"),
    (
      policyJSON(
        rules: rule(String(repeating: "a", count: 65), "permit", request, ["provider:anthropic"])),
      "rules[0].id"
    ),
    (
      policyJSON(
        rules: rule("a", "permit", request, ["provider:anthropic"]),
        guards: rateGuard("a", max: 1, within: 1)), "duplicate rule or guard id 'a'"
    ),
    (policyJSON(rules: rule("a", "permit", request, ["workspace:attached"])), "resource type"),
    (policyJSON(rules: rule("a", "permit", request, [])), "must not be empty"),
    (
      policyJSON(rules: rule("a", "permit", request, ["provider:openai", "provider:openai"])),
      "duplicate resource"
    ),
    (
      policyJSON(rules: rule("a", "permit", request, ["provider:openai"], instances: [])),
      "must not be empty"
    ),
    (
      policyJSON(rules: rule("a", "permit", request, ["provider:openai"], instances: ["x", "x"])),
      "duplicate instance"
    ),
    (
      policyJSON(rules: rule("a", "permit", request, ["provider:openai"], instances: ["a/b"])),
      "not a valid instance name"
    ),
    (policyJSON(guards: rateGuard("g", max: 0, within: 60)), "max_requests"),
    (policyJSON(guards: rateGuard("g", max: 10_001, within: 60)), "max_requests"),
    (policyJSON(guards: rateGuard("g", max: 1, within: 0)), "within_seconds"),
    (policyJSON(guards: rateGuard("g", max: 1, within: 3_601)), "within_seconds"),
    (policyJSON(guards: approvalGuard("g", seconds: 0)), "seconds"),
    (policyJSON(guards: approvalGuard("g", seconds: 901)), "seconds"),
    (
      policyJSON(
        guards: approvalGuard("g", seconds: 10).replacingOccurrences(
          of: "workspace.pull.apply", with: "proxy.request"
        ).replacingOccurrences(of: "workspace:attached", with: "provider:anthropic")),
      "approval_within applies only to workspace.pull.apply"
    ),
    (
      policyJSON(
        guards: approvalGuard("g", seconds: 10).replacingOccurrences(
          of: "{\"approval_within\":{\"seconds\":10}}",
          with:
            "{\"approval_within\":{\"seconds\":10},\"rate_limit\":{\"max_requests\":1,\"within_seconds\":1}}"
        )), "exactly one"
    ),
    (
      policyJSON(
        guards: (1...5).map { rateGuard("g\($0)", max: 1, within: 1) }.joined(separator: ",")),
      "more than 4 rate guards"
    ),
  ]
  for (json, expected) in cases {
    let error = compileError(json)
    #expect(
      error?.description.contains(expected) == true, "\(expected): \(String(describing: error))")
  }
}

@Test func boundsAtTheirLimits() throws {
  #expect(compileError(policyJSON(guards: rateGuard("g", max: 10_000, within: 3_600))) == nil)
  #expect(compileError(policyJSON(guards: approvalGuard("g", seconds: 900))) == nil)
  // Four guards per scope, each at full capacity: exactly 40,000 slots.
  let four = (1...4).map { rateGuard("g\($0)", max: 10_000, within: 1) }.joined(separator: ",")
  #expect(compileError(policyJSON(guards: four)) == nil)
  // Guards scoped to different instances do not share a proxy.
  let scoped = (1...8).map {
    rateGuard("g\($0)", max: 1, within: 1, instances: [$0 <= 4 ? "one" : "two"])
  }.joined(separator: ",")
  #expect(compileError(policyJSON(guards: scoped)) == nil)
  let overlapping =
    scoped + "," + rateGuard("all", max: 1, within: 1)
  #expect(
    compileError(policyJSON(guards: overlapping))?.description.contains("more than 4") == true)
  let manyRules = (0..<129).map { rule("r\($0)", "permit", "proxy.request", ["provider:openai"]) }
    .joined(separator: ",")
  #expect(compileError(policyJSON(rules: manyRules))?.description.contains("more than 128") == true)
  let manyGuards = (0..<17).map { approvalGuard("g\($0)", seconds: 1) }.joined(separator: ",")
  #expect(
    compileError(policyJSON(guards: manyGuards))?.description.contains("more than 16") == true)
  let maxIDs = (0..<128).map {
    rule(
      "r\($0)" + String(repeating: "x", count: 60), "permit", "proxy.request",
      ["provider:anthropic", "provider:openai"],
      instances: (0..<64).map { "instance-\($0)-" + String(repeating: "n", count: 40) })
  }.joined(separator: ",")
  #expect(compileError(policyJSON(rules: maxIDs))?.description.contains("64 KiB") == true)
}

@Test func offModeMayBeEmptyButMustBeValid() throws {
  let off = try compile(policyJSON(mode: "off", actions: []))
  #expect(off.governedActions.isEmpty)
  #expect(compileError(policyJSON(mode: "off", rules: rule("a", "permit", "x", []))) != nil)
}

extension PolicyJSON {
  var objectMembers: [String: PolicyJSON]? {
    if case .object(let members) = self { members } else { nil }
  }
  var arrayItems: [PolicyJSON]? {
    if case .array(let items) = self { items } else { nil }
  }
}
