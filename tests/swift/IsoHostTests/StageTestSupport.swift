import Foundation
import IsoConfiguration
import IsoCore

@testable import IsoHost

/// Builds and selects a stage the way a receive does: a fresh incoming
/// attempt is populated by `populate` (standing in for the receiver),
/// proven quiescent, validated against `destination`, and promoted.
@discardableResult
func makeSelectedStage(
  _ location: StageLocation, destination: String, instance: String = "test",
  policy: StagePolicyBinding? = nil, limits: StageLimits = .defaults,
  populate: (String) throws -> Void
) throws -> SelectedStage {
  let lock = try location.lock()
  defer { lock.release() }
  let attempt = try ReceiveAttempt(location)
  try populate(attempt.tree)
  guard let hold = try attempt.awaitQuiescence(timeout: .seconds(5)) else {
    throw HostError("test stage writer did not finish")
  }
  _ = hold
  let resolved = try ReturnDestination.resolve(destination, controlRoots: [])
  var builder = StageBuilder(
    tree: attempt.tree, destination: StageDestinationView(resolved, try resolved.open()),
    limits: limits)
  let manifest = try builder.build(id: attempt.id, instance: instance, policy: policy)
  try location.promote(attempt, manifest: manifest)
  return try location.loadSelected()
}

/// Writes `files` (relative path to text) below `root`.
func populate(_ root: String, _ files: [String: String]) throws {
  for (name, text) in files {
    let path = root + "/" + name
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }
}
