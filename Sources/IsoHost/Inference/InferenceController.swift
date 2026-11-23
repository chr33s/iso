import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

// Host-side controller for the `iso-inference` gateway
// (docs/design/secure-local-inference-spec.md §12, §22). One gateway runs
// per host user under `sandbox-exec`, reached over an owner-only Unix
// socket in a fixed per-user directory. Per VM boot session the controller
// registers the instance's services on a Unix socket, verifies the
// registration, and only then activates the session, binding it to the
// process that carries guest connections to that socket: on vmnet the
// sandbox owner, which relays it into the guest over vsock; on brokered the
// fixed `ssh -R` forward iso starts over the instance's SSH connection
// (§22.9). Any failure revokes the partial session: no raw endpoint, no
// other transport and no cloud credential is used instead.

/// How guest connections reach an instance's gateway session (§22).
package enum InferenceCarrier: Sendable, Equatable {
  /// vmnet: the sandbox owner relays this host socket into the guest over
  /// vsock, as the isolation gate verified; nil when the boot has none.
  case relay(socket: String?)
  /// brokered: iso's fixed reverse forward carries guest 127.0.0.1:11788 to
  /// this host socket, which iso derives for the sandbox. `granted` is
  /// whether the boot's gate-verified network policy carries the
  /// `inference-gateway` grant (brokered spec 7.3).
  case forward(socket: String, granted: Bool)
}

/// The gateway's transport kind (control protocol 3 and later): which
/// process activation binds the session to.
package enum InferenceTransportKind: String, Sendable, Equatable {
  case owner
  case forward
}

/// What the controller needs about a running VM's boot.
package struct InferenceBoot: Sendable {
  package let ownerPID: Int32
  package let deadline: Date?
  package let carrier: InferenceCarrier

  package init(ownerPID: Int32, deadline: Date?, carrier: InferenceCarrier) {
    self.ownerPID = ownerPID
    self.deadline = deadline
    self.carrier = carrier
  }

  /// A vmnet boot whose relay's host end is `relaySocket`.
  package init(ownerPID: Int32, deadline: Date?, relaySocket: String?) {
    self.init(ownerPID: ownerPID, deadline: deadline, carrier: .relay(socket: relaySocket))
  }
}

/// A process a session is bound to: its PID and kernel start time.
package struct BoundProcess: Sendable, Equatable {
  package let pid: Int32
  package let start: String

  /// Still the same process (a reused PID has another start time).
  var isAlive: Bool { HostProcess.start(pid) == start }
}

/// An active gateway session for one instance.
package struct InferenceSession: Sendable, Equatable {
  package let sessionID: String
  package let epoch: String
  /// Services granted, by alias.
  package let services: [InferenceServiceName]
  /// What carries guest connections: the vmnet relay (with the guest
  /// bridge) or the brokered forward (no guest bridge).
  package var transport: InferenceTransportKind = .owner

  /// The guest's loopback endpoint for the session, the same on both
  /// transports: the bridge to the relayed socket, or the forward (§22).
  package var guestBaseURL: String { "http://127.0.0.1:\(InferenceController.guestPort)" }
}

/// `iso inference attach`: a persisted application grant (§12.1).
package struct InferenceAttachGrant: Sendable, Equatable {
  package let service: InferenceServiceName
  package let api: InferenceAPI

  package init(service: InferenceServiceName, api: InferenceAPI) {
    self.service = service
    self.api = api
  }

  package static func path(_ instance: Instance) -> String {
    instance.directory + "/inference-grant.json"
  }

  package static func load(_ instance: Instance) throws -> InferenceAttachGrant? {
    guard let bytes = try StateStore.readControlFile(path(instance)) else { return nil }
    guard
      case .object(let members) = try ConfigLoader.parse(
        bytes, format: .json, path: "inference-grant.json", limits: .configuration),
      case .string(let service)? = members["service"], case .string(let api)? = members["api"],
      let parsedAPI = InferenceAPI(rawValue: api), members.count == 2
    else { throw HostError("inference-grant.json is malformed") }
    return InferenceAttachGrant(service: try InferenceServiceName(service), api: parsedAPI)
  }

  /// Removes the grant; false when there was none.
  @discardableResult
  package static func remove(_ instance: Instance) throws -> Bool {
    guard unlink(path(instance)) == 0 else {
      if errno == ENOENT { return false }
      throw HostError.posix("Failed to remove", path(instance))
    }
    return true
  }

  package func save(_ instance: Instance) throws {
    let json = OutputJSON.object([
      ("service", .string(service.rawValue)), ("api", .string(api.rawValue)),
    ])
    try AtomicFile.write(
      Array(json.rendered().utf8), to: Self.path(instance), mode: .atMost(0o600))
  }
}

