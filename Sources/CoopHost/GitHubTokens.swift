import CoopConfiguration
import CoopCore
import Foundation

/// Prefix of every fine-grained PAT.
public let githubPATPrefix = "github_pat_"

/// The "no entry" error for a repository in PAT mode.
public func missingPATEntryError(_ repo: RepoSlug) -> String {
  "No GitHub PAT configured for '\(repo)'. Run `coop github setup-pat --repo \(repo)` to add one, or set `github = \"off\"` to disable token forwarding."
}

/// Host-side GitHub token selection for guests and clones (the GitHub parts
/// of the Rust `backend.rs`). Nothing is forwarded without an explicit
/// `github` mode; `cmd:` references are resolved only here, on use.
public struct GitHubTokens: Sendable {
  let tools: HostTools
  let resolver: CredentialResolver
  let diagnostics: Diagnostics

  public init(
    environment: [String: String], diagnostics: Diagnostics, runner: ProcessRunner = ProcessRunner()
  ) {
    tools = HostTools(environment: environment, runner: runner)
    resolver = CredentialResolver(runner: runner, environment: environment)
    self.diagnostics = diagnostics
  }

  var environmentToken: Secret<String>? {
    tools.environment["GITHUB_TOKEN"].flatMap { $0.isEmpty ? nil : Secret($0) }
  }

  /// The `GITHUB_TOKEN` to forward into a guest session, or nil for none.
  /// `repo` selects the PAT-mode entry (an active VM assignment's repo when
  /// there is one). A missing PAT-mode repo or entry forwards nothing, so
  /// follow-up commands still work; a failing entry lookup is an error.
  public func guestToken(_ github: GitHubAuth?, repo: RepoSlug?) throws -> Secret<String>? {
    switch github ?? .off {
    case .auto: return environmentToken ?? tools.ghAuthToken()
    case .env:
      if let token = environmentToken { return token }
      diagnostics.warn(
        "github: \"env\" requires GITHUB_TOKEN to be set. Private repo access will fail.")
      return nil
    case .off: return nil
    case .pat:
      guard let repo else {
        diagnostics.warn(
          "github: \"pat\" requires a resolvable repo (via --git-repo or workspace origin). No token will be forwarded."
        )
        return nil
      }
      guard github?.patEntry(repo) != nil else {
        diagnostics.warn(
          "github: \"pat\" mode has no [github.pat.\"\(repo)\"] entry. No token forwarded. Run `coop github setup-pat --repo \(repo)` to add one."
        )
        return nil
      }
      return try patToken(github, repo: repo)
    }
  }

  /// Resolve the `github.pat."<repo>"` entry. Missing entries and failed
  /// lookups are errors; a token without the fine-grained prefix is used
  /// with a warning.
  public func patToken(_ github: GitHubAuth?, repo: RepoSlug) throws -> Secret<String> {
    guard let entry = github?.patEntry(repo) else { throw HostError(missingPATEntryError(repo)) }
    let token: Secret<String>
    do { token = try resolver.resolve(entry) } catch {
      throw ContextError("Failed to resolve token for [github.pat.\"\(repo)\"]", cause: error)
    }
    if !token.expose().hasPrefix(githubPATPrefix) {
      diagnostics.warn(
        "github.pat.\"\(repo)\".token did not start with '\(githubPATPrefix)' — proceeding, but the FGPAT server-side scope guarantees do not apply."
      )
    }
    return token
  }

  /// The token for cloning `url` in the guest (used once, over stdin, never
  /// left in the guest environment). An active assignment's entry wins and
  /// never falls back; then a matching PAT-mode entry; otherwise the host's
  /// `gh auth token` or `GITHUB_TOKEN`, whatever the mode.
  public func cloneToken(_ github: GitHubAuth?, url: String, assigned: RepoSlug?) throws
    -> Secret<String>?
  {
    if let assigned { return try patToken(github, repo: assigned) }
    if let slug = Self.clonePATSlug(github, url: url) { return try patToken(github, repo: slug) }
    return Self.selectHostToken(
      gh: tools.ghAuthToken()?.expose(), env: tools.environment["GITHUB_TOKEN"]
    ).map(Secret.init)
  }

