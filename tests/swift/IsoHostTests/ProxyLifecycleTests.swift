import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

private let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../..").standardized

@Test func seatbeltProfileIsTheCheckedInFile() throws {
  let path = repositoryRoot.appending(path: "Sources/IsoHost/Guest/Resources/seatbelt-proxy.sb")
    .path
  let text = try #require(readFile(path))
  #expect(SeatbeltProfile.proxy == text)
  #expect(SeatbeltProfile.proxy.contains("(deny default)"))
  #expect(SeatbeltProfile.proxy.contains(#"(allow process-exec* (literal (param "PROXY_BIN")))"#))
  let egressPath = repositoryRoot.appending(
    path: "Sources/IsoHost/Guest/Resources/seatbelt-egress.sb"
  ).path
  #expect(SeatbeltProfile.egress == (try #require(readFile(egressPath))))
  #expect(SeatbeltProfile.egress.contains("(deny default)"))
}

/// Both companions read only system paths and their own binary, reach no
/// loopback IP service on any port (443 and 53 included), and no UNIX socket
/// but the resolver's.
@Test(arguments: [("PROXY_BIN", SeatbeltProfile.proxy), ("EGRESS_BIN", SeatbeltProfile.egress)])
func companionProfilesAreNarrow(binary: String, profile: String) throws {
  let rules = profile.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.hasPrefix(";;") }
  #expect(!rules.contains("(allow file-read*)"))
  #expect(!rules.contains { $0.hasPrefix("(allow file-read-metadata)") })
  #expect(rules.contains("(allow file-read*"))
  #expect(rules.contains("(literal (param \"\(binary)\"))"))
  #expect(
    !rules.contains {
      $0.contains("subpath \"/Users") || $0.contains("subpath \"/private/var/folders")
    })
  #expect(!rules.contains("(allow network-outbound (remote unix-socket))"))
  #expect(
    rules.contains(#"(allow network-outbound (path-literal "/private/var/run/mDNSResponder"))"#))
  let loopback = try #require(
    rules.firstIndex(of: #"(deny network-outbound (remote ip "localhost:*"))"#))
  // Seatbelt applies the last matching rule: the deny must follow every port allow.
  for port in [#"(remote tcp "*:443"))"#, #"(remote tcp "*:53"))"#, #"(remote udp "*:53"))"#] {
    let allow = try #require(rules.firstIndex(of: "(allow network-outbound " + port))
    #expect(allow < loopback, "\(port) is allowed after the loopback deny")
  }
}

@Test func proxyPortsArePerInstanceAndPerProvider() throws {
  let root = try scratchDirectory("ports")
  defer { try? FileManager.default.removeItem(atPath: root) }
  #expect(ProxyProvider.anthropic.port(try testInstance(root, index: 0)) == 8788)
  #expect(ProxyProvider.anthropic.port(try testInstance(root, index: 5)) == 8793)
  #expect(ProxyProvider.openai.port(try testInstance(root, index: 0)) == 9788)
  #expect(ProxyProvider.openai.port(try testInstance(root, index: 5)) == 9793)
  #expect(ProxyProvider.anthropic.basePort + InstanceIndex.maximum < ProxyProvider.openai.basePort)
}

@Test func startupDocumentsCarryTheCredentialOnlyInTheirBody() throws {
  let apiKey = ProxyLauncher.wireConfig(
    listen: "127.0.0.1:8788", capabilityToken: Secret("cap-tok"), provider: .anthropic,
    auth: .apiKey, credential: Secret("sk-real"))
  #expect(
    try canonicalJSON(String(decoding: apiKey.expose(), as: UTF8.self))
      == canonicalJSON(
        #"{"listen":"127.0.0.1:8788","capability_token":"cap-tok","version":1,"provider":"anthropic","injection":{"scheme":"x_api_key","credential":"sk-real"}}"#
      ))
  let bearer = ProxyLauncher.wireConfig(
    listen: "127.0.0.1:9788", capabilityToken: Secret("t"), provider: .openai, auth: .bearer,
    credential: Secret("sk-openai"))
  #expect(String(decoding: bearer.expose(), as: UTF8.self).contains(#""scheme":"bearer""#))
  #expect("\(apiKey)" == "<redacted>")
}

@Test func capabilityTokensAreReadTrimmedAndClearedWithTheProxy() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  #expect(ProxyLauncher.capabilityToken(instance, provider: .openai) == nil)
  for (content, expected) in [("", nil), ("  \n\t ", nil), ("  cap-123\n", "cap-123")] {
    try writeFile(ProxyLauncher.tokenPath(instance, "openai"), content)
    #expect(ProxyLauncher.capabilityToken(instance, provider: .openai)?.expose() == expected)
  }
  #expect(ProxyLauncher.capabilityToken(instance, provider: .anthropic) == nil)
  guest.proxies().stop(instance, provider: .openai)
  #expect(ProxyLauncher.capabilityToken(instance, provider: .openai) == nil)
}

