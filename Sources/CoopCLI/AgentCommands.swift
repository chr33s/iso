// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoopConfiguration
import CoopCore
import CoopHost
import Foundation

// MARK: - Shared wiring

extension CommandContext {
  /// Bootstrap and session services for this command.
  var agents: AgentBootstrap {
    let resolver = CredentialResolver(environment: environment.variables)
    return AgentBootstrap(
      config: config, client: ssh, environment: environment.variables, home: environment.home,
      resolver: resolver,
      proxies: ProxyLauncher(
        environment: environment.variables, resolver: resolver, diagnostics: diagnostics,
        coopExecutable: CommandLine.executablePath),
      github: HostGitHubTokens(
        config: config, environment: environment.variables, diagnostics: diagnostics),
      diagnostics: diagnostics, secrets: secretResolver)
  }
}

/// Interactive prompts on stderr; a non-TTY stdin declines.
enum TerminalPrompt {
  static func readReply() -> String? {
    readLine(strippingNewline: true)
  }

  static func confirm(_ prompt: String) -> Bool {
    guard isatty(0) == 1 else { return false }
    FileHandle.standardError.write(Data("\(prompt) [y/N] ".utf8))
    let reply = (readReply() ?? "").trimmingUnicodeWhitespace().lowercased()
    return reply == "y" || reply == "yes"
  }

  /// The trimmed reply; nil for an empty reply or a non-TTY stdin.
  static func line(_ prompt: String) -> String? {
    guard isatty(0) == 1 else { return nil }
    FileHandle.standardError.write(Data("\(prompt): ".utf8))
    let reply = (readReply() ?? "").trimmingUnicodeWhitespace()
    return reply.isEmpty ? nil : reply
  }

  /// A secret typed with echo off (`stty -echo`, restored afterwards).
  static func secret() throws -> Secret<String> {
    FileHandle.standardError.write(Data("Paste token: ".utf8))
    var saved = termios()
    let echoOff = isatty(0) == 1 && tcgetattr(0, &saved) == 0
    if echoOff {
      var quiet = saved
      quiet.c_lflag &= ~tcflag_t(ECHO)
      tcsetattr(0, TCSANOW, &quiet)
    }
    let reply = readReply()
    if echoOff {
      tcsetattr(0, TCSANOW, &saved)
      FileHandle.standardError.write(Data("\n".utf8))
    }
    let token = (reply ?? "").trimmingUnicodeWhitespace()
    guard !token.isEmpty else { throw HostError("No token entered") }
    return Secret(token)
  }
}

// MARK: - claude / claude-agents / codex

/// Trailing arguments as clap delivered them: a leading `--` separator is
/// not itself an argument.
func passthrough(_ arguments: [String]) -> [String] {
  arguments.first == "--" ? Array(arguments.dropFirst()) : arguments
}

/// clap's `trailing_var_arg`: `--ask` ahead of the first extra argument is
/// still the flag (`coop codex NAME --ask -- ARGS`).
func splitAsk(_ ask: Bool, _ arguments: [String]) -> (Bool, [String]) {
  var rest = arguments[...]
  var ask = ask
  while rest.first == "--ask" {
    ask = true
    rest = rest.dropFirst()
  }
  return (ask, passthrough(Array(rest)))
}

struct ClaudeCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude",
    abstract: "Launch Claude Code inside the VM (skips permissions by default)")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Prompt for permissions instead of skipping them") var ask = false
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Argument(parsing: .captureForPassthrough, help: "Extra arguments passed to `claude`")
  var args: [String] = []

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let (_, session) = try context.agents.openSession(
        context.backend, name: name, instances: context.listInstances())
      // The managed settings default to bypass mode; --ask overrides it.
      let (ask, args) = splitAsk(ask, args)
      let extra = ask ? ["--permission-mode", "default"] + args : args
      try InteractiveSSH.run(
        context.ssh, session, [session.target.user.claudeBinary.rawValue] + extra,
        diagnostics: context.diagnostics)
    }
  }
}

struct ClaudeAgentsCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "claude-agents",
    abstract: "Open the Claude Code agent view inside the VM (`claude agents`)",
    discussion:
      "If the remote TUI stops responding, type Enter, then ~. to disconnect. If your terminal remains broken afterward, run `stty sane`.",
    aliases: ["ca"])

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Argument(parsing: .captureForPassthrough, help: "Extra arguments passed to `claude agents`")
  var args: [String] = []

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let (_, session) = try context.agents.openSession(
        context.backend, name: name, instances: context.listInstances())
      try InteractiveSSH.run(
        context.ssh, session,
        [session.target.user.claudeBinary.rawValue, "agents"] + passthrough(args),
        diagnostics: context.diagnostics)
    }
  }
}

