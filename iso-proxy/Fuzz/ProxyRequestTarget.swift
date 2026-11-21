import Foundation
import IsoProxyCore

/// `RequestTarget` and `OperationPolicy` on guest request targets. The guest
/// chooses the path and query; it must never choose the upstream host.
public enum ProxyRequestTargetHarness {
  public static func run(_ bytes: [UInt8]) {
    let text = String(decoding: bytes, as: UTF8.self)
    guard let target = try? RequestTarget(text) else { return }
    let raw = Array(target.raw.utf8)
    require(target.raw == text, "target kept verbatim")
    require(raw.first == 0x2F && !target.raw.hasPrefix("//"), "origin form only")
    require(raw.allSatisfy { $0 > 32 && $0 < 127 && $0 != 0x23 && $0 != 0x5C }, "visible ASCII")
    require(!target.path.contains("?") && target.raw.hasPrefix(target.path), "path precedes query")
    for (index, byte) in raw.enumerated() where byte == 0x25 {
      require(index + 2 < raw.count, "complete percent escape")
    }
    for provider in Provider.allCases {
      guard OperationPolicy.allows(method: "POST", target: target, provider: provider) else {
        continue
      }
      require(
        ["/v1/messages", "/v1/messages/count_tokens", "/v1/responses"].contains(target.path),
        "only the documented operations")
      // The same Foundation parse `UpstreamClient.request` and
      // `OwnedHTTPRequest` apply: the host stays fixed and the path exact.
      guard let url = URL(string: "https://" + provider.hostname + target.raw),
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
      else { continue }
      require(url.host == provider.hostname, "upstream host is fixed")
      require(parts.percentEncodedPath == target.path, "forwarded path is the authorized path")
      let uri = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
      require(uri.utf8.allSatisfy { $0 > 32 && $0 < 127 }, "request line stays one token")
    }
  }
}
