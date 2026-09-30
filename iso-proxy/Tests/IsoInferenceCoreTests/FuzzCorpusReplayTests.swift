import Foundation
import IsoInferenceFuzz
import Testing

/// Replays the committed inference corpora (fuzz/corpus/Inference*) through
/// the same harness bodies scripts/fuzz.sh links into libFuzzer targets.
/// Regression coverage in ordinary builds, not fuzzing.
private let corpusRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().appending(path: "../../../fuzz/corpus").standardized

@Test(arguments: ["InferenceRequest", "InferenceStream", "InferenceControl"])
func inferenceCorpusReplays(_ target: String) throws {
  let files = try FileManager.default.contentsOfDirectory(
    at: corpusRoot.appending(path: target), includingPropertiesForKeys: nil
  )
  .filter { !$0.lastPathComponent.hasPrefix(".") }
  #expect(!files.isEmpty, "empty corpus for \(target)")
  for file in files.sorted(by: { $0.path < $1.path }) {
    let bytes = Array(try Data(contentsOf: file))
    switch target {
    case "InferenceRequest": InferenceRequestHarness.run(bytes)
    case "InferenceStream": InferenceStreamHarness.run(bytes)
    default: InferenceControlHarness.run(bytes)
    }
  }
}
