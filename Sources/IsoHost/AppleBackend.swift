import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// The one concrete backend (S-01): Apple Containerization through
/// `iso-sandbox`. This slice covers the read-only probes that `list`,
/// `status` and `logs` need; lifecycle operations arrive with phase 3.
public final class AppleBackend: Sendable {
  public static let name = "apple-container"

  public let config: IsoConfig
  let environment: [String: String]
  public let diagnostics: Diagnostics
  let executable: String?
  /// Resolved and qualified once per process; a resolution failure is not
  /// cached, so the next call retries (baseline behavior).
  private let cachedRuntime = Mutex<SandboxRuntime?>(nil)
  private let runtimeFactory: @Sendable () throws(RuntimeError) -> SandboxRuntime

  public init(
    config: IsoConfig, environment: [String: String], executable: String?,
    diagnostics: Diagnostics = Diagnostics(verbosity: 0)
  ) {
    self.config = config
    self.environment = environment
    self.diagnostics = diagnostics
    self.executable = executable
    runtimeFactory = { () throws(RuntimeError) in
      try SandboxRuntime.open(config, environment: environment, executable: executable)
    }
  }

  /// Test seam: a runtime built from a scripted executor.
  init(
    config: IsoConfig, environment: [String: String],
    diagnostics: Diagnostics = Diagnostics(verbosity: 0),
    runtime: @escaping @Sendable () throws(RuntimeError) -> SandboxRuntime
  ) {
    self.config = config
    self.environment = environment
    self.diagnostics = diagnostics
    executable = nil
    runtimeFactory = runtime
  }

  /// The same runtime (resolved and qualified at most once per process)
  /// under a command's overridden configuration.
  public func reconfigured(_ config: IsoConfig) -> AppleBackend {
    let base = self
    return AppleBackend(
      config: config, environment: environment, diagnostics: diagnostics,
      runtime: { () throws(RuntimeError) in try base.runtime() })
  }

  public func runtime() throws(RuntimeError) -> SandboxRuntime {
    if let runtime = cachedRuntime.withLock({ $0 }) { return runtime }
    let runtime = try runtimeFactory()
    cachedRuntime.withLock { $0 = runtime }
    return runtime
  }

  /// A running, gate-verified instance with its pinned SSH target.
  public struct Running: Sendable {
    public let instance: Instance
    public let sidecar: MachineSidecar
    public let ready: IsolationGate.Ready
    public let target: SSHTarget
  }

  /// Owner, no pending journal, sidecar, and ownership check.
  public func ownedSidecar(_ instance: Instance) throws -> MachineSidecar {
    let owner = try Owner.load(config)
    if let journal = try Journal.loadIfPresent(instance) {
      throw RuntimeError.operationUncertain(
        "instance '\(instance.name)' has an unfinished \(journal.op.describe); \(journal.op.recoveryHint(instance.name))"
      )
    }
    guard let sidecar = try MachineSidecar.loadIfPresent(instance) else {
      throw HostError(
        "Instance '\(instance.name)' has no Apple sandbox record at \(MachineSidecar.path(instance))"
      )
    }
    try sidecar.checkOwner(owner)
    return sidecar
  }

  /// For listings: true only for a running sandbox; a missing record is
  /// stopped; a pending journal or a booting sandbox is an error.
  public func probeRunning(_ instance: Instance) throws -> Bool {
    if let journal = try Journal.loadIfPresent(instance) {
      throw RuntimeError.operationUncertain(
        "instance '\(instance.name)' has an unfinished \(journal.op.describe)")
    }
    guard let sidecar = try MachineSidecar.loadIfPresent(instance) else { return false }
    switch try runtime().inspect(sidecar.machineID).status {
    case .running: return true
    case .stopped, .crashed: return false
    case .booting: throw RuntimeError.operationUncertain("sandbox \(sidecar.machineID) is booting")
    }
  }

  /// Best-effort: every error counts as not running.
  public func isRunning(_ instance: Instance) -> Bool {
    guard let sidecar = try? MachineSidecar.loadIfPresent(instance),
      let inspection = try? runtime().inspect(sidecar.machineID)
    else { return false }
    return inspection.status == .running
  }

