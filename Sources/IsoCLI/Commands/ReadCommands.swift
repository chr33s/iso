// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import IsoSecrets

/// Why a command loads its context. Anything but `normal` shows no update
/// notice and schedules no update check.
enum LoadIntent {
  case normal
  /// Commands that resolve no `vault:` reference (dry runs of `run`, agent
  /// and image catalog commands, `run-cleanup`): no secret store either.
  case preview
  /// `setup`, `up` and `start --dry-run`. Translating a devcontainer may fetch
  /// it from a private git repository with that repository's `github.pat`
  /// entry, so the secret store stays attached; it unlocks only if that
  /// entry is a `vault:` reference.
  case devcontainerPreview

  static func dryRun(_ dryRun: Bool) -> Self { dryRun ? .devcontainerPreview : .normal }

  var checksForUpdates: Bool { self == .normal }
  var attachesSecretStore: Bool { self != .preview }
}

extension CommandContext {
  static func load(
    _ global: GlobalOptions, override: (IsoConfig) throws -> IsoConfig = { $0 },
    intent: LoadIntent = .normal
  ) throws -> CommandContext {
    let environment = ConfigEnvironment.process
    try checkDataRoot(global, environment)
    let config = try override(
      ConfigLoader.load(global.selection(environment: environment), environment: environment))
    let diagnostics = Diagnostics(verbosity: global.verbose)
    if intent.checksForUpdates {
      AdminSupport.updateNotice(config, environment: environment, diagnostics: diagnostics)
    }
    if intent.attachesSecretStore {
      // Every credential resolver in this process reads `vault:` references
      // through the one store.
      CredentialResolver.processSecrets = StoreSecretResolver.shared(
        EnclaveStore(directory: config.dataDirectory.appending("secrets").path))
    }
    return CommandContext(
      environment: environment, config: config,
      backend: AppleBackend(
        config: config, environment: environment.variables, executable: CommandLine.executablePath,
        diagnostics: diagnostics),
      output: StandardStreams(), diagnostics: diagnostics,
      ssh: SSHClient(environment: environment.variables))
  }
}

/// Refuses a default data root that is not a real directory.
func checkDataRoot(_ global: GlobalOptions, _ environment: ConfigEnvironment) throws {
  guard let home = environment.home else { throw HostError("Cannot determine home directory") }
  try DataRoot.check(home: home, usesDefaultConfiguration: global.config == nil)
}

extension CommandLine {
  static var executablePath: String? {
    var size = UInt32(PATH_MAX)
    var buffer = [CChar](repeating: 0, count: Int(size))
    guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }
}

func padded(_ text: String, _ width: Int) -> String {
  let count = text.unicodeScalars.count
  return count >= width ? text : text + String(repeating: " ", count: width - count)
}

/// Render the error context chain on one line.
func oneLine(_ error: any Error) -> String {
  error.contextError?.alternate ?? "\(error)"
}

enum InstanceState: String {
  /// `unhealthy`: the sandbox runs, but its filtered readiness proof failed.
  case running, stopped, unhealthy, unknown
}

// MARK: - list

struct List: MachineCommand {
  static let configuration = CommandConfiguration(
    abstract: "List instances by name and state", aliases: ["ls"])

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Emit legacy unversioned JSON instead of the text table") var json = false
  @Flag(
    name: .customLong("all-hosts"),
    help: "Also list every enrolled remote host; unreachable hosts are reported, not hidden")
  var allHosts = false

  func validate() throws {
    try global.rejectLegacyJSON(json)
    if allHosts && json {
      throw ArgumentParser.ValidationError("--all-hosts needs --output json or text")
    }
  }

