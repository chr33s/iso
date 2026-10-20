import Foundation

/// The published local-preflight compatibility manifest (spec section 9). It
/// binds the runner/image identity, the accepted syntax features, the
/// approved actions with their runtimes and supported inputs, the endpoint
/// profile, and the protocol fixtures that exercise each feature.
///
/// A manifest is a qualification claim only when every fixture it names
/// passes against the bound runner and image; until then it is a declared
/// subset that the compiler enforces, not evidence of parity. Workflows
/// using anything outside it are rejected before allocation.
package struct CompatibilityManifest: Sendable, Equatable, Codable {
  package struct RunnerBinding: Sendable, Equatable, Codable {
    package let minimumVersion: String
    package let maximumVersion: String
    /// The approved image descriptor name this manifest was qualified with.
    package let imageIdentity: String
    package let platform: String
  }

  package enum ActionKind: String, Sendable, Codable {
    case javascript
    case composite
    /// Approved checkout: replaced by visible synthetic checkout + overlay.
    case checkoutReplacement = "checkout-replacement"
  }

  package struct ApprovedAction: Sendable, Equatable, Codable {
    package let nameWithOwner: String
    /// Major version tag accepted (`v4` and `v4.x.y`); a full commit SHA is
    /// accepted too but delivery requires an imported archive of that commit.
    package let majorVersion: String
    package let kind: ActionKind
    /// `node20`, `node24` or `composite`.
    package let runtime: String
    package let inputs: [String]
    /// Inputs whose presence is outside the subset (rejected when set).
    package let rejectedInputs: [String]
    package let fixtures: [String]
  }

  package let id: String
  package let runner: RunnerBinding
  package let features: [String]
  package let actions: [ApprovedAction]
  package let allowsLocalActions: Bool
  package let allowsDockerActions: Bool
  package let allowsJobContainers: Bool
  package let allowsServiceContainers: Bool
  package let fixtures: [String]
  package let endpointProfile: String

  package var digest: Digest { descriptorDigest(self) }

  package func approvedAction(_ nameWithOwner: String) -> ApprovedAction? {
    actions.first { $0.nameWithOwner.lowercased() == nameWithOwner.lowercased() }
  }

  /// Whether `ref` is acceptable for `action`: the major tag, a semver tag
  /// within it, or a full 40-hex commit.
  package static func refAccepted(_ ref: String, for action: ApprovedAction) -> Bool {
    if ref == action.majorVersion || ref.hasPrefix(action.majorVersion + ".") {
      let rest = ref.dropFirst(action.majorVersion.count)
      return rest.isEmpty
        || rest.dropFirst().split(separator: ".").allSatisfy {
          $0.allSatisfy(\.isNumber) && !$0.isEmpty
        }
    }
    return ref.utf8.count == 40 && Array(ref.utf8).allSatisfy(isLowerHex)
  }

  package static func builtin(_ id: String) throws(CIError) -> CompatibilityManifest {
    switch id {
    case "local-actions/v1": return localActionsV1
    default:
      throw CIError(
        .compatibilityRejected, "unknown compatibility manifest \(String(id.prefix(64)))")
    }
  }

  package static let localActionsV1 = CompatibilityManifest(
    id: "local-actions/v1",
    runner: RunnerBinding(
      minimumVersion: "2.328.0", maximumVersion: "2.329.0",
      imageIdentity: "approved-linux-arm64-runner", platform: "linux/arm64"),
    features: [
      "continue-on-error", "defaults.run", "env", "if", "job.container", "job.outputs",
      "job.services", "needs", "run", "shell", "strategy.matrix.static", "timeout-minutes",
      "uses.composite", "uses.docker", "uses.javascript", "uses.local", "working-directory",
      "workflow_dispatch.inputs",
    ],
    actions: [
      ApprovedAction(
        nameWithOwner: "actions/checkout", majorVersion: "v4", kind: .checkoutReplacement,
        runtime: "node20",
        inputs: [
          "path", "fetch-depth", "fetch-tags", "clean", "persist-credentials",
          "set-safe-directory", "show-progress", "repository", "ref", "lfs", "submodules",
        ],
        rejectedInputs: [
          "token", "ssh-key", "ssh-known-hosts", "ssh-strict", "ssh-user", "sparse-checkout",
          "sparse-checkout-cone-mode", "filter", "github-server-url",
        ],
        fixtures: ["synthetic-checkout", "snapshot-overlay"]),
      ApprovedAction(
        nameWithOwner: "actions/cache", majorVersion: "v4", kind: .javascript, runtime: "node20",
        inputs: [
          "path", "key", "restore-keys", "upload-chunk-size", "enableCrossOsArchive",
          "fail-on-cache-miss", "lookup-only", "save-always",
        ],
        rejectedInputs: [], fixtures: ["cache-v1"]),
      ApprovedAction(
        nameWithOwner: "actions/upload-artifact", majorVersion: "v4", kind: .javascript,
        runtime: "node20",
        inputs: [
          "name", "path", "if-no-files-found", "retention-days", "compression-level", "overwrite",
          "include-hidden-files",
        ],
        rejectedInputs: [], fixtures: ["artifact-v4-twirp"]),
      ApprovedAction(
        nameWithOwner: "actions/download-artifact", majorVersion: "v4", kind: .javascript,
        runtime: "node20",
        inputs: [
          "name", "path", "pattern", "merge-multiple", "run-id", "github-token", "repository",
        ],
        rejectedInputs: ["run-id", "github-token", "repository"],
        fixtures: ["artifact-v4-twirp"]),
    ],
    allowsLocalActions: true, allowsDockerActions: true, allowsJobContainers: true,
    allowsServiceContainers: true,
    fixtures: [
      "runner-v1-job", "runner-v1-timeline-logs", "action-download", "cache-v1",
      "artifact-v4-twirp", "synthetic-checkout", "snapshot-overlay", "job-container",
      "service-container", "container-action",
    ],
    endpointProfile: "approved-preflight-egress-and-service")
}
