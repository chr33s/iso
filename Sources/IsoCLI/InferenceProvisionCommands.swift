import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

// Managed backend provisioning (secure-local-inference spec §20.2–20.6).
// The user-facing commands run unprivileged and invoke one privileged step,
// `iso inference *-system`, through `sudo`, which prompts on the terminal.
// Those root steps read no configuration: everything they act on arrives in
// a validated plan on stdin or as a validated backend name.

enum PrivilegedStep {
  /// Run `sudo -- <this iso> inference <step> ...`, with `input` on stdin.
  static func run(_ step: String, _ arguments: [String], input: [UInt8]? = nil) throws {
    guard let executable = CommandLine.executablePath, let resolved = canonicalPath(executable)
    else { throw HostError("Failed to locate the iso executable") }
    let termination: ProcessRunner.Termination
    do {
      termination = try ProcessRunner().attached(
        .init(
          executable: "/usr/bin/sudo", arguments: ["--", resolved, "inference", step] + arguments,
          environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], deadline: .seconds(7200),
          input: input),
        inheritStdin: input == nil)
    } catch {
      throw ContextError("Failed to run sudo", cause: error)
    }
    guard termination.succeeded else {
      throw HostError("the privileged step `\(step)` failed (\(termination))")
    }
  }

  static func backendName(_ name: String) throws -> ManagedBackendName {
    do { return try ManagedBackendName(name) } catch { throw HostError("\(error)") }
  }

  /// The configured backend `name`, which must have a `managed` section.
  static func managedBackend(_ context: CommandContext, _ name: String) throws -> (
    ManagedBackendName, InferenceBackendConfig
  ) {
    let parsed = try backendName(name)
    guard let backend = context.config.inference.backends[name], backend.managed != nil else {
      throw HostError("inference backend '\(name)' is not managed by iso (no `managed` section)")
    }
    return (parsed, backend)
  }

  static let stderrLog: @Sendable (String) -> Void = { line in
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }
}

struct InferenceProvision: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "provision",
    abstract:
      "Provision a managed backend: role account, root-owned files, confined LaunchDaemon, Keychain token (runs one step with sudo)"
  )

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Backend name from `inference.backends` with a `managed` section") var backend:
    String

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let (name, config) = try PrivilegedStep.managedBackend(context, backend)
      let account = try SecretAccount(name.rawValue)
      let keychain = Keychain(environment: context.environment.variables)
      try keychain.requireAvailable()
      let token = Secret(randomHex(32))
      _ = try keychain.store(
        service: ManagedBackendConfig.keychainService, account: account, secret: token)
      let plan = try ManagedBackendPlan(name: name, backend: config, token: token)
      context.output.out(
        "Provisioning '\(backend)' as \(ManagedBackendConfig.roleAccount); sudo will ask for your password."
      )
      try PrivilegedStep.run("provision-system", [], input: plan.encoded)
      let result = BackendChecks.verify(name: backend, backend: config)
      context.output.write(result.json.rendered())
      guard
        result.isolationVerified
          || config.managed?.confinement == ManagedBackendConfig.Confinement.none
      else {
        throw HostError("the provisioned backend did not pass verification; see the report above")
      }
    }
  }
}

struct InferenceDeprovision: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "deprovision",
    abstract: "Remove a managed backend, its files and token (runs one step with sudo)")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Backend name") var backend: String

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let name = try PrivilegedStep.backendName(backend)
      try PrivilegedStep.run("deprovision-system", [name.rawValue])
      Keychain(environment: context.environment.variables).delete(
        service: ManagedBackendConfig.keychainService, account: try SecretAccount(name.rawValue))
      context.output.out("Removed managed backend '\(name)'.")
    }
  }
}

struct InferenceRestartBackend: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "restart-backend",
    abstract: "Restart a managed backend's LaunchDaemon (runs one step with sudo)")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Backend name") var backend: String

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let (name, _) = try PrivilegedStep.managedBackend(context, backend)
      try PrivilegedStep.run("restart-system", [name.rawValue])
      context.output.out("Restarted managed backend '\(backend)'.")
    }
  }
}

/// Root steps. Hidden: run only through `sudo` by the commands above.
struct InferenceProvisionSystem: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "provision-system", abstract: "Privileged step of `provision`",
    shouldDisplay: false)

  func run() throws {
    try IsoCLI.run {
      var bytes: [UInt8] = []
      while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
        bytes += chunk
        guard bytes.count <= 64 << 10 else { throw HostError("the provisioning plan is too large") }
      }
      let plan = try ManagedBackendPlan.decode(bytes)
      try ManagedBackendProvisioner(log: PrivilegedStep.stderrLog).provision(plan)
    }
  }
}

struct InferenceDeprovisionSystem: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "deprovision-system", abstract: "Privileged step of `deprovision`",
    shouldDisplay: false)
  @Argument var backend: String

  func run() throws {
    try IsoCLI.run {
      try ManagedBackendProvisioner(log: PrivilegedStep.stderrLog).deprovision(
        name: try PrivilegedStep.backendName(backend))
    }
  }
}

