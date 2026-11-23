import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private func guardedConfig(_ extra: String = "", evidence: String = "drain") throws -> IsoConfig {
  try testConfig(
    #"""
    "inference": {
      "mode": "required",
      "qualification_profiles": {
        "reviewed": {
          "protocol": "anthropic-messages", "completion_evidence": "\#(evidence)",
          "context_overflow": "reject",
          "input_overhead": {"per_request_bytes": 512, "per_message_bytes": 16},
          "max_input_bytes": 1048576
        },
        "reviewed-responses": {
          "protocol": "openai-responses", "completion_evidence": "drain",
          "context_overflow": "truncate",
          "input_overhead": {"per_request_bytes": 512, "per_message_bytes": 16},
          "max_input_bytes": 1048576
        }
      },
      "backends": {
        "mlx": {
          "base_url": "http://127.0.0.1:18080", "protocol": "anthropic-messages",
          "qualification_profile": "reviewed", "credential": "cmd:printf backend-secret"
        },
        "mlx-responses": {
          "base_url": "http://127.0.0.1:18081", "protocol": "openai-responses",
          "qualification_profile": "reviewed-responses"
        }
      },
      "services": {
        "local-claude": {
          "backend": "mlx", "upstream_model": "mlx/claude-ish", "frontend_apis": ["anthropic-messages"],
          "max_context_tokens": 65536
        },
        "local-codex": {
          "backend": "mlx-responses", "upstream_model": "mlx/codex-ish",
          "frontend_apis": ["openai-responses"], "max_context_tokens": 131072
        }
      }
    },
    "claude": {"local_model": {"service": "local-claude"}, "api_key": "sk-ant"},
    "codex": {"local_model": {"service": "local-codex"}}
    \#(extra)
    """#)
}

private func controller(_ config: IsoConfig, guest: FakeGuest, state: String) -> InferenceController
{
  let resolver = CredentialResolver(environment: guest.environment)
  return InferenceController(
    config: config, environment: guest.environment, resolver: resolver,
    diagnostics: guest.sink.diagnostics, isoExecutable: nil, proxies: guest.proxies(resolver),
    boot: { _ in
      InferenceBoot(ownerPID: getpid(), deadline: nil, relaySocket: state + "-relay/8e84.sock")
    },
    sandboxExec: "/usr/bin/sandbox-exec", stateDirectory: state, relayDirectory: state + "-relay")
}

private let session = InferenceSession(sessionID: "s", epoch: "e", services: [])

@Test func inferenceSeatbeltProfileMatchesItsCanonicalFile() throws {
  let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../Sources/IsoHost/Inference/Resources/seatbelt-inference.sb")
    .standardized.path
  let profile = SeatbeltProfile.inference
  #expect(profile == (try #require(readFile(path))))
  #expect(profile.contains("(deny default)"))
  #expect(profile.contains(#"(allow process-exec* (literal (param "INFERENCE_BIN")))"#))
  #expect(profile.contains(#"(allow file-write* (subpath (param "STATE_DIR")))"#))
  // Reads are narrowed; no blanket file-read*.
  #expect(!profile.contains("(allow file-read*)\n"))
  // The broker reaches no backend and binds no session socket (§5.1): no
  // outbound rule, no port marker and nothing in the relay directory.
  #expect(!profile.contains("network-outbound"))
  #expect(!profile.contains(SeatbeltProfile.backendPortsMarker))
  #expect(!profile.contains("RELAY_DIR"))
  #expect(profile.contains("(deny process-info*)"))
  // A session worker reaches only its grants' backend ports and the broker.
  let worker = SeatbeltProfile.inferenceWorker(backendPorts: [18081, 18080, 18080])
  #expect(worker.contains(#"(allow network-outbound (remote ip "localhost:18080"))"#))
  #expect(worker.contains(#"(allow network-outbound (remote ip "localhost:18081"))"#))
  #expect(worker.components(separatedBy: "localhost:18080").count == 2, "one rule per port")
  #expect(worker.contains(#"(remote unix-socket (literal (param "BROKER_SOCKET")))"#))
  #expect(worker.contains(#"(allow file-write* (literal (param "SESSION_SOCKET")))"#))
  #expect(!worker.contains(#"(remote ip "localhost:*")"#))
  #expect(!worker.contains("*:443") && !worker.contains("*:53"))
  #expect(worker.contains("(deny process-info*)"))
  #expect(!SeatbeltProfile.inferenceWorker(backendPorts: []).contains("remote ip"))
}

@Test func requiredModeWithholdsEveryProviderCredential() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let config = try guardedConfig()
  let agents = guest.bootstrap(config)
  let env = try agents.prepareEnvForwarding(
    repo: nil, suppressAnthropicKey: false, suppressOpenAIKey: false)
  #expect(!env.contains("ANTHROPIC_API_KEY") && !env.contains("OPENAI_API_KEY"))
  // Explicit declarations fail rather than being silently dropped.
  for extra in [
    #", "guest_env": {"OPENAI_API_KEY": "x"}"#,
    #", "guest_env": {"ANTHROPIC_AUTH_TOKEN": "x"}"#,
  ] {
    let declaring = try guardedConfig(extra)
    #expect(throws: HostError.self) {
      try guest.bootstrap(declaring).prepareEnvForwarding(
        repo: nil, suppressAnthropicKey: false, suppressOpenAIKey: false)
    }
  }
}

@Test func requiredModeNeedsNoProviderProxyAndStartsNone() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let config = try guardedConfig(#", "egress": "none""#)
  let instance = try testInstance(guest.root + "/instance")
  let agents = guest.bootstrap(config)
  try agents.requireProviderProxy(instance, noAgents: false, guestEnvironment: [:])
  var state = ModelState()
  state.mode = .local
  state.claudeEndpoint = try LocalModel(
    hostURL: "http://localhost:9999", model: "m", authToken: nil)
  // A saved raw endpoint never becomes a tunnel under `required`.
  #expect(try LocalEndpoints.tunnels(state, config: config).isEmpty)
  #expect(!(try agents.proxyConfigured(instance, .anthropic)))
}

@Test func agentConfigurationPointsAtTheGatewaySession() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let agents = guest.bootstrap(try guardedConfig())
  let env = agents.claudeInferenceEnv(session)
  #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:11788")
  // The capability comes from the key helper reading the guest's file.
  #expect(env["ANTHROPIC_AUTH_TOKEN"] == nil)
  #expect(agents.claudeKeyHelper(session) == ClaudeSettings.inferenceKeyHelper)
  #expect(ClaudeSettings.inferenceKeyHelper.contains(GuestHomeFile.inferenceToken.rawValue))
  #expect(env["ANTHROPIC_MODEL"] == "local-claude")
  #expect(env["ANTHROPIC_SMALL_FAST_MODEL"] == "local-claude")
  #expect(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] == "65536")
  let table = agents.codexInferenceTable(session)
  let rendered = table.document
  #expect(rendered.contains(#"base_url = "http://127.0.0.1:11788/v1""#))
  #expect(rendered.contains(#"model = "local-codex""#))
  #expect(rendered.contains(#"wire_api = "responses""#))
  #expect(rendered.contains(#"env_key = ""# + ModelRouting.codexLocalEnvKey + #"""#))
}

/// The key helper is iso's to set and to remove: removed only where it is
/// still iso's, so a stale helper never sends the capability once the mode
/// changes, and a guest's own helper is left alone.
@Test func claudeKeyHelperIsManagedOnlyWhereItIsIsos() throws {
  let mine = ClaudeSettings.inferenceKeyHelper
  let set = try ClaudeSettings.merge("{}", localEnv: [:], keyHelper: mine)
  #expect(set.contains(#""apiKeyHelper""#))
  let cleared = try ClaudeSettings.merge(set, localEnv: [:], keyHelper: nil)
  #expect(!cleared.contains("apiKeyHelper"))
  let theirs = try ClaudeSettings.merge(#"{"apiKeyHelper":"my-helper"}"#, localEnv: [:])
  #expect(theirs.contains("my-helper"))
  #expect(ClaudeSettings.managedDefaults([:], keyHelper: mine).contains(#""apiKeyHelper""#))
}

/// A guest-file variable is read in the guest from a fixed path: the host
/// sends no value and no `SendEnv` for it.
@Test func guestFileVariablesAreReadInTheGuest() throws {
  var env = EnvForward()
  env.set("PLAIN", Secret("value"))
  env.setFromGuestFile(ModelRouting.codexLocalEnvKey, .inferenceToken)
  let prepared = try env.prepare("true", terminal: .requested)
  #expect(prepared.remote.contains(GuestHomeFile.inferenceToken.rawValue))
  #expect(prepared.remote.contains("export \(ModelRouting.codexLocalEnvKey)="))
  #expect(prepared.options == ["-o", "SendEnv=\(EnvForward.aliasPrefix)0"])
  #expect(env.contains(ModelRouting.codexLocalEnvKey))
  #expect(!"\(env)".contains("value"))
  // Only guest-file variables: a wrapper with no alias check.
  var only = EnvForward()
  only.setFromGuestFile("ISO_INFERENCE_TOKEN", .inferenceToken)
  let alone = try only.prepare("true", terminal: .requested)
  #expect(alone.options.isEmpty && alone.remote.contains("ISO_INFERENCE_TOKEN"))
  #expect(!alone.remote.contains("did not arrive"))
  // Setting a literal replaces a guest-file variable of the same name.
  only.set("ISO_INFERENCE_TOKEN", Secret("x"))
  #expect(only.guestFiles.isEmpty)
}

@Test func launchingAnAgentWithoutAServiceIsRefused() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let claudeOnly = try testConfig(
    #"""
    "inference": {
      "mode": "required",
      "qualification_profiles": {"p": {"protocol": "anthropic-messages", "completion_evidence": "drain",
        "context_overflow": "reject", "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
        "max_input_bytes": 1024}},
      "backends": {"b": {"isolation": "unverified", "base_url": "http://127.0.0.1:18080", "protocol": "anthropic-messages",
        "qualification_profile": "p"}},
      "services": {"s": {"backend": "b", "upstream_model": "m", "frontend_apis": ["anthropic-messages"],
        "max_context_tokens": 1000}}
    },
    "claude": {"local_model": {"service": "s"}}
    """#)
  let agents = guest.bootstrap(claudeOnly)
  try agents.requireInferenceService(forClaude: true)
  #expect(throws: HostError.self) { try agents.requireInferenceService(forClaude: false) }
  try guest.bootstrap(try testConfig()).requireInferenceService(forClaude: false)
}

@Test func registrationCarriesResolvedPolicyAndAStableFingerprint() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let config = try guardedConfig()
  let instance = try testInstance(guest.root + "/instance", index: 2)
  let control = controller(config, guest: guest, state: guest.root + "/inference")
  #expect(InferenceController.guestPort == 11788)
  let services = try control.requestedServices(instance)
  #expect(services.map(\.rawValue) == ["local-claude", "local-codex"])
  let message = try control.registrationMessage(
    instance, resolved: services.map(control.resolved), boot: (1, "1.0"),
    nonce: String(repeating: "0", count: 32), socket: "8e84.sock", transport: .owner)
  let rendered = OutputJSON.object(message).compactRendered()
  #expect(rendered.contains(#""socket":"8e84.sock""#))
  #expect(rendered.contains(#""transport":"owner""#))
  #expect(rendered.contains(#""credential":"backend-secret""#))
  #expect(rendered.contains(#""upstream_model":"mlx/claude-ish""#))
  #expect(rendered.contains(#""completion_evidence":"drain""#))
  #expect(rendered.contains(#""front":"plain""#))
  #expect(!rendered.contains(#""front":"launcher""#))
  let fingerprint = try control.registrationFingerprint(services)
  // The fingerprint never covers credentials, and tracks policy changes.
  let changed = try guardedConfig(evidence: "stream-close")
  #expect(
    try controller(changed, guest: guest, state: guest.root + "/i2").registrationFingerprint(
      services) != fingerprint)
  #expect(!fingerprint.contains("backend-secret"))
}

/// A managed backend is iso's launcher: the gateway challenges each
/// connection to it and names the session's cache partition (spec §20.3).
@Test func aManagedBackendIsALauncherFrontEnd() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let config = try testConfig(
    #"""
    "inference": {
      "mode": "required",
      "qualification_profiles": {"p": {"protocol": "openai-chat", "completion_evidence": "drain",
        "context_overflow": "reject", "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
        "max_input_bytes": 1024}},
      "backends": {"m": {"base_url": "http://127.0.0.1:18080", "protocol": "openai-chat",
        "qualification_profile": "p",
        "managed": {"server": "mlx-lm", "python": "/opt/py/bin/python3", "model": "/models/m"}}},
      "services": {"s": {"backend": "m", "upstream_model": "default_model",
        "frontend_apis": ["openai-chat"], "max_context_tokens": 1000}}
    }
    """#)
  let control = controller(config, guest: guest, state: guest.root + "/inference")
  let grant = control.grant(
    try control.resolved(try InferenceServiceName("s")), credential: "token")
  let rendered = grant.compactRendered()
  #expect(rendered.contains(#""front":"launcher""#))
  #expect(rendered.contains(#""credential":"token""#))
}

@Test func attachGrantRoundTrips() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  #expect(try InferenceAttachGrant.load(instance) == nil)
  let grant = InferenceAttachGrant(
    service: try InferenceServiceName("local-claude"), api: .anthropicMessages)
  try grant.save(instance)
  #expect(try InferenceAttachGrant.load(instance) == grant)
  var info = stat()
  #expect(stat(InferenceAttachGrant.path(instance), &info) == 0 && info.st_mode & 0o077 == 0)
  try writeFile(InferenceAttachGrant.path(instance), #"{"service": "x", "api": "exec"}"#)
  #expect(throws: (any Error).self) { try InferenceAttachGrant.load(instance) }
}

@Test func backendBindingChecks() throws {
  let loopback = try TCPListener(address: "127.0.0.1")
  try InferenceController.checkBackend(port: loopback.port)
  #expect(InferenceController.exposedAddresses(port: loopback.port).isEmpty)
  let closed = loopback.port
  loopback.close()
  #expect(throws: HostError.self) { try InferenceController.checkBackend(port: closed) }
  // A wildcard bind answers on every address the probe is given, whatever
  // interfaces this Mac has: here 127.0.0.1 stands in for a LAN address.
  let wildcard = try TCPListener(address: "0.0.0.0")
  defer { wildcard.close() }
  let exposed = InferenceController.exposedAddresses(
    port: wildcard.port, addresses: ["127.0.0.1"])
  #expect(exposed == ["127.0.0.1"])
  let error = try #require(throws: HostError.self) {
    try InferenceController.requireSafeBinding(
      port: wildcard.port, reachable: true, exposedAddresses: exposed)
  }
  #expect(error.message.contains("INFERENCE_BACKEND_UNSAFE_BIND"))
  // A loopback-only listener answers on none of them.
  let only = try TCPListener(address: "127.0.0.1")
  defer { only.close() }
  #expect(
    InferenceController.exposedAddresses(port: only.port, addresses: ["192.0.2.1"]).isEmpty)
}

@Test func controlErrorsCarryTheGatewayCode() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let path = guest.root + "/c.sock"
  let server = try UnixReplyServer(
    path: path, reply: #"{"version":1,"ok":false,"code":"INFERENCE_POLICY_DENIED","message":"no"}"#)
  defer { server.stop() }
  let reply = try ControlSocket.exchange(
    path, Array("{}".utf8), timeoutSeconds: 5, verify: { _ in })
  #expect(String(decoding: reply, as: UTF8.self).contains("INFERENCE_POLICY_DENIED"))
  let peer = try ControlSocket.peer(path)
  #expect(peer.uid == getuid() && peer.pid == getpid())
  // A peer that fails verification is refused before the request is sent.
  #expect(throws: HostError.self) {
    _ = try ControlSocket.exchange(
      path, Array("{}".utf8), timeoutSeconds: 5,
      verify: { _ in throw HostError("wrong peer") })
  }
}

/// A loopback (or wildcard) TCP listener that accepts and closes.
final class TCPListener: @unchecked Sendable {
  let fd: Int32
  let port: UInt16

  init(address: String) throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var one: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr = in_addr(s_addr: inet_addr(address))
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(listener, 8) == 0 else { throw HostError("bind failed") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    fd = listener
    port = UInt16(bigEndian: addr.sin_port)
  }

  func close() { Darwin.close(fd) }
}

/// Serves one fixed control reply per connection.
final class UnixReplyServer: @unchecked Sendable {
  let fd: Int32
  let path: String

  init(path: String, reply: String) throws {
    self.path = path
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
    guard bound == 0, listen(fd, 4) == 0 else { throw HostError("bind failed") }
    let listener = fd
    let body = Array(reply.utf8)
    Thread {
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0 else { return }
        var one: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var header = [UInt8](repeating: 0, count: 4)
        _ = recv(connection, &header, 4, MSG_WAITALL)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        var request = [UInt8](repeating: 0, count: max(length, 1))
        _ = recv(connection, &request, length, MSG_WAITALL)
        let size = UInt32(body.count)
        let frame =
          [
            UInt8(size >> 24), UInt8((size >> 16) & 0xFF), UInt8((size >> 8) & 0xFF),
            UInt8(size & 0xFF),
          ]
          + body
        _ = frame.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        Darwin.close(connection)
      }
    }.start()
  }

  func stop() {
    shutdown(fd, SHUT_RDWR)
    Darwin.close(fd)
    unlink(path)
  }
}

@Test func rememberedSessionsNeedTheSameOwnerProcess() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let memo = SessionMemo()
  let start = try #require(HostProcess.start(getpid()))
  let owner = BoundProcess(pid: getpid(), start: start)
  memo.remember(instance, .init(fingerprint: "f", session: session, bound: [owner]))
  #expect(memo.session(instance, fingerprint: "f") == session)
  #expect(memo.session(instance, fingerprint: "other") == nil, "changed grants re-register")
  // Claude's settings are written once per session per command.
  #expect(memo.markClaudeSettings(instance, session: session))
  #expect(!memo.markClaudeSettings(instance, session: session))
  // An owner with another start time (a reused PID) is not the one remembered.
  memo.remember(
    instance,
    .init(fingerprint: "f", session: session, bound: [BoundProcess(pid: getpid(), start: "0.0")]))
  #expect(memo.session(instance, fingerprint: "f") == nil)
  // A brokered session also needs its forward: a reused PID, or none at all,
  // is not the one remembered.
  memo.remember(
    instance,
    .init(
      fingerprint: "f", session: session,
      bound: [owner, BoundProcess(pid: getpid(), start: "0.0")]))
  #expect(memo.session(instance, fingerprint: "f") == nil)
  memo.remember(instance, .init(fingerprint: "f", session: session, bound: []))
  #expect(memo.session(instance, fingerprint: "f") == nil)
  memo.forget(instance)
  #expect(memo.session(instance, fingerprint: "f") == nil)
}

@Test func sessionsNeedTheGateVerifiedRelaySocket() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let control = controller(try guardedConfig(), guest: guest, state: guest.root + "/inference")
  let relay = guest.root + "/inference-relay"
  #expect(
    try control.relaySocketName(relay + "/8e84b04d471a546a.sock", instance: instance)
      == "8e84b04d471a546a.sock")
  // No relay (a sandbox booted before inference was required), another
  // directory, or a name the runtime never derives: no session.
  for bad in [
    nil, "/tmp/8e84.sock", relay + "/../8e84.sock", relay + "/8E84.sock", relay + "/x.sock",
    relay + "/8e84b04d471a546a0.sock",
  ] as [String?] {
    #expect(throws: HostError.self) { try control.relaySocketName(bad, instance: instance) }
  }
}

/// The checks the gateway leaves to the host (spec §12.3): the bound process
/// is this user's and runs the sandbox owner (`iso-sandbox`) or, for a
/// brokered forward, the system `ssh`. Its PID version is readable.
@Test func theCarrierIsTheSandboxOwnerOrTheSystemSSH() throws {
  let directory = try scratchDirectory("carrier")
  defer { try? FileManager.default.removeItem(atPath: directory) }
  // A copy of /bin/sleep is killed outside the system paths: build a
  // sleeper under the owner's name instead.
  let owner = directory + "/iso-sandbox"
  let compiler = Process()
  compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
  compiler.arguments = ["-x", "c", "-", "-o", owner]
  let source = Pipe()
  compiler.standardInput = source
  try compiler.run()
  source.fileHandleForWriting.write(
    Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8))
  try source.fileHandleForWriting.close()
  compiler.waitUntilExit()
  try #require(compiler.terminationStatus == 0)
  func spawn(_ path: String, _ arguments: [String]) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }
  // ssh waits on a silent ProxyCommand: no network is used.
  let processes = [
    try spawn(owner, []), try spawn("/bin/sleep", ["30"]),
    try spawn(
      "/usr/bin/ssh",
      ["-F", "none", "-o", "BatchMode=yes", "-o", "ProxyCommand=/bin/sleep 30", "carrier.invalid"]),
  ]
  defer { for process in processes { process.terminate() } }
  usleep(300_000)
  let bound = try processes.map { process in
    BoundProcess(
      pid: process.processIdentifier,
      start: try #require(HostProcess.start(process.processIdentifier)))
  }
  try InferenceController.checkCarrier(bound[0], .owner)
  try InferenceController.checkCarrier(bound[2], .forward)
  for (process, kind) in [
    (bound[0], InferenceTransportKind.forward), (bound[1], .owner), (bound[1], .forward),
    (bound[2], .owner),
  ] {
    #expect(throws: HostError.self) { try InferenceController.checkCarrier(process, kind) }
  }
  #expect(HostProcess.pidVersion(bound[0].pid) != nil)
  #expect(HostProcess.pidVersion(bound[0].pid) != HostProcess.pidVersion(bound[1].pid))
  // The version is the one the gateway sees in a connection's peer token:
  // here this process's, through a socket pair.
  var pair: [Int32] = [0, 0]
  try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
  defer { for fd in pair { close(fd) } }
  var token = audit_token_t()
  var length = socklen_t(MemoryLayout<audit_token_t>.size)
  try #require(getsockopt(pair[0], SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0)
  #expect(Int32(bitPattern: token.val.5) == getpid())
  #expect(HostProcess.pidVersion(getpid()) == token.val.7)
}
