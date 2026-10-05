import Foundation
import IsoConfiguration
import IsoCore
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

@Test func proxyPortsArePerInstanceAndPerProvider() throws {
  let root = try scratchDirectory("ports")
  defer { try? FileManager.default.removeItem(atPath: root) }
  #expect(ProxyProvider.anthropic.port(try testInstance(root, index: 0)) == 8788)
  #expect(ProxyProvider.anthropic.port(try testInstance(root, index: 5)) == 8793)
  #expect(ProxyProvider.openai.port(try testInstance(root, index: 0)) == 9788)
  #expect(ProxyProvider.openai.port(try testInstance(root, index: 5)) == 9793)
  #expect(ProxyProvider.anthropic.basePort + InstanceIndex.maximum < ProxyProvider.openai.basePort)
  #expect(ProxyProvider.openai.persistsToken && !ProxyProvider.anthropic.persistsToken)
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

  launcher.stop(instance, provider: .openai)
  for path in [
    ProxyLauncher.pidPath(instance, "openai"), ProxyLauncher.forwardPIDPath(instance, "openai"),
    ProxyLauncher.tokenPath(instance, "openai"),
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
  #expect(ProxyLauncher.RecordedProcess.proxy.matches("/opt/iso/bin/iso-proxy"))
  #expect(ProxyLauncher.RecordedProcess.proxy.matches("/usr/bin/python3 /tmp/g/app/iso-proxy"))
  #expect(
    !ProxyLauncher.RecordedProcess.proxy.matches("/Applications/Safari.app/Contents/MacOS/Safari"))
  #expect(ProxyLauncher.RecordedProcess.ssh.matches("/usr/bin/ssh -N -T host"))
  #expect(!ProxyLauncher.RecordedProcess.ssh.matches("/bin/zsh -c ssh"))
  // This test process is alive but is not a proxy: it must not be signalled.
  #expect(
    ProxyLauncher.commandLine(getpid()).map(ProxyLauncher.RecordedProcess.proxy.matches) == false)
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
