import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

/// Client-local association of a display name with one qualified remote
/// instance (spec 7.1 `ClientBinding`). It never claims authoritative
/// lifecycle; the worker's records do.
package struct ClientBinding: Codable, Sendable, Equatable {
  package var schema = 1
  package let host: HostAlias
  package let hostID: HostID
  package let ownerID: OwnerID
  package let instanceID: InstanceID
  package let runtimeID: MachineName
  package let guestOS: GuestOS
  package let name: InstanceName
  package let policyHash: SHA256Hex
  package let createdBy: HostOperationID
  /// The last observed VM state; never an operation's state.
  package var lastState: ObservedState?
  package var lastObservedAt: UInt64?

  package init(
    host: HostAlias, hostID: HostID, ownerID: OwnerID, instanceID: InstanceID,
    runtimeID: MachineName, guestOS: GuestOS, name: InstanceName, policyHash: SHA256Hex,
    createdBy: HostOperationID, lastState: ObservedState?, lastObservedAt: UInt64?
  ) {
    self.host = host
    self.hostID = hostID
    self.ownerID = ownerID
    self.instanceID = instanceID
    self.runtimeID = runtimeID
    self.guestOS = guestOS
    self.name = name
    self.policyHash = policyHash
    self.createdBy = createdBy
    self.lastState = lastState
    self.lastObservedAt = lastObservedAt
  }

  package var instance: QualifiedInstance {
    QualifiedInstance(
      hostID: hostID, ownerID: ownerID, instanceID: instanceID, runtimeID: runtimeID,
      guestOS: guestOS)
  }

  /// Earlier builds could record an operation state ("succeeded") here; such
  /// a value is not an observation and reads as none.
  package init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    host = try c.decode(HostAlias.self, forKey: .host)
    hostID = try c.decode(HostID.self, forKey: .hostID)
    ownerID = try c.decode(OwnerID.self, forKey: .ownerID)
    instanceID = try c.decode(InstanceID.self, forKey: .instanceID)
    runtimeID = try c.decode(MachineName.self, forKey: .runtimeID)
    guestOS = try c.decode(GuestOS.self, forKey: .guestOS)
    name = try c.decode(InstanceName.self, forKey: .name)
    policyHash = try c.decode(SHA256Hex.self, forKey: .policyHash)
    createdBy = try c.decode(HostOperationID.self, forKey: .createdBy)
    lastState = try c.decodeIfPresent(String.self, forKey: .lastState).flatMap {
      ObservedState(rawValue: $0)
    }
    lastObservedAt = try c.decodeIfPresent(UInt64.self, forKey: .lastObservedAt)
  }
}

/// Bindings under `<state root>/host-bindings/<host id>/<name>.json`, so
/// equal names on two hosts never collide.
package struct ClientBindingStore: Sendable {
  let root: String

  package init(config: IsoConfig) { root = config.stateRoot.appending("host-bindings").path }
  package init(root: String) { self.root = root }

  func path(_ host: HostID, _ name: InstanceName) -> String {
    root + "/" + host.rawValue + "/" + name.rawValue + ".json"
  }

  package func load(_ host: HostID, _ name: InstanceName) throws(HostError) -> ClientBinding? {
    guard let bytes = try StateStore.readControlFile(path(host, name)) else { return nil }
    return try StateStore.decode(ClientBinding.self, bytes, path: path(host, name))
  }

  package func save(_ binding: ClientBinding) throws(HostError) {
    try StateStore.ensurePrivateDirectory(root)
    try StateStore.ensurePrivateDirectory(root + "/" + binding.hostID.rawValue)
    try StateStore.writeControlFile(binding, to: path(binding.hostID, binding.name))
  }

  package func remove(_ host: HostID, _ name: InstanceName) throws(HostError) {
    try StateStore.removeIfPresent(path(host, name))
  }

  package func list(_ host: HostID) -> [ClientBinding] {
    let directory = root + "/" + host.rawValue
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    return names.sorted().compactMap { name in
      guard name.hasSuffix(".json"), let instance = try? InstanceName(String(name.dropLast(5)))
      else { return nil }
      return try? load(host, instance)
    }
  }
}

