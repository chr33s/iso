// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoopConfiguration
import CoopCore
import CoopHost
import Foundation

/// What a command runs with: one validated configuration (S-02), the
/// backend, and its output and diagnostic streams.
struct CommandContext {
  let environment: ConfigEnvironment
  let config: CoopConfig
  let backend: AppleBackend
  let output: any OutputStreams
  let diagnostics: Diagnostics
  let ssh: SSHClient

  static func load(_ global: GlobalOptions, override: (CoopConfig) throws -> CoopConfig = { $0 })
    throws
    -> CommandContext
  {
    let environment = ConfigEnvironment.process
    try checkDataRoot(global, environment)
    let config = try override(
      ConfigLoader.load(global.selection(environment: environment), environment: environment))
    let diagnostics = Diagnostics(verbosity: global.verbose)
    AdminSupport.updateNotice(config, environment: environment, diagnostics: diagnostics)
    return CommandContext(
      environment: environment, config: config,
      backend: AppleBackend(
        config: config, environment: environment.variables, executable: CommandLine.executablePath,
        diagnostics: diagnostics),
      output: StandardStreams(), diagnostics: diagnostics,
      ssh: SSHClient(environment: environment.variables))
  }

  func listInstances() throws -> [Instance] {
    try InstanceStore.list(config) { path, error in
      diagnostics.warn(
        "Skipping corrupted instance dir \(path) (\(error)). Remove it manually or run `destroy --all`."
      )
    }
  }
}

/// Refuses a default `~/.coop` that holds upstream coop state.
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

/// Rust `{:<width$}` on a `&str`: pad to `width` characters.
func padded(_ text: String, _ width: Int) -> String {
  let count = text.unicodeScalars.count
  return count >= width ? text : text + String(repeating: " ", count: width - count)
}

/// anyhow `{:#}`: the context chain on one line.
func oneLine(_ error: any Error) -> String {
  (error as? ContextError)?.alternate ?? "\(error)"
}

enum InstanceState: String {
  case running, stopped, unknown
}

// MARK: - list

