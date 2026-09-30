/// Stable gateway error codes (§13). Messages are fixed text or carry only
/// sanitized field names; they never echo request bodies, tokens or paths.
public enum InferenceErrorCode: String, Sendable, CaseIterable {
  case authInvalid = "INFERENCE_AUTH_INVALID"
  case sessionRevoked = "INFERENCE_SESSION_REVOKED"
  case policyDenied = "INFERENCE_POLICY_DENIED"
  case requestInvalid = "INFERENCE_REQUEST_INVALID"
  case lengthRequired = "INFERENCE_LENGTH_REQUIRED"
  case requestTooLarge = "INFERENCE_REQUEST_TOO_LARGE"
  case unsupported = "INFERENCE_UNSUPPORTED"
  case protocolUnsupported = "INFERENCE_PROTOCOL_UNSUPPORTED"
  case modelUnqualified = "INFERENCE_MODEL_UNQUALIFIED"
  case capacity = "INFERENCE_CAPACITY"
  case upstreamInvalid = "INFERENCE_UPSTREAM_INVALID"
  case backendUnavailable = "INFERENCE_BACKEND_UNAVAILABLE"
  case backendQuarantined = "INFERENCE_BACKEND_QUARANTINED"
  case backendUnsafeBind = "INFERENCE_BACKEND_UNSAFE_BIND"
  case deadline = "INFERENCE_DEADLINE"

  public var status: Int {
    switch self {
    case .authInvalid, .sessionRevoked: 401
    case .policyDenied: 403
    case .requestInvalid: 400
    case .lengthRequired: 411
    case .requestTooLarge: 413
    case .unsupported, .protocolUnsupported, .modelUnqualified: 422
    case .capacity: 429
    case .upstreamInvalid: 502
    case .backendUnavailable, .backendQuarantined, .backendUnsafeBind: 503
    case .deadline: 504
    }
  }
}

public struct InferenceError: Error, Sendable, Equatable {
  public let code: InferenceErrorCode
  public let message: String

  public init(_ code: InferenceErrorCode, _ message: String) {
    self.code = code
    self.message = message
  }

  /// The JSON error body in the frontend protocol's own shape.
  public func body(for api: FrontendAPI?) -> [UInt8] {
    let detail: JSON
    switch api {
    case .anthropicMessages?, .anthropicCountTokens?:
      detail = .object(
        JSONObject([
          "type": .string("error"),
          "error": .object(
            JSONObject([
              "type": .string(anthropicType), "message": .string(message),
              "code": .string(code.rawValue),
            ])),
        ]))
    default:
      detail = .object(
        JSONObject([
          "error": .object(
            JSONObject([
              "message": .string(message), "type": .string(openAIType),
              "code": .string(code.rawValue),
            ]))
        ]))
    }
    return detail.serialized
  }

  var anthropicType: String {
    switch code.status {
    case 401: "authentication_error"
    case 403: "permission_error"
    case 413: "request_too_large"
    case 429: "rate_limit_error"
    case 503, 504: "overloaded_error"
    case 500...: "api_error"
    default: "invalid_request_error"
    }
  }

  var openAIType: String {
    switch code.status {
    case 401: "authentication_error"
    case 403: "permission_error"
    case 429: "rate_limit_error"
    case 500...: "server_error"
    default: "invalid_request_error"
    }
  }
}

/// A field name safe to show the guest and to keep in a response: printable
/// ASCII identifier characters only, truncated. Anything else is described
/// generically so attacker-chosen keys never reach logs verbatim.
func displayName(_ key: String) -> String {
  let allowed = key.utf8.allSatisfy {
    (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
      || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: ".")
  }
  guard allowed, !key.isEmpty else { return "<field>" }
  return key.utf8.count <= 64 ? key : String(key.prefix(64)) + "…"
}