@Test func stoppingEgressClearsCurrentAndLegacyBootPolicy() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let path = FilteredHandoff.policyPath(instance)
  try StateStore.writeControlFile(
    FilteredHandoff.BootPolicy(bootID: "boot", policyHash: "hash"), to: path)
  try writeFile(instance.directory + "/egress-boot-id", "legacy")
  try writeFile(instance.directory + "/egress-readiness-key", "legacy-signing-key")
  try writeFile(EgressPorts.capabilityPath(instance), "synthetic-capability")
  try TunnelIdentity(pid: 1, controlPath: "/tmp/iso-proxy-x/ssh.sock", address: "a")
    .save(instance, name: "egress")
  try AtomicFile.write(
    Array(String(repeating: "b", count: 64).utf8), to: FilteredReadiness.keyPath(instance),
    mode: .atMost(0o600))
  #expect(try FilteredHandoff.recordedPolicy(instance) != nil)
  let launcher = guest.proxies()
  launcher.stopEgress(instance)
  #expect(!FileManager.default.fileExists(atPath: path))
  #expect(!FileManager.default.fileExists(atPath: instance.directory + "/egress-boot-id"))
  #expect(!FileManager.default.fileExists(atPath: EgressPorts.capabilityPath(instance)))
  #expect(!FileManager.default.fileExists(atPath: FilteredReadiness.keyPath(instance)))
  #expect(!FileManager.default.fileExists(atPath: instance.directory + "/egress-readiness-key"))
  #expect(!FileManager.default.fileExists(atPath: TunnelIdentity.path(instance, "egress")))
  launcher.stopEgress(instance)
  #expect(try FilteredHandoff.recordedPolicy(instance) == nil)
}

@Test func modelTunnelRecordsAndIdentity() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  for name in [
    "proxy-model-11434-fwd.pid", "proxy-model-40443-fwd.pid", "proxy-anthropic-fwd.pid",
    "proxy-model-x-fwd.pid",
  ] {
    try writeFile(instance.directory + "/" + name, "0")
  }
  #expect(ProxyLauncher.recordedModelTunnels(instance).sorted() == [11434, 40443])
  let a = ReverseTunnel(guestPort: 8000, hostAddress: try IPv4Address("127.0.0.1"), hostPort: 8000)
  let b = ReverseTunnel(guestPort: 8000, hostAddress: try IPv4Address("127.0.0.2"), hostPort: 8000)
  #expect(
    ProxyLauncher.modelTunnelSpec(guest.target, a)
      == "ubuntu@10.231.1.2:22 iso-test.iso 8000:127.0.0.1:8000")
  #expect(
    ProxyLauncher.modelTunnelSpec(guest.target, a) != ProxyLauncher.modelTunnelSpec(guest.target, b)
  )
  let launcher = guest.proxies()
  try writeFile(
    ProxyLauncher.modelSpecPath(instance, 8000), ProxyLauncher.modelTunnelSpec(guest.target, a))
  #expect(
    !launcher.modelTunnelIsCurrent(
      instance, port: 8000, spec: ProxyLauncher.modelTunnelSpec(guest.target, a)))
  launcher.stopModelTunnels(instance)
  #expect(ProxyLauncher.recordedModelTunnels(instance).isEmpty)
  #expect(FileManager.default.fileExists(atPath: instance.directory + "/proxy-anthropic-fwd.pid"))

  #expect(ProxyLauncher.isSSHCommand("/usr/bin/ssh\n"))
  #expect(ProxyLauncher.isSSHCommand("ssh"))
  #expect(!ProxyLauncher.isSSHCommand("sshd"))
  // A reused PID that is not ssh is neither current nor signalled.
  try writeFile(ProxyLauncher.forwardPIDPath(instance, "model-8000"), String(getpid()))
  #expect(launcher.modelTunnelPID(instance, port: 8000) == nil)
  launcher.stopModelTunnel(instance, port: 8000)
  #expect(
    !FileManager.default.fileExists(atPath: ProxyLauncher.forwardPIDPath(instance, "model-8000")))
}

