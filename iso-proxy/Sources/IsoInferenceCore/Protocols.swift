/// A guest-facing API a session may be granted. Each maps to exactly one
/// route; nothing else is served on a session listener.
public enum FrontendAPI: String, Sendable, CaseIterable, Hashable {
  case openAIChat = "openai-chat"
  case openAIResponses = "openai-responses"
  case anthropicMessages = "anthropic-messages"
  case anthropicCountTokens = "anthropic-count-tokens"
  case modelDiscovery = "model-discovery"

  public var method: String { self == .modelDiscovery ? "GET" : "POST" }

  public var path: String {
    switch self {
    case .openAIChat: "/v1/chat/completions"
    case .openAIResponses: "/v1/responses"
    case .anthropicMessages: "/v1/messages"
    case .anthropicCountTokens: "/v1/messages/count_tokens"
    case .modelDiscovery: "/v1/models"
    }
  }

  /// Exact query strings a qualified client sends (field table §8.2).
  /// Claude Code adds `?beta=true` to every Messages call.
  public var allowedQueries: Set<String> {
    switch self {
    case .anthropicMessages, .anthropicCountTokens: ["beta=true"]
    default: []
    }
  }

  /// The backend protocol a same-protocol adapter needs for this frontend.
  /// Discovery is synthetic and needs none.
  public var backendProtocol: BackendProtocol? {
    switch self {
    case .openAIChat: .openAIChat
    case .openAIResponses: .openAIResponses
    case .anthropicMessages, .anthropicCountTokens: .anthropicMessages
    case .modelDiscovery: nil
    }
  }

  /// The route a request head names, before authorization. Query strings
  /// outside the table fail here.
  public static func route(method: String, target: String) -> FrontendAPI? {
    let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    let path = String(pieces[0])
    guard let api = allCases.first(where: { $0.path == path && $0.method == method }) else {
      return nil
    }
    if pieces.count == 2 {
      guard api.allowedQueries.contains(String(pieces[1])) else { return nil }
    }
    return api
  }
}

/// The wire protocol an attached backend was qualified to serve.
public enum BackendProtocol: String, Sendable, CaseIterable, Hashable {
  case openAIChat = "openai-chat"
  case openAIResponses = "openai-responses"
  case anthropicMessages = "anthropic-messages"

  public var path: String {
    switch self {
    case .openAIChat: "/v1/chat/completions"
    case .openAIResponses: "/v1/responses"
    case .anthropicMessages: "/v1/messages"
    }
  }
}

/// How a qualified backend proves that a request's work ended (§9.2).
public enum CompletionEvidence: String, Sendable, CaseIterable, Hashable {
  /// A backend cancellation or job-status API. No qualified backend offers
  /// one yet, so registration refuses it until an adapter implements it.
  case explicit
  /// Closing the upstream stream stops generation (qualified by test).
  case streamClose = "stream-close"
  /// Only the stream's terminal event or end shows the work ended.
  case drain
  /// No reliable evidence: any cancellation quarantines the backend.
  case none
}

/// What a backend does with a prompt longer than its context window.
public enum ContextOverflow: String, Sendable, CaseIterable, Hashable {
  case reject
  case truncate
  /// Processes it past the window (degraded output); only the gateway's
  /// input bound limits it.
  case accept
}

/// A qualified exact token counter for `count_tokens`.
public enum TokenCounter: String, Sendable, CaseIterable, Hashable {
  /// No exact counter: `count_tokens` is not served.
  case none
  /// The backend's own `/v1/messages/count_tokens`.
  case backend
}
