import Foundation
import IsoConfiguration
import IsoCore

/// `--devcontainer PATH` / `--no-devcontainer` as one value, so "explicit
/// and disabled" cannot be represented.
public enum DevcontainerInput: Sendable, Equatable {
  /// Use exactly this file; no discovery or prompt.
  case explicit(String)
  /// Skip discovery entirely.
  case disabled
  /// Discover a file, then prompt before applying it.
  case discover

  /// `--no-devcontainer` wins, matching the opt-out's precedence.
  public static func fromFlags(path: String?, noDevcontainer: Bool) -> DevcontainerInput {
    if noDevcontainer { return .disabled }
    return path.map(DevcontainerInput.explicit) ?? .discover
  }
}

/// Discovery and apply controls for one command.
public struct DevcontainerOptions: Sendable {
  public var input: DevcontainerInput
  /// Print the report and stop before side effects (no prompt).
  public var dryRun: Bool
  public var workspace: String?
  public var mounts: [Mount]
  public var gitRepo: String?
  public var githubAuth: GitHubAuth?
  /// `Devcontainer.preferencesPath(config)`; nil disables stored opt-outs.
  public var preferencePath: String?

  public init(
    input: DevcontainerInput, dryRun: Bool, workspace: String? = nil, mounts: [Mount] = [],
    gitRepo: String? = nil, githubAuth: GitHubAuth? = nil, preferencePath: String? = nil
  ) {
    self.input = input
    self.dryRun = dryRun
    self.workspace = workspace
    self.mounts = mounts
    self.gitRepo = gitRepo
    self.githubAuth = githubAuth
    self.preferencePath = preferencePath
  }
}

/// Interactive confirmation (Rust `prompt::confirm*`). Both answer false
/// when stdin is not a terminal.
public protocol DevcontainerPrompter: Sendable {
  var isInteractive: Bool { get }
  /// `[y/N]`.
  func confirm(_ prompt: String) throws -> Bool
  /// `[Y/n]`.
  func confirmDefaultYes(_ prompt: String) throws -> Bool
}

public struct TerminalPrompter: DevcontainerPrompter {
  public init() {}

  public var isInteractive: Bool { isatty(0) == 1 }

  public func confirm(_ prompt: String) throws -> Bool {
    guard let reply = try ask(prompt + " [y/N] ") else { return false }
    return reply == "y" || reply == "yes"
  }

  public func confirmDefaultYes(_ prompt: String) throws -> Bool {
    guard let reply = try ask(prompt + " [Y/n] ") else { return false }
    return reply.isEmpty || reply == "y" || reply == "yes"
  }

  /// The trimmed, ASCII-lowercased reply; nil when stdin is not a terminal.
  func ask(_ prompt: String) throws -> String? {
    guard isInteractive else { return nil }
    FileHandle.standardError.write(Data(prompt.utf8))
    let line = readLine(strippingNewline: true) ?? ""
    return String(
      line.trimmingUnicodeWhitespace().unicodeScalars.map {
        ("A"..."Z").contains($0) ? Character(Unicode.Scalar($0.value + 32)!) : Character($0)
      })
  }
}

/// Discovery, prompting and translation (Rust `resolve_devcontainer*`).
public struct DevcontainerResolver: Sendable {
  let environment: [String: String]
  let diagnostics: Diagnostics
  let prompter: any DevcontainerPrompter
  let features: FeatureResolver
  let remote: GitRepoDevcontainerDiscovery
  let errorSink: @Sendable (String) -> Void

  public init(
    environment: [String: String], diagnostics: Diagnostics,
    prompter: any DevcontainerPrompter = TerminalPrompter(),
    runner: ProcessRunner = ProcessRunner(),
    errorSink: @escaping @Sendable (String) -> Void = { text in
      FileHandle.standardError.write(Data(text.utf8))
    }
  ) {
    self.environment = environment
    self.diagnostics = diagnostics
    self.prompter = prompter
    features = FeatureResolver(environment: environment, runner: runner, diagnostics: diagnostics)
    remote = GitRepoDevcontainerDiscovery(
      environment: environment, runner: runner, diagnostics: diagnostics)
    self.errorSink = errorSink
  }

