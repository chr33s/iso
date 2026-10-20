import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost
import IsoSecrets

/// Remote project workflows through the owned relay: create-or-reuse,
/// one-way push, and staged pull whose apply needs no host.

/// Reuses a live coordinator whose boot is still current; otherwise opens a
/// session for this command and renews it until the command ends.
private func withSession<T>(
  _ env: HostCommandEnvironment, _ remote: RemoteHost, _ binding: ClientBinding,
  _ body: (SSHTarget) throws -> T
) throws -> T {
  if let live = CoordinatorRecord.live(env.config, binding) {
    let current = try VMObservation(wire: try remote.client.call(.vmInspect(binding.instance)))
    if current.state == .running, current.bootID == live.boot {
      return try body(try CoordinatorRecord.target(live, config: env.config))
    }
  }
  let session = try ClientSessionCoordinator.open(
    host: remote, binding: binding, config: env.config, environment: env.environment,
    client: env.clientLabel)
  defer { session.finish() }
  session.startRenewing(diagnostics: env.diagnostics)
  return try body(try session.guestTarget(config: env.config))
}

struct HostPush: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "push", abstract: "Copy a client directory into a remote VM's /workspace")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Option(help: "Client directory (default: the recorded one, else .)", completion: .directory)
  var dir: String?
  @Flag(help: "Overwrite uncommitted guest changes") var force = false
  @Flag(name: .customLong("exclude-git"), help: ArgumentHelp(DeprecatedExcludeGit.help))
  var excludeGit = false

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      DeprecatedExcludeGit.warn(excludeGit, env.diagnostics)
      let remote = try env.resolve(host)
      let binding = try env.binding(remote, name)
      let recorded = try WorkspaceState.load(try RemoteWorkspace.shadow(env.config, binding))
      let source = dir ?? recorded?.source.hostPath ?? FileManager.default.currentDirectoryPath
      try withSession(env, remote, binding) { target in
        try RemoteWorkspace.push(
          target, source: source, config: env.config, binding: binding, force: force,
          environment: env.environment, diagnostics: env.diagnostics)
      }
      env.output.out("Pushed \(source) to \(binding.name) on \(binding.host)")
    }
  }
}

struct HostPull: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "pull",
    abstract: "Stage a remote VM's /workspace for review, then apply it (apply works offline)")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Option(
    help: "Client destination when staging (default: the recorded source directory)",
    completion: .directory)
  var dir: String?
  @Flag(help: "Apply the completed stage named by --stage-id; needs no host connection")
  var apply = false
  @Flag(help: "Deprecated, no effect: drift is never overridden") var force = false
  @Option(name: .customLong("stage-id"), help: "With --apply: the exact stage to apply (required)")
  var stageID: String?
  @Option(
    help: ArgumentHelp(
      "With --apply: approve one execution-sensitive entry shown at review (repeatable)",
      valueName: "PATH"))
  var approveSensitive: [String] = []
  @Flag(name: .customLong("exclude-git"), help: ArgumentHelp(DeprecatedExcludeGit.help))
  var excludeGit = false

  /// Each flag belongs to one mode; one that cannot affect the selected mode
  /// is refused rather than ignored (the deprecated no-op flags only warn).
  /// A stage's destination is fixed when it is created.
  func validate() throws {
    if apply {
      if dir != nil {
        throw UsageError(
          "--dir is fixed when the stage is created; it cannot be used with --apply")
      }
      if stageID == nil {
        throw UsageError(
          "--apply needs the exact --stage-id shown when the stage was created; nothing is inferred"
        )
      }
    } else {
      if stageID != nil { throw UsageError("--stage-id requires --apply") }
      if !approveSensitive.isEmpty { throw UsageError("--approve-sensitive requires --apply") }
    }
  }

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      DeprecatedExcludeGit.warn(excludeGit, env.diagnostics)
      if force { env.diagnostics.warn("--force is deprecated and has no effect") }
      guard
        let binding = try ClientBindingStore(config: env.config).load(
          try env.hostID(host), try InstanceName(name))
      else { throw HostError("no instance '\(name)' is bound on host '\(host)'") }
      if apply, let stageID {
        let (manifest, applied) = try RemoteWorkspace.apply(
          config: env.config, binding: binding,
          request: WorkspaceTransfer.ApplyRequest(
            stageID: stageID, replace: true, sensitive: approveSensitive),
          environment: env.environment, diagnostics: env.diagnostics)
        env.output.out("Applied stage \(manifest.id): \(applied.count) change(s)")
        return
      }
      let remote = try env.resolve(host)
      let manifest = try withSession(env, remote, binding) { target in
        try RemoteWorkspace.stage(
          target, config: env.config, binding: binding, directory: dir,
          environment: env.environment, diagnostics: env.diagnostics)
      }
      let review = StageReview(manifest: manifest, tree: "")
      review.summary(instance: binding.name.rawValue).forEach(env.output.out)
      let command =
        (["iso host pull \(host) \(name) --apply --stage-id \(manifest.id)"]
        + manifest.sensitivePaths.map { "--approve-sensitive \(shellEscape($0))" })
        .joined(separator: " ")
      env.output.out(
        manifest.applicable ? "Review, then: \(command)" : "This stage cannot be applied.")
    }
  }
}

