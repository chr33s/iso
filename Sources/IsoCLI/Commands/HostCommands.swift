import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

/// Execution-host enrollment, inspection and remote VM lifecycle
/// (docs/design/local-and-remote-hosts-spec.md sections 5 and 13).
struct HostCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "host", abstract: "Enroll, inspect and use remote execution hosts",
    subcommands: [
      HostAdd.self, HostList.self, HostInspect.self, HostRemove.self, HostEnable.self,
      HostDisable.self, HostImage.self, HostUp.self, HostPush.self, HostPull.self, HostForward.self,
      HostEditor.self, HostAgent.self, HostRun.self, HostRunResults.self, HostVM.self,
      HostShell.self, HostSession.self, HostOperation.self,
      HostMigrate.self,
    ])
}

/// Shared loading for host commands.
struct HostCommandEnvironment {
  let config: IsoConfig
  let environment: [String: String]
  let diagnostics: Diagnostics
  let output: StandardStreams
  let configPath: String?

  init(_ global: GlobalOptions) throws {
    configPath = global.config
    let configEnvironment = ConfigEnvironment.process
    config = try ConfigLoader.load(
      global.selection(environment: configEnvironment), environment: configEnvironment)
    environment = ProcessInfo.processInfo.environment
    diagnostics = Diagnostics(verbosity: global.verbose)
    output = StandardStreams()
  }

  /// `local` is this machine's host service; any other name an enrollment.
  func resolve(_ name: String) throws -> RemoteHost {
    let alias = try HostAlias(name)
    if alias.isLocal { return try RemoteHost.local(config: config, configPath: configPath) }
    return try RemoteHost.resolve(alias, config: config, environment: environment)
  }

  /// The installation a host name refers to, without contacting it.
  func hostID(_ name: String) throws -> HostID {
    let alias = try HostAlias(name)
    if alias.isLocal {
      guard let installation = try OperationStore(root: HostService.root(config)).loadInstallation()
      else { throw HostError("the local host service has no installation yet") }
      return installation.hostID
    }
    guard let enrollment = try HostRegistry(config: config).load(alias) else {
      throw HostError("host '\(alias)' is not enrolled")
    }
    return enrollment.hostID
  }

  func binding(_ host: RemoteHost, _ name: String) throws -> ClientBinding {
    let instance = try InstanceName(name)
    guard
      let binding = try ClientBindingStore(config: config).load(
        host.enrollment.hostID, instance)
    else {
      throw HostError("no instance '\(instance)' is bound on host '\(host.enrollment.alias)'")
    }
    return binding
  }

  var clientLabel: ClientLabel {
    let raw = ProcessInfo.processInfo.hostName.unicodeScalars.map {
      isSafeNameCharacter($0) ? String($0) : "-"
    }.joined()
    return (try? ClientLabel(String(raw.prefix(ClientLabel.maxLength))))
      ?? (try! ClientLabel("client"))
  }
}

struct HostAdd: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add", abstract: "Enroll a remote host after verifying its identity")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Host name used with --host") var name: String
  @Option(help: "ssh_config alias of the host (default: execution.hosts or NAME)") var ssh: String?
  @Option(name: .customLong("agent-path"), help: "Absolute path of iso on the host")
  var agentPath: String?

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let alias = try HostAlias(name)
      guard !alias.isLocal else { throw HostError("'local' is the implicit local host") }
      let configured = env.config.execution.hosts[alias]
      let sshAlias = try ssh.map { try HostAlias($0) } ?? configured?.sshAlias ?? alias
      guard let agent = try agentPath.map({ try AgentPath($0) }) ?? configured?.agentPath else {
        throw HostError("pass --agent-path or configure execution.hosts.\(alias).agent_path")
      }
      guard let sshExecutable = SSHClient(environment: env.environment).sshExecutable() else {
        throw HostError("ssh is not installed")
      }
      // ssh verifies the management host key (StrictHostKeyChecking=yes); the
      // hello then establishes the application identity recorded below.
      let client = HostControlClient(
        transport: SSHHostTransport(
          alias: sshAlias, agent: agent, ssh: sshExecutable, environment: env.environment),
        expected: nil)
      let hello = try client.hello(clientBuild: IsoVersion.string)
      guard hello.guestOperations.contains(.linux) else {
        throw HostError("host '\(alias)' does not offer Linux guests")
      }
      let registry = HostRegistry(config: env.config)
      if let existing = try registry.load(alias),
        existing.hostID != hello.hostID || existing.ownerID != hello.ownerID
      {
        throw HostControlError(
          .hostIdentityChanged,
          "host '\(alias)' now reports installation \(hello.hostID) (enrolled: \(existing.hostID)); remove it explicitly before enrolling a replacement",
          details: ["layer": "application"])
      }
      for other in try registry.list() where other.alias != alias && other.hostID == hello.hostID {
        env.output.out("Note: '\(alias)' is another alias for enrolled host '\(other.alias)'")
      }
      try registry.save(
        HostEnrollment(
          alias: alias, sshAlias: sshAlias, agentPath: agent, hostID: hello.hostID,
          ownerID: hello.ownerID, enrolledAt: UInt64(Date().timeIntervalSince1970)))
      env.output.out("Enrolled \(alias): installation \(hello.hostID), owner \(hello.ownerID)")
      switch hello.runtime {
      case .qualified(let version): env.output.out("Runtime: qualified (\(version))")
      case .unqualified(let reason):
        env.output.out("Runtime: not qualified (\(reason)); new VMs are refused until it is")
      }
    }
  }
}

