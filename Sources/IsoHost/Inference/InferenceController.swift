import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import Synchronization

// Host-side controller for the `iso-inference` gateway
// (docs/design/secure-local-inference-spec.md §12, §22). One gateway runs
// per host user under `sandbox-exec`, reached over an owner-only Unix
// socket in a fixed per-user directory. Per VM boot session the controller
// registers the instance's services on the Unix socket its sandbox runtime
// relays into the guest over vsock, verifies the registration, and only then
// activates the session, binding it to the sandbox owner process that
// carries the relay. Any failure revokes the partial session: no raw
// endpoint and no cloud credential is used instead.

/// What the controller needs about a running VM's boot.
package struct InferenceBoot: Sendable {
  package let ownerPID: Int32
  package let deadline: Date?
  /// The host end of the instance's vsock relay, verified by the isolation
  /// gate; nil when the sandbox was booted without one.
  package let relaySocket: String?

  package init(ownerPID: Int32, deadline: Date?, relaySocket: String?) {
    self.ownerPID = ownerPID
    self.deadline = deadline
    self.relaySocket = relaySocket
  }
}

/// An active gateway session for one instance.
package struct InferenceSession: Sendable, Equatable {
  package let sessionID: String
  package let epoch: String
  package let token: Secret<String>
  /// Services granted, by alias.
  package let services: [InferenceServiceName]

  /// The guest's bridge to the relayed gateway socket (§22).
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
  static let controlVersion: UInt64 = 2
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
    stateDirectory: String, relayDirectory: String
  ) {
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
  static func tokenPath(_ instance: Instance) -> String { instance.directory + "/inference.token" }
  static func revokedPath(_ instance: Instance) -> String {
    instance.directory + "/inference-revoked"
  }

  // MARK: Services

  /// The guarded services this instance's agents and grant use.
  package func requestedServices(_ instance: Instance) throws -> [InferenceServiceName] {
    var names = Set<InferenceServiceName>()
    if let service = config.claude.localService { names.insert(service) }
    if let service = config.codex.localService { names.insert(service) }
    if let grant = try InferenceAttachGrant.load(instance) { names.insert(grant.service) }
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
  /// so a new capability) was just created.
  package func ensureSession(_ instance: Instance, target: SSHTarget) throws -> (
    session: InferenceSession, fresh: Bool
  )? {
    guard config.inference.mode == .required else { return nil }
    let services = try requestedServices(instance)
    guard !services.isEmpty else {
      revoke(instance)
      return nil
    }
    // A manual revocation withholds inference only: shells and commands
    // still work, and agents reach no model until the VM restarts or a grant
    // is attached.
    if isManuallyRevoked(instance) {
      diagnostics.warn(
        "inference access for '\(instance.name)' was revoked with `iso inference revoke`; restart the VM or run `iso inference attach` to grant it again"
      )
      return nil
    }
    let fingerprint = try registrationFingerprint(services)
    if let remembered = sessions.session(instance, fingerprint: fingerprint) {
      return (remembered, false)
    }
    if let current = current(instance), current.fingerprint == fingerprint {
      remember(instance, current.session, fingerprint: fingerprint, owner: current.owner)
      return (current.session, false)
    }
    let (session, owner) = try establish(
      instance, target: target, services: services, fingerprint: fingerprint)
    remember(instance, session, fingerprint: fingerprint, owner: owner)
    return (session, true)
  }

  /// Remembered only with the exact owner process that carries the relay.
  func remember(
    _ instance: Instance, _ session: InferenceSession, fingerprint: String,
    owner: (pid: Int32, start: String)
  ) {
    sessions.remember(
      instance,
      .init(
        fingerprint: fingerprint, session: session, ownerPID: owner.pid, ownerStart: owner.start))
  }

  /// §12.2 steps 3–7. Every failure revokes the partial session.
  func establish(
    _ instance: Instance, target: SSHTarget, services: [InferenceServiceName], fingerprint: String
  ) throws -> (InferenceSession, owner: (pid: Int32, start: String)) {
    let resolved = try services.map(resolved)
    for (name, backend) in Set(resolved.map(\.backendName)).sorted().compactMap({ name in
      config.inference.backends[name].map { (name, $0) }
    }) {
      try BackendChecks.enforce(name: name, backend: backend)
    }
    try ensureGatewayCovers(Set(resolved.map(\.backend.port)))
    let bootInfo = try boot(instance)
    let socket = try relaySocketName(bootInfo.relaySocket, instance: instance)
    guard let ownerStart = HostProcess.start(bootInfo.ownerPID) else {
      throw HostError("cannot read the sandbox owner process for '\(instance.name)'")
    }
    // The old capability first: a replaced session must not linger.
    revoke(instance)
    let nonce = randomHex(16)
    let registration = try registrationMessage(
      instance, resolved: resolved, boot: (bootInfo.ownerPID, ownerStart), nonce: nonce,
      socket: socket)
    let registered = try control(registration)
    guard case .string(let sessionID)? = registered["session_id"],
      case .string(let epoch)? = registered["epoch"],
      case .string(let capability)? = registered["capability"],
      registered["socket"] == .string(socket)
    else { throw HostError("iso-inference returned an incomplete registration") }
    let token = Secret(capability)
    do {
      try verifyRegistered(instance, sessionID: sessionID, nonce: nonce)
      // The session lives as long as the owner process that carries the
      // instance's relay: its exit (VM stop) revokes the session.
      var activation: [(String, OutputJSON)] = [
        ("version", .uint(Self.controlVersion)), ("op", .string("activate_session")),
        ("session_id", .string(sessionID)), ("epoch", .string(epoch)),
        (
          "transport",
          .object([("pid", .int(Int64(bootInfo.ownerPID))), ("start", .string(ownerStart))])
        ),
      ]
      if let deadline = bootInfo.deadline {
        activation.append(
          ("deadline_seconds", .int(max(1, Int64(deadline.timeIntervalSinceNow.rounded(.down))))))
      }
      _ = try control(activation)
      try AtomicFile.write(
        Array(capability.utf8), to: Self.tokenPath(instance), mode: .atMost(0o600))
      try AtomicFile.write(
        Array(
          OutputJSON.object([
            ("session_id", .string(sessionID)), ("epoch", .string(epoch)),
            ("owner_pid", .int(Int64(bootInfo.ownerPID))), ("owner_start", .string(ownerStart)),
            ("fingerprint", .string(fingerprint)),
            ("services", .array(services.map { .string($0.rawValue) })),
          ]).rendered().utf8), to: Self.statePath(instance), mode: .atMost(0o600))
    } catch {
      _ = try? control([
        ("version", .uint(Self.controlVersion)), ("op", .string("revoke_session")),
        ("session_id", .string(sessionID)),
      ])
      removeState(instance)
      throw ContextError(
        "Failed to establish the inference session for '\(instance.name)' (fail-closed; no raw or cloud fallback)",
        cause: error)
    }
    diagnostics.log(
      .info,
      "Inference gateway session active for '\(instance.name)' (guest → 127.0.0.1:\(Self.guestPort) over the sandbox relay; services \(services.map(\.rawValue).joined(separator: ", ")))"
    )
    return (
      InferenceSession(sessionID: sessionID, epoch: epoch, token: token, services: services),
      (bootInfo.ownerPID, ownerStart)
    )
  }

  /// The relay socket's file name, when the isolation gate verified it in
  /// the relay directory. A sandbox booted without a relay cannot carry a
  /// session.
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
  /// the same epoch and the sandbox owner it was bound to still runs.
  func current(_ instance: Instance) -> (
    session: InferenceSession, fingerprint: String, owner: (pid: Int32, start: String)
  )? {
    guard let bytes = try? StateStore.readControlFile(Self.statePath(instance)),
      case .object(let state)? = try? ConfigLoader.parse(
        bytes, format: .json, path: "inference.json", limits: .configuration),
      case .string(let sessionID)? = state["session_id"], case .string(let epoch)? = state["epoch"],
      case .string(let fingerprint)? = state["fingerprint"],
      let ownerPID = state["owner_pid"].flatMap(Self.integer).flatMap(Int32.init(exactly:)),
      case .string(let ownerStart)? = state["owner_start"],
      HostProcess.start(ownerPID) == ownerStart,
      case .array(let rawServices)? = state["services"],
      let tokenBytes = try? StateStore.readControlFile(Self.tokenPath(instance)),
      let token = String(validating: tokenBytes, as: UTF8.self),
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
    return (
      InferenceSession(
        sessionID: sessionID, epoch: epoch, token: Secret(token), services: services), fingerprint,
      (ownerPID, ownerStart)
    )
  }

  /// Revoke at the gateway (when it runs), stop the forward and remove the
  /// capability. Idempotent and best effort: the forward's exit alone also
  /// revokes the session at the gateway (§12.3).
  package func revoke(_ instance: Instance) {
    sessions.forget(instance)
    _ = try? control([
      ("version", .uint(Self.controlVersion)), ("op", .string("revoke_session")),
      ("instance", .object(instanceKey(instance))),
    ])
    removeState(instance)
  }

  /// `iso inference revoke`: as `revoke`, and the instance stays revoked
  /// until the VM restarts or a new grant is attached.
  package func revokeManually(_ instance: Instance) throws {
    revoke(instance)
    try AtomicFile.write(
      Array("revoked\n".utf8), to: Self.revokedPath(instance), mode: .atMost(0o600))
  }

  package func isManuallyRevoked(_ instance: Instance) -> Bool {
    FileManager.default.fileExists(atPath: Self.revokedPath(instance))
  }

  /// A VM restart or an explicit attach lifts a manual revocation.
  package static func clearManualRevocation(_ instance: Instance) {
    unlink(revokedPath(instance))
  }

  func removeState(_ instance: Instance) {
    unlink(Self.statePath(instance))
    unlink(Self.tokenPath(instance))
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
    nonce: String, socket: String
  ) throws -> [(String, OutputJSON)] {
    let limits = config.inference.globalLimits
    return [
      ("version", .uint(Self.controlVersion)), ("op", .string("register_session")),
      ("instance", .object(instanceKey(instance))),
      ("boot", .object([("owner_pid", .int(Int64(boot.0))), ("owner_start", .string(boot.1))])),
      ("nonce", .string(nonce)), ("socket", .string(socket)),
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
  package static func exposedAddresses(port: UInt16) -> [String] {
    Socket.nonLoopbackAddresses().filter {
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
    return Self.realPath(candidate)
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

  /// A verified connection check: the socket's peer is this user's
  /// `iso-inference` binary beside this `iso`. With `start`, launches it.
  @discardableResult
  package func connect(start: Bool) throws -> Int32 {
    if let peer = try? ControlSocket.peer(socketPath) {
      try verifyPeer(peer)
      return peer.pid
    }
    guard start else { throw HostError("the inference gateway is not running") }
    let binary = try locateBinary()
    let directory = try prepareStateDirectory()
    let relay = try prepareRelayDirectory()
    let logPath = directory + "/gateway.log"
    let log = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
    guard log >= 0 else { throw HostError.posix("Failed to open", logPath) }
    defer { close(log) }
    let ports = backendPorts
    guard !ports.isEmpty else { throw HostError("inference configuration names no backend") }
    var child = try DetachedChild.spawn(
      executable: sandboxExec,
      arguments: [
        "-D", "INFERENCE_BIN=\(binary)", "-D", "STATE_DIR=\(directory)", "-D",
        "RELAY_DIR=\(relay)", "-p", SeatbeltProfile.inference(backendPorts: ports), binary,
        "--state-dir", directory, "--relay-dir", relay,
      ] + ports.flatMap { ["--backend-port", String($0)] }, environment: [:], stdin: .null,
      stderr: log)
    let deadline = ContinuousClock.now + Self.startTimeout
    while ContinuousClock.now < deadline {
      if let peer = try? ControlSocket.peer(socketPath) {
        try verifyPeer(peer)
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

  func verifyPeer(_ peer: ControlSocket.Peer) throws {
    guard peer.uid == getuid() else {
      throw HostError("the inference control socket is served by another user — refusing to use it")
    }
    let expected = try locateBinary()
    guard let path = HostProcess.executablePath(peer.pid), Self.realPath(path) == expected else {
      throw HostError(
        "a different iso-inference (pid \(peer.pid)) serves \(socketPath); stop it with `iso inference stop` and retry"
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
        socketPath, body, timeoutSeconds: Self.controlTimeoutSeconds, verify: verifyPeer)
    } catch let error as ControlSocket.Unreachable {
      throw HostError("the inference gateway is not running (\(error.reason))")
    }
    guard
      case .object(let members) = try ConfigLoader.parse(
        reply, format: .json, path: "iso-inference", limits: .configuration)
    else { throw HostError("iso-inference sent a malformed reply") }
    guard members["version"].flatMap(Self.integer) == Int64(Self.controlVersion) else {
      throw HostError("iso-inference speaks an unsupported control protocol version")
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