struct InferenceRestartSystem: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "restart-system", abstract: "Privileged step of `restart-backend`",
    shouldDisplay: false)
  @Argument var backend: String

  func run() throws {
    try IsoCLI.run {
      try ManagedBackendProvisioner(log: { _ in }).restart(
        name: try PrivilegedStep.backendName(backend))
    }
  }
}

struct InferenceInit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract:
      "Write hardened inference defaults: required mode, offline preset, session TTL, a confined managed MLX backend and a chat service"
  )

  @OptionGroup var global: GlobalOptions
  @Option(help: "Managed backend name") var backend = "mlx-main"
  @Option(help: "Loopback port for the backend") var port: UInt16 = 18080
  @Option(help: "Local model directory to install (absolute)") var model: String?
  @Option(help: "Hugging Face repository to fetch instead (opt-in network)") var modelRepo: String?
  @Option(help: "40-hex commit of --model-repo") var modelRevision: String?
  @Option(help: "Interpreter that imports mlx_lm (absolute)") var python: String?
  @Option(help: "Install this pinned mlx-lm version instead (opt-in network)") var install: String?
  @Option(help: "MLX memory ceiling, for example 24GiB") var memoryLimit: String?
  @Flag(help: "Replace conflicting existing values") var force = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let settings = try Self.settings(
        backend: backend, port: port, model: model, repo: modelRepo, revision: modelRevision,
        python: python, install: install, memoryLimit: memoryLimit)
      let target = try global.configTarget(context.environment)
      let path = target.path
      let changed = try ConfigStore.applyDefaults(
        at: path, format: target.format, settings: settings, force: force,
        environment: context.environment)
      context.output.out(
        changed.isEmpty
          ? "Nothing to change in \(path)." : "Updated \(path): \(changed.joined(separator: ", "))")
      context.output.out(
        "mlx-lm serves Chat Completions only, so this configures the `local-chat` service for `iso inference attach`; Claude Code and Codex need a backend that speaks their protocol."
      )
      context.output.out(
        "Next: `iso inference provision \(backend)` (asks for your password once).")
    }
  }

  static func settings(
    backend: String, port: UInt16, model: String?, repo: String?, revision: String?,
    python: String?, install: String?, memoryLimit: String?
  ) throws -> [([String], JSONValue)] {
    _ = try PrivilegedStep.backendName(backend)
    let chat = JSONValue.string(InferenceProtocol.openAIChat.rawValue)
    var managed: [String: JSONValue] = [
      "server": .string("mlx-lm"),
      "confinement": .string(ManagedBackendConfig.Confinement.seatbelt.rawValue),
    ]
    switch (python, install) {
    case (let path?, nil): managed["python"] = .string(path)
    case (nil, let version?): managed["install"] = .string(version)
    default: throw HostError("pass exactly one of --python or --install")
    }
    switch (model, repo, revision) {
    case (let directory?, nil, nil): managed["model"] = .string(directory)
    case (nil, let repository?, let commit?):
      managed["model"] = .object(["repo": .string(repository), "revision": .string(commit)])
    default: throw HostError("pass --model DIR, or --model-repo with --model-revision")
    }
    if let memoryLimit { managed["memory_limit"] = .string(memoryLimit) }
    let profile: JSONValue = .object([
      "protocol": chat,
      "completion_evidence": .string(QualifiedMLXLM.completionEvidence.rawValue),
      "stream_close_drain_ms": .number(.integer(QualifiedMLXLM.streamCloseDrainMilliseconds)),
      "context_overflow": .string(QualifiedMLXLM.contextOverflow.rawValue),
      "input_overhead": .object([
        "per_request_bytes": .number(.integer(4096)), "per_message_bytes": .number(.integer(64)),
      ]),
      "max_input_bytes": .string("4MiB"),
    ])
    return [
      (["security", "preset"], .string("offline")),
      (["limits", "session_ttl"], .string("8h")),
      (["inference", "mode"], .string("required")),
      (["inference", "qualification_profiles", "mlx-lm-0.31"], profile),
      (
        ["inference", "backends", backend],
        .object([
          "base_url": .string("http://127.0.0.1:\(port)"), "protocol": chat,
          "qualification_profile": .string("mlx-lm-0.31"),
          "max_active_requests": .number(.integer(1)), "managed": .object(managed),
        ])
      ),
      (
        ["inference", "services", "local-chat"],
        .object([
          "backend": .string(backend), "upstream_model": .string("default_model"),
          "frontend_apis": .array([.string(InferenceAPI.openAIChat.rawValue)]),
          "max_context_tokens": .number(.integer(32768)),
          "default_output_tokens": .number(.integer(2048)),
          "max_output_tokens": .number(.integer(4096)),
        ])
      ),
    ]
  }
}

/// What qualification established for mlx-lm 0.31.3 (spec §19): the gateway
/// always streams upstream, and closing that stream stops generation within
/// 500 ms, or once prefill ends (prefill is not interruptible); an over-long
/// prompt is processed, not rejected or cut.
enum QualifiedMLXLM {
  static let completionEvidence = CompletionEvidenceMode.streamClose
  static let streamCloseDrainMilliseconds: Int64 = 10_000
  static let contextOverflow = ContextOverflowMode.accept
}
