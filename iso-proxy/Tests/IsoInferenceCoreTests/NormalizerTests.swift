import IsoProxyCore
import Testing

@testable import IsoInferenceCore

private let claudeFixtures = [
  "claude-code-2.1.285-first", "claude-code-2.1.285-tool-result", "claude-code-2.1.285-long",
]
private let codexFixtures = ["codex-0.159.2-first", "codex-0.159.2-tool-result"]

@Test(arguments: claudeFixtures)
func claudeCodeFixturesPassTheMessagesTable(_ name: String) throws {
  let fixture = try Fixture.load(name)
  let api = try #require(FrontendAPI.route(method: fixture.method, target: fixture.path))
  #expect(api == .anthropicMessages)
  try HeaderTable.check(fixture.headers, hasBody: true)
  let request = try Normalizer.normalize(
    api: api, body: fixture.body, grants: ["local-coder": grant(.anthropicMessages)])
  let upstream = try json(String(decoding: request.upstreamBody, as: UTF8.self))
  #expect(upstream["model"]?.string == "mlx-community/Test-Model-4bit")
  #expect(upstream["stream"]?.bool == true)
  // Claude Code asks for 32000 output tokens; the service ceiling applies.
  #expect(upstream["max_tokens"]?.number?.int64 == 8_192)
  #expect(request.clamped && request.outputTokens == 8_192)
  for dropped in ["safeguards", "metadata", "thinking", "context_management", "output_config"] {
    #expect(upstream[dropped] == nil, "\(dropped) must not reach the backend")
  }
  #expect(!String(decoding: request.upstreamBody, as: UTF8.self).contains("cache_control"))
  #expect(request.inputBound > request.upstreamBody.count)
}

@Test(arguments: codexFixtures)
func codexFixturesPassTheResponsesTable(_ name: String) throws {
  let fixture = try Fixture.load(name)
  let api = try #require(FrontendAPI.route(method: fixture.method, target: fixture.path))
  #expect(api == .openAIResponses)
  try HeaderTable.check(fixture.headers, hasBody: true)
  let request = try Normalizer.normalize(
    api: api, body: fixture.body, grants: ["local-coder": grant(.openAIResponses)])
  let upstream = try json(String(decoding: request.upstreamBody, as: UTF8.self))
  #expect(upstream["store"]?.bool == false)
  #expect(upstream["stream"]?.bool == true)
  #expect(upstream["max_output_tokens"]?.number?.int64 == 4_096)
  #expect(!request.clamped)
  let toolTypes = upstream["tools"]?.array?.compactMap { $0["type"]?.string } ?? []
  #expect(!toolTypes.contains("web_search"), "hosted tool declarations are dropped")
  #expect(toolTypes.contains("function"))
  for dropped in ["client_metadata", "prompt_cache_key", "include", "reasoning"] {
    #expect(upstream[dropped] == nil)
  }
}

