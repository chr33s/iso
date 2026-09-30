/// Versioned field tables (§8.3.1), derived from recorded traffic of the
/// qualified clients (Claude Code 2.1.285, Codex CLI 0.159.2; fixtures in
/// Tests/IsoInferenceCoreTests/Fixtures) plus the public API references.
/// A client update that sends a new member fails with 422 until the table
/// is revised and the client requalified.
public struct FieldTable: Sendable {
  public let api: FrontendAPI
  public let version: String
  public let body: ObjectSchema

  public static func table(for api: FrontendAPI) -> FieldTable? {
    switch api {
    case .openAIChat: FieldTable(api: api, version: "openai-chat/1", body: Tables.chat)
    case .openAIResponses:
      FieldTable(api: api, version: "openai-responses/1", body: Tables.responses)
    case .anthropicMessages:
      FieldTable(api: api, version: "anthropic-messages/1", body: Tables.messages)
    case .anthropicCountTokens:
      FieldTable(api: api, version: "anthropic-count-tokens/1", body: Tables.countTokens)
    case .modelDiscovery: nil
    }
  }
}

enum Size {
  static let text = 16 << 20
  static let identifier = 256
  static let toolSchema = 256 << 10
  static let toolInput = 4 << 20
  static let smallObject = 64 << 10
  static let messages = 20_000
  static let blocks = 4_096
  static let tools = 512
}

enum Tables {
  static let text: Schema = .string(maxBytes: Size.text)
  static let identifier: Schema = .string(maxBytes: Size.identifier)
  static let droppedObject: Schema = .opaque(maxBytes: Size.smallObject)
  static let droppedLarge: Schema = .opaque(maxBytes: Size.text)
  static let outputLimit: Schema = .integer(1...10_000_000)

  // Backend-specific knobs that select models, adapters or templates on the
  // host: never guest request parameters (§8.4).
  static let hostSelected: [String: Rule] = [
    "draft_model": .deny, "num_draft_tokens": .deny, "adapters": .deny, "adapter": .deny,
    "adapter_path": .deny, "tokenizer": .deny, "chat_template": .deny,
    "chat_template_kwargs": .deny, "trust_remote_code": .deny, "model_path": .deny,
    "role_mapping": .deny, "download": .deny,
  ]

  // MARK: Anthropic Messages

  static let cacheControl: Rule = .drop(droppedObject)

  static let anthropicText = ObjectSchema(
    [
      "type": .forward(.enumeration(["text"])), "text": .forward(text),
      "cache_control": cacheControl, "citations": .drop(droppedLarge),
    ], required: ["text"])

  static let anthropicToolResultContent: Schema = .anyOf([
    text,
    .array(
      .tagged(TaggedSchema(variants: ["text": anthropicText], denied: ["image", "document"])),
      maxCount: Size.blocks),
  ])

  static let anthropicBlocks: Schema = .array(
    .tagged(
      TaggedSchema(
        variants: [
          "text": anthropicText,
          "tool_use": ObjectSchema(
            [
              "type": .forward(.enumeration(["tool_use"])), "id": .forward(identifier),
              "name": .forward(identifier), "input": .forward(.opaque(maxBytes: Size.toolInput)),
              "cache_control": cacheControl, "caller": .drop(droppedObject),
            ], required: ["id", "name", "input"]),
          "tool_result": ObjectSchema(
            [
              "type": .forward(.enumeration(["tool_result"])),
              "tool_use_id": .forward(identifier), "content": .forward(anthropicToolResultContent),
              "is_error": .forward(.bool), "cache_control": cacheControl,
            ], required: ["tool_use_id"]),
        ],
        // Prior-turn reasoning carries provider signatures a local model
        // cannot use; removing it cannot widen authority.
        dropped: ["thinking": droppedLarge, "redacted_thinking": droppedLarge],
        denied: [
          "image", "document", "search_result", "server_tool_use", "web_search_tool_result",
          "web_fetch_tool_result", "code_execution_tool_result", "mcp_tool_use",
          "mcp_tool_result", "container_upload",
        ])),
    maxCount: Size.blocks)

  static let anthropicMessage = ObjectSchema(
    [
      "role": .forward(.enumeration(["user", "assistant", "system"])),
      "content": .forward(.anyOf([text, anthropicBlocks])),
    ], required: ["role", "content"])

  static let anthropicSystem: Schema = .anyOf([
    text, .array(.tagged(TaggedSchema(variants: ["text": anthropicText])), maxCount: Size.blocks),
  ])

  static let anthropicCustomTool = ObjectSchema(
    [
      "type": .forward(.enumeration(["custom"])), "name": .forward(identifier),
      "description": .forward(text), "input_schema": .forward(.opaque(maxBytes: Size.toolSchema)),
      "cache_control": cacheControl, "strict": .drop(.bool),
      "eager_input_streaming": .drop(.bool), "defer_loading": .drop(.bool),
      "input_examples": .drop(droppedLarge),
    ], required: ["name", "input_schema"])

