import Foundation
import IsoConfiguration
import IsoCore

/// A native runtime failure as the supervisor must treat it.
package enum NativeFailure: Error, Sendable, Equatable {
  /// The runtime cannot be reached or is not qualified; nothing was attempted.
  case unavailable(String)
  /// A known failure; the observation that follows decides the disposition.
  case failed(String)
  /// The effect is unknown; the operation stays reconciling.
  case uncertain(String)
}

/// The guest SSH endpoint chosen from current native proof.
package struct GuestEndpoint: Sendable, Equatable {
  package enum Route: Sendable, Equatable {
    /// The guest's vmnet address.
    case tcp(address: IPv4Address, port: UInt16)
    /// A brokered guest: the runtime's stream connector, bound to the
    /// gate-approved boot and digests. It has no address to dial.
    case brokered(ConnectorCommand)
  }

  package let route: Route

  package init(address: IPv4Address, port: UInt16) {
    route = .tcp(address: address, port: port)
  }

  package init(brokered connector: ConnectorCommand) { route = .brokered(connector) }
}

/// The native lifecycle seam under `HostSupervisor`. Production uses
/// `AppleNativeHost`, which reuses `AppleBackend` so isolation proof, host-key
/// pinning and the runtime owner's deadline are unchanged; tests use a fake.
/// Every call is synchronous and addresses one owned runtime object.
package protocol NativeHost: Sendable {
  func qualification() -> RuntimeQualification
  func observe(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure) -> NativeState
  /// Creates the stopped VM under the reserved runtime name. Its first boot
  /// (guest host-key enrollment) is bounded by the runtime owner.
  func create(_ instance: InstanceID, runtime: MachineName, spec: VMSpec, owner: OwnerID)
    throws(NativeFailure)
  /// Boots with a fixed deadline the runtime owner enforces independently.
  func start(_ instance: InstanceID, runtime: MachineName, expiresAt: Date?) throws(NativeFailure)
  /// Stops through the runtime, without guest cooperation.
  func stop(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure)
  /// Deletes the exact owned runtime object and its worker-side records.
  func delete(_ instance: InstanceID, runtime: MachineName, owner: OwnerID) throws(NativeFailure)
  func guestEndpoint(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure)
    -> GuestEndpoint
  /// For a running brokered VM: the network proof of a fresh gate pass of
  /// its current boot (spec 6.2). Nil for vmnet VMs; throws when a brokered
  /// boot fails the gate.
  func networkProof(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure)
    -> NetworkProof?
  /// Whether `image` is prepared on this worker (its own manifest, verified
  /// against the runtime); a client-side record never counts.
  func imageReady(_ image: ImageName) -> Bool
  /// Builds or confirms `request.image`; idempotent by manifest, so a
  /// reconciling retry repeats it safely. Returns the published identity.
  func ensureImage(_ request: ImageRequest) throws(NativeFailure) -> String
  /// Stopped-VM maintenance through the existing native journals.
  func maintain(_ instance: InstanceID, runtime: MachineName, _ change: Maintenance)
    throws(NativeFailure)
  /// For a filtered-egress VM: the worker's native egress proof for the live
  /// boot, then its recorded boot policy. Nil for other egress modes.
  func filteredPolicy(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure)
    -> FilteredGrantPolicy?
  /// The unprivileged guest account clients log in as.
  func guestUser(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure) -> GuestUser
  /// The guest's pinned SSH host key line (`ssh-ed25519 <base64>`).
  func guestHostKey(_ instance: InstanceID, runtime: MachineName) throws(NativeFailure) -> String
  /// Adds a client session key to the guest's authorized keys (idempotent).
  func authorizeClientKey(_ instance: InstanceID, runtime: MachineName, key: ClientPublicKey)
    throws(NativeFailure)
  /// Best-effort hygiene only: removal does not terminate existing streams.
  func removeClientKey(_ instance: InstanceID, runtime: MachineName, key: ClientPublicKey)
  /// A tar of the guest's fixed results directory over the worker's own
  /// pinned bootstrap route, at most `limit` bytes. The bytes are untrusted.
  func exportResults(_ instance: InstanceID, runtime: MachineName, limit: UInt64)
    throws(NativeFailure) -> [UInt8]
}

/// The guest directory a disposable run's results are collected from,
/// relative to the guest user's home.
package let runResultsDirectory = "iso-results"