struct HostList: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List enrolled hosts (no network access)")

  @OptionGroup var global: GlobalOptions

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let hosts = try HostRegistry(config: env.config).list()
      let defaultHost = env.config.execution.defaultHost
      env.output.out("local\t(implicit)\(defaultHost.isLocal ? "\tdefault" : "")")
      for host in hosts {
        var line = "\(host.alias)\tssh:\(host.sshAlias)\t\(host.hostID)"
        if host.disabled { line += "\tdisabled" }
        if host.alias == defaultHost { line += "\tdefault" }
        env.output.out(line)
      }
    }
  }
}

struct HostInspect: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inspect", abstract: "Contact a host and verify its identity and runtime")

  @OptionGroup var global: GlobalOptions
  @Argument var name: String

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let host = try env.resolve(name)
      let hello = try host.client.hello(clientBuild: IsoVersion.string)
      guard hello.hostID == host.enrollment.hostID, hello.ownerID == host.enrollment.ownerID else {
        throw HostControlError(.hostIdentityChanged, "host identity changed since enrollment")
      }
      env.output.out("Host: \(host.enrollment.alias) (ssh: \(host.enrollment.sshAlias))")
      env.output.out("Installation: \(hello.hostID)")
      env.output.out("Owner: \(hello.ownerID)")
      env.output.out("Service epoch: \(hello.epoch)")
      switch hello.runtime {
      case .qualified(let version): env.output.out("Runtime: qualified (\(version))")
      case .unqualified(let reason): env.output.out("Runtime: not qualified (\(reason))")
      }
      env.output.out("Guests: \(hello.guestOperations.map(\.rawValue).joined(separator: ", "))")
      env.output.out("Methods: \(hello.methods.map(\.rawValue).joined(separator: ", "))")
      if host.enrollment.disabled { env.output.out("State: disabled for new work") }
    }
  }
}

struct HostRemove: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Forget a host's enrollment (remote VMs are not touched)")

  @OptionGroup var global: GlobalOptions
  @Argument var name: String

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let alias = try HostAlias(name)
      let registry = HostRegistry(config: env.config)
      guard let enrollment = try registry.load(alias) else {
        throw HostError("host '\(alias)' is not enrolled")
      }
      let bound = ClientBindingStore(config: env.config).list(enrollment.hostID)
      if !bound.isEmpty {
        env.output.error(
          "warning: \(bound.count) instance binding(s) remain for \(alias); re-enroll the same installation to manage them"
        )
      }
      try registry.remove(alias)
      env.output.out("Removed \(alias)")
    }
  }
}

struct HostEnable: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "enable", abstract: "Allow new work on a disabled host")

  @OptionGroup var global: GlobalOptions
  @Argument var name: String

  func run() throws { try IsoCLI.run { try setDisabled(global, name, false) } }
}

struct HostDisable: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "disable",
    abstract: "Refuse new work on a host; observation and cleanup stay available")

  @OptionGroup var global: GlobalOptions
  @Argument var name: String

  func run() throws { try IsoCLI.run { try setDisabled(global, name, true) } }
}

private func setDisabled(_ global: GlobalOptions, _ name: String, _ disabled: Bool) throws {
  let env = try HostCommandEnvironment(global)
  let alias = try HostAlias(name)
  let registry = HostRegistry(config: env.config)
  guard var enrollment = try registry.load(alias) else {
    throw HostError("host '\(alias)' is not enrolled")
  }
  enrollment.disabled = disabled
  try registry.save(enrollment, replacing: true)
  env.output.out("\(alias): \(disabled ? "disabled" : "enabled")")
}

