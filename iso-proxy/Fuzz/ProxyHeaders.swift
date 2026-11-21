import Foundation
import IsoProxyCore

/// `HeaderPolicy` on guest request headers and upstream response headers:
/// hop-by-hop and `Connection`-named fields go, the guest's credential and
/// host never pass, and exactly one injected credential and host are added.
public enum ProxyHeadersHarness {
  static let secret = "fuzz-injected-credential"
  static let hopByHop: Set<String> = [
    "connection", "proxy-connection", "keep-alive", "transfer-encoding", "te", "trailer",
    "upgrade", "proxy-authenticate", "proxy-authorization",
  ]

  public static func run(_ bytes: [UInt8]) {
    let headers = headerLines(bytes).map { Header($0.0, $0.1) }
    let nominated = Set(
      headers.filter { $0.name.lowercased() == "connection" }.flatMap {
        $0.value.split(separator: ",", omittingEmptySubsequences: false).map {
          $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
      })
    let removed = hopByHop.union(nominated)
    guard let response = try? HeaderPolicy.response(headers) else {
      require(!nominated.isEmpty, "only a bad Connection list is refused")
      return
    }
    require(
      response == headers.filter { !removed.contains($0.name.lowercased()) },
      "response keeps every other field in order")
    for (provider, scheme) in [(Provider.anthropic, Injection.Scheme.xAPIKey), (.openai, .bearer)] {
      guard
        let injection = try? Injection(
          scheme: scheme, credential: Secret(secret), provider: provider),
        let request = try? HeaderPolicy.request(headers, provider: provider, injection: injection)
      else {
        require(false, "a valid response list is a valid request list")
        return
      }
      let credential = scheme == .xAPIKey ? "x-api-key" : "authorization"
      let value = scheme == .xAPIKey ? secret : "Bearer " + secret
      let names = request.map { $0.name.lowercased() }
      require(names.filter { $0 == "host" }.count == 1, "one host")
      require(request.contains(Header("host", provider.hostname)), "provider host")
      require(
        names.filter { $0 == "x-api-key" || $0 == "authorization" }.count == 1, "one credential")
      require(request.last == Header(credential, value), "injected credential last")
      // The proxy's own host and credential are added after filtering, even
      // when the guest names them in `Connection`.
      require(
        names.dropLast(2).allSatisfy { !removed.contains($0) }, "no hop-by-hop field forwarded")
      require(
        Array(request.dropLast(2))
          == response.filter {
            !["authorization", "x-api-key", "host"].contains($0.name.lowercased())
          }, "guest fields forwarded in order")
    }
  }
}
