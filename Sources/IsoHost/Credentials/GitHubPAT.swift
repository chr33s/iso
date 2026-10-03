// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoConfiguration
import IsoCore

/// The terminal an interactive GitHub flow talks to: prompts and progress
/// on stderr, answers from stdin.
package struct WizardConsole: Sendable {
  /// Raw text to stderr (callers add newlines).
  package var write: @Sendable (String) -> Void
  /// One line from stdin; nil at end of input.
  package var readLine: @Sendable () -> String?
  /// Turn terminal echo off; false when there is no terminal to change.
  package var echoOff: @Sendable () -> Bool
  package var echoOn: @Sendable () -> Void
  package var stdinIsTerminal: @Sendable () -> Bool

  package init(
    write: @escaping @Sendable (String) -> Void, readLine: @escaping @Sendable () -> String?,
    echoOff: @escaping @Sendable () -> Bool, echoOn: @escaping @Sendable () -> Void,
    stdinIsTerminal: @escaping @Sendable () -> Bool
  ) {
    self.write = write
    self.readLine = readLine
    self.echoOff = echoOff
    self.echoOn = echoOn
    self.stdinIsTerminal = stdinIsTerminal
  }

  /// The process's own stdin/stderr, with echo toggled by `stty` on the
  /// inherited terminal. A signal while echo is off leaves it off; `stty
  /// echo` restores it (as with the baseline).
  package static func standard(tools: HostTools) -> WizardConsole {
    let stty = { @Sendable (argument: String) -> Bool in
      guard let executable = tools.locate("stty"),
        let termination = try? tools.runner.attached(
          .init(
            executable: executable, arguments: [argument], environment: tools.environment,
            deadline: HostTools.deadline), inheritStdin: true)
      else { return false }
      return termination.succeeded
    }
    return WizardConsole(
      write: { FileHandle.standardError.write(Data($0.utf8)) },
      readLine: { Swift.readLine(strippingNewline: false) },
      echoOff: { stty("-echo") }, echoOn: { _ = stty("echo") },
      stdinIsTerminal: { isatty(0) == 1 })
  }
}

/// A configuration file the GitHub commands edit.
package struct ConfigTarget: Sendable, Equatable {
  package let path: String
  package let format: ConfigFormat

  package init(path: String, format: ConfigFormat) {
    self.path = path
    self.format = format
  }
}

extension ConfigStore {
  /// Locked read-modify-write of the `github` member (see `upsertProxy`).
  /// The file is owner-only when any PAT token is a literal, 0644 otherwise,
  /// and never widened. An unchanged document is not rewritten.
  static func editGitHub(
    at target: ConfigTarget,
    _ edit: ([UInt8]?) throws(ConfigError) -> GitHubConfigEdit?
  ) throws {
    let lock = try FileLock.sibling(of: target.path)
    defer { lock.release() }
    let existing = try ConfigLoader.readSnapshot(
      target.path, limit: JSONLimits.configuration.maxBytes)
    guard let updated = try edit(existing) else { return }
    try AtomicFile.write(
      updated.bytes, to: target.path, mode: .atMost(updated.holdsLiteralToken ? 0o600 : 0o644))
  }

  package static func upsertPAT(
    at target: ConfigTarget, repo: RepoSlug, token: String, environment: ConfigEnvironment
  ) throws {
    try editGitHub(at: target) { existing throws(ConfigError) in
      try ConfigEditor.upsertPAT(
        existing: existing, format: target.format, path: target.path, repo: repo, token: token,
        environment: environment)
    }
  }

  package static func removePAT(
    at target: ConfigTarget, repo: RepoSlug, environment: ConfigEnvironment
  ) throws {
    try editGitHub(at: target) { existing throws(ConfigError) in
      guard let existing else { return nil }
      return try ConfigEditor.removePAT(
        existing: existing, format: target.format, path: target.path, repo: repo,
        environment: environment)
    }
  }

  package static func addSkipMarker(
    at target: ConfigTarget, repo: RepoSlug, environment: ConfigEnvironment
  ) throws {
    try editGitHub(at: target) { existing throws(ConfigError) in
      try ConfigEditor.addSkipMarker(
        existing: existing, format: target.format, path: target.path, repo: repo,
        environment: environment)
    }
  }
}

