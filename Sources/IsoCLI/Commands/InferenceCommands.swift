import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

// `iso inference …` (secure-local-inference spec §12.1). Status names what
// the gateway enforces separately from what the backend's qualification
// profile claims and from what nobody has verified; it never prints a
// capability or credential.

struct InferenceCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inference",
    abstract: "Manage the guarded local inference gateway (`iso-inference`)",
    subcommands: [
      InferenceStatus.self, InferenceDoctor.self, InferenceAttach.self, InferenceDetach.self,
      InferenceRevoke.self,
      InferenceRequalify.self, InferenceStop.self, InferenceInit.self, InferenceProvision.self,
      InferenceDeprovision.self, InferenceRestartBackend.self, InferenceProvisionSystem.self,
      InferenceDeprovisionSystem.self, InferenceRestartSystem.self,
    ])
}

extension CommandContext {
  func requireInferenceController() throws -> InferenceController {
    guard
      let controller = inferenceController(
        resolver: CredentialResolver(environment: environment.variables),
        isoExecutable: CommandLine.executablePath)
    else { throw HostError("Cannot determine home directory") }
    return controller
  }
}

/// Stable, key-sorted JSON for `--json` output.
func inferenceJSON(_ value: JSONValue) -> OutputJSON {
  switch value {
  case .null: .null
  case .bool(let flag): .bool(flag)
  case .number(.integer(let n)): .int(n)
  case .number(.unsigned(let n)): .uint(n)
  case .number(.decimal(let n)): .double(NSDecimalNumber(decimal: n).doubleValue)
  case .string(let text): .string(text)
  case .array(let elements): .array(elements.map(inferenceJSON))
  case .object(let members):
    // Each key comes from `members` itself, so the lookup cannot miss.
    .object(members.keys.sorted().map { ($0, inferenceJSON(members[$0]!)) })
  }
}