  func run() throws {
    if global.output == .json {
      return try IsoCLI.run(global, Self.self) {
        let context = try CommandContext.load(global)
        let local = try Self.rows(context)
        guard allHosts else {
          return MachineListResult(instances: local.map { MachineInstance($0, $1) })
        }
        let remote = try RemoteListing.collect(
          config: context.config, environment: ProcessInfo.processInfo.environment)
        return MachineListResult(
          instances: local.map { MachineInstance(local: $0, $1) }
            + remote.rows.map(MachineInstance.init),
          hostFailures: remote.failures.map {
            .init(host: $0.host.rawValue, code: $0.error.code.rawValue, message: $0.error.message)
          })
      }
    }
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      try Self.run(context, json: json)
      if allHosts { try Self.runRemote(context) }
    }
  }

  static func runRemote(_ context: CommandContext) throws {
    let remote = try RemoteListing.collect(
      config: context.config, environment: ProcessInfo.processInfo.environment)
    for row in remote.rows {
      let instance = MachineInstance(row)
      let host = instance.remote?.host ?? ""
      let suffix = instance.remote?.reachability == "unreachable" ? " (host unreachable)" : ""
      context.output.out(padded(instance.name, 16) + " " + instance.state + "  @" + host + suffix)
    }
    for failure in remote.failures {
      context.diagnostics.warn("host '\(failure.host)': \(failure.error.message)")
    }
  }

  /// Sorted by name; a state that cannot be probed is `unknown`, and an
  /// unhealthy one names its failed proof, each with a warning.
  static func rows(_ context: CommandContext) throws -> [(Instance, InstanceState)] {
    let instances = try context.listInstances().sorted {
      $0.name.rawValue.utf8.lexicographicallyPrecedes($1.name.rawValue.utf8)
    }
    return instances.map { instance -> (Instance, InstanceState) in
      do {
        switch try context.backend.probeHealth(instance) {
        case .stopped: return (instance, .stopped)
        case .running: return (instance, .running)
        case .unhealthy(let failure):
          context.diagnostics.warn("'\(instance.name)' is unhealthy: \(failure.reason)")
          return (instance, .unhealthy)
        }
      } catch {
        context.diagnostics.warn(
          "Could not determine the state of '\(instance.name)': \(oneLine(error))")
        return (instance, .unknown)
      }
    }
  }

  static func run(_ context: CommandContext, json: Bool) throws {
    let rows = try rows(context)
    if json {
      try context.output.writeJSON(
        rows.map {
          InstanceListOutput(name: $0.0.name.rawValue, state: $0.1.rawValue)
        })
      return
    }
    guard !rows.isEmpty else {
      context.output.out("No instances found")
      return
    }
    context.output.out(padded("NAME", 16) + " STATE")
    for (instance, state) in rows {
      context.output.out(padded(instance.name.rawValue, 16) + " " + state.rawValue)
    }
  }
}

// MARK: - status

struct Status: MachineCommand {
  static let configuration = CommandConfiguration(abstract: "Show VM status")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Instance name (shows all if omitted)", transform: parseInstanceName) var name:
    InstanceName?
  @Flag(help: "Emit legacy unversioned JSON instead of the text output") var json = false

  func validate() throws { try global.rejectLegacyJSON(json) }

