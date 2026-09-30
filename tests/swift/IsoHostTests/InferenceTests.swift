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
    boot: { _ in InferenceBoot(ownerPID: getpid(), deadline: nil) },
    sandboxExec: "/usr/bin/sandbox-exec", stateDirectory: state)
}

private let session = InferenceSession(
  sessionID: "s", epoch: "e", guestPort: 10790, token: Secret(String(repeating: "c", count: 64)),
  services: [])

@Test func inferenceSeatbeltProfileMatchesItsCanonicalFile() throws {
  let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../../Sources/IsoHost/seatbelt-inference.sb").standardized.path
  #expect(SeatbeltProfile.inferenceTemplate == (try #require(readFile(path))))
  let profile = SeatbeltProfile.inference(backendPorts: [18081, 18080])
  #expect(profile.contains("(deny default)"))
  #expect(profile.contains(#"(allow process-exec* (literal (param "INFERENCE_BIN")))"#))
  #expect(profile.contains(#"(allow file-write* (subpath (param "STATE_DIR")))"#))
  // Reads are narrowed; no blanket file-read*.
  #expect(!profile.contains("(allow file-read*)\n"))
  // Outbound only to the listed backend ports; no 443/53, no wildcard port.
  #expect(profile.contains(#"(allow network-outbound (remote ip "localhost:18080"))"#))
  #expect(profile.contains(#"(allow network-outbound (remote ip "localhost:18081"))"#))
  #expect(!profile.contains(#"(remote ip "localhost:*")"#))
  #expect(!profile.contains("*:443") && !profile.contains("*:53"))
  #expect(!SeatbeltProfile.inference(backendPorts: []).contains("network-outbound"))
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
  #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:10790")
  #expect(env["ANTHROPIC_AUTH_TOKEN"] == session.token.expose())
  #expect(env["ANTHROPIC_MODEL"] == "local-claude")
  #expect(env["ANTHROPIC_SMALL_FAST_MODEL"] == "local-claude")
  #expect(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] == "65536")
  let table = try #require(agents.codexInferenceTable(session))
  let rendered = table.document
  #expect(rendered.contains(#"base_url = "http://127.0.0.1:10790/v1""#))
  #expect(rendered.contains(#"model = "local-codex""#))
  #expect(rendered.contains(#"wire_api = "responses""#))
  #expect(!rendered.contains(session.token.expose()))
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
      "backends": {"b": {"base_url": "http://127.0.0.1:18080", "protocol": "anthropic-messages",
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
  #expect(InferenceController.guestPort(instance) == 10790)
  let services = try control.requestedServices(instance)
  #expect(services.map(\.rawValue) == ["local-claude", "local-codex"])
  let message = try control.registrationMessage(
    instance, resolved: services.map(control.resolved), boot: (1, "1.0"),
    nonce: String(repeating: "0", count: 32))
  let rendered = OutputJSON.object(message).rendered()
  #expect(rendered.contains(#""credential": "backend-secret""#))
  #expect(rendered.contains(#""upstream_model": "mlx/claude-ish""#))
  #expect(rendered.contains(#""completion_evidence": "drain""#))
  let fingerprint = try control.registrationFingerprint(services)
  // The fingerprint never covers credentials, and tracks policy changes.
  let changed = try guardedConfig(evidence: "stream-close")
  #expect(
    try controller(changed, guest: guest, state: guest.root + "/i2").registrationFingerprint(
      services) != fingerprint)
  #expect(!fingerprint.contains("backend-secret"))
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
  // A wildcard bind is reachable on the host's other addresses.
  guard !Socket.nonLoopbackAddresses().filter({ !$0.contains(":") }).isEmpty else { return }
  let wildcard = try TCPListener(address: "0.0.0.0")
  defer { wildcard.close() }
  let error = try #require(throws: HostError.self) {
    try InferenceController.checkBackend(port: wildcard.port)
  }
  #expect(error.message.contains("INFERENCE_BACKEND_UNSAFE_BIND"))
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

@Test func rememberedSessionsNeedTheSameForwardProcess() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let memo = SessionMemo()
  let start = try #require(HostProcess.start(getpid()))
  memo.remember(
    instance, .init(fingerprint: "f", session: session, forwardPID: getpid(), forwardStart: start))
  #expect(memo.session(instance, fingerprint: "f") == session)
  #expect(memo.session(instance, fingerprint: "other") == nil, "changed grants re-register")
  // Claude's settings are written once per session per command.
  #expect(memo.markClaudeSettings(instance, session: session))
  #expect(!memo.markClaudeSettings(instance, session: session))
  // A forward with another start time (a reused PID) is not the one remembered.
  memo.remember(
    instance, .init(fingerprint: "f", session: session, forwardPID: getpid(), forwardStart: "0.0"))
  #expect(memo.session(instance, fingerprint: "f") == nil)
  memo.forget(instance)
  #expect(memo.session(instance, fingerprint: "f") == nil)
}