struct InferenceStatus: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Show guarded services, gateway sessions, limits and backend qualification")

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Instance name (default: every instance)", transform: parseInstanceName)
  var name: InstanceName?
  @Flag(help: "Emit JSON") var json = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let controller = try context.requireInferenceController()
      let instance = try name.map { try InstanceStore.resolve(context.config, name: $0) }
      let state = controller.probe()
      let gateway: [String: JSONValue]? =
        if case .verified = state { try controller.inspect(instance) } else { nil }
      let checks = Self.hostChecks(context, controller)
      let revoked = try Self.revocations(context, instance)
      if json {
        var members: [(String, OutputJSON)] = [
          ("mode", .string(context.config.inference.mode.rawValue)),
          ("egress", .string(context.config.egress.rawValue)),
          ("gateway_running", .bool(gateway != nil)),
          ("gateway_state", .string(Self.stateName(state))),
        ]
        if case .unverified(let pid, _, let reason) = state {
          members.append(
            (
              "gateway_unverified",
              .object([
                ("pid", .int(Int64(pid))), ("reason", .string(reason)),
              ])
            ))
        }
        if let gateway {
          for key in ["gateway", "sessions", "backends"] {
            if let value = gateway[key] { members.append((key, inferenceJSON(value))) }
          }
        }
        members.append(("revoked", Self.revokedJSON(revoked)))
        members.append(("host_checks", checks.json))
        context.output.write(OutputJSON.object(members).rendered())
        return
      }
      let out = { (line: String) in context.output.out(neutralizeControls(line)) }
      out("Inference mode: \(context.config.inference.mode.rawValue)")
      out("Egress:         \(context.config.egress.rawValue)")
      for (name, result) in checks.results {
        out(
          "Backend host:   \(name) run_as \(result.runAs.account ?? "-") verified \(Self.flag(result.runAs.passed)) authenticated \(Self.flag(result.authenticated)) challenge \(Self.flag(result.challenged)) confined \(Self.flag(result.confined)) isolation_verified \(result.isolationVerified)"
        )
      }
      for line in Self.revokedLines(revoked) { out(line) }
      if case .unverified(let pid, _, let reason) = state {
        out("Gateway:        UNVERIFIED (pid \(pid)): \(reason)")
        throw ExitCode(1)
      }
      guard let gateway else {
        out("Gateway:        not running")
        return
      }
      Self.printGateway(context, gateway)
    }
  }

  /// The instances (the named one, or every instance) that stay revoked
  /// until they restart or are attached, and why.
  static func revocations(_ context: CommandContext, _ instance: Instance?) throws
    -> [(name: String, reason: InferenceController.Revocation)]
  {
    let instances = try instance.map { [$0] } ?? InstanceStore.list(context.config)
    return instances.compactMap { instance in
      InferenceController.revocation(instance).map { (instance.name.rawValue, $0) }
    }
  }

  static func revokedJSON(
    _ revoked: [(name: String, reason: InferenceController.Revocation)]
  ) -> OutputJSON {
    .array(
      revoked.map {
        .object([("instance", .string($0.name)), ("reason", .string($0.reason.rawValue))])
      })
  }

  static func revokedLines(
    _ revoked: [(name: String, reason: InferenceController.Revocation)]
  ) -> [String] {
    revoked.map { name, reason in
      let cause =
        switch reason {
        case .manual: "by `iso inference revoke`"
        case .forwardExited: "its inference forward exited"
        }
      return
        "Revoked:        \(name) \(reason.rawValue) (\(cause)); restart the VM (`iso stop \(name)`, then `iso start \(name)`) or run `iso inference attach \(name)`"
    }
  }

  static func printGateway(_ context: CommandContext, _ inspection: [String: JSONValue]) {
    let out = LineOutput(context.output)
    if case .object(let gateway)? = inspection["gateway"] {
      out.out(
        "Gateway:        pid \(text(gateway["pid"])), epoch \(text(gateway["epoch"])), gateway_enforced \(text(gateway["gateway_enforced"]))"
      )
      if case .object(let limits)? = gateway["limits"] {
        out.out(
          "Limits:         "
            + limits.keys.sorted().map { "\($0)=\(text(limits[$0]))" }.joined(
              separator: " "))
      }
    }
    if case .array(let sessions)? = inspection["sessions"] {
      for case .object(let session) in sessions {
        let instance: String =
          if case .object(let key)? = session["instance"] { text(key["name"]) } else { "?" }
        out.out(
          "Session:        \(instance) \(text(session["state"])) aliases \(list(session["aliases"])) apis \(list(session["apis"])) transport \(text(session["transport_kind"])) transport_pid \(text(session["transport_pid"])) deadline_seconds \(text(session["deadline_seconds"]))"
        )
      }
    }
    if case .array(let backends)? = inspection["backends"] {
      for case .object(let backend) in backends {
        out.out(
          "Backend:        \(text(backend["name"])) \(text(backend["backend"])) profile \(text(backend["qualification_profile"])) evidence \(text(backend["completion_evidence"])) backend_cancellation_verified \(text(backend["backend_cancellation_verified"])) backend_isolation_verified \(text(backend["backend_isolation_verified"])) active \(text(backend["active"])) queued \(text(backend["queued"])) quarantine \(text(backend["quarantine"]))"
        )
      }
    }
  }

  /// `iso model show NAME` under `inference.mode = "required"`.
  static func modelLines(_ context: CommandContext, _ instance: Instance) throws {
    let config = context.config
    let out = LineOutput(context.output)
    out.out("Instance: \(instance.name)")
    out.out("Mode:     local (inference.mode = \"required\")")
    for (label, service) in [
      ("Claude", config.claude.localService), ("Codex", config.codex.localService),
    ] {
      if let service, let resolved = config.inference.resolve(service) {
        out.out(
          "\(label.padding(toLength: 9, withPad: " ", startingAt: 0)) guarded — \(service) → \(resolved.backendName) (\(resolved.backend.baseURL), profile \(resolved.profile.name))"
        )
      } else {
        out.out(
          "\(label.padding(toLength: 9, withPad: " ", startingAt: 0)) refused — no guarded inference service configured"
        )
      }
    }
    if let grant = try InferenceAttachGrant.load(instance) {
      out.out("Grant:    \(grant.service) (\(grant.api.rawValue)) via ISO_INFERENCE_* variables")
    }
  }

  struct HostChecks {
    let results: [(String, BackendVerification)]
    var json: OutputJSON { .object(results.map { ($0.0, $0.1.json) }) }
  }

  /// What this host process can verify about each backend (spec §20.8).
  /// A managed backend's challenge needs its Keychain token; one that
  /// cannot be read leaves the challenge unverified.
  static func hostChecks(_ context: CommandContext, _ controller: InferenceController)
    -> HostChecks
  {
    HostChecks(
      results: context.config.inference.backends.sorted { $0.key < $1.key }.map { name, backend in
        let token: Secret<String>? =
          switch Result(catching: { try controller.backendToken(backend, name) }) {
          case .success(let token): token
          case .failure: nil
          }
        return (name, BackendChecks.verify(name: name, backend: backend, token: token))
      })
  }

  static func stateName(_ state: InferenceController.GatewayState) -> String {
    switch state {
    case .notRunning: "not_running"
    case .verified: "running"
    case .unverified: "unverified"
    }
  }

  static func flag(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "-" }

  static func text(_ value: JSONValue?) -> String {
    switch value {
    case .string(let text)?: text
    case .bool(let flag)?: flag ? "true" : "false"
    case .number(let number)?: number.description
    case .null?, nil: "-"
    default: "…"
    }
  }

  static func list(_ value: JSONValue?) -> String {
    guard case .array(let items)? = value else { return "-" }
    return items.map { text($0) }.joined(separator: ",")
  }
}