struct CodexCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "codex",
    abstract: "Launch Codex inside the VM (bypasses the sandbox and approvals by default)")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Keep Codex's sandbox and approval prompts instead of bypassing them") var ask =
    false
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Argument(parsing: .captureForPassthrough, help: "Extra arguments passed to `codex`")
  var args: [String] = []

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let (running, session) = try context.agents.openSession(
        context.backend, name: name, instances: context.listInstances())
      let (ask, args) = splitAsk(ask, args)
      var binary = GuestBinaries.codex
      if context.config.codexAuth == .chatgpt {
        let state = try ModelState.loadOrDefault(running.instance)
        try CodexChecks.ensureRemoteAuthConsistent(
          context.config, instance: running.instance, modelState: state)
        try CodexChecks.ensureAccountGuestSupport(context.ssh, session.target)
        // Without the keyring setting the wrapper would pass through and
        // `codex login` would write a plaintext token.
        try CodexChecks.ensureKeyringConfigured(context.ssh, session.target)
        binary = GuestBinaries.codexAccount
      }
      try InteractiveSSH.run(
        context.ssh, session,
        [binary.rawValue] + CodexChecks.launchArguments(ask: ask, args),
        diagnostics: context.diagnostics)
    }
  }
}

// MARK: - model

struct ModelCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "model", abstract: "Show or switch a VM's model backend (cloud vs. local)",
    usage: "coop model [NAME] [COMMAND]",
    discussion: """
      Commands:
        local   Route this VM's agents at a host-side local model server
        remote  Restore cloud defaults (Anthropic / `OpenAI`)
      """)

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: ArgumentHelp(
      "Instance name (required if multiple instances exist), then `local` or `remote`",
      valueName: "NAME"))
  var words: [String] = []

  /// `[NAME] [local|remote]`; a leading `local`/`remote` is the command.
  static func parse(_ words: [String]) throws -> (InstanceName?, ModelMode?) {
    var rest = words[...]
    var name: InstanceName?
    if let first = rest.first, ModelMode(rawValue: first) == nil {
      do { name = try InstanceName(first) } catch {
        throw UsageError("invalid value '\(first)' for '[NAME]': \(error.message)")
      }
      rest = rest.dropFirst()
    }
    var mode: ModelMode?
    if let command = rest.first {
      guard let parsed = ModelMode(rawValue: command) else {
        throw UsageError("unrecognized subcommand '\(command)'")
      }
      mode = parsed
      rest = rest.dropFirst()
    }
    if let extra = rest.first { throw UsageError("unexpected argument '\(extra)' found") }
    return (name, mode)
  }

  func validate() throws { _ = try Self.parse(words) }

  func run() throws {
    let (name, mode) = try Self.parse(words)
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      switch mode {
      case nil: try Self.status(context, instance)
      case .local?: try Self.setLocal(context, instance)
      case .remote?: try Self.setRemote(context, instance)
      }
    }
  }

  static func status(_ context: CommandContext, _ instance: Instance) throws {
    let state = try ModelState.loadOrDefault(instance)
    context.output.out("Instance: \(instance.name)")
    context.output.out("Mode:     \(state.mode.rawValue)")
    for (label, endpoint) in [
      ("Claude", state.resolvedClaude(context.config.claude)),
      ("Codex", state.resolvedCodex(context.config.codex)),
    ] {
      context.output.out(try toolLine(label, mode: state.mode, endpoint: endpoint))
    }
  }

  static func toolLine(_ label: String, mode: ModelMode, endpoint: LocalModel?) throws -> String {
    switch (mode, endpoint) {
    case (.local, let endpoint?):
      let plan = try LocalEndpoints.plan(endpoint.hostURL)
      let via = plan.tunnel != nil ? " (via SSH reverse tunnel)" : ""
      return "\(padded(label, 9)) local — \(endpoint.model) @ \(plan.guestURL)\(via)"
    case (.local, nil): return "\(padded(label, 9)) cloud (no local endpoint configured)"
    case (.remote, _): return "\(padded(label, 9)) cloud"
    }
  }

  static func setLocal(_ context: CommandContext, _ instance: Instance) throws {
    let config = context.config
    var state = try ModelState.loadOrDefault(instance)
    state.mode = .local
    // Offer each tool that resolves no endpoint; a non-TTY declines.
    if state.resolvedClaude(config.claude) == nil, let endpoint = try promptEndpoint("Claude") {
      state.claudeEndpoint = endpoint
    }
    if state.resolvedCodex(config.codex) == nil, let endpoint = try promptEndpoint("Codex") {
      state.codexEndpoint = endpoint
    }
    guard state.resolvedClaude(config.claude) != nil || state.resolvedCodex(config.codex) != nil
    else {
      throw HostError(
        "No local model endpoint configured for '\(instance.name)'.\nSet claude.local_model or codex.local_model in the configuration file, or run `coop model \(instance.name) local` in an interactive terminal to enter one."
      )
    }
    if state.resolvedCodex(config.codex) != nil { state.codexMaterialized = true }
    try state.save(instance, diagnostics: context.diagnostics)
    try report(context, instance, state, applied: applyToRunning(context, instance))
  }

  static func setRemote(_ context: CommandContext, _ instance: Instance) throws {
    var state = try ModelState.loadOrDefault(instance)
    // Saved endpoints stay so a later `local` does not prompt again.
    state.mode = .remote
    try state.save(instance, diagnostics: context.diagnostics)
    try report(context, instance, state, applied: applyToRunning(context, instance))
  }

  /// Re-materialize the guest configuration live; false when stopped.
  static func applyToRunning(_ context: CommandContext, _ instance: Instance) throws -> Bool {
    guard let running = try context.backend.asRunning(instance) else { return false }
    let agents = context.agents
    let session = try agents.session(for: running)
    try agents.bootstrapAgents(session, instance: running.instance, mode: .restart)
    return true
  }

  static func report(
    _ context: CommandContext, _ instance: Instance, _ state: ModelState, applied: Bool
  ) throws {
    let local = state.mode == .local
    for line in reportLines(
      instance.name.rawValue, mode: state.mode,
      claudeLocal: local && state.resolvedClaude(context.config.claude) != nil,
      codexLocal: local && state.resolvedCodex(context.config.codex) != nil, applied: applied)
    {
      context.output.out(line)
    }
  }

  static func reportLines(
    _ name: String, mode: ModelMode, claudeLocal: Bool, codexLocal: Bool, applied: Bool
  ) -> [String] {
    var lines: [String] = []
    switch mode {
    case .remote: lines.append("'\(name)' now uses cloud models for Claude and Codex.")
    case .local:
      let tools = [
        ("Claude", "claude.local_model", claudeLocal), ("Codex", "codex.local_model", codexLocal),
      ]
      lines.append(
        "'\(name)' now uses a local model for \(tools.filter(\.2).map(\.0).joined(separator: " and "))."
      )
      for (label, key, isLocal) in tools where !isLocal {
        lines.append(
          "  warning: \(label) stays on cloud — no local endpoint configured; set \(key) in the configuration file or re-run `coop model \(name) local` in an interactive terminal."
        )
      }
    }
    lines.append(
      applied
        ? "Applied to the running VM — no restart needed; relaunch claude/codex (e.g. `coop claude \(name)`) to pick it up."
        : "Saved — applies on next start.")
    return lines
  }

  static func promptEndpoint(_ tool: String) throws -> LocalModel? {
    guard TerminalPrompt.confirm("Configure a local model for \(tool)?") else { return nil }
    guard let url = TerminalPrompt.line("\(tool) host URL (e.g. http://localhost:11434)") else {
      throw HostError("\(tool) host URL is required")
    }
    guard let model = TerminalPrompt.line("\(tool) model name") else {
      throw HostError("\(tool) model name is required")
    }
    let token = TerminalPrompt.line("\(tool) auth token (optional — press enter to skip)")
    do {
      return try LocalModel(hostURL: url, model: model, authToken: token.map(Secret.init))
    } catch {
      throw HostError("invalid \(tool) host URL '\(url)': \(error.message)")
    }
  }
}

