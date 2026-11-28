import Foundation
import Testing

@testable import IsoProxyCore

private let token = String(repeating: "a", count: 64)
private let wrong = String(repeating: "b", count: 64)

@Test func capabilityFormatAndConstantTimeVerification() throws {
  let capability = try Capability(token)
  #expect(capability.verifies(token))
  #expect(!capability.verifies(wrong))
  for invalid in [
    "", "a", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
    String(repeating: "A", count: 64), String(repeating: "g", count: 64),
    String(repeating: "é", count: 32),
  ] {
    #expect(throws: PolicyError.self) { try Capability(invalid) }
    #expect(!capability.verifies(invalid))
  }
  #expect(!String(reflecting: capability).contains(token))
}

@Test func everyPresentedCredentialMustAgree() throws {
  let capability = try Capability(token)
  let auth = Header("Authorization", "Bearer " + token)
  let apiKey = Header("X-API-Key", token)
  let googKey = Header("X-Goog-Api-Key", token)
  for headers in [[auth], [apiKey], [googKey], [auth, apiKey], [apiKey, googKey]] {
    #expect(capability.authorizes(headers))
  }
  for headers in [
    [Header](), [auth, auth], [apiKey, apiKey],
    [auth, Header("x-api-key", wrong)], [Header("authorization", "Bearer " + wrong), apiKey],
    [googKey, googKey], [googKey, Header("x-api-key", wrong)],
    [apiKey, Header("x-goog-api-key", wrong)], [Header("x-goog-api-key", wrong)],
    [Header("authorization", "Basic " + token), apiKey],
    [Header("authorization", "Bearer ")], [Header("authorization", "bearer " + token)],
    [Header("authorization", "Bearer " + String(repeating: "a", count: 100_000))],
  ] {
    #expect(!capability.authorizes(headers))
  }
}

@Test func exactOperationPolicy() throws {
  let allowedPaths: [Provider: [String]] = [
    .anthropic: ["/v1/messages", "/v1/messages/count_tokens"], .openai: ["/v1/responses"],
    .google: [
      "/v1beta/models/gemini-3-pro:generateContent",
      "/v1beta/models/gemini-3.0-flash_x:streamGenerateContent",
      "/v1beta/models/gemini-3-pro:countTokens",
    ],
  ]
  for provider in Provider.allCases {
    let allowed = allowedPaths[provider]!
    for path in allowed {
      for suffix in ["", "?beta=true", "?", "?x=%2f"] {
        let target = try RequestTarget(path + suffix)
        #expect(OperationPolicy.allows(method: "POST", target: target, provider: provider))
        #expect(target.raw == path + suffix)
      }
      for method in ["GET", "DELETE", "TRACE", "CONNECT", "PUT", "post"] {
        #expect(
          !OperationPolicy.allows(
            method: method, target: try RequestTarget(path), provider: provider))
      }
      for suffix in ["/", "/id", "/../messages", "%2f", "/batches"] {
        #expect(
          !OperationPolicy.allows(
            method: "POST", target: try RequestTarget(path + suffix), provider: provider))
      }
    }
    for path in [
      "/v1/files", "/v1/organizations/invites", "/v1/../v1/messages", "/v1/%6dessages",
      "/v1beta/models/gemini:embedContent", "/v1beta/models/:generateContent",
      "/v1beta/models/a/b:generateContent", "/v1beta/models/a%2fb:generateContent",
      "/v1beta/models/Gemini:generateContent", "/v1beta/models/a:generateContent:x",
      "/v1beta/models/../files:generateContent", "/v1beta/files", "/upload/v1beta/files",
      "/v1beta/cachedContents", "/v1/models/gemini-3-pro:generateContent",
      "/v1beta/models/" + String(repeating: "a", count: 129) + ":generateContent",
    ] {
      #expect(
        !OperationPolicy.allows(method: "POST", target: try RequestTarget(path), provider: provider)
      )
    }
    let listing = try RequestTarget("/v1beta/models?pageSize=1000")
    #expect(
      OperationPolicy.allows(method: "GET", target: listing, provider: provider)
        == (provider == .google))
    for path in [
      "/v1beta/models/gemini-3-pro", "/v1beta/models/x:generateContent", "/v1beta/files",
    ] {
      #expect(
        !OperationPolicy.allows(method: "GET", target: try RequestTarget(path), provider: provider))
    }
    for other in Provider.allCases where other != provider {
      for path in allowedPaths[other]! {
        #expect(
          !OperationPolicy.allows(
            method: "POST", target: try RequestTarget(path), provider: provider))
      }
    }
  }
}

