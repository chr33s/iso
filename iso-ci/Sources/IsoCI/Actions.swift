import ArgumentParser
import Foundation
import IsoCICore

struct Actions: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Approved action archives for local preflight",
    subcommands: [ActionsImport.self, ActionsList.self])
}

/// Fetches one approved action's archive from GitHub on the host (an
/// explicit operator action), pins the resolved commit and archive digest,
/// and stores it for delivery to preflight jobs through the data plane.
/// Guests never fetch actions themselves.
struct ActionsImport: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "import", abstract: "Fetch, pin and store an approved action (OWNER/REPO@REF)")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "An action the compatibility manifest approves, e.g. actions/cache@v4")
  var action: String

  func run() throws {
    try global.run { () throws(CIError) in
      let parts = action.split(separator: "@", maxSplits: 1).map(String.init)
      guard parts.count == 2, let repository = try? RepositoryName(parts[0]),
        (1...100).contains(parts[1].utf8.count),
        parts[1].unicodeScalars.allSatisfy({ isSafeNameScalar($0) || $0 == "/" }),
        !parts[1].contains("..")
      else { throw CIError.invalid("expected OWNER/REPO@REF") }
      let manifest = try CompatibilityManifest.builtin("local-actions/v1")
      guard manifest.actions.contains(where: { $0.nameWithOwner == repository.rawValue }) else {
        throw CIError(.compatibilityRejected, "\(repository) is not approved by \(manifest.id)")
      }
      let api = GitHubAPI(http: URLSessionGitHubHTTP())
      let commit = try api.resolveCommit(repository: repository, ref: parts[1])
      let archive = try api.downloadArchive(repository: repository, commit: commit, limit: 64 << 20)
      let runtime = try Runtime.open(
        root: global.dataRoot, iso: global.iso, isoConfig: global.isoConfig,
        environment: ProcessInfo.processInfo.environment)
      let digest = try runtime.objects.importBytes(archive, kind: .actionArchive)
      let resolved = ResolvedAction(
        nameWithOwner: repository.rawValue, ref: parts[1], commit: commit, archiveDigest: digest)
      try ApprovedActions.save(resolved, store: runtime.store)
      try runtime.store.event(
        "actions", "action.imported", "\(repository)@\(parts[1]) -> \(commit)",
        data: ["digest": digest.rawValue])
      Output.emit(jsonValue(resolved), json: global.json) { _ in
        Output.line("Imported \(repository)@\(parts[1]) at \(commit) (sha256:\(digest.short))")
      }
    }
  }
}

struct ActionsList: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List the manifest's approved actions")
  @OptionGroup var global: GlobalOptions

  func run() throws {
    try global.run { () throws(CIError) in
      let manifest = try CompatibilityManifest.builtin("local-actions/v1")
      let value = JSONValue.array(manifest.actions.map { jsonValue($0) })
      Output.emit(value, json: global.json) { _ in
        for action in manifest.actions {
          Output.line(
            "\(action.nameWithOwner)@\(action.majorVersion) (\(action.kind.rawValue), \(action.runtime))"
          )
        }
      }
    }
  }
}