struct HostUp: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "up",
    abstract: "Create or reuse a project VM on a remote host, start it, and push the project",
    discussion:
      "Every run pushes PATH into /workspace, including onto a VM it reuses. An explicit --egress must match the egress of a VM it reuses; it never recreates the VM or changes its policy."
  )

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument(help: "Client project directory") var path: String = "."
  @Option(help: "Instance name (default: the directory name)") var name: String?
  @Option var image: String = ImageName.default.rawValue
  @Option(
    help: "Boot lifetime (\"30m\", \"8h\"; at most 24h)", transform: parseDurationArgument)
  var ttl: Duration?
  @Option(help: "open, none or filtered (default: the configured egress)")
  var egress: EgressMode?

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let (binding, project) = try prepare(env, remote)
      try withSession(env, remote, binding) { target in
        try RemoteWorkspace.push(
          target, source: project, config: env.config, binding: binding, force: false,
          environment: env.environment, diagnostics: env.diagnostics)
      }
      env.output.out("Ready: iso host shell \(host) \(binding.name)")
    }
  }

  /// Everything before the push: create or reuse the binding, check an
  /// explicit --egress against a reused VM, and start a stopped one. A
  /// refusal here happens before any start or push.
  func prepare(_ env: HostCommandEnvironment, _ remote: RemoteHost) throws -> (
    ClientBinding, String
  ) {
    guard let project = canonicalPath(path) else { throw HostError("\(path) does not exist") }
    let instanceName =
      try name.map { try InstanceName($0) }
      ?? InstanceName(Instance.sanitizedBasename((project as NSString).lastPathComponent))
    let store = ClientBindingStore(config: env.config)
    var binding = try store.load(remote.enrollment.hostID, instanceName)
    let reused = !(binding == nil || binding?.lastState == .destroyed)
    if !reused { binding = try create(env, remote, instanceName, store) }
    guard let binding else { throw HostError("no binding for \(instanceName)") }
    let current = try VMObservation(wire: try remote.client.call(.vmInspect(binding.instance)))
    // A destroyed or unknown VM is reported by the state switch below.
    if reused, let egress, current.state == .running || current.state == .stopped,
      let refusal = Self.reusedEgressRefusal(
        requested: egress, observed: current.egress, name: binding.name, host: host)
    {
      throw HostError(refusal)
    }
    switch current.state {
    case .running:
      env.output.out("Reusing running \(binding.name)")
    case .stopped:
      try remote.requireEnabled()
      let seconds = ttlSeconds(ttl, default: env.config.execution.remote.defaultSessionTTL)
      let receipt = try submit(
        remote,
        .vmStart(
          binding.instance, expectedGeneration: current.generation, ttlSeconds: seconds,
          policy: binding.policyHash), operation: .fresh(), wait: .seconds(600),
        output: env.output)
      guard succeeded(receipt) else { throw HostError(describe(receipt)) }
    case .unknown, .unhealthy, .destroyed:
      // An unknown or broken instance never triggers recreation or a restart.
      throw HostError(
        "\(binding.name) on \(binding.host) is \(current.state.rawValue); inspect it before continuing"
      )
    }
    return (binding, project)
  }

  /// Why an explicit `--egress` cannot apply to an existing VM: it differs
  /// from the VM's fixed egress, or the host did not report that egress.
  static func reusedEgressRefusal(
    requested: EgressMode, observed: EgressMode?, name: InstanceName, host: String
  ) -> String? {
    let next =
      "Omit --egress to reuse it, or destroy it (`iso host vm destroy \(host) \(name)`) and run `iso host up` again."
    guard let observed else {
      return
        "\(name) on \(host) did not report its egress, so --egress \(requested.rawValue) cannot be confirmed. \(next)"
    }
    guard observed != requested else { return nil }
    return
      "\(name) on \(host) was created with egress \(observed.rawValue); --egress \(requested.rawValue) does not change an existing VM. \(next)"
  }

  private func create(
    _ env: HostCommandEnvironment, _ remote: RemoteHost, _ instanceName: InstanceName,
    _ store: ClientBindingStore
  ) throws -> ClientBinding {
    try remote.requireEnabled()
    let mode = egress ?? env.config.egress
    let spec = try VMSpec.make(
      name: instanceName, image: ImageName(image), imageDigest: nil,
      cpus: UInt32(env.config.vm.vcpuCount), memoryMiB: UInt64(env.config.vm.memory.mib.value),
      diskGiB: UInt64(env.config.vm.templateSize.value), guestOS: .linux, egress: mode)
    let id = SubmittedOperation.fresh()
    let receipt = try submit(
      remote, .vmCreate(spec), operation: id, wait: .seconds(1_800), output: env.output)
    guard succeeded(receipt), let instance = receipt.instance else {
      throw HostError(describe(receipt))
    }
    let created = ClientBinding(
      host: remote.enrollment.alias, hostID: instance.hostID, ownerID: instance.ownerID,
      instanceID: instance.instanceID, runtimeID: instance.runtimeID, guestOS: instance.guestOS,
      name: instanceName, policyHash: spec.policyHash, createdBy: id.id,
      lastState: .stopped, lastObservedAt: receipt.completedAt?.seconds)
    try store.save(created)
    env.output.out("Created \(instanceName) on \(remote.enrollment.alias)")
    return created
  }
}

