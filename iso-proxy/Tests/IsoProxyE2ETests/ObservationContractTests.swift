import CoreFoundation
import Foundation
import IsoProxyTestSupport
import Testing

private enum Contract: CaseIterable, Sendable {
  case bodyLimit, bodyIdle, disconnect, capacity, streamMemory, responseMemory, uploadMemory,
    aggregateMemory

  func observations() -> [[String: Any]] {
    switch self {
    case .bodyLimit:
      let cap = 64 * 1024 * 1024
      return ["anthropic", "openai"].flatMap { provider in
        [cap, cap + 1, 0].map { declared in
          let admitted = declared == cap
          return [
            "provider": provider, "declared_bytes": declared == 0 ? NSNull() : declared,
            "status": declared == 0 ? 411 : (admitted ? 200 : 413),
            "upstream_connections": admitted ? 1 : 0, "upstream_requests": admitted ? 1 : 0,
            "upstream_body_bytes": admitted ? cap : 0,
            "upstream_sha256": admitted
              ? "98dc891b284e4d84ac25b0c0a24fdbe39a7f0dbd643ad5e8aa06e02fc6258254" : NSNull(),
            "upstream_closed": admitted ? 1 : 0, "guest_closed": true,
          ] as [String: Any]
        }
      }
    case .bodyIdle:
      return ["anthropic", "openai"].map {
        [
          "provider": $0, "status": 408, "upstream_body": [97, 98], "upload_complete": false,
          "guest_closed": true, "upstream_closed": true, "elapsed_ms": 45000,
        ]
      }
    case .disconnect:
      return ["anthropic", "openai"].flatMap { provider in
        ["beforeHeaders", "duringBody"].flatMap { phase in
          ["abruptTCP", "cleanTLS"].flatMap { transport in
            (0..<2).map { round in
              [
                "id": "\(provider)-\(phase)-\(transport)-\(round)",
                "response_status": phase == "beforeHeaders" ? 502 : 200,
                "response_body": phase == "beforeHeaders" ? "" : "part",
                "connection_closed": true, "connection_slots": 1, "request_slots": 1,
              ]
            }
          }
        }
      }
    case .capacity, .streamMemory:
      return ["anthropic", "openai"].flatMap { provider in
        (0..<3).map { round in
          let complete = round == 1
          var record: [String: Any] = [
            "provider": provider, "round": round,
            "termination": complete ? "complete" : "disconnect",
            "held_responses": 256, "upstream_requests": 256, "upstream_closed": 256,
            "excess_response_bytes": 0, "completed_responses": complete ? 256 : 0,
            "held_duration_ms": complete ? 31000 : 0,
          ]
          if self == .streamMemory {
            record.merge([
              "baseline_rss": 100, "rss_samples": Array(repeating: 200, count: complete ? 200 : 2),
              "peak_rss": 200, "growth_rss": 100, "growth_after_first_round": 0,
            ]) { _, new in new }
          }
          return record
        }
      }
    case .responseMemory, .uploadMemory:
      let upload = self == .uploadMemory
      let progress = upload ? "guest_sent" : "upstream_sent"
      var record: [String: Any] = [
        "offered_bytes": 64 * 1024 * 1024, "baseline_rss": 100, "peak_rss": 200, "growth_rss": 100,
        progress: 1000, "samples": [["resident_bytes": 200, progress: 1000, "plateau_ms": 3000]],
        "plateau_ms": 3000, "upstream_closed": true, "producer_stopped": true,
        "connections": 1, "per_peer_sent": [1000],
      ]
      if upload {
        record["provider_received_while_stalled"] = 0
        record["per_peer_received"] = [0]
      }
      return [record]
    case .aggregateMemory:
      return [
        [
          "rounds": 2, "connections_per_round": 256, "partial_bytes_per_connection": 48 * 1024,
          "baseline_rss": 100, "peak_rss": 200, "growth_rss": 100, "growth_after_first_round": 0,
          "samples": (0..<8).map { ["round": $0 / 4, "resident_bytes": 200] },
          "refusals": 512, "excess_closed": 2, "forwarded_parts": 0,
        ]
      ]
    }
  }

  func validate(_ observations: [[String: Any]]) throws {
    let data = try JSONSerialization.data(withJSONObject: observations)
    let records = try decodeRecords(JSONSerialization.jsonObject(with: data))
    switch self {
    case .bodyLimit: try ObservationContracts.bodyLimit(records)
    case .bodyIdle: try ObservationContracts.bodyIdle(records)
    case .disconnect: try ObservationContracts.disconnect(records)
    case .capacity: try ObservationContracts.streamCapacity(records)
    case .streamMemory: try ObservationContracts.streamCapacity(records, memory: true)
    case .responseMemory, .uploadMemory:
      try check(records.count == 1, "memory record count")
      try ObservationContracts.memory(
        records[0], offered: 64 * 1024 * 1024, upload: self == .uploadMemory, connections: 1)
    case .aggregateMemory:
      try check(records.count == 1, "aggregate record count")
      try ObservationContracts.aggregateMemory(records[0], rounds: 2)
    }
  }
}