  /// The slug of `url` when PAT mode has an entry for it.
  static func clonePATSlug(_ github: GitHubAuth?, url: String) -> RepoSlug? {
    guard case .pat? = github, let slug = RepoSlug.parse(url: url), github?.patEntry(slug) != nil
    else { return nil }
    return slug
  }

  /// Prefer `gh`, then `GITHUB_TOKEN`; each trimmed, blank means absent.
  static func selectHostToken(gh: String?, env: String?) -> String? {
    let normalize = { (value: String) -> String? in
      let trimmed = value.trimmingUnicodeWhitespace()
      return trimmed.isEmpty ? nil : trimmed
    }
    return gh.flatMap(normalize) ?? env.flatMap(normalize)
  }
}

// MARK: - Guest side

/// GitHub steps run in the guest. Only fixed literals and escaped values
/// reach the remote shell; tokens travel in forwarded variables or stdin.
public enum GitHubGuest {
  /// Point git's credential helper at `gh` (which reads the forwarded
  /// `GITHUB_TOKEN`). Bootstrap runs this when the session forwards one.
  public static func setupAuth(_ ssh: SSHClient, _ session: SSHSession) throws {
    do {
      try ssh.exec(session, RemoteCommand().literal("gh auth setup-git"))
    } catch {
      throw ContextError("Failed to configure git credential helper in guest", cause: error)
    }
  }

  /// Clone `url` into `/workspace`, with a host-resolved token for GitHub
  /// HTTPS URLs when one is available.
  public static func clone(
    _ ssh: SSHClient, _ target: SSHTarget, url: String, github: GitHubAuth?,
    assigned: RepoSlug?, tokens: GitHubTokens
  ) throws {
    tokens.diagnostics.log(.info, "Cloning \(url) into guest /workspace")
    let isGitHub = GitRepoURL.isGitHubHTTPS(url)
    let token = isGitHub ? try tokens.cloneToken(github, url: url, assigned: assigned) : nil
    do {
      if let token {
        try ssh.exec(target, cloneWithTokenScript(url), stdin: Array((token.expose() + "\n").utf8))
      } else {
        try ssh.exec(
          target,
          RemoteCommand().literal(
            "sudo mkdir -p /workspace && sudo chown $(whoami):$(whoami) /workspace && git clone "
          ).arg(url).literal(" /workspace && echo 'Repository cloned to /workspace'"))
      }
    } catch {
      let context =
        if token != nil {
          "Failed to clone \(url) in guest (host-resolved token rejected)"
        } else if isGitHub {
          "Failed to clone \(url) in guest. If this is a private repo, configure a PAT with `coop github setup-pat --repo <owner/repo>`, run `gh auth login`, or set `GITHUB_TOKEN` on the host before starting the VM."
        } else {
          "Failed to clone \(url) in guest"
        }
      throw ContextError(context, cause: error)
    }
    tokens.diagnostics.log(.info, "Repository cloned to /workspace")
  }

  /// Reads the token from stdin and hands it to a one-shot credential
  /// helper; the single quotes defer `$GH_TOKEN` to the helper's subshell.
  static func cloneWithTokenScript(_ url: String) -> RemoteCommand {
    RemoteCommand()
      .literal(
        "set -eu\nIFS= read -r GH_TOKEN\nexport GH_TOKEN\nsudo mkdir -p /workspace\nsudo chown \"$(whoami):$(whoami)\" /workspace\ngit -c credential.helper='!f() { echo username=x-access-token; echo \"password=$GH_TOKEN\"; }; f' clone "
      )
      .arg(url)
      .literal(" /workspace\necho 'Repository cloned to /workspace'\n")
  }
}

// MARK: - Instance repository

extension Instance {
  /// The GitHub slug for this instance's workspace: the recorded clone URL,
  /// or the `origin` of the pushed/mounted host directory. An unreadable
  /// `workspace.json` is warned about and yields nil.
  public func detectRepo(tools: HostTools, diagnostics: Diagnostics) -> RepoSlug? {
    let source: WorkspaceRecord.Source
    do {
      guard let record = try WorkspaceRecord.load(self) else { return nil }
      source = record.source
    } catch {
      diagnostics.warn(
        "Could not read workspace state for '\(name)'; GitHub repo detection is disabled (pat-mode tokens will not be forwarded). \(oneLine(error))"
      )
      return nil
    }
    switch source {
    case .gitRepo(let url): return url.slug
    case .workspace(let path), .mount(let path):
      return (try? tools.detectWorkspaceRepo(path)) ?? nil
    }
  }
}