/// A resolved, enrolled remote host and its typed control client.
package struct RemoteHost: Sendable {
  package let enrollment: HostEnrollment
  package let client: HostControlClient

  /// Resolves `alias` through the registry. A disabled host is returned for
  /// observation and cleanup; `requireEnabled` gates new work.
  package static func resolve(
    _ alias: HostAlias, config: IsoConfig, environment: [String: String]
  ) throws -> RemoteHost {
    guard !alias.isLocal else { throw HostError("'local' is not a remote host") }
    guard let enrollment = try HostRegistry(config: config).load(alias) else {
      throw HostError("host '\(alias)' is not enrolled; run `iso host add \(alias) ...` first")
    }
    guard let ssh = SSHClient(environment: environment).sshExecutable() else {
      throw HostError("ssh is not installed")
    }
    let transport = SSHHostTransport(
      alias: enrollment.sshAlias, agent: enrollment.agentPath, ssh: ssh, environment: environment)
    return RemoteHost(
      enrollment: enrollment,
      client: HostControlClient(
        transport: transport, expected: (enrollment.hostID, enrollment.ownerID)))
  }

  /// This machine's own host service, started on demand. Its requests
  /// arrive on the local socket, so local-only capabilities are available.
  package static func local(config: IsoConfig, configPath: String?) throws -> RemoteHost {
    let paths = try HostService.ensureRunning(config: config, configPath: configPath)
    let store = try OperationStore(root: HostService.root(config))
    guard let installation = try store.loadInstallation() else {
      throw HostError("the local host service has no installation record")
    }
    guard let executable = Bundle.main.executablePath, let agent = try? AgentPath(executable) else {
      throw HostError("cannot resolve the iso executable path")
    }
    let enrollment = HostEnrollment(
      alias: .local, sshAlias: .local, agentPath: agent, hostID: installation.hostID,
      ownerID: installation.ownerID, enrolledAt: installation.createdAt)
    return RemoteHost(
      enrollment: enrollment,
      client: HostControlClient(
        transport: LocalHostTransport(paths: paths),
        expected: (installation.hostID, installation.ownerID)))
  }

  package func requireEnabled() throws {
    guard !enrollment.disabled else {
      throw HostError(
        "host '\(enrollment.alias)' is disabled for new work; enable it or use observation and cleanup only"
      )
    }
  }
}

