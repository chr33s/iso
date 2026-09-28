import CoopFuzzHarnesses
import Foundation
import Testing

/// Replays every committed corpus and regression input through the same
/// harness bodies the libFuzzer targets use, in an ordinary Xcode build.
/// This is regression coverage, not fuzzing (section 7.1).
private let corpusRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().appending(path: "../../../fuzz/corpus").standardized

private func inputs(_ target: String) throws -> [URL] {
  let directory = corpusRoot.appending(path: target)
  return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    .filter { !$0.lastPathComponent.hasPrefix(".") }
    .sorted { $0.path < $1.path }
}

@Test(arguments: ["ParseRepoSlug", "JSONCToJSON", "ConfigLoad"])
func corpusReplays(_ target: String) throws {
  let files = try inputs(target)
  #expect(!files.isEmpty, "empty corpus for \(target)")
  for file in files {
    let bytes = Array(try Data(contentsOf: file))
    switch target {
    case "ParseRepoSlug": ParseRepoSlugHarness.run(bytes)
    case "JSONCToJSON": JSONCToJSONHarness.run(bytes)
    default: ConfigLoadHarness.run(bytes)
    }
  }
}