@Test func modelTunnelsAreOpenedKeptAndClosed() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let launcher = guest.proxies()
  let tunnel = ReverseTunnel(
    guestPort: 11434, hostAddress: try IPv4Address("127.0.0.1"), hostPort: 11434)
  try launcher.syncModelTunnels(instance, target: guest.target, wanted: [11434: tunnel])
  let pid = try #require(launcher.modelTunnelPID(instance, port: 11434))
  #expect(
    readFile(ProxyLauncher.modelSpecPath(instance, 11434))
      == ProxyLauncher.modelTunnelSpec(guest.target, tunnel))
  #expect(
    guest.log("tunnels.log").contains {
      $0.contains("-O forward -R 127.0.0.1:11434:127.0.0.1:11434")
    })
  try launcher.syncModelTunnels(instance, target: guest.target, wanted: [11434: tunnel])
  #expect(guest.log("tunnels.log").filter { $0.hasPrefix("master") }.count == 1)
  #expect(launcher.modelTunnelPID(instance, port: 11434) == pid)
  try launcher.syncModelTunnels(instance, target: guest.target, wanted: [:])
  #expect(ProxyLauncher.recordedModelTunnels(instance).isEmpty)
  var status: Int32 = 0
  #expect(waitpid(pid, &status, 0) == pid)

  // A refused forward fails closed and leaves nothing recorded.
  try guest.flag("forward-fails")
  let error = try #require(throws: (any Error).self) {
    try launcher.syncModelTunnels(instance, target: guest.target, wanted: [11434: tunnel])
  }
  #expect(
    oneLineError(error).contains("Failed to tunnel local model 127.0.0.1:11434 into the guest"))
  #expect(oneLineError(error).contains("request failed"))
  #expect(ProxyLauncher.recordedModelTunnels(instance).isEmpty)
}

@Test func filteredProofRequiresEveryStartedModelTunnel() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let config = try testConfig()
  let launcher = guest.proxies()
  var model = ModelState()
  model.mode = .local
  model.claudeEndpoint = try LocalModel(
    hostURL: "http://127.0.0.1:11434", model: "m", authToken: nil)
  try model.save(instance)
  // `--no-agents` starts no tunnel; none is required.
  try ModelTunnelReadiness.require(instance, config: config, scope: .guest(guest.target))

  let tunnel = ReverseTunnel(
    guestPort: 11434, hostAddress: try IPv4Address("127.0.0.1"), hostPort: 11434)
  try launcher.syncModelTunnels(instance, target: guest.target, wanted: [11434: tunnel])
  let pid = try #require(launcher.modelTunnelPID(instance, port: 11434))
  try ModelTunnelReadiness.require(instance, config: config, scope: .guest(guest.target))
  try ModelTunnelReadiness.require(instance, config: config, scope: .host)

  // A tunnel recorded for another target, or no longer wanted, does not count.
  let spec = ProxyLauncher.modelSpecPath(instance, 11434)
  let recorded = try #require(readFile(spec))
  try writeFile(spec, recorded.replacingOccurrences(of: "iso-test.iso", with: "other.iso"))
  #expect(throws: HostError.self) {
    try ModelTunnelReadiness.require(instance, config: config, scope: .guest(guest.target))
  }
  try writeFile(spec, recorded)
  model.mode = .remote
  try model.save(instance)
  #expect(throws: HostError.self) {
    try ModelTunnelReadiness.require(instance, config: config, scope: .host)
  }
  model.mode = .local
  try model.save(instance)

  // A dead tunnel fails both scopes.
  kill(pid, SIGTERM)
  var status: Int32 = 0
  #expect(waitpid(pid, &status, 0) == pid)
  for scope in [FilteredReadiness.Scope.host, .guest(guest.target)] {
    let error = try #require(throws: HostError.self) {
      try ModelTunnelReadiness.require(instance, config: config, scope: scope)
    }
    #expect(error.message.hasPrefix("FILTERED_MODEL_TUNNEL_NOT_READY: "))
  }
  launcher.stopModelTunnels(instance)
}

@Test func tunnelIdentityNamesOnlyTheRecordedMaster() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance")
  let launcher = guest.proxies()
  let a = ReverseTunnel(guestPort: 11434, hostAddress: try IPv4Address("127.0.0.1"), hostPort: 1)
  let b = ReverseTunnel(guestPort: 11435, hostAddress: try IPv4Address("127.0.0.1"), hostPort: 2)
  try launcher.syncModelTunnels(instance, target: guest.target, wanted: [11434: a, 11435: b])
  let name = ProxyLauncher.modelTunnelName(11434)
  let identity = try #require(TunnelIdentity.load(instance, name))
  #expect(identity.address == guest.target.address)
  #expect(identity.controlPath.contains("/iso-proxy-"))
  #expect(TunnelIdentity.verify(instance, name, address: guest.target.address))
  #expect(TunnelIdentity.verify(instance, name, address: nil))
  #expect(!TunnelIdentity.verify(instance, name, address: "ubuntu@10.231.9.9"))

  // Another live tunnel master is still not this tunnel.
  let other = try #require(TunnelIdentity.load(instance, ProxyLauncher.modelTunnelName(11435)))
  let pidPath = ProxyLauncher.forwardPIDPath(instance, name)
  let pid = try #require(readFile(pidPath))
  try writeFile(pidPath, String(other.pid))
  #expect(!TunnelIdentity.verify(instance, name, address: nil))
  try writeFile(pidPath, pid)
  try TunnelIdentity(pid: other.pid, controlPath: identity.controlPath, address: identity.address)
    .save(instance, name: name)
  try writeFile(pidPath, String(other.pid))
  #expect(!TunnelIdentity.verify(instance, name, address: nil))
  try writeFile(pidPath, pid)
  try identity.save(instance, name: name)
  #expect(TunnelIdentity.verify(instance, name, address: nil))

  launcher.stopModelTunnels(instance)
  #expect(!FileManager.default.fileExists(atPath: TunnelIdentity.path(instance, name)))
  #expect(!TunnelIdentity.verify(instance, name, address: nil))
}