struct InferenceDoctor: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "doctor",
    abstract:
      "Check the gateway binary, state directory, backend binding and qualification; exits non-zero on a failure"
  )

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Emit JSON") var json = false

  enum Level: String { case ok, warn, fail }

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let controller = try context.requireInferenceController()
      let inference = context.config.inference
      var checks: [Check] = []
      checks.append(
        .passing(
          "mode", inference.mode == .required, else: .warn,
          ok: "inference.mode = \"required\"",
          otherwise: "inference.mode = \"off\": no guarded inference"))
      switch controller.probe() {
      case .verified:
        checks.append(Check("gateway", .ok, "running and verified as this user's iso-inference"))
      case .notRunning:
        checks.append(Check("gateway", .ok, "not running; it starts on demand"))
      case .unverified(let pid, _, let reason):
        checks.append(
          Check(
            "gateway", .fail,
            "pid \(pid) on the control socket failed verification: \(reason); `iso inference stop --force` stops a same-user gateway"
          ))
      }
      let hostChecks = InferenceStatus.hostChecks(context, controller)
      for (name, backend) in inference.backends.sorted(by: { $0.key < $1.key }) {
        let host =
          hostChecks.results.first { $0.0 == name }?.1
          ?? BackendChecks.verify(name: name, backend: backend)
        checks.append(
          .passing(
            "backend \(name) reachable", host.reachable, else: .warn,
            ok: "\(backend.baseURL) accepts connections",
            otherwise: "\(backend.baseURL) is not listening"))
        checks.append(
          .passing(
            "backend \(name) bind", host.exposedAddresses.isEmpty, else: .fail,
            ok: "not reachable on any non-loopback host address",
            otherwise:
              "INFERENCE_BACKEND_UNSAFE_BIND: also accepts on \(host.exposedAddresses.joined(separator: ", "))"
          ))
        switch host.runAs {
        case .notConfigured:
          checks.append(
            Check(
              "backend \(name) run_as", .warn,
              "no run_as: the backend may run as you and read your files; see `iso inference init`")
          )
        case .verified(let account):
          checks.append(Check("backend \(name) run_as", .ok, "runs as \(account), not as you"))
        case .failed(_, let reason):
          checks.append(
            Check("backend \(name) run_as", .fail, "INFERENCE_BACKEND_UNSAFE_OWNER: \(reason)"))
        }
        if let authenticated = host.authenticated {
          checks.append(
            .passing(
              "backend \(name) authentication", authenticated, else: .fail,
              ok: "refuses requests without its token", otherwise: "answers without a token"))
        }
        if let managed = backend.managed {
          checks.append(
            .passing(
              "backend \(name) identity", host.challenged == true, else: .fail,
              ok: "the listener answered the launcher's token challenge",
              otherwise:
                "the listener did not prove it holds the managed token (another process may hold the port)"
            ))
          checks.append(
            Check(
              "backend \(name) confinement",
              host.confined == true ? .ok : managed.confinement == .none ? .warn : .fail,
              host.confined.map { $0 ? "sandboxed (kernel-reported)" : "not sandboxed" }
                ?? "could not be determined"))
        }
        if let profile = inference.profiles[backend.profile] {
          checks.append(
            Check(
              "backend \(name) qualification", profile.completionEvidence == .none ? .warn : .ok,
              "profile \(profile.name): evidence \(profile.completionEvidence.rawValue), context \(profile.contextOverflow.rawValue); backend isolation (filesystem, network, prompt logging) is not verified by iso"
            ))
        }
      }
      if case .verified = controller.probe(), let gateway = try? controller.inspect(nil),
        case .array(let backends)? = gateway["backends"]
      {
        for case .object(let backend) in backends {
          if case .string(let reason)? = backend["quarantine"] {
            let name = InferenceStatus.text(backend["name"])
            checks.append(
              Check(
                "backend \(name) quarantine", .fail,
                "INFERENCE_BACKEND_QUARANTINED (\(reason)); drain or restart it, then `iso inference requalify \(name)`"
              ))
          }
        }
      }
      for listener in BackendChecks.guestReachableListeners() {
        checks.append(
          Check(
            "host listener \(listener.address)", .warn,
            "\(listener.command) (pid \(listener.pid)) listens beyond loopback; guests can reach it whatever `egress` says"
          ))
      }
      checks.append(
        Check(
          "host listeners (other accounts)", .warn,
          "listeners of other accounts are not visible without privilege: `sudo lsof -nP -iTCP -sTCP:LISTEN`"
        ))
      switch context.config.egress {
      case .none:
        checks.append(
          Check(
            "egress", .ok,
            "egress = \"none\"; on vmnet, host services remain reachable from the guest"))
      case .filtered:
        checks.append(
          Check(
            "egress", .warn,
            "egress = \"filtered\": the approved hosts stay reachable; inference does not change them"
          ))
      case .open:
        checks.append(
          Check("egress", .warn, "egress = \"open\": no protection against general exfiltration"))
      }
      if json {
        context.output.write(
          OutputJSON.array(
            checks.map {
              .object([
                ("check", .string($0.name)), ("level", .string($0.level.rawValue)),
                ("detail", .string($0.detail)),
              ])
            }
          ).rendered())
      } else {
        for check in checks {
          context.output.out(
            neutralizeControls("[\(check.level.rawValue)] \(check.name): \(check.detail)"))
        }
      }
      if checks.contains(where: { $0.level == .fail }) { throw ExitCode(1) }
    }
  }

  struct Check {
    let name: String
    let level: Level
    let detail: String

    init(_ name: String, _ level: Level, _ detail: String) {
      self.name = name
      self.level = level
      self.detail = detail
    }

    /// `ok` when the condition holds, otherwise `failure` with its detail.
    static func passing(
      _ name: String, _ condition: Bool, else failure: Level, ok: String, otherwise: String
    ) -> Check {
      condition ? Check(name, .ok, ok) : Check(name, failure, otherwise)
    }
  }

}