/// `iso github …` and the start-time PAT prompt. PATs are stored in the
/// macOS Keychain only (C-04); the configuration holds the `cmd:` reference.
package struct GitHubHost: Sendable {
  package static let newTokenURL = "https://github.com/settings/personal-access-tokens/new"

  package let environment: ConfigEnvironment
  package let tools: HostTools
  package let keychain: Keychain
  package let console: WizardConsole
  package let diagnostics: Diagnostics
  /// Where `setup-pat` without `--repo` looks for an `origin`.
  let workingDirectory: String?
  /// Where `vault:` entries resolve; the command's own store by default.
  let secrets: (any SecretReferenceResolver)?

  package init(
    environment: ConfigEnvironment, diagnostics: Diagnostics,
    runner: ProcessRunner = ProcessRunner(), security: String = Keychain.defaultSecurity,
    console: WizardConsole? = nil,
    workingDirectory: String? = FileManager.default.currentDirectoryPath,
    secrets: (any SecretReferenceResolver)? = CredentialResolver.processSecrets
  ) {
    self.environment = environment
    tools = HostTools(environment: environment.variables, runner: runner)
    keychain = Keychain(security: security, environment: environment.variables, runner: runner)
    self.console = console ?? .standard(tools: tools)
    self.diagnostics = diagnostics
    self.workingDirectory = workingDirectory
    self.secrets = secrets
  }

  var api: GitHubAPI { GitHubAPI(tools: tools, diagnostics: diagnostics) }
  var resolver: CredentialResolver {
    CredentialResolver(runner: tools.runner, environment: environment.variables, secrets: secrets)
  }

  // MARK: setup-pat / rotate-pat

  /// The fine-grained PAT wizard: validate the pasted token against the
  /// repository (and same-owner submodules), store it in the Keychain, and
  /// write `github.pat."<repo>"` with any skip marker removed.
  package func setupPAT(_ config: IsoConfig, target: ConfigTarget, repo: RepoSlug?) throws {
    let repo = try targetRepo(repo)
    try keychain.requireAvailable()
    let prediscovered = api.prefetchSubmodules(repo)
    console.write(Self.formInstructions(repo, prediscovered))
    _ = try? tools.run("open", [Self.newTokenURL])

    var token = try readToken()
    warnFormat(token)
    console.write("\nValidating token against api.github.com…\n")
    try probe(token, repo)
    token = try coverSubmodules(token, repo, prediscovered)

    let reference: KeychainReference
    do {
      reference = try keychain.store(
        service: SecretStore.githubPATService, account: SecretAccount(repo: repo), secret: token)
    } catch {
      throw ContextError("Failed to store secret in chosen backend", cause: error)
    }
    try ConfigStore.upsertPAT(
      at: target, repo: repo, token: reference.description, environment: environment)
    console.write(
      "\nWrote \(target.path):\n  github.mode = \"pat\"\n  [github.pat.\"\(repo)\"]\n  token = \"\(reference)\"\n"
    )
    console.write("\nDone. VM startups for https://github.com/\(repo) will use this token.\n")
  }

  /// The same wizard, noting when there is no entry to replace.
  package func rotatePAT(_ config: IsoConfig, target: ConfigTarget, repo: RepoSlug) throws {
    if config.github?.patEntry(repo) == nil {
      console.write(
        "note: no existing PAT entry for '\(repo)' — proceeding as if this were a fresh setup.\n")
    }
    try setupPAT(config, target: target, repo: repo)
  }

  func targetRepo(_ repo: RepoSlug?) throws -> RepoSlug {
    if let repo { return repo }
    if let directory = workingDirectory, let slug = try tools.detectWorkspaceRepo(directory) {
      return slug
    }
    throw HostError(
      "Could not detect a target repo. Pass --repo owner/name, or run from a git working tree whose origin points at github.com."
    )
  }

  /// Read a pasted secret with echo off. Shared with `iso proxy setup`.
  package func readToken() throws -> Secret<String> {
    console.write("Paste token: ")
    let echoWasDisabled = console.echoOff()
    let line = console.readLine()
    if echoWasDisabled {
      console.write("\n")
      console.echoOn()
    }
    let token = (line ?? "").trimmingUnicodeWhitespace()
    guard !token.isEmpty else { throw HostError("No token entered") }
    return Secret(token)
  }

  func warnFormat(_ token: Secret<String>) {
    // Classic PATs are accepted; they lack the fine-grained scope guarantees.
    if !token.expose().hasPrefix(githubPATPrefix) {
      console.write(
        "warning: token does not start with '\(githubPATPrefix)' — not a fine-grained PAT. Proceeding anyway.\n"
      )
    }
  }

  func probe(_ token: Secret<String>, _ repo: RepoSlug) throws {
    _ = try api.userLogin(token: token)
    console.write("  ✓ /user\n")
    try api.probeRepo(token: token, repo: repo)
    console.write("  ✓ /repos/\(repo)\n")
  }

  /// Report the discovery and, while same-owner submodules are not covered,
  /// ask for a widened token. Returns the token to store: the last one that
  /// passed every probe.
  func coverSubmodules(
    _ token: Secret<String>, _ parent: RepoSlug, _ prediscovered: SubmoduleDiscovery?
  ) throws -> Secret<String> {
    let discovery = try prediscovered ?? discoverWithPastedToken(token, parent)
    if discovery.isEmpty { return token }
    var token = token
    if !discovery.sameOwner.isEmpty {
      while true {
        let failed = try api.uncovered(token: token, expected: discovery.sameOwner)
        if failed.isEmpty {
          console.write("  ✓ all same-owner submodule repos covered\n")
          break
        }
        console.write(Self.widenInstructions(parent, expected: discovery.sameOwner, failed: failed))
        token = try readToken()
        warnFormat(token)
        console.write("\nValidating widened token against api.github.com…\n")
        try probe(token, parent)
      }
    }
    // Pre-discovery already printed this advice with the form.
    if prediscovered == nil {
      if !discovery.crossOwner.isEmpty {
        var text =
          "\nNote: submodules under other resource owners need their own FGPAT (one form per owner). Run:\n"
        for (owner, repos) in discovery.crossOwner {
          text += "\n  Resource owner: \(owner)\n"
          for slug in repos { text += "    iso github setup-pat --repo \(slug)\n" }
        }
        console.write(text)
      }
      console.write(
        "\nNote: only depth-1 submodules were checked. Nested submodules (submodules of submodules) need their own `setup-pat` runs.\n"
      )
    }
    return token
  }

  func discoverWithPastedToken(_ token: Secret<String>, _ parent: RepoSlug) throws
    -> SubmoduleDiscovery
  {
    var (discovery, warnStatus) = try api.discoverSubmodules(token: token, parent: parent)
    if let warnStatus {
      console.write(
        "warning: GET /repos/\(parent)/contents/.gitmodules returned HTTP \(warnStatus) — skipping submodule check.\n"
      )
    }
    let skipped = discovery.dropPublic(api.isPublic)
    if !skipped.isEmpty {
      console.write(
        "\nSkipping \(skipped.count) public submodule repo(s) — they clone without a token:\n"
          + skipped.map { "  - \($0)\n" }.joined())
    }
    if !discovery.nonGitHubURLs.isEmpty {
      console.write(
        "\nIgnoring non-GitHub submodule URLs (this token can't cover them):\n"
          + discovery.nonGitHubURLs.map { "  - \(sanitizeForDisplay($0))\n" }.joined())
    }
    return discovery
  }

  static func widenInstructions(_ parent: RepoSlug, expected: [RepoSlug], failed: [RepoSlug])
    -> String
  {
    var text =
      "\n\(failed.count) submodule repo(s) under '\(parent.owner)' are not covered by this token:\n"
    for slug in failed { text += "  - \(slug)\n" }
    text +=
      "\nRe-open \(newTokenURL) (or edit the existing token), keep Resource owner '\(parent.owner)', and under 'Only select repositories' include all of:\n"
    text += "  - \(parent)\n"
    for slug in expected { text += "  - \(slug)\n" }
    return text + "Generate a fresh token, then paste it below. (Empty input aborts.)\n"
  }

  /// The form to fill in at github.com. With a discovery, the repository
  /// list includes same-owner private submodules, and other-owner and
  /// non-GitHub submodules are explained before the paste prompt.
  static func formInstructions(_ repo: RepoSlug, _ discovery: SubmoduleDiscovery?) -> String {
    let extras = discovery?.sameOwner ?? []
    var s = "\nConfigure the form at \(newTokenURL):\n"
    s += "  Token name:        iso-\(repo.owner)-\(repo.repo)\n"
    s += "  Expiration:        (your choice — 90 days is a reasonable default)\n"
    s += "  Resource owner:    \(repo.owner)\n"
    if extras.isEmpty {
      s += "  Repository access: Only select repositories → \(repo)\n"
    } else {
      s += "  Repository access: Only select repositories:\n"
      s += "                       - \(repo)\n"
      for slug in extras { s += "                       - \(slug)\n" }
    }
    s += "  Repository permissions:\n"
    s += "    Contents:        Read and write\n"
    s += "    Pull requests:   Read and write\n"
    s += "    Issues:          Read and write\n"
    s += "    Commit statuses: Read-only\n"
    s += "    Metadata:        Read-only (auto-included)\n"
    if let discovery {
      if !discovery.crossOwner.isEmpty {
        s +=
          "\nSubmodules under other resource owners need their own FGPAT (one form per owner). After this token, run:\n"
        for (owner, repos) in discovery.crossOwner {
          s += "\n  Resource owner: \(owner)\n"
          for slug in repos { s += "    iso github setup-pat --repo \(slug)\n" }
        }
      }
      if !discovery.nonGitHubURLs.isEmpty {
        s += "\nThese submodule URLs are not on github.com — this token can't cover them:\n"
        for url in discovery.nonGitHubURLs { s += "  - \(sanitizeForDisplay(url))\n" }
      }
      if !extras.isEmpty || !discovery.crossOwner.isEmpty {
        s +=
          "\nNote: only depth-1 submodules were checked. Nested submodules (submodules of submodules) need their own `setup-pat` runs.\n"
      }
    }
    return s + "\nClick \"Generate token\", then paste it below.\n"
  }

  // MARK: forget-pat

  /// Remove the entry (no skip marker) and, when its reference is the
  /// Keychain item iso writes, that item. Any other reference is the
  /// user's own and is left alone.
  package func forgetPAT(_ config: IsoConfig, target: ConfigTarget, repo: RepoSlug) throws {
    guard let entry = config.github?.patEntry(repo) else {
      throw HostError(
        "No PAT entry for '\(repo)' — nothing to forget. Run `iso github status`.")
    }
    if KeychainReference.parse(entry.expose()) != nil {
      keychain.delete(service: SecretStore.githubPATService, account: SecretAccount(repo: repo))
    } else {
      diagnostics.log(
        .info,
        "Storage backend not recognised from cmd: invocation — config entry removed; clean up the underlying secret manually if needed."
      )
    }
    try ConfigStore.removePAT(at: target, repo: repo, environment: environment)
    console.write("Removed PAT entry for \(repo).\n")
    console.write(
      "note: the token itself may still be live on GitHub — revoke it under https://github.com/settings/personal-access-tokens if you want to fully invalidate it.\n"
    )
  }

  // MARK: status

  /// `github status`. Never carries a token; `probe` resolves each entry's
  /// reference (which may raise a Keychain prompt).
  package func status(_ config: IsoConfig, probe: Bool, instance: Instance?) throws
    -> GitHubStatusView
  {
    var entries: [GitHubStatusView.Entry] = []
    var skip: [RepoSlug] = []
    if case .pat(let pat)? = config.github {
      // One unlock for every `vault:` entry; a failure here surfaces per
      // entry below.
      if probe {
        do { try resolver.prefetchStored(Array(pat.entries.values)) } catch {
          diagnostics.debug("stored-secret prefetch failed; resolving entries one by one: \(error)")
        }
      }
      for repo in pat.entries.keys.sorted() {
        let token = pat.entries[repo]!
        let status: GitHubStatusView.ProbeStatus? =
          probe
          ? {
            guard let resolved = try? resolver.resolveAllowingStored(token) else {
              return .resolveFailed
            }
            return resolved.expose().hasPrefix(githubPATPrefix) ? .ok : .unexpectedFormat
          }() : nil
        entries.append(
          .init(repo: repo, keychain: KeychainReference.parse(token.expose()) != nil, probe: status)
        )
      }
      skip = pat.skip
    }
    var view = GitHubStatusView(
      vm: nil, mode: config.github?.modeName ?? "off", entries: entries, skip: skip)
    if let instance {
      let assignment = try GitHubAssignment.load(instance)
      let repo =
        assignment == nil ? instance.detectRepo(tools: tools, diagnostics: diagnostics) : nil
      view.vm = .init(
        name: instance.name, assignedEntry: assignment?.repo,
        source: .of(config, assignment: assignment, repo: repo))
    }
    return view
  }

  // MARK: start-time prompt

  /// Before a VM boots: offer the wizard for `repo` when GitHub auth is not
  /// configured for it. Returns `config` with `github` reloaded from disk
  /// after the wizard or a `never` answer changed it; other overrides stay.
  /// A failed wizard asks whether to continue unauthenticated.
  package func maybePrompt(
    _ config: IsoConfig, target: ConfigTarget, repo: RepoSlug?, noPrompt: Bool
  ) throws -> IsoConfig {
    let interactive = console.stdinIsTerminal()
    let ci = environment.variables["CI"] != nil
    guard
      PATPromptDecision.resolve(
        config, repo: repo, isTerminal: interactive, isCI: ci, noPrompt: noPrompt) == .prompt,
      let repo
    else {
      if let repo, !interactive || ci, config.github == nil || config.github == .off {
        diagnostics.log(
          .info, "tip: run 'iso github setup-pat --repo \(repo)' to scope GitHub auth to this repo"
        )
      }
      return config
    }
    console.write(
      "\nNo GitHub credential is configured for \(repo) (github = \(debugQuoted(config.github?.modeName ?? "off"))).\n"
    )
    console.write("Pushes and private-repo operations from the guest will fail.\n\n")
    console.write("Set up a scoped fine-grained PAT now? [y/N/never] ")
    switch asciiLowercased((console.readLine() ?? "").trimmingUnicodeWhitespace()) {
    case "y", "yes":
      try setupOrRecover(config, target: target, repo: repo)
      return try reloadingGitHub(config, target)
    case "never":
      try ConfigStore.addSkipMarker(at: target, repo: repo, environment: environment)
      let updated = try reloadingGitHub(config, target)
      diagnostics.log(.info, "recorded skip marker for \(repo); continuing without GitHub auth")
      return updated
    default:
      diagnostics.log(.info, "continuing without GitHub auth for \(repo)")
      return config
    }
  }

  func reloadingGitHub(_ config: IsoConfig, _ target: ConfigTarget) throws -> IsoConfig {
    let fresh = try ConfigLoader.load(
      .file(path: target.path, format: target.format), environment: environment)
    return config.replacingGitHub(fresh.github)
  }

  func setupOrRecover(_ config: IsoConfig, target: ConfigTarget, repo: RepoSlug) throws {
    do {
      try setupPAT(config, target: target, repo: repo)
    } catch {
      switch error as? GitHubProbeError {
      case .notFound(let repo)?:
        console.write(
          "'\(repo)' wasn't found with this token. Check the slug and that the PAT's resource owner matches, then retry: iso github setup-pat --repo \(repo)\n"
        )
      case .orgPolicyBlock?:
        console.write(
          "The token is valid but the org blocks fine-grained PATs. Public repos still clone unauthenticated; private pushes will fail until an org admin approves the token.\n"
        )
      default: break
      }
      let summary = (error as? ContextError)?.context ?? "\(error)"
      diagnostics.warn("PAT setup failed (\(summary)); falling back to unauthenticated start")
      console.write("continue without GitHub auth? [y/N] ")
      let answer = asciiLowercased((console.readLine() ?? "").trimmingUnicodeWhitespace())
      guard answer == "y" || answer == "yes" else { throw error }
    }
  }
}