  func run() throws {
    if global.output == .json {
      return try IsoCLI.run(global, Self.self) {
        MachineStatusResult(try Self.collect(CommandContext.load(global), name: name))
      }
    }
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      // Only the text report of one instance shows the runtime description.
      let report = try Self.collect(context, name: name, depth: json ? .summary : .detailed)
      if json {
        try context.output.writeJSON(report.legacyJSON)
      } else {
        report.text.forEach(context.output.out)
      }
    }
  }

  /// How much one named instance is probed: the text report also describes
  /// a running instance and reports a stopped one without re-probing it.
  enum Depth { case summary, detailed }

  /// One collection per invocation; every renderer reads the same rows.
  enum Report {
    case one(Row)
    case all([Row])

    var legacyJSON: LegacyStatusJSON {
      switch self {
      case .one(let row): .one(StatusOutput(row))
      case .all(let rows): .all(rows.map(StatusOutput.init))
      }
    }

    var text: [String] {
      switch self {
      case .one(let row):
        let header = "Instance '\(row.instance.name)' (\(row.state.rawValue))"
        let identity = "\n  Backend: \(AppleBackend.name)\n  Image: \(row.instance.image)"
        switch row.state {
        case .unhealthy: return [header + identity + "\n  Reason: \(row.reason ?? "")"]
        case .running:
          let usage = row.usage.map(\.display) ?? "Guest usage: unavailable"
          return [(row.detail ?? header) + "\n  " + usage]
        case .stopped, .unknown: return [header + identity]
        }
      case .all(let rows):
        guard !rows.isEmpty else { return ["No instances found"] }
        return rows.map { row in
          let usage = row.usage.map { "  " + $0.summary } ?? ""
          return
            "\(row.instance.name) \(padded(row.state.rawValue, 10)) \(row.instance.image) \(AppleBackend.name)\(usage)"
        }
      }
    }
  }

  static func collect(_ context: CommandContext, name: InstanceName?, depth: Depth = .summary)
    throws -> Report
  {
    if let name {
      let instance = try InstanceStore.resolve(context.config, name: name)
      return .one(try status(context, instance, depth: depth))
    }
    return .all(try context.listInstances().map { listedStatus(context, $0) })
  }

  struct Row {
    let instance: Instance
    let state: InstanceState
    let usage: ResourceUsage?
    /// Why an unhealthy instance failed its readiness proof.
    var reason: String? = nil
    /// The runtime's description of a running instance (detailed depth only).
    var detail: String? = nil
    /// Set only for a brokered instance: its creation-time transport and,
    /// when running and gate-approved, the effective boot's state.
    var brokered: BrokeredStatus? = nil
  }

  struct BrokeredStatus {
    let requestedTransport: NetworkTransport
    let effective: BrokeredView?
  }

  /// Nil for a vmnet instance (its records say nothing of a transport).
  static func brokeredStatus(
    _ context: CommandContext, _ instance: Instance, running: AppleBackend.Running?
  ) -> BrokeredStatus? {
    let recorded: NetworkPolicy?
    do { recorded = try NetworkPolicy.load(instance) } catch {
      context.diagnostics.warn(
        "Could not read the network policy record of '\(instance.name)': \(oneLine(error))")
      return nil
    }
    guard recorded?.recordedTransport == .brokered else { return nil }
    return BrokeredStatus(
      requestedTransport: context.config.network.transport,
      effective: running.flatMap { try? context.backend.brokeredView($0) })
  }

  static func status(_ context: CommandContext, _ instance: Instance, depth: Depth = .summary)
    throws -> Row
  {
    let running: AppleBackend.Running?
    do {
      running = try context.backend.asRunning(instance)
    } catch let failure as InstanceUnhealthy {
      return Row(
        instance: instance, state: .unhealthy, usage: nil, reason: failure.reason,
        brokered: brokeredStatus(context, instance, running: nil))
    }
    if let running {
      let detail = depth == .detailed ? try context.backend.describe(running) : nil
      return Row(
        instance: instance, state: .running,
        usage: ResourceUsage.query(context.ssh, running.target), detail: detail,
        brokered: brokeredStatus(context, instance, running: running))
    }
    // Stopped: re-probe only for its error side (journal, booting).
    if depth == .summary { _ = try context.backend.probeRunning(instance) }
    return Row(
      instance: instance, state: .stopped, usage: nil,
      brokered: brokeredStatus(context, instance, running: nil))
  }

  static func listedStatus(_ context: CommandContext, _ instance: Instance) -> Row {
    do {
      return try status(context, instance)
    } catch {
      context.diagnostics.warn(
        "Could not determine the state of '\(instance.name)': \(oneLine(error))")
      return Row(instance: instance, state: .unknown, usage: nil)
    }
  }
}

/// `status --json`: one object for a named instance, an array otherwise.
enum LegacyStatusJSON: Encodable {
  case one(StatusOutput)
  case all([StatusOutput])

  func encode(to encoder: any Encoder) throws {
    switch self {
    case .one(let value): try value.encode(to: encoder)
    case .all(let values): try values.encode(to: encoder)
    }
  }
}

func parseInstanceName(_ text: String) throws -> InstanceName {
  do { return try InstanceName(text) } catch { throw ArgumentParser.ValidationError(error.message) }
}

// MARK: - images

