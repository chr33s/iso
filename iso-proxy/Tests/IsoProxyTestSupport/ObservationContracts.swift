import Foundation

public enum ObservationContracts {
  public static func bodyLimit(_ records: [Record]) throws {
    let cap = 64 * 1024 * 1024
    var seen: Set<String> = []
    for record in records {
      try record.keys([
        "provider", "declared_bytes", "status", "upstream_connections", "upstream_requests",
        "upstream_body_bytes", "upstream_sha256", "upstream_closed", "guest_closed",
      ])
      let provider = try record.string("provider")
      try check(["anthropic", "openai"].contains(provider), "unexpected provider")
      let absent = record.fields["declared_bytes"] is NSNull
      let declared = absent ? 0 : try record.integer("declared_bytes")
      try check(absent || [cap, cap + 1].contains(declared), "unexpected declared body size")
      try check(seen.insert("\(provider)-\(declared)").inserted, "duplicate body case")
      let count = declared == cap ? 1 : 0
      try check(
        try record.integer("status") == (absent ? 411 : (count == 1 ? 200 : 413)), "body status")
      for field in ["upstream_connections", "upstream_requests", "upstream_closed"] {
        try check(try record.integer(field) == count, "body upstream count: \(field)")
      }
      try check(
        try record.integer("upstream_body_bytes") == (count == 1 ? cap : 0), "body byte count")
      if count == 1 {
        try check(
          try record.string("upstream_sha256")
            == "98dc891b284e4d84ac25b0c0a24fdbe39a7f0dbd643ad5e8aa06e02fc6258254",
          "body digest")
      } else {
        try check(record.fields["upstream_sha256"] is NSNull, "unexpected digest")
      }
      try check(try record.boolean("guest_closed"), "body guest EOF")
    }
    try check(seen.count == 6, "missing body boundary cases")
  }

  public static func bodyIdle(_ records: [Record]) throws {
    var seen: Set<String> = []
    for record in records {
      try record.keys([
        "provider", "status", "upstream_body", "upload_complete", "guest_closed", "upstream_closed",
        "elapsed_ms",
      ])
      let provider = try record.string("provider")
      try check(
        ["anthropic", "openai"].contains(provider) && seen.insert(provider).inserted,
        "idle provider matrix")
      try check(
        try (44000...51000).contains(record.integer("elapsed_ms")),
        "body idle deadline failed to reset")
      try check(try record.integer("status") == 408, "idle status")
      try check(try record.integers("upstream_body") == [97, 98], "idle partial upload")
      try check(try !record.boolean("upload_complete"), "idle upload completed")
      try check(try record.boolean("guest_closed") && record.boolean("upstream_closed"), "idle EOF")
    }
    try check(seen.count == 2, "missing idle provider")
  }

  public static func disconnect(_ records: [Record]) throws {
    var expected: Set<String> = []
    for provider in ["anthropic", "openai"] {
      for phase in ["beforeHeaders", "duringBody"] {
        for closure in ["abruptTCP", "cleanTLS"] {
          for round in 0..<2 { expected.insert("\(provider)-\(phase)-\(closure)-\(round)") }
        }
      }
    }
    for record in records {
      try record.keys([
        "id", "response_status", "response_body", "connection_closed", "connection_slots",
        "request_slots",
      ])
      let id = try record.string("id")
      try check(expected.remove(id) != nil, "unexpected/duplicate disconnect case")
      let before = id.contains("-beforeHeaders-")
      try check(try record.integer("response_status") == (before ? 502 : 200), "disconnect status")
      try check(try record.string("response_body") == (before ? "" : "part"), "disconnect body")
      try check(try record.boolean("connection_closed"), "disconnect guest EOF")
      for field in ["connection_slots", "request_slots"] {
        try check(try record.integer(field) == 1, "disconnect capacity recovery")
      }
    }
    try check(expected.isEmpty, "missing disconnect cases")
  }

  public static func streamCapacity(_ records: [Record], memory: Bool = false) throws {
    var seen: Set<String> = []
    var baselines: [String: Int] = [:]
    var firstPeaks: [String: Int] = [:]
    let ordered = try records.sorted {
      let left = (try $0.string("provider"), try $0.integer("round"))
      let right = (try $1.string("provider"), try $1.integer("round"))
      return left < right
    }
    for record in ordered {
      var keys: Set<String> = [
        "provider", "round", "termination", "held_responses", "upstream_requests",
        "upstream_closed",
        "excess_response_bytes", "completed_responses", "held_duration_ms",
      ]
      if memory {
        keys.formUnion([
          "baseline_rss", "rss_samples", "peak_rss", "growth_rss", "growth_after_first_round",
        ])
      }
      try record.keys(keys)
      let provider = try record.string("provider")
      let round = try record.integer("round")
      try check(["anthropic", "openai"].contains(provider) && round < 3, "stream matrix")
      try check(seen.insert("\(provider)-\(round)").inserted, "duplicate stream round")
      let complete = round == 1
      try check(
        try record.string("termination") == (complete ? "complete" : "disconnect"),
        "stream termination")
      let duration = try record.integer("held_duration_ms")
      try check(
        complete ? (31000...36000).contains(duration) : duration == 0, "stream hold duration")
      for field in ["held_responses", "upstream_requests", "upstream_closed"] {
        try check(try record.integer(field) == 256, "stream count: \(field)")
      }
      try check(try record.integer("excess_response_bytes") == 0, "excess stream admitted")
      try check(
        try record.integer("completed_responses") == (complete ? 256 : 0), "stream completion count"
      )
      if memory {
        let samples = try record.integers("rss_samples")
        try check(
          samples.count >= (complete ? 200 : 2) && samples.allSatisfy { $0 > 0 },
          "stream RSS samples")
        let baseline = try record.integer("baseline_rss")
        let peak = max(baseline, samples.max() ?? 0)
        if round == 0 {
          baselines[provider] = baseline
          firstPeaks[provider] = peak
        }
        try check(baseline > 0 && baselines[provider] == baseline, "stream RSS baseline")
        guard let first = firstPeaks[provider] else {
          throw ObservationFailure.invalid("stream rounds out of order")
        }
        try check(try record.integer("peak_rss") == peak, "stream RSS peak")
        try check(
          try record.integer("growth_rss") == peak - baseline
            && peak - baseline < 256 * 1024 * 1024, "stream RSS budget")
        try check(
          try record.integer("growth_after_first_round") == max(0, peak - first)
            && max(0, peak - first) < 64 * 1024 * 1024, "stream retained RSS budget")
      }
    }
    try check(seen.count == 6, "missing stream rounds")
  }

