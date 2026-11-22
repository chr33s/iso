import Testing

@testable import IsoInferenceCore

private func events(_ text: String) throws -> [SSEEvent] {
  var parser = SSEParser(maxEventBytes: 1 << 20)
  return try parser.feed(Array(text.utf8))
}

@Test func sseParserHandlesLineEndingsCommentsAndMultiLineData() throws {
  var parser = SSEParser(maxEventBytes: 1 << 10)
  var got = try parser.feed(Array(": c\r\nevent: a\r\ndata: 1\r\ndata: 2\r\n\r\n".utf8))
  got += try parser.feed(Array("data:x\n".utf8))
  got += try parser.feed(Array("\n".utf8))
  #expect(
    got == [
      SSEEvent(name: "a", data: Array("1\n2".utf8)), SSEEvent(name: nil, data: Array("x".utf8)),
    ])
  var bounded = SSEParser(maxEventBytes: 8)
  #expect(throws: SSEParser.Failure.eventTooLarge) {
    try bounded.feed(Array("data: 0123456789\n\n".utf8))
  }
}

@Test func chatStreamIsRelayedWithAliasAndAggregated() throws {
  var translator = StreamTranslator(api: .openAIChat, alias: "local-coder", maxEventBytes: 1 << 20)
  let stream = """
    data: {"id":"c1","created":7,"model":"mlx/real","choices":[{"index":0,"delta":{"role":"assistant","content":"he"},"finish_reason":null}]}

    data: {"id":"c1","model":"mlx/real","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"ls","arguments":"{\\"a\\""}}]},"finish_reason":null}]}

    data: {"id":"c1","model":"mlx/real","choices":[{"index":0,"delta":{"content":"llo","tool_calls":[{"index":0,"function":{"arguments":":1}"}}]},"finish_reason":"length"}]}

    data: {"id":"c1","model":"mlx/real","choices":[],"usage":{"prompt_tokens":11,"completion_tokens":3}}

    data: [DONE]


    """
  var relayed = ""
  for event in try events(stream) {
    if let out = try translator.consume(event) { relayed += String(decoding: out, as: UTF8.self) }
  }
  #expect(translator.outcome == .completed)
  #expect(translator.usage == Usage(inputTokens: 11, outputTokens: 3))
  #expect(!relayed.contains("mlx/real") && relayed.contains(#""model":"local-coder""#))
  #expect(relayed.hasSuffix("data: [DONE]\n\n"))
  let aggregate = try json(String(decoding: try translator.aggregated(), as: UTF8.self))
  let choice = try #require(aggregate["choices"]?.array?.first)
  #expect(choice["finish_reason"]?.string == "length")
  #expect(choice["message"]?["content"]?.string == "hello")
  #expect(
    choice["message"]?["tool_calls"]?.array?.first?["function"]?["arguments"]?.string == #"{"a":1}"#
  )
  #expect(aggregate["usage"]?["total_tokens"]?.number?.int64 == 14)
}

@Test func anthropicStreamAggregatesToolUse() throws {
  var translator = StreamTranslator(
    api: .anthropicMessages, alias: "local-coder", maxEventBytes: 1 << 20)
  let stream = """
    event: message_start
    data: {"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"real","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":9,"output_tokens":1}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"Bash","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"ls\\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":6}}

    event: message_stop
    data: {"type":"message_stop"}


    """
  for event in try events(stream) { _ = try translator.consume(event) }
  #expect(translator.outcome == .completed)
  #expect(translator.usage == Usage(inputTokens: 9, outputTokens: 6))
  let message = try json(String(decoding: try translator.aggregated(), as: UTF8.self))
  #expect(message["model"]?.string == "local-coder")
  #expect(message["stop_reason"]?.string == "tool_use")
  #expect(message["content"]?.array?.first?["input"]?["command"]?.string == "ls")
}