struct Images: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List or manage golden images",
    subcommands: [ImagesInspect.self, ImagesCache.self])

  @OptionGroup var global: GlobalOptions
  @Option(help: "Delete a named image", transform: parseImageName) var delete: ImageName?
  @Flag(help: "Emit machine-readable JSON instead of the text table") var json = false

  /// The listing's JSON shape does not describe a deletion.
  func validate() throws {
    if delete != nil && json {
      throw UsageError("the argument '--delete <DELETE>' cannot be used with '--json'")
    }
  }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      if let delete { return try context.backend.destroyImage(delete) }
      try Self.run(context, json: json)
    }
  }

  static func run(_ context: CommandContext, json: Bool) throws {
    let images = try ImageStore.list(context.config) { raw, error in
      context.diagnostics.warn("Skipping invalid image dir '\(raw)': \(error)")
    }
    if json {
      try context.output.writeJSON(
        images.map {
          ImageListOutput(
            name: $0.name.rawValue, profiles: $0.config?.profiles ?? [],
            created: $0.config?.created)
        })
      return
    }
    guard !images.isEmpty else {
      context.output.out("No images found. Run `iso setup` to build one.")
      return
    }
    for image in images {
      let profiles =
        switch image.config {
        case let config? where !config.profiles.isEmpty: config.profiles.joined(separator: ", ")
        case .some: "none"
        case nil: "unknown"
        }
      context.output.out(
        "\(image.name) profiles: \(padded(profiles, 30)) created: \(padded(image.config?.created ?? "unknown", 24)) size: n/a (runtime image store)"
      )
    }
  }
}

struct ImagesInspect: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inspect",
    abstract: "Show host-recorded image provenance. Runtime cache details may be unavailable.")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Image name", transform: parseImageName) var name: ImageName
  @Flag(help: "Emit JSON") var json = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global, intent: .preview)
      let report = try ImageInspectionReport.inspect(context.config, name)
      if json {
        try context.output.writeJSON(report)
      } else {
        for line in report.lines { context.output.out(line) }
      }
    }
  }
}

struct ImagesCache: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "cache", abstract: "Report image-cache records without deleting them",
    subcommands: [ImagesCacheStatus.self])
}

struct ImagesCacheStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Distinguish manifests from instance records. Runtime allocation is not measured.")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Emit JSON") var json = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global, intent: .preview)
      let report = try ImageInspectionReport.cacheStatus(context.config)
      if json {
        try context.output.writeJSON(report)
      } else {
        for line in report.lines { context.output.out(line) }
      }
    }
  }
}

// MARK: - profiles

struct ProfilesCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "profiles", abstract: "List or inspect available profiles",
    subcommands: [ProfilesList.self, ProfilesShow.self], defaultSubcommand: ProfilesList.self)
}

struct ProfilesList: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List all available profiles (builtin and custom)")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Emit machine-readable JSON instead of the text listing") var json = false

  func run() throws { try IsoCLI.run { try Self.run(CommandContext.load(global), json: json) } }

  static func run(_ context: CommandContext, json: Bool) throws {
    let (builtin, custom) = Profiles.listing(context.config)
    if json {
      try context.output.writeJSON(
        ProfilesOutput(
          builtin: builtin.map(ProfileOutput.init), custom: custom.map(ProfileOutput.init)))
      return
    }
    // Width is measured in bytes; padding counts Unicode scalars.
    let width = (builtin + custom).map { $0.name.utf8.count }.max() ?? 0
    context.output.out("Builtin:")
    for entry in builtin { context.output.out("  \(padded(entry.name, width)) \(entry.summary)") }
    if !custom.isEmpty {
      context.output.out("")
      context.output.out("Custom:")
      for entry in custom { context.output.out("  \(padded(entry.name, width)) \(entry.summary)") }
    }
  }
}

struct ProfilesShow: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show", abstract: "Show the full definition of a profile")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Profile name to inspect") var name: String

  func run() throws { try IsoCLI.run { try Self.run(CommandContext.load(global), name: name) } }

  static func run(_ context: CommandContext, name: String) throws {
    let profile = try Profiles.lookup(name, config: context.config)
    let list = { (values: [String]) in values.isEmpty ? "(none)" : values.joined(separator: ", ") }
    context.output.out(
      "Profile: \(name) (\(context.config.profiles[name] != nil ? "custom" : "builtin"))")
    context.output.out("  apt_packages: \(list(profile.aptPackages))")
    context.output.out("  pre_install:  \(Profiles.scriptSummary(profile.preInstall))")
    context.output.out("  post_install: \(Profiles.scriptSummary(profile.postInstall))")
    context.output.out("  marketplaces: \(list(profile.marketplaces))")
    context.output.out("  plugins:      \(list(profile.plugins))")
  }
}