package struct InferenceController: Sendable {
  /// The guest's loopback port for its gateway session: a systemd socket
  /// bridged to the relayed Unix socket, one per VM. Clear of the guest ports
  /// iso already forwards per instance index (0...252): the credential
  /// proxies' 8788 and 9788 ranges and filtered egress's 10788 range.
  package static let guestPort: UInt16 = 11788
  /// The gateway control protocol this host speaks (IsoInferenceCore's
  /// `ControlProtocol.version`).
  static let controlVersion: UInt64 = 5
  static let controlTimeoutSeconds = 15
  static let startTimeout: Duration = .seconds(5)

  let config: IsoConfig
  let environment: [String: String]
  let resolver: CredentialResolver
  let diagnostics: Diagnostics
  let isoExecutable: String?
  let proxies: ProxyLauncher
  let boot: @Sendable (Instance) throws -> InferenceBoot
  let sandboxExec: String
  package let stateDirectory: String
  /// Where the gateway binds session sockets: the runtime's relay directory.
  let relayDirectory: String
  /// Sessions this command established or verified (shared by copies).
  let sessions = SessionMemo()
  /// Checks the control socket's peer before anything is sent; production
  /// uses `verifyPeer`, tests a stand-in gateway in this process.
  let peerCheck: (@Sendable (ControlSocket.Peer) throws -> Void)?
  /// Checks the process a session will be bound to; production uses
  /// `checkCarrier`, tests stand-in processes.
  let carrierCheck: (@Sendable (BoundProcess, InferenceTransportKind) throws -> Void)?

  package init(
    config: IsoConfig, environment: [String: String], resolver: CredentialResolver,
    diagnostics: Diagnostics, isoExecutable: String?, proxies: ProxyLauncher, home: String,
    boot: @escaping @Sendable (Instance) throws -> InferenceBoot
  ) {
    self.init(
      config: config, environment: environment, resolver: resolver, diagnostics: diagnostics,
      isoExecutable: isoExecutable, proxies: proxies, boot: boot,
      sandboxExec: "/usr/bin/sandbox-exec", stateDirectory: Self.stateDirectory(home: home),
      relayDirectory: IsolationGate.relayDirectory)
  }

  init(
    config: IsoConfig, environment: [String: String], resolver: CredentialResolver,
    diagnostics: Diagnostics, isoExecutable: String?, proxies: ProxyLauncher,
    boot: @escaping @Sendable (Instance) throws -> InferenceBoot, sandboxExec: String,
    stateDirectory: String, relayDirectory: String,
    peerCheck: (@Sendable (ControlSocket.Peer) throws -> Void)? = nil,
    carrierCheck: (@Sendable (BoundProcess, InferenceTransportKind) throws -> Void)? = nil
  ) {
    self.peerCheck = peerCheck
    self.carrierCheck = carrierCheck
    self.config = config
    self.environment = environment
    self.resolver = resolver
    self.diagnostics = diagnostics
    self.isoExecutable = isoExecutable
    self.proxies = proxies
    self.boot = boot
    self.sandboxExec = sandboxExec
    self.stateDirectory = stateDirectory
    self.relayDirectory = relayDirectory
  }

  /// Fixed per user, independent of `data_dir`: every data root attaches to
  /// the same gateway and shares its budgets (§5.1).
  package static func stateDirectory(home: String) -> String {
    HostPath(absolute: home).appending("Library/Application Support/iso/inference").path
  }

  static func statePath(_ instance: Instance) -> String { instance.directory + "/inference.json" }
  /// Where releases before the guest-held capability (spec §12.1) kept a
  /// host copy of it; only ever removed now.
  static func legacyTokenPath(_ instance: Instance) -> String {
    instance.directory + "/inference.token"
  }
  package static func revokedPath(_ instance: Instance) -> String {
    instance.directory + "/inference-revoked"
  }

  // MARK: Services

  /// The guarded services this instance's agents and grant use.
  package func requestedServices(_ instance: Instance) throws -> [InferenceServiceName] {
    var names = Set<InferenceServiceName>()
    if let service = config.claude.localService { names.insert(service) }
    if let service = config.codex.localService { names.insert(service) }
    if let grant = try InferenceAttachGrant.load(instance) {
      guard config.inference.services[grant.service] != nil else {
        throw HostError(
          "the attach grant of '\(instance.name)' (\(InferenceAttachGrant.path(instance))) names service '\(grant.service)', which inference.services no longer defines; run `iso inference detach \(instance.name)` or attach another service"
        )
      }
      names.insert(grant.service)
    }
    return names.sorted()
  }

  func resolved(_ name: InferenceServiceName) throws -> ResolvedInferenceService {
    guard let resolved = config.inference.resolve(name) else {
      throw HostError("INFERENCE_PROTOCOL_UNSUPPORTED: unknown inference service '\(name)'")
    }
    return resolved
  }

  // MARK: Sessions

  /// The instance's live session, established if needed. nil when the
  /// instance requests no service. `fresh` is true when a new session (and
  /// so a new capability) was just created. `configureGuest` writes the
  /// capability, the guest's bridge and agent configuration for a new
  /// session before it is activated (§12.2 step 6 before 7), so a failure
  /// or crash between them leaves no active session the guest is not set up
  /// for. The capability reaches only that closure: the host keeps no copy.
  package func ensureSession(
    _ instance: Instance, target: SSHTarget,
    configureGuest: (InferenceSession, Secret<String>) throws -> Void = { _, _ in }
  ) throws -> (session: InferenceSession, fresh: Bool)? {
    guard config.inference.mode == .required else {
      // A mode change disables admission first (§12.4): a session recorded
      // under `required` is revoked once the configuration says `off`.
      try revokeRecorded(instance)
      return nil
    }
    let services = try requestedServices(instance)
    guard !services.isEmpty else {
      try revoke(instance)
      return nil
    }
    // A manual revocation, or a brokered forward that exited, withholds
    // inference only: shells and commands still work, and agents reach no
    // model until the VM restarts or a grant is attached.
    if withheld(instance) { return nil }
    let fingerprint = try registrationFingerprint(services)
    if let remembered = sessions.session(instance, fingerprint: fingerprint) {
      return (remembered, false)
    }
    // One establisher per instance: concurrent commands must not revoke
    // each other's sessions or remove each other's state.
    let lock = try FileLock.sibling(of: Self.statePath(instance))
    defer { lock.release() }
    // Under the lock again: another command may have found the forward dead.
    if withheld(instance) { return nil }
    // A brokered session whose forward died during this boot is not
    // replaced: the instance stays revoked until it restarts (§22.9).
    if forwardDied(instance) {
      try revokeManually(instance, reason: .forwardExited)
      _ = withheld(instance)
      return nil
    }
    if let current = current(instance), current.fingerprint == fingerprint {
      remember(instance, current.session, fingerprint: fingerprint, bound: current.bound)
      return (current.session, false)
    }
    let (session, bound) = try establish(
      instance, target: target, services: services, fingerprint: fingerprint,
      configureGuest: configureGuest)
    remember(instance, session, fingerprint: fingerprint, bound: bound)
    return (session, true)
  }

  /// The checks on the process a session is bound to, which the gateway's
  /// profile leaves to the host (§12.3): this user's, and running the sandbox
  /// owner (`iso-sandbox`) or, for a brokered forward, the system `ssh`.
  static func checkCarrier(_ carrier: BoundProcess, _ kind: InferenceTransportKind) throws {
    guard HostProcess.uid(carrier.pid) == getuid(),
      let path = HostProcess.executablePath(carrier.pid)
    else { throw HostError("the session's transport process \(carrier.pid) is not this user's") }
    let expected =
      switch kind {
      case .owner: (path as NSString).lastPathComponent == "iso-sandbox"
      case .forward: path == "/usr/bin/ssh"
      }
    guard expected else {
      throw HostError(
        "the session's transport process \(carrier.pid) runs \(sanitizeForDisplay(path)), not \(kind == .owner ? "iso-sandbox" : "/usr/bin/ssh")"
      )
    }
  }

  /// Remembered only with the exact processes the session is bound to: the
  /// sandbox owner and, on brokered, the forward.
  func remember(
    _ instance: Instance, _ session: InferenceSession, fingerprint: String, bound: [BoundProcess]
  ) {
    sessions.remember(instance, .init(fingerprint: fingerprint, session: session, bound: bound))
  }

  /// §12.2 steps 3–7, under the instance's session lock. Every failure
  /// revokes the partial session.
  func establish(
    _ instance: Instance, target: SSHTarget, services: [InferenceServiceName], fingerprint: String,
    configureGuest: (InferenceSession, Secret<String>) throws -> Void
  ) throws -> (InferenceSession, bound: [BoundProcess]) {
    let resolved = try services.map(resolved)
    try enforceBackends(resolved)
    try ensureGatewayCovers(Set(resolved.map(\.backend.port)))
    let bootInfo = try boot(instance)
    let (socket, kind) = try sessionSocket(bootInfo.carrier, instance: instance)
    guard let ownerStart = HostProcess.start(bootInfo.ownerPID) else {
      throw HostError("cannot read the sandbox owner process for '\(instance.name)'")
    }
    let owner = BoundProcess(pid: bootInfo.ownerPID, start: ownerStart)
    // The old capability (and a brokered boot's old forward) first: a
    // replaced session must not linger.
    try revoke(instance)
    let nonce = randomHex(16)
    let registration = try registrationMessage(
      instance, resolved: resolved, boot: (owner.pid, owner.start), nonce: nonce,
      socket: socket, transport: kind)
    let registered = try control(registration)
    guard case .string(let sessionID)? = registered["session_id"],
      case .string(let epoch)? = registered["epoch"],
      case .string(let capability)? = registered["capability"],
      registered["socket"] == .string(socket)
    else { throw HostError("iso-inference returned an incomplete registration") }
    var session = InferenceSession(sessionID: sessionID, epoch: epoch, services: services)
    session.transport = kind
    var bound = [owner]
    do {
      try verifyRegistered(instance, sessionID: sessionID, nonce: nonce)
      try configureGuest(session, Secret(capability))
      // The session lives as long as the process that carries guest
      // connections: the owner relaying it (its exit, a VM stop, revokes the
      // session), or the brokered forward started only now, after the guest
      // is configured (its exit, or the owner's, revokes it).
      let carrier: BoundProcess
      switch kind {
      case .owner: carrier = owner
      case .forward:
        let forward = try proxies.startInferenceForward(
          instance, target: target, socket: relayDirectory + "/" + socket)
        carrier = BoundProcess(pid: forward.pid, start: forward.start)
        bound.append(carrier)
      }
      try (carrierCheck ?? Self.checkCarrier)(carrier, kind)
      // The gateway binds the session, and every connection to it, to this
      // process's PID and PID version (§12.3). Read the version, then
      // confirm the PID still names the recorded process.
      guard let version = HostProcess.pidVersion(carrier.pid), carrier.isAlive else {
        throw HostError("the process carrying '\(instance.name)''s session exited as it started")
      }
      var activation: [(String, OutputJSON)] = [
        ("version", .uint(Self.controlVersion)), ("op", .string("activate_session")),
        ("session_id", .string(sessionID)), ("epoch", .string(epoch)),
        (
          "transport",
          .object([("pid", .int(Int64(carrier.pid))), ("version", .uint(UInt64(version)))])
        ),
      ]
      if let deadline = bootInfo.deadline {
        activation.append(
          ("deadline_seconds", .int(max(1, Int64(deadline.timeIntervalSinceNow.rounded(.down))))))
      }
      _ = try control(activation)
      unlink(Self.legacyTokenPath(instance))
      var state: [(String, OutputJSON)] = [
        ("session_id", .string(sessionID)), ("epoch", .string(epoch)),
        ("owner_pid", .int(Int64(owner.pid))), ("owner_start", .string(owner.start)),
        ("transport", .string(kind.rawValue)),
      ]
      if kind == .forward {
        state += [
          ("forward_pid", .int(Int64(carrier.pid))), ("forward_start", .string(carrier.start)),
        ]
      }
      state += [
        ("fingerprint", .string(fingerprint)),
        ("services", .array(services.map { .string($0.rawValue) })),
      ]
      try AtomicFile.write(
        Array(OutputJSON.object(state).rendered().utf8), to: Self.statePath(instance),
        mode: .atMost(0o600))
    } catch {
      // Already failing: the forward closes first, so no guest connection
      // reaches the partial session. The revocation is best effort, and the
      // gateway also revokes an inactive session when the owner exits.
      if kind == .forward { proxies.stopInferenceForward(instance) }
      _ = try? control([
        ("version", .uint(Self.controlVersion)), ("op", .string("revoke_session")),
        ("session_id", .string(sessionID)),
      ])
      removeState(instance)
      throw ContextError(
        "Failed to establish the inference session for '\(instance.name)' (fail-closed; no raw or cloud fallback)",
        cause: error)
    }
    let carried = kind == .owner ? "the sandbox relay" : "the SSH reverse forward"
    diagnostics.log(
      .info,
      "Inference gateway session active for '\(instance.name)' (guest → 127.0.0.1:\(Self.guestPort) over \(carried); services \(services.map(\.rawValue).joined(separator: ", ")))"
    )
    return (session, bound)
  }

  /// Each backend the services use passes the §10/§20 checks, with its
  /// credential for the managed-backend challenge.
  func enforceBackends(_ resolved: [ResolvedInferenceService]) throws {
    for name in Set(resolved.map(\.backendName)).sorted() {
      guard let backend = config.inference.backends[name] else { continue }
      try BackendChecks.enforce(
        name: name, backend: backend, token: try backendToken(backend, name))
    }
  }

  /// A managed backend's Keychain token, for its challenge (§20.3).
  package func backendToken(_ backend: InferenceBackendConfig, _ name: String) throws
    -> Secret<String>?
  {
    guard backend.managed != nil, let reference = Self.credential(backend, name: name) else {
      return nil
    }
    do { return try resolver.resolve(reference) } catch {
      throw ContextError(
        "Failed to read the token of managed inference backend '\(name)' from the Keychain (fail-closed)",
        cause: error)
    }
  }

  /// The session socket's file name and the transport that carries it. A
  /// vmnet boot needs the relay the isolation gate verified; a brokered boot
  /// needs the inference grant in its gate-verified network policy. Either
  /// way the socket is in the relay directory under the runtime's hash name.
  func sessionSocket(_ carrier: InferenceCarrier, instance: Instance) throws -> (
    String, InferenceTransportKind
  ) {
    switch carrier {
    case .relay(let path):
      return (try relaySocketName(path, instance: instance), .owner)
    case .forward(let path, let granted):
      guard granted else {
        throw HostError(
          "'\(instance.name)' was booted without the inference-gateway grant in its network policy; restart it (`iso stop`, then `iso start`) so its boot carries the inference forward (fail-closed)"
        )
      }
      return (try relaySocketName(path, instance: instance), .forward)
    }
  }

  /// The relay socket's file name, when the isolation gate verified it in
  /// the relay directory (or iso derived it there for a brokered boot). A
  /// sandbox booted without a relay cannot carry a session.
  func relaySocketName(_ path: String?, instance: Instance) throws -> String {
    guard let path else {
      throw HostError(
        "'\(instance.name)' was booted without the inference relay; restart it (`iso stop`, then `iso start`) so the runtime relays the gateway socket (fail-closed)"
      )
    }
    let name = String(path.split(separator: "/").last ?? "")
    // The gate already matched the runtime's derived path; this keeps the
    // gateway's name rule (1-16 lowercase ASCII hex digits, `.sock`).
    let stem = name.hasSuffix(".sock") ? Array(name.utf8.dropLast(5)) : []
    guard path == relayDirectory + "/" + name, (1...16).contains(stem.count),
      stem.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
    else {
      throw HostError(
        "the inference relay of '\(instance.name)' is not a socket in \(relayDirectory) (fail-closed)"
      )
    }
    return name
  }

  /// The recorded session when the gateway still reports it active under
  /// the same epoch and the processes it was bound to still run: the sandbox
  /// owner and, for a brokered boot, the forward iso recorded.
  func current(_ instance: Instance) -> (
    session: InferenceSession, fingerprint: String, bound: [BoundProcess]
  )? {
    guard let bytes = try? StateStore.readControlFile(Self.statePath(instance)),
      case .object(let state)? = try? ConfigLoader.parse(
        bytes, format: .json, path: "inference.json", limits: .configuration),
      case .string(let sessionID)? = state["session_id"], case .string(let epoch)? = state["epoch"],
      case .string(let fingerprint)? = state["fingerprint"],
      let ownerPID = state["owner_pid"].flatMap(Self.integer).flatMap(Int32.init(exactly:)),
      case .string(let ownerStart)? = state["owner_start"],
      HostProcess.start(ownerPID) == ownerStart,
      let bound = Self.boundProcesses(
        state, owner: BoundProcess(pid: ownerPID, start: ownerStart),
        forward: proxies.inferenceForward(instance).map {
          BoundProcess(pid: $0.pid, start: $0.start)
        }),
      case .array(let rawServices)? = state["services"],
      let inspection = try? inspect(instance, start: false),
      case .object(let gateway)? = inspection["gateway"], gateway["epoch"] == .string(epoch),
      case .array(let sessions)? = inspection["sessions"],
      sessions.contains(where: {
        guard case .object(let session) = $0 else { return false }
        return session["session_id"] == .string(sessionID) && session["state"] == .string("active")
      })
    else { return nil }
    let services = rawServices.compactMap { value -> InferenceServiceName? in
      guard case .string(let raw) = value else { return nil }
      return try? InferenceServiceName(raw)
    }
    var session = InferenceSession(sessionID: sessionID, epoch: epoch, services: services)
    session.transport = bound.count > 1 ? .forward : .owner
    return (session, fingerprint, bound)
  }

  /// The processes a recorded session is bound to. A forward session (one
  /// whose record names `transport: "forward"`) needs its recorded forward
  /// to be the live tunnel master iso started (`forward`), at the same start
  /// time; a record without `transport` predates the brokered path.
  static func boundProcesses(
    _ state: [String: JSONValue], owner: BoundProcess, forward: BoundProcess?
  ) -> [BoundProcess]? {
    switch state["transport"] {
    case nil, .string(InferenceTransportKind.owner.rawValue)?: return [owner]
    case .string(InferenceTransportKind.forward.rawValue)?:
      guard let pid = state["forward_pid"].flatMap(integer).flatMap(Int32.init(exactly:)),
        case .string(let start)? = state["forward_start"],
        let forward, forward == BoundProcess(pid: pid, start: start), forward.isAlive
      else { return nil }
      return [owner, forward]
    default: return nil
    }
  }

  /// Revoke the instance's session at the gateway and remove the host-side
  /// capability. Idempotent. A gateway that is not running holds no session
  /// (a restarted one starts a new epoch), so that counts as revoked; any
  /// other failure (peer verification, protocol version, timeout, refusal)
  /// throws and keeps the state, because the session may still be active.
  package func revoke(_ instance: Instance) throws {
    sessions.forget(instance)
    // A brokered boot's forward closes first: it ends every guest stream to
    // the session (NET-08), whether or not the gateway answers.
    proxies.stopInferenceForward(instance)
    do {
      _ = try control([
        ("version", .uint(Self.controlVersion)), ("op", .string("revoke_session")),
        ("instance", .object(instanceKey(instance))),
      ])
    } catch is InferenceGatewayNotRunning {}
    removeState(instance)
  }

  /// `revoke`, when a session is recorded for the instance.
  func revokeRecorded(_ instance: Instance) throws {
    guard FileManager.default.fileExists(atPath: Self.statePath(instance)) else { return }
    try revoke(instance)
  }

  /// Why an instance is revoked until it restarts.
  package enum Revocation: String, Sendable {
    /// `iso inference revoke`.
    case manual = "revoked"
    /// The brokered boot's forward exited (§22.9).
    case forwardExited = "forward-exited"
  }

  /// `iso inference revoke`: as `revoke`, and the instance stays revoked
  /// until the VM restarts or a new grant is attached. The marker is written
  /// first, so no command re-establishes a session while the revocation runs.
  package func revokeManually(_ instance: Instance, reason: Revocation = .manual) throws {
    try AtomicFile.write(
      Array("\(reason.rawValue)\n".utf8), to: Self.revokedPath(instance), mode: .atMost(0o600))
    try revoke(instance)
  }

  package func isManuallyRevoked(_ instance: Instance) -> Bool {
    FileManager.default.fileExists(atPath: Self.revokedPath(instance))
  }

  /// The recorded revocation, when there is one. An unreadable or unknown
  /// marker still revokes (fail closed), as a manual one.
  package static func revocation(_ instance: Instance) -> Revocation? {
    guard FileManager.default.fileExists(atPath: revokedPath(instance)) else { return nil }
    let text = (try? StateStore.readControlFile(revokedPath(instance))).map {
      String(decoding: $0, as: UTF8.self).trimmingUnicodeWhitespace()
    }
    return text.flatMap(Revocation.init(rawValue:)) ?? .manual
  }

  /// True, with a warning naming the way out, while the instance is revoked.
  func withheld(_ instance: Instance) -> Bool {
    guard let revocation = Self.revocation(instance) else { return false }
    let name = instance.name
    switch revocation {
    case .manual:
      diagnostics.warn(
        "inference access for '\(name)' was revoked with `iso inference revoke`; restart the VM or run `iso inference attach` to grant it again"
      )
    case .forwardExited:
      diagnostics.warn(
        "the inference forward of '\(name)' exited, so its gateway session was revoked; restart the VM (`iso stop \(name)`, then `iso start \(name)`) or run `iso inference attach \(name)` to grant inference again"
      )
    }
    return true
  }

  /// The recorded session is a brokered one of the running boot (its
  /// sandbox owner still runs) whose forward is no longer the live master
  /// iso started for it.
  func forwardDied(_ instance: Instance) -> Bool {
    guard let bytes = try? StateStore.readControlFile(Self.statePath(instance)),
      case .object(let state)? = try? ConfigLoader.parse(
        bytes, format: .json, path: "inference.json", limits: .configuration),
      state["transport"] == .string(InferenceTransportKind.forward.rawValue),
      let ownerPID = state["owner_pid"].flatMap(Self.integer).flatMap(Int32.init(exactly:)),
      case .string(let ownerStart)? = state["owner_start"],
      HostProcess.start(ownerPID) == ownerStart
    else { return false }
    let forward = proxies.inferenceForward(instance).map {
      BoundProcess(pid: $0.pid, start: $0.start)
    }
    return Self.boundProcesses(
      state, owner: BoundProcess(pid: ownerPID, start: ownerStart), forward: forward) == nil
  }

  /// A VM restart or an explicit attach lifts a manual revocation.
  package static func clearManualRevocation(_ instance: Instance) {
    unlink(revokedPath(instance))
  }

  func removeState(_ instance: Instance) {
    unlink(Self.statePath(instance))
    unlink(Self.legacyTokenPath(instance))
  }

  func verifyRegistered(_ instance: Instance, sessionID: String, nonce: String) throws {
    let inspection = try inspect(instance, start: false)
    guard case .array(let sessions)? = inspection["sessions"],
      sessions.contains(where: {
        guard case .object(let session) = $0 else { return false }
        return session["session_id"] == .string(sessionID) && session["nonce"] == .string(nonce)
          && session["state"] == .string("inactive")
      })
    else {
      throw HostError(
        "the gateway does not report the registered session with its nonce — refusing to activate")
    }
  }

  // MARK: Registration

  func instanceKey(_ instance: Instance) -> [(String, OutputJSON)] {
    [("data_root", .string(config.dataDirectory.path)), ("name", .string(instance.name.rawValue))]
  }

  func registrationMessage(
    _ instance: Instance, resolved: [ResolvedInferenceService], boot: (Int32, String),
    nonce: String, socket: String, transport: InferenceTransportKind
  ) throws -> [(String, OutputJSON)] {
    let limits = config.inference.globalLimits
    return [
      ("version", .uint(Self.controlVersion)), ("op", .string("register_session")),
      ("instance", .object(instanceKey(instance))),
      ("boot", .object([("owner_pid", .int(Int64(boot.0))), ("owner_start", .string(boot.1))])),
      ("nonce", .string(nonce)), ("socket", .string(socket)),
      ("transport", .string(transport.rawValue)),
      (
        "global_limits",
        .object([
          ("max_active_requests", .uint(UInt64(limits.maxActiveRequests))),
          ("max_queued_requests", .uint(UInt64(limits.maxQueuedRequests))),
          ("max_request_buffer_bytes", .uint(UInt64(limits.maxRequestBufferBytes))),
        ])
      ),
      ("grants", .array(try grantsWithCredentials(resolved))),
    ]
  }

  /// Grants carrying each backend's credential, resolved once per backend
  /// (a Keychain lookup) however many services share it.
  func grantsWithCredentials(_ services: [ResolvedInferenceService]) throws -> [OutputJSON] {
    var credentials: [String: String] = [:]
    return try services.map { service in
      if credentials[service.backendName] == nil,
        let reference = Self.credential(service.backend, name: service.backendName)
      {
        do {
          credentials[service.backendName] = try resolver.resolve(reference).expose()
        } catch {
          throw ContextError(
            "Failed to resolve the credential for inference backend '\(service.backendName)' (fail-closed)",
            cause: error)
        }
      }
      return grant(service, credential: credentials[service.backendName])
    }
  }

  /// The backend's bearer credential: the configured reference, or a managed
  /// backend's token in the login Keychain (spec §20.3).
  static func credential(_ backend: InferenceBackendConfig, name: String) -> CredentialReference? {
    switch backend.operation {
    case .external(let credential, _): credential
    case .managed:
      CredentialReference(
        KeychainReference(service: ManagedBackendConfig.keychainService, account: name).description)
    }
  }

  func grant(_ service: ResolvedInferenceService, credential: String?) -> OutputJSON {
    let profile = service.profile
    var backend: [(String, OutputJSON)] = [
      ("port", .uint(UInt64(service.backend.port))), ("name", .string(service.backendName)),
      ("max_active", .uint(UInt64(service.backend.maxActiveRequests))),
      // iso's launcher proves itself on every connection (spec §20.3).
      ("front", .string(service.backend.managed == nil ? "plain" : "launcher")),
      (
        "profile",
        .object([
          ("name", .string(profile.name)), ("protocol", .string(profile.backendProtocol.rawValue)),
          ("completion_evidence", .string(profile.completionEvidence.rawValue)),
          ("stream_close_drain_ms", .uint(UInt64(profile.streamCloseDrainMilliseconds))),
          ("context_overflow", .string(profile.contextOverflow.rawValue)),
          ("overhead_per_request_bytes", .uint(UInt64(profile.overheadPerRequestBytes))),
          ("overhead_per_message_bytes", .uint(UInt64(profile.overheadPerMessageBytes))),
          ("max_input_bytes", .uint(UInt64(profile.maxInputBytes))),
          ("max_request_body_bytes", .uint(UInt64(profile.maxRequestBodyBytes))),
          ("token_counter", .string(profile.tokenCounter.rawValue)),
        ])
      ),
    ]
    if let credential { backend.append(("credential", .string(credential))) }
    var out: [(String, OutputJSON)] = [
      ("alias", .string(service.name.rawValue)),
      ("upstream_model", .string(service.service.upstreamModel)),
      ("apis", .array(service.service.frontendAPIs.map { .string($0.rawValue) })),
      ("max_context_tokens", .uint(UInt64(service.service.maxContextTokens))),
      ("default_output_tokens", .uint(UInt64(service.service.defaultOutputTokens))),
      ("max_output_tokens", .uint(UInt64(service.service.maxOutputTokens))),
      ("backend", .object(backend)),
    ]
    if let bytes = service.service.maxInputBytes {
      out.append(("max_input_bytes", .uint(UInt64(bytes))))
    }
    return .object(out)
  }

  /// Changes whenever the policy a session would carry changes (credential
  /// references excluded), so a configuration edit re-registers.
  func registrationFingerprint(_ services: [InferenceServiceName]) throws -> String {
    let grants = try services.map { grant(try resolved($0), credential: nil) }
    let limits = config.inference.globalLimits
    let document = OutputJSON.object([
      ("grants", .array(grants)),
      (
        "limits",
        .array([
          .uint(UInt64(limits.maxActiveRequests)), .uint(UInt64(limits.maxQueuedRequests)),
          .uint(UInt64(limits.maxRequestBufferBytes)),
        ])
      ),
    ])
    return sha256Hex(Array(document.rendered().utf8))
  }

  // MARK: Backend checks (§10)

  /// The backend must accept on 127.0.0.1 and on no other host address a
  /// guest could reach. Unprivileged probes: a connection accepted on any
  /// non-loopback address fails attachment.
  static func checkBackend(port: UInt16) throws {
    try requireSafeBinding(
      port: port, reachable: backendAccepts(port: port),
      exposedAddresses: exposedAddresses(port: port))
  }

  static func requireSafeBinding(port: UInt16, reachable: Bool, exposedAddresses: [String]) throws {
    guard reachable else {
      throw HostError(
        "INFERENCE_BACKEND_UNAVAILABLE: no backend is listening on 127.0.0.1:\(port); start the local model server first"
      )
    }
    if let address = exposedAddresses.first {
      throw HostError(
        "INFERENCE_BACKEND_UNSAFE_BIND: the backend on port \(port) also accepts connections on \(address); a guest could reach it directly. Bind the model server to 127.0.0.1 only."
      )
    }
  }

  /// Whether a backend accepts connections on 127.0.0.1.
  package static func backendAccepts(port: UInt16) -> Bool {
    Socket.connects(host: "127.0.0.1", port: port, timeoutMilliseconds: 1000)
  }

  /// Every non-loopback address the backend port answers on.
  /// `addresses` are the host's non-loopback addresses (injected by tests).
  package static func exposedAddresses(
    port: UInt16, addresses: [String] = Socket.nonLoopbackAddresses()
  ) -> [String] {
    addresses.filter {
      Socket.connects(host: $0, port: port, timeoutMilliseconds: 300)
    }
  }

  // MARK: Gateway process

  func locateBinary() throws -> String {
    guard let isoExecutable else { throw HostError("Failed to locate the iso executable") }
    guard let candidate = Self.siblingBinary("iso-inference", of: isoExecutable) else {
      throw HostError(
        "iso-inference not found next to iso at \((isoExecutable as NSString).deletingLastPathComponent) (fail-closed; no raw or cloud fallback). An update from iso v0.11.x or earlier installs no iso-inference: run `iso update --force` once, or rerun install.sh; a source build needs scripts/build-release.py"
      )
    }
    // As for the runtime: owned by root or this user, unwritable by others
    // down to `/`, and (release builds) signed like iso.
    do {
      return try proxies.verifyCompanion(try TrustedExecutable.verify(candidate).path).path
    } catch {
      throw ContextError("Refusing to start \(candidate) (fail-closed)", cause: error)
    }
  }

  static func realPath(_ path: String) -> String { canonicalPath(path) ?? path }

  /// The companion `name` installed beside `isoExecutable`, when it is a
  /// regular file.
  static func siblingBinary(_ name: String, of isoExecutable: String) -> String? {
    let candidate = (isoExecutable as NSString).deletingLastPathComponent + "/" + name
    var status = stat()
    guard stat(candidate, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
    return candidate
  }

  /// The owner-only state directory, created `0700` when missing.
  func prepareStateDirectory() throws -> String {
    let parent = (stateDirectory as NSString).deletingLastPathComponent
    for directory in [parent, stateDirectory] {
      if mkdir(directory, 0o700) != 0 && errno != EEXIST {
        throw HostError.posix("Failed to create", directory)
      }
    }
    var info = stat()
    guard lstat(stateDirectory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      info.st_uid == getuid()
    else { throw HostError("\(stateDirectory) is not a directory owned by this user") }
    if info.st_mode & 0o077 != 0 && chmod(stateDirectory, 0o700) != 0 {
      throw HostError.posix("Failed to restrict", stateDirectory)
    }
    return Self.realPath(stateDirectory)
  }

  /// The relay directory (§22), created `0700` when missing (its parent is
  /// the runtime's control-socket directory). Returned resolved: Seatbelt
  /// matches resolved paths.
  func prepareRelayDirectory() throws -> String {
    let parent = (relayDirectory as NSString).deletingLastPathComponent
    for directory in [parent, relayDirectory] {
      if mkdir(directory, 0o700) != 0 && errno != EEXIST {
        throw HostError.posix("Failed to create", directory)
      }
      var info = stat()
      guard lstat(directory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
        info.st_uid == getuid(), info.st_mode & 0o077 == 0
      else {
        throw HostError("\(directory) is not a private directory owned by this user (fail-closed)")
      }
    }
    return Self.realPath(relayDirectory)
  }

  var socketPath: String { stateDirectory + "/control.sock" }

  /// What answers on the control socket, without starting anything.
  package enum GatewayState: Sendable, Equatable {
    case notRunning
    case verified(pid: Int32)
    /// Something answers that fails peer verification or speaks another
    /// control protocol version; `pid` is the peer's, `sameUser` whether it
    /// runs as this user.
    case unverified(pid: Int32, sameUser: Bool, reason: String)
  }

  package func probe() -> GatewayState {
    guard let peer = try? ControlSocket.peer(socketPath) else { return .notRunning }
    do {
      try checkPeer(peer)
      _ = try inspect(nil)
      return .verified(pid: peer.pid)
    } catch is InferenceGatewayNotRunning {
      return .notRunning
    } catch {
      return .unverified(pid: peer.pid, sameUser: peer.uid == getuid(), reason: "\(error)")
    }
  }

  /// A verified connection check: the socket's peer is this user's
  /// `iso-inference` binary beside this `iso`. With `start`, launches it.
  @discardableResult
  package func connect(start: Bool) throws -> Int32 {
    if let peer = try? ControlSocket.peer(socketPath) {
      try checkPeer(peer)
      return peer.pid
    }
    guard start else { throw InferenceGatewayNotRunning(reason: "nothing serves \(socketPath)") }
    let binary = try locateBinary()
    let directory = try prepareStateDirectory()
    let relay = try prepareRelayDirectory()
    let logPath = directory + "/gateway.log"
    let log = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard log >= 0 else { throw HostError.posix("Failed to open", logPath) }
    defer { close(log) }
    let ports = backendPorts
    guard !ports.isEmpty else { throw HostError("inference configuration names no backend") }
    // The gateway holds a socket per guest connection across every VM: it
    // inherits a descriptor limit raised toward the hard limit.
    var child = try Self.withRaisedFileLimit(Self.gatewayFileLimit) {
      try DetachedChild.spawn(
        executable: sandboxExec,
        arguments: [
          "-D", "INFERENCE_BIN=\(binary)", "-D", "STATE_DIR=\(directory)", "-D",
          "RELAY_DIR=\(relay)", "-p", SeatbeltProfile.inference(backendPorts: ports), binary,
          "--state-dir", directory, "--relay-dir", relay,
        ] + ports.flatMap { ["--backend-port", String($0)] }, environment: [:], stdin: .null,
        stderr: log)
    }
    let deadline = ContinuousClock.now + Self.startTimeout
    while ContinuousClock.now < deadline {
      if let peer = try? ControlSocket.peer(socketPath) {
        try checkPeer(peer)
        return peer.pid
      }
      if let status = child.poll(), status != .exited(3) {
        throw HostError(
          "iso-inference exited before serving (\(status)); its confinement or startup failed (fail-closed).\n\(ProxyLauncher.readLog(logPath))"
        )
      }
      usleep(100_000)
    }
    throw HostError(
      "iso-inference did not start within 5s (fail-closed).\n\(ProxyLauncher.readLog(logPath))")
  }

  static let gatewayFileLimit: rlim_t = 8192

  /// `body` with this process's soft descriptor limit raised to `limit`
  /// (or the hard limit), restored afterwards; a child spawned in `body`
  /// keeps the raised limit.
  static func withRaisedFileLimit<T>(_ limit: rlim_t, _ body: () throws -> T) rethrows -> T {
    var saved = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &saved) == 0, saved.rlim_cur < limit else { return try body() }
    var raised = saved
    raised.rlim_cur = min(limit, saved.rlim_max)
    _ = setrlimit(RLIMIT_NOFILE, &raised)
    defer { _ = setrlimit(RLIMIT_NOFILE, &saved) }
    return try body()
  }

  /// Every backend port in the configuration: the only loopback ports the
  /// gateway's launch profile lets it reach (spec §20.5).
  var backendPorts: [UInt16] { Set(config.inference.backends.values.map(\.port)).sorted() }

  /// A running gateway launched for other ports is restarted when idle;
  /// one with active sessions is left alone and the start fails.
  func ensureGatewayCovers(_ needed: Set<UInt16>) throws {
    guard let inspection = try? inspect(nil, start: false),
      case .object(let gateway)? = inspection["gateway"]
    else { return }
    let allowed: Set<UInt16> =
      if case .array(let ports)? = gateway["gateway_egress_ports"] {
        Set(ports.compactMap { Self.integer($0).flatMap(UInt16.init(exactly:)) })
      } else { [] }
    guard !needed.isSubset(of: allowed) else { return }
    if case .array(let sessions)? = inspection["sessions"], !sessions.isEmpty {
      throw HostError(
        "the running inference gateway was started for other backend ports and has active sessions; run `iso inference stop --force`, then retry"
      )
    }
    try stopGateway(force: false)
    let deadline = ContinuousClock.now + Self.startTimeout
    while (try? ControlSocket.peer(socketPath)) != nil, ContinuousClock.now < deadline {
      usleep(100_000)
    }
  }

  func checkPeer(_ peer: ControlSocket.Peer) throws {
    if let peerCheck { return try peerCheck(peer) }
    try Self.verifyPeer(
      peer, expected: try locateBinary(), socketPath: socketPath,
      executablePath: HostProcess.executablePath, sandboxed: BackendChecks.isSandboxed)
  }

  /// The peer runs as this user, is the `iso-inference` beside this `iso`,
  /// and is sandboxed (the kernel's answer: the gateway checks its own
  /// confinement at startup, and this refuses one started without it).
  static func verifyPeer(
    _ peer: ControlSocket.Peer, expected: String, socketPath: String,
    executablePath: (Int32) -> String?, sandboxed: (Int32) -> Bool?
  ) throws {
    guard peer.uid == getuid() else {
      throw HostError("the inference control socket is served by another user — refusing to use it")
    }
    guard let path = executablePath(peer.pid), Self.realPath(path) == expected else {
      throw HostError(
        "a different program (pid \(peer.pid)) serves \(socketPath), not \(expected); stop it with `iso inference stop --force` and retry"
      )
    }
    guard sandboxed(peer.pid) == true else {
      throw HostError(
        "iso-inference (pid \(peer.pid)) is not running under its Seatbelt profile; stop it with `iso inference stop --force` and retry (fail-closed)"
      )
    }
  }

  // MARK: Control requests

  /// One control request; the gateway's own error is raised as a HostError
  /// carrying its stable code.
  /// The peer is verified on the connection that carries the request; only
  /// a registration starts a gateway that is not running.
  func control(_ message: [(String, OutputJSON)], start: Bool = false) throws -> [String: JSONValue]
  {
    if start || message.first(where: { $0.0 == "op" })?.1 == .string("register_session") {
      _ = try connect(start: true)
    }
    let body = Array(OutputJSON.object(message).rendered().utf8)
    let reply: [UInt8]
    do {
      reply = try ControlSocket.exchange(
        socketPath, body, timeoutSeconds: Self.controlTimeoutSeconds, verify: checkPeer)
    } catch let error as ControlSocket.Unreachable {
      throw InferenceGatewayNotRunning(reason: error.reason)
    }
    guard
      case .object(let members) = try ConfigLoader.parse(
        reply, format: .json, path: "iso-inference", limits: .configuration)
    else { throw HostError("iso-inference sent a malformed reply") }
    let version = members["version"].flatMap(Self.integer)
    guard version == Int64(Self.controlVersion) else {
      throw InferenceGatewayIncompatible(version: version, expected: Self.controlVersion)
    }
    guard members["ok"] == .bool(true) else {
      let code: String =
        if case .string(let code)? = members["code"] { code } else { "INFERENCE_ERROR" }
      let text: String = if case .string(let text)? = members["message"] { text } else { "refused" }
      throw HostError("\(code): \(text)")
    }
    return members
  }

  package func inspect(_ instance: Instance?, start: Bool = false) throws -> [String: JSONValue] {
    var message: [(String, OutputJSON)] = [
      ("version", .uint(Self.controlVersion)), ("op", .string("inspect")),
    ]
    if let instance { message.append(("instance", .object(instanceKey(instance)))) }
    return try control(message, start: start)
  }

  package func requalify(port: UInt16) throws {
    _ = try control([
      ("version", .uint(Self.controlVersion)), ("op", .string("requalify_backend")),
      ("port", .uint(UInt64(port))),
    ])
  }

  package func stopGateway(force: Bool) throws {
    _ = try control([
      ("version", .uint(Self.controlVersion)), ("op", .string("shutdown")), ("force", .bool(force)),
    ])
  }

  static func integer(_ value: JSONValue) -> Int64? {
    switch value {
    case .number(.integer(let n)): n
    case .number(.unsigned(let n)): Int64(exactly: n)
    default: nil
    }
  }
}

/// No gateway accepts connections on the control socket: it holds no
/// session (a started one begins a new epoch).
package struct InferenceGatewayNotRunning: Error, CustomStringConvertible {
  let reason: String
  package var description: String { "the inference gateway is not running (\(reason))" }
}

/// The running gateway speaks another control protocol version, as an
/// iso-inference left running across `iso update` does.
package struct InferenceGatewayIncompatible: Error, CustomStringConvertible {
  let version: Int64?
  let expected: UInt64
  package var description: String {
    "the running iso-inference speaks control protocol \(version.map(String.init) ?? "unknown"), not \(expected) (it predates this iso, as after `iso update`); its sessions cannot be managed. Run `iso inference stop --force` (revokes them), then retry"
  }
}