  /// `collect`, then the report to stderr followed by a blank line.
  public func resolve(
    _ options: DevcontainerOptions, inputs: DevcontainerTranslatorInputs, stage: DevcontainerStage
  ) throws -> DevcontainerTranslation? {
    let translation = try collect(options, inputs: inputs, stage: stage)
    if let translation { errorSink(translation.report.render() + "\n") }
    return translation
  }

  private enum Source {
    case path(String)
    case contents(displayPath: String, contents: String)
  }

  /// Nil when disabled, nothing was found, a stored opt-out applies, or the
  /// user declined. Discovery without a TTY is an error unless dry-running:
  /// scripts must pass `--devcontainer` or `--no-devcontainer`.
  public func collect(
    _ options: DevcontainerOptions, inputs: DevcontainerTranslatorInputs, stage: DevcontainerStage
  ) throws -> DevcontainerTranslation? {
    let source: Source
    var losers: [String] = []
    switch options.input {
    case .disabled: return nil
    case .explicit(let path): source = .path(path)
    case .discover:
      let found = Devcontainer.discover(workspace: options.workspace, mounts: options.mounts)
      if let (winner, others) = Devcontainer.pickWinner(found) {
        source = .path(winner.path)
        losers = others
      } else if let repository = options.gitRepo,
        let file = try remote.discover(repository, auth: options.githubAuth)
      {
        source = .contents(displayPath: file.displayPath, contents: file.contents)
      } else {
        return nil
      }
    }
    let displayPath: String
    let isLocal: Bool
    switch source {
    case .path(let path):
      displayPath = path
      isLocal = true
    case .contents(let path, _):
      displayPath = path
      isLocal = false
    }

    if options.input == .discover && isLocal,
      try skipForStoredOptOut(options, displayPath: displayPath)
    {
      return nil
    }

    if options.input == .discover && !options.dryRun {
      guard prompter.isInteractive else {
        if isLocal {
          throw HostError(
            "Found \(displayPath) but stdin is not a TTY.\nPass --devcontainer \(displayPath) to apply it, or --no-devcontainer to ignore.\niso reads a subset of devcontainer.json — see docs/devcontainer.md for the supported keys."
          )
        }
        throw HostError(
          "Found \(displayPath) but stdin is not a TTY.\nRun interactively to confirm the remote file, pass --no-devcontainer to ignore it, or pass --devcontainer <local-path> to apply an explicit file.\niso reads a subset of devcontainer.json — see docs/devcontainer.md for the supported keys."
        )
      }
      guard try prompter.confirmDefaultYes("Use devcontainer.json at \(displayPath)?") else {
        if isLocal {
          diagnostics.log(
            .info,
            "Skipping \(displayPath). Re-run with --devcontainer \(displayPath) to apply it later.")
          if let project = options.workspace { try recordOptOut(options, project: project) }
        } else {
          diagnostics.log(.info, "Skipping \(displayPath). Re-run interactively to apply it later.")
        }
        return nil
      }
    }

    let parsed: ParsedDevcontainer
    switch source {
    case .path(let path): parsed = try ParsedDevcontainer.load(path)
    case .contents(let path, let contents):
      parsed = try ParsedDevcontainer(path: path, text: contents)
    }
    var translation = Devcontainer.translate(parsed, inputs: inputs, stage: stage)
    if !isLocal { translation.applied?.source = .remoteContents }
    translation.report.ignoredPaths = losers
    resolveFeatureRequests(&translation)
    return translation
  }

