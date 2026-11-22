import Foundation
import IsoInferenceCore
import IsoProxyCore

/// A request line (`METHOD target`) and header lines (`name:value`) through
/// the production route table and header table. An accepted head names one
/// exact route and carries no framing, browser or upgrade header, at most
/// one Content-Type, and a JSON one whenever the route takes a body.
public enum InferenceHeadersHarness {
  static let refused: Set<String> = [
    "origin", "transfer-encoding", "upgrade", "te", "trailer", "http2-settings",
  ]

  public static func run(_ bytes: [UInt8]) {
    let lines = String(decoding: bytes, as: UTF8.self).split(
      separator: "\n", omittingEmptySubsequences: false)
    guard let requestLine = lines.first else { return }
    let parts = requestLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2 else { return }
    let method = String(parts[0])
    let target = String(parts[1])
    if let api = FrontendAPI.route(method: method, target: target) {
      let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
      require(String(path[0]) == api.path && method == api.method, "a route is exact")
      require(
        path.count == 1 || api.allowedQueries.contains(String(path[1])), "only listed queries")
    }
    let headers = headerLines(Array(lines.dropFirst().joined(separator: "\n").utf8)).map {
      Header($0.0, $0.1)
    }
    let hasBody = method == "POST"
    guard (try? HeaderTable.check(headers, hasBody: hasBody)) != nil else { return }
    let names = headers.map { $0.name.lowercased() }
    require(names.allSatisfy { !refused.contains($0) }, "framing and browser headers fail")
    let types = headers.filter { $0.name.lowercased() == "content-type" }
    require(types.count <= 1, "at most one Content-Type")
    if hasBody || !types.isEmpty {
      require(types.count == 1 || !hasBody, "a body needs a Content-Type")
      for header in types {
        let media = header.value.prefix { $0 != ";" }.lowercased()
          .trimmingCharacters(in: [" ", "\t"])
        require(media == "application/json", "the Content-Type is JSON")
      }
    }
  }
}