@Test func readinessRequiresAnUnauthorizedHTTPResponse() throws {
  for (reply, ready) in [
    ("HTTP/1.1 401 Unauthorized\r\n", true), ("HTTP/1.1 200 OK\r\n", false),
    ("GET /v1/messages HTTP/1.1\r\n", false), ("HTTP/1.1 401 Unauthorized", false), ("", false),
  ] {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        _ = bind(listener, $0, length)
        _ = listen(listener, 1)
        _ = getsockname(listener, $0, &length)
      }
    }
    let port = UInt16(bigEndian: address.sin_port)
    let peer = Thread {
      let connection = accept(listener, nil, nil)
      var request = [UInt8](repeating: 0, count: 256)
      _ = recv(connection, &request, request.count, 0)
      _ = reply.withCString { send(connection, $0, strlen($0), 0) }
      usleep(300_000)
      close(connection)
    }
    peer.start()
    #expect(ProxyLauncher.httpReady(port: port) == ready, "\(reply)")
    usleep(350_000)
    close(listener)
  }
}

@Test func proxyStartsConfinedWithTheCredentialOnStdinOnly() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let iso = try guest.installProxyStubs()
  let instance = try testInstance(guest.root + "/instance", index: 7)
  let launcher = guest.proxies(iso: iso)
  let upstream = EffectiveUpstream(
    credential: CredentialReference("cmd:printf sk-real-credential")!, auth: .bearer)
  let handle = try launcher.start(
    instance, provider: .openai, upstream: upstream, target: guest.target)
  defer { launcher.stopAll(instance) }
  #expect(handle.baseURL == "http://127.0.0.1:9795")
  let stdin = try OrderedJSON.parse(try #require(readFile(guest.root + "/proxy-stdin")))
  #expect(stdin["injection"]?["credential"] == .string("sk-real-credential"))
  #expect(stdin["capability_token"] == .string(handle.capabilityToken.expose()))
  #expect(stdin["listen"] == .string("127.0.0.1:9795"))
  // Never on argv, in the environment (empty), logs, or state files.
  let argv = try #require(readFile(guest.root + "/sandbox-argv"))
  #expect(argv.hasPrefix("-D\nPROXY_BIN=\(guest.root)/app/iso-proxy\n-p\n"))
  #expect(argv.contains(SeatbeltProfile.proxy))
  #expect(!argv.contains("sk-real-credential"))
  // The confinement wrapper starts with an empty environment (the shell
  // stand-in adds only its own PWD/SHLVL/_).
  let environment = rustLines(try #require(readFile(guest.root + "/sandbox-env")))
  #expect(
    environment.allSatisfy { $0.hasPrefix("PWD=") || $0.hasPrefix("SHLVL=") || $0.hasPrefix("_=") })
  for name in (try FileManager.default.contentsOfDirectory(atPath: instance.directory)) {
    #expect(
      readFile(instance.directory + "/" + name)?.contains("sk-real-credential") != true, "\(name)")
  }
  #expect(!guest.sink.text.contains("sk-real-credential"))
  #expect(ProxyLauncher.capabilityToken(instance, provider: .openai) == handle.capabilityToken)
  var status = stat()
  stat(ProxyLauncher.tokenPath(instance, "openai"), &status)
  #expect(status.st_mode & 0o777 == 0o600)
  #expect(guest.log("tunnels.log").contains { $0.contains("-R 127.0.0.1:9795:127.0.0.1:9795") })
  #expect(FileManager.default.fileExists(atPath: ProxyLauncher.pidPath(instance, "openai")))

  let identity = ProcessIdentity.path(forPIDFile: ProxyLauncher.pidPath(instance, "openai"))
  #expect(FileManager.default.fileExists(atPath: identity))
  #expect(
    ProxyLauncher.recordedProcessAlive(ProxyLauncher.pidPath(instance, "openai"), expect: .proxy))

  launcher.stop(instance, provider: .openai)
  for path in [
    ProxyLauncher.pidPath(instance, "openai"), ProxyLauncher.forwardPIDPath(instance, "openai"),
    ProxyLauncher.tokenPath(instance, "openai"), identity,
  ] {
    #expect(!FileManager.default.fileExists(atPath: path))
  }
}

