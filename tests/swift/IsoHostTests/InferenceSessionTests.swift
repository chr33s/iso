import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

/// A stand-in `iso-inference` on a Unix control socket in this process:
/// it keeps sessions as a real gateway would (register → inactive with the
/// nonce, activate → active, revoke → gone) and records every request.
/// `override` answers an op instead (an error, a malformed reply).
final class FakeGateway: Sendable {
  struct State {
    /// Each request as received (JSON), in order.
    var requests: [Data] = []
    var sessions: [(id: String, nonce: String, state: String, instance: String)] = []
    var epoch = "epoch-1"
    var next = 0
    var override: [String: [String: Any]] = [:]
    var version = 6
    /// Whether registrations name a worker key, as the broker does.
    var workerKeys = true
    /// The backend ports it was "launched" for.
    var ports: [Int] = []
  }

  let path: String
  let fd: Int32
  let state = Mutex(State())
  /// Called with each request before it is answered (e.g. to check host
  /// state at that moment).
  let observer: Mutex<(@Sendable ([String: Any]) -> Void)?> = Mutex(nil)

  init(path: String) throws {
    self.path = path
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    chmod((path as NSString).deletingLastPathComponent, 0o700)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, listen(fd, 16) == 0 else { throw HostError("bind failed") }
    let listener = fd
    Thread { [self] in
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        self.serve(connection)
      }
    }.start()
  }

  func serve(_ connection: Int32) {
    defer { Darwin.close(connection) }
    var one: Int32 = 1
    setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var header = [UInt8](repeating: 0, count: 4)
    guard recv(connection, &header, 4, MSG_WAITALL) == 4 else { return }
    let length = header.reduce(0) { ($0 << 8) | Int($1) }
    var body = [UInt8](repeating: 0, count: max(length, 1))
    guard recv(connection, &body, length, MSG_WAITALL) == length,
      let request = try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))
        as? [String: Any]
    else { return }
    observer.withLock { $0 }?(request)
    let raw = Data(body.prefix(length))
    let encoded = state.withLock { state -> Data in
      state.requests.append(raw)
      return (try? JSONSerialization.data(withJSONObject: answer(raw, &state))) ?? Data()
    }
    let data = Array(encoded)
    let size = UInt32(data.count)
    let frame =
      [
        UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF),
        UInt8(size & 0xFF),
      ]
      + data
    _ = frame.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
  }

  func answer(_ raw: Data, _ s: inout State) -> [String: Any] {
    let request = (try? JSONSerialization.jsonObject(with: raw) as? [String: Any]) ?? [:]
    let op = request["op"] as? String ?? ""
    if var reply = s.override[op] {
      reply["version"] = reply["version"] ?? s.version
      return reply
    }
    var reply: [String: Any] = ["version": s.version, "ok": true]
    let instance = (request["instance"] as? [String: Any])?["name"] as? String ?? ""
    switch op {
    case "register_session":
      s.next += 1
      let id = "session-\(s.next)"
      s.sessions.append((id, request["nonce"] as? String ?? "", "inactive", instance))
      reply["session_id"] = id
      reply["epoch"] = s.epoch
      reply["capability"] = String(repeating: "c", count: 63) + String(s.next % 10)
      reply["socket"] = request["socket"]
      if s.workerKeys {
        reply["worker_key"] = String(repeating: "d", count: 63) + String(s.next % 10)
      }
    case "activate_session":
      let id = request["session_id"] as? String
      for index in s.sessions.indices where s.sessions[index].id == id {
        s.sessions[index].state = "active"
      }
    case "revoke_session":
      if let id = request["session_id"] as? String {
        s.sessions.removeAll { $0.id == id }
      } else {
        s.sessions.removeAll { $0.instance == instance }
      }
    case "inspect":
      reply["gateway"] = ["epoch": s.epoch, "pid": getpid(), "gateway_egress_ports": s.ports]
      reply["sessions"] = s.sessions.map {
        [
          "session_id": $0.id, "nonce": $0.nonce, "state": $0.state,
          "instance": ["name": $0.instance],
        ]
      }
    default: break
    }
    return reply
  }

  /// The first request with `op`, decoded.
  func request(_ op: String) -> [String: Any]? {
    state.withLock { $0.requests }.lazy.compactMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }.first { $0["op"] as? String == op }
  }

  var ops: [String] {
    state.withLock { $0.requests }.compactMap {
      (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["op"] as? String
    }
  }

  func stop() {
    shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
    unlink(path)
  }
}

private struct Rig {
  let guest: FakeGuest
  let gateway: FakeGateway
  /// The workers the controller started, in order.
  let launches = Launches()
  let instance: Instance
  let backends: [TCPListener]
  let stateDirectory: String
  let relay: String

  init(services: Bool = true) throws {
    guest = try FakeGuest()
    stateDirectory = guest.root + "/st"
    relay = guest.root + "/rl"
    try FileManager.default.createDirectory(atPath: relay, withIntermediateDirectories: true)
    chmod(relay, 0o700)
    gateway = try FakeGateway(path: stateDirectory + "/control.sock")
    instance = try testInstance(guest.root + "/instance")
    backends = [try TCPListener(address: "127.0.0.1")]
    let ports = backends.map { Int($0.port) }
    gateway.state.withLock { $0.ports = ports }
    _ = services
  }

