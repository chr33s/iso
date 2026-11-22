import Foundation
import IsoInferenceCore
import IsoProxyFuzzHarnesses
import Testing

/// Replays the committed corpus through the same harness bodies the
/// libFuzzer targets use, in an ordinary build. Regression coverage, not fuzzing.
private let corpusRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().appending(path: "../../../fuzz/corpus").standardized

private func corpus(_ target: String) throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: corpusRoot.appending(path: target), includingPropertiesForKeys: nil
  )
  .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
}

@Test(arguments: [
  "ProxyRequestTarget", "ProxyHeaders", "ProxyCapability", "InferenceRequest", "InferenceControl",
  "InferenceHeaders",
])
func corpusReplays(_ target: String) throws {
  let files = try corpus(target)
  #expect(!files.isEmpty, "empty corpus for \(target)")
  for file in files {
    let bytes = Array(try Data(contentsOf: file))
    switch target {
    case "ProxyRequestTarget": ProxyRequestTargetHarness.run(bytes)
    case "ProxyHeaders": ProxyHeadersHarness.run(bytes)
    case "ProxyCapability": ProxyCapabilityHarness.run(bytes)
    case "InferenceRequest": InferenceRequestHarness.run(bytes)
    case "InferenceControl": InferenceControlHarness.run(bytes)
    case "InferenceHeaders": InferenceHeadersHarness.run(bytes)
    default: Issue.record("unknown target \(target)")
    }
  }
}

/// Each stream seed is named for its protocol (`chat`, `responses` or
/// `messages`, as a prefix) and must reach that translator and be relayed
/// by it, so a seed cannot silently exercise nothing.
@Test func streamSeedsReachTheirTranslator() throws {
  let expected: [(String, FrontendAPI)] = [
    ("chat", .openAIChat), ("responses", .openAIResponses), ("messages", .anthropicMessages),
  ]
  let files = try corpus("InferenceStream")
  #expect(!files.isEmpty)
  for file in files {
    let name = file.lastPathComponent
    let api = try #require(expected.first { name.hasPrefix($0.0) }?.1, "seed \(name) names no API")
    let outcome = InferenceStreamHarness.run(Array(try Data(contentsOf: file)))
    #expect(outcome.api == api, "\(name)")
    #expect(outcome.relayed >= 1, "\(name)")
  }
}
