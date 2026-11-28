import IsoProxyCore

extension Provider {
  /// One operation each provider admits, for tests that run every provider.
  var fixturePath: String {
    switch self {
    case .anthropic: "/v1/messages"
    case .openai: "/v1/responses"
    case .google: "/v1beta/models/gemini-test:generateContent"
    }
  }

  /// The startup injection scheme each provider accepts.
  var fixtureScheme: String {
    switch self {
    case .anthropic: "x_api_key"
    case .openai: "bearer"
    case .google: "x_goog_api_key"
    }
  }
}