@Test func rawTargetsCannotChangeAuthority() throws {
  for value in [
    "https://api.anthropic.com/v1/messages", "http://evil/v1/messages", "evil:443", "*", "",
    "//evil/v1/messages",
    "/v1/messages#fragment", "/v1/messages\r\n", "/v1/messages?x=%", "/v1/messages?x=%gg",
    "/v1/\\messages",
  ] {
    #expect(throws: PolicyError.self) { try RequestTarget(value) }
  }
  #expect(Provider.anthropic.hostname == "api.anthropic.com")
  #expect(Provider.openai.hostname == "api.openai.com")
  #expect(Provider.google.hostname == "generativelanguage.googleapis.com")
  for provider in Provider.allCases {
    #expect(provider.scheme == "https")
    #expect(provider.port == 443)
  }
}

/// Foundation's URL parse, which builds the upstream request, percent-encodes
/// these bytes and then every `%` in the target (`?"%2F` went upstream as
/// `?%22%252F`), so they are refused before authorization.
@Test func requestTargetRefusesBytesTheUpstreamURLWouldRewrite() throws {
  for byte in "\"<>[]^`{|}" {
    #expect(throws: PolicyError.self) { try RequestTarget("/v1/messages?x=%2F\(byte)") }
    #expect(throws: PolicyError.self) { try RequestTarget("/v1/messages\(byte)") }
  }
  let kept = "/v1/messages?a=%2F&b=(x)!*'~:@/?$+,;=-._"
  #expect(try RequestTarget(kept).raw == kept)
}

@Test func headerRemovalAndInjection() throws {
  let hopNames = [
    "Connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
    "proxy-authenticate", "proxy-authorization",
  ]
  var headers = hopNames.map { Header($0, $0 == "Connection" ? "x-private, HOST" : "discard") }
  headers += [
    Header("connection", "x-second"), Header("x-private", "discard"), Header("x-second", "discard"),
    Header("authorization", "Bearer " + token), Header("x-api-key", token),
    Header("x-goog-api-key", token), Header("host", "evil"),
    Header("content-type", "application/json"), Header("anthropic-version", "2023-06-01"),
  ]
  for (provider, scheme) in [
    (Provider.anthropic, Injection.Scheme.xAPIKey), (.anthropic, .bearer), (.openai, .bearer),
    (.google, .xGoogAPIKey),
  ] {
    let injection = try Injection(scheme: scheme, credential: Secret("secret"), provider: provider)
    let out = try HeaderPolicy.request(headers, provider: provider, injection: injection)
    #expect(out.count == 4)
    #expect(out.contains(Header("host", provider.hostname)))
    #expect(out.contains(Header("content-type", "application/json")))
    #expect(out.contains(Header("anthropic-version", "2023-06-01")))
    let injected =
      switch scheme {
      case .bearer: Header("authorization", "Bearer secret")
      case .xAPIKey: Header("x-api-key", "secret")
      case .xGoogAPIKey: Header("x-goog-api-key", "secret")
      }
    #expect(out.contains(injected))
    #expect(!out.contains { $0.value.contains(token) })
  }
  let response = try HeaderPolicy.response([
    Header("connection", "x-private"), Header("x-private", "hidden"),
    Header("location", "https://elsewhere"),
  ])
  #expect(response == [Header("location", "https://elsewhere")])
  for nomination in ["", "x-private,", "x-private,,x-other", "bad header"] {
    #expect(throws: PolicyError.self) {
      try HeaderPolicy.response([Header("connection", nomination)])
    }
  }
}

@Test func resourceConstants() {
  #expect(Limits.connections == 256)
  #expect(Limits.requests == 256)
  #expect(Limits.headerFieldBytes == 16_384)
  #expect(Limits.headerBlockBytes == 65_536)
  #expect(Limits.headerCount == 128)
  #expect(Limits.requestBodyBytes == 67_108_864)
  #expect(Limits.establishmentSeconds == 30)
  #expect(Limits.initialHeaderSeconds == 10)
  #expect(Limits.bodyIdleSeconds == 30)
}