  /// Server-tool declarations (`web_search_20250305` and the like) are
  /// removed: the local model never sees them.
  static let anthropicTools: Schema = .array(
    .tagged(
      TaggedSchema(
        variants: ["custom": anthropicCustomTool],
        dropped: [
          "web_search_20250305": droppedObject, "web_fetch_20250910": droppedObject,
          "bash_20250124": droppedObject, "text_editor_20250728": droppedObject,
          "code_execution_20250825": droppedObject, "memory_20250818": droppedObject,
          "tool_search_tool_regex_20251119": droppedObject,
          "tool_search_tool_bm25_20251119": droppedObject,
        ],
        denied: ["mcp_toolset", "computer_20250124"],
        defaultVariant: "custom")),
    maxCount: Size.tools)

  static let anthropicToolChoice: Schema = .tagged(
    TaggedSchema(variants: [
      "auto": ObjectSchema([
        "type": .forward(.enumeration(["auto"])), "disable_parallel_tool_use": .forward(.bool),
      ]),
      "any": ObjectSchema([
        "type": .forward(.enumeration(["any"])), "disable_parallel_tool_use": .forward(.bool),
      ]),
      "tool": ObjectSchema(
        [
          "type": .forward(.enumeration(["tool"])), "name": .forward(identifier),
          "disable_parallel_tool_use": .forward(.bool),
        ], required: ["name"]),
      "none": ObjectSchema(["type": .forward(.enumeration(["none"]))]),
    ]))

  static let anthropicShared: [String: Rule] = [
    "model": .rewrite(identifier),
    "messages": .forward(.array(.object(anthropicMessage), maxCount: Size.messages)),
    "system": .forward(anthropicSystem),
    "tools": .forward(anthropicTools),
    "tool_choice": .forward(anthropicToolChoice),
    "thinking": .drop(droppedObject),
    "context_management": .drop(droppedObject),
    "output_config": .drop(droppedObject),
    "metadata": .drop(droppedObject),
    "container": .deny, "mcp_servers": .deny,
  ]

  static let messages = ObjectSchema(
    anthropicShared.merging(hostSelected) { a, _ in a }.merging([
      "max_tokens": .rewrite(outputLimit),
      "stream": .rewrite(.bool),
      "stop_sequences": .forward(.array(.string(maxBytes: 256), maxCount: 16)),
      "temperature": .forward(.number(0...2)),
      "top_p": .forward(.number(0...1)),
      "top_k": .forward(.integer(0...1_000)),
      // Claude Code's auto-mode classifier context: host paths and rules
      // with no meaning to a local model.
      "safeguards": .drop(droppedLarge),
      "service_tier": .drop(identifier),
      "inference_geo": .drop(identifier),
    ]) { a, _ in a }, required: ["model", "messages", "max_tokens"])

  static let countTokens = ObjectSchema(
    anthropicShared.merging(hostSelected) { a, _ in a }, required: ["model", "messages"])

  // MARK: OpenAI Responses

  static let responsesContent: Schema = .anyOf([
    text,
    .array(
      .tagged(
        TaggedSchema(
          variants: [
            "input_text": ObjectSchema(
              ["type": .forward(.enumeration(["input_text"])), "text": .forward(text)],
              required: ["text"]),
            "output_text": ObjectSchema(
              [
                "type": .forward(.enumeration(["output_text"])), "text": .forward(text),
                "annotations": .drop(droppedLarge), "logprobs": .drop(droppedLarge),
              ], required: ["text"]),
            "refusal": ObjectSchema(
              ["type": .forward(.enumeration(["refusal"])), "refusal": .forward(text)],
              required: ["refusal"]),
          ],
          denied: ["input_image", "input_file", "input_audio"])),
      maxCount: Size.blocks),
  ])

  static let responsesToolOutput: Schema = .anyOf([
    text,
    .array(
      .tagged(
        TaggedSchema(
          variants: [
            "input_text": ObjectSchema(
              ["type": .forward(.enumeration(["input_text"])), "text": .forward(text)],
              required: ["text"])
          ],
          denied: ["input_image", "input_file"])),
      maxCount: Size.blocks),
  ])