@Test func proxyStartFailsClosed() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  // High ports, away from any proxy a developer may be running.
  let instance = try testInstance(guest.root + "/instance", index: 200)
  let upstream = EffectiveUpstream(credential: CredentialReference("cmd:printf k")!, auth: .apiKey)

  // Unresolvable credential: nothing is spawned.
  var iso = try guest.installProxyStubs()
  let unresolved = EffectiveUpstream(credential: CredentialReference("cmd:exit 4")!, auth: .apiKey)
  var error = try #require(throws: (any Error).self) {
    try guest.proxies(iso: iso).start(
      instance, provider: .anthropic, upstream: unresolved, target: guest.target)
  }
  #expect(oneLineError(error).contains("aborting VM start (fail-closed)"))
  #expect(!FileManager.default.fileExists(atPath: guest.root + "/proxy-stdin"))

  // No proxy binary next to iso.
  error = try #require(throws: (any Error).self) {
    try guest.proxies(iso: guest.root + "/elsewhere/iso").start(
      instance, provider: .anthropic, upstream: upstream, target: guest.target)
  }
  #expect("\(error)".contains("iso-proxy not found next to iso"))

  // Confinement failure: the proxy exits before serving.
  iso = try guest.installProxyStubs(behavior: "exit")
  error = try #require(throws: (any Error).self) {
    try guest.proxies(iso: iso).start(
      instance, provider: .anthropic, upstream: upstream, target: guest.target)
  }
  #expect("\(error)".contains("exited before it began serving"))
  #expect("\(error)".contains("boom: jail could not be established"))
  #expect(!FileManager.default.fileExists(atPath: ProxyLauncher.pidPath(instance, "anthropic")))

  // The guest refuses the forward: the running proxy is torn down.
  iso = try guest.installProxyStubs()
  try guest.flag("forward-fails")
  error = try #require(throws: (any Error).self) {
    try guest.proxies(iso: iso).start(
      instance, provider: .openai, upstream: upstream, target: guest.target)
  }
  #expect(oneLineError(error).contains("reverse SSH tunnel"))
  for path in [
    ProxyLauncher.pidPath(instance, "openai"), ProxyLauncher.forwardPIDPath(instance, "openai"),
    ProxyLauncher.tokenPath(instance, "openai"),
  ] {
    #expect(!FileManager.default.fileExists(atPath: path))
  }

  // A tunnel master that dies before authenticating.
  try FileManager.default.removeItem(atPath: guest.root + "/flags/forward-fails")
  try guest.flag("master-exits")
  error = try #require(throws: (any Error).self) {
    try guest.proxies(iso: iso).start(
      instance, provider: .anthropic, upstream: upstream, target: guest.target)
  }
  #expect(oneLineError(error).contains("before its control socket became ready"))
}

@Test func proxyOverridesResolveAndLiteralsFailClosed() throws {
  let root = try scratchDirectory("pstate")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let instance = try testInstance(root)
  let config = try testConfig(
    #""proxy": {"anthropic": {"credential": "cmd:default", "auth": "bearer"}, "openai": {"credential": "cmd:default-oai", "auth": "bearer"}}"#
  ).proxy
  #expect(
    try ProxyState.effectiveUpstream(instance, .anthropic, config: config)?.credential.command
      .expose() == "cmd:default")
  #expect(
    try ProxyState.effectiveUpstream(instance, .anthropic, config: try testConfig().proxy) == nil)

  try ProxyState.setOverride(
    instance, provider: .anthropic, credential: CredentialReference("cmd:override")!, auth: .apiKey)
  let effective = try ProxyState.effectiveUpstream(instance, .anthropic, config: config)
  #expect(
    effective == EffectiveUpstream(credential: CredentialReference("cmd:override")!, auth: .apiKey))
  var status = stat()
  stat(instance.proxyStatePath, &status)
  #expect(status.st_mode & 0o777 == 0o600)

  // Invalid credential state is rejected without rewriting or exposing it.
  try writeFile(
    instance.proxyStatePath,
    #"{"openai": {"credential": "sk-literal", "auth": "bearer"}, "anthropic": {"credential": "cmd:a"}, "extra": 1}"#
  )
  let error = try #require(throws: (any Error).self) {
    try ProxyState.effectiveUpstream(instance, .openai, config: config)
  }
  #expect("\(error)".contains("Failed to parse proxy.json"))
  #expect(!"\(error)".contains("sk-literal"))
  #expect(throws: HostError("Failed to parse proxy.json")) {
    try ProxyState.setOverride(
      instance, provider: .anthropic, credential: CredentialReference("cmd:new")!, auth: .bearer)
  }
  #expect(readFile(instance.proxyStatePath)?.contains("sk-literal") == true)
  try writeFile(
    instance.proxyStatePath,
    #"{"openai": {"credential": "cmd:openai", "auth": "bearer"}, "anthropic": {"credential": "cmd:a"}, "extra": 1}"#
  )
  try ProxyState.setOverride(
    instance, provider: .anthropic, credential: CredentialReference("cmd:new")!, auth: .bearer)
  #expect(
    try canonicalJSON(readFile(instance.proxyStatePath))
      == canonicalJSON(
        "{\n  \"anthropic\": {\n    \"credential\": \"cmd:new\",\n    \"auth\": \"bearer\"\n  },\n  \"openai\": {\n    \"credential\": \"cmd:openai\",\n    \"auth\": \"bearer\"\n  }\n}"
      ))
  try ProxyState.setOverride(
    instance, provider: .openai, credential: CredentialReference("cmd:fixed")!, auth: .bearer)
  #expect(
    try ProxyState.effectiveUpstream(instance, .openai, config: config)?.credential.command.expose()
      == "cmd:fixed")

  try writeFile(instance.proxyStatePath, "{")
  #expect(throws: (any Error).self) {
    try ProxyState.setOverride(
      instance, provider: .openai, credential: CredentialReference("cmd:x")!, auth: .bearer)
  }
}

