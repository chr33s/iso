import Foundation

extension ObservationContracts {
  public static func forwardingCases(_ corpus: Data) throws -> [String: Record] {
    let cases = try decodeRecords(JSONSerialization.jsonObject(with: corpus))
    try check(!cases.isEmpty, "empty forwarding corpus")
    var byID: [String: Record] = [:]
    let required: Set<String> = [
      "id", "provider", "scheme", "path", "response_date", "response_status", "request_body",
      "response_body",
    ]
    let optional: Set<String> = [
      "certificate", "trust_anchor", "establishment_failure", "stall_handshake", "dns_failure",
      "minimum_elapsed_ms", "maximum_elapsed_ms",
    ]
    for item in cases {
      let keys = Set(item.fields.keys)
      try check(
        required.isSubset(of: keys) && keys.isSubset(of: required.union(optional)),
        "forwarding corpus schema")
      let id = try item.string("id")
      try check(
        !id.isEmpty && byID.updateValue(item, forKey: id) == nil, "duplicate/empty corpus ID")
      for key in required.subtracting(["response_status"]) { _ = try item.string(key) }
      _ = try item.integer("response_status")
      for key in ["trust_anchor", "establishment_failure", "stall_handshake", "dns_failure"]
      where keys.contains(key) {
        _ = try item.boolean(key)
      }
      if keys.contains("certificate") { _ = try item.string("certificate") }
      for key in ["minimum_elapsed_ms", "maximum_elapsed_ms"] where keys.contains(key) {
        _ = try item.integer(key)
      }
      if item.fields["stall_handshake"] as? Bool == true {
        try check(
          try item.integer("minimum_elapsed_ms") <= item.integer("maximum_elapsed_ms"),
          "handshake deadline bounds")
      }
    }
    return byID
  }

  public static func forwarding(_ records: [Record], corpus: Data) throws {
    var byID = try forwardingCases(corpus)
    for record in records {
      let id = try record.string("id")
      guard let item = byID.removeValue(forKey: id) else {
        throw ObservationFailure.invalid("unknown/duplicate observation ID")
      }
      let failed = item.fields["establishment_failure"] as? Bool == true
      var keys: Set<String> = ["id", "upstream_count", "response_status", "connection_closed"]
      if !failed {
        keys.formUnion([
          "method", "path", "request_headers", "request_body", "response_headers", "response_body",
        ])
      }
      let stalled = item.fields["stall_handshake"] as? Bool == true
      if stalled { keys.formUnion(["elapsed_ms", "upstream_closed"]) }
      try record.keys(keys)
      try check(
        try record.integer("upstream_count") == (failed ? 0 : 1), "forwarding upstream count")
      try check(
        try record.integer("response_status") == (failed ? 502 : item.integer("response_status")),
        "forwarding response status")
      try check(try record.boolean("connection_closed"), "forwarding EOF")
      if !failed {
        try check(
          try record.string("method") == "POST" && record.string("path") == item.string("path"),
          "forwarding request target")
        for key in ["request_body", "response_body"] {
          try check(
            try record.integers(key) == Array(item.string(key).utf8).map(Int.init),
            "forwarding body bytes")
        }
        func headers(_ key: String) throws -> [[String]] {
          guard let pairs = record.fields[key] as? [[String]], pairs.allSatisfy({ $0.count == 2 })
          else {
            throw ObservationFailure.invalid("invalid header pairs")
          }
          return pairs.map { [$0[0].lowercased(), $0[1]] }.sorted {
            $0.lexicographicallyPrecedes($1)
          }
        }
        let scheme = try item.string("scheme")
        let credential =
          scheme == "bearer"
          ? ["authorization", "Bearer test-credential"] : ["x-api-key", "test-credential"]
        let requestHeaders = [
          ["host", "api.\(try item.string("provider")).com"], credential,
          ["content-length", String(try item.string("request_body").utf8.count)],
        ].sorted { $0.lexicographicallyPrecedes($1) }
        let responseHeaders = [
          ["date", try item.string("response_date")],
          ["location", "https://unreached.invalid/redirect"], ["content-encoding", "gzip"],
          ["set-cookie", "a=1"], ["set-cookie", "b=2"],
          ["content-length", String(try item.string("response_body").utf8.count)],
          ["connection", "close"],
        ].sorted { $0.lexicographicallyPrecedes($1) }
        try check(try headers("request_headers") == requestHeaders, "forwarding request headers")
        try check(try headers("response_headers") == responseHeaders, "forwarding response headers")
      }
      if stalled {
        let elapsed = try record.integer("elapsed_ms")
        try check(
          try elapsed >= item.integer("minimum_elapsed_ms")
            && elapsed <= item.integer("maximum_elapsed_ms"), "TLS handshake deadline")
        try check(try record.boolean("upstream_closed"), "TLS handshake cleanup")
      }
    }
    try check(byID.isEmpty, "missing forwarding observations")
  }
}

/// Also used without wrapper environment variables so ordinary swift test enforces the schema.
public func recordEvidence(
  _ records: [[String: Any]], name: String, validate: ([Record]) throws -> Void
) throws {
  let evidence = try Evidence(name)
  let data = try JSONSerialization.data(
    withJSONObject: records, options: [.sortedKeys, .prettyPrinted])
  try data.write(to: evidence.file("observations.json"), options: .atomic)
  try validate(decodeRecords(JSONSerialization.jsonObject(with: data)))
}