@Test func responsesStreamReturnsFinalResponse() throws {
  var translator = StreamTranslator(
    api: .openAIResponses, alias: "local-coder", maxEventBytes: 1 << 20)
  let stream = """
    event: response.created
    data: {"type":"response.created","response":{"id":"r","model":"real","status":"in_progress","output":[]}}

    event: response.completed
    data: {"type":"response.completed","response":{"id":"r","model":"real","status":"completed","output":[{"type":"message"}],"usage":{"input_tokens":5,"output_tokens":2}}}


    """
  var relayed = ""
  for event in try events(stream) {
    if let out = try translator.consume(event) { relayed += String(decoding: out, as: UTF8.self) }
  }
  #expect(relayed.hasPrefix("event: response.created\n"))
  #expect(!relayed.contains(#""model":"real""#))
  #expect(translator.outcome == .completed)
  let response = try json(String(decoding: try translator.aggregated(), as: UTF8.self))
  #expect(response["status"]?.string == "completed" && response["model"]?.string == "local-coder")
}

@Test func streamFailuresAndGarbage() throws {
  var translator = StreamTranslator(
    api: .anthropicMessages, alias: "local-coder", maxEventBytes: 1 << 20)
  _ = try translator.consume(SSEEvent(name: "error", data: Array(#"{"type":"error"}"#.utf8)))
  #expect(translator.outcome == .failed)
  var garbage = StreamTranslator(api: .openAIChat, alias: "a", maxEventBytes: 1 << 20)
  #expect(throws: InferenceError.self) {
    try garbage.consume(SSEEvent(name: nil, data: Array("not json".utf8)))
  }
  #expect(throws: InferenceError.self) {
    try garbage.consume(SSEEvent(name: nil, data: Array("[1]".utf8)))
  }
}

@Test func countTokensResponseIsReduced() throws {
  let out = try CountTokensResponse.translate(Array(#"{"input_tokens":12,"extra":"x"}"#.utf8))
  #expect(String(decoding: out, as: UTF8.self) == #"{"input_tokens":12}"#)
  #expect(throws: InferenceError.self) {
    try CountTokensResponse.translate(Array(#"{"input_tokens":-1}"#.utf8))
  }
}

@Test func unknownEventsAreDroppedAndEveryModelFieldIsRewritten() throws {
  var translator = StreamTranslator(
    api: .anthropicMessages, alias: "local-coder", maxEventBytes: 1 << 20)
  #expect(
    try translator.consume(
      SSEEvent(name: "debug", data: Array(#"{"type":"debug","model":"real","prompt":"x"}"#.utf8)))
      == nil)
  let relayed = try #require(
    try translator.consume(
      SSEEvent(
        name: "message_start",
        data: Array(
          #"{"type":"message_start","model":"real","message":{"model":"real","usage":{}}}"#.utf8))))
  #expect(!String(decoding: relayed, as: UTF8.self).contains(#""real""#))
  var chat = StreamTranslator(api: .openAIChat, alias: "a", maxEventBytes: 1 << 20)
  #expect(try chat.consume(SSEEvent(name: nil, data: Array(#"{"object":"x"}"#.utf8))) == nil)
  var responses = StreamTranslator(api: .openAIResponses, alias: "a", maxEventBytes: 1 << 20)
  #expect(
    try responses.consume(SSEEvent(name: nil, data: Array(#"{"type":"debug.trace"}"#.utf8))) == nil)
}

/// The guest sees a fixed gateway error in the protocol's shape, never the
/// backend's error text.
@Test(arguments: [
  (FrontendAPI.openAIChat, #"{"error":{"message":"SECRET-BACKEND-TEXT"}}"#),
  (.openAIResponses, #"{"type":"error","code":"x","message":"SECRET-BACKEND-TEXT"}"#),
  (
    .openAIResponses,
    #"{"type":"response.failed","response":{"error":{"message":"SECRET-BACKEND-TEXT"}}}"#
  ),
  (.anthropicMessages, #"{"type":"error","error":{"type":"x","message":"SECRET-BACKEND-TEXT"}}"#),
])
func backendStreamErrorsAreSanitized(_ api: FrontendAPI, _ data: String) throws {
  var translator = StreamTranslator(api: api, alias: "a", maxEventBytes: 1 << 20)
  let relayed = try #require(try translator.consume(SSEEvent(name: nil, data: Array(data.utf8))))
  let text = String(decoding: relayed, as: UTF8.self)
  #expect(translator.outcome == .failed)
  #expect(!text.contains("SECRET-BACKEND-TEXT"))
  #expect(text.contains("INFERENCE_UPSTREAM_INVALID") || text.contains("backend reported an error"))
}

/// A Responses event name is the backend's `type`; one that could break
/// the SSE framing fails the stream.
@Test(arguments: ["response.x\nevent: forged", "response.x\r", "response.x y", "response.ÿ"])
func responsesEventNamesCannotForgeEvents(_ type: String) {
  var translator = StreamTranslator(api: .openAIResponses, alias: "a", maxEventBytes: 1 << 20)
  let data = JSON.object(JSONObject(["type": .string(type)])).serialized
  #expect(throws: InferenceError.self) { try translator.consume(SSEEvent(name: nil, data: data)) }
}

@Test(arguments: [
  #"{"choices":[],"usage":{"prompt_tokens":-1,"completion_tokens":1}}"#,
  #"{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":-5}}"#,
  #"{"choices":[],"usage":{"prompt_tokens":9223372036854775807,"completion_tokens":9223372036854775807}}"#,
  #"{"choices":[],"usage":{"prompt_tokens":1.5,"completion_tokens":1}}"#,
  #"{"choices":[],"usage":{"prompt_tokens":"1","completion_tokens":1}}"#,
])
func invalidUsageFailsTheStream(_ data: String) {
  var translator = StreamTranslator(api: .openAIChat, alias: "a", maxEventBytes: 1 << 20)
  #expect(throws: InferenceError.self) {
    try translator.consume(SSEEvent(name: nil, data: Array(data.utf8)))
  }
}

@Test func usageIsValidatedForEveryProtocol() {
  let cases: [(FrontendAPI, String)] = [
    (
      .anthropicMessages,
      #"{"type":"message_start","message":{"model":"m","usage":{"input_tokens":-3}}}"#
    ),
    (.anthropicMessages, #"{"type":"message_delta","delta":{},"usage":{"output_tokens":-1}}"#),
    (
      .openAIResponses,
      #"{"type":"response.completed","response":{"usage":{"input_tokens":1,"output_tokens":-1}}}"#
    ),
  ]
  for (api, data) in cases {
    var translator = StreamTranslator(api: api, alias: "a", maxEventBytes: 1 << 20)
    #expect(throws: InferenceError.self, "\(data)") {
      try translator.consume(SSEEvent(name: nil, data: Array(data.utf8)))
    }
  }
}

/// Only content and tool events end the time-to-first-output wait.
@Test func firstOutputNeedsContent() throws {
  var anthropic = StreamTranslator(api: .anthropicMessages, alias: "a", maxEventBytes: 1 << 20)
  for data in [
    #"{"type":"message_start","message":{"model":"m","usage":{"input_tokens":1}}}"#,
    #"{"type":"ping"}"#,
    #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
  ] {
    _ = try anthropic.consume(SSEEvent(name: nil, data: Array(data.utf8)))
  }
  #expect(!anthropic.sawOutput)
  _ = try anthropic.consume(
    SSEEvent(
      name: nil,
      data: Array(
        #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#.utf8))
  )
  #expect(anthropic.sawOutput)

  var chat = StreamTranslator(api: .openAIChat, alias: "a", maxEventBytes: 1 << 20)
  _ = try chat.consume(
    SSEEvent(
      name: nil,
      data: Array(#"{"choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}"#.utf8)))
  #expect(!chat.sawOutput)
  _ = try chat.consume(
    SSEEvent(name: nil, data: Array(#"{"choices":[{"index":0,"delta":{"content":"h"}}]}"#.utf8)))
  #expect(chat.sawOutput)

  var responses = StreamTranslator(api: .openAIResponses, alias: "a", maxEventBytes: 1 << 20)
  for data in [
    #"{"type":"response.created","response":{"model":"m"}}"#,
    #"{"type":"response.in_progress","response":{"model":"m"}}"#,
  ] {
    _ = try responses.consume(SSEEvent(name: nil, data: Array(data.utf8)))
  }
  #expect(!responses.sawOutput)
  _ = try responses.consume(
    SSEEvent(name: nil, data: Array(#"{"type":"response.output_text.delta","delta":"x"}"#.utf8)))
  #expect(responses.sawOutput)
}
