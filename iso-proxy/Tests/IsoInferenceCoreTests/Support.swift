import Foundation
import IsoProxyCore
import Testing

@testable import IsoInferenceCore

func profile(
  _ backendProtocol: BackendProtocol, evidence: CompletionEvidence = .drain,
  maxInputBytes: Int = 1 << 20, tokenCounter: TokenCounter = .none
) -> QualificationProfile {
  QualificationProfile(
    name: "test-\(backendProtocol.rawValue)", backendProtocol: backendProtocol,
    evidence: evidence, streamCloseDrainMilliseconds: 250, contextOverflow: .reject,
    overheadPerRequestBytes: 512, overheadPerMessageBytes: 16, maxInputBytes: maxInputBytes,
    maxRequestBodyBytes: 4 << 20, tokenCounter: tokenCounter)
}

func grant(
  _ backendProtocol: BackendProtocol, alias: String = "local-coder",
  apis: Set<FrontendAPI>? = nil, port: UInt16 = 18080, maxActive: Int = 1,
  evidence: CompletionEvidence = .drain, maxInputBytes: Int = 1 << 20,
  tokenCounter: TokenCounter = .none
) -> ServiceGrant {
  let defaultAPI: FrontendAPI =
    switch backendProtocol {
    case .openAIChat: .openAIChat
    case .openAIResponses: .openAIResponses
    case .anthropicMessages: .anthropicMessages
    }
  return ServiceGrant(
    alias: alias,
    backend: BackendPolicy(
      id: BackendID(port: port), name: "mlx-main", maxActive: maxActive,
      profile: profile(
        backendProtocol, evidence: evidence, maxInputBytes: maxInputBytes,
        tokenCounter: tokenCounter),
      credential: nil),
    upstreamModel: "mlx-community/Test-Model-4bit", apis: apis ?? [defaultAPI],
    maxContextTokens: 131_072, defaultOutputTokens: 4_096, maxOutputTokens: 8_192,
    maxInputBytes: nil)
}

struct Fixture {
  let method: String
  let path: String
  let headers: [Header]
  let body: [UInt8]

  static func load(_ name: String) throws -> Fixture {
    let url = try #require(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/clients"))
    let data = try Data(contentsOf: url)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let headers = try #require(object["headers"] as? [[String]]).map { Header($0[0], $0[1]) }
    let body = try JSONSerialization.data(withJSONObject: try #require(object["body"]))
    return Fixture(
      method: try #require(object["method"] as? String),
      path: try #require(object["path"] as? String), headers: headers, body: Array(body))
  }
}

func json(_ text: String) throws -> JSON {
  try JSONParser.parse(Array(text.utf8), limits: .init(maxBytes: 1 << 24, maxDepth: 64))
}

func body(_ text: String) -> [UInt8] { Array(text.utf8) }
