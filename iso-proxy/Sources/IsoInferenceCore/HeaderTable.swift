import IsoProxyCore

/// Request headers are never forwarded: the gateway rebuilds every upstream
/// header (§8.2). This table decides which guest headers a request may carry
/// at all. Names the qualified clients send are accepted and discarded;
/// framing and browser headers fail the request; anything else is unknown
/// and fails with 422, like an unknown body member.
public enum HeaderTable {
  static let accepted: Set<String> = [
    "host", "content-type", "content-length", "authorization", "x-api-key", "accept",
    "accept-encoding", "accept-language", "user-agent", "connection", "keep-alive", "expect",
    "cache-control", "pragma", "priority",
    // Anthropic SDK and Claude Code.
    "anthropic-version", "anthropic-beta", "anthropic-dangerous-direct-browser-access", "x-app",
    // OpenAI SDK and Codex.
    "openai-organization", "openai-project", "openai-beta", "originator", "session-id",
    "session_id", "thread-id", "x-client-request-id", "version", "conversation_id",
    // Tracing.
    "traceparent", "tracestate", "x-request-id",
    // Removed rather than forwarded (§8.2): credentials for other hops,
    // forwarding metadata, cookies.
    "proxy-authorization", "cookie", "forwarded", "via",
  ]

  static let acceptedPrefixes = ["x-stainless-", "x-codex-", "x-claude-code-", "x-forwarded-"]

  /// Checks one request head. `hasBody` is true for every POST route.
  public static func check(_ headers: [Header], hasBody: Bool) throws(InferenceError) {
    var contentTypes = 0
    for header in headers {
      let name = header.name.lowercased()
      let value = header.value.trimmed(of: " \t")
      switch name {
      case "origin":
        throw InferenceError(.policyDenied, "browser-origin requests are not accepted")
      case "transfer-encoding":
        throw InferenceError(.lengthRequired, "chunked request bodies are not accepted")
      case "content-encoding":
        guard value.lowercased() == "identity" else {
          throw InferenceError(.requestInvalid, "compressed request bodies are not accepted")
        }
      case "upgrade", "te", "trailer", "http2-settings":
        throw InferenceError(.requestInvalid, "protocol upgrades are not accepted")
      case "expect":
        guard value.lowercased() == "100-continue" else {
          throw InferenceError(.requestInvalid, "unsupported Expect header")
        }
      case "content-type":
        contentTypes += 1
        let media = value.split(separator: ";", maxSplits: 1)[0]
          .trimmed(of: " \t").lowercased()
        guard media == "application/json" else {
          throw InferenceError(.requestInvalid, "request bodies must be application/json")
        }
      default:
        guard accepted.contains(name) || acceptedPrefixes.contains(where: name.hasPrefix) else {
          throw InferenceError(.unsupported, "header '\(displayName(name))' is not supported")
        }
      }
    }
    guard contentTypes <= 1 else {
      throw InferenceError(.requestInvalid, "duplicate Content-Type header")
    }
    if hasBody && contentTypes == 0 {
      throw InferenceError(.requestInvalid, "request bodies must be application/json")
    }
  }
}

extension StringProtocol {
  func trimmed(of set: String) -> String {
    let characters = Set(set)
    var slice = Substring(self)[...]
    while let first = slice.first, characters.contains(first) { slice = slice.dropFirst() }
    while let last = slice.last, characters.contains(last) { slice = slice.dropLast() }
    return String(slice)
  }
}
