import Foundation
import IsoConfiguration
import IsoCore

/// macOS guests on the same backend: `iso-sandbox macos …` sandboxes
/// cloned from a template that `iso setup --guest macos` built. The guest's
/// SSH host key comes from the runtime, which pinned it over the
/// authenticated guest-helper channel and has the helper confirm it on
/// every boot; the host never trusts a key on first use.
extension AppleBackend {
  /// One runtime inspection of a sandbox, whatever its guest OS, gated as
  /// that inspection: status, boot and gate never come from different
  /// snapshots.
  package enum Observed: Sendable {
    case linux(SandboxInspection)
    case macos(MacInspection, template: MachineName)

    package var status: SandboxStatus {
      switch self {
      case .linux(let i): i.status
      case .macos(let i, _): i.status
      }
    }

    package var bootID: String? {
      switch self {
      case .linux(let i): i.live?.bootId
      case .macos(let i, _): i.live?.bootId
      }
    }

    package var ownerPID: Int32? {
      switch self {
      case .linux(let i): i.live?.pid
      case .macos(let i, _): i.live?.pid
      }
    }

    func gate(_ expected: IsolationGate.Expected) throws(RuntimeError) -> IsolationGate.Ready {
      switch self {
      case .linux(let i): try IsolationGate.verifyEffective(i, expected)
      case .macos(let i, let template):
        try IsolationGate.verifyMacEffective(i, expected, template: template, helper: .pinned)
      }
    }
  }

  func observe(_ runtime: SandboxRuntime, _ sidecar: MachineSidecar) throws -> Observed {
    switch sidecar.kind {
    case .linux: return .linux(try runtime.inspect(sidecar.machineID))
    case .macos:
      try runtime.requireMacGuests()
      return .macos(
        try runtime.macInspect(sidecar.machineID), template: try Self.macTemplate(sidecar))
    }
  }

  /// A macOS instance records its template as its image reference.
  static func macTemplate(_ sidecar: MachineSidecar) throws(RuntimeError) -> MachineName {
    do { return try MachineName(sidecar.imageRef) } catch {
      throw .identityConflict(
        "macOS instance records template \(debugQuoted(sanitizeForDisplay(sidecar.imageRef)))")
    }
  }

  /// macOS boots and enrolls more slowly than a Linux guest: at least five
  /// minutes, or the configured boot timeout when that is longer.
  func macBootDeadline(_ runtime: SandboxRuntime) -> ContinuousClock.Instant {
    ContinuousClock.now + max(runtime.settings.bootTimeout.duration, .seconds(300))
  }

  // MARK: Boot

  /// Start the owner, wait for the guest helper to connect and confirm the
  /// pinned host key on this boot, then gate it once.
  func macBootValidated(
    _ runtime: SandboxRuntime, _ expected: IsolationGate.Expected, template: MachineName,
    until deadline: ContinuousClock.Instant, sessionTTL: SessionTTL?
  ) throws -> (IsolationGate.Ready, HostPublicKey) {
    let name = expected.sandbox
    do {
      try runtime.macStart(
        name, expiresAt: sessionTTL.map { Date().addingTimeInterval(TimeInterval($0.seconds)) })
    } catch {
      throw RuntimeError.bootTimeout("sandbox \(name) failed to boot: \(error)")
    }
    var reason = "owner starting"
    while true {
      try Shutdown.check()
      let inspection = try runtime.macInspect(name)
      try IsolationGate.verifyMacRecord(inspection, expected, template: template)
      switch inspection.status {
      case .stopped, .crashed:
        throw RuntimeError.bootTimeout(
          "sandbox \(name) \(inspection.status.rawValue) during boot (\(reason))")
      default: break
      }
      if let pending = IsolationGate.macPending(inspection) {
        reason = pending
      } else {
        let ready = try IsolationGate.verifyMacEffective(
          inspection, expected, template: template, helper: .confirmedThisBoot)
        guard let text = inspection.sshHostKey, text == inspection.runtime?.sshHostKey else {
          throw RuntimeError.hostKeyChanged(
            "sandbox \(name) reports different pinned and confirmed host keys")
        }
        return (ready, try HostPublicKey(parsing: text))
      }
      guard ContinuousClock.now < deadline else {
        throw RuntimeError.bootTimeout("sandbox \(name) was not ready in time: \(reason)")
      }
      sleep(.seconds(1))
    }
  }

  // MARK: Create