/// Whether the start-time prompt may be shown.
package enum PATPromptDecision: Equatable, Sendable {
  case skip
  case prompt

  /// Needs a repository, an interactive non-CI terminal, no `--no-prompt`,
  /// `setup.prompt_for_pat`, and a mode of off/unset or PAT without an entry
  /// or skip marker for the repository. `auto`/`env` are respected.
  package static func resolve(
    _ config: IsoConfig, repo: RepoSlug?, isTerminal: Bool, isCI: Bool, noPrompt: Bool
  ) -> PATPromptDecision {
    guard let repo else { return .skip }
    if noPrompt || isCI || !isTerminal || !config.setup.promptForPAT { return .skip }
    switch config.github {
    case nil, .off?: return .prompt
    case .pat(let pat)?:
      return pat.skip.contains(repo) || pat.entries[repo] != nil ? .skip : .prompt
    case .auto?, .env?: return .skip
    }
  }
}

/// `iso github status` model; it never holds a token.
package struct GitHubStatusView: Sendable, Encodable {
  package enum SelectionSource: String, Sendable, Encodable {
    case assignment
    case missingAssignment = "missing_assignment"
    case repository, auto, env, off
    case noMatchingEntry = "no_matching_entry"

    /// Rust `{:?}`, used by the text report.
    var debugName: String {
      switch self {
      case .assignment: "Assignment"
      case .missingAssignment: "MissingAssignment"
      case .repository: "Repository"
      case .auto: "Auto"
      case .env: "Env"
      case .off: "Off"
      case .noMatchingEntry: "NoMatchingEntry"
      }
    }

    /// How a VM's session token is selected: its assignment first (or the
    /// reason it cannot be used), then the configured mode.
    package static func of(_ config: IsoConfig, assignment: GitHubAssignment?, repo: RepoSlug?)
      -> SelectionSource
    {
      if let assignment { return assignment.isAvailable(config) ? .assignment : .missingAssignment }
      switch config.github {
      case .auto?: return .auto
      case .env?: return .env
      case .pat(let pat)?:
        return repo.map { pat.entries[$0] != nil } == true ? .repository : .noMatchingEntry
      case .off?, nil: return .off
      }
    }
  }

  package enum ProbeStatus: String, Sendable, Encodable {
    case ok
    case unexpectedFormat = "unexpected_format"
    case resolveFailed = "resolve_failed"

    var label: String {
      switch self {
      case .ok: "resolves, format ok"
      case .unexpectedFormat: "resolves but unexpected format"
      case .resolveFailed: "FAILED to resolve"
      }
    }
  }

  package struct VM: Sendable, Encodable {
    package let name: InstanceName
    package let assignedEntry: RepoSlug?
    package let source: SelectionSource

    enum CodingKeys: String, CodingKey {
      case name, source
      case assignedEntry = "assigned_entry"
    }

    package func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(name, forKey: .name)
      try values.encode(assignedEntry?.rawValue, forKey: .assignedEntry)
      try values.encode(source, forKey: .source)
    }
  }

  package struct Entry: Sendable, Encodable {
    package let repo: RepoSlug
    /// The reference is the Keychain item iso writes; otherwise opaque.
    package let keychain: Bool
    package let probe: ProbeStatus?

    enum CodingKeys: String, CodingKey { case repo, storage, probe }

    package func encode(to encoder: any Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(repo.rawValue, forKey: .repo)
      try values.encode(keychain ? SecretStore.keychainToken : nil, forKey: .storage)
      try values.encode(probe, forKey: .probe)
    }
  }

  package var vm: VM?
  package let mode: String
  package let entries: [Entry]
  package let skip: [RepoSlug]

  enum CodingKeys: String, CodingKey { case vm, mode, entries, skip }

  package func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(vm, forKey: .vm)
    try values.encode(mode, forKey: .mode)
    try values.encode(entries, forKey: .entries)
    try values.encode(skip.map(\.rawValue), forKey: .skip)
  }

  package func text() -> String {
    var s = ""
    if let vm {
      s +=
        "VM \(vm.name): selection \(vm.source.debugName); assigned entry: \(vm.assignedEntry?.rawValue ?? "none")\n"
      if vm.source == .missingAssignment {
        s +=
          "  Assigned entry unavailable: restore it with setup-pat or use unassign-pat --vm \(vm.name)\n"
      }
    }
    guard mode == "pat" else { return s + "github mode: \(mode) (no PAT entries)\n" }
    if entries.isEmpty && skip.isEmpty { return s + "github mode: pat (no entries)\n" }
    s += "github mode: pat\nentries (\(entries.count)):\n"
    for entry in entries {
      s += "  \(entry.repo)\n"
      s += "    storage: \(entry.keychain ? SecretStore.keychainLabel : "unknown")\n"
      if let probe = entry.probe { s += "    status:  \(probe.label)\n" }
    }
    if !skip.isEmpty {
      s += "skip (\(skip.count)):\n"
      for repo in skip { s += "  \(repo)\n" }
    }
    return s
  }
}
