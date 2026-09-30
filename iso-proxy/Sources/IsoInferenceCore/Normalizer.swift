/// A validated request rebuilt for the backend (§8.1 steps 4–8).
public struct NormalizedRequest: Sendable {
  public let api: FrontendAPI
  public let grant: ServiceGrant
  public let upstreamPath: String
  public let upstreamBody: [UInt8]
  public let clientStreams: Bool
  public let upstreamStreams: Bool
  /// Conservative upper bound on input tokens (§8.4.1).
  public let inputBound: Int
  /// The explicit upstream output limit; 0 for token counting.
  public let outputTokens: Int
  public let clamped: Bool
}

public enum Normalizer {
  static func parseLimits(_ maxBytes: Int) -> JSONParser.Limits {
    JSONParser.Limits(maxBytes: maxBytes, maxDepth: SessionLimits.jsonDepth)
  }

  /// Parse, validate against the field table, resolve the alias and build
  /// the upstream document. `grants` are the session's, by alias.
  public static func normalize(
    api: FrontendAPI, body: [UInt8], grants: [String: ServiceGrant]
  ) throws(InferenceError) -> NormalizedRequest {
    guard let table = FieldTable.table(for: api) else {
      throw InferenceError(.policyDenied, "route is not an inference operation")
    }
    let limit = grants.values.map(\.maxRequestBodyBytes).max() ?? 0
    let root: JSON
    do {
      root = try JSONParser.parse(body, limits: parseLimits(limit))
    } catch {
      switch error {
      case .tooLarge: throw InferenceError(.requestTooLarge, "request body is too large")
      case .tooDeep: throw InferenceError(.requestInvalid, "request body is nested too deeply")
      case .duplicateKey: throw InferenceError(.requestInvalid, "request body has a duplicate key")
      case .invalidUTF8: throw InferenceError(.requestInvalid, "request body is not valid UTF-8")
      case .syntax, .trailingData:
        throw InferenceError(.requestInvalid, "request body is not valid JSON")
      }
    }
    let validated = try SchemaValidator.validate(root, table.body)
    guard case .string(let alias)? = validated.rewrites["model"] else {
      throw InferenceError(.requestInvalid, "field 'model' is required")
    }
    guard let grant = grants[alias], grant.apis.contains(api) else {
      throw InferenceError(.policyDenied, "model '\(displayName(alias))' is not authorized")
    }
    guard body.count <= grant.maxRequestBodyBytes else {
      throw InferenceError(.requestTooLarge, "request body is too large")
    }
    guard grant.backend.profile.backendProtocol == api.backendProtocol else {
      throw InferenceError(
        .protocolUnsupported, "the backend for '\(displayName(alias))' does not serve this API")
    }
    var document = validated.document
    document["model"] = .string(grant.upstreamModel)

    let clientStreams = validated.rewrites["stream"]?.bool ?? false
    var outputTokens = 0
    var clamped = false
    if api != .anthropicCountTokens {
      let requested = try requestedOutput(api, validated.rewrites)
      outputTokens = min(requested ?? grant.defaultOutputTokens, grant.maxOutputTokens)
      clamped = (requested ?? 0) > grant.maxOutputTokens
      document["stream"] = .bool(true)
    }
    switch api {
    case .openAIChat:
      document["max_tokens"] = .int(Int64(outputTokens))
      document["stream_options"] = .object(JSONObject(["include_usage": .bool(true)]))
    case .openAIResponses:
      document["max_output_tokens"] = .int(Int64(outputTokens))
      document["store"] = .bool(false)
    case .anthropicMessages:
      document["max_tokens"] = .int(Int64(outputTokens))
    case .anthropicCountTokens:
      guard grant.backend.profile.tokenCounter == .backend else {
        throw InferenceError(
          .protocolUnsupported, "no qualified exact token counter for '\(displayName(alias))'")
      }
    case .modelDiscovery:
      throw InferenceError(.policyDenied, "route is not an inference operation")
    }
    let upstreamBody = JSON.object(document).serialized
    let profile = grant.backend.profile
    let bound =
      upstreamBody.count + profile.overheadPerRequestBytes
      + profile.overheadPerMessageBytes * messageCount(api, document)
    guard bound <= grant.effectiveMaxInputBytes else {
      throw InferenceError(
        .unsupported,
        "request input (\(bound) bytes bound) exceeds the \(grant.effectiveMaxInputBytes)-byte limit for '\(displayName(alias))'"
      )
    }
    return NormalizedRequest(
      api: api, grant: grant, upstreamPath: api.path, upstreamBody: upstreamBody,
      clientStreams: clientStreams && api != .anthropicCountTokens,
      upstreamStreams: api != .anthropicCountTokens, inputBound: bound,
      outputTokens: outputTokens, clamped: clamped)
  }

  static func requestedOutput(_ api: FrontendAPI, _ rewrites: [String: JSON])
    throws(InferenceError) -> Int?
  {
    func value(_ key: String) -> Int? {
      rewrites[key]?.number?.int64.map { Int(clamping: $0) }
    }
    switch api {
    case .openAIChat:
      let legacy = value("max_tokens")
      let current = value("max_completion_tokens")
      if let legacy, let current, legacy != current {
        throw InferenceError(
          .requestInvalid, "max_tokens and max_completion_tokens disagree")
      }
      return current ?? legacy
    case .openAIResponses: return value("max_output_tokens")
    case .anthropicMessages: return value("max_tokens")
    case .anthropicCountTokens, .modelDiscovery: return nil
    }
  }

  static func messageCount(_ api: FrontendAPI, _ document: JSONObject) -> Int {
    switch api {
    case .openAIChat: return document["messages"]?.array?.count ?? 0
    case .openAIResponses:
      let items = document["input"]?.array?.count ?? 1
      return items + (document["instructions"] == nil ? 0 : 1)
    case .anthropicMessages, .anthropicCountTokens:
      let system: Int
      switch document["system"] {
      case .array(let blocks)?: system = blocks.count
      case .string?: system = 1
      default: system = 0
      }
      return (document["messages"]?.array?.count ?? 0) + system
    case .modelDiscovery: return 0
    }
  }

  /// The synthetic `GET /v1/models` body: only the session's aliases.
  public static func discovery(_ grants: [String: ServiceGrant]) -> [UInt8] {
    let data = grants.keys.sorted().map { alias in
      JSON.object(
        JSONObject([
          "id": .string(alias), "object": .string("model"), "owned_by": .string("iso"),
        ]))
    }
    return JSON.object(JSONObject(["object": .string("list"), "data": .array(data)])).serialized
  }
}
