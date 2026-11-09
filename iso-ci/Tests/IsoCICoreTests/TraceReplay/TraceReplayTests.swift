import Foundation
import Testing

@testable import IsoCICore

/// Qualification cases C-T19–C-T24 as deterministic protocol traces
/// (`Fixtures/traces/*.jsonl`) replayed against the scheduler, the
/// scale-set listener and job policy, and the pool reconcilers.
@Suite struct TraceReplayTests {
  static func fixture(_ name: String) throws -> String {
    let url = try #require(
      Bundle.module.resourceURL?.appending(path: "Fixtures/traces/\(name).jsonl"))
    return try String(contentsOf: url, encoding: .utf8)
  }

  @Test(arguments: [
    "C-T19-scale-to-zero", "C-T20-fork-rejection", "C-T21-room-reservation",
    "C-T22-exclusive-drain", "C-T23-vz-ceiling", "C-T24-restart-readoption",
  ])
  func qualificationTrace(_ name: String) throws {
    try TraceReplayer().replay(try Self.fixture(name))
  }

  /// `--record-protocol-trace` output: the records a replay needs, and no
  /// token, queue URL or JIT material.
  @Test func recordedTracesCarryNoSecrets() throws {
    let path = scratchDirectory("trace") + ".jsonl"
    let trace = try ProtocolTrace(path: path)
    try TraceReplayer(trace: trace).replay(try Self.fixture("C-T19-scale-to-zero"))
    let text = try String(contentsOfFile: path, encoding: .utf8)
    for record in [
      "scaleset_session", "scaleset_message", "scaleset_acquired", "schedule", "allocation_created",
    ] {
      #expect(text.contains("\"type\":\"\(record)\""), "missing \(record)")
    }
    for secret in ["ADMIN-TOKEN", "QUEUE-TOKEN", "JIT-SECRET", "message/q1", "Bearer"] {
      #expect(!text.contains(secret), "trace leaks \(secret)")
    }
    for line in text.split(separator: "\n") {
      _ = try StrictJSON.parse(Array(line.utf8), limits: .github)
    }
    var status = stat()
    #expect(stat(path, &status) == 0 && status.st_mode & 0o077 == 0)
  }
}