@Test func keychainProvisioningUsesTheExistingNamesAndFailsExplicitly() throws {
  let root = try scratchDirectory("keychain")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let tool = root + "/security"
  try writeFile(tool, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(root)/argv\"\n", mode: 0o755)
  #expect(ProxyProvisioning.service(for: .anthropic, vm: nil) == "iso-anthropic")
  #expect(ProxyProvisioning.service(for: .openai, vm: try InstanceName("dev")) == "iso-openai-dev")
  #expect(ProxyProvisioning.auth(for: .openai, apiKey: true) == .bearer)
  #expect(ProxyProvisioning.auth(for: .anthropic, apiKey: true) == .apiKey)
  #expect(ProxyProvisioning.auth(for: .anthropic, apiKey: false) == .bearer)
  let reference = try ProxyProvisioning.storeInKeychain(
    service: "iso-openai-dev", account: "openai", secret: Secret("sk-x"), environment: [:],
    tool: tool)
  #expect(
    reference.command.expose()
      == "cmd:security find-generic-password -s iso-openai-dev -a openai -w")
  #expect(
    readFile(root + "/argv")
      == "add-generic-password\n-U\n-s\niso-openai-dev\n-a\nopenai\n-w\nsk-x\n")
  #expect(ProxyProvisioning.shellQuote("a b") == "'a b'")
  #expect(ProxyProvisioning.shellQuote("a'b") == "'a'\\''b'")
  #expect(ProxyProvisioning.shellQuote("") == "''")

  try writeFile(tool, "#!/bin/sh\nexit 45\n", mode: 0o755)
  let refused = try #require(throws: (any Error).self) {
    try ProxyProvisioning.storeInKeychain(
      service: "s", account: "a", secret: Secret("sk-x"), environment: [:], tool: tool)
  }
  #expect(oneLineError(refused).contains("Failed to write secret to macOS Keychain"))
  #expect(!oneLineError(refused).contains("sk-x"))
  #expect(throws: (any Error).self) {
    try ProxyProvisioning.storeInKeychain(
      service: "s", account: "a", secret: Secret("sk-x"), environment: [:], tool: root + "/missing")
  }
}

@Test func recordedPIDsAreSignalledOnlyWhileTheyNameTheProcess() {
  #expect(ProxyLauncher.RecordedProcess.isSSH("/usr/bin/ssh -N -T host"))
  #expect(!ProxyLauncher.RecordedProcess.isSSH("/bin/zsh -c ssh"))
  // This test process is alive but was never recorded as a proxy.
  #expect(!ProxyLauncher.isRecorded(getpid(), pidPath: "/nonexistent/proxy.pid", expect: .proxy))
}

/// A process whose arguments merely name iso-proxy or iso-egress is not a
/// companion; only the identity recorded at spawn (start time and
/// executable) makes a PID one, and a legacy record must run the executable
/// iso would start.
@Test func companionPIDsAreTrustedOnlyByTheirRecordedIdentity() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance", index: 12)
  try FileManager.default.createDirectory(
    atPath: instance.directory, withIntermediateDirectories: true)
  let bystander = Process()
  // bash itself, not the /bin/sh trampoline, so the image stays the same.
  bystander.executableURL = URL(fileURLWithPath: "/bin/bash")
  bystander.arguments = ["-c", "/bin/sleep 30; :", "/opt/iso/bin/iso-proxy", "/opt/iso/iso-egress"]
  try bystander.run()
  defer { bystander.terminate() }
  let pid = bystander.processIdentifier
  for (name, expect) in [("openai", ProxyLauncher.RecordedProcess.proxy), ("egress", .egress)] {
    let pidPath = ProxyLauncher.pidPath(instance, name)
    try writeFile(pidPath, String(pid))
    #expect(!ProxyLauncher.recordedProcessAlive(pidPath, expect: expect))
    #expect(
      !ProxyLauncher.isRecorded(
        pid, pidPath: pidPath, expect: expect, legacyExecutable: "/opt/iso/bin/iso-proxy"))
    #expect(
      ProxyLauncher.isRecorded(
        pid, pidPath: pidPath, expect: expect,
        legacyExecutable: ProcessIdentity.executablePath(pid)))
    // Liveness checks accept a legacy record running the companion beside
    // this iso, as stopping does.
    let bin = guest.root + "/bin-\(name)"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: bin + (name == "openai" ? "/iso-proxy" : "/iso-egress"),
      withDestinationPath: "/bin/bash")
    #expect(
      ProxyLauncher.recordedProcessAlive(pidPath, expect: expect, isoExecutable: bin + "/iso"))
    #expect(
      !ProxyLauncher.recordedProcessAlive(
        pidPath, expect: expect, isoExecutable: "/opt/iso/bin/iso"))
    try ProxyLauncher.record(pid, at: pidPath, label: name)
    #expect(ProxyLauncher.recordedProcessAlive(pidPath, expect: expect))
    let recorded = try #require(ProcessIdentity.load(forPIDFile: pidPath))
    #expect(recorded.executable == ProcessIdentity.executablePath(pid))
    // The same PID with another start time is a reused PID.
    try ProcessIdentity(
      pid: pid, startSeconds: recorded.startSeconds &- 1,
      startMicroseconds: recorded.startMicroseconds, executable: recorded.executable
    ).save(forPIDFile: pidPath)
    #expect(!ProxyLauncher.recordedProcessAlive(pidPath, expect: expect))
  }
  let launcher = guest.proxies()
  launcher.stop(instance, provider: .openai)
  launcher.stopEgress(instance)
  usleep(200_000)
  #expect(bystander.isRunning)
  for name in ["openai", "egress"] {
    let pidPath = ProxyLauncher.pidPath(instance, name)
    #expect(!FileManager.default.fileExists(atPath: pidPath))
    #expect(!FileManager.default.fileExists(atPath: ProcessIdentity.path(forPIDFile: pidPath)))
  }
}