// MARK: - proxy status

struct ProxyCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "proxy", abstract: "Manage the credential-injecting proxy",
    subcommands: [ProxySetup.self, ProxyStatus.self])
}

struct ProxyStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract:
      "Show what each VM's agents resolve to (per-VM override → default → off), with credentials redacted"
  )

  @OptionGroup var global: GlobalOptions
  @Option(
    name: .customLong("vm"),
    help: ArgumentHelp(
      "Show the effective resolution for a single VM instead of all", valueName: "NAME"))
  var vm: String?

  func run() throws { try IsoCLI.run { try Self.run(CommandContext.load(global), vm: vm) } }

  static func run(_ context: CommandContext, vm: String?) throws {
    let out = context.output
    if let vm {
      let name: InstanceName
      do { name = try InstanceName(vm) } catch {
        throw ContextError("'\(vm)' is not a valid instance name", cause: error)
      }
      let instance = try InstanceStore.resolve(context.config, name: name)
      writeVM(out, instance.name.rawValue, try ProxyState.load(instance), context.config.proxy)
      let routed = try GuestEnvState.tryLoad(instance)?.providerSecrets() ?? [:]
      for provider in ProxyProvider.allCases {
        guard let secret = routed[provider] else { continue }
        out.out(
          "  \(padded(provider.rawValue, 10)) provider secret from --env: \(secret.variable)={vault:\(secret.name)} (takes precedence)"
        )
      }
    } else {
      out.out("Credential proxy — defaults (proxy in the configuration file):")
      for provider in ProxyProvider.allCases {
        out.out(
          "  \(padded(provider.rawValue, 10)) \(ProxyResolution.resolve(provider, state: nil, config: context.config.proxy).description)"
        )
      }
      var overrides: [(Instance, ProxyState)] = []
      for instance in try context.listInstances() {
        do {
          let state = try ProxyState.load(instance)
          if !state.isEmpty { overrides.append((instance, state)) }
        } catch {
          context.diagnostics.warn(
            "Skipping '\(instance.name)' in proxy status — unreadable proxy.json: \(oneLine(error))"
          )
        }
      }
      if overrides.isEmpty {
        out.out("\nNo per-VM overrides.")
      } else {
        out.out("\nPer-VM overrides:")
        for (instance, state) in overrides {
          writeVM(out, instance.name.rawValue, state, context.config.proxy)
        }
      }
    }
    out.out(
      "\nValues are cmd: references, not secrets. Each running VM in remote model mode routes its agents through the proxy; the raw credential stays on the host."
    )
  }

  static func writeVM(
    _ out: any OutputStreams, _ vm: String, _ state: ProxyState, _ config: ProxyConfig
  ) {
    out.out("  \(vm):")
    for provider in ProxyProvider.allCases {
      out.out(
        "    \(padded(provider.rawValue, 10)) \(ProxyResolution.resolve(provider, state: state, config: config).description)"
      )
    }
  }
}

// MARK: - logs

struct Logs: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Stream VM serial console logs")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(name: .shortAndLong, help: "Follow log output") var follow = false

  func run() throws {
    try IsoCLI.run { try Self.run(CommandContext.load(global), name: name, follow: follow) }
  }

  static func run(_ context: CommandContext, name: InstanceName?, follow: Bool) throws {
    let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
    try context.backend.streamLogs(
      running, follow: follow, line: context.output.out, stderr: context.output.error)
  }
}

// MARK: - audit

struct Audit: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show the boundary events recorded for an instance (metadata only, never values)")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Print an advisory JSONC fragment that narrows what was observed")
  var suggestConfig = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      let lines = try BoundaryAudit.lines(instance)
      let events = BoundaryAudit.events(from: lines)
      if suggestConfig {
        BoundaryAudit.suggestConfig(events).forEach(context.output.out)
        return
      }
      if events.isEmpty {
        context.output.error("No boundary events recorded for '\(instance.name)' yet.")
      }
      for line in lines {
        context.output.out(neutralizeControls(line))
      }
    }
  }
}