// MARK: - agent update

struct AgentCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agent", abstract: "Manage the coding agents installed inside a VM",
    subcommands: [AgentUpdateCommand.self])
}

struct AgentUpdateCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "update", abstract: "Update coding agent(s) to the latest version inside the VM.",
    discussion:
      "With no agent flag, both Claude Code and Codex are updated. The VM must be running.")

  @OptionGroup var global: GlobalOptions
  @Argument(
    help: "Instance name (required if multiple instances exist)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Update Claude Code (default: update both agents)") var claude = false
  @Flag(help: "Update Codex (default: update both agents)") var codex = false
  @Flag(help: "Only report installed vs. latest versions — change nothing") var check = false
  @Flag(name: .shortAndLong, help: "Skip the confirmation prompt") var yes = false

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      let selection = AgentUpdate.Selection(claude: claude, codex: codex)
      let (running, session) = try context.agents.openSession(
        context.backend, name: name, instances: context.listInstances())
      if check {
        for line in AgentUpdate.check(
          context.ssh, session, selection,
          latestCodexTag: {
            try AdminSupport.updater(context.environment, verbosity: global.verbose)
              .latestReleaseTag(repository: "openai/codex")
          },
          diagnostics: context.diagnostics)
        {
          context.output.out(line)
        }
        return
      }
      if !yes
        && !TerminalPrompt.confirm(
          "Update \(selection.phrase) in '\(running.instance.name)' to the latest version?")
      {
        context.diagnostics.log(.info, "Update cancelled")
        return
      }
      try AgentUpdate.run(context.ssh, session, selection, out: context.output.out)
    }
  }
}

