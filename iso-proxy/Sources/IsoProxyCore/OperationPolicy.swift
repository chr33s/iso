package enum OperationPolicy {
  package static func allows(method: String, target: RequestTarget, provider: Provider) -> Bool {
    // agy lists models (`GET /v1beta/models?pageSize=…`) before choosing one.
    if provider == .google && method == "GET" { return target.path == "/v1beta/models" }
    guard method == "POST" else { return false }
    switch provider {
    case .anthropic:
      return target.path == "/v1/messages" || target.path == "/v1/messages/count_tokens"
    case .openai:
      return target.path == "/v1/responses"
    case .google:
      return geminiModelMethod(target.path)
    }
  }

  /// Gemini generation methods on one model: `/v1beta/models/{model}:{method}`.
  /// The model segment is a plain id, so no encoded or nested path matches.
  static let geminiMethods: Set<Substring> = [
    "generateContent", "streamGenerateContent", "countTokens",
  ]

  static func geminiModelMethod(_ path: String) -> Bool {
    let prefix = "/v1beta/models/"
    guard path.hasPrefix(prefix) else { return false }
    let rest = path.dropFirst(prefix.count)
    let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, geminiMethods.contains(parts[1]) else { return false }
    let model = parts[0]
    return !model.isEmpty && model.utf8.count <= 128
      && model.utf8.allSatisfy { byte in
        (97...122).contains(byte) || (48...57).contains(byte) || byte == 45 || byte == 46
          || byte == 95
      }
  }
}