/// The client's own ed25519 session key for remote guests,
/// `<state root>/host_client_key`. The private half never leaves the client.
package enum ClientSessionKey {
  package static func path(_ config: IsoConfig) -> String {
    config.stateRoot.appending("host_client_key").path
  }

  package static func ensure(_ config: IsoConfig, environment: [String: String]) throws
    -> ClientPublicKey
  {
    let key = path(config)
    if !FileManager.default.fileExists(atPath: key) {
      try StateStore.ensurePrivateDirectory(config.stateRoot.path)
      let output = try ProcessRunner().capture(
        .init(
          executable: "/usr/bin/ssh-keygen",
          arguments: ["-t", "ed25519", "-N", "", "-q", "-C", "iso-host-client", "-f", key],
          environment: environment, deadline: .seconds(60)))
      guard output.termination == .exited(0) else {
        throw HostError("Failed to generate the remote session key")
      }
    }
    guard let bytes = try StateStore.readControlFile(key + ".pub"),
      let text = String(validating: bytes, as: UTF8.self)
    else { throw HostError("Missing \(key).pub") }
    return try ClientPublicKey(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

/// One live access session held by this client process: opens the grant,
/// writes the private descriptor and an ssh config that routes through the
/// owned relay, renews every 10 seconds, and closes and removes its files on
/// `finish`. Renewal failure is terminal; the session is never revived.
package final class ClientSessionCoordinator: Sendable {
  package static let renewInterval: Duration = .seconds(10)

  package let grant: AccessGrant
  package let descriptorPath: String
  package let sshConfigPath: String
  package let sshAlias: String
  let host: RemoteHost
  let bearer: AccessBearer
  let knownHostsPath: String
  private let state = Mutex<(stopped: Bool, failure: HostControlError?)>((false, nil))

  private init(
    grant: AccessGrant, descriptorPath: String, sshConfigPath: String, sshAlias: String,
    host: RemoteHost, bearer: AccessBearer, knownHostsPath: String
  ) {
    self.grant = grant
    self.descriptorPath = descriptorPath
    self.sshConfigPath = sshConfigPath
    self.sshAlias = sshAlias
    self.host = host
    self.bearer = bearer
    self.knownHostsPath = knownHostsPath
  }

  package static func open(
    host: RemoteHost, binding: ClientBinding, config: IsoConfig, environment: [String: String],
    client: ClientLabel, purpose: AccessPurpose = .ssh
  ) throws -> ClientSessionCoordinator {
    let key = try ClientSessionKey.ensure(config, environment: environment)
    let hello = try host.client.hello(clientBuild: "iso")
    let observation = try VMObservation(wire: try host.client.call(.vmInspect(binding.instance)))
    guard observation.state == .running, let boot = observation.bootID,
      let policy = observation.policyHash
    else { throw HostError("instance '\(binding.name)' on \(binding.host) is not running") }
    let bearer = AccessBearer.generate()
    let session = SessionID.generate()
    let request = AccessOpenRequest(
      instance: binding.instance, expectedEpoch: hello.epoch, expectedBoot: boot,
      expectedGeneration: observation.generation, policyHash: policy, session: session,
      client: client, clientKey: key, purpose: purpose, bearer: bearer)
    let grant = try AccessGrant(wire: try host.client.call(.accessOpen(request)))
    guard grant.instance == binding.instance, grant.bootID == boot, grant.session == session else {
      throw HostError("the host returned a grant for a different session")
    }
    let directory = SessionDescriptor.directory(config)
    let base = directory + "/" + session.rawValue
    // Any failure from here on closes the grant and removes its private files.
    do {
      return try materialize(
        grant: grant, host: host, binding: binding, config: config, bearer: bearer, base: base)
    } catch {
      _ = try? host.client.call(.accessClose(session: session, bearer: bearer, epoch: grant.epoch))
      for suffix in [".json", ".known_hosts", ".ssh_config"] { unlink(base + suffix) }
      throw error
    }
  }

  private static func materialize(
    grant: AccessGrant, host: RemoteHost, binding: ClientBinding, config: IsoConfig,
    bearer: AccessBearer, base: String
  ) throws -> ClientSessionCoordinator {
    let session = grant.session
    guard let executable = Bundle.main.executablePath else {
      throw HostError("cannot resolve the iso executable path")
    }
    // These paths reach ssh's ProxyCommand (run by a shell) and rsync's -e.
    for path in [executable, base, ClientSessionKey.path(config)] {
      try ClientSessionCoordinator.requireRouteSafe(path)
    }
    let descriptor = SessionDescriptor(
      host: host.enrollment.alias, sshAlias: host.enrollment.sshAlias,
      agentPath: host.enrollment.agentPath, session: session, bearer: bearer, epoch: grant.epoch,
      instance: binding.instanceID, guestHostKey: grant.guestHostKey,
      localRelay: (host.client.transport as? LocalHostTransport)?.paths.relay)
    try descriptor.save(config)
    // Equal display names and guest IPs on different hosts get distinct aliases.
    let alias = "\(binding.name).\(host.enrollment.alias).iso-remote"
    try AtomicFile.write(
      Array("\(alias) \(grant.guestHostKey)\n".utf8), to: base + ".known_hosts",
      mode: .atMost(0o600))
    let proxy = RemoteCommand().arg(executable).literal(" host-agent connect --descriptor ")
      .arg(SessionDescriptor.path(config, session)).rendered
    let sshConfig = """
      Host \(alias)
        HostName \(alias)
        User \(grant.guestUser)
        IdentityFile \(ClientSessionKey.path(config))
        IdentitiesOnly yes
        IdentityAgent none
        HostKeyAlias \(alias)
        UserKnownHostsFile \(base).known_hosts
        GlobalKnownHostsFile /dev/null
        StrictHostKeyChecking yes
        UpdateHostKeys no
        ForwardAgent no
        ProxyCommand \(proxy)

      """
    try AtomicFile.write(Array(sshConfig.utf8), to: base + ".ssh_config", mode: .atMost(0o600))
    return ClientSessionCoordinator(
      grant: grant, descriptorPath: SessionDescriptor.path(config, session),
      sshConfigPath: base + ".ssh_config", sshAlias: alias, host: host, bearer: bearer,
      knownHostsPath: base + ".known_hosts")
  }

  /// Renews until `finish` or a renewal failure (which ends the session).
  package func startRenewing(diagnostics: Diagnostics) {
    Thread.detachNewThread { [self] in
      while true {
        Thread.sleep(forTimeInterval: Self.renewInterval.seconds)
        if state.withLock({ $0.stopped }) { return }
        do throws(HostControlError) {
          _ = try host.client.call(
            .accessRenew(
              session: grant.session, bearer: bearer, epoch: grant.epoch, boot: grant.bootID,
              policy: grant.policyHash))
        } catch {
          state.withLock { $0.failure = error }
          diagnostics.warn("remote session ended: \(error.message)")
          return
        }
      }
    }
  }

  package var failure: HostControlError? { state.withLock { $0.failure } }

  /// Closes the grant (best effort when the host is unreachable) and always
  /// removes the private files.
  package func finish() {
    state.withLock { $0.stopped = true }
    _ = try? host.client.call(
      .accessClose(session: grant.session, bearer: bearer, epoch: grant.epoch))
    for path in [descriptorPath, sshConfigPath, knownHostsPath] { unlink(path) }
  }
}

/// One remote row of an all-host listing: a fresh observation, or the
/// client's last record of a binding on a host that did not answer.
package enum RemoteListingRow: Sendable {
  case observed(host: HostAlias, VMObservation)
  case unreachable(ClientBinding)
}

package struct RemoteListing: Sendable {
  package var rows: [RemoteListingRow] = []
  /// Hosts that could not be listed; their bindings appear as unreachable rows.
  package var failures: [(host: HostAlias, error: HostControlError)] = []

  /// Lists every enrolled host, bounded per host; one host's failure never
  /// hides the others and never turns into a stopped state.
  package static func collect(config: IsoConfig, environment: [String: String]) throws
    -> RemoteListing
  {
    var listing = RemoteListing()
    let bindings = ClientBindingStore(config: config)
    for enrollment in try HostRegistry(config: config).list() {
      do {
        let host = try RemoteHost.resolve(
          enrollment.alias, config: config, environment: environment)
        var cursor: InstanceID?
        var pages = 0
        repeat {
          let page = try host.client.call(.vmList(cursor: cursor, limit: 200))
          guard case .array(let items)? = page["instances"] else {
            throw HostControlError.invalidRequest("malformed vm.list result")
          }
          for item in items {
            listing.rows.append(.observed(host: enrollment.alias, try VMObservation(wire: item)))
          }
          if let next = page["next_cursor"] {
            cursor = try InstanceID(try WireObject.string(next, field: "next_cursor"))
          } else {
            cursor = nil
          }
          pages += 1
        } while cursor != nil && pages < 50
      } catch {
        let failure =
          (error as? HostControlError)
          ?? HostControlError(.hostUnreachable, HostControlError.sanitize("\(error)"))
        listing.failures.append((enrollment.alias, failure))
        for binding in bindings.list(enrollment.hostID) {
          listing.rows.append(.unreachable(binding))
        }
      }
    }
    return listing
  }
}

extension ClientSessionCoordinator {
  /// The pinned guest route through this session's relay, usable by every
  /// existing transport (ssh, scp, rsync, tar). Refuses paths ssh could not
  /// carry unquoted inside a ProxyCommand or rsync `-e`.
  package func guestTarget(config: IsoConfig) throws -> SSHTarget {
    guard let executable = Bundle.main.executablePath else {
      throw HostError("cannot resolve the iso executable path")
    }
    let key = ClientSessionKey.path(config)
    for path in [executable, descriptorPath, key, knownHostsPath] {
      try Self.requireRouteSafe(path)
    }
    var target = SSHTarget(
      host: sshAlias, port: 22, user: grant.guestUser, keyPath: key, knownHosts: knownHostsPath,
      alias: sshAlias)
    target.proxyCommand = "\(executable) host-agent connect --descriptor \(descriptorPath)"
    return target
  }
}

extension ClientSessionCoordinator {
  /// Paths inside a ProxyCommand (shell-run, `%`-expanded) and rsync `-e`
  /// must be plain: `[A-Za-z0-9/._-]` only.
  package static func requireRouteSafe(_ path: String) throws {
    guard !path.isEmpty, path.unicodeScalars.allSatisfy({ $0 == "/" || isSafeNameCharacter($0) })
    else {
      throw HostError(
        "\(path) has characters the remote guest route cannot carry; use a data_dir and iso path of [A-Za-z0-9/._-]"
      )
    }
  }
}

/// Client-side state of one remote binding: workspace association and
/// completed stages live here, independent of the worker VM's lifetime, so a
/// stage stays reviewable and applicable when the host is offline or the VM
/// is destroyed.
package enum RemoteWorkspace {
  package static func directory(_ config: IsoConfig, _ binding: ClientBinding) -> String {
    config.stateRoot.appending("host-workspaces").path + "/" + binding.hostID.rawValue + "/"
      + binding.instanceID.rawValue
  }

  /// A client-local instance record whose directory holds `workspace.json`
  /// and `stage/`; it never names a local VM.
  /// `ports` reserves a client port slot (credential proxies and tunnels);
  /// workspace and stage use alone never take one.
  package static func shadow(_ config: IsoConfig, _ binding: ClientBinding, ports: Bool = false)
    throws -> Instance
  {
    let directory = directory(config, binding)
    try StateStore.ensurePrivateDirectory(config.stateRoot.appending("host-workspaces").path)
    try StateStore.ensurePrivateDirectory(
      config.stateRoot.appending("host-workspaces").path + "/" + binding.hostID.rawValue)
    try StateStore.ensurePrivateDirectory(directory)
    let index: InstanceIndex
    if ports {
      index = try shadowIndex(config, directory: directory)
    } else {
      // Unused for ports or addresses: no proxy or tunnel runs for this shadow.
      guard let unused = InstanceIndex(0) else {
        throw HostError("instance index 0 is out of range")
      }
      index = unused
    }
    return Instance(name: binding.name, index: index, directory: directory, image: .default)
  }

  /// Gives back a binding's client port slot (after destroy or a finished run).
  package static func releasePorts(_ config: IsoConfig, _ binding: ClientBinding) {
    unlink(directory(config, binding) + "/index")
  }

  /// Removes a finished disposable run's client state (not its results stage).
  package static func removeRunState(_ config: IsoConfig, _ binding: ClientBinding) {
    try? FileManager.default.removeItem(atPath: directory(config, binding))
  }

  /// The client-side port slot of a remote binding (credential-proxy and
  /// tunnel ports derive from it). Chosen once, from the top of the range,
  /// avoiding local instances and other remote bindings; a later collision
  /// fails closed when the port is found in use.
  static func shadowIndex(_ config: IsoConfig, directory: String) throws -> InstanceIndex {
    let path = directory + "/index"
    if let bytes = try StateStore.readControlFile(path),
      let value = UInt16(
        String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
      let index = InstanceIndex(value)
    {
      return index
    }
    var used = Set(
      (try? InstanceStore.list(config, skipped: { _, _ in }))?.map(\.index.value) ?? [])
    let root = config.stateRoot.appending("host-workspaces").path
    for host in (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] {
      let hostDirectory = root + "/" + host
      for instance in (try? FileManager.default.contentsOfDirectory(atPath: hostDirectory)) ?? [] {
        if let bytes = try? StateStore.readControlFile(hostDirectory + "/" + instance + "/index"),
          let value = UInt16(
            String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        {
          used.insert(value)
        }
      }
    }
    guard
      let free = stride(from: InstanceIndex.maximum, through: 0, by: -1).first(where: {
        !used.contains($0)
      }), let index = InstanceIndex(free)
    else { throw HostError("all client port slots are in use") }
    try AtomicFile.write(Array(String(free).utf8), to: path, mode: .atMost(0o600))
    return index
  }

  /// One-way push of a client directory to the guest workspace through the
  /// verified route; never bidirectional.
  package static func push(
    _ target: SSHTarget, source: String, config: IsoConfig, binding: ClientBinding, force: Bool,
    excludeGit: Bool, environment: [String: String], diagnostics: Diagnostics
  ) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: source, isDirectory: &isDirectory),
      isDirectory.boolValue, let canonical = canonicalPath(source)
    else { throw HostError("Source directory \(source) does not exist") }
    let client = SSHClient(environment: environment)
    let transfer = WorkspaceTransfer(client: client, diagnostics: diagnostics)
    let prepare = RemoteCommand().literal("sudo mkdir -p ").arg(guestWorkspace.rawValue)
      .literal(" && sudo chown \"$(id -u):$(id -g)\" ").arg(guestWorkspace.rawValue)
    guard client.capture(target, prepare.rendered) != nil else {
      throw HostError("could not prepare \(guestWorkspace) in the guest")
    }
    if !force { try transfer.checkGuestClean(target, guestWorkspace) }
    diagnostics.log(
      .info, "Pushing \(canonical) -> \(binding.host):\(binding.name):\(guestWorkspace)")
    if try transfer.guestHasRsync(target) {
      try transfer.rsyncPush(target, source: canonical, to: guestWorkspace, excludeGit: excludeGit)
    } else {
      try transfer.tarPipe(target, source: canonical, to: guestWorkspace, excludeGit: excludeGit)
    }
    try WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: canonical))
      .save(try shadow(config, binding), diagnostics: diagnostics)
  }

  /// Stages the guest workspace for review; nothing reaches the client
  /// directory until `apply`.
  package static func stage(
    _ target: SSHTarget, config: IsoConfig, binding: ClientBinding, directory: String?,
    excludeGit: Bool, environment: [String: String], diagnostics: Diagnostics
  ) throws -> StageManifest {
    let transfer = WorkspaceTransfer(
      client: SSHClient(environment: environment), diagnostics: diagnostics)
    return try transfer.stage(
      instance: try shadow(config, binding), target: target, directory: directory,
      excludeGit: excludeGit, limits: config.workspacePull.limits)
  }

  /// Applies a completed stage; needs no host or VM.
  package static func apply(
    config: IsoConfig, binding: ClientBinding, stageID: String?, force: Bool,
    environment: [String: String], diagnostics: Diagnostics
  ) throws -> (manifest: StageManifest, applied: [String]) {
    let transfer = WorkspaceTransfer(
      client: SSHClient(environment: environment), diagnostics: diagnostics)
    return try transfer.applyStage(try shadow(config, binding), stageID: stageID, force: force)
  }
}

/// Interactive Claude and Codex on a remote VM in client-broker mode
/// (spec 10.2): provider credentials resolve on this client into the
/// confined credential proxy, which reaches the guest only through a reverse
/// tunnel inside the session's relayed route. Nothing secret is sent to the
/// execution host.
package enum RemoteAgent: String, Sendable {
  case claude
  case codex

  /// Prepares the agent through the relayed route and runs it attached;
  /// returns the remote command's status. Proxies stop when it ends.
  /// A remote guest reaches provider credentials only through this client's
  /// proxy: `required` withholds every provider variable and Codex's
  /// `auth.json`, which `auto` copies when a provider has no proxy. `off`
  /// starts no proxy, so a remote agent would have no credential path.
  package static func brokeredConfig(_ config: IsoConfig) throws -> IsoConfig {
    guard config.proxy.mode != .off else {
      throw HostError(
        "proxy.mode = \"off\" starts no credential proxy; remote agents reach provider credentials only through one (set proxy.mode to \"auto\" or \"required\" and run `iso proxy setup`)"
      )
    }
    // MCP header values are resolved on this client; a remote guest never
    // receives them, so header-bearing servers are not configured there.
    return config.overridingProxyMode(.required).droppingHeaderedMCPServers()
  }

  /// What the agent's session forwards: Codex reads the client proxy's
  /// capability token from `ISO_LOCAL_API_KEY` (its provider's `env_key`), as
  /// the local session sets it. The token opens only this client's proxy,
  /// reached through the relay; it is guest-visible by design.
  func agentEnvironment(_ shadow: Instance) -> EnvForward {
    var env = EnvForward()
    if self == .codex, let token = ProxyLauncher.capabilityToken(shadow, provider: .openai) {
      env.set(ModelRouting.codexLocalEnvKey, token)
    }
    return env
  }

  /// The configuration a remote agent's broker and bootstrap run under: the
  /// proxy rule of ``brokeredConfig(_:)`` plus the VM's own egress. For a
  /// filtered VM the worker's proven boot policy (from the grant) binds the
  /// broker's signed readiness check, which runs through the relayed guest
  /// path; without that policy the agent is refused rather than started
  /// unproven.
  package static func agentConfig(
    _ config: IsoConfig, filteredPolicy: FilteredGrantPolicy?, vmEgress: EgressMode?
  ) throws -> IsoConfig {
    let brokered = try brokeredConfig(config)
    if filteredPolicy != nil { return brokered.overridingEgress(.filtered) }
    guard vmEgress != .filtered else {
      throw HostError(
        "FILTERED_BROKER_NOT_READY: the host did not prove filtered egress for this boot")
    }
    guard let vmEgress else {
      throw HostError("the host did not report this VM's egress; refusing to start an agent broker")
    }
    return brokered.overridingEgress(vmEgress)
  }

  package func run(
    session: ClientSessionCoordinator, binding: ClientBinding, config: IsoConfig,
    vmEgress: EgressMode?, environment: [String: String], home: String?, diagnostics: Diagnostics,
    arguments: [String]
  ) throws -> Int32 {
    if self == .codex, config.codexAuth == .chatgpt {
      throw HostError(
        "Codex ChatGPT account auth keeps its token in the guest; remote hosts support only client-held credentials"
      )
    }
    let shadow = try RemoteWorkspace.shadow(config, binding, ports: true)
    unlink(FilteredHandoff.policyPath(shadow))
    for name in config.headeredMCPServerNames {
      diagnostics.warn(
        "MCP server '\(name)' sends headers resolved on this client; it is not configured on the remote VM"
      )
    }
    let config = try Self.agentConfig(
      config, filteredPolicy: session.grant.filteredPolicy, vmEgress: vmEgress)
    if let policy = session.grant.filteredPolicy {
      try StateStore.writeControlFile(
        FilteredHandoff.BootPolicy(
          bootID: policy.bootID.rawValue, policyHash: policy.policyHash.rawValue),
        to: FilteredHandoff.policyPath(shadow))
    }
    let client = SSHClient(environment: environment)
    let resolver = CredentialResolver(environment: environment)
    let bootstrap = AgentBootstrap(
      config: config, client: client, environment: environment, home: home, resolver: resolver,
      proxies: ProxyLauncher(
        environment: environment, resolver: resolver, diagnostics: diagnostics,
        isoExecutable: Bundle.main.executablePath),
      github: HostGitHubTokens(
        config: config, environment: environment, diagnostics: diagnostics, githubDisabled: true),
      diagnostics: diagnostics, placement: .remote)
    let target = try session.guestTarget(config: config)
    let guest = SSHSession(target: target)
    defer { bootstrap.proxies.stopAll(shadow) }
    let binary: GuestPath
    switch self {
    case .claude:
      try bootstrap.bootstrapClaude(guest, instance: shadow, mode: .restart)
      binary = target.user.claudeBinary
    case .codex:
      try bootstrap.bootstrapCodex(guest, instance: shadow, mode: .restart)
      binary = GuestBinaries.codex
    }
    if let failure = session.failure { throw failure }
    guard let ssh = client.sshExecutable() else { throw HostError("ssh is not installed") }
    let agentEnv = agentEnvironment(shadow)
    let termination = try ProcessRunner().attached(
      .init(
        executable: ssh,
        arguments: InteractiveSSH.arguments(
          SSHSession(target: target, env: agentEnv),
          remote: InteractiveSSH.render([binary.rawValue] + arguments)),
        environment: agentEnv.overlay(SSHClient.transportEnvironment(environment)),
        deadline: .seconds(0)),
      inheritStdin: true, deadline: nil)
    if case .exited(let code) = termination { return code }
    return 1
  }
}

/// A coordinator that outlives the command that started it (spec 10.1):
/// one per binding, holding the binding's coordinator lock for its life and
/// publishing what other commands need to reuse its session. Reuse is
/// allowed only while the lock is held and the boot still matches.
package enum CoordinatorRecord {
  package struct Published: Codable, Sendable, Equatable {
    package var schema = 1
    package let pid: Int32
    package let session: SessionID
    package let boot: BootID
    package let guestUser: GuestUser
    package let alias: String
    package let descriptor: String
    package let knownHosts: String
    package let sshConfig: String
  }

  static func paths(_ config: IsoConfig, _ binding: ClientBinding) -> (record: String, lock: String)
  {
    let directory = RemoteWorkspace.directory(config, binding)
    return (directory + "/coordinator.json", directory + "/coordinator.lock")
  }

  /// Claims the binding's coordinator role for this process's lifetime.
  package static func claim(_ config: IsoConfig, _ binding: ClientBinding) throws -> FileLock {
    _ = try RemoteWorkspace.shadow(config, binding)
    guard let lock = try FileLock.attempt(path: paths(config, binding).lock) else {
      throw HostControlError(
        .sessionInUse,
        "a session coordinator for \(binding.name) on \(binding.host) is already running")
    }
    // A record left by a coordinator that died without cleanup is not ours.
    unlink(paths(config, binding).record)
    return lock
  }

  package static func publish(
    _ session: ClientSessionCoordinator, config: IsoConfig, binding: ClientBinding
  ) throws {
    let record = Published(
      pid: getpid(), session: session.grant.session, boot: session.grant.bootID,
      guestUser: session.grant.guestUser, alias: session.sshAlias,
      descriptor: session.descriptorPath, knownHosts: session.knownHostsPath,
      sshConfig: session.sshConfigPath)
    try StateStore.writeControlFile(record, to: paths(config, binding).record)
  }

  package static func withdraw(_ config: IsoConfig, _ binding: ClientBinding) {
    unlink(paths(config, binding).record)
  }

  /// The live coordinator's record, if one holds the lock and its private
  /// files still exist.
  /// Never takes the coordinator lock itself, so it cannot race a
  /// coordinator's claim; liveness is the recorded pid being this user's
  /// `iso host session` process.
  package static func live(_ config: IsoConfig, _ binding: ClientBinding) -> Published? {
    let recordPath = paths(config, binding).record
    guard let bytes = try? StateStore.readControlFile(recordPath),
      let record = try? JSONDecoder().decode(Published.self, from: Data(bytes))
    else { return nil }
    guard isCoordinator(record.pid),
      FileManager.default.fileExists(atPath: SessionDescriptor.path(config, record.session))
    else {
      unlink(recordPath)
      return nil
    }
    return record
  }

  /// Whether `pid` is a live `iso host session` process of this user.
  static func isCoordinator(_ pid: Int32) -> Bool {
    guard pid > 1 else { return false }
    var info = proc_bsdinfo()
    let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    guard size == MemoryLayout<proc_bsdinfo>.size, info.pbi_uid == getuid() else { return false }
    return HostMigration.arguments(of: pid)?.contains(" host session ") ?? false
  }

  /// The relayed guest route through a live coordinator's session.
  package static func target(_ record: Published, config: IsoConfig) throws -> SSHTarget {
    guard let executable = Bundle.main.executablePath else {
      throw HostError("cannot resolve the iso executable path")
    }
    // Paths are rebuilt from the session id, never taken from the record.
    let descriptor = SessionDescriptor.path(config, record.session)
    let knownHosts =
      SessionDescriptor.directory(config) + "/" + record.session.rawValue + ".known_hosts"
    for path in [executable, descriptor, knownHosts, ClientSessionKey.path(config)] {
      try ClientSessionCoordinator.requireRouteSafe(path)
    }
    var target = SSHTarget(
      host: record.alias, port: 22, user: record.guestUser,
      keyPath: ClientSessionKey.path(config), knownHosts: knownHosts, alias: record.alias)
    target.proxyCommand = "\(executable) host-agent connect --descriptor \(descriptor)"
    return target
  }

  /// Starts `arguments` as a detached coordinator process (own process
  /// group, stderr to `log`) and returns its pid.
  package static func spawnDetached(arguments: [String], environment: [String: String], log: String)
    throws -> Int32
  {
    guard let executable = Bundle.main.executablePath else {
      throw HostError("cannot resolve the iso executable path")
    }
    let fd = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw HostError.posix("Failed to open", log) }
    defer { close(fd) }
    let child = try DetachedChild.spawn(
      executable: executable, arguments: arguments, environment: environment, stdin: .null,
      stderr: fd)
    return child.pid
  }

  /// Asks a live coordinator to end its session (it closes the grant and
  /// removes its files on the way out).
  package static func stop(_ config: IsoConfig, _ binding: ClientBinding) -> Bool {
    guard let record = live(config, binding), record.pid > 1 else { return false }
    return kill(record.pid, SIGTERM) == 0
  }
}

