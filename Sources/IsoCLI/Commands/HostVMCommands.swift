import ArgumentParser
import Foundation
import IsoConfiguration
import IsoCore
import IsoHost

/// Remote VM lifecycle through the host service. Every mutation has a
/// durable operation id; `--operation-id` retries the same one.
struct HostVM: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "vm", abstract: "Create, start, stop, destroy and inspect remote VMs",
    subcommands: [
      HostVMList.self, HostVMCreate.self, HostVMStart.self, HostVMStop.self, HostVMDestroy.self,
      HostVMInspect.self, HostVMResize.self, HostVMCommit.self, HostVMRestore.self,
    ])
}

struct OperationOption: ParsableArguments {
  @Option(
    name: .customLong("operation-id"),
    help: "Retry a previously submitted operation with its original id")
  var operationID: String?

  func resolve() throws -> SubmittedOperation {
    SubmittedOperation(
      id: try operationID.map { try HostOperationID($0) } ?? .generate(), resendable: true)
  }
}

struct HostVMList: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "List the host's VMs with fresh observations")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      var cursor: InstanceID?
      repeat {
        let page = try remote.client.call(.vmList(cursor: cursor, limit: 200))
        guard case .array(let items)? = page["instances"] else {
          throw HostError("malformed vm.list result")
        }
        for item in items {
          let observation = try VMObservation(wire: item)
          env.output.out(
            "\(observation.name)\t\(observation.state.rawValue)\tgen \(observation.generation)\t\(observation.instance.instanceID)"
          )
        }
        cursor = try page["next_cursor"].map { value throws in
          try InstanceID(try WireObject.string(value, field: "next_cursor"))
        }
      } while cursor != nil
    }
  }
}

struct HostVMCreate: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "create", abstract: "Create a stopped Linux VM on the host")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument(help: "Display name, unique per host on this client") var name: String
  @Option var image: String = ImageName.default.rawValue
  @Option(name: [.customLong("vcpus"), .customLong("cpus")], help: "Number of vCPUs")
  var cpus: UInt32 = 2
  @Option(name: [.customLong("mem"), .customLong("memory-mib")], help: "Memory in MiB")
  var memoryMiB: UInt64 = 4_096
  @Option(
    name: [.customLong("disk"), .customLong("disk-gib")], help: "Disk size in GiB",
    transform: parseAbsoluteDiskGiB)
  var diskGiB: UInt64 = 16
  @Option(help: "open, none or filtered") var egress: EgressMode = .open
  @OptionGroup var operation: OperationOption

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      try remote.requireEnabled()
      let instanceName = try InstanceName(name)
      let store = ClientBindingStore(config: env.config)
      if let existing = try store.load(remote.enrollment.hostID, instanceName),
        existing.lastState != .destroyed, operation.operationID == nil
      {
        throw HostError("'\(instanceName)' is already bound on \(remote.enrollment.alias)")
      }
      let spec = try VMSpec.make(
        name: instanceName, image: ImageName(image), imageDigest: nil, cpus: cpus,
        memoryMiB: memoryMiB, diskGiB: diskGiB, guestOS: .linux, egress: egress)
      let id = try operation.resolve()
      let receipt = try submit(
        remote, .vmCreate(spec), operation: id, wait: .seconds(1_800), output: env.output)
      if let instance = receipt.instance {
        try store.save(
          ClientBinding(
            host: remote.enrollment.alias, hostID: instance.hostID, ownerID: instance.ownerID,
            instanceID: instance.instanceID, runtimeID: instance.runtimeID,
            guestOS: instance.guestOS, name: instanceName, policyHash: spec.policyHash,
            // A successful create leaves the VM stopped; any other outcome
            // is not an observation.
            createdBy: id.id, lastState: succeeded(receipt) ? .stopped : nil,
            lastObservedAt: succeeded(receipt) ? receipt.completedAt?.seconds : nil))
      }
      try requireSucceeded(receipt, output: env.output)
    }
  }
}

/// Fresh observation of a bound instance (its generation is the precondition).
private func observe(_ remote: RemoteHost, _ binding: ClientBinding) throws -> VMObservation {
  try VMObservation(wire: try remote.client.call(.vmInspect(binding.instance)))
}