/// `NativeHost` over the existing concrete Apple backend. Each host-control
/// instance keeps its native records in an ordinary instance directory named
/// `hc-<instance id>`, so `AppleLifecycle`'s journals stay the native layer.
package struct AppleNativeHost: NativeHost {
  /// The first (enrollment) boot inside `vm.create` is bounded too.
  static let creationBootSeconds: TimeInterval = 15 * 60

  let backend: AppleBackend

  /// The service's backend is the sole writer of adopted instances.
  package init(backend: AppleBackend) { self.backend = backend.asServiceWriter() }

  static func instanceName(_ id: InstanceID) -> InstanceName {
    // Cannot fail: "hc-" plus a canonical UUID is 39 characters of [a-z0-9-].
    try! InstanceName("hc-" + id.rawValue)
  }

  /// The native record: `hc-<id>` for instances the service created, or a
  /// legacy instance directory adopted by migration (its marker names `id`).
  private func instance(_ id: InstanceID) throws(NativeFailure) -> Instance? {
    let name = Self.instanceName(id)
    do {
      let all = try InstanceStore.list(backend.config, skipped: { _, _ in })
      return all.first { $0.name == name } ?? all.first { (try? ServiceAdoption.load($0)) == id }
    } catch { throw .unavailable("worker instance records are unreadable") }
  }

  private func require(_ id: InstanceID) throws(NativeFailure) -> Instance {
    guard let instance = try instance(id) else {
      throw .failed("worker has no native record for instance \(id)")
    }
    return instance
  }

  /// The backend under this VM's creation-time network policy, so start,
  /// stop and every guest route use the egress the VM was created with,
  /// not whatever the worker's configuration says today.
  private func scoped(_ instance: Instance) throws(NativeFailure) -> AppleBackend {
    let recorded: NetworkPolicy?
    do { recorded = try NetworkPolicy.load(instance) } catch {
      throw .failed("the VM's network policy record is unreadable")
    }
    // No record means the creation-time policy cannot be established: refuse
    // rather than fall back to today's configuration.
    guard let recorded, let mode = EgressMode(rawValue: recorded.mode) else {
      throw .failed("the VM has no recorded network policy; destroy and recreate it")
    }
    return backend.reconfigured(
      backend.config.overridingEgress(mode).overridingTransport(recorded.recordedTransport))
  }

  private func runtime() throws(NativeFailure) -> SandboxRuntime {
    do { return try backend.runtime() } catch { throw .unavailable(error.description) }
  }

  package func qualification() -> RuntimeQualification {
    do {
      return .qualified(try backend.runtime().requireQualified())
    } catch {
      return .unqualified(HostControlError.sanitize(error.description))
    }
  }

  package func observe(_ id: InstanceID, runtime name: MachineName) throws(NativeFailure)
    -> NativeState
  {
    let runtime = try runtime()
    do {
      guard try runtime.listed(name) != nil else { return .absent }
      let inspection = try runtime.inspect(name)
      switch inspection.status {
      case .stopped: return .stopped
      case .running:
        guard let live = inspection.live, let boot = try? BootID(live.bootId) else {
          return .unhealthy("running without a boot identity")
        }
        return .running(boot: boot, address: live.ipv4?.description, expiresAt: nil)
      case .booting: return .unhealthy("booting")
      case .crashed: return .unhealthy("crashed")
      }
    } catch {
      throw .uncertain(HostControlError.sanitize(error.description))
    }
  }

  package func create(_ id: InstanceID, runtime name: MachineName, spec: VMSpec, owner: OwnerID)
    throws(NativeFailure)
  {
    guard spec.guestOS == .linux else { throw .failed("only Linux guests are created here") }
    guard let value = UInt32(exactly: spec.memoryMiB), let mib = MiB(value),
      let memory = try? VmMemory(mib)
    else { throw .failed("invalid memory size") }
    guard let cpus = UInt8(exactly: spec.cpus) else { throw .failed("invalid cpu count") }
    let config = backend.config.overridingVM(vcpus: cpus, memory: memory, templateSize: nil)
      .overridingEgress(spec.egress)
    let scoped = backend.reconfigured(config)
    do {
      let instance =
        try self.instance(id)
        ?? Instance.allocate(
          config, name: Self.instanceName(id), image: spec.image, workspacePath: nil)
      try scoped.createAndStart(
        instance, diskGiB: spec.diskGiB, machine: name,
        expiresAt: Date().addingTimeInterval(Self.creationBootSeconds))
      try scoped.stopUnproven(instance)
    } catch let error as NativeFailure {
      throw error
    } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
  }

  package func start(_ id: InstanceID, runtime _: MachineName, expiresAt: Date?)
    throws(NativeFailure)
  {
    let instance = try require(id)
    do { try scoped(instance).startExisting(instance, expiresAt: expiresAt) } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
  }

  package func stop(_ id: InstanceID, runtime name: MachineName) throws(NativeFailure) {
    if let instance = try instance(id) {
      do { try scoped(instance).stopUnproven(instance) } catch {
        throw .uncertain(HostControlError.sanitize("\(error)"))
      }
      return
    }
    // No worker record: stop the owned runtime object directly.
    let runtime = try runtime()
    do { _ = try runtime.stop(name) } catch {
      throw .uncertain(HostControlError.sanitize(error.description))
    }
  }

  package func delete(_ id: InstanceID, runtime name: MachineName, owner: OwnerID)
    throws(NativeFailure)
  {
    guard name.belongs(to: owner) else { throw .failed("runtime object is not owned") }
    if let instance = try instance(id) {
      do { try backend.destroyInstance(instance) } catch {
        throw .uncertain(HostControlError.sanitize("\(error)"))
      }
      return
    }
    let runtime = try runtime()
    do {
      if try runtime.listed(name) != nil { try runtime.delete(name, owner: owner) }
    } catch { throw .uncertain(HostControlError.sanitize(error.description)) }
  }

  package func imageReady(_ image: ImageName) -> Bool {
    guard let manifest = try? ImageManifest.load(backend.config, image), manifest.guestOS == .linux,
      let runtime = try? backend.runtime()
    else { return false }
    return (try? runtime.verifyImage(manifest)) != nil
  }

  package func ensureImage(_ request: ImageRequest) throws(NativeFailure) -> String {
    guard request.guestOS == .linux else { throw .failed("only Linux images are built here") }
    do {
      let profiles = try resolveProfiles(request.profiles, backend.config)
      try backend.setup(
        SetupOptions(
          rebuild: request.rebuild, profiles: profiles, image: request.image,
          guestUser: request.guestUser, builderTimeout: nil))
      let manifest = try ImageManifest.load(backend.config, request.image)
      return "\(manifest.imageRef) \(manifest.digest) manifest \(manifest.manifestID)"
    } catch let error as RuntimeError {
      if case .unavailable(let reason) = error { throw .unavailable(reason) }
      throw .failed(HostControlError.sanitize(error.description))
    } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
  }

  package func maintain(_ id: InstanceID, runtime _: MachineName, _ change: Maintenance)
    throws(NativeFailure)
  {
    let instance = try require(id)
    let backend = try scoped(instance)
    do {
      switch change {
      case .resize(let cpus, let memory, let disk):
        if let disk {
          let stopped = try backend.asStopped(instance)
          // Growing to the current size is already done (a reconciling retry).
          if try backend.currentDiskGiB(stopped) < disk {
            try backend.resizeDisk(stopped, toGiB: disk)
          }
        }
        if cpus != nil || memory != nil {
          try backend.setMachineResources(
            try backend.asStopped(instance), memoryMiB: memory.flatMap { UInt32(exactly: $0) },
            vcpus: cpus.flatMap { UInt8(exactly: $0) }, startAfter: false)
        }
      case .commit(let image):
        try backend.commitDisk(try backend.asStopped(instance), image: image)
      case .restore(let image):
        try backend.restoreDisk(try backend.asStopped(instance), image: image)
      }
    } catch let error as RuntimeError {
      if case .operationUncertain(let reason) = error { throw .uncertain(reason) }
      throw .failed(HostControlError.sanitize(error.description))
    } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
  }

  package func filteredPolicy(_ id: InstanceID, runtime _: MachineName) throws(NativeFailure)
    -> FilteredGrantPolicy?
  {
    let instance = try require(id)
    let backend = try scoped(instance)
    guard backend.config.egress == .filtered else { return nil }
    do {
      // The transport proof: owner lock, live boot, egress companion and its
      // guest-path readiness, recorded policy. Broker keys are the client's.
      guard try backend.asBootstrapRunning(instance) != nil,
        let policy = try FilteredHandoff.recordedPolicy(instance)
      else { throw NativeFailure.failed("FILTERED_EGRESS_NOT_READY: the VM is not running") }
      return FilteredGrantPolicy(
        bootID: try BootID(policy.bootID), policyHash: try BootID(policy.policyHash))
    } catch let error as NativeFailure {
      throw error
    } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
  }

  package func guestUser(_ id: InstanceID, runtime _: MachineName) throws(NativeFailure)
    -> GuestUser
  {
    let instance = try require(id)
    do { return try backend.ownedSidecar(instance).guestUser } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
  }

  package func guestHostKey(_ id: InstanceID, runtime _: MachineName) throws(NativeFailure)
    -> String
  {
    let instance = try require(id)
    guard let bytes = try? StateStore.readControlFile(instance.knownHostsPath),
      let text = String(validating: bytes, as: UTF8.self)
    else { throw .failed("the guest host key is not pinned") }
    // `<machine>.iso ssh-ed25519 <base64>`: the pin written at enrollment.
    let fields = text.split(whereSeparator: \.isWhitespace)
    guard fields.count >= 3,
      let key = try? HostPublicKey(parsing: "ssh-ed25519 " + fields[2])
    else { throw .failed("the guest host key pin is malformed") }
    return "ssh-ed25519 " + key.base64
  }

  private func guestCommand(_ id: InstanceID, _ command: RemoteCommand) throws(NativeFailure) {
    let instance = try require(id)
    let target: SSHTarget
    do { target = try scoped(instance).sshTarget(instance) } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
    guard SSHClient(environment: backend.environment).capture(target, command.rendered) != nil
    else { throw .failed("guest key update failed") }
  }

  package func authorizeClientKey(_ id: InstanceID, runtime _: MachineName, key: ClientPublicKey)
    throws(NativeFailure)
  {
    let line = key.line
    let command = RemoteCommand().literal(
      "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF "
    )
    .arg(line).literal(" ~/.ssh/authorized_keys || printf '%s\\n' ").arg(line)
    .literal(" >> ~/.ssh/authorized_keys)")
    try guestCommand(id, command)
  }

  package func removeClientKey(_ id: InstanceID, runtime _: MachineName, key: ClientPublicKey) {
    let command = RemoteCommand().literal("f=~/.ssh/authorized_keys; [ -f \"$f\" ] && grep -vxF ")
      .arg(key.line).literal(" \"$f\" > \"$f.iso\"; mv \"$f.iso\" \"$f\"")
    try? guestCommand(id, command)
  }

  package func exportResults(_ id: InstanceID, runtime _: MachineName, limit: UInt64)
    throws(NativeFailure) -> [UInt8]
  {
    let instance = try require(id)
    let client = SSHClient(environment: backend.environment)
    guard let ssh = client.sshExecutable() else { throw .unavailable("ssh is not installed") }
    do {
      let target = try scoped(instance).sshTarget(instance)
      try target.requireHandoff()
      // A fixed, iso-authored command: the archive root never comes from a request.
      let command = RemoteCommand().literal("mkdir -p ").arg(runResultsDirectory)
        .literal(" && tar cf - -C ").arg(runResultsDirectory).literal(" .")
      let output = try ProcessRunner().capture(
        .init(
          executable: ssh, arguments: target.sshOptions + [target.address, command.rendered],
          environment: SSHClient.transportEnvironment(backend.environment),
          deadline: SSHClient.captureDeadline, outputLimit: Int(clamping: limit)))
      guard output.termination == .exited(0) else {
        throw NativeFailure.failed("result export exited unsuccessfully")
      }
      return output.stdout
    } catch let error as NativeFailure {
      throw error
    } catch ProcessRunner.Failure.outputLimitExceeded {
      throw .failed("results exceed the run's output limit")
    } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
  }

  package func networkProof(_ id: InstanceID, runtime _: MachineName) throws(NativeFailure)
    -> NetworkProof?
  {
    guard let instance = try instance(id) else { return nil }
    let backend = try scoped(instance)
    guard backend.config.network.transport == .brokered else { return nil }
    do {
      let route = try backend.brokeredRoute(instance)
      return NetworkProof(
        bootID: route.bootID, networkPolicy: route.networkPolicy,
        channelPolicy: route.channelPolicy)
    } catch {
      throw .failed(HostControlError.sanitize("\(error)"))
    }
  }

  package func guestEndpoint(_ id: InstanceID, runtime name: MachineName) throws(NativeFailure)
    -> GuestEndpoint
  {
    // A brokered VM's last hop is the runtime connector, chosen from a fresh
    // gate pass, never an address (spec 4.2).
    if let instance = try instance(id) {
      let backend = try scoped(instance)
      if backend.config.network.transport == .brokered {
        do {
          return GuestEndpoint(brokered: try backend.brokeredRelayCommand(instance))
        } catch {
          throw .failed(HostControlError.sanitize("\(error)"))
        }
      }
    }
    let runtime = try runtime()
    do {
      let inspection = try runtime.inspect(name)
      guard inspection.status == .running, let address = inspection.ipv4 else {
        throw NativeFailure.failed("guest is not running")
      }
      return GuestEndpoint(address: address, port: 22)
    } catch let error as NativeFailure {
      throw error
    } catch {
      throw .uncertain(HostControlError.sanitize("\(error)"))
    }
  }
}