struct HostForward: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "forward",
    abstract: "Forward client loopback ports to a remote VM for as long as its session lives")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Option(
    help:
      "Forward a guest port to client loopback (`GUEST[:HOST]`, repeatable), as `iso up --forward-port`",
    transform: parsePortForward)
  var forwardPort: [PortForward] = []
  @Argument(
    help:
      "Older form: LOCAL[:GUEST] port pairs (note the reversed order); cannot be mixed with --forward-port"
  )
  var ports: [String] = []

  func validate() throws {
    if !ports.isEmpty && !forwardPort.isEmpty {
      throw UsageError(
        "give ports either as --forward-port GUEST[:HOST] or as positional LOCAL[:GUEST], not both")
    }
    guard !ports.isEmpty || !forwardPort.isEmpty else {
      throw UsageError("give at least one port (--forward-port GUEST[:HOST])")
    }
    _ = try parsed()
  }

  /// Every forward as `PortForward(guest:host:)`; the older grammar's
  /// reversed `LOCAL[:GUEST]` is turned around here and nowhere else. Every
  /// listener binds 127.0.0.1 on the client, whichever grammar named it.
  func parsed() throws -> [PortForward] {
    if !forwardPort.isEmpty { return forwardPort }
    return try ports.map { spec in
      let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
      guard (1...2).contains(parts.count), let local = UInt16(parts[0]), local > 0,
        let guest = UInt16(parts.count == 2 ? parts[1] : parts[0]), guest > 0
      else { throw ArgumentParser.ValidationError("invalid port spec '\(spec)'") }
      return try PortForward(guest: guest, host: local)
    }
  }

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let binding = try env.binding(remote, name)
      let forwards = try parsed()
      try withSession(env, remote, binding) { target in
        guard let ssh = SSHClient(environment: env.environment).sshExecutable() else {
          throw HostError("ssh is not installed")
        }
        // Client loopback only; the forward lives inside the relayed session,
        // so revocation or expiry closes it.
        let arguments =
          target.sshOptions + ["-N", "-o", "ExitOnForwardFailure=yes"]
          + forwards.flatMap { ["-L", "127.0.0.1:\($0.host):127.0.0.1:\($0.guest)"] }
          + [target.address]
        env.output.out(
          forwards.map { "127.0.0.1:\($0.host) -> \(binding.name):\($0.guest)" }.joined(
            separator: ", "))
        let termination = try ProcessRunner().attached(
          .init(
            executable: ssh, arguments: arguments,
            environment: SSHClient.transportEnvironment(env.environment), deadline: .seconds(0)),
          inheritStdin: false, deadline: nil)
        if !termination.succeeded { throw ExitCode(termination.exitStatus) }
      }
    }
  }
}