/// Renders a receipt; never implies a fresh observation.
func describe(_ receipt: OperationReceipt) -> String {
  var text =
    "operation \(receipt.operationID) \(receipt.method.rawValue): \(receipt.state.rawValue)"
  // `existing` is how any receipt reads back after a wait; only the
  // admission outcomes that change meaning are shown.
  if receipt.disposition == .unchanged || receipt.disposition == .existingCleanup {
    text += " (\(receipt.disposition.rawValue))"
  }
  if let outcome = receipt.outcome { text += ": \(outcome)" }
  return text
}

/// Submits a durable mutation and waits for its terminal receipt. A lost
/// reply leaves the operation id printed for an explicit same-id retry.
func submit(
  _ host: RemoteHost, _ body: HostRequestBody, operation: HostOperationID, wait timeout: Duration,
  output: StandardStreams
) throws -> OperationReceipt {
  let accepted: OperationReceipt
  do {
    accepted = try OperationReceipt(wire: try host.client.call(body, operation: operation))
  } catch  where error.code == .operationUncertain {
    throw HostError(
      "\(error.message). Retry with --operation-id \(operation), or check `iso host operation \(host.enrollment.alias) \(operation)`"
    )
  }
  if accepted.disposition == .unchanged || accepted.state.isTerminal { return accepted }
  output.error("accepted \(describe(accepted))")
  let receipt = try host.client.wait(operation, timeout: timeout)
  guard receipt.state.isTerminal else {
    throw HostError(
      "operation \(operation) is still \(receipt.state.rawValue); it continues on the host. Check `iso host operation \(host.enrollment.alias) \(operation)`"
    )
  }
  return receipt
}

struct HostOperation: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "operation", abstract: "Show (or cancel) an accepted host operation")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var operation: String
  @Flag(help: "Cancel it if no external effect has started") var cancel = false

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let id = try HostOperationID(operation)
      let body: HostRequestBody = cancel ? .operationCancel(target: id) : .operationGet(id)
      env.output.out(describe(try OperationReceipt(wire: try remote.client.call(body))))
    }
  }
}

struct HostMigrate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "migrate",
    abstract: "Preview, then activate, the host service for this machine's local data root")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Only `local` is supported") var target: String
  @Flag(help: "Prepare the handoff and let the host service complete it (never stops a VM)")
  var activate = false
  @Flag(help: "Undo a prepared migration that has not completed") var rollback = false

  func run() throws {
    try IsoCLI.run {
      guard target == "local" else { throw HostError("only `iso host migrate local` is supported") }
      let context = try CommandContext.load(global)
      if rollback {
        try HostMigration.rollback(config: context.config)
        context.output.out("Rolled back the prepared migration")
        return
      }
      let preview = try HostMigration.preview(
        config: context.config, backend: context.backend, diagnostics: context.diagnostics)
      let output = context.output
      if let installation = preview.installation {
        output.out("Installation: \(installation.hostID) (\(installation.state.rawValue))")
      } else {
        output.out("Installation: not yet created")
      }
      if let migration = preview.migration {
        output.out(
          "Migration: \(migration.state.rawValue) (\(migration.adoptions.count) adoption(s))")
      }
      for instance in preview.legacyInstances {
        var line = "legacy instance \(instance.name): \(instance.running ? "running" : "stopped")"
        if let journal = instance.pendingJournal { line += ", unfinished \(journal)" }
        line += instance.adoptable ? ", will be adopted" : ", stays on the legacy path"
        output.out(line)
      }
      if preview.blockers.isEmpty {
        output.out("Nothing blocks activation.")
      } else {
        for blocker in preview.blockers { output.out("blocked: \(blocker)") }
      }
      guard activate else { return }
      let prepared: HostMigration.MigrationRecord
      if let existing = preview.migration, existing.state == .prepared {
        prepared = existing
      } else {
        prepared = try HostMigration.prepare(config: context.config, preview: preview)
      }
      output.out(
        "Prepared: \(prepared.adoptions.count) instance(s) to adopt; starting the host service")
      // The service completes activation under its own ownership lock.
      _ = try HostService.ensureRunning(config: context.config, configPath: global.config)
      guard let record = try HostMigration.loadRecord(context.config), record.state == .active
      else {
        throw HostControlError(
          .migrationRequired,
          "the host service could not complete activation; see its log, then retry or `--rollback`")
      }
      for adoption in record.adoptions {
        output.out("adopted \(adoption.name) as \(adoption.instanceID)")
      }
      output.out("Active: manage adopted instances with `iso host vm ... local NAME`")
    }
  }
}