struct HostVMStart: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "start", abstract: "Boot a VM with a finite host-enforced deadline")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Option(
    help: "Boot lifetime (\"30m\", \"8h\"; at most 24h)", transform: parseDurationArgument)
  var ttl: Duration?
  @OptionGroup var operation: OperationOption

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      try remote.requireEnabled()
      let binding = try env.binding(remote, name)
      let seconds = ttlSeconds(ttl, default: env.config.execution.remote.defaultSessionTTL)
      let current = try observe(remote, binding)
      let receipt = try submit(
        remote,
        .vmStart(
          binding.instance, expectedGeneration: current.generation, ttlSeconds: seconds,
          policy: binding.policyHash), operation: try operation.resolve(), wait: .seconds(600),
        output: env.output)
      env.output.out(describe(receipt))
      if let expiry = receipt.expiresAt { env.output.out("Deadline: \(expiry.date)") }
      guard succeeded(receipt) else { throw ExitCode.failure }
    }
  }
}

struct HostVMStop: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "stop", abstract: "Stop a VM and verify it stopped")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @OptionGroup var operation: OperationOption

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let binding = try env.binding(remote, name)
      let current = try observe(remote, binding)
      let receipt = try submit(
        remote, .vmStop(binding.instance, expectedGeneration: current.generation),
        operation: try operation.resolve(), wait: .seconds(600), output: env.output
      )
      try requireSucceeded(receipt, output: env.output)
    }
  }
}

struct HostVMDestroy: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "destroy", abstract: "Delete exactly this VM and verify its absence")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @OptionGroup var operation: OperationOption

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let binding = try env.binding(remote, name)
      let current = try observe(remote, binding)
      let receipt = try submit(
        remote, .vmDestroy(binding.instance, expectedGeneration: current.generation),
        operation: try operation.resolve(), wait: .seconds(600), output: env.output
      )
      try requireSucceeded(receipt, output: env.output)
      // Only a verified destroy releases the name. The binding is kept, marked
      // destroyed, so its completed stages stay reviewable and applicable.
      let observation = try observe(remote, binding)
      if observation.state == .destroyed {
        RemoteWorkspace.releasePorts(env.config, binding)
        var updated = binding
        updated.lastState = .destroyed
        updated.lastObservedAt = observation.observedAt.seconds
        try ClientBindingStore(config: env.config).save(updated)
      }
    }
  }
}

struct HostVMInspect: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "inspect", abstract: "Show a fresh observation, or unknown when unreachable")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      var binding = try env.binding(remote, name)
      do {
        let observation = try observe(remote, binding)
        binding.lastState = observation.state
        binding.lastObservedAt = observation.observedAt.seconds
        try ClientBindingStore(config: env.config).save(binding)
        env.output.out("\(binding.name) on \(binding.host): \(observation.state.rawValue)")
        env.output.out("  instance \(binding.instanceID) generation \(observation.generation)")
        if let boot = observation.bootID { env.output.out("  boot \(boot)") }
        if let expiry = observation.expiresAt { env.output.out("  deadline \(expiry.date)") }
        if let active = observation.activeOperation {
          env.output.out("  active operation \(active)")
        }
      } catch let error as HostControlError where error.code == .hostUnreachable {
        // Unreachable is unknown, never stopped; the last observation is history.
        env.output.out("\(binding.name) on \(binding.host): unknown (host unreachable)")
        if let last = binding.lastState, let at = binding.lastObservedAt {
          env.output.out(
            "  last observed \(last.rawValue) at \(Date(timeIntervalSince1970: TimeInterval(at)))")
        }
      }
    }
  }
}

