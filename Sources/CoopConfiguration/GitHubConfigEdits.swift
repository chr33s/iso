// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import CoopCore

extension GitHubAuth {
  /// The `github.pat."owner/repo"` token reference, in PAT mode only.
  public func patEntry(_ repo: RepoSlug) -> Secret<String>? {
    guard case .pat(let pat) = self else { return nil }
    return pat.entries[repo]
  }
}

extension CoopConfig {
  /// The same configuration with `github` replaced (after the PAT wizard or
  /// a skip marker rewrote it on disk), keeping every command-line override.
  public func replacingGitHub(_ github: GitHubAuth?) -> CoopConfig {
    CoopConfig(
      dataDirectory: dataDirectory, vm: vm, sshPort: sshPort, github: github, setup: setup,
      claude: claude, codex: codex, codexAuth: codexAuth, proxy: proxy,
      guestEnvironment: guestEnvironment, profiles: profiles, postStart: postStart,
      forwardPorts: forwardPorts, updates: updates, appleContainer: appleContainer,
      workspacePull: workspacePull, egress: egress)
  }

  /// `up`/`start --no-github`: GitHub auth off and the PAT prompt disabled
  /// for this command. The caller also passes `githubDisabled` to the VM
  /// assignment check so a stored assignment is not even read.
  public func disablingGitHub() -> CoopConfig {
    CoopConfig(
      dataDirectory: dataDirectory, vm: vm, sshPort: sshPort, github: .off,
      setup: SetupConfig(promptForPAT: false), claude: claude, codex: codex, codexAuth: codexAuth,
      proxy: proxy, guestEnvironment: guestEnvironment, profiles: profiles, postStart: postStart,
      forwardPorts: forwardPorts, updates: updates, appleContainer: appleContainer,
      workspacePull: workspacePull, egress: egress)
  }
}

/// A verified GitHub edit of the configuration document.
public struct GitHubConfigEdit: Sendable {
  public let bytes: [UInt8]
  /// Some `github.pat.*.token` is a literal rather than a `cmd:` reference;
  /// the file is then written owner-only.
  public let holdsLiteralToken: Bool
}

/// Structural edits of the `github` member, with the Rust wizard's rules:
/// a non-object `github` (e.g. `"off"`) becomes an object, `mode` is forced
/// to `"pat"`, and non-object/non-array `pat`/`skip` members are replaced.
/// Each returns nil when the document would not change, so a repeated
/// rotation does not rewrite (and strip the comments of) the file.
extension ConfigEditor {
  /// Set `github.pat."<repo>" = {"token": token}` and drop `repo` from `skip`.
  public static func upsertPAT(
    existing: [UInt8]?, format: ConfigFormat, path: String, repo: RepoSlug, token: String,
    environment: ConfigEnvironment, limits: JSONLimits = .configuration
  ) throws(ConfigError) -> GitHubConfigEdit? {
    try editGitHub(
      existing: existing, format: format, path: path, environment: environment, limits: limits
    ) { github in
      github["mode"] = .string("pat")
      var pat: [String: JSONValue] = [:]
      if case .object(let members)? = github["pat"] { pat = members }
      pat[repo.rawValue] = .object(["token": .string(token)])
      github["pat"] = .object(pat)
      if case .array(let skip)? = github["skip"] {
        github["skip"] = .array(skip.filter { $0 != .string(repo.rawValue) })
      }
    }
  }

  /// Remove `github.pat."<repo>"`; everything else is kept.
  public static func removePAT(
    existing: [UInt8], format: ConfigFormat, path: String, repo: RepoSlug,
    environment: ConfigEnvironment, limits: JSONLimits = .configuration
  ) throws(ConfigError) -> GitHubConfigEdit? {
    guard case .object(let top) = try parse(existing, format: format, path: path, limits: limits),
      case .object? = top["github"]
    else { return nil }
    return try editGitHub(
      existing: existing, format: format, path: path, environment: environment, limits: limits
    ) { github in
      guard case .object(var pat)? = github["pat"] else { return }
      pat[repo.rawValue] = nil
      github["pat"] = .object(pat)
    }
  }

  /// Record `repo` in `github.skip` (the auto-prompt's `never`). `mode` is
  /// forced to `"pat"` because the skip list is only read in PAT mode; PAT
  /// mode without a matching entry forwards no token, as `off` does.
  public static func addSkipMarker(
    existing: [UInt8]?, format: ConfigFormat, path: String, repo: RepoSlug,
    environment: ConfigEnvironment, limits: JSONLimits = .configuration
  ) throws(ConfigError) -> GitHubConfigEdit? {
    try editGitHub(
      existing: existing, format: format, path: path, environment: environment, limits: limits
    ) { github in
      github["mode"] = .string("pat")
      var skip: [JSONValue] = []
      if case .array(let entries)? = github["skip"] { skip = entries }
      if !skip.contains(.string(repo.rawValue)) { skip.append(.string(repo.rawValue)) }
      github["skip"] = .array(skip)
    }
  }

  private static func parse(
    _ existing: [UInt8]?, format: ConfigFormat, path: String, limits: JSONLimits
  ) throws(ConfigError) -> JSONValue {
    guard let existing else { return .object([:]) }
    return try ConfigLoader.parse(existing, format: format, path: path, limits: limits)
  }

  private static func editGitHub(
    existing: [UInt8]?, format: ConfigFormat, path: String, environment: ConfigEnvironment,
    limits: JSONLimits, _ change: (inout [String: JSONValue]) -> Void
  ) throws(ConfigError) -> GitHubConfigEdit? {
    let original = try parse(existing, format: format, path: path, limits: limits)
    // Only a valid configuration is edited (see `upsertProxy`).
    _ = try ConfigLoader.decode(original, path: path, environment: environment)
    guard case .object(var top) = original else { throw .rootNotObject(path: path) }
    var github: [String: JSONValue] = [:]
    if case .object(let members)? = top["github"] { github = members }
    change(&github)
    top["github"] = .object(github)
    let edited = JSONValue.object(top)
    if existing != nil && edited.semanticallyEquals(original) { return nil }
    let bytes = try encodeVerified(
      edited, format: format, path: path, environment: environment, limits: limits)
    return GitHubConfigEdit(bytes: bytes, holdsLiteralToken: holdsLiteralToken(edited))
  }

  static func holdsLiteralToken(_ document: JSONValue) -> Bool {
    guard case .object(let entries)? = document["github"]?["pat"] else { return false }
    return entries.values.contains { entry in
      if case .string(let token)? = entry["token"] { return !token.hasPrefix("cmd:") }
      return false
    }
  }
}