struct HostEditor: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "editor",
    abstract: "Open a sandboxed code or zed editor on a remote VM through its host relay")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Argument(help: "code or zed") var editor: String
  @Option(
    name: [.customLong("guest-path"), .customLong("path")],
    help: "Guest directory to open (an absolute path inside the VM, never a host path)")
  var guestPath: String = guestWorkspace.rawValue

  func run() throws {
    try IsoCLI.run {
      guard let provider = EditorProviderID(rawValue: editor) else {
        throw HostError("editor must be code or zed")
      }
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let binding = try env.binding(remote, name)
      let guestPath = try GuestPath.absolute(self.guestPath)
      let observation = try VMObservation(
        wire: try remote.client.call(.vmInspect(binding.instance)))
      guard let egress = observation.egress else {
        throw HostError("the host did not report this VM's egress")
      }
      let session = try ClientSessionCoordinator.open(
        host: remote, binding: binding, config: env.config, environment: env.environment,
        client: env.clientLabel, purpose: .editor)
      defer { session.finish() }
      session.startRenewing(diagnostics: env.diagnostics)
      let target = try session.guestTarget(config: env.config)
      // The editor is supervised against the session: a lost grant (expiry,
      // revocation, stop) ends it and cleans its enclave.
      try EditorLauncher(
        environment: env.environment, diagnostics: env.diagnostics, security: env.config.editor,
        home: ProcessInfo.processInfo.environment["HOME"]
      ).launchRemote(
        guest: target,
        .remote(name: binding.name, guestPath: guestPath, egress: egress),
        choice: .only(provider.provider),
        revalidate: {
          if let failure = session.failure { throw failure }
        })
    }
  }
}

struct HostAgent: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "agent",
    abstract: "Run Claude or Codex in a remote VM; credentials stay on this client")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Argument(help: "claude or codex") var agent: String
  @Flag(help: "Prompt for permissions instead of skipping them (claude)") var ask = false
  @Argument(parsing: .postTerminator, help: "Arguments passed to the agent") var args: [String] = []

  func run() throws {
    try IsoCLI.run {
      guard let kind = RemoteAgent(rawValue: agent) else {
        throw HostError("agent must be claude or codex")
      }
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let binding = try env.binding(remote, name)
      let observation = try VMObservation(
        wire: try remote.client.call(.vmInspect(binding.instance)))
      // Every `vault:` reference resolves through the one local store.
      CredentialResolver.processSecrets = StoreSecretResolver.shared(
        EnclaveStore(directory: env.config.dataDirectory.appending("secrets").path))
      let session = try ClientSessionCoordinator.open(
        host: remote, binding: binding, config: env.config, environment: env.environment,
        client: env.clientLabel)
      defer { session.finish() }
      session.startRenewing(diagnostics: env.diagnostics)
      let extra = kind == .claude && ask ? ["--permission-mode", "default"] + args : args
      let code = try kind.run(
        session: session, binding: binding, config: env.config, vmEgress: observation.egress,
        environment: env.environment,
        home: ProcessInfo.processInfo.environment["HOME"], diagnostics: env.diagnostics,
        arguments: extra)
      if let failure = session.failure { env.output.error("session ended: \(failure.message)") }
      if code != 0 { throw ExitCode(code) }
    }
  }
}