struct List: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List instances by name and state", aliases: ["ls"])

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Emit machine-readable JSON instead of the text table") var json = false

  func run() throws { try CoopCLI.run { try Self.run(CommandContext.load(global), json: json) } }

  static func run(_ context: CommandContext, json: Bool) throws {
    let instances = try context.listInstances().sorted {
      $0.name.rawValue.utf8.lexicographicallyPrecedes($1.name.rawValue.utf8)
    }
    let rows = instances.map { instance -> (Instance, InstanceState) in
      do {
        return (instance, try context.backend.probeRunning(instance) ? .running : .stopped)
      } catch {
        context.diagnostics.warn(
          "Could not determine the state of '\(instance.name)': \(oneLine(error))")
        return (instance, .unknown)
      }
    }
    if json {
      context.output.write(
        OutputJSON.array(
          rows.map {
            .object([("name", .string($0.0.name.rawValue)), ("state", .string($0.1.rawValue))])
          }
        ).rendered())
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

struct Status: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Show VM status")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Instance name (shows all if omitted)", transform: parseInstanceName) var name:
    InstanceName?
  @Flag(help: "Emit machine-readable JSON instead of the text output") var json = false

  func run() throws {
    try CoopCLI.run { try Self.run(CommandContext.load(global), name: name, json: json) }
  }

  static func run(_ context: CommandContext, name: InstanceName?, json: Bool) throws {
    if let name {
      let instance = try InstanceStore.resolve(context.config, name: name)
      if json {
        context.output.write(statusJSON(try status(context, instance)).rendered())
        return
      }
      guard let running = try context.backend.asRunning(instance) else {
        context.output.out(
          "Instance '\(instance.name)' (stopped)\n  Backend: \(AppleBackend.name)\n  Image: \(instance.image)"
        )
        return
      }
      var report = try context.backend.describe(running)
      if let usage = ResourceUsage.query(context.ssh, running.target) {
        report += "\n  \(usage.display)"
      } else {
        report += "\n  Guest usage: unavailable"
      }
      context.output.out(report)
      return
    }
    let instances = try context.listInstances()
    let rows = instances.map { listedStatus(context, $0) }
    if json {
      context.output.write(OutputJSON.array(rows.map(statusJSON)).rendered())
      return
    }
    guard !rows.isEmpty else {
      context.output.out("No instances found")
      return
    }
    for row in rows {
      // The baseline pads only the state column (name and image are
      // newtypes whose Display ignores width).
      let usage = row.usage.map { "  " + $0.summary } ?? ""
      context.output.out(
        "\(row.instance.name) \(padded(row.state.rawValue, 10)) \(row.instance.image) \(AppleBackend.name)\(usage)"
      )
    }
  }

  struct Row {
    let instance: Instance
    let state: InstanceState
    let usage: ResourceUsage?
  }

  static func status(_ context: CommandContext, _ instance: Instance) throws -> Row {
    if let running = try context.backend.asRunning(instance) {
      return Row(
        instance: instance, state: .running, usage: ResourceUsage.query(context.ssh, running.target)
      )
    }
    // Stopped: re-probe only for its error side (journal, booting).
    _ = try context.backend.probeRunning(instance)
    return Row(instance: instance, state: .stopped, usage: nil)
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

  static func statusJSON(_ row: Row) -> OutputJSON {
    let usage: OutputJSON =
      row.usage.map {
        .object([
          ("load_1m", .double($0.load1m)), ("mem_used_mib", .uint($0.memUsedMiB)),
          ("mem_total_mib", .uint($0.memTotalMiB)), ("disk_used_mib", .uint($0.diskUsedMiB)),
          ("disk_total_mib", .uint($0.diskTotalMiB)),
        ])
      } ?? .null
    return .object([
      ("name", .string(row.instance.name.rawValue)), ("state", .string(row.state.rawValue)),
      ("image", .string(row.instance.image.rawValue)), ("backend", .string(AppleBackend.name)),
      ("usage", usage),
    ])
  }
}

func parseInstanceName(_ text: String) throws -> InstanceName {
  do { return try InstanceName(text) } catch { throw ArgumentParser.ValidationError(error.message) }
}

// MARK: - images

struct Images: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "List or manage golden images")

  @OptionGroup var global: GlobalOptions
  @Option(help: "Delete a named image", transform: parseImageName) var delete: ImageName?
  @Flag(help: "Emit machine-readable JSON instead of the text table") var json = false

  func run() throws {
    try CoopCLI.run {
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
      // Image content lives in the runtime's store, so no size is reported.
      context.output.write(
        OutputJSON.array(
          images.map {
            .object([
              ("name", .string($0.name.rawValue)),
              ("profiles", .array(($0.config?.profiles ?? []).map(OutputJSON.string))),
              ("created", .optional($0.config?.created)), ("size_bytes", .null),
            ])
          }
        ).rendered())
      return
    }
    guard !images.isEmpty else {
      context.output.out("No images found. Run `coop setup` to build one.")
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

  func run() throws { try CoopCLI.run { try Self.run(CommandContext.load(global), json: json) } }

  static func run(_ context: CommandContext, json: Bool) throws {
    let (builtin, custom) = Profiles.listing(context.config)
    if json {
      let entry = { (e: Profiles.ListEntry) in
        OutputJSON.object([("name", .string(e.name)), ("summary", .string(e.summary))])
      }
      context.output.write(
        OutputJSON.object([
          ("builtin", .array(builtin.map(entry))), ("custom", .array(custom.map(entry))),
        ]).rendered())
      return
    }
    // Width is in bytes (Rust `len()`); padding counts characters.
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

  func run() throws { try CoopCLI.run { try Self.run(CommandContext.load(global), name: name) } }

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

  func run() throws { try CoopCLI.run { try Self.run(CommandContext.load(global), vm: vm) } }

  static func run(_ context: CommandContext, vm: String?) throws {
    let out = context.output
    if let vm {
      let name: InstanceName
      do { name = try InstanceName(vm) } catch {
        throw ContextError("'\(vm)' is not a valid instance name", cause: error)
      }
      let instance = try InstanceStore.resolve(context.config, name: name)
      writeVM(out, instance.name.rawValue, try ProxyState.load(instance), context.config.proxy)
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
    try CoopCLI.run { try Self.run(CommandContext.load(global), name: name, follow: follow) }
  }

  static func run(_ context: CommandContext, name: InstanceName?, follow: Bool) throws {
    let running = try context.backend.resolveRunning(name, instances: try context.listInstances())
    try context.backend.streamLogs(
      running, follow: follow, line: context.output.out, stderr: context.output.error)
  }
}