/// The part of `workspace.json` repo detection reads.
struct WorkspaceRecord: Decodable {
  enum Source: Decodable {
    case workspace(String)
    case gitRepo(GitRepoURL)
    case mount(String)

    enum CodingKeys: String, CodingKey {
      case kind, url
      case hostPath = "host_path"
    }

    init(from decoder: any Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      switch try c.decode(String.self, forKey: .kind) {
      case "workspace": self = .workspace(try c.decode(String.self, forKey: .hostPath))
      case "git_repo": self = .gitRepo(try c.decode(GitRepoURL.self, forKey: .url))
      case "mount": self = .mount(try c.decode(String.self, forKey: .hostPath))
      case let other:
        throw DecodingError.dataCorruptedError(
          forKey: .kind, in: c,
          debugDescription:
            "unknown variant `\(other)`, expected one of `workspace`, `git_repo`, `mount`")
      }
    }
  }

  let source: Source

  enum CodingKeys: String, CodingKey {
    case source
    case guestPath = "guest_path"
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let guestPath = try c.decode(String.self, forKey: .guestPath)
    do { _ = try GuestPath.absolute(guestPath) } catch {
      throw DecodingError.dataCorruptedError(
        forKey: .guestPath, in: c, debugDescription: error.message)
    }
    source = try c.decode(Source.self, forKey: .source)
  }

  static func load(_ instance: Instance) throws -> WorkspaceRecord? {
    let path = instance.workspaceStatePath
    guard let bytes = try StateStore.readControlFile(path) else { return nil }
    do {
      return try JSONDecoder().decode(WorkspaceRecord.self, from: Data(bytes))
    } catch {
      throw ContextError(
        "Failed to parse \(path).\nIf this file was written by a pre-#147 coop the on-disk shape changed; delete it and run `coop up` again to regenerate, or `coop destroy <name>` if the instance is no longer needed.",
        cause: HostError(RuntimeProtocol.describe(error)))
    }
  }
}

// MARK: - VM assignment

/// `github_pat.json`: a VM's choice of stored PAT entry. It holds the entry
/// key only, never a token; the token is resolved from the configuration on
/// every use, so rotation applies immediately.
public struct GitHubAssignment: Equatable, Sendable {
  public let repo: RepoSlug

  public init(repo: RepoSlug) { self.repo = repo }

  static func path(_ instance: Instance) -> String { instance.directory + "/github_pat.json" }

