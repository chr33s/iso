import Foundation
import IsoProxyFuzzHarnesses
import Testing

/// Replays the committed corpus through the same harness bodies the
/// libFuzzer targets use, in an ordinary build. Regression coverage, not fuzzing.
private let corpusRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().appending(path: "../../../fuzz/corpus").standardized

@Test(arguments: ["ProxyRequestTarget", "ProxyHeaders", "ProxyCapability"])
func corpusReplays(_ target: String) throws {
  let files = try FileManager.default.contentsOfDirectory(
    at: corpusRoot.appending(path: target), includingPropertiesForKeys: nil
  )
  .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.path < $1.path }
  #expect(!files.isEmpty, "empty corpus for \(target)")
  for file in files {
    let bytes = Array(try Data(contentsOf: file))
    switch target {
    case "ProxyRequestTarget": ProxyRequestTargetHarness.run(bytes)
    case "ProxyHeaders": ProxyHeadersHarness.run(bytes)
    case "ProxyCapability": ProxyCapabilityHarness.run(bytes)
    default: Issue.record("unknown target \(target)")
    }
  }
}