struct HostShell: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "shell",
    abstract: "Open a shell (or run a command) in a remote VM through its host relay")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Argument(parsing: .postTerminator, help: "Command to run instead of a login shell")
  var command: [String] = []

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let binding = try env.binding(remote, name)
      let session = try ClientSessionCoordinator.open(
        host: remote, binding: binding, config: env.config, environment: env.environment,
        client: env.clientLabel)
      defer { session.finish() }
      session.startRenewing(diagnostics: env.diagnostics)
      guard let ssh = SSHClient(environment: env.environment).sshExecutable() else {
        throw HostError("ssh is not installed")
      }
      let remoteCommand =
        command.isEmpty
        ? [] : [command.map { RemoteCommand().arg($0).rendered }.joined(separator: " ")]
      let termination = try ProcessRunner().attached(
        .init(
          executable: ssh,
          arguments: ["-F", session.sshConfigPath, command.isEmpty ? "-t" : "-T", session.sshAlias]
            + remoteCommand,
          environment: SSHClient.transportEnvironment(env.environment), deadline: .seconds(0)),
        inheritStdin: true, deadline: nil)
      if let failure = session.failure { env.output.error("session ended: \(failure.message)") }
      if !termination.succeeded { throw ExitCode(termination.exitStatus) }
    }
  }
}

struct HostSession: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "session",
    abstract: "Hold a renewed access session for a remote VM and print an ssh config for it",
    discussion:
      "Runs in the foreground until Ctrl-C, or with --detach as a coordinator that outlives this command; other `iso host` commands reuse a live coordinator's session."
  )

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Flag(help: "Run the coordinator in the background") var detach = false
  @Flag(help: "End this binding's background coordinator") var stop = false

  func validate() throws {
    if detach && stop { throw UsageError("the argument '--detach' cannot be used with '--stop'") }
  }

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      let binding = try env.binding(remote, name)
      if stop {
        env.output.out(
          CoordinatorRecord.stop(env.config, binding)
            ? "Stopping the coordinator" : "No coordinator is running")
        return
      }
      if let live = CoordinatorRecord.live(env.config, binding) {
        env.output.out("ssh -F \(live.sshConfig) \(live.alias)")
        return
      }
      if detach {
        let log = try RemoteWorkspace.shadow(env.config, binding).directory + "/coordinator.log"
        let pid = try CoordinatorRecord.spawnDetached(
          arguments: (env.configPath.map { ["--config", $0] } ?? []) + [
            "host", "session", host, name,
          ],
          environment: env.environment, log: log)
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
          if let live = CoordinatorRecord.live(env.config, binding), live.pid == pid {
            env.output.out("ssh -F \(live.sshConfig) \(live.alias)")
            return
          }
          if kill(pid, 0) != 0 { break }
          Thread.sleep(forTimeInterval: 0.2)
        }
        throw HostError("the coordinator did not start; see \(log)")
      }
      let ownership = try CoordinatorRecord.claim(env.config, binding)
      defer { ownership.release() }
      let session = try ClientSessionCoordinator.open(
        host: remote, binding: binding, config: env.config, environment: env.environment,
        client: env.clientLabel)
      defer { session.finish() }
      // SIGINT/SIGTERM end the loop so the grant is closed, not left to expire.
      let signals = Shutdown.install()
      defer { signals.restore() }
      session.startRenewing(diagnostics: env.diagnostics)
      try CoordinatorRecord.publish(session, config: env.config, binding: binding)
      defer { CoordinatorRecord.withdraw(env.config, binding) }
      env.output.out("ssh -F \(session.sshConfigPath) \(session.sshAlias)")
      while session.failure == nil, !Shutdown.isRequested {
        Thread.sleep(forTimeInterval: 0.5)
      }
    }
  }
}

struct HostImage: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "image",
    abstract: "Build or confirm an image on the host from its own build context")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Option var image: String = ImageName.default.rawValue
  @Option(
    name: .customLong("profile"),
    help: "Profile resolved on the host (repeatable or comma-separated)",
    transform: parseProfileList)
  var profiles: [[String]] = []
  @Option(name: .customLong("guest-user")) var guestUser: String = GuestUser.default.rawValue
  @Flag(help: "Rebuild even when the image is current") var rebuild = false
  @OptionGroup var operation: OperationOption

  func run() throws {
    try IsoCLI.run {
      let env = try HostCommandEnvironment(global)
      let remote = try env.resolve(host)
      try remote.requireEnabled()
      let request = try ImageRequest(
        image: ImageName(image), guestOS: .linux, profiles: profiles.flatMap { $0 },
        guestUser: GuestUser(guestUser), rebuild: rebuild)
      // Builds keep their own deadline; this only bounds how long we watch.
      let receipt = try submit(
        remote, .imageEnsure(request), operation: try operation.resolve(), wait: .seconds(7_200),
        output: env.output)
      try requireSucceeded(receipt, output: env.output)
    }
  }
}

