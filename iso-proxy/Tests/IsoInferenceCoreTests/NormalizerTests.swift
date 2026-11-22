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

@Test(arguments: ["", ";", " ;", ";charset=utf-8", "\t; charset=utf-8"])
func contentTypeWithoutAMediaTypeIsRefused(_ value: String) {
  let headers = [Header("content-type", value), Header("authorization", "Bearer x")]
  #expect(throws: InferenceError(.requestInvalid, "request bodies must be application/json")) {
    try HeaderTable.check(headers, hasBody: true)
  }
}

@Test func contentTypeParametersAreAllowed() throws {
  try HeaderTable.check(
    [Header("content-type", "Application/JSON ; charset=utf-8")], hasBody: true)
}

/// Fields that are dropped are still type-checked: their value is never
/// forwarded, but a wrong JSON type fails the request (§8.3.1).
@Test func droppedFieldsAreTypeChecked() throws {
  let cases: [(FrontendAPI, String)] = [
    (.anthropicMessages, #"{"model":"local-coder","messages":[],"max_tokens":5,"metadata":5}"#),
    (.anthropicMessages, #"{"model":"local-coder","messages":[],"max_tokens":5,"thinking":"x"}"#),
    (.anthropicMessages, #"{"model":"local-coder","messages":[],"max_tokens":5,"safeguards":{}}"#),
    (.openAIChat, #"{"model":"local-coder","messages":[],"metadata":[1]}"#),
    (.openAIResponses, #"{"model":"local-coder","input":"hi","reasoning":true}"#),
    (.openAIResponses, #"{"model":"local-coder","input":"hi","client_metadata":"x"}"#),
  ]
  for (api, text) in cases {
    let backend: BackendProtocol =
      api == .openAIChat
      ? .openAIChat : api == .openAIResponses ? .openAIResponses : .anthropicMessages
    do {
      _ = try Normalizer.normalize(
        api: api, body: body(text), grants: ["local-coder": grant(backend)])
      Issue.record("accepted \(text)")
    } catch {
      #expect(error.code == .requestInvalid, "\(text)")
    }
  }
}

/// `tool_choice`, `response_format` and `text.format` are closed to their
/// documented shapes; only the JSON Schema body inside a structured-output
/// format is opaque.
@Test func structuredChoicesAreClosed() throws {
  let chat = ["local-coder": grant(.openAIChat)]
  let responses = ["local-coder": grant(.openAIResponses)]
  let refused: [(FrontendAPI, String, InferenceErrorCode)] = [
    (
      .openAIChat, #""tool_choice":{"type":"function","function":{"name":"f"},"extra":1}"#,
      .unsupported
    ),
    (
      .openAIChat, #""tool_choice":{"type":"function","function":{"name":"f","adapter":"/x"}}"#,
      .unsupported
    ),
    (.openAIChat, #""tool_choice":{"type":"web_search"}"#, .unsupported),
    (.openAIChat, #""tool_choice":5"#, .requestInvalid),
    (
      .openAIChat,
      #""response_format":{"type":"json_schema","json_schema":{"name":"x","schema":{}},"draft_model":"y"}"#,
      .unsupported
    ),
    (.openAIChat, #""response_format":{"type":"grammar"}"#, .unsupported),
    (
      .openAIResponses, #""tool_choice":{"type":"mcp","server_label":"x","server_url":"http://x"}"#,
      .policyDenied
    ),
    (
      .openAIResponses, #""tool_choice":{"type":"function","name":"f","server_url":"http://x"}"#,
      .unsupported
    ),
    (.openAIResponses, #""tool_choice":{"type":"web_search_preview"}"#, .unsupported),
    (
      .openAIResponses,
      #""text":{"format":{"type":"json_schema","name":"x","schema":{},"url":"http://x"}}"#,
      .unsupported
    ),
    (.openAIResponses, #""text":{"format":{"type":"text","x":1}}"#, .unsupported),
  ]
  for (api, extra, code) in refused {
    let text =
      api == .openAIChat
      ? #"{"model":"local-coder","messages":[{"role":"user","content":"hi"}],\#(extra)}"#
      : #"{"model":"local-coder","input":"hi",\#(extra)}"#
    do {
      _ = try Normalizer.normalize(
        api: api, body: body(text), grants: api == .openAIChat ? chat : responses)
      Issue.record("accepted \(extra)")
    } catch {
      #expect(error.code == code, "\(extra)")
    }
  }
  let chatAccepted = try Normalizer.normalize(
    api: .openAIChat,
    body: body(
      #"{"model":"local-coder","messages":[{"role":"user","content":"hi"}],"tool_choice":{"type":"function","function":{"name":"f"}},"response_format":{"type":"json_schema","json_schema":{"name":"x","strict":true,"schema":{"type":"object","properties":{"a":{"type":"string"}}}}}}"#
    ), grants: chat)
  let forwarded = try json(String(decoding: chatAccepted.upstreamBody, as: UTF8.self))
  #expect(forwarded["tool_choice"]?["function"]?["name"]?.string == "f")
  #expect(
    forwarded["response_format"]?["json_schema"]?["schema"]?["properties"]?["a"]?["type"]?.string
      == "string")
  let responsesAccepted = try Normalizer.normalize(
    api: .openAIResponses,
    body: body(
      #"{"model":"local-coder","input":"hi","tool_choice":{"type":"function","name":"f"},"text":{"format":{"type":"json_schema","name":"x","schema":{"type":"object"}},"verbosity":"low"}}"#
    ), grants: responses)
  let upstream = try json(String(decoding: responsesAccepted.upstreamBody, as: UTF8.self))
  #expect(upstream["tool_choice"]?["name"]?.string == "f")
  #expect(upstream["text"]?["format"]?["schema"]?["type"]?.string == "object")
  #expect(upstream["text"]?["verbosity"] == nil)
}

/// Integer fields take integer syntax only, and are forwarded in canonical
/// form rather than as the guest's text.
@Test func integerFieldsAreExactAndCanonical() throws {
  let grants = ["local-coder": grant(.anthropicMessages)]
  for value in ["0.99999999999999999999", "1e-400", "1.0", "1e3", "10.5"] {
    let text = #"{"model":"local-coder","messages":[],"max_tokens":\#(value)}"#
    do {
      _ = try Normalizer.normalize(api: .anthropicMessages, body: body(text), grants: grants)
      Issue.record("accepted max_tokens \(value)")
    } catch {
      #expect(error.code == .requestInvalid, "\(value)")
    }
  }
  let request = try Normalizer.normalize(
    api: .anthropicMessages,
    body: body(#"{"model":"local-coder","messages":[],"max_tokens":5,"top_k":-0}"#),
    grants: grants)
  #expect(String(decoding: request.upstreamBody, as: UTF8.self).contains(#""top_k":0"#))
}

/// A body of many tiny values fails before its parse tree outgrows the
/// body by more than a fixed factor.
@Test func parseTreeIsBoundedByTheValueCount() throws {
  let elements = Array(repeating: "0", count: 200_000).joined(separator: ",")
  let text =
    #"{"model":"local-coder","messages":[],"max_tokens":5,"stop_sequences":[\#(elements)]}"#
  do {
    _ = try Normalizer.normalize(
      api: .anthropicMessages, body: body(text), grants: ["local-coder": grant(.anthropicMessages)])
    Issue.record("parsed 200,000 values")
  } catch {
    #expect(error.code == .requestTooLarge)
  }
}