  var config: IsoConfig {
    get throws {
      try testConfig(
        #"""
        "inference": {
          "mode": "required",
          "qualification_profiles": {"p": {"protocol": "anthropic-messages",
            "completion_evidence": "drain", "context_overflow": "reject",
            "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
            "max_input_bytes": 1024}},
          "backends": {"b": {"isolation": "unverified", "base_url": "http://127.0.0.1:\#(backends[0].port)",
            "protocol": "anthropic-messages", "qualification_profile": "p"}},
          "services": {"s": {"backend": "b", "upstream_model": "m",
            "frontend_apis": ["anthropic-messages"], "max_context_tokens": 1000}}
        },
        "claude": {"local_model": {"service": "s"}}
        """#)
    }
  }

  /// A brokered boot's carrier: the derived socket, and whether the boot's
  /// network policy grants the forward.
  func forward(granted: Bool = true) -> InferenceCarrier {
    .forward(socket: relay + "/8e84.sock", granted: granted)
  }

  func controller(
    _ config: IsoConfig? = nil, carrier: InferenceCarrier? = nil, relayDirectory: String? = nil
  ) throws -> InferenceController {
    let resolver = CredentialResolver(environment: guest.environment)
    let relay = relayDirectory ?? self.relay
    let carrier = carrier ?? .relay(socket: relay + "/8e84.sock")
    return InferenceController(
      config: try config ?? self.config, environment: guest.environment, resolver: resolver,
      diagnostics: guest.sink.diagnostics, isoExecutable: nil, proxies: guest.proxies(resolver),
      boot: { _ in InferenceBoot(ownerPID: getpid(), deadline: nil, carrier: carrier) },
      sandboxExec: "/usr/bin/false", stateDirectory: stateDirectory, relayDirectory: relay,
      peerCheck: { _ in }, carrierCheck: { _, _ in },
      workerLauncher: { [launches] launch in launches.record(launch) })
  }

  func remove() {
    gateway.stop()
    for backend in backends { backend.close() }
    guest.remove()
  }
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

/// §12.2: register, check the nonce, configure the guest, and only then
/// activate and persist; the capability reaches only the guest
/// configuration, and the host keeps no copy of it (§12.1).
@Test func sessionsAreActivatedOnlyAfterTheGuestIsConfigured() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller()
  var configuredBeforeActivation = false
  var capability = ""
  let result = try #require(
    try control.ensureSession(rig.instance, target: rig.guest.target) { _, token in
      capability = token.expose()
      configuredBeforeActivation = !rig.gateway.ops.contains("activate_session")
    })
  #expect(capability.count == 64)
  #expect(result.fresh)
  #expect(configuredBeforeActivation)
  let ops = rig.gateway.ops.filter { $0 != "inspect" }
  #expect(ops == ["revoke_session", "register_session", "activate_session"], "\(ops)")
  // Control protocol 6: the vmnet relay is carried by the sandbox owner, and
  // an attached backend is a plain front end, never challenged.
  let registration = try #require(rig.gateway.request("register_session"))
  #expect(registration["version"] as? Int == 6)
  #expect(registration["transport"] as? String == "owner")
  let backend = (registration["grants"] as? [[String: Any]])?.first?["backend"] as? [String: Any]
  #expect(backend?["front"] as? String == "plain")
  // The relay is the owner's: no SSH forward is started for it.
  #expect(rig.guest.log("tunnels.log").isEmpty)
  #expect(result.session.transport == .owner)
  #expect(exists(InferenceController.statePath(rig.instance)))
  #expect(!exists(InferenceController.legacyTokenPath(rig.instance)))
  #expect(!(readFile(InferenceController.statePath(rig.instance)) ?? "").contains(capability))
  // A later command reuses the recorded active session.
  let again = try #require(
    try rig.controller().ensureSession(rig.instance, target: rig.guest.target))
  #expect(!again.fresh && again.session == result.session)
  #expect(rig.gateway.ops.filter { $0 == "register_session" }.count == 1)
}

/// A failed guest configuration revokes the registered session; nothing is
/// activated or persisted (no session the guest is not set up for).
@Test func aFailedGuestConfigurationRevokesThePartialSession() throws {
  let rig = try Rig()
  defer { rig.remove() }
  #expect(throws: (any Error).self) {
    try rig.controller().ensureSession(rig.instance, target: rig.guest.target) { _, _ in
      throw HostError("bridge install failed")
    }
  }
  #expect(!rig.gateway.ops.contains("activate_session"))
  #expect(rig.gateway.state.withLock { $0.sessions.isEmpty })
  #expect(!exists(InferenceController.statePath(rig.instance)))
  #expect(!exists(InferenceController.legacyTokenPath(rig.instance)))
}

/// The registration must show up with its nonce, inactive, before anything
/// is activated.
@Test func aRegistrationWithoutItsNonceIsNotActivated() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let ports = rig.backends.map { Int($0.port) }
  rig.gateway.state.withLock {
    $0.override["inspect"] = [
      "ok": true, "gateway": ["epoch": "epoch-1", "gateway_egress_ports": ports],
      "sessions": [["session_id": "session-1", "nonce": "other", "state": "inactive"]],
    ]
  }
  let error = try #require(throws: (any Error).self) {
    try rig.controller().ensureSession(rig.instance, target: rig.guest.target)
  }
  #expect("\(error)".contains("nonce"))
  #expect(rig.gateway.ops.contains("register_session"))
  #expect(!rig.gateway.ops.contains("activate_session"))
  #expect(!exists(InferenceController.statePath(rig.instance)))
}

/// `current()`: a recorded session counts only under the same epoch, the
/// same sandbox owner (PID and start time) and while the gateway reports it
/// active.
@Test func recordedSessionsNeedTheEpochOwnerAndActiveState() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller()
  _ = try control.ensureSession(rig.instance, target: rig.guest.target)
  #expect(control.current(rig.instance) != nil)
  rig.gateway.state.withLock { $0.epoch = "epoch-2" }
  #expect(control.current(rig.instance) == nil, "a restarted gateway")
  rig.gateway.state.withLock {
    $0.epoch = "epoch-1"
    $0.sessions[0].state = "inactive"
  }
  #expect(control.current(rig.instance) == nil, "not active")
  rig.gateway.state.withLock { $0.sessions[0].state = "active" }
  let state = try #require(readFile(InferenceController.statePath(rig.instance)))
  try writeFile(
    InferenceController.statePath(rig.instance),
    state.replacingOccurrences(of: "\"owner_start\" : \"", with: "\"owner_start\" : \"1"))
  #expect(control.current(rig.instance) == nil, "another owner process")
}

/// H4: two commands establishing at once register one session; neither
/// revokes the other's or removes its state.
@Test func concurrentEstablishersShareOneSession() throws {
  let rig = try Rig()
  defer { rig.remove() }
  // Slow the first registration so both commands overlap.
  rig.gateway.observer.withLock {
    $0 = { request in
      if request["op"] as? String == "register_session" { usleep(300_000) }
    }
  }
  let results = Mutex<[InferenceSession?]>([])
  let group = DispatchGroup()
  for _ in 0..<2 {
    let control = try rig.controller()
    let instance = rig.instance
    let target = rig.guest.target
    DispatchQueue.global().async(group: group) {
      let session = try? control.ensureSession(instance, target: target)?.session
      results.withLock { $0.append(session) }
    }
  }
  group.wait()
  let sessions = results.withLock { $0 }
  #expect(sessions.count == 2 && sessions.allSatisfy { $0 != nil })
  #expect(sessions[0] == sessions[1])
  #expect(rig.gateway.ops.filter { $0 == "register_session" }.count == 1)
  #expect(rig.gateway.state.withLock { $0.sessions.map(\.state) } == ["active"])
  #expect(exists(InferenceController.statePath(rig.instance)))
}

/// H3: only "gateway not running" counts as revoked; a refusal, a protocol
/// mismatch or a failed peer check throws and keeps the state.
@Test func revocationFailuresAreReported() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller()
  _ = try control.ensureSession(rig.instance, target: rig.guest.target)
  rig.gateway.state.withLock {
    $0.override["revoke_session"] = [
      "ok": false, "code": "INFERENCE_CONTROL_DENIED", "message": "no",
    ]
  }
  let refused = try #require(throws: (any Error).self) { try control.revoke(rig.instance) }
  #expect("\(refused)".contains("INFERENCE_CONTROL_DENIED"))
  #expect(exists(InferenceController.statePath(rig.instance)))
  rig.gateway.state.withLock {
    $0.override = [:]
    $0.version = 2
  }
  #expect(throws: InferenceGatewayIncompatible.self) { try control.revoke(rig.instance) }
  #expect(exists(InferenceController.statePath(rig.instance)))
  // A peer that fails verification is never sent the request.
  let unverified = InferenceController(
    config: try rig.config, environment: rig.guest.environment,
    resolver: CredentialResolver(environment: rig.guest.environment),
    diagnostics: rig.guest.sink.diagnostics, isoExecutable: nil,
    proxies: rig.guest.proxies(), boot: { _ in throw HostError("unused") },
    sandboxExec: "/usr/bin/false", stateDirectory: rig.stateDirectory,
    relayDirectory: rig.relay, peerCheck: { _ in throw HostError("wrong peer") })
  #expect(throws: HostError.self) { try unverified.revoke(rig.instance) }
  #expect(exists(InferenceController.statePath(rig.instance)))
  // No gateway at all: nothing holds the session, so the state goes.
  rig.gateway.stop()
  try control.revoke(rig.instance)
  #expect(!exists(InferenceController.statePath(rig.instance)))
}

/// H11: `iso inference revoke` records the revocation before asking the
/// gateway, and while it is recorded no session is established.
@Test func manualRevocationIsRecordedFirstAndHolds() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller()
  _ = try control.ensureSession(rig.instance, target: rig.guest.target)
  let markedFirst = Mutex<Bool?>(nil)
  let marker = InferenceController.revokedPath(rig.instance)
  rig.gateway.observer.withLock {
    $0 = { request in
      if request["op"] as? String == "revoke_session" {
        let marked = FileManager.default.fileExists(atPath: marker)
        markedFirst.withLock { if $0 == nil { $0 = marked } }
      }
    }
  }
  try control.revokeManually(rig.instance)
  #expect(markedFirst.withLock { $0 } == true)
  #expect(control.isManuallyRevoked(rig.instance))
  let before = rig.gateway.ops.count
  #expect(try rig.controller().ensureSession(rig.instance, target: rig.guest.target) == nil)
  #expect(rig.gateway.ops.count == before, "a revoked instance asks the gateway for nothing")
  InferenceController.clearManualRevocation(rig.instance)
  #expect(try rig.controller().ensureSession(rig.instance, target: rig.guest.target) != nil)
}

/// H10: under `off`, a session recorded under `required` is revoked.
@Test func switchingInferenceOffRevokesTheRecordedSession() throws {
  let rig = try Rig()
  defer { rig.remove() }
  _ = try rig.controller().ensureSession(rig.instance, target: rig.guest.target)
  let off = try rig.controller(try testConfig())
  #expect(try off.ensureSession(rig.instance, target: rig.guest.target) == nil)
  #expect(rig.gateway.state.withLock { $0.sessions.isEmpty })
  #expect(!exists(InferenceController.statePath(rig.instance)))
  // The bootstrap's mode check does the same before a handoff.
  _ = try rig.controller().ensureSession(rig.instance, target: rig.guest.target)
  let agents = AgentBootstrap(
    config: try testConfig(), client: rig.guest.client, environment: rig.guest.environment,
    home: rig.guest.root + "/hosthome",
    resolver: CredentialResolver(environment: rig.guest.environment),
    proxies: rig.guest.proxies(), github: NoGitHub(), diagnostics: rig.guest.sink.diagnostics,
    inference: off)
  agents.reconcileInferenceMode([rig.instance])
  #expect(rig.gateway.state.withLock { $0.sessions.isEmpty })
  #expect(!exists(InferenceController.statePath(rig.instance)))
}

/// K4: a shell or hook session without inference warns and carries no
/// inference variables; an agent launch fails.
@Test func onlyAgentLaunchesFailWithoutAnInferenceSession() throws {
  let rig = try Rig()
  defer { rig.remove() }
  rig.gateway.state.withLock {
    $0.override["register_session"] = ["ok": false, "code": "INFERENCE_BACKEND_UNAVAILABLE"]
  }
  let agents = AgentBootstrap(
    config: try rig.config, client: rig.guest.client, environment: rig.guest.environment,
    home: rig.guest.root + "/hosthome",
    resolver: CredentialResolver(environment: rig.guest.environment),
    proxies: rig.guest.proxies(), github: NoGitHub(), diagnostics: rig.guest.sink.diagnostics,
    inference: try rig.controller())
  #expect(try agents.optionalInferenceSession(rig.instance, target: rig.guest.target) == nil)
  #expect(rig.guest.sink.text.contains("continuing without model access"))
  #expect(throws: (any Error).self) {
    try agents.withStrictInference().optionalInferenceSession(
      rig.instance, target: rig.guest.target)
  }
}

/// A grant whose service is gone names its file and the way out.
@Test func aStaleAttachGrantNamesItsFile() throws {
  let rig = try Rig()
  defer { rig.remove() }
  try InferenceAttachGrant(service: try InferenceServiceName("gone"), api: .openAIChat)
    .save(rig.instance)
  let error = try #require(throws: HostError.self) {
    try rig.controller().requestedServices(rig.instance)
  }
  #expect(error.message.contains(InferenceAttachGrant.path(rig.instance)))
  #expect(error.message.contains("iso inference detach"))
  #expect(try InferenceAttachGrant.remove(rig.instance))
  #expect(try rig.controller().requestedServices(rig.instance).map(\.rawValue) == ["s"])
  #expect(try !InferenceAttachGrant.remove(rig.instance))
}

/// The control socket's peer: this user, the `iso-inference` beside iso,
/// and sandboxed.
@Test func gatewayPeersMustBeTheConfinedCompanion() throws {
  let me = ControlSocket.Peer(pid: getpid(), uid: getuid())
  let path = { (_: Int32) -> String? in "/opt/iso/bin/iso-inference" }
  try InferenceController.verifyPeer(
    me, expected: "/opt/iso/bin/iso-inference", socketPath: "s", executablePath: path,
    sandboxed: { _ in true })
  #expect(throws: HostError.self) {
    try InferenceController.verifyPeer(
      ControlSocket.Peer(pid: 1, uid: getuid() &+ 1), expected: "/opt/iso/bin/iso-inference",
      socketPath: "s", executablePath: path, sandboxed: { _ in true })
  }
  #expect(throws: HostError.self) {
    try InferenceController.verifyPeer(
      me, expected: "/opt/iso/bin/iso-inference", socketPath: "s",
      executablePath: { _ in "/tmp/impostor" }, sandboxed: { _ in true })
  }
  for sandboxed in [false, nil] as [Bool?] {
    #expect(throws: HostError.self) {
      try InferenceController.verifyPeer(
        me, expected: "/opt/iso/bin/iso-inference", socketPath: "s", executablePath: path,
        sandboxed: { _ in sandboxed })
    }
  }
}

/// The gateway's directories: owner-only, owned by this user.
@Test func gatewayDirectoriesMustBePrivate() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller()
  chmod(rig.relay, 0o755)
  #expect(throws: HostError.self) { try control.prepareRelayDirectory() }
  chmod(rig.relay, 0o700)
  #expect(try control.prepareRelayDirectory() == BinaryResolver.canonicalPath(rig.relay))
  chmod(rig.stateDirectory, 0o755)
  _ = try control.prepareStateDirectory()
  var info = stat()
  #expect(lstat(rig.stateDirectory, &info) == 0 && info.st_mode & 0o077 == 0)
  try FileManager.default.removeItem(atPath: rig.relay)
  try FileManager.default.createSymbolicLink(atPath: rig.relay, withDestinationPath: "/tmp")
  #expect(throws: HostError.self) { try control.prepareRelayDirectory() }
}

/// Without a session Claude still points at the gateway, never at
/// Anthropic's defaults (INV-08), and an attach grant's base URL suits its
/// SDK (no `/v1/v1`).
@Test func agentsWithoutASessionReachNoModel() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let agents = rig.guest.bootstrap(try rig.config)
  let blocked = agents.claudeInferenceEnv(nil)
  #expect(blocked["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:11788")
  #expect(blocked["ANTHROPIC_AUTH_TOKEN"] == AgentBootstrap.noSessionToken)
  #expect(
    agents.codexInferenceTable(nil).document.contains(#"base_url = "http://127.0.0.1:11788/v1""#))
  let session = InferenceSession(sessionID: "s", epoch: "e", services: [])
  #expect(agents.claudeKeyHelper(nil) == nil, "no session: the refused token stands")
  #expect(AgentBootstrap.attachBaseURL(.anthropicCountTokens, session) == "http://127.0.0.1:11788")
  #expect(AgentBootstrap.attachBaseURL(.anthropicMessages, session) == "http://127.0.0.1:11788")
  #expect(AgentBootstrap.attachBaseURL(.openAIChat, session) == "http://127.0.0.1:11788/v1")
}

// MARK: - Brokered: the fixed SSH reverse forward (§22.9)

/// Whether `pid` still runs; an exited child of this test process is
/// reaped first (the forward master is one).
private func isRunning(_ pid: Int32) -> Bool {
  var status: Int32 = 0
  _ = waitpid(pid, &status, WNOHANG)
  return kill(pid, 0) == 0
}

/// The forward's master, as the tunnel identity records it.
private func forwardMaster(_ rig: Rig) -> Int32? {
  TunnelIdentity.load(rig.instance, ProxyLauncher.inferenceTunnelName)?.pid
}

/// The activation's transport binding.
private func activationTransport(_ rig: Rig) -> (pid: Int?, version: Int?) {
  let transport = rig.gateway.request("activate_session")?["transport"] as? [String: Any]
  return (transport?["pid"] as? Int, transport?["version"] as? Int)
}

/// A brokered session registers as `forward`, starts exactly the fixed
/// reverse forward to its socket after the guest is configured and before
/// activation, and activates bound to that forward's process (PID and start
/// time), never the owner. No guest bridge is installed.
@Test func brokeredSessionsBindTheFixedForwardStartedAfterTheGuestIsConfigured() throws {
  let rig = try Rig()
  defer { rig.remove() }
  var forwardedBeforeConfiguration = true
  let result = try #require(
    try rig.controller(carrier: rig.forward()).ensureSession(
      rig.instance, target: rig.guest.target
    ) { _, _ in
      forwardedBeforeConfiguration = !rig.guest.log("tunnels.log").isEmpty
    })
  defer { if let pid = forwardMaster(rig) { kill(pid, SIGKILL) } }
  #expect(!forwardedBeforeConfiguration)
  #expect(result.fresh && result.session.transport == .forward)
  let ops = rig.gateway.ops.filter { $0 != "inspect" }
  #expect(ops == ["revoke_session", "register_session", "activate_session"], "\(ops)")
  let registration = try #require(rig.gateway.request("register_session"))
  #expect(registration["transport"] as? String == "forward")
  #expect(registration["socket"] as? String == "8e84.sock")
  // Exactly one static forward: guest 127.0.0.1:11788 to the session socket.
  let forwards = rig.guest.log("tunnels.log").filter { $0.hasPrefix("forward ") }
  #expect(forwards.count == 1, "\(forwards)")
  let words = forwards.first?.split(separator: " ").map(String.init) ?? []
  let spec = zip(words, words.dropFirst()).filter { $0.0 == "-R" }.map(\.1)
  #expect(spec == ["127.0.0.1:11788:\(rig.relay)/8e84.sock"], "\(words)")
  for line in rig.guest.log("tunnels.log") {
    let flags = line.split(separator: " ").map(String.init)
    #expect(!flags.contains("-D") && !flags.contains("-L"), "no dynamic or local forward: \(line)")
  }
  // Activation names the forward's master, not the sandbox owner.
  let master = try #require(forwardMaster(rig))
  #expect(master != getpid())
  let bound = activationTransport(rig)
  #expect(bound.pid == Int(master))
  #expect(bound.version.map(UInt32.init) == HostProcess.pidVersion(master))
  let state = try #require(readFile(InferenceController.statePath(rig.instance)))
  #expect(state.contains(#""transport" : "forward""#), "\(state)")
  #expect(state.contains(#""forward_pid" : \#(master)"#), "\(state)")
  // A later command reuses it while the forward runs.
  let again = try #require(
    try rig.controller(carrier: rig.forward()).ensureSession(
      rig.instance, target: rig.guest.target))
  #expect(!again.fresh && again.session == result.session)
}

/// Revocation (iso inference revoke, mode off, a replaced session) closes
/// the forward and revokes the session at the gateway; stop and destroy
/// close it with the instance's other tunnels.
@Test func revokingABrokeredSessionClosesItsForward() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller(carrier: rig.forward())
  _ = try control.ensureSession(rig.instance, target: rig.guest.target)
  let first = try #require(forwardMaster(rig))
  #expect(isRunning(first))
  try control.revokeManually(rig.instance)
  #expect(waitUntil { !isRunning(first) }, "the forward outlived its revocation")
  #expect(forwardMaster(rig) == nil)
  #expect(rig.gateway.state.withLock { $0.sessions.isEmpty })
  #expect(!exists(InferenceController.statePath(rig.instance)))

  // Mode off revokes, and closes the forward, before anything else.
  InferenceController.clearManualRevocation(rig.instance)
  _ = try control.ensureSession(rig.instance, target: rig.guest.target)
  let second = try #require(forwardMaster(rig))
  let off = try testConfig(#""inference": {"mode": "off"}"#)
  #expect(
    try rig.controller(off, carrier: rig.forward()).ensureSession(
      rig.instance, target: rig.guest.target) == nil)
  #expect(waitUntil { !isRunning(second) })

  // Stopping the instance's tunnels closes it too.
  _ = try control.ensureSession(rig.instance, target: rig.guest.target)
  let third = try #require(forwardMaster(rig))
  rig.guest.proxies().stopAll(rig.instance)
  #expect(waitUntil { !isRunning(third) })
}

/// The forward's death ends the recorded session (NET-08) and revokes the
/// instance until it restarts (§22.9): neither the memo nor the record
/// reuses it, and no command registers a new session or starts a new
/// forward. A restart or an attach lifts it; the next session is a fresh
/// registration over a new forward, never another transport.
@Test func aDeadForwardRevokesTheInstanceUntilItRestarts() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller(carrier: rig.forward())
  let first = try #require(try control.ensureSession(rig.instance, target: rig.guest.target))
  let master = try #require(forwardMaster(rig))
  #expect(control.current(rig.instance) != nil)
  kill(master, SIGKILL)
  #expect(waitUntil { !isRunning(master) })
  #expect(control.current(rig.instance) == nil, "a recorded session without its forward")
  #expect(control.forwardDied(rig.instance))
  let forwards = { rig.guest.log("tunnels.log").filter { $0.hasPrefix("forward ") }.count }
  #expect(forwards() == 1)
  #expect(try control.ensureSession(rig.instance, target: rig.guest.target) == nil)
  #expect(InferenceController.revocation(rig.instance) == .forwardExited)
  #expect(rig.gateway.state.withLock { $0.sessions.isEmpty })
  #expect(!exists(InferenceController.statePath(rig.instance)))
  let warning = rig.guest.sink.text
  #expect(warning.contains("inference forward of '\(rig.instance.name)' exited"), "\(warning)")
  #expect(warning.contains("iso stop \(rig.instance.name)"), "\(warning)")
  #expect(warning.contains("iso inference attach \(rig.instance.name)"), "\(warning)")
  // It holds for later commands, through a fresh controller (no memo).
  let registrations = {
    rig.gateway.state.withLock { $0.requests }.compactMap {
      try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
    }.filter { $0["op"] as? String == "register_session" }
  }
  for _ in 0..<2 {
    #expect(
      try rig.controller(carrier: rig.forward()).ensureSession(
        rig.instance, target: rig.guest.target) == nil)
  }
  #expect(registrations().count == 1, "a dead forward is never silently replaced")
  #expect(forwards() == 1 && forwardMaster(rig) == nil)

  // A restart (or an attach) lifts it, as for `iso inference revoke`.
  InferenceController.clearManualRevocation(rig.instance)
  let next = try #require(try control.ensureSession(rig.instance, target: rig.guest.target))
  defer { if let pid = forwardMaster(rig) { kill(pid, SIGKILL) } }
  #expect(next.fresh && next.session != first.session)
  #expect(next.session.transport == .forward)
  #expect(registrations().map { $0["transport"] as? String } == ["forward", "forward"])
  #expect(try #require(forwardMaster(rig)) != master)
}

/// A revocation recorded while a command waits for the session lock (as a
/// concurrent command that found the forward dead records it) holds: the
/// waiting command registers nothing once it holds the lock.
@Test func aRevocationRecordedWhileWaitingForTheLockHolds() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller(carrier: rig.forward())
  let lock = try FileLock.sibling(of: InferenceController.statePath(rig.instance))
  let result = Mutex<Result<Bool, any Error>?>(nil)
  let group = DispatchGroup()
  let instance = rig.instance
  let target = rig.guest.target
  DispatchQueue.global().async(group: group) {
    let outcome = Result { try control.ensureSession(instance, target: target) == nil }
    result.withLock { $0 = outcome }
  }
  usleep(500_000)
  try AtomicFile.write(
    Array("forward-exited\n".utf8), to: InferenceController.revokedPath(rig.instance),
    mode: .atMost(0o600))
  lock.release()
  group.wait()
  defer { if let pid = forwardMaster(rig) { kill(pid, SIGKILL) } }
  #expect(try result.withLock { try $0?.get() } == true)
  #expect(!rig.gateway.ops.contains("register_session"))
  #expect(rig.guest.log("tunnels.log").isEmpty)
}

/// A forward record from a previous boot (its sandbox owner gone) is not a
/// forward death: the new boot establishes its own session.
@Test func aPreviousBootsForwardRecordIsNotAForwardDeath() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller(carrier: rig.forward())
  _ = try control.ensureSession(rig.instance, target: rig.guest.target)
  let master = try #require(forwardMaster(rig))
  kill(master, SIGKILL)
  #expect(waitUntil { !isRunning(master) })
  let path = InferenceController.statePath(rig.instance)
  let state = try #require(readFile(path))
  let rewritten = state.replacingOccurrences(
    of: #""owner_start" : ""#, with: #""owner_start" : "0."#)
  #expect(rewritten != state)
  try writeFile(path, rewritten)
  #expect(!control.forwardDied(rig.instance))
}

/// A brokered boot whose policy lacks the grant, a failing forward, or a
/// refused activation leaves no session and no forward.
@Test func aBrokeredSessionFailsClosed() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let ungranted = try #require(throws: (any Error).self) {
    try rig.controller(carrier: rig.forward(granted: false)).ensureSession(
      rig.instance, target: rig.guest.target)
  }
  #expect("\(ungranted)".contains("inference-gateway grant"))
  #expect(!rig.gateway.ops.contains("register_session"))
  #expect(rig.guest.log("tunnels.log").isEmpty)

  try rig.guest.flag("forward-fails")
  #expect(throws: (any Error).self) {
    try rig.controller(carrier: rig.forward()).ensureSession(
      rig.instance, target: rig.guest.target)
  }
  #expect(!rig.gateway.ops.contains("activate_session"))
  #expect(rig.gateway.state.withLock { $0.sessions.isEmpty })
  #expect(forwardMaster(rig) == nil)
  unlink(rig.guest.root + "/flags/forward-fails")

  rig.gateway.state.withLock {
    $0.override["activate_session"] = ["ok": false, "code": "POLICY_DENIED", "message": "no"]
  }
  #expect(throws: (any Error).self) {
    try rig.controller(carrier: rig.forward()).ensureSession(
      rig.instance, target: rig.guest.target)
  }
  let master = activationTransport(rig).pid.map { Int32($0) }
  #expect(master != nil)
  #expect(waitUntil { master.map { !isRunning($0) } ?? false }, "a refused activation's forward")
  #expect(forwardMaster(rig) == nil)
  #expect(!exists(InferenceController.statePath(rig.instance)))
  #expect(!exists(InferenceController.legacyTokenPath(rig.instance)))
}

/// ssh splits `-R` on `:`, and a Unix socket path must fit sun_path: any
/// other session socket is refused before a forward is requested.
@Test func theForwardRefusesASocketSSHCannotCarry() throws {
  let rig = try Rig()
  defer { rig.remove() }
  for socket in [
    "relative.sock", rig.relay + "/a:b.sock", rig.relay + "/a b.sock",
    "/" + String(repeating: "a", count: 104),
  ] {
    #expect(throws: HostError.self) {
      try rig.guest.proxies().startInferenceForward(
        rig.instance, target: rig.guest.target, socket: socket)
    }
  }
  #expect(rig.guest.log("tunnels.log").isEmpty)
}

/// The forward always runs the system `ssh` the gateway binds (§22.9), in
/// debug builds too: never the first `ssh` on `PATH`. Only a unit test's
/// double replaces it.
@Test func theForwardRunsTheSystemSSHNeverOneFromPATH() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let decoy = rig.guest.root + "/decoy"
  try writeFile(
    decoy + "/ssh", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(decoy)/calls.log\"\nexit 1\n",
    mode: 0o755)
  var environment = rig.guest.environment
  environment["PATH"] = decoy + ":" + (environment["PATH"] ?? "")
  let resolver = CredentialResolver(environment: environment)
  // As every command builds it: the system ssh, whatever PATH says.
  let shipped = ProxyLauncher(
    environment: environment, resolver: resolver, diagnostics: rig.guest.sink.diagnostics,
    isoExecutable: nil)
  #expect(shipped.inferenceSSH == "/usr/bin/ssh")
  let defaulted = ProxyLauncher(
    environment: environment, resolver: resolver, diagnostics: rig.guest.sink.diagnostics,
    isoExecutable: nil, sandboxExec: "/usr/bin/false", controlRoot: rig.guest.root)
  #expect(defaulted.inferenceSSH == "/usr/bin/ssh")
  // The forward runs the configured client, not the PATH decoy.
  let launcher = ProxyLauncher(
    environment: environment, resolver: resolver, diagnostics: rig.guest.sink.diagnostics,
    isoExecutable: nil, sandboxExec: "/usr/bin/false", controlRoot: rig.guest.root,
    inferenceSSH: rig.guest.root + "/bin/ssh")
  let forward = try launcher.startInferenceForward(
    rig.instance, target: rig.guest.target, socket: rig.relay + "/8e84.sock")
  defer { kill(forward.pid, SIGKILL) }
  #expect(readFile(decoy + "/calls.log") == nil)
  #expect(rig.guest.log("tunnels.log").filter { $0.hasPrefix("forward ") }.count == 1)
}

/// Whether `condition` holds within five seconds.
private func waitUntil(_ condition: () -> Bool) -> Bool {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    usleep(20_000)
  }
  return condition()
}

/// The guest end differs by transport, its URL does not: a vmnet session
/// installs the systemd bridge to the relayed socket, a brokered one
/// installs nothing (the forward's sshd listener is the only one on 11788).
/// Claude is pointed at http://127.0.0.1:11788 either way.
@Test func onlyTheVmnetRelayInstallsAGuestBridge() throws {
  for brokered in [false, true] {
    let rig = try Rig()
    defer { rig.remove() }
    let agents = AgentBootstrap(
      config: try rig.config, client: rig.guest.client, environment: rig.guest.environment,
      home: rig.guest.root + "/hosthome",
      resolver: CredentialResolver(environment: rig.guest.environment),
      proxies: rig.guest.proxies(), github: NoGitHub(), diagnostics: rig.guest.sink.diagnostics,
      inference: try rig.controller(carrier: brokered ? rig.forward() : nil))
    let result = try #require(try agents.inferenceSession(rig.instance, target: rig.guest.target))
    defer { if let pid = forwardMaster(rig) { kill(pid, SIGKILL) } }
    #expect(result.session.transport == (brokered ? .forward : .owner))
    #expect(result.session.guestBaseURL == "http://127.0.0.1:11788")
    let bridged = (readFile(rig.guest.root + "/sudo-stdin") ?? "").contains("iso-inference.socket")
    #expect(bridged == !brokered, "brokered \(brokered)")
    let settings = rig.guest.guestFile(".claude/settings.json") ?? ""
    #expect(settings.contains("http://127.0.0.1:11788"), "\(settings)")
    // The capability is in the guest's token file, read by Claude's key
    // helper, and in no settings file.
    let token = rig.guest.guestFile(GuestHomeFile.inferenceToken.rawValue) ?? ""
    #expect(token.count == 64, "\(token)")
    #expect(settings.contains(#""apiKeyHelper":"#) && !settings.contains(token))
    #expect(!settings.contains("ANTHROPIC_AUTH_TOKEN"))
  }
}

/// Every SSH session gets the capability from the guest's token file, never
/// from the host: Codex's provider key and an attach grant's token are
/// guest-file variables, and only the grant's URL and model are sent.
@Test func sshSessionsReadTheCapabilityInTheGuest() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let responses = try TCPListener(address: "127.0.0.1")
  defer { responses.close() }
  rig.gateway.state.withLock { $0.ports.append(Int(responses.port)) }
  let config = try testConfig(
    #"""
    "inference": {
      "mode": "required",
      "qualification_profiles": {
        "p": {"protocol": "anthropic-messages", "completion_evidence": "drain",
          "context_overflow": "reject", "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
          "max_input_bytes": 1024},
        "r": {"protocol": "openai-responses", "completion_evidence": "drain",
          "context_overflow": "reject", "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
          "max_input_bytes": 1024}},
      "backends": {
        "b": {"isolation": "unverified", "base_url": "http://127.0.0.1:\#(rig.backends[0].port)",
          "protocol": "anthropic-messages", "qualification_profile": "p"},
        "c": {"isolation": "unverified", "base_url": "http://127.0.0.1:\#(responses.port)",
          "protocol": "openai-responses", "qualification_profile": "r"}},
      "services": {
        "s": {"backend": "b", "upstream_model": "m", "frontend_apis": ["anthropic-messages"],
          "max_context_tokens": 1000},
        "x": {"backend": "c", "upstream_model": "m", "frontend_apis": ["openai-responses"],
          "max_context_tokens": 1000}}
    },
    "claude": {"local_model": {"service": "s"}},
    "codex": {"local_model": {"service": "x"}}
    """#)
  try InferenceAttachGrant(service: try InferenceServiceName("s"), api: .anthropicMessages)
    .save(rig.instance)
  let agents = AgentBootstrap(
    config: config, client: rig.guest.client, environment: rig.guest.environment,
    home: rig.guest.root + "/hosthome",
    resolver: CredentialResolver(environment: rig.guest.environment),
    proxies: rig.guest.proxies(), github: NoGitHub(), diagnostics: rig.guest.sink.diagnostics,
    inference: try rig.controller(config))
  var env = EnvForward()
  try agents.inferenceEnvironment(rig.instance, target: rig.guest.target, into: &env)
  let fromGuest = env.guestFiles.map(\.name).sorted()
  #expect(
    fromGuest == [AgentBootstrap.attachVariables.token, ModelRouting.codexLocalEnvKey].sorted())
  #expect(env.guestFiles.allSatisfy { $0.file == .inferenceToken })
  #expect(
    env.names.sorted()
      == [AgentBootstrap.attachVariables.baseURL, AgentBootstrap.attachVariables.model].sorted())
  let token = try #require(rig.guest.guestFile(GuestHomeFile.inferenceToken.rawValue))
  let prepared = try env.prepare("true", terminal: .requested)
  #expect(!prepared.remote.contains(token))
  #expect(!prepared.environment([:]).values.contains(token))
}

/// The worker launches a rig's controller made.
private final class Launches: Sendable {
  private let recorded = Mutex<[WorkerLaunch]>([])
  func record(_ launch: WorkerLaunch) { recorded.withLock { $0.append(launch) } }
  var all: [WorkerLaunch] { recorded.withLock { $0 } }
}

/// Each new session gets its own worker (§5.1): started after the nonce is
/// confirmed and before activation, for that session's socket, with the key
/// the gateway returned on stdin and only the session's backend ports.
@Test func eachSessionStartsItsOwnWorker() throws {
  let rig = try Rig()
  defer { rig.remove() }
  // A second backend no service of this session uses: its port is not the
  // worker's to reach.
  let config = try testConfig(
    #"""
    "inference": {
      "mode": "required",
      "qualification_profiles": {"p": {"protocol": "anthropic-messages",
        "completion_evidence": "drain", "context_overflow": "reject",
        "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
        "max_input_bytes": 1024}},
      "backends": {
        "b": {"isolation": "unverified", "base_url": "http://127.0.0.1:\#(rig.backends[0].port)",
          "protocol": "anthropic-messages", "qualification_profile": "p"},
        "unused": {"isolation": "unverified", "base_url": "http://127.0.0.1:1999",
          "protocol": "anthropic-messages", "qualification_profile": "p"}},
      "services": {"s": {"backend": "b", "upstream_model": "m",
        "frontend_apis": ["anthropic-messages"], "max_context_tokens": 1000}}
    },
    "claude": {"local_model": {"service": "s"}}
    """#)
  rig.gateway.state.withLock { $0.ports.append(1999) }
  // The relay directory through a symlink, as `/var` is to `/private/var`.
  let linked = rig.guest.root + "/rl-link"
  try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: rig.relay)
  var launchedBeforeActivation = false
  let result = try #require(
    try rig.controller(config, relayDirectory: linked).ensureSession(
      rig.instance, target: rig.guest.target
    ) { _, _ in
      launchedBeforeActivation =
        rig.launches.all.count == 1 && !rig.gateway.ops.contains("activate_session")
    })
  #expect(launchedBeforeActivation)
  let launch = try #require(rig.launches.all.first)
  #expect(rig.launches.all.count == 1)
  #expect(launch.sessionID == result.session.sessionID)
  // Resolved: the worker's profile names the path Seatbelt matches.
  #expect(launch.socketPath == InferenceController.realPath(rig.relay) + "/8e84.sock")
  #expect(launch.socketPath != linked + "/8e84.sock")
  #expect(launch.key.expose() == String(repeating: "d", count: 63) + "1")
  #expect(launch.backendPorts == [rig.backends[0].port])
  let argv = launch.sandboxArguments(binary: "/opt/iso-inference", broker: "/st/workers.sock")
  #expect(argv.contains("SESSION_SOCKET=\(launch.socketPath)"))
  #expect(argv.contains("BROKER_SOCKET=/st/workers.sock"))
  #expect(!argv.joined(separator: " ").contains(launch.key.expose()), "the key goes on stdin")
  let profile = try #require(argv.first { $0.contains("(deny default)") })
  #expect(profile.contains("localhost:\(rig.backends[0].port)"))
  #expect(!profile.contains("localhost:1999"))
  // A recorded session is reused: no second worker.
  _ = try rig.controller(config, relayDirectory: linked).ensureSession(
    rig.instance, target: rig.guest.target)
  #expect(rig.launches.all.count == 1)
}

/// A gateway that names no worker is refused, and the partial session revoked.
@Test func aRegistrationWithoutAWorkerKeyFailsClosed() throws {
  let rig = try Rig()
  defer { rig.remove() }
  rig.gateway.state.withLock { $0.workerKeys = false }
  #expect(throws: (any Error).self) {
    try rig.controller().ensureSession(rig.instance, target: rig.guest.target)
  }
  #expect(rig.gateway.ops.contains("register_session"), "the registration itself succeeded")
  #expect(rig.launches.all.isEmpty)
  #expect(!rig.gateway.ops.contains("activate_session"))
}