  static let responsesItems: Schema = .array(
    .tagged(
      TaggedSchema(
        variants: [
          "message": ObjectSchema(
            [
              "type": .forward(.enumeration(["message"])), "id": .drop(identifier),
              "role": .forward(.enumeration(["user", "assistant", "system", "developer"])),
              "content": .forward(responsesContent), "status": .drop(identifier),
            ], required: ["role", "content"]),
          "function_call": ObjectSchema(
            [
              "type": .forward(.enumeration(["function_call"])), "id": .drop(identifier),
              "call_id": .forward(identifier), "name": .forward(identifier),
              "namespace": .forward(identifier),
              "arguments": .forward(.string(maxBytes: Size.toolInput)),
              "status": .drop(identifier),
            ], required: ["call_id", "name", "arguments"]),
          "function_call_output": ObjectSchema(
            [
              "type": .forward(.enumeration(["function_call_output"])), "id": .drop(identifier),
              "call_id": .forward(identifier), "output": .forward(responsesToolOutput),
              "status": .drop(identifier),
            ], required: ["call_id", "output"]),
          "custom_tool_call": ObjectSchema(
            [
              "type": .forward(.enumeration(["custom_tool_call"])), "id": .drop(identifier),
              "call_id": .forward(identifier), "name": .forward(identifier),
              "input": .forward(.string(maxBytes: Size.toolInput)), "status": .drop(identifier),
            ], required: ["call_id", "name", "input"]),
          "custom_tool_call_output": ObjectSchema(
            [
              "type": .forward(.enumeration(["custom_tool_call_output"])), "id": .drop(identifier),
              "call_id": .forward(identifier), "output": .forward(responsesToolOutput),
            ], required: ["call_id", "output"]),
        ],
        // Encrypted provider reasoning and compaction summaries cannot be
        // read by a local model.
        dropped: ["reasoning": droppedLarge, "compaction": droppedLarge],
        denied: [
          "item_reference", "web_search_call", "file_search_call", "computer_call",
          "computer_call_output", "image_generation_call", "code_interpreter_call",
          "local_shell_call", "local_shell_call_output", "mcp_call", "mcp_list_tools",
          "mcp_approval_request", "mcp_approval_response",
        ],
        defaultVariant: "message")),
    maxCount: Size.messages)

  static let responsesFunctionTool = ObjectSchema(
    [
      "type": .forward(.enumeration(["function"])), "name": .forward(identifier),
      "description": .forward(text), "parameters": .forward(.opaque(maxBytes: Size.toolSchema)),
      "strict": .forward(.bool), "defer_loading": .drop(.bool),
    ], required: ["name"])

  static let hostedTools: [String: Schema] = [
    "web_search": droppedObject, "web_search_preview": droppedObject,
    "file_search": droppedObject, "code_interpreter": droppedObject,
    "image_generation": droppedObject, "computer_use_preview": droppedObject,
    "local_shell": droppedObject, "tool_search": droppedObject,
  ]

  static let responsesTools: Schema = .array(
    .tagged(
      TaggedSchema(
        variants: [
          "function": responsesFunctionTool,
          "custom": ObjectSchema(
            [
              "type": .forward(.enumeration(["custom"])), "name": .forward(identifier),
              "description": .forward(text), "format": .forward(.opaque(maxBytes: Size.toolSchema)),
            ], required: ["name"]),
          "namespace": ObjectSchema(
            [
              "type": .forward(.enumeration(["namespace"])), "name": .forward(identifier),
              "description": .forward(text),
              "tools": .forward(
                .array(
                  .tagged(TaggedSchema(variants: ["function": responsesFunctionTool])),
                  maxCount: Size.tools)),
            ], required: ["name", "tools"]),
        ],
        dropped: hostedTools, denied: ["mcp"])),
    maxCount: Size.tools)

  static let responses = ObjectSchema(
    hostSelected.merging([
      "model": .rewrite(identifier),
      "input": .forward(.anyOf([text, responsesItems])),
      "instructions": .forward(text),
      "tools": .forward(responsesTools),
      "tool_choice": .forward(
        .anyOf([
          .enumeration(["auto", "none", "required"]), .opaque(maxBytes: Size.smallObject),
        ])),
      "parallel_tool_calls": .forward(.bool),
      "max_output_tokens": .rewrite(outputLimit),
      "temperature": .forward(.number(0...2)),
      "top_p": .forward(.number(0...1)),
      "stream": .rewrite(.bool),
      "store": .rewrite(.bool),
      "text": .forward(
        .object(
          ObjectSchema([
            "format": .forward(.opaque(maxBytes: Size.toolSchema)), "verbosity": .drop(identifier),
          ]))),
      "include": .drop(.array(identifier, maxCount: 64)),
      "reasoning": .drop(droppedObject),
      "prompt_cache_key": .drop(identifier),
      "client_metadata": .drop(droppedObject),
      "metadata": .drop(droppedObject),
      "service_tier": .drop(identifier),
      "user": .drop(identifier),
      "safety_identifier": .drop(identifier),
      "truncation": .drop(identifier),
      "stream_options": .drop(droppedObject),
      "previous_response_id": .deny, "conversation": .deny, "background": .deny,
      "prompt": .deny, "top_logprobs": .deny, "max_tool_calls": .deny,
    ]) { _, new in new }, required: ["model"])

