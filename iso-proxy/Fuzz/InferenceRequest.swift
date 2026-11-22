import IsoInferenceCore
import IsoProxyCore

/// Guest request bodies through the production parser, field tables and
/// normalizer. The first byte selects the API. Accepted requests must
/// rebuild into a JSON object that names only the host-selected model,
/// streams upstream, and carries no host-selected knob.
public enum InferenceRequestHarness {
  static let apis: [FrontendAPI] = [
    .openAIChat, .openAIResponses, .anthropicMessages, .anthropicCountTokens,
  ]

  static func grant(_ api: FrontendAPI) -> ServiceGrant {
    let backendProtocol = api.backendProtocol!
    return ServiceGrant(
      alias: "local-coder",
      backend: BackendPolicy(
        id: BackendID(port: 18080), name: "fuzz", maxActive: 1,
        profile: QualificationProfile(
          name: "fuzz", backendProtocol: backendProtocol, evidence: .drain,
          streamCloseDrainMilliseconds: 0, contextOverflow: .reject, overheadPerRequestBytes: 64,
          overheadPerMessageBytes: 8, maxInputBytes: 1 << 20, maxRequestBodyBytes: 1 << 20,
          tokenCounter: .backend),
        credential: nil),
      upstreamModel: "upstream/model", apis: [api], maxContextTokens: 32_768,
      defaultOutputTokens: 256, maxOutputTokens: 1_024, maxInputBytes: nil)
  }

  static let hostSelected = [
    "draft_model", "adapters", "adapter", "chat_template", "trust_remote_code", "tokenizer",
  ]

  public static func run(_ bytes: [UInt8]) {
    guard let selector = bytes.first else { return }
    let api = apis[Int(selector) % apis.count]
    let body = Array(bytes.dropFirst())
    guard
      let request = try? Normalizer.normalize(
        api: api, body: body, grants: ["local-coder": grant(api)])
    else { return }
    let rebuilt = try? JSONParser.parse(
      request.upstreamBody, limits: .init(maxBytes: 8 << 20, maxDepth: 64))
    guard case .object(let object)? = rebuilt else {
      require(false, "an accepted request rebuilds into a JSON object")
      return
    }
    require(object["model"] == .string("upstream/model"), "the upstream model is host-selected")
    require(
      api == .anthropicCountTokens || object["stream"] == .bool(true), "the backend always streams")
    for key in hostSelected {
      require(object[key] == nil, "host-selected knobs never reach the backend")
    }
    require(request.outputTokens <= 1_024, "output never exceeds the ceiling")
    require(request.inputBound >= request.upstreamBody.count, "the input bound covers the body")
  }
}