/// Copies `/bin/sleep` to `path`, re-signed ad hoc: a copied platform binary
/// is killed at launch.
private func runnableSleep(at path: String) throws {
  try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: path)
  let signed = try ProcessRunner().capture(
    .init(
      executable: "/usr/bin/codesign", arguments: ["-f", "-s", "-", path], environment: [:],
      deadline: .seconds(30)))
  try #require(signed.termination.succeeded)
}

/// A companion started from an image that `iso update` later replaces, or
/// that is then removed, is still the recorded process; a reused PID is not.
@Test func aRecordedCompanionOutlivesItsImageBeingReplacedOrRemoved() throws {
  let root = try scratchDirectory("identity")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let image = root + "/iso-proxy"
  try runnableSleep(at: image)
  let child = Process()
  child.executableURL = URL(fileURLWithPath: image)
  child.arguments = ["30"]
  try child.run()
  defer {
    child.terminate()
    child.waitUntilExit()
  }
  let pid = child.processIdentifier
  let identity = try #require(ProcessIdentity.observe(pid))
  #expect(identity.executable == image)
  // An update renames a new binary over the path; the kernel still reports it.
  try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: root + "/staged")
  #expect(rename(root + "/staged", image) == 0)
  #expect(child.isRunning)
  #expect(identity.isAlive)
  // Once the path is gone the kernel reports none; the start time still matches.
  #expect(unlink(image) == 0)
  #expect(ProcessIdentity.executablePath(pid) == nil)
  #expect(child.isRunning)
  #expect(identity.isAlive)
  let start = (seconds: identity.startSeconds, microseconds: identity.startMicroseconds)
  #expect(!identity.matches(start: start, executable: "/usr/bin/other"))
  #expect(!identity.matches(start: (start.seconds &- 1, start.microseconds), executable: nil))
  let reused = ProcessIdentity(
    pid: pid, startSeconds: identity.startSeconds &- 1,
    startMicroseconds: identity.startMicroseconds, executable: identity.executable)
  #expect(!reused.isAlive)
}

/// Stopping a record written by an older iso compares the running image with
/// the companion's path without checking its signature, so a companion that
/// would fail verification (mid-upgrade) is still stopped. A tunnel's stop
/// leaves `TunnelIdentity`'s file to `stopTunnel`.
@Test func legacyRecordsAreStoppedWithoutVerifyingTheCompanion() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let app = guest.root + "/legacy"
  try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
  try writeFile(app + "/iso", "", mode: 0o755)
  try runnableSleep(at: app + "/iso-proxy")
  let verified = Mutex(0)
  let launcher = ProxyLauncher(
    environment: [:], resolver: CredentialResolver(environment: [:]),
    diagnostics: guest.sink.diagnostics, isoExecutable: app + "/iso",
    sandboxExec: guest.root + "/bin/sandbox-exec", controlRoot: guest.root,
    verifyCompanion: { _ in
      verified.withLock { $0 += 1 }
      throw HostError("refused")
    })
  let child = Process()
  child.executableURL = URL(fileURLWithPath: app + "/iso-proxy")
  child.arguments = ["30"]
  try child.run()
  let instance = try testInstance(guest.root + "/instance", index: 14)
  try FileManager.default.createDirectory(
    atPath: instance.directory, withIntermediateDirectories: true)
  let pidPath = ProxyLauncher.pidPath(instance, "openai")
  try writeFile(pidPath, String(child.processIdentifier))
  #expect(child.isRunning)
  launcher.killPIDFile(pidPath, label: "proxy", expect: .proxy)
  child.waitUntilExit()
  #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
  #expect(verified.withLock { $0 } == 0)
  #expect(!FileManager.default.fileExists(atPath: pidPath))

  let forward = ProxyLauncher.forwardPIDPath(instance, "openai")
  try writeFile(forward, "999999")
  try writeFile(TunnelIdentity.path(instance, "openai"), "{}")
  launcher.killPIDFile(forward, label: "proxy tunnel", expect: .ssh)
  #expect(!FileManager.default.fileExists(atPath: forward))
  #expect(FileManager.default.fileExists(atPath: TunnelIdentity.path(instance, "openai")))
}

