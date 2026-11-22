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
    var version = 2
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
          "backends": {"b": {"base_url": "http://127.0.0.1:\#(backends[0].port)",
            "protocol": "anthropic-messages", "qualification_profile": "p"}},
          "services": {"s": {"backend": "b", "upstream_model": "m",
            "frontend_apis": ["anthropic-messages"], "max_context_tokens": 1000}}
        },
        "claude": {"local_model": {"service": "s"}}
        """#)
    }
  }

  func controller(_ config: IsoConfig? = nil) throws -> InferenceController {
    let resolver = CredentialResolver(environment: guest.environment)
    let relay = self.relay
    return InferenceController(
      config: try config ?? self.config, environment: guest.environment, resolver: resolver,
      diagnostics: guest.sink.diagnostics, isoExecutable: nil, proxies: guest.proxies(resolver),
      boot: { _ in
        InferenceBoot(ownerPID: getpid(), deadline: nil, relaySocket: relay + "/8e84.sock")
      },
      sandboxExec: "/usr/bin/false", stateDirectory: stateDirectory, relayDirectory: relay,
      peerCheck: { _ in })
  }

  func remove() {
    gateway.stop()
    for backend in backends { backend.close() }
    guest.remove()
  }
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

/// §12.2: register, check the nonce, configure the guest, and only then
/// activate and persist; the capability lands in the owner-only token file.
@Test func sessionsAreActivatedOnlyAfterTheGuestIsConfigured() throws {
  let rig = try Rig()
  defer { rig.remove() }
  let control = try rig.controller()
  var configuredBeforeActivation = false
  let result = try #require(
    try control.ensureSession(rig.instance, target: rig.guest.target) { session in
      #expect(session.token.expose().count == 64)
      configuredBeforeActivation = !rig.gateway.ops.contains("activate_session")
    })
  #expect(result.fresh)
  #expect(configuredBeforeActivation)
  let ops = rig.gateway.ops.filter { $0 != "inspect" }
  #expect(ops == ["revoke_session", "register_session", "activate_session"], "\(ops)")
  #expect(exists(InferenceController.statePath(rig.instance)))
  #expect(readFile(InferenceController.tokenPath(rig.instance)) == result.session.token.expose())
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
    try rig.controller().ensureSession(rig.instance, target: rig.guest.target) { _ in
      throw HostError("bridge install failed")
    }
  }
  #expect(!rig.gateway.ops.contains("activate_session"))
  #expect(rig.gateway.state.withLock { $0.sessions.isEmpty })
  #expect(!exists(InferenceController.statePath(rig.instance)))
  #expect(!exists(InferenceController.tokenPath(rig.instance)))
}

/// The registration must show up with its nonce, inactive, before anything
/// is activated.
@Test func aRegistrationWithoutItsNonceIsNotActivated() throws {
  let rig = try Rig()
  defer { rig.remove() }
  rig.gateway.state.withLock {
    $0.override["inspect"] = [
      "ok": true, "gateway": ["epoch": "epoch-1"],
      "sessions": [["session_id": "session-1", "nonce": "other", "state": "inactive"]],
    ]
  }
  #expect(throws: (any Error).self) {
    try rig.controller().ensureSession(rig.instance, target: rig.guest.target)
  }
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
    $0.version = 3
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
  let session = InferenceSession(
    sessionID: "s", epoch: "e", token: Secret(String(repeating: "c", count: 64)), services: [])
  #expect(AgentBootstrap.attachBaseURL(.anthropicCountTokens, session) == "http://127.0.0.1:11788")
  #expect(AgentBootstrap.attachBaseURL(.anthropicMessages, session) == "http://127.0.0.1:11788")
  #expect(AgentBootstrap.attachBaseURL(.openAIChat, session) == "http://127.0.0.1:11788/v1")
}