  func skipForStoredOptOut(_ options: DevcontainerOptions, displayPath: String) throws -> Bool {
    guard let preferencePath = options.preferencePath, let project = options.workspace else {
      return false
    }
    let preferences = try DevcontainerPreferences.load(preferencePath)
    guard let key = try preferences.ignoredProject(project) else { return false }
    errorSink(
      "Skipping \(displayPath) because a stored devcontainer opt-out is set for project \(key).\nRun `iso devcontainer clear \(key)` to re-enable discovery, or pass --devcontainer \(displayPath) to apply this file once.\n"
    )
    return true
  }

  func recordOptOut(_ options: DevcontainerOptions, project: String) throws {
    guard let preferencePath = options.preferencePath else { return }
    guard try prompter.confirm("Always ignore devcontainer.json for project \(project)?") else {
      return
    }
    var preferences = try DevcontainerPreferences.load(preferencePath)
    let key = try preferences.setIgnored(project)
    try preferences.save(preferencePath)
    diagnostics.log(.info, "Recorded persistent devcontainer opt-out for project \(key)")
  }

  /// Fetch each OCI Feature and report its digest and install-script hash
  /// (the script runs during setup), or why it could not be resolved.
  func resolveFeatureRequests(_ translation: inout DevcontainerTranslation) {
    guard !translation.ociFeatureRequests.isEmpty else { return }
    let results = features.resolve(translation.ociFeatureRequests)
    for (request, result) in zip(translation.ociFeatureRequests, results) {
      let key = "features.\(request.rawID)"
      switch result {
      case .success(let feature):
        translation.report.push(
          key, .applied, .devcontainer, "sha256:\(feature.installed.digest.hash.rawValue)",
          "OCI feature '\(feature.installed.id)' install.sh sha256 \(feature.installed.installScriptHash.rawValue) will run during setup"
        )
        translation.ociFeatures.append(feature)
      case .failure(let error):
        translation.report.push(
          key, .invalid, .devcontainer, request.rawID,
          "failed to resolve OCI feature: \(oneLine(error))")
      }
    }
  }
}

// MARK: - Dry-run plan

extension IsoConfig {
  /// What the hardening settings resolve to after `security.preset`.
  public var securitySummary: OutputJSON {
    .object([
      ("preset", securityPreset.map { .string($0.rawValue) } ?? .null),
      ("egress", .string(egress.rawValue)), ("proxy_mode", .string(proxy.mode.rawValue)),
      ("workspace_pull", .string(workspacePull.mode.rawValue)),
      ("session_ttl", limits.sessionTTL.map { .string($0.description) } ?? .null),
    ])
  }
}

/// `up --dry-run --json` / `start --dry-run --json` (Rust
/// `json::DryRunPlan`). `report` is nil when no devcontainer applied.
public struct DevcontainerDryRunPlan: Sendable {
  public var report: DevcontainerReport?
  public var profiles: [String]
  public var guestUser: GuestUser
  public var vcpus: UInt8?
  public var memory: MiB?
  public var disk: GiB?
  /// The effective hardening settings (preset expansion), when known.
  public var security: OutputJSON?

  public init(
    report: DevcontainerReport?, profiles: [String], guestUser: GuestUser, vcpus: UInt8?,
    memory: MiB?, disk: GiB?
  ) {
    self.report = report
    self.profiles = profiles
    self.guestUser = guestUser
    self.vcpus = vcpus
    self.memory = memory
    self.disk = disk
  }

  public var json: OutputJSON {
    .object(
      [
        ("report", report?.json ?? .null),
        ("profiles", .array(profiles.map(OutputJSON.string))),
        ("guest_user", .string(guestUser.rawValue)),
        (
          "vm",
          .object([
            ("vcpus", vcpus.map { .uint(UInt64($0)) } ?? .null),
            ("mem_mib", memory.map { .uint(UInt64($0.value)) } ?? .null),
            ("disk_gib", disk.map { .uint(UInt64($0.value)) } ?? .null),
          ])
        ),
      ] + (security.map { [("security", $0)] } ?? []))
  }
}
