// Property tests for what a guest request can influence upstream: the
// request target, the forwarded headers and the capability check, each
// against an independent model and through `UpstreamClient.request`.

import AsyncHTTPClient
import Foundation
import IsoProxyCore
import NIOHTTP1
import Testing

@testable import IsoProxyTransport

// MARK: - Request targets

/// Pieces that, alone or combined, try to name another authority or smuggle
/// syntax past the target check.
private let targetPrefixes = [
  "", "/", "//", "///", "/\\", "\\", "http://evil.example", "https://api.anthropic.com",
  "HTTPS://api.openai.com:443", "evil.example:443", "*", "@evil.example", "//evil.example",
  "/@evil.example", " /", "%2f", "/%2F%2Fevil.example", "/./", "/..",
]
private let operationPaths = ["/v1/messages", "/v1/messages/count_tokens", "/v1/responses"]
private let pathPieces = [
  "v1", "messages", "responses", "count_tokens", "..", ".", "%2e%2e", "%2F", "%2f", "evil.example",
  "@evil.example", ":443", "", "a", "%", "%g0", "%0", "%41", "\\", "é", " ", "\t", "\r\n", "#",
]
private let queryAlphabet: [String] = [
  "a", "=", "&", "?", "/", "//", "@", ":", ";", "%2f", "%2F", "%", "%zz", "%4", "#", "\\", " ",
  "\t", "\r", "\n", "\u{0}", "\u{7F}", "é", "|", "{", "}", "^", "`", "[", "]", "\"", "<", ">",
  "'", "!", "$", "(", ")", "*", "+", ",", "~", "evil.example", "https://evil.example",
]

private func targetText(_ rng: inout PropertyRNG) -> String {
  var target: String
  if rng.oneIn(2) {
    target = rng.element(operationPaths)
    if rng.oneIn(4) { target = rng.element(targetPrefixes) + target }
  } else {
    target =
      rng.element(targetPrefixes)
      + (0..<rng.int(0...4)).map { _ in rng.element(pathPieces) }.joined(separator: "/")
  }
  if rng.oneIn(6) { target += rng.element(pathPieces) }
  if !rng.oneIn(3) {
    target += "?" + (0..<rng.int(0...6)).map { _ in rng.element(queryAlphabet) }.joined()
  }
  return target
}

