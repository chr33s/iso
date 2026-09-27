public enum Provider: String, Sendable, Decodable, CaseIterable {
  case anthropic, openai

  public var hostname: String {
    switch self {
    case .anthropic: "api.anthropic.com"
    case .openai: "api.openai.com"
    }
  }
  public var port: Int { 443 }
  public var scheme: String { "https" }
}