  // MARK: OpenAI Chat Completions

  static let chatText = ObjectSchema(
    ["type": .forward(.enumeration(["text"])), "text": .forward(text)], required: ["text"])

  static let chatTextContent: Schema = .anyOf([
    text,
    .array(.tagged(TaggedSchema(variants: ["text": chatText])), maxCount: Size.blocks),
  ])

  static let chatToolCalls: Schema = .array(
    .object(
      ObjectSchema(
        [
          "id": .forward(identifier), "type": .forward(.enumeration(["function"])),
          "function": .forward(
            .object(
              ObjectSchema(
                [
                  "name": .forward(identifier),
                  "arguments": .forward(.string(maxBytes: Size.toolInput)),
                ], required: ["name", "arguments"]))),
        ], required: ["id", "function"])),
    maxCount: Size.blocks)

  static let chatMessages: Schema = .array(
    .tagged(
      TaggedSchema(
        key: "role",
        variants: [
          "system": ObjectSchema(
            [
              "role": .forward(.enumeration(["system"])), "content": .forward(chatTextContent),
              "name": .forward(identifier),
            ], required: ["content"]),
          "developer": ObjectSchema(
            [
              "role": .forward(.enumeration(["developer"])),
              "content": .forward(chatTextContent), "name": .forward(identifier),
            ], required: ["content"]),
          "user": ObjectSchema(
            [
              "role": .forward(.enumeration(["user"])),
              "content": .forward(
                .anyOf([
                  text,
                  .array(
                    .tagged(
                      TaggedSchema(
                        variants: ["text": chatText],
                        denied: ["image_url", "input_audio", "file"])),
                    maxCount: Size.blocks),
                ])),
              "name": .forward(identifier),
            ], required: ["content"]),
          "assistant": ObjectSchema([
            "role": .forward(.enumeration(["assistant"])),
            "content": .forward(.anyOf([.null, chatTextContent])),
            "name": .forward(identifier), "tool_calls": .forward(chatToolCalls),
            "refusal": .forward(.anyOf([.null, text])),
            "reasoning_content": .drop(droppedLarge), "audio": .deny,
          ]),
          "tool": ObjectSchema(
            [
              "role": .forward(.enumeration(["tool"])), "content": .forward(chatTextContent),
              "tool_call_id": .forward(identifier),
            ], required: ["content", "tool_call_id"]),
        ],
        denied: ["function"])),
    maxCount: Size.messages)

  static let chat = ObjectSchema(
    hostSelected.merging([
      "model": .rewrite(identifier),
      "messages": .forward(chatMessages),
      "max_tokens": .rewrite(outputLimit),
      "max_completion_tokens": .rewrite(outputLimit),
      "n": .rewrite(.integer(1...1)),
      "stream": .rewrite(.bool),
      "stream_options": .rewrite(droppedObject),
      "temperature": .forward(.number(0...2)),
      "top_p": .forward(.number(0...1)),
      "frequency_penalty": .forward(.number(-2...2)),
      "presence_penalty": .forward(.number(-2...2)),
      "seed": .forward(.integer(Int64.min...Int64.max)),
      "stop": .forward(
        .anyOf([.string(maxBytes: 256), .array(.string(maxBytes: 256), maxCount: 4)])),
      "tools": .forward(
        .array(
          .object(
            ObjectSchema(
              [
                "type": .forward(.enumeration(["function"])),
                "function": .forward(
                  .object(
                    ObjectSchema(
                      [
                        "name": .forward(identifier), "description": .forward(text),
                        "parameters": .forward(.opaque(maxBytes: Size.toolSchema)),
                        "strict": .forward(.bool),
                      ], required: ["name"]))),
              ], required: ["type", "function"])),
          maxCount: Size.tools)),
      "tool_choice": .forward(
        .anyOf([
          .enumeration(["auto", "none", "required"]), .opaque(maxBytes: Size.smallObject),
        ])),
      "parallel_tool_calls": .forward(.bool),
      "response_format": .forward(.opaque(maxBytes: Size.toolSchema)),
      "user": .drop(identifier), "metadata": .drop(droppedObject), "store": .drop(.bool),
      "service_tier": .drop(identifier), "prompt_cache_key": .drop(identifier),
      "safety_identifier": .drop(identifier), "reasoning_effort": .drop(identifier),
      "verbosity": .drop(identifier),
      "logit_bias": .deny, "logprobs": .deny, "top_logprobs": .deny, "modalities": .deny,
      "audio": .deny, "prediction": .deny, "web_search_options": .deny, "functions": .deny,
      "function_call": .deny,
    ]) { _, new in new }, required: ["model", "messages"])
}