  /// Nil when stopped; a running sandbox must pass qualification and the
  /// isolation gate before its SSH target is handed out.
  public func asRunning(_ instance: Instance) throws -> Running? {
    let sidecar = try ownedSidecar(instance)
    let runtime = try runtime()
    let inspection = try runtime.inspect(sidecar.machineID)
    switch inspection.status {
    case .stopped: return nil
    case .crashed, .booting:
      throw RuntimeError.operationUncertain(
        "sandbox \(sidecar.machineID) is \(inspection.status.rawValue)")
    case .running: break
    }
    do {
      try NetworkPolicy.enforce(instance, config: config)
      _ = try runtime.requireQualified()
      let ready = try IsolationGate.verifyEffective(
        inspection,
        .init(
          sandbox: sidecar.machineID, owner: sidecar.ownerID, runtimeRoot: runtime.root,
          resources: sidecar.resources, egress: config.egress))
      let target = try SSHTarget.pinned(
        config: config, instance: instance, machine: sidecar.machineID, ip: ready.ipv4,
        user: sidecar.guestUser)
      let sandboxDir = "\(runtime.root)/sandboxes/\(sidecar.machineID.rawValue)"
      let bootPolicy =
        config.egress == .filtered ? try FilteredHandoff.recordedPolicy(instance) : nil
      let live = EgressLease.liveIdentity(at: sandboxDir + "/live.json")
      if let failure = FilteredHandoff.prove(
        filtered: config.egress == .filtered,
        recordedBootID: bootPolicy?.bootID,
        liveBootID: inspection.live?.bootId,
        ownerLockHeld: EgressLease.ownerLockHeld(at: sandboxDir + "/owner.lock"),
        companionAlive: ProxyLauncher.recordedProcessAlive(
          ProxyLauncher.pidPath(instance, "egress"), expect: .egress),
        tunnelAlive: ProxyLauncher.recordedProcessAlive(
          ProxyLauncher.forwardPIDPath(instance, "egress"), expect: .ssh),
        advertisedProtocol: runtime.advertisedProtocol,
        recordedPolicyHash: bootPolicy?.policyHash,
        wantedPolicyHash: NetworkPolicy.make(config).policyHash,
        ownerMatches: live?.bootID == inspection.live?.bootId
          && live?.pid == sidecar.lastObservedOwnerPID && live?.pid == inspection.live?.pid
      ) {
        throw HostError(
          "FILTERED_EGRESS_NOT_READY: \(failure) for '\(instance.name)'. The VM is still running; `iso stop \(instance.name)` does not connect to the guest."
        )
      }
      return Running(instance: instance, sidecar: sidecar, ready: ready, target: target)
    } catch {
      throw ContextError(
        "Instance '\(instance.name)' is running but cannot be reached safely; `iso stop \(instance.name)` stops it without connecting to the guest",
        cause: error)
    }
  }

  /// The pinned target of an instance whatever its state (Rust
  /// `ssh_target`): qualification and the isolation gate still apply, so a
  /// stopped sandbox yields an error rather than a target.
  public func sshTarget(_ instance: Instance) throws -> SSHTarget {
    let sidecar = try ownedSidecar(instance)
    let runtime = try runtime()
    let inspection = try runtime.inspect(sidecar.machineID)
    _ = try runtime.requireQualified()
    let ready = try IsolationGate.verifyEffective(
      inspection,
      .init(
        sandbox: sidecar.machineID, owner: sidecar.ownerID, runtimeRoot: runtime.root,
        resources: sidecar.resources, egress: config.egress))
    return try SSHTarget.pinned(
      config: config, instance: instance, machine: sidecar.machineID, ip: ready.ipv4,
      user: sidecar.guestUser)
  }

  /// `iso status NAME` text for a running instance, without the usage line.
  public func describe(_ running: Running) throws -> String {
    let sidecar = try ownedSidecar(running.instance)
    let runtime = try runtime()
    let inspection = try runtime.inspect(sidecar.machineID)
    let identity: String
    switch runtime.qualification {
    case .success(let value): identity = value
    case .failure(let error): identity = "unqualified (\(error))"
    }
    let ip = inspection.ipv4?.description ?? "unavailable"
    let network =
      inspection.effective?.interfaces.first.map { sanitizeForDisplay($0.network) } ?? "unavailable"
    return """
      Instance '\(running.instance.name)' (\(inspection.status.rawValue))
        Backend: apple-container (iso-sandbox)
        Runtime: \(identity)
        Sandbox: \(sidecar.machineID)
        Network: \(network) (dedicated)
        vCPUs: \(inspection.record.cpus)
        Memory: \(inspection.record.memoryBytes / (1 << 20)) MiB
        Disk: \(Self.gib(inspection.disk.logicalBytes)) GiB (\(Self.gib(inspection.disk.allocatedBytes)) GiB allocated)
        Address: \(ip) (host key \(sidecar.hostKeyFingerprint))
        Workspace: copied (no live mounts)
      """
  }

  /// Longest guest console line passed on.
  public static let maxLogLine = 64 << 10