@Test func unauthorizedAliasAndProtocolMismatchFail() throws {
  let request = body(#"{"model":"other","messages":[],"max_tokens":10}"#)
  #expect(throws: InferenceError.self) {
    try Normalizer.normalize(
      api: .anthropicMessages, body: request, grants: ["local-coder": grant(.anthropicMessages)])
  }
  let mismatch = body(#"{"model":"local-coder","messages":[],"max_tokens":10}"#)
  do {
    _ = try Normalizer.normalize(
      api: .anthropicMessages, body: mismatch,
      grants: ["local-coder": grant(.openAIChat, apis: [.anthropicMessages])])
    Issue.record("expected a protocol failure")
  } catch {
    #expect(error.code == .protocolUnsupported)
  }
}

@Test func hostSelectedAndUnknownFieldsAreRejected() throws {
  let chat = ["local-coder": grant(.openAIChat)]
  let cases: [(String, InferenceErrorCode)] = [
    (#"{"model":"local-coder","messages":[],"draft_model":"x"}"#, .policyDenied),
    (#"{"model":"local-coder","messages":[],"adapters":"/tmp/x"}"#, .policyDenied),
    (#"{"model":"local-coder","messages":[],"logit_bias":{}}"#, .policyDenied),
    (#"{"model":"local-coder","messages":[],"surprise":1}"#, .unsupported),
    (#"{"model":"local-coder","messages":[],"n":2}"#, .requestInvalid),
    (#"{"model":"local-coder","messages":[],"temperature":9}"#, .requestInvalid),
    (
      #"{"model":"local-coder","messages":[],"max_tokens":5,"max_completion_tokens":6}"#,
      .requestInvalid
    ),
    (
      #"{"model":"local-coder","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"http://x"}}]}]}"#,
      .policyDenied
    ),
    (#"{"model":"local-coder","messages":[{"role":"function","content":"x"}]}"#, .policyDenied),
    (#"{"model":"local-coder","messages":[],"model":"x"}"#, .requestInvalid),
    (#"["model"]"#, .requestInvalid),
  ]
  for (text, code) in cases {
    do {
      _ = try Normalizer.normalize(api: .openAIChat, body: body(text), grants: chat)
      Issue.record("accepted \(text)")
    } catch {
      #expect(error.code == code, "\(text)")
    }
  }
}

@Test func responsesRejectsStatefulAndHostedFeatures() throws {
  let grants = ["local-coder": grant(.openAIResponses)]
  for text in [
    #"{"model":"local-coder","input":"hi","previous_response_id":"resp_1"}"#,
    #"{"model":"local-coder","input":"hi","background":true}"#,
    #"{"model":"local-coder","input":[{"type":"web_search_call","id":"x"}]}"#,
    #"{"model":"local-coder","input":[{"type":"item_reference","id":"x"}]}"#,
    #"{"model":"local-coder","input":[{"role":"user","content":[{"type":"input_image","image_url":"http://x"}]}]}"#,
    #"{"model":"local-coder","input":"hi","tools":[{"type":"mcp","server_url":"http://x"}]}"#,
  ] {
    do {
      _ = try Normalizer.normalize(api: .openAIResponses, body: body(text), grants: grants)
      Issue.record("accepted \(text)")
    } catch {
      #expect(error.code == .policyDenied, "\(text)")
    }
  }
  let stored = try Normalizer.normalize(
    api: .openAIResponses, body: body(#"{"model":"local-coder","input":"hi","store":true}"#),
    grants: grants)
  #expect(try json(String(decoding: stored.upstreamBody, as: UTF8.self))["store"]?.bool == false)
}

@Test func outputLimitNormalization() throws {
  let grants = ["local-coder": grant(.openAIChat)]
  func limit(_ extra: String) throws -> (Int, Bool) {
    let request = try Normalizer.normalize(
      api: .openAIChat,
      body: body(#"{"model":"local-coder","messages":[{"role":"user","content":"hi"}]\#(extra)}"#),
      grants: grants)
    return (request.outputTokens, request.clamped)
  }
  #expect(try limit("") == (4_096, false))
  #expect(try limit(#","max_tokens":100"#) == (100, false))
  #expect(try limit(#","max_completion_tokens":100000"#) == (8_192, true))
  #expect(try limit(#","max_tokens":9000,"max_completion_tokens":9000"#) == (8_192, true))
  #expect(throws: InferenceError.self) { try limit(#","max_tokens":0"#) }
  #expect(throws: InferenceError.self) { try limit(#","max_tokens":1.5"#) }
}

@Test func inputBoundIsEnforced() throws {
  let small = ["local-coder": grant(.openAIChat, maxInputBytes: 700)]
  let text = String(repeating: "a", count: 400)
  do {
    _ = try Normalizer.normalize(
      api: .openAIChat,
      body: body(#"{"model":"local-coder","messages":[{"role":"user","content":"\#(text)"}]}"#),
      grants: small)
    Issue.record("expected the input bound to reject")
  } catch {
    #expect(error.code == .unsupported)
  }
}

@Test func countTokensNeedsAQualifiedCounter() throws {
  let request = body(#"{"model":"local-coder","messages":[{"role":"user","content":"hi"}]}"#)
  do {
    _ = try Normalizer.normalize(
      api: .anthropicCountTokens, body: request,
      grants: ["local-coder": grant(.anthropicMessages, apis: [.anthropicCountTokens])])
    Issue.record("counted without a qualified counter")
  } catch {
    #expect(error.code == .protocolUnsupported)
  }
  let counted = try Normalizer.normalize(
    api: .anthropicCountTokens, body: request,
    grants: [
      "local-coder": grant(
        .anthropicMessages, apis: [.anthropicCountTokens], tokenCounter: .backend)
    ])
  #expect(!counted.upstreamStreams && counted.outputTokens == 0)
}

@Test func routesAndQueries() {
  #expect(FrontendAPI.route(method: "POST", target: "/v1/messages?beta=true") == .anthropicMessages)
  #expect(FrontendAPI.route(method: "POST", target: "/v1/messages?beta=false") == nil)
  #expect(FrontendAPI.route(method: "POST", target: "/v1/responses?x=1") == nil)
  #expect(FrontendAPI.route(method: "GET", target: "/v1/responses") == nil)
  #expect(FrontendAPI.route(method: "POST", target: "/v1/chat/completions/") == nil)
  #expect(FrontendAPI.route(method: "POST", target: "/v1/models/pull") == nil)
  #expect(FrontendAPI.route(method: "GET", target: "/v1/models") == .modelDiscovery)
}

@Test func headerTable() throws {
  let base = [Header("content-type", "application/json"), Header("authorization", "Bearer x")]
  try HeaderTable.check(base, hasBody: true)
  try HeaderTable.check(
    base + [Header("X-Stainless-Foo", "1"), Header("Cookie", "a")], hasBody: true)
  let failures: [([Header], InferenceErrorCode)] = [
    ([Header("origin", "https://evil.example")], .policyDenied),
    ([Header("transfer-encoding", "chunked")], .lengthRequired),
    ([Header("content-encoding", "gzip")], .requestInvalid),
    ([Header("upgrade", "h2c")], .requestInvalid),
    ([Header("expect", "something")], .requestInvalid),
    ([Header("x-unknown", "1")], .unsupported),
    ([Header("content-type", "text/plain")], .requestInvalid),
  ]
  for (extra, code) in failures {
    let headers =
      extra.first?.name == "content-type"
      ? [extra[0], Header("authorization", "Bearer x")] : base + extra
    do {
      try HeaderTable.check(headers, hasBody: true)
      Issue.record("accepted \(extra)")
    } catch {
      #expect(error.code == code)
    }
  }
}