/// RFC 3986 origin form, written independently: a leading `/` but not `//`,
/// only unreserved, sub-delim, `:`, `@`, `/`, `?` and `%` bytes, and every
/// `%` followed by two hex digits. Returns the path (up to the first `?`).
private let uriBytes = Set(
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?%".utf8)

private func modelTargetPath(_ raw: String) -> String? {
  let bytes = Array(raw.utf8)
  guard bytes.first == UInt8(ascii: "/"), bytes.dropFirst().first != UInt8(ascii: "/") else {
    return nil
  }
  for (index, byte) in bytes.enumerated() {
    guard uriBytes.contains(byte) else { return nil }
    if byte == UInt8(ascii: "%") {
      let hex = Array("0123456789abcdefABCDEF".utf8)
      guard index + 2 < bytes.count, hex.contains(bytes[index + 1]), hex.contains(bytes[index + 2])
      else { return nil }
    }
  }
  return String(raw.prefix { $0 != "?" })
}

@Test func requestTargetAcceptsExactlyOriginForm() {
  expectHolds(
    checkProperty(
      "RequestTarget accepts exactly origin form", iterations: 3000, generate: targetText
    ) {
      raw in
      let parsed = try? RequestTarget(raw)
      let expected = modelTargetPath(raw)
      guard parsed?.path == expected else {
        return "parsed path \(parsed?.path ?? "nil"), model \(expected ?? "nil")"
      }
      if let parsed, parsed.raw != raw { return "kept \(parsed.raw), not the raw target" }
      return nil
    })
}

private func proxyConfig(_ provider: Provider, scheme: Injection.Scheme) throws -> ProxyConfig {
  try ProxyConfig(
    json: JSONSerialization.data(withJSONObject: [
      "version": 1, "provider": provider.rawValue, "listen": "127.0.0.1:0",
      "capability_token": String(repeating: "a", count: 64),
      "injection": [
        "scheme": scheme.rawValue, "credential": "upstream-\(provider.rawValue)-secret",
      ],
    ]))
}

private let configurations: [(Provider, Injection.Scheme, ProxyConfig)] = [
  (.anthropic, .xAPIKey), (.anthropic, .bearer), (.openai, .bearer),
].map { provider, scheme in (provider, scheme, try! proxyConfig(provider, scheme: scheme)) }

private let allowedPaths: [Provider: Set<String>] = [
  .anthropic: ["/v1/messages", "/v1/messages/count_tokens"], .openai: ["/v1/responses"],
]

private struct TargetCase: CustomStringConvertible {
  let method: HTTPMethod
  let target: String
  let configuration: Int
  var description: String { "\(method) \(target) via configuration \(configuration)" }
}

/// Whatever the guest sends as method and target, the upstream request is
/// built only for `POST` to one of the provider's exact operation paths,
/// always to the provider's fixed https authority, and the request line
/// `OwnedHTTPRequest` writes is the authorized target, byte for byte.
@Test func upstreamRequestNeverLeavesTheProviderAuthority() {
  expectHolds(
    checkProperty(
      "UpstreamClient.request keeps the fixed authority", iterations: 3000,
      generate: { rng in
        TargetCase(
          method: rng.oneIn(5) ? rng.element([.GET, .PUT, .CONNECT, .RAW(value: "post")]) : .POST,
          target: targetText(&rng), configuration: rng.below(configurations.count))
      },
      property: { input in
        let (provider, _, config) = configurations[input.configuration]
        let head = HTTPRequestHead(version: .http1_1, method: input.method, uri: input.target)
        let authorized =
          input.method == .POST
          && modelTargetPath(input.target).map { allowedPaths[provider]!.contains($0) } == true
        guard
          let request = try? UpstreamClient.request(head: head, config: config, body: .bytes([]))
        else { return authorized ? "refused an authorized request" : nil }
        guard authorized else { return "built a request the operation policy refuses" }
        guard request.host == provider.hostname, request.port == 443, request.useTLS,
          request.url.scheme == "https", request.url.host == provider.hostname,
          request.url.port == nil, request.url.user == nil, request.url.password == nil
        else { return "upstream authority became \(request.url.absoluteString)" }
        guard let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else {
          return "the built URL does not parse"
        }
        // The request line OwnedHTTPRequest derives from the URL.
        let uri = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        return uri == input.target ? nil : "request line \(uri), authorized \(input.target)"
      }))
}

// MARK: - Headers

private let hopByHop = [
  "connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade",
  "proxy-authenticate", "proxy-authorization",
]
private let replaced = ["authorization", "x-api-key", "host"]
private let ordinary = [
  "content-type", "anthropic-version", "anthropic-beta", "openai-beta", "accept", "user-agent",
  "x-custom", "x-request-id", "cookie", "x-forwarded-for", "forwarded", "x-api-keys", "hosts",
  "authorization-extra", "te-x",
]
/// Nominations for `Connection`: names to remove, and lists that must be refused.
private let nominations = [
  "x-custom", "X-Custom", "host", "authorization", "x-api-key", "content-type", "keep-alive",
  "close", "anthropic-version", "cookie", "", "bad name", "a/b", "é", "x-custom;q=1",
]

private func mixedCase(_ name: String, _ rng: inout PropertyRNG) -> String {
  switch rng.below(4) {
  case 0: name.uppercased()
  case 1:
    String(
      name.enumerated().map { $0.offset % 2 == 0 ? Character($0.element.uppercased()) : $0.element }
    )
  default: name
  }
}

private func connectionValue(_ rng: inout PropertyRNG) -> String {
  (0..<rng.int(1...3)).map { _ in
    rng.element(["", " ", "\t", "  "]) + rng.element(nominations) + rng.element(["", " ", "\t"])
  }.joined(separator: ",")
}

private func generatedHeaders(_ rng: inout PropertyRNG) -> [Header] {
  (0..<rng.int(0...10)).map { _ in
    let name: String
    switch rng.below(6) {
    case 0: name = rng.element(hopByHop)
    case 1: name = rng.element(replaced)
    case 2: name = "connection"
    default: name = rng.element(ordinary + nominations.filter { !$0.isEmpty && !$0.contains(" ") })
    }
    let value =
      name == "connection"
      ? connectionValue(&rng)
      : rng.element([
        "v", "", "Bearer guest", String(repeating: "a", count: 64), "api.evil.example",
        "chunked", "x-custom", "1",
      ])
    return Header(mixedCase(name, &rng), value)
  }
}

private func isToken(_ byte: UInt8) -> Bool {
  (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte)
    || Array("!#$%&'*+-.^_`|~".utf8).contains(byte)
}

/// RFC 9110 `Connection` handling, written independently: the fixed
/// hop-by-hop set plus every nominated name is dropped, a list with an
/// empty or non-token member is refused, and every other field stays in
/// order. Names compare ASCII case-insensitively.
private func modelFiltered(_ headers: [Header]) -> [Header]? {
  var removed = Set(hopByHop)
  for header in headers where header.name.lowercased() == "connection" {
    for member in header.value.split(separator: ",", omittingEmptySubsequences: false) {
      let name = member.trimmingCharacters(in: CharacterSet(charactersIn: " \t")).lowercased()
      guard !name.isEmpty, name.utf8.allSatisfy(isToken) else { return nil }
      removed.insert(name)
    }
  }
  return headers.filter { !removed.contains($0.name.lowercased()) }
}

private struct HeaderCase: CustomStringConvertible {
  let headers: [Header]
  let configuration: Int
  var description: String {
    "configuration \(configuration): "
      + headers.map { "\($0.name): \($0.value)" }.joined(separator: " | ")
  }
}

/// Removal never lets a hop-by-hop, nominated, guest credential or guest
/// host field through; the proxy's host and credential appear exactly once
/// with their exact values, last; every other guest field keeps its order.
@Test func headerPolicyRemovesInjectsAndPreservesOrder() {
  expectHolds(
    checkProperty(
      "HeaderPolicy request and response filtering", iterations: 3000,
      generate: { rng in
        HeaderCase(headers: generatedHeaders(&rng), configuration: rng.below(configurations.count))
      },
      property: { input in
        let (provider, scheme, config) = configurations[input.configuration]
        let expected = modelFiltered(input.headers)
        let response = try? HeaderPolicy.response(input.headers)
        guard response == expected else {
          return "response kept \(response.map(String.init(describing:)) ?? "nil")"
        }
        let request = try? HeaderPolicy.request(
          input.headers, provider: provider, injection: config.injection)
        guard let expected else {
          return request == nil ? nil : "a refused Connection list still built a request"
        }
        guard let request else { return "refused a valid header list" }
        let credential =
          scheme == .xAPIKey
          ? Header("x-api-key", "upstream-\(provider.rawValue)-secret")
          : Header("authorization", "Bearer upstream-\(provider.rawValue)-secret")
        let forwarded = expected.filter { !replaced.contains($0.name.lowercased()) }
        guard request == forwarded + [Header("host", provider.hostname), credential] else {
          return "request headers \(request)"
        }
        return nil
      }))
}

/// The same headers through `UpstreamClient.request`: the wire request has
/// one host, one credential with the injected value, and no guest credential.
@Test func upstreamRequestCarriesOnlyTheInjectedCredential() {
  expectHolds(
    checkProperty(
      "UpstreamClient.request headers", iterations: 1000,
      generate: { rng in
        HeaderCase(headers: generatedHeaders(&rng), configuration: rng.below(configurations.count))
      },
      property: { input in
        let (provider, scheme, config) = configurations[input.configuration]
        let path = provider == .openai ? "/v1/responses" : "/v1/messages"
        let head = HTTPRequestHead(
          version: .http1_1, method: .POST, uri: path,
          headers: HTTPHeaders(input.headers.map { ($0.name, $0.value) }))
        guard
          let request = try? UpstreamClient.request(head: head, config: config, body: .bytes([]))
        else { return modelFiltered(input.headers) == nil ? nil : "refused valid headers" }
        let secret = "upstream-\(provider.rawValue)-secret"
        let hosts = request.headers[canonicalForm: "host"]
        let keys = request.headers[canonicalForm: "x-api-key"]
        let bearers = request.headers[canonicalForm: "authorization"]
        let ok =
          hosts == [Substring(provider.hostname)]
          && (scheme == .xAPIKey
            ? keys == [Substring(secret)] && bearers.isEmpty
            : bearers == [Substring("Bearer " + secret)] && keys.isEmpty)
          && !request.headers.contains { hopByHop.contains($0.name.lowercased()) }
        return ok ? nil : "upstream headers \(request.headers)"
      }))
}

// MARK: - Capability

private struct CapabilityCase: CustomStringConvertible {
  let token: String
  let presented: String
  let headers: [Header]
  var description: String { "token \(token) presented \(presented) headers \(headers)" }
}

private let hexDigits = Array("0123456789abcdef")

/// Near misses of `token`: case, one changed nibble, length, padding,
/// non-hex and lookalike scalars, and unrelated tokens.
private func presentation(of token: String, _ rng: inout PropertyRNG) -> String {
  var chars = Array(token)
  switch rng.below(12) {
  case 0, 1: return token
  case 2: return token.uppercased()
  case 3:
    let index = rng.below(chars.count)
    chars[index] = rng.element(hexDigits.filter { $0 != chars[index] })
    return String(chars)
  case 4: return String(chars.dropLast())
  case 5: return token + rng.element(["0", "a", " ", "\n", "\u{0}"])
  case 6: return rng.element([" ", "\t", "0"]) + token
  case 7:
    chars[rng.below(chars.count)] = rng.element(["g", "G", "\u{FF10}", "\u{0661}", "é", "%"])
    return String(chars)
  case 8: return String(token.prefix(32))
  case 9: return String((0..<64).map { _ in rng.element(hexDigits) })
  case 10: return ""
  default: return String(token.prefix(62)) + "é"
  }
}

private func capabilityCase(_ rng: inout PropertyRNG) -> CapabilityCase {
  let token = String((0..<64).map { _ in rng.element(hexDigits) })
  let headers = (0..<rng.int(0...3)).map { _ -> Header in
    let value = presentation(of: token, &rng)
    switch rng.below(3) {
    case 0:
      return Header(
        mixedCase("x-api-key", &rng), rng.oneIn(4) ? rng.element(["Bearer ", " "]) + value : value)
    default:
      return Header(
        mixedCase("authorization", &rng),
        rng.element(["Bearer ", "Bearer ", "bearer ", "Bearer  ", "Basic ", "Bearer", ""]) + value)
    }
  }
  return CapabilityCase(token: token, presented: presentation(of: token, &rng), headers: headers)
}

/// Exactly one 64-digit lowercase hex token decodes and verifies itself; a
/// request is authorized only when it presents at most one `Authorization`
/// and at most one `x-api-key`, at least one of them, and every one presented
/// is exactly `Bearer <token>` or `<token>`.
@Test func capabilityAcceptsExactlyTheIssuedToken() {
  expectHolds(
    checkProperty(
      "Capability accepts exactly its token", iterations: 3000, generate: capabilityCase
    ) { input in
      guard let capability = try? Capability(input.token) else { return "refused a valid token" }
      let wellFormed =
        input.presented.utf8.count == 64
        && input.presented.utf8.allSatisfy { hexDigits.contains(Character(Unicode.Scalar($0))) }
      if ((try? Capability(input.presented)) != nil) != wellFormed {
        return "decoding \(input.presented) disagrees with the 64-hex grammar"
      }
      let verifies = capability.verifies(input.presented)
      if verifies != (input.presented == input.token) {
        return "verifies(\(input.presented)) is \(verifies)"
      }
      let bearers = input.headers.filter { $0.name.lowercased() == "authorization" }
      let keys = input.headers.filter { $0.name.lowercased() == "x-api-key" }
      let expected =
        bearers.count <= 1 && keys.count <= 1 && !(bearers.isEmpty && keys.isEmpty)
        && bearers.allSatisfy { $0.value == "Bearer " + input.token }
        && keys.allSatisfy { $0.value == input.token }
      let authorized = capability.authorizes(input.headers)
      return authorized == expected ? nil : "authorizes is \(authorized), model \(expected)"
    })
}
