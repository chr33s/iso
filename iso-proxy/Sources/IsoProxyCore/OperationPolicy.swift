package enum OperationPolicy {
  package static func allows(method: String, target: RequestTarget, provider: Provider) -> Bool {
    guard method == "POST" else { return false }
    switch provider {
    case .anthropic:
      return target.path == "/v1/messages" || target.path == "/v1/messages/count_tokens"
    case .openai:
      return target.path == "/v1/responses"
    }
  }
}
