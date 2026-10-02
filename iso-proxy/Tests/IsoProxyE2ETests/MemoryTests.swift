import Foundation
import IsoProxyTestSupport
import Testing

/// Launch one Swift Testing process per workload; RSS includes only that workload's fixtures.
/// The workers stay disabled in ordinary runs. The parent validates their observations,
/// so a missing selection or skipped worker cannot masquerade as a passing resource gate.
@Suite(
  .serialized, .enabled(if: ProcessInfo.processInfo.environment["ISO_PROXY_RESOURCE_GATE"] == "1"))
struct ProxyMemoryE2ETests {
  private func worker(
    _ test: String, variables: [String: String], artifactVariable: String,
    validate: (Any) throws -> Void
  ) async throws {
    let evidence = try Evidence(test)
    let artifact = evidence.file("observations.json")
    let bundle = try activeTestBundle().deletingLastPathComponent()
      .appendingPathComponent("IsoProxyTransportTests.xctest/Contents/MacOS/IsoProxyTransportTests")
    try check(
      FileManager.default.isExecutableFile(atPath: bundle.path), "transport test bundle missing")
    // Reuse the helper from this active SwiftPM invocation, rather than invoking a nested build.
    let helper = URL(fileURLWithPath: CommandLine.arguments[0])
    try check(
      helper.lastPathComponent == "swiftpm-testing-helper",
      "resource gates require the pinned SwiftPM testing helper")
    var environment = variables
    environment[artifactVariable] = artifact.path
    // SwiftPM can supply a toolchain library search path. Forward only loader paths, never credentials.
    for key in ["DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] {
      environment[key] = ProcessInfo.processInfo.environment[key]
    }
    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
    defer { try? input.close() }
    let child = try TestProcessRunner(
      executable: helper,
      arguments: [
        "--test-bundle-path", bundle.path, "--testing-library", "swift-testing", "--filter", test,
      ],
      environment: environment, input: input.fileDescriptor, evidence: evidence, name: "worker")
    defer { child.cleanup() }
    try check(try await child.wait(seconds: 300) == 0, "memory worker failed: \(child.stderr.path)")
    let output = String(decoding: try child.output(), as: UTF8.self)
    try check(output.contains("Test \(test)() passed"), "worker did not run selected test")
    try validate(JSONSerialization.jsonObject(with: Data(contentsOf: artifact)))
  }

  @Test func responseAndUploadMatrix() async throws {
    for connections in [1, 256] {
      for upload in [false, true] {
        for offered in (upload ? [16, 64] : [256, 1024]).map({ $0 * 1024 * 1024 }) {
          try await worker(
            upload
              ? "slowProviderBoundsResidentMemoryAndGuestUploadProgress"
              : "slowGuestBoundsResidentMemoryAndUpstreamProgress",
            variables: [
              upload ? "ISO_PROXY_UPLOAD_MEMORY_GATE" : "ISO_PROXY_MEMORY_GATE": "1",
              upload ? "ISO_MEMORY_UPLOAD_BYTES" : "ISO_MEMORY_RESPONSE_BYTES": String(offered),
              "ISO_MEMORY_CONNECTIONS": String(connections),
            ], artifactVariable: "ISO_MEMORY_OBSERVATIONS"
          ) { object in
            let record = Record(try #require(object as? [String: Any]))
            try ObservationContracts.memory(
              record, offered: offered, upload: upload, connections: connections)
          }
        }
      }
    }
  }

  @Test func partialAndMalformedHeadersMatrix() async throws {
    for rounds in [2, 8] {
      try await worker(
        "concurrentPartialAndMalformedHeadersBoundResidentMemory",
        variables: ["ISO_PROXY_AGGREGATE_MEMORY_GATE": "1", "ISO_MEMORY_ROUNDS": String(rounds)],
        artifactVariable: "ISO_MEMORY_OBSERVATIONS"
      ) { object in
        try ObservationContracts.aggregateMemory(
          Record(try #require(object as? [String: Any])), rounds: rounds)
      }
    }
  }

  @Test func heldStreamsMatrix() async throws {
    try await worker(
      "heldTLSStreamsBoundAggregateResidentMemory",
      variables: ["ISO_PROXY_STREAM_MEMORY_GATE": "1"],
      artifactVariable: "ISO_STREAM_OBSERVATIONS"
    ) { try ObservationContracts.streamCapacity(decodeRecords($0), memory: true) }
  }
}