struct InferenceAttach: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "attach",
    abstract:
      "Grant an application in the VM a guarded service; sessions then carry ISO_INFERENCE_BASE_URL, ISO_INFERENCE_MODEL and ISO_INFERENCE_TOKEN"
  )

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Instance name", transform: parseInstanceName) var name: InstanceName
  @Option(help: "Guarded service alias from `inference.services`") var service: String
  @Option(help: "Frontend API the application uses (for example `openai-chat`)") var api: String

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      guard context.config.inference.mode == .required else {
        throw HostError("iso inference attach needs inference.mode = \"required\"")
      }
      let serviceName = try InferenceServiceName(service)
      guard let resolved = context.config.inference.resolve(serviceName) else {
        throw HostError("unknown inference service '\(service)'")
      }
      guard let parsedAPI = InferenceAPI(rawValue: api),
        resolved.service.frontendAPIs.contains(parsedAPI)
      else {
        throw HostError(
          "INFERENCE_PROTOCOL_UNSUPPORTED: '\(service)' grants \(resolved.service.frontendAPIs.map(\.rawValue).joined(separator: ", ")), not '\(api)'"
        )
      }
      let instance = try InstanceStore.resolve(context.config, name: name)
      try InferenceAttachGrant(service: serviceName, api: parsedAPI).save(instance)
      InferenceController.clearManualRevocation(instance)
      if let running = try context.backend.asRunning(instance) {
        _ = try context.agents.session(for: running)
        context.output.out("Granted '\(service)' (\(api)) to running instance '\(name)'.")
      } else {
        context.output.out(
          "Granted '\(service)' (\(api)) to '\(name)'; it applies at the next start.")
      }
    }
  }
}