  func macProvisionSandbox(
    _ instance: Instance, runtime: SandboxRuntime, owner: Owner, manifest: ImageManifest,
    machine: MachineName, authorizedKey: String, journal: inout Journal
  ) throws {
    let template = try MachineName(manifest.imageRef)
    let cpus = UInt32(config.vm.vcpuCount)
    let memoryMiB = UInt64(config.vm.memory.mib.value)
    try NetworkPolicy.save(config, instance)
    try journal.advance(instance, .create(stage: .creatingMachine))
    try runtime.macCreate(
      machine, template: template, cpus: cpus, memoryMiB: memoryMiB, owner: owner.id,
      egress: config.egress, authorizedKey: authorizedKey)
    try journal.advance(instance, .create(stage: .machineCreated))
    var sidecar = MachineSidecar(
      schemaVersion: StateSchema.version, backend: StateSchema.backend, ownerID: owner.id,
      machineID: machine, imageRef: manifest.imageRef, imageDigest: manifest.digest,
      imageManifestID: manifest.manifestID, guestUser: manifest.guestUser, requestedCPUs: cpus,
      requestedMemoryBytes: memoryMiB * (1 << 20), hostKeyFingerprint: "",
      lastObservedOwnerPID: nil, lastObservedIP: nil, reenrollHostKey: false,
      createdAt: utcTimestamp(), runtimeIdentity: try runtime.requireQualified(), guestOS: .macos)
    try IsolationGate.verifyMacRecord(
      try runtime.macInspect(machine), expected(sidecar, runtime), template: template)
    let deadline = macBootDeadline(runtime)
    let (ready, key) = try macBootValidated(
      runtime, expected(sidecar, runtime), template: template, until: deadline,
      sessionTTL: config.limits.sessionTTL)
    try HostKeyPin.apply(.enroll, instance: instance, machine: machine, key: key)
    try waitForSSH(instance, ready, user: manifest.guestUser, until: deadline)
    sidecar.hostKeyFingerprint = key.fingerprint
    sidecar.lastObservedOwnerPID = ready.ownerPID
    sidecar.lastObservedIP = ready.ipv4
    try sidecar.save(instance)
  }

  /// The installation's one public key, authorized for the guest user at
  /// enrollment (Linux images bake it in instead).
  static func authorizedKey(_ config: IsoConfig) throws -> String {
    let path = config.sshKeyPath.path + ".pub"
    guard let bytes = try StateStore.readControlFile(path),
      let text = String(validating: bytes, as: UTF8.self)
    else { throw HostError("Missing \(path); run `iso setup` first") }
    return "ssh-ed25519 \(try HostPublicKey(parsing: text).base64)"
  }

  /// Codex ChatGPT account auth keeps credentials in the Linux Secret
  /// Service, which macOS guests do not have.
  func requireMacSupportedConfig() throws {
    guard config.codexAuth != .chatgpt else {
      throw HostError(
        "Codex ChatGPT account auth (`\"codex\": {\"auth\": \"chatgpt\"}`) needs the Linux Secret Service; macOS guests do not support it"
      )
    }
  }

  // MARK: Start

  func macStartExisting(
    _ instance: Instance, runtime: SandboxRuntime, sidecar: inout MachineSidecar
  ) throws -> IsolationGate.Ready {
    try runtime.requireMacGuests()
    try requireMacSupportedConfig()
    let template = try Self.macTemplate(sidecar)
    let inspection = try runtime.macInspect(sidecar.machineID)
    switch inspection.status {
    case .stopped: break
    case .crashed: try NetworkPolicy.enforce(instance, config: config)
    case .running: throw HostError("Instance '\(instance.name)' is already running")
    case .booting:
      throw RuntimeError.operationUncertain(
        "sandbox \(sidecar.machineID) is booting; wait for it to settle")
    }
    try IsolationGate.verifyMacRecord(inspection, expected(sidecar, runtime), template: template)
    let deadline = macBootDeadline(runtime)
    do {
      let (ready, key) = try macBootValidated(
        runtime, expected(sidecar, runtime), template: template, until: deadline,
        sessionTTL: config.limits.sessionTTL)
      try HostKeyPin.apply(.requirePin, instance: instance, machine: sidecar.machineID, key: key)
      try waitForSSH(instance, ready, user: sidecar.guestUser, until: deadline)
      try NetworkPolicy.save(config, instance)
      return ready
    } catch {
      stopAfterFailure(runtime.namespace(.macos), sidecar.machineID)
      throw error
    }
  }

  // MARK: Delete

  /// Stop and delete `machine` through the namespace that holds it.
  func deleteListedSandbox(
    _ sandboxes: SandboxNamespace, _ instance: Instance, machine: MachineName, owner: Owner,
    journal: inout Journal?
  ) throws {
    if let listed = try sandboxes.listed(machine) {
      if listed != .stopped { try sandboxes.stopAndConfirm(machine) }
      if journal == nil {
        journal = try Journal.begin(
          instance, owner: owner, op: .destroy(stage: .reserved), machine: machine)
      }
      try journal!.advance(instance, .destroy(stage: .deletingMachine))
      try sandboxes.delete(machine, owner: owner.id)
      try journal!.advance(instance, .destroy(stage: .machineDeleted))
    }
    sandboxes.reconcileBestEffort(diagnostics: diagnostics)
  }

  // MARK: Status

  func macDescribe(_ running: Running, runtime: SandboxRuntime, identity: String) throws -> String {
    let inspection = try runtime.macInspect(running.sidecar.machineID)
    let network = inspection.effective.map { sanitizeForDisplay($0.network) } ?? "unavailable"
    return """
      Instance '\(running.instance.name)' (\(inspection.status.rawValue))
        Backend: apple-container (iso-sandbox, macOS guest)
        Runtime: \(identity)
        Sandbox: \(running.sidecar.machineID)
        Template: \(sanitizeForDisplay(inspection.record.template)) (\(sanitizeForDisplay(inspection.record.templateBuild)))
        Network: \(network) (dedicated)
        vCPUs: \(inspection.record.cpus)
        Memory: \(inspection.record.memoryBytes / (1 << 20)) MiB
        Address: \(running.ready.ipv4) (host key \(running.sidecar.hostKeyFingerprint))
        Workspace: copied (no live mounts)
      """
  }
}