struct HostRun: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run",
    abstract: "Run a command in a disposable remote VM and collect ~/iso-results",
    discussion:
      "The run is attached: if this client goes away, the host stops the VM and keeps what it can for one hour (`iso host run-results`). Unlike `iso run`, which launches an agent in a local project environment, this runs a plain command and always uses a new VM."
  )

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Option(help: "Client project directory to push", completion: .directory) var dir: String = "."
  @Option var image: String = ImageName.default.rawValue
  @Option(help: "VM lifetime (default: 1h; at most 24h)", transform: parseDurationArgument)
  var ttl: Duration?
  @Option(name: .customLong("output-limit-mib")) var outputLimitMiB: UInt64 = 64
  @Option(help: "none or filtered keeps one recovery boot possible; open does not")
  var egress: EgressMode = .none
  @Argument(parsing: .postTerminator, help: "Command to run in /workspace") var command: [String]

  func run() throws {
    try IsoCLI.run {
      guard !command.isEmpty else { throw HostError("give a command after --") }
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      try remote.requireEnabled()
      guard let project = canonicalPath(dir) else { throw HostError("\(dir) does not exist") }
      let seconds = ttlSeconds(ttl, default: 3_600)
      let runID = RunID.generate()
      let spec = try VMSpec.make(
        name: InstanceName("run-" + runID.rawValue.prefix(8)), image: ImageName(image),
        imageDigest: nil, cpus: UInt32(env.config.vm.vcpuCount),
        memoryMiB: UInt64(env.config.vm.memory.mib.value),
        diskGiB: UInt64(env.config.vm.templateSize.value), guestOS: .linux, egress: egress)
      let limit = outputLimitMiB << 20
      let created = try submit(
        remote, .runCreate(run: runID, spec: spec, outputLimitBytes: limit, ttlSeconds: seconds),
        operation: .fresh(), wait: .seconds(1_800), output: env.output)
      guard succeeded(created) else { throw HostError(describe(created)) }
      env.output.error("run \(runID) is running")
      var run = try RunObservation(wire: try remote.client.call(.runInspect(runID)))
      guard let instanceID = run.instanceID, let runtime = run.runtimeID else {
        throw HostError("the run has no VM identity")
      }
      let binding = ClientBinding(
        host: remote.enrollment.alias, hostID: remote.enrollment.hostID,
        ownerID: remote.enrollment.ownerID, instanceID: instanceID, runtimeID: runtime,
        guestOS: .linux, name: spec.name, policyHash: spec.policyHash,
        createdBy: created.operationID,
        lastState: nil, lastObservedAt: nil)
      // The session is the run's controlling lease: losing it lets the host stop the VM.
      let completion = HostOperationID.generate()
      let status: Int32 = try withSession(env, remote, binding) { target in
        try RemoteWorkspace.push(
          target, source: project, config: env.config, binding: binding, force: true,
          environment: env.environment, diagnostics: env.diagnostics)
        guard let ssh = SSHClient(environment: env.environment).sshExecutable() else {
          throw HostError("ssh is not installed")
        }
        let termination = try ProcessRunner().attached(
          .init(
            executable: ssh,
            arguments: target.sshOptions + [
              "-T", target.address,
              "mkdir -p ~/\(runResultsDirectory) && " + InteractiveSSH.render(command),
            ],
            environment: SSHClient.transportEnvironment(env.environment), deadline: .seconds(0)),
          inheritStdin: true, deadline: nil)
        let code = termination.exitStatus
        // Complete while the session still holds the run's lease, so the
        // host exports before it stops rather than treating this as a loss.
        let current = try RunObservation(wire: try remote.client.call(.runInspect(runID)))
        _ = try remote.client.call(
          .runComplete(run: runID, expectedGeneration: current.generation, exitStatus: code),
          operation: completion)
        return code
      }
      let completed = try remote.client.wait(completion, timeout: .seconds(900))
      run = try RunObservation(wire: try remote.client.call(.runInspect(runID)))
      guard run.phase == .resultsPending else {
        throw HostError(
          "\(describe(completed)); results were not exported (\(run.phase.rawValue)). Recover or discard with `iso host run-results \(host) \(runID)`"
        )
      }
      let acknowledged = try finishResults(env, remote, run, limit: limit)
      // The run's client workspace record and port slot are not reused.
      RemoteWorkspace.removeRunState(env.config, binding)
      if status != 0 { throw ExitCode(status) }
      if !acknowledged { throw ExitCode.failure }
    }
  }
}

