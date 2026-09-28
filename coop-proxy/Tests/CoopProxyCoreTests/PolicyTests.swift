import Foundation
import Testing

@testable import CoopProxyCore

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
  for headers in [[auth], [apiKey], [auth, apiKey]] {
    #expect(capability.authorizes(headers))
  }
  for headers in [
    [Header](), [auth, auth], [apiKey, apiKey],
    [auth, Header("x-api-key", wrong)], [Header("authorization", "Bearer " + wrong), apiKey],
    [Header("authorization", "Basic " + token), apiKey],
    [Header("authorization", "Bearer ")], [Header("authorization", "bearer " + token)],
    [Header("authorization", "Bearer " + String(repeating: "a", count: 100_000))],
  ] {
    #expect(!capability.authorizes(headers))
  }
}

@Test func exactOperationPolicy() throws {
  for provider in Provider.allCases {
    let allowed =
      provider == .anthropic ? ["/v1/messages", "/v1/messages/count_tokens"] : ["/v1/responses"]
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
    for path in ["/v1/files", "/v1/organizations/invites", "/v1/../v1/messages", "/v1/%6dessages"] {
      #expect(
        !OperationPolicy.allows(method: "POST", target: try RequestTarget(path), provider: provider)
      )
    }
    let other = try RequestTarget(provider == .anthropic ? "/v1/responses" : "/v1/messages")
    #expect(!OperationPolicy.allows(method: "POST", target: other, provider: provider))
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
  for provider in Provider.allCases {
    #expect(provider.scheme == "https")
    #expect(provider.port == 443)
  }
}

@Test func headerRemovalAndInjection() throws {
  let hopNames = [
    "Connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
    "proxy-authenticate", "proxy-authorization",
  ]
  var headers = hopNames.map { Header($0, $0 == "Connection" ? "x-private, HOST" : "discard") }
  headers += [
    Header("connection", "x-second"), Header("x-private", "discard"), Header("x-second", "discard"),
    Header("authorization", "Bearer " + token), Header("x-api-key", token), Header("host", "evil"),
    Header("content-type", "application/json"), Header("anthropic-version", "2023-06-01"),
  ]
  for (provider, scheme) in [
    (Provider.anthropic, Injection.Scheme.xAPIKey), (.anthropic, .bearer), (.openai, .bearer),
  ] {
    let injection = try Injection(scheme: scheme, credential: Secret("secret"), provider: provider)
    let out = try HeaderPolicy.request(headers, provider: provider, injection: injection)
    #expect(out.count == 4)
    #expect(out.contains(Header("host", provider.hostname)))
    #expect(out.contains(Header("content-type", "application/json")))
    #expect(out.contains(Header("anthropic-version", "2023-06-01")))
    #expect(
      out.contains(
        scheme == .bearer ? Header("authorization", "Bearer secret") : Header("x-api-key", "secret")
      ))
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