/// Stopped-VM maintenance; the host service dispatches it only for `local`.
private func maintain(
  _ global: GlobalOptions, _ host: String, _ name: String, _ operation: OperationOption,
  _ change: Maintenance
) throws {
  let env = try HostCommandEnvironment(global)
  let remote = try env.resolve(host)
  let binding = try env.binding(remote, name)
  let current = try observe(remote, binding)
  let receipt = try submit(
    remote, .maintenance(binding.instance, expectedGeneration: current.generation, change),
    operation: try operation.resolve(), wait: .seconds(1_800), output: env.output)
  try requireSucceeded(receipt, output: env.output)
}

struct HostVMResize: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "resize", abstract: "Change a stopped VM's CPUs, memory or disk (local only)")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @Option(name: [.customLong("vcpus"), .customLong("cpus")], help: "New number of vCPUs")
  var cpus: UInt32?
  @Option(name: [.customLong("mem"), .customLong("memory-mib")], help: "New memory in MiB")
  var memoryMiB: UInt64?
  @Option(
    name: [.customLong("disk"), .customLong("disk-gib")],
    help: "Grow the disk to this absolute size in GiB (relative sizes are local `iso resize` only)",
    transform: parseAbsoluteDiskGiB)
  var diskGiB: UInt64?
  @OptionGroup var operation: OperationOption

  func run() throws {
    try IsoCLI.run {
      try maintain(
        global, host, name, operation,
        try Maintenance.validatedResize(cpus: cpus, memoryMiB: memoryMiB, diskGiB: diskGiB))
    }
  }
}

/// `--image IMAGE`, with the older positional IMAGE kept as a compatibility
/// spelling; giving both is refused.
struct MaintenanceImageArguments: ParsableArguments {
  @Argument(
    help: ArgumentHelp("Older positional form of --image", visibility: .hidden),
    transform: parseImageName)
  var positional: ImageName?
  @Option(help: "Image name", transform: parseImageName) var image: ImageName?

  func validate() throws {
    switch (positional, image) {
    case (nil, nil):
      throw UsageError("the following required arguments were not provided:\n  --image <IMAGE>")
    case (.some, .some):
      throw UsageError("give the image once: --image IMAGE, not also as a positional")
    default: break
    }
  }

  /// Present once `validate` has run.
  var resolved: ImageName? { image ?? positional }
}

/// The service resizes to an absolute size; `+20` would otherwise parse as
/// 20 GiB, not as the relative growth local `iso resize --disk +20` means.
func parseAbsoluteDiskGiB(_ text: String) throws -> UInt64 {
  guard !text.hasPrefix("+") else {
    throw UsageError(
      "--disk on a host VM is an absolute size in GiB; relative sizes such as \(text) are only for local `iso resize`"
    )
  }
  guard let value = UInt64(text) else {
    throw UsageError("--disk expects whole GiB, got \(debugQuoted(text))")
  }
  return value
}

struct HostVMCommit: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "commit", abstract: "Save a stopped VM's disk as an image (local only)")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @OptionGroup var imageArguments: MaintenanceImageArguments
  @OptionGroup var operation: OperationOption

  func run() throws {
    try IsoCLI.run {
      guard let image = imageArguments.resolved else { throw UsageError("--image is required") }
      try maintain(global, host, name, operation, .commit(image))
    }
  }
}

struct HostVMRestore: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "restore", abstract: "Replace a stopped VM's disk from an image (local only)")

  @OptionGroup var global: GlobalOptions
  @Argument var host: String
  @Argument var name: String
  @OptionGroup var imageArguments: MaintenanceImageArguments
  @OptionGroup var operation: OperationOption

  func run() throws {
    try IsoCLI.run {
      guard let image = imageArguments.resolved else { throw UsageError("--image is required") }
      try maintain(global, host, name, operation, .restore(image))
    }
  }
}