struct InferenceDetach: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "detach",
    abstract:
      "Remove an instance's `iso inference attach` grant; its next session carries no ISO_INFERENCE_* variables"
  )

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Instance name", transform: parseInstanceName) var name: InstanceName

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      guard try InferenceAttachGrant.remove(instance) else {
        context.output.out("'\(name)' has no attach grant.")
        return
      }
      // The grant's service may still be in the running session: revoke it,
      // so the next command registers only what remains.
      if context.config.inference.mode == .required {
        try context.requireInferenceController().revoke(instance)
      }
      context.output.out("Removed the attach grant of '\(name)'.")
    }
  }
}

struct InferenceRevoke: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "revoke",
    abstract:
      "Revoke an instance's gateway session now; it stays revoked until the VM restarts or a grant is attached"
  )

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Instance name", transform: parseInstanceName) var name: InstanceName

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let instance = try InstanceStore.resolve(context.config, name: name)
      // Throws unless the gateway confirmed the revocation or is not running.
      try context.requireInferenceController().revokeManually(instance)
      context.output.out("Revoked inference access for '\(name)'.")
    }
  }
}

struct InferenceRequalify: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "requalify",
    abstract:
      "Clear a backend's quarantine after you have drained or restarted it (the gateway never kills an attached backend)"
  )

  @OptionGroup var global: GlobalOptions
  @Argument(help: "Backend name from `inference.backends`") var backend: String
  @Flag(help: "Restart the managed backend first (sudo), so no old generation can still run")
  var restart = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      guard let config = context.config.inference.backends[backend] else {
        throw HostError("unknown inference backend '\(backend)'")
      }
      if restart {
        let (name, _) = try PrivilegedStep.managedBackend(context, backend)
        try PrivilegedStep.run("restart-system", [name.rawValue])
        let deadline = Date().addingTimeInterval(300)
        while !InferenceController.backendAccepts(port: config.port), Date() < deadline {
          usleep(500_000)
        }
      }
      try context.requireInferenceController().requalify(port: config.port)
      context.output.out("Backend '\(backend)' (\(config.baseURL)) requalified.")
    }
  }
}

struct InferenceStop: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stop", abstract: "Stop the inference gateway")

  @OptionGroup var global: GlobalOptions
  @Flag(help: "Revoke active sessions instead of refusing") var force = false

  func run() throws {
    try IsoCLI.run {
      let context = try CommandContext.load(global)
      let controller = try context.requireInferenceController()
      switch controller.probe() {
      case .notRunning:
        context.output.out("The inference gateway is not running.")
      case .verified:
        try controller.stopGateway(force: force)
        context.output.out("Stopped the inference gateway.")
      case .unverified(let pid, let sameUser, let reason):
        // It cannot be asked to stop over the control protocol. A same-user
        // process can be signalled; another account's never is.
        guard force, sameUser else {
          throw HostError(
            "pid \(pid) serves the inference control socket but failed verification (\(reason))\(sameUser ? "; pass --force to terminate it (its sessions end with it)" : "; it runs as another user, so iso will not signal it")"
          )
        }
        guard kill(pid, SIGTERM) == 0 else {
          throw HostError.posix("Failed to terminate", "pid \(pid)")
        }
        context.output.out("Terminated the unverified gateway process \(pid).")
      }
    }
  }
}

/// Lines with control characters neutralized: gateway and lsof text reaches
/// the terminal.
struct LineOutput {
  let streams: any OutputStreams
  init(_ streams: any OutputStreams) { self.streams = streams }
  func out(_ line: String) { streams.out(neutralizeControls(line)) }
}