  public static func memory(_ record: Record, offered: Int, upload: Bool, connections: Int) throws {
    let progress = upload ? "guest_sent" : "upstream_sent"
    var keys: Set<String> = [
      "offered_bytes", "baseline_rss", "peak_rss", "growth_rss", progress, "samples", "plateau_ms",
      "upstream_closed", "producer_stopped", "connections", "per_peer_sent",
    ]
    if upload { keys.formUnion(["provider_received_while_stalled", "per_peer_received"]) }
    try record.keys(keys)
    try check(
      try record.integer("connections") == connections
        && record.integer("offered_bytes") == offered, "memory workload")
    let peers = try record.integers("per_peer_sent")
    let limit = (upload ? 8 : 16) * 1024 * 1024
    try check(
      peers.count == connections && peers.allSatisfy { $0 > 0 && $0 < limit },
      "producer per-peer progress")
    let sent = try record.integer(progress)
    try check(
      peers.reduce(0, +) == sent && sent > 0 && sent < limit * connections,
      "producer aggregate progress")
    let samples = try record.records("samples")
    try check(!samples.isEmpty, "no RSS samples")
    let baseline = try record.integer("baseline_rss")
    try check(baseline > 0, "RSS baseline")
    var previous = 0
    var peak = baseline
    for sample in samples {
      try sample.keys(["resident_bytes", progress, "plateau_ms"])
      let current = try sample.integer(progress)
      try check(current >= previous, "nonmonotonic producer progress")
      previous = current
      peak = max(peak, try sample.integer("resident_bytes"))
      _ = try sample.integer("plateau_ms")
    }
    try check(try record.integer("peak_rss") == peak, "RSS peak")
    try check(
      try record.integer("growth_rss") == peak - baseline
        && peak - baseline < (connections == 256 ? 256 : 32) * 1024 * 1024, "RSS growth budget")
    guard let last = samples.last else { throw ObservationFailure.invalid("no final RSS sample") }
    try check(try last.integer(progress) == sent, "final producer progress")
    let plateau = try record.integer("plateau_ms")
    try check(try plateau >= 3000 && last.integer("plateau_ms") == plateau, "producer plateau")
    if upload {
      let received = try record.integers("per_peer_received")
      try check(
        received.count == connections && received.allSatisfy { $0 <= 64 * 1024 },
        "stalled provider read budget")
      try check(
        try record.integer("provider_received_while_stalled") == received.reduce(0, +),
        "provider aggregate reads")
    }
    try check(
      try record.boolean("upstream_closed") && record.boolean("producer_stopped"),
      "memory producer cleanup")
  }

  public static func aggregateMemory(_ record: Record, rounds: Int) throws {
    try record.keys([
      "rounds", "connections_per_round", "partial_bytes_per_connection", "baseline_rss", "peak_rss",
      "growth_rss", "growth_after_first_round", "samples", "refusals", "excess_closed",
      "forwarded_parts",
    ])
    try check(
      try record.integer("rounds") == rounds && record.integer("connections_per_round") == 256,
      "aggregate workload")
    let bytes = try record.integer("partial_bytes_per_connection")
    try check(bytes >= 48 * 1024 && bytes < 64 * 1024, "aggregate partial bytes")
    try check(
      try record.integer("refusals") == rounds * 256 && record.integer("excess_closed") == rounds
        && record.integer("forwarded_parts") == 0, "aggregate refusal counts")
    let samples = try record.records("samples")
    try check(samples.count == rounds * 4, "aggregate RSS sample count")
    var residents: [Int] = []
    for (index, sample) in samples.enumerated() {
      try sample.keys(["round", "resident_bytes"])
      let resident = try sample.integer("resident_bytes")
      try check(try sample.integer("round") == index / 4 && resident > 0, "aggregate RSS sample")
      residents.append(resident)
    }
    let baseline = try record.integer("baseline_rss")
    let peak = max(baseline, residents.max() ?? 0)
    let first = residents.prefix(4).max() ?? 0
    try check(baseline > 0, "aggregate RSS baseline")
    try check(try record.integer("peak_rss") == peak, "aggregate RSS peak")
    try check(
      try record.integer("growth_rss") == peak - baseline && peak - baseline < 96 * 1024 * 1024,
      "aggregate RSS budget")
    try check(
      try record.integer("growth_after_first_round") == max(0, peak - first)
        && max(0, peak - first) < 32 * 1024 * 1024, "aggregate retained RSS budget")
  }
}