// MARK: - proxy setup

struct ProxySetup: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "setup",
    abstract:
      "Store a provider credential in the macOS Keychain and wire it into `proxy.<provider>` (the default) or a per-VM override. Anthropic (Claude) is the default provider; pass `--openai` for Codex"
  )

  @OptionGroup var global: GlobalOptions
  @Flag(
    help:
      "Configure the `OpenAI` (Codex) upstream instead of Anthropic. `OpenAI` keys are always injected as `Authorization: Bearer`"
  ) var openai = false
  @Flag(help: "Configure the Anthropic (Claude) upstream (the default provider)") var anthropic =
    false
  @Option(
    name: .customLong("vm"),
    help: ArgumentHelp(
      "Store the credential as a per-VM override for this instance instead of the global `proxy.<provider>` default",
      valueName: "NAME"))
  var vm: String?
  @Flag(
    help:
      "Anthropic only: store an API key (`x-api-key`) instead of a Claude `setup-token`. Ignored for `--openai` (always Bearer)"
  ) var apiKey = false

  func validate() throws {
    if openai && anthropic {
      throw UsageError("the argument '--openai' cannot be used with '--anthropic'")
    }
  }

  func run() throws {
    try CoopCLI.run {
      let context = try CommandContext.load(global)
      try Self.run(
        context, provider: openai ? .openai : .anthropic, vm: vm, apiKey: apiKey,
        target: global.writableTarget(environment: context.environment),
        token: TerminalPrompt.secret)
    }
  }

  static func run(
    _ context: CommandContext, provider: ProxyProvider, vm: String?, apiKey: Bool,
    target: (path: String, format: ConfigFormat), token: () throws -> Secret<String>,
    keychainTool: String = ProxyProvisioning.securityTool
  ) throws {
    // The VM is validated before anything is stored, so an unknown name
    // leaves no orphaned Keychain item.
    var instance: Instance?
    if let vm {
      let name: InstanceName
      do { name = try InstanceName(vm) } catch {
        throw ContextError("'\(vm)' is not a valid instance name", cause: error)
      }
      instance = try InstanceStore.resolve(context.config, name: name)
    }
    let auth = ProxyProvisioning.auth(for: provider, apiKey: apiKey)
    for line in guidance(provider, auth) { context.output.error(line) }
    let secret = try token()
    let reference: CredentialReference
    do {
      reference = try ProxyProvisioning.storeInKeychain(
        service: ProxyProvisioning.service(for: provider, vm: instance?.name),
        account: provider.rawValue, secret: secret, environment: context.environment.variables,
        tool: keychainTool)
    } catch {
      throw ContextError(
        "Failed to store the \(provider.rawValue) credential in the macOS Keychain", cause: error)
    }
    if let instance {
      try ProxyState.setOverride(instance, provider: provider, credential: reference, auth: auth)
      context.output.error(
        "\nStored a per-VM \(provider.rawValue) credential override for '\(instance.name)' (auth = \"\(auth.rawValue)\")."
      )
    } else {
      try ConfigStore.upsertProxy(
        at: target.path, format: target.format, provider: provider, credential: reference,
        auth: auth, environment: context.environment)
      context.output.error(
        "\nWrote \(target.path):\n  proxy.\(provider.rawValue).credential = \"\(reference.command.expose())\"\n  proxy.\(provider.rawValue).auth = \"\(auth.rawValue)\""
      )
    }
    context.output.error(
      "\nProxy mode is now configured. It applies to remote-mode VMs; the raw credential stays on the host and is injected upstream, never forwarded into the guest."
    )
  }

  static func guidance(_ provider: ProxyProvider, _ auth: ProxyAuthScheme) -> [String] {
    switch (provider, auth) {
    case (.openai, _):
      [
        "Paste your OpenAI API key (sk-...). It is stored in the macOS Keychain, never as plaintext in the config, and injected as Authorization: Bearer upstream. Codex subscription (auth.json) is not supported in proxy mode — use an API key."
      ]
    case (.anthropic, .apiKey):
      [
        "Paste your Anthropic API key (sk-ant-...). It is stored in the macOS Keychain, never as plaintext in the config."
      ]
    case (.anthropic, .bearer):
      [
        "Run `claude setup-token` (needs a Claude subscription) to generate a long-lived, inference-scoped token (~1 year), then paste it below.",
        "It is stored in the macOS Keychain, never as plaintext in the config or in the guest.",
      ]
    }
  }
}