  /// Guest console output, one sanitized line per call. A snapshot is
  /// spooled (runtime stdout and stderr together) and printed only after the
  /// runtime succeeds; following streams stdout lines and forwards stderr.
  public func streamLogs(
    _ running: Running, follow: Bool, line emit: (String) throws -> Void, stderr: (String) -> Void
  ) throws {
    let sidecar = try ownedSidecar(running.instance)
    let runtime = try runtime()
    let decode = { (bytes: [UInt8]) in sanitizeForDisplay(String(decoding: bytes, as: UTF8.self)) }
    if follow {
      var out = BoundedLineSplitter(limit: Self.maxLogLine)
      var err = BoundedLineSplitter(limit: Self.maxLogLine)
      let termination = try runtime.logs(sidecar.machineID, follow: true) { stream, bytes in
        if stream == .stdout {
          try out.feed(bytes) { try emit(decode($0)) }
        } else {
          err.feed(bytes) { stderr(decode($0)) }
        }
      }
      try out.finish { try emit(decode($0)) }
      err.finish { stderr(decode($0)) }
      guard termination == .exited(0) else {
        throw HostError("`iso-sandbox logs` exited with \(Self.rustExitCode(termination))")
      }
      return
    }
    var spool: [UInt8] = []
    let termination = try runtime.logs(sidecar.machineID, follow: false) { _, bytes in
      spool.append(contentsOf: bytes)
    }
    guard termination == .exited(0) else {
      throw HostError("`iso-sandbox logs` failed: \(decode(Array(spool.suffix(2048))))")
    }
    var splitter = BoundedLineSplitter(limit: Self.maxLogLine)
    try splitter.feed(spool[...]) { try emit(decode($0)) }
    try splitter.finish { try emit(decode($0)) }
  }

  /// Rust `Option<i32>` debug text of an exit status.
  static func rustExitCode(_ termination: ProcessRunner.Termination) -> String {
    switch termination {
    case .exited(let code): "Some(\(code))"
    case .signaled: "None"
    }
  }

  /// The running instance a command acts on: the named one (which must be
  /// running), or the only running instance.
  public func resolveRunning(_ name: InstanceName?, instances: [Instance]) throws -> Running {
    if let name {
      guard let instance = instances.first(where: { $0.name == name }) else {
        throw HostError("No instance named '\(name)'.\nCreate one with: iso up . --name \(name)")
      }
      guard let running = try asRunning(instance) else {
        throw HostError("Instance '\(name)' is not running.\nStart it with: iso start \(name)")
      }
      return running
    }
    let running = instances.filter { isRunning($0) }
    let stopped = instances.filter { !running.contains($0) }
    switch running.count {
    case 1:
      guard let target = try asRunning(running[0]) else {
        throw HostError("Instance stopped unexpectedly while resolving")
      }
      return target
    case 0 where stopped.count == 1:
      let name = stopped[0].name
      throw HostError(
        "Instance '\(name)' exists but is stopped.\nStart it with: iso start \(name)")
    case 0 where stopped.isEmpty:
      throw HostError(
        "No instances found.\nCreate one with: iso up\n(Run `iso setup` first if you haven't built an image yet.)"
      )
    case 0:
      throw HostError(
        "No running instances. Stopped: \(stopped.map(\.name.rawValue).joined(separator: ", "))\nStart one with: iso start <name>"
      )
    default:
      throw HostError(
        "Multiple running instances. Specify one: \(running.map(\.name.rawValue).joined(separator: ", "))"
      )
    }
  }

  /// Tenths of a GiB, truncated: `12.3`.
  static func gib(_ bytes: UInt64) -> String {
    let tenths = bytes.multipliedFullWidth(by: 10)
    let value = UInt64((UInt128(tenths.high) << 64 | UInt128(tenths.low)) / (1 << 30))
    return "\(value / 10).\(value % 10)"
  }
}

/// An error with added context, rendered like anyhow's `{:?}`:
/// the context, then `Caused by:` and the cause.
public struct ContextError: Error, CustomStringConvertible {
  public let context: String
  public let cause: any Error

  public init(_ context: String, cause: any Error) {
    self.context = context
    self.cause = cause
  }

  public var description: String {
    var causes: [String] = []
    var next: (any Error)? = cause
    while let error = next {
      if let wrapped = error as? ContextError {
        causes.append(wrapped.context)
        next = wrapped.cause
      } else {
        causes.append("\(error)")
        next = nil
      }
    }
    if causes.count == 1 { return "\(context)\n\nCaused by:\n    \(causes[0])" }
    return "\(context)\n\nCaused by:\n"
      + causes.enumerated().map { "    \($0.offset): \($0.element)" }.joined(separator: "\n")
  }

  /// anyhow `{:#}`: context and causes joined by `: `.
  public var alternate: String {
    var parts = [context]
    var next: (any Error)? = cause
    while let error = next {
      if let wrapped = error as? ContextError {
        parts.append(wrapped.context)
        next = wrapped.cause
      } else {
        parts.append("\(error)")
        next = nil
      }
    }
    return parts.joined(separator: ": ")
  }
}
