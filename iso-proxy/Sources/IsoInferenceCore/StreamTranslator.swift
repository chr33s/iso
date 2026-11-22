/// Token usage a backend reported for one request. Each count is within
/// `0...Usage.maxTokens`; the translator refuses any other report.
package struct Usage: Sendable, Equatable {
  /// No qualified model reports more tokens for one request.
  package static let maxTokens = 100_000_000

  package var inputTokens: Int?
  package var outputTokens: Int?
  package init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
  }
}

package enum StreamOutcome: Sendable, Equatable {
  /// The protocol's own terminal event arrived (including length stops).
  case completed
  /// The backend reported an error inside the stream.
  case failed
}

/// Parses a backend's event stream for one same-protocol adapter (§8.5):
/// every event is parsed, bounded and re-serialized, the upstream model id
/// is replaced by the guest alias, and the protocol's terminal event and
/// usage are recorded. For non-streaming clients the events are aggregated
/// into the protocol's single response object.
package struct StreamTranslator: Sendable {
  package let api: FrontendAPI
  let alias: String
  let limits: JSONParser.Limits
  package private(set) var outcome: StreamOutcome?
  package private(set) var usage = Usage()
  /// Whether the backend produced content or a tool call (time to first
  /// output). Stream metadata, pings and role-only chunks do not count.
  package private(set) var sawOutput = false
  var aggregate: Aggregate

  package init(api: FrontendAPI, alias: String, maxEventBytes: Int) {
    self.api = api
    self.alias = alias
    // Events are parsed on an event loop's thread, so nesting stays shallow.
    limits = JSONParser.Limits(maxBytes: maxEventBytes, maxDepth: 32)
    aggregate = Aggregate()
  }

  /// Bytes for a streaming client, or nil when the event is not relayed.
  package mutating func consume(_ event: SSEEvent) throws(InferenceError) -> [UInt8]? {
    guard outcome == nil else { return nil }
    if api == .openAIChat, event.data == Array("[DONE]".utf8) {
      outcome = .completed
      return SSEEvent.encode(name: nil, data: event.data)
    }
    guard case .object(var object) = try parse(event.data) else {
      throw InferenceError(.upstreamInvalid, "backend sent a non-object event")
    }
    // Only the protocol's own event types are relayed; anything else a
    // backend emits (extensions, debug events) is dropped unread.
    guard Self.relayable(api, object) else { return nil }
    switch api {
    case .openAIChat: try chat(&object)
    case .openAIResponses: try responses(&object)
    case .anthropicMessages: try anthropic(&object)
    case .anthropicCountTokens, .modelDiscovery:
      throw InferenceError(.upstreamInvalid, "unexpected stream")
    }
    // A backend's error text can carry prompt fragments or host paths: the
    // guest gets the gateway's own error instead (§13).
    if outcome == .failed { return Self.backendError.streamEvent(for: api) }
    rewriteModels(&object)
    // Relayable Chat chunks have no event name; the others' names are
    // their checked `type`.
    let name: String? = api == .openAIChat ? nil : object["type"]?.string
    return SSEEvent.encode(name: name, data: JSON.object(object).serialized)
  }

  static let backendError = InferenceError(.upstreamInvalid, "backend reported an error")

  /// A usage count from the backend: absent or null, or an integer in
  /// `0...Usage.maxTokens`. Anything else fails the stream.
  static func tokens(_ value: JSON?) throws(InferenceError) -> Int? {
    switch value {
    case nil, .null?: return nil
    case .number(let number)?:
      if let count = number.int64, (0...Int64(Usage.maxTokens)).contains(count) {
        return Int(count)
      }
    default: break
    }
    throw InferenceError(.upstreamInvalid, "backend reported invalid token usage")
  }

  /// An event type relayed as an SSE event name: lowercase letters, digits,
  /// `_` and `.` only, so it can never end the line it is written on.
  static func isEventName(_ type: String) -> Bool {
    let bytes = type.utf8
    return (1...128).contains(bytes.count)
      && bytes.allSatisfy {
        (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == UInt8(ascii: "_")
          || $0 == UInt8(ascii: ".")
      }
  }

  /// Every model field a guest could see names the alias.
  func rewriteModels(_ object: inout JSONObject) {
    if object["model"] != nil { object["model"] = .string(alias) }
    for key in ["message", "response"] {
      if case .object(var nested)? = object[key], nested["model"] != nil {
        nested["model"] = .string(alias)
        object[key] = .object(nested)
      }
    }
  }

  static let anthropicEvents: Set<String> = [
    "message_start", "content_block_start", "content_block_delta", "content_block_stop",
    "message_delta", "message_stop", "ping", "error",
  ]

  static func relayable(_ api: FrontendAPI, _ object: JSONObject) -> Bool {
    switch api {
    case .openAIChat:
      return object["choices"]?.array != nil || object["error"] != nil
    case .openAIResponses:
      guard case .string(let type)? = object["type"] else { return false }
      return type.hasPrefix("response.") || type == "error"
    case .anthropicMessages:
      guard case .string(let type)? = object["type"] else { return false }
      return anthropicEvents.contains(type)
    case .anthropicCountTokens, .modelDiscovery:
      return false
    }
  }

  func parse(_ bytes: [UInt8]) throws(InferenceError) -> JSON {
    do { return try JSONParser.parse(bytes, limits: limits) } catch {
      throw InferenceError(.upstreamInvalid, "backend sent an invalid event")
    }
  }

  // MARK: OpenAI Chat Completions

  mutating func chat(_ chunk: inout JSONObject) throws(InferenceError) {
    if chunk["error"] != nil {
      outcome = .failed
      return
    }
    if chunk["model"] != nil { chunk["model"] = .string(alias) }
    if case .object(let reported)? = chunk["usage"] {
      usage.inputTokens = try Self.tokens(reported["prompt_tokens"])
      usage.outputTokens = try Self.tokens(reported["completion_tokens"])
    }
    if aggregate.id == nil { aggregate.id = chunk["id"] }
    if aggregate.created == nil { aggregate.created = chunk["created"] }
    for choice in chunk["choices"]?.array ?? [] {
      guard case .object(let choice) = choice, choice["index"]?.number?.int64 ?? 0 == 0 else {
        continue
      }
      if case .object(let delta)? = choice["delta"] {
        // Any member but the role, with a value, is model output.
        if delta.members.contains(where: { $0.key != "role" && Self.hasContent($0.value) }) {
          sawOutput = true
        }
        if case .string(let text)? = delta["content"] { aggregate.text += text }
        for call in delta["tool_calls"]?.array ?? [] {
          guard case .object(let call) = call else { continue }
          let index = Int(call["index"]?.number?.int64 ?? 0)
          guard (0..<1024).contains(index) else {
            throw InferenceError(.upstreamInvalid, "backend sent an invalid tool call index")
          }
          // Mutated in place: a copy would re-copy the arguments per delta.
          if aggregate.toolCalls[index] == nil { aggregate.toolCalls[index] = Aggregate.ToolCall() }
          if case .string(let id)? = call["id"] { aggregate.toolCalls[index]!.id = id }
          if case .object(let function)? = call["function"] {
            if case .string(let name)? = function["name"] {
              aggregate.toolCalls[index]!.name = name
            }
            if case .string(let arguments)? = function["arguments"] {
              aggregate.toolCalls[index]!.arguments += arguments
            }
          }
        }
      }
      if let reason = choice["finish_reason"], reason != .null { aggregate.finishReason = reason }
    }
  }

  static func hasContent(_ value: JSON) -> Bool {
    switch value {
    case .null: false
    case .string(let text): !text.isEmpty
    case .array(let elements): !elements.isEmpty
    case .object(let object): !object.isEmpty
    case .bool, .number: true
    }
  }

  // MARK: OpenAI Responses

  static let responsesTerminal: [String: StreamOutcome] = [
    "response.completed": .completed, "response.incomplete": .completed,
    "response.failed": .failed, "error": .failed,
  ]

  mutating func responses(_ event: inout JSONObject) throws(InferenceError) {
    guard case .string(let type)? = event["type"], Self.isEventName(type) else {
      throw InferenceError(.upstreamInvalid, "backend sent an untyped or malformed event")
    }
    // Text, refusal, reasoning and tool-argument deltas.
    if type.hasSuffix(".delta") { sawOutput = true }
    if case .object(var response)? = event["response"] {
      if response["model"] != nil { response["model"] = .string(alias) }
      if case .object(let reported)? = response["usage"] {
        usage.inputTokens = try Self.tokens(reported["input_tokens"])
        usage.outputTokens = try Self.tokens(reported["output_tokens"])
      }
      event["response"] = .object(response)
      aggregate.response = response
    }
    if let terminal = Self.responsesTerminal[type] { outcome = terminal }
  }

  // MARK: Anthropic Messages

  mutating func anthropic(_ event: inout JSONObject) throws(InferenceError) {
    guard case .string(let type)? = event["type"] else {
      throw InferenceError(.upstreamInvalid, "backend sent an untyped event")
    }
    switch type {
    case "message_start":
      guard case .object(var message)? = event["message"] else {
        throw InferenceError(.upstreamInvalid, "backend sent an invalid message_start")
      }
      message["model"] = .string(alias)
      if case .object(let reported)? = message["usage"] {
        usage.inputTokens = try Self.tokens(reported["input_tokens"])
        usage.outputTokens = try Self.tokens(reported["output_tokens"])
      }
      event["message"] = .object(message)
      aggregate.message = message
    case "content_block_start":
      guard case .object(let block)? = event["content_block"] else {
        throw InferenceError(.upstreamInvalid, "backend sent an invalid content block")
      }
      let index = try blockIndex(event)
      aggregate.blocks[index] = Aggregate.Block(start: block)
      // A tool call's name is already model output; an empty text block is not.
      if block["type"]?.string == "tool_use" { sawOutput = true }
    case "content_block_delta":
      sawOutput = true
      let index = try blockIndex(event)
      guard aggregate.blocks[index] != nil, case .object(let delta)? = event["delta"] else {
        throw InferenceError(.upstreamInvalid, "backend sent a delta for no block")
      }
      // Mutated in place: a copy would re-copy the block's text per delta.
      switch delta["type"]?.string {
      case "text_delta": aggregate.blocks[index]!.text += delta["text"]?.string ?? ""
      case "input_json_delta": aggregate.blocks[index]!.json += delta["partial_json"]?.string ?? ""
      case "thinking_delta": aggregate.blocks[index]!.text += delta["thinking"]?.string ?? ""
      case "signature_delta": aggregate.blocks[index]!.signature = delta["signature"]?.string
      default: break
      }
    case "message_delta":
      if case .object(let delta)? = event["delta"] {
        if let reason = delta["stop_reason"] { aggregate.stopReason = reason }
        if let sequence = delta["stop_sequence"] { aggregate.stopSequence = sequence }
      }
      if case .object(let reported)? = event["usage"],
        let output = try Self.tokens(reported["output_tokens"])
      {
        usage.outputTokens = output
      }
    case "message_stop": outcome = .completed
    case "error": outcome = .failed
    default: break
    }
  }

  func blockIndex(_ event: JSONObject) throws(InferenceError) -> Int {
    guard let index = event["index"]?.number?.int64, (0..<4096).contains(index) else {
      throw InferenceError(.upstreamInvalid, "backend sent an invalid block index")
    }
    return Int(index)
  }

  // MARK: Non-streaming responses

  /// The single JSON response for a non-streaming client, after a
  /// `.completed` outcome.
  package func aggregated() throws(InferenceError) -> [UInt8] {
    switch api {
    case .openAIChat:
      var message = JSONObject(["role": .string("assistant")])
      message["content"] =
        aggregate.text.isEmpty && !aggregate.toolCalls.isEmpty
        ? .null : .string(aggregate.text)
      if !aggregate.toolCalls.isEmpty {
        message["tool_calls"] = .array(
          aggregate.toolCalls.keys.sorted().map { index in
            let call = aggregate.toolCalls[index]!
            return .object(
              JSONObject([
                "id": .string(call.id), "type": .string("function"),
                "function": .object(
                  JSONObject([
                    "name": .string(call.name), "arguments": .string(call.arguments),
                  ])),
              ]))
          })
      }
      var body = JSONObject([
        "id": aggregate.id ?? .string("chatcmpl-iso"), "object": .string("chat.completion"),
        "created": aggregate.created ?? .int(0), "model": .string(alias),
        "choices": .array([
          .object(
            JSONObject([
              "index": .int(0), "message": .object(message),
              "finish_reason": aggregate.finishReason ?? .null,
            ]))
        ]),
      ])
      // Each count is at most Usage.maxTokens, so the sum cannot overflow.
      if let input = usage.inputTokens, let output = usage.outputTokens {
        body["usage"] = .object(
          JSONObject([
            "prompt_tokens": .int(Int64(input)), "completion_tokens": .int(Int64(output)),
            "total_tokens": .int(Int64(input) + Int64(output)),
          ]))
      }
      return JSON.object(body).serialized
    case .openAIResponses:
      guard let response = aggregate.response else {
        throw InferenceError(.upstreamInvalid, "backend sent no response object")
      }
      return JSON.object(response).serialized
    case .anthropicMessages:
      guard var message = aggregate.message else {
        throw InferenceError(.upstreamInvalid, "backend sent no message_start")
      }
      var content: [JSON] = []
      for index in aggregate.blocks.keys.sorted() {
        content.append(.object(try aggregate.blocks[index]!.finished()))
      }
      message["content"] = .array(content)
      message["stop_reason"] = aggregate.stopReason ?? .null
      message["stop_sequence"] = aggregate.stopSequence ?? .null
      var reported = message["usage"]?.object ?? JSONObject()
      if let input = usage.inputTokens { reported["input_tokens"] = .int(Int64(input)) }
      if let output = usage.outputTokens { reported["output_tokens"] = .int(Int64(output)) }
      message["usage"] = .object(reported)
      return JSON.object(message).serialized
    case .anthropicCountTokens, .modelDiscovery:
      throw InferenceError(.upstreamInvalid, "unexpected stream")
    }
  }

  struct Aggregate: Sendable {
    struct ToolCall: Sendable {
      var id = ""
      var name = ""
      var arguments = ""
    }
    struct Block: Sendable {
      let start: JSONObject
      var text = ""
      var json = ""
      var signature: String?

      func finished() throws(InferenceError) -> JSONObject {
        var block = start
        switch start["type"]?.string {
        case "text": block["text"] = .string(text)
        case "thinking":
          block["thinking"] = .string(text)
          if let signature { block["signature"] = .string(signature) }
        case "tool_use":
          if !json.isEmpty {
            guard
              let input = try? JSONParser.parse(
                Array(json.utf8), limits: .init(maxBytes: Size.toolInput, maxDepth: 64)),
              case .object = input
            else { throw InferenceError(.upstreamInvalid, "backend sent invalid tool input") }
            block["input"] = input
          }
        default: break
        }
        return block
      }
    }
    var id: JSON?
    var created: JSON?
    var text = ""
    var toolCalls: [Int: ToolCall] = [:]
    var finishReason: JSON?
    var response: JSONObject?
    var message: JSONObject?
    var blocks: [Int: Block] = [:]
    var stopReason: JSON?
    var stopSequence: JSON?
  }
}

/// A non-streaming `count_tokens` response: `{"input_tokens": n}` only.
package enum CountTokensResponse {
  package static func translate(_ body: [UInt8]) throws(InferenceError) -> [UInt8] {
    guard
      let parsed = try? JSONParser.parse(body, limits: .init(maxBytes: 64 << 10, maxDepth: 8)),
      case .number(let count)? = parsed["input_tokens"], let value = count.int64, value >= 0
    else { throw InferenceError(.upstreamInvalid, "backend sent an invalid token count") }
    return JSON.object(JSONObject(["input_tokens": .int(value)])).serialized
  }
}