/// Downloads, stages and acknowledges a run's committed results; false when
/// the host's acknowledgement receipt did not succeed (the local stage stays).
private func finishResults(
  _ env: HostCommandEnvironment, _ remote: RemoteHost, _ run: RunObservation, limit: UInt64
) throws -> Bool {
  let stage = try RemoteRunResults.download(
    remote.client, run: run, config: env.config, host: remote.enrollment.hostID, limit: limit)
  env.output.out("Results: \(stage.path)")
  guard let digest = run.artifactDigest else { return true }
  let ack = try submit(
    remote,
    .runResultsAck(
      run: run.runID, expectedGeneration: run.generation, digest: digest, stage: stage.id),
    operation: .fresh(), wait: .seconds(600), output: env.output)
  env.output.error(describe(ack))
  return succeeded(ack)
}

struct HostRunResults: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "run-results",
    abstract: "Inspect, download, recover or discard a disposable run's retained results")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument(help: "Run id") var runID: String
  @Flag(help: "Spend the run's one restricted recovery boot to export results") var recover = false
  @Flag(help: "Delete the run's VM and results without downloading") var discard = false
  @Option(name: .customLong("output-limit-mib")) var outputLimitMiB: UInt64 = 256

  func validate() throws {
    if recover && discard {
      throw UsageError("the argument '--recover' cannot be used with '--discard'")
    }
  }

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      try perform(env, try env.resolve(host))
    }
  }

  func perform(_ env: HostCommandEnvironment, _ remote: RemoteHost) throws {
    let id = try RunID(runID)
    var observation = try RunObservation(wire: try remote.client.call(.runInspect(id)))
    env.output.out(
      "run \(id): \(observation.phase.rawValue)"
        + (observation.disposition.map { " (\($0))" } ?? ""))
    if discard {
      let receipt = try submit(
        remote, .runResultsDiscard(run: id, expectedGeneration: observation.generation),
        operation: .fresh(), wait: .seconds(600), output: env.output)
      try requireSucceeded(receipt, output: env.output)
      return
    }
    // A failed recovery still downloads results that are already pending,
    // then fails the command.
    var recovered = true
    if recover {
      let receipt = try submit(
        remote, .runResultsRecover(run: id, expectedGeneration: observation.generation),
        operation: .fresh(), wait: .seconds(900), output: env.output)
      env.output.out(describe(receipt))
      recovered = succeeded(receipt)
      observation = try RunObservation(wire: try remote.client.call(.runInspect(id)))
    }
    var acknowledged = true
    if observation.phase == .resultsPending {
      acknowledged = try finishResults(env, remote, observation, limit: outputLimitMiB << 20)
    }
    if !recovered || !acknowledged { throw ExitCode.failure }
  }
}