/// Deliberately corrupt the evidence formerly checked by Python. These tripwires protect
/// field coverage, JSON types, EOF/counts/deadlines, sample consistency and workload matrices.
@Test(arguments: Contract.allCases)
private func observationContractsRejectDeliberateBreakages(contract: Contract) throws {
  let valid = contract.observations()
  try contract.validate(valid)
  if contract == .capacity || contract == .streamMemory { try contract.validate(valid.reversed()) }
  var mutants: [[[String: Any]]] = [Array(valid.dropLast()), valid + [valid[0]]]
  var extra = valid
  extra[0]["unexpected"] = 0
  mutants.append(extra)
  for (key, value) in valid[0] {
    var missing = valid
    missing[0].removeValue(forKey: key)
    mutants.append(missing)
    if let number = value as? NSNumber {
      var wrongType = valid
      wrongType[0][key] = CFGetTypeID(number) == CFBooleanGetTypeID() ? 1 : true
      mutants.append(wrongType)
      var changed = valid
      changed[0][key] =
        CFGetTypeID(number) == CFBooleanGetTypeID()
        ? !number.boolValue : number.intValue + 999_999_999
      mutants.append(changed)
    }
  }
  for mutant in mutants { #expect(throws: (any Error).self) { try contract.validate(mutant) } }
}

@Test private func forwardingRejectsIncompleteAndDuplicateCorpusEvidence() throws {
  let corpus = Data(
    """
    [{"id":"one","provider":"anthropic","scheme":"x_api_key","path":"/v1/messages",
      "response_date":"date","response_status":200,"request_body":"hi","response_body":"ok"}]
    """.utf8)
  let valid: [String: Any] = [
    "id": "one", "upstream_count": 1, "response_status": 200, "connection_closed": true,
    "method": "POST", "path": "/v1/messages",
    "request_headers": [
      ["host", "api.anthropic.com"], ["x-api-key", "test-credential"], ["content-length", "2"],
    ],
    "response_headers": [
      ["date", "date"], ["location", "https://unreached.invalid/redirect"],
      ["content-encoding", "gzip"], ["set-cookie", "a=1"], ["set-cookie", "b=2"],
      ["content-length", "2"], ["connection", "close"],
    ], "request_body": [104, 105],
    "response_body": [111, 107],
  ]
  func validate(_ records: [[String: Any]], _ data: Data = corpus) throws {
    try ObservationContracts.forwarding(
      decodeRecords(
        JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: records))),
      corpus: data)
  }
  try validate([valid])
  var reordered = valid
  for field in ["request_headers", "response_headers"] {
    reordered[field] = try #require(valid[field] as? [[String]]).reversed().map {
      [$0[0].uppercased(), $0[1]]
    }
  }
  try validate([reordered])
  for field in ["request_headers", "response_headers"] {
    let headers = try #require(valid[field] as? [[String]])
    var dropped = valid
    dropped[field] = Array(headers.dropLast())
    #expect(throws: (any Error).self) { try validate([dropped]) }
    var duplicated = valid
    duplicated[field] = headers + [headers[0]]
    #expect(throws: (any Error).self) { try validate([duplicated]) }
  }
  #expect(throws: (any Error).self) { try validate([]) }
  #expect(throws: (any Error).self) { try validate([valid, valid]) }
  #expect(throws: (any Error).self) { try validate([valid], Data("[]".utf8)) }
  for (key, _) in valid {
    var missing = valid
    missing.removeValue(forKey: key)
    #expect(throws: (any Error).self) { try validate([missing]) }
  }
  for (key, value) in [
    ("response_status", 502 as Any), ("connection_closed", false), ("request_body", [0]),
    ("response_body", [0]), ("upstream_count", true), ("unexpected", 1),
  ] {
    var mutant = valid
    mutant[key] = value
    #expect(throws: (any Error).self) { try validate([mutant]) }
  }
}

@Test private func integerSchemaDoesNotAcceptBooleansOrFloatingPoint() throws {
  for value in [NSNumber(value: true), NSNumber(value: 1.0), NSNumber(value: -1)] {
    #expect(throws: (any Error).self) { try Record(["value": value]).integer("value") }
  }
  #expect(try Record(["value": NSNumber(value: 1)]).integer("value") == 1)
}