/// Client-side completion of a disposable run's results (spec 12.1, 12.3):
/// download the committed artifact over the artifact channel, verify size and
/// digest, validate it as an archive, fsync it into a client-owned stage, and
/// only then acknowledge. The worker never names a client path.
package enum RemoteRunResults {
  package struct Stage: Sendable {
    package let id: StageID
    package let path: String
  }

  package static func directory(_ config: IsoConfig, host: HostID) -> String {
    config.stateRoot.appending("host-run-results").path + "/" + host.rawValue
  }

  package static func download(
    _ client: HostControlClient, run: RunObservation, config: IsoConfig, host: HostID,
    limit: UInt64
  ) throws -> Stage {
    guard let handle = run.artifact, let digest = run.artifactDigest else {
      throw HostControlError(.resultsUnavailable, "the run has no committed results")
    }
    var bytes: [UInt8] = []
    while true {
      let chunk = try client.call(
        .artifactRead(
          handle: handle, offset: UInt64(bytes.count),
          length: UInt32(HostRequestBody.maxArtifactChunk)))
      guard case .string(let text)? = chunk["data"], let data = Data(base64Encoded: text) else {
        throw HostControlError.invalidRequest("malformed artifact chunk")
      }
      if data.isEmpty { break }
      bytes += data
      guard UInt64(bytes.count) <= limit else {
        throw HostControlError(.limitExceeded, "results exceed the run's output limit")
      }
    }
    guard HostWire.sha256(bytes) == digest else {
      throw HostControlError(.resultsUnavailable, "downloaded results do not match their digest")
    }
    _ = try ArchiveValidator.validate(bytes: bytes)
    let stage = StageID.generate()
    let root = directory(config, host: host)
    try StateStore.ensurePrivateDirectory(config.stateRoot.appending("host-run-results").path)
    try StateStore.ensurePrivateDirectory(root)
    let path = root + "/" + run.runID.rawValue + "-" + stage.rawValue + ".tar"
    // AtomicFile fsyncs before publishing: the stage is complete before the ack.
    try AtomicFile.createExclusive(bytes, at: path, mode: 0o600)
    return Stage(id: stage, path: path)
  }
}