@Test func egressStartsConfinedUnderItsOwnProfile() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let iso = try guest.installProxyStubs()
  // The proxy stand-in serves any startup document with a listen address.
  try FileManager.default.copyItem(
    atPath: guest.root + "/app/iso-proxy", toPath: guest.root + "/app/iso-egress")
  let instance = try testInstance(guest.root + "/instance", index: 13)
  try FileManager.default.createDirectory(
    atPath: instance.directory, withIntermediateDirectories: true)
  let launcher = guest.proxies(iso: iso)
  let port = EgressPorts.port(instance)
  var control: [Int32] = [-1, -1]
  try #require(pipe(&control) == 0)
  defer {
    close(control[0])
    close(control[1])
  }
  try launcher.spawnEgress(
    instance, port: port, binary: try launcher.locateEgressBinary(),
    startup: Array(#"{"listen":"127.0.0.1:\#(port)"}"#.utf8), controlRead: control[0])
  defer { launcher.stopEgress(instance) }
  let argv = try #require(readFile(guest.root + "/sandbox-argv"))
  let binary = guest.root + "/app/iso-egress"
  #expect(argv.hasPrefix("-D\nEGRESS_BIN=\(binary)\n-p\n"))
  #expect(argv.contains(SeatbeltProfile.egress))
  #expect(argv.hasSuffix("\n\(binary)\n"))
  let pidPath = ProxyLauncher.pidPath(instance, "egress")
  #expect(ProxyLauncher.recordedProcessAlive(pidPath, expect: .egress))
  #expect(FileManager.default.fileExists(atPath: ProcessIdentity.path(forPIDFile: pidPath)))
}

@Test func aProxyPortServedByAnotherProcessIsRefused() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let iso = try guest.installProxyStubs()
  let instance = try testInstance(guest.root + "/instance", index: 9)
  // Something else already listens where this instance's proxy would.
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  defer { close(fd) }
  var reuse: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = UInt16(9797).bigEndian
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  try #require(bound == 0 && listen(fd, 16) == 0)
  let launcher = guest.proxies(iso: iso)
  let upstream = EffectiveUpstream(
    credential: CredentialReference("cmd:printf sk-real-credential")!, auth: .bearer)
  // Refused before the proxy starts (port probe), or — if the probe loses a
  // race — fail-closed when the proxy cannot bind or is not the listener.
  // Either way nothing is left serving or recorded.
  #expect(throws: (any Error).self) {
    try launcher.start(instance, provider: .openai, upstream: upstream, target: guest.target)
  }
  for path in [
    ProxyLauncher.pidPath(instance, "openai"), ProxyLauncher.tokenPath(instance, "openai"),
  ] {
    #expect(!FileManager.default.fileExists(atPath: path))
  }
}

@Test func aReusedPIDIsNotSignalled() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let instance = try testInstance(guest.root + "/instance", index: 11)
  // A live process that is not a proxy now holds the recorded PID.
  let bystander = Process()
  bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
  bystander.arguments = ["30"]
  try bystander.run()
  defer { bystander.terminate() }
  try FileManager.default.createDirectory(
    atPath: instance.directory, withIntermediateDirectories: true)
  let pidPath = ProxyLauncher.pidPath(instance, "openai")
  try Data(String(bystander.processIdentifier).utf8).write(to: URL(fileURLWithPath: pidPath))
  guest.proxies().stop(instance, provider: .openai)
  #expect(!FileManager.default.fileExists(atPath: pidPath))
  usleep(200_000)
  #expect(bystander.isRunning)
}

@Test func occupiedProxyPortsAreRefusedAndForeignListenersRejected() throws {
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = 0
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  let ready = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, length) == 0 && listen(fd, 64) == 0 && getsockname(fd, $0, &length) == 0
    }
  }
  try #require(ready)
  let port = UInt16(bigEndian: address.sin_port)
  #expect(throws: HostError.self) { try ProxyLauncher.requireFreePort(port) }
  // This test process listens there, not the given pid.
  #expect(throws: HostError.self) { try ProxyLauncher.requireListener(1, port: port) }
  #expect(throws: Never.self) { try ProxyLauncher.requireListener(getpid(), port: port) }
}