  public static func load(_ instance: Instance) throws -> GitHubAssignment? {
    let path = path(instance)
    var status = stat()
    if lstat(path, &status) != 0 {
      let code = errno
      if code == ENOENT { return nil }
      throw ContextError(
        "Cannot inspect github_pat.json", cause: HostError(String(cString: strerror(code))))
    }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw HostError(
        "github_pat.json must be a regular file; use coop github unassign-pat --vm <name> to remove it"
      )
    }
    let bytes: [UInt8]?
    do { bytes = try StateStore.readControlFile(path) } catch {
      throw ContextError("Cannot read github_pat.json", cause: error)
    }
    guard let bytes else { return nil }
    do {
      return try decode(bytes)
    } catch {
      throw ContextError(
        "Invalid github_pat.json; use coop github unassign-pat --vm <name> to remove it",
        cause: error)
    }
  }

  /// Exactly `{"repo": "<owner/repo>"}`.
  static func decode(_ bytes: [UInt8]) throws -> GitHubAssignment {
    let value = try ConfigLoader.parse(
      bytes, format: .json, path: "github_pat.json", limits: .configuration)
    guard case .object(let members) = value else {
      throw HostError("invalid type: \(value.typeName), expected struct Assignment")
    }
    if let unknown = members.keys.sorted(by: byteOrder).first(where: { $0 != "repo" }) {
      throw HostError("unknown field `\(unknown)`, expected `repo`")
    }
    guard let raw = members["repo"] else { throw HostError("missing field `repo`") }
    guard case .string(let slug) = raw else {
      throw HostError("invalid type: \(raw.typeName), expected a string")
    }
    return GitHubAssignment(repo: try RepoSlug(slug))
  }

  /// Fails unless the entry exists; written owner-only.
  public func save(_ config: CoopConfig, _ instance: Instance) throws {
    try validate(config)
    // serde_json's compact form; a slug needs no escaping.
    try AtomicFile.write(
      Array("{\"repo\":\"\(repo)\"}".utf8), to: Self.path(instance), mode: .atMost(0o600))
  }

  /// Unlink the association (never its target); absent is fine.
  public static func remove(_ instance: Instance) throws {
    if unlink(path(instance)) != 0 && errno != ENOENT {
      throw ContextError(
        "Cannot remove github_pat.json", cause: HostError(String(cString: strerror(errno))))
    }
  }

  public func isAvailable(_ config: CoopConfig) -> Bool { config.github?.patEntry(repo) != nil }

  public func validate(_ config: CoopConfig) throws {
    guard isAvailable(config) else {
      throw HostError(
        "Assigned PAT entry '\(repo)' is unavailable; restore it with coop github setup-pat --repo \(repo), or use coop github unassign-pat --vm <name>"
      )
    }
  }

  /// The assignment in force for `instance`. `githubDisabled` (`--no-github`)
  /// precedes even reading the file. A present assignment must name an
  /// existing entry and must not be shadowed by a user-set `GITHUB_TOKEN` /
  /// `GH_TOKEN`; it never falls back.
  public static func active(_ config: CoopConfig, _ instance: Instance, githubDisabled: Bool)
    throws -> GitHubAssignment?
  {
    if githubDisabled { return nil }
    guard let assignment = try load(instance) else { return nil }
    try assignment.validate(config)
    try rejectOverrides(config.guestEnvironment.map(\.name.rawValue))
    try rejectOverrides((config.claude.envForward + config.codex.envForward).map(\.rawValue))
    if let names = try persistedGuestEnvironmentNames(instance) { try rejectOverrides(names) }
    return assignment
  }

  public static func rejectOverrides(_ names: some Sequence<String>) throws {
    for name in names where name == "GITHUB_TOKEN" || name == "GH_TOKEN" {
      throw HostError(
        "VM PAT assignment conflicts with managed \(name); remove it from guest_env, env_forward, and persisted guest_env.json (including --env/containerEnv), or unassign the PAT"
      )
    }
  }

  /// Variable names in `guest_env.json` (the start-time `--env` snapshot);
  /// values are not retained.
  static func persistedGuestEnvironmentNames(_ instance: Instance) throws -> [String]? {
    try GuestEnvState.tryLoad(instance)?.sortedEntries.map(\.0.rawValue)
  }
}

/// The bootstrap's view of GitHub auth, backed by this module's token,
/// assignment and guest-setup logic.
public struct HostGitHubTokens: GitHubTokenSource {
  let config: CoopConfig
  let githubDisabled: Bool
  let tokens: GitHubTokens
  let tools: HostTools
  let diagnostics: Diagnostics

  /// `githubDisabled` is `--no-github`: no assignment is read and no token
  /// is forwarded.
  public init(
    config: CoopConfig, environment: [String: String], diagnostics: Diagnostics,
    githubDisabled: Bool = false
  ) {
    self.config = githubDisabled ? config.disablingGitHub() : config
    self.githubDisabled = githubDisabled
    tokens = GitHubTokens(environment: environment, diagnostics: diagnostics)
    tools = HostTools(environment: environment)
    self.diagnostics = diagnostics
  }

  public func instanceRepo(_ instance: Instance) -> RepoSlug? {
    instance.detectRepo(tools: tools, diagnostics: diagnostics)
  }

  public func activeAssignment(_ instance: Instance) throws -> RepoSlug? {
    try GitHubAssignment.active(config, instance, githubDisabled: githubDisabled)?.repo
  }

  public func token(repo: RepoSlug?) throws -> Secret<String>? {
    try tokens.guestToken(config.github, repo: repo)
  }

  public func resolvePAT(_ repo: RepoSlug) throws -> Secret<String> {
    try tokens.patToken(config.github, repo: repo)
  }

  public func configureGuest(_ client: SSHClient, _ session: SSHSession) throws {
    try GitHubGuest.setupAuth(client, session)
  }
}
