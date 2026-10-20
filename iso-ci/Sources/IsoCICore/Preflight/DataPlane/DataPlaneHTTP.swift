import Foundation

/// A transport-neutral HTTP request as the endpoint sees it.
package struct DataPlaneRequest: Sendable, Equatable {
  package let method: String
  /// Percent-decoded path, without the query.
  package let path: String
  /// Percent-decoded query parameters (first value wins).
  package let query: [String: String]
  /// Lowercased header names (last value wins).
  package let headers: [String: String]
  package let body: [UInt8]
  /// The allocation whose own socket carried this request; every credential
  /// presented on it must belong to that allocation. Nil only for the
  /// in-process endpoint used by tests.
  package var boundAllocation: AllocationID?

  package init(
    method: String, target: String, headers: [String: String] = [:], body: [UInt8] = []
  ) {
    self.method = method.uppercased()
    let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    path = Self.decode(String(parts.first ?? ""), plusIsSpace: false) ?? "/"
    var query: [String: String] = [:]
    if parts.count == 2 {
      for pair in parts[1].split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let key = Self.decode(String(kv[0]), plusIsSpace: true), query[key] == nil else {
          continue
        }
        query[key] = kv.count == 2 ? Self.decode(String(kv[1]), plusIsSpace: true) ?? "" : ""
      }
    }
    self.query = query
    var lowered: [String: String] = [:]
    for (name, value) in headers { lowered[name.lowercased()] = value }
    self.headers = lowered
    self.body = body
  }

  package static func decode(_ text: String, plusIsSpace: Bool) -> String? {
    let source = plusIsSpace ? text.replacingOccurrences(of: "+", with: " ") : text
    return source.removingPercentEncoding
  }

  /// `application/x-www-form-urlencoded` body fields.
  package var formFields: [String: String] {
    var fields: [String: String] = [:]
    let text = String(decoding: body, as: UTF8.self)
    for pair in text.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let key = Self.decode(String(kv[0]), plusIsSpace: true), fields[key] == nil else {
        continue
      }
      fields[key] = kv.count == 2 ? Self.decode(String(kv[1]), plusIsSpace: true) ?? "" : ""
    }
    return fields
  }

  package var bearer: String? {
    guard let value = headers["authorization"], value.lowercased().hasPrefix("bearer ") else {
      return nil
    }
    return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
  }

  /// The password of `Authorization: Basic x-access-token:<token>`.
  package var basicAccessToken: String? {
    guard let value = headers["authorization"], value.lowercased().hasPrefix("basic "),
      let decoded = Data(
        base64Encoded: String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
      let text = String(data: decoded, encoding: .utf8), text.hasPrefix("x-access-token:")
    else { return nil }
    return String(text.dropFirst("x-access-token:".count))
  }
}

package struct DataPlaneResponse: Sendable, Equatable {
  package enum Body: Sendable, Equatable {
    case bytes([UInt8])
    /// A private file the server opens, unlinks and streams.
    case file(path: String, offset: UInt64, length: UInt64)
  }

  package var status: Int
  package var headers: [(String, String)]
  package var body: Body

  package init(status: Int, headers: [(String, String)] = [], body: Body = .bytes([])) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  package static func == (a: DataPlaneResponse, b: DataPlaneResponse) -> Bool {
    a.status == b.status && a.body == b.body
      && a.headers.map { $0.0 + ":" + $0.1 } == b.headers.map { $0.0 + ":" + $0.1 }
  }

  package var bodyLength: UInt64 {
    switch body {
    case .bytes(let bytes): UInt64(bytes.count)
    case .file(_, _, let length): length
    }
  }

  package var bodyBytes: [UInt8] {
    if case .bytes(let bytes) = body { return bytes }
    return []
  }

  package var json: JSONValue? {
    try? StrictJSON.parse(bodyBytes, limits: JSONLimits(maxBytes: 64 << 20, maxKeys: 1 << 20))
  }

  package static func json(_ status: Int, _ value: JSONValue) -> DataPlaneResponse {
    DataPlaneResponse(
      status: status, headers: [("Content-Type", "application/json; charset=utf-8")],
      body: .bytes(value.canonical))
  }

  package static func empty(_ status: Int) -> DataPlaneResponse {
    DataPlaneResponse(status: status)
  }

  /// A bounded error body that never echoes request bytes.
  package static func error(_ status: Int, _ message: String) -> DataPlaneResponse {
    json(status, ["message": .string(CIError.bounded(message))])
  }

  /// Twirp error body (`{"code","msg"}`).
  package static func twirp(_ status: Int, _ code: String, _ message: String) -> DataPlaneResponse {
    json(status, ["code": .string(code), "msg": .string(CIError.bounded(message))])
  }
}
