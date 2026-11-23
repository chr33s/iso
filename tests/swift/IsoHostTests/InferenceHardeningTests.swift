import CryptoKit
import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

private let token = String(repeating: "c", count: 64)
private let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../../Sources/IsoHost/Inference/Resources").standardized

private let mlxMain = try! ManagedBackendName("mlx-main")

private func plan(
  port: UInt16 = 18090, runtime: ManagedBackendConfig.Runtime, model: ManagedBackendConfig.Model,
  confinement: ManagedBackendConfig.Confinement = .seatbelt
) -> ManagedBackendPlan {
  ManagedBackendPlan(
    name: mlxMain, port: port, runtime: runtime, model: model, memoryLimitBytes: 8 << 30,
    confinement: confinement, token: Secret(token))
}

private func python() throws -> String { try requireSystemPython() }

@Test func embeddedInferenceResourcesMatchTheirFiles() throws {
  for (embedded, file) in [
    (EmbeddedInference.launcher, "inference-launcher.py"),
    (EmbeddedInference.backendProfile, "seatbelt-inference-backend.sb"),
    (EmbeddedInference.gatewayProfile, "seatbelt-inference.sb"),
    (EmbeddedInference.mlxLMLock, "mlx-lm-0.31.3.lock"),
  ] {
    #expect(
      embedded == (try #require(readFile(resources.appending(path: file).path))),
      "\(file) is stale; run scripts/generate-embedded-resources.py")
  }
  let profile = EmbeddedInference.backendProfile
  #expect(profile.contains("(deny default)"))
  #expect(!profile.contains("network-outbound"), "the backend makes no outbound connections")
  #expect(profile.contains(#"(literal (param "PYTHON_EXECUTABLE")))"#))
  #expect(profile.contains(#"(string-append "localhost:" (param "PORT"))"#))
  #expect(!profile.contains(#""localhost:*""#), "the backend binds its own port only")
}

/// `install` accepts exactly the releases iso ships a lock for, and each
/// lock pins every requirement, its own release included, with hashes.
@Test func everyInstallableReleaseShipsAFullyHashedLock() throws {
  #expect(Set(ManagedBackend.locks.keys) == Set(ManagedBackendConfig.lockedMLXLM))
  for (version, lock) in ManagedBackend.locks {
    let requirements = lock.replacingOccurrences(of: "\\\n", with: " ")
      .split(separator: "\n").map { String($0).trimmingUnicodeWhitespace() }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    #expect(requirements.count > 1)
    #expect(requirements.contains { $0.hasPrefix("mlx-lm==\(version) ") })
    for requirement in requirements {
      let fields = requirement.split(separator: " ")
      #expect(fields.first?.contains("==") == true, "\(requirement)")
      let hashes = fields.dropFirst()
      #expect(!hashes.isEmpty, "\(requirement)")
      #expect(
        hashes.allSatisfy {
          $0.hasPrefix("--hash=sha256:")
            && ManagedBackendConfig.isHex(String($0.dropFirst(14)), count: 64)
        }, "\(requirement)")
    }
  }
}

@Test func planRoundTripsAndRejectsTampering() throws {
  let install = plan(
    runtime: .install(version: "0.31.3"), model: .directory(HostPath(absolute: "/m")))
  #expect(try ManagedBackendPlan.decode(install.encoded) == install)
  for version in ["0.31.4", "0.31.3 ", "0.31"] {
    let tampered = String(decoding: install.encoded, as: UTF8.self)
      .replacingOccurrences(of: "\"0.31.3\"", with: "\"\(version)\"")
    #expect(throws: (any Error).self) { try ManagedBackendPlan.decode(Array(tampered.utf8)) }
  }
  let original = plan(
    runtime: .python(HostPath(absolute: "/opt/py/bin/python3")),
    model: .fetch(
      repository: "mlx-community/Model-4bit", revision: String(repeating: "a", count: 40)))
  #expect(try ManagedBackendPlan.decode(original.encoded) == original)
  let text = String(decoding: original.encoded, as: UTF8.self)
  for tampered in [
    text.replacingOccurrences(of: token, with: "short"),
    text.replacingOccurrences(of: "\"mlx-main\"", with: "\"../etc\""),
    text.replacingOccurrences(of: "18090", with: "80"),
    text.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"extra\":1"),
    text.replacingOccurrences(of: "/opt/py/bin/python3", with: "relative/python"),
    text.replacingOccurrences(of: String(repeating: "a", count: 40), with: "main"),
    // A name that is a path component outside the backends directory.
    text.replacingOccurrences(of: "\"mlx-main\"", with: "\"..\""),
    // The root step applies the configuration's repository rule.
    text.replacingOccurrences(of: "mlx-community/Model-4bit", with: "../Model-4bit"),
  ] {
    #expect(throws: (any Error).self) { try ManagedBackendPlan.decode(Array(tampered.utf8)) }
  }
}

@Test func jobArgumentsAndPlist() throws {
  let layout = ManagedBackendLayout(name: mlxMain)
  let python = PythonRuntime(
    launch: "/p/bin/python3", executable: "/base/bin/python3.14", prefix: "/p", basePrefix: "/base")
  let confined = ManagedBackend.programArguments(
    plan(
      runtime: .python(HostPath(absolute: "/p/bin/python3")),
      model: .directory(HostPath(absolute: "/m"))),
    layout: layout, python: python, tools: SystemTools())
  #expect(confined.first == "/usr/bin/sandbox-exec")
  #expect(confined.contains("-f") && confined.contains(layout.profile))
  #expect(confined.contains("PORT=18090"))
  #expect(confined.contains("PYTHON_EXECUTABLE=/base/bin/python3.14"))
  #expect(confined.contains("PYTHON_BASE_PREFIX=/base"))
  #expect(confined.suffix(10).contains("--token-file"))
  let open = ManagedBackend.programArguments(
    plan(
      runtime: .python(HostPath(absolute: "/p/bin/python3")),
      model: .directory(HostPath(absolute: "/m")),
      confinement: .none),
    layout: layout, python: python, tools: SystemTools())
  #expect(open.first == "/p/bin/python3" && open.contains("-I"))
  let data = Data(
    try ManagedBackend.plist(
      plan(runtime: .python(HostPath(absolute: "/p")), model: .directory(HostPath(absolute: "/m"))),
      layout: layout, arguments: confined))
  let document = try #require(
    try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
  #expect(document["Label"] as? String == "com.iso.inference.mlx-main")
  #expect(document["UserName"] as? String == "_isoinference")
  #expect(document["KeepAlive"] as? Bool == true)
  #expect(document["ProcessType"] as? String == "Background")
  let environment = try #require(document["EnvironmentVariables"] as? [String: String])
  #expect(environment["HF_HUB_OFFLINE"] == "1" && environment["HOME"] == layout.cache)
  #expect(!String(decoding: data, as: UTF8.self).contains(token), "the token is never in the plist")
}

/// A fake system under a prefix: `dscl` records calls and remembers the role
/// account; `launchctl bootstrap` starts a stand-in backend that requires the
/// token from the provisioned token file.
private struct FakeSystem {
  let root: String
  var prefix: String { root + "/prefix" }
  var log: String { root + "/calls.log" }

  /// `requireToken: false` makes the stand-in answer without the token.
  init(port: UInt16, requireToken: Bool = true) throws {
    root = try scratchDirectory("provision")
    try FileManager.default.createDirectory(atPath: prefix, withIntermediateDirectories: true)
    let layout = ManagedBackendLayout(name: mlxMain, prefix: prefix)
    try FileManager.default.createDirectory(
      atPath: prefix + "/Library/LaunchDaemons", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: prefix + "/Library/Application Support", withIntermediateDirectories: true)
    try writeFile(
      root + "/dscl",
      """
      #!/bin/sh
      echo "dscl $*" >> "\(log)"
      case "$2" in
        -read) [ -f "\(root)/created" ] && echo "$4: 402" && exit 0; exit 56 ;;
        -list) case "$3" in /Users) printf 'root 0\\nfoo 400\\n' ;; *) printf 'wheel 0\\nbar 401\\n' ;; esac ;;
        -create) [ "$4" = "UniqueID" ] && touch "\(root)/created" ;;
        -delete) rm -f "\(root)/created" ;;
      esac
      exit 0
      """, mode: 0o755)
    try writeFile(
      root + "/backend.py",
      """
      import hashlib, hmac, sys
      from http.server import BaseHTTPRequestHandler, HTTPServer
      token = open(sys.argv[2]).read().strip()
      class H(BaseHTTPRequestHandler):
          def do_GET(self):
              if self.path.startswith("/iso/challenge/"):
                  body = hmac.new(token.encode(), self.path.rsplit("/", 1)[1].encode(), hashlib.sha256).hexdigest().encode()
                  self.send_response(200)
                  self.send_header("content-length", str(len(body)))
                  self.end_headers()
                  self.wfile.write(body)
                  return
              ok = \(requireToken ? "" : "True or ")self.headers.get("Authorization") == "Bearer " + token
              self.send_response(200 if ok else 401)
              self.send_header("content-length", "0")
              self.end_headers()
          def log_message(self, *a): pass
      HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
      """)
    try writeFile(
      root + "/launchctl",
      """
      #!/bin/sh
      echo "launchctl $*" >> "\(log)"
      case "$1" in
        bootstrap) "\(try requireSystemPython())" "\(root)/backend.py" \(port) "\(layout.token)" >/dev/null 2>&1 &
                   echo $! > "\(root)/backend.pid" ;;
        bootout|kickstart) [ -f "\(root)/backend.pid" ] && kill "$(cat "\(root)/backend.pid")" 2>/dev/null ;;
      esac
      exit 0
      """, mode: 0o755)
  }

  var tools: SystemTools {
    var tools = SystemTools()
    tools.dscl = root + "/dscl"
    tools.launchctl = root + "/launchctl"
    tools.privilegedUID = getuid()
    tools.chown = { _, _, _ in 0 }
    return tools
  }

  func stop() {
    if let pid = readFile(root + "/backend.pid").flatMap({ Int32($0.trimmingUnicodeWhitespace()) })
    {
      kill(pid, SIGTERM)
    }
    try? FileManager.default.removeItem(atPath: root)
  }
}

private func mode(_ path: String) -> mode_t {
  var info = stat()
  return lstat(path, &info) == 0 ? info.st_mode & 0o7777 : 0
}

@Test func provisioningBuildsTheLayoutAndVerifiesTheToken() throws {
  let port = try TCPListener(address: "127.0.0.1")
  let chosen = port.port
  port.close()
  let system = try FakeSystem(port: chosen)
  defer { system.stop() }
  let model = system.root + "/weights"
  try writeFile(model + "/config.json", "{}")
  try writeFile(model + "/model.safetensors", "weights")
  let provisioner = ManagedBackendProvisioner(
    tools: system.tools, prefix: system.prefix, log: { _ in })
  let request = plan(
    port: chosen, runtime: .python(HostPath(absolute: try python())),
    model: .directory(HostPath(absolute: model)))
  try provisioner.provision(request)
  let layout = ManagedBackendLayout(name: mlxMain, prefix: system.prefix)
  let calls = readFile(system.log) ?? ""
  #expect(calls.contains("-create /Users/_isoinference UniqueID 402"))
  #expect(calls.contains("-create /Users/_isoinference UserShell /usr/bin/false"))
  #expect(calls.contains("-create /Users/_isoinference IsHidden 1"))
  #expect(calls.contains("launchctl bootstrap system \(layout.plist)"))
  #expect(readFile(layout.token) == token && mode(layout.token) == 0o640)
  #expect(
    mode(layout.launcher) == 0o644 && readFile(layout.launcher) == EmbeddedInference.launcher)
  #expect(mode(layout.cache) == 0o700 && mode(layout.logs) == 0o755)
  #expect(mode(layout.logs + "/backend.log") == 0o600, "root-owned: launchd opens it as root")
  #expect(readFile(layout.model + "/model.safetensors") == "weights")
  #expect(mode(layout.model + "/model.safetensors") == 0o644 && mode(layout.model) == 0o755)
  #expect(FileManager.default.fileExists(atPath: layout.plist))
  // A second run reuses the account.
  try provisioner.provision(request)
  #expect((readFile(system.log) ?? "").components(separatedBy: "UniqueID 402").count == 2)

  try provisioner.deprovision(name: mlxMain)
  #expect(!FileManager.default.fileExists(atPath: layout.plist))
  #expect(!FileManager.default.fileExists(atPath: layout.directory))
  #expect((readFile(system.log) ?? "").contains("-delete /Users/_isoinference"))
}

/// The role account runs downloaded code with network access during a model
/// fetch (and `install`): no token, old or new, exists while it runs (§20.2).
@Test func noTokenExistsWhileTheRoleAccountFetches() throws {
  let port = try TCPListener(address: "127.0.0.1")
  let chosen = port.port
  port.close()
  let system = try FakeSystem(port: chosen)
  defer { system.stop() }
  let layout = ManagedBackendLayout(name: mlxMain, prefix: system.prefix)
  // A role-account run records whether a token is present, then fetches by
  // writing a config into its last argument, the staging directory.
  try writeFile(
    system.root + "/sudo",
    """
    #!/bin/sh
    if [ -e "\(layout.token)" ]; then echo "token present during a role run" >> "\(system.log)"; fi
    echo "sudo $*" >> "\(system.log)"
    for last; do :; done
    echo '{}' > "$last/config.json"
    exit 0
    """, mode: 0o755)
  var tools = system.tools
  tools.sudo = system.root + "/sudo"
  let provisioner = ManagedBackendProvisioner(tools: tools, prefix: system.prefix, log: { _ in })
  let request = plan(
    port: chosen, runtime: .python(HostPath(absolute: try python())),
    model: .fetch(repository: "owner/model", revision: String(repeating: "a", count: 40)))
  // A token left by an earlier provisioning is removed first, too.
  try FileManager.default.createDirectory(
    atPath: layout.directory, withIntermediateDirectories: true)
  try writeFile(layout.token, "old")
  try provisioner.provision(request)
  let calls = readFile(system.log) ?? ""
  #expect(calls.contains("snapshot_download"), "the fetch ran as the role account")
  #expect(!calls.contains("token present"))
  #expect(readFile(layout.token) == token && mode(layout.token) == 0o640)
}

@Test func weightsMayNotContainSymbolicLinks() throws {
  let model = try scratchDirectory("weights")
  defer { try? FileManager.default.removeItem(atPath: model) }
  try writeFile(model + "/config.json", "{}")
  try FileManager.default.createSymbolicLink(
    atPath: model + "/link", withDestinationPath: "/etc/hosts")
  var tools = SystemTools()
  tools.privilegedUID = getuid()
  tools.chown = { _, _, _ in 0 }
  let provisioner = ManagedBackendProvisioner(tools: tools, log: { _ in })
  #expect(throws: HostError.self) { try provisioner.restrict(model) }
  try provisioner.restrict(model, allowLinks: true)
}

@Test func provisioningRefusesABackendThatAnswersWithoutItsToken() throws {
  let listener = try TCPListener(address: "127.0.0.1")
  let chosen = listener.port
  listener.close()
  let system = try FakeSystem(port: chosen, requireToken: false)
  defer { system.stop() }
  let model = system.root + "/weights"
  try writeFile(model + "/config.json", "{}")
  let provisioner = ManagedBackendProvisioner(
    tools: system.tools, prefix: system.prefix, log: { _ in })
  #expect(throws: (any Error).self) {
    try provisioner.provision(
      plan(
        port: chosen, runtime: .python(HostPath(absolute: try python())),
        model: .directory(HostPath(absolute: model))))
  }
  let calls = readFile(system.log) ?? ""
  #expect(calls.components(separatedBy: "launchctl bootout").count == 3, "unloaded after failing")
}

@Test func listenerAuditKeepsOnlyNonLoopbackAddresses() {
  let parsed = BackendChecks.parseListeners(
    "p671\ncControlCe\nn*:7000\nn*:5000\np900\ncmlx\nn127.0.0.1:8080\nn[::1]:8080\np901\ncweb\nn192.168.1.5:3000\n"
  )
  #expect(parsed.map(\.address) == ["*:7000", "*:5000", "192.168.1.5:3000"])
  #expect(parsed.first?.command == "ControlCe" && parsed.first?.pid == 671)
}

@Test func runAsRefusesTheInvokingUserAndMissingAccounts() throws {
  let me = String(cString: getpwuid(getuid())!.pointee.pw_name)
  #expect(throws: HostError.self) {
    try BackendChecks.verifyRunAs(me, port: 1, managedJob: nil)
  }
  #expect(throws: HostError.self) {
    try BackendChecks.verifyRunAs("_isonosuchaccount", port: 1, managedJob: nil)
  }
  // Another account with no listener of ours on the port passes.
  try BackendChecks.verifyRunAs("nobody", port: 1, managedJob: nil)
  // Our own listener on the port fails, whoever run_as names.
  let own = try TCPListener(address: "127.0.0.1")
  defer { own.close() }
  #expect(throws: HostError.self) {
    try BackendChecks.verifyRunAs("nobody", port: own.port, managedJob: nil)
  }
  // A managed job must be running, as the account.
  #expect(throws: HostError.self) {
    try BackendChecks.verifyRunAs("nobody", port: 1, managedJob: ("com.iso.inference.x", nil))
  }
  #expect(throws: HostError.self) {
    try BackendChecks.verifyRunAs(
      "nobody", port: 1, managedJob: ("com.iso.inference.x", getpid()))
  }
}

@Test func managedBackendsUseTheKeychainCredentialAndRoleAccount() throws {
  let config = try testConfig(
    #"""
    "inference": {
      "mode": "required",
      "qualification_profiles": {"p": {"protocol": "openai-chat", "completion_evidence": "drain",
        "context_overflow": "truncate", "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
        "max_input_bytes": 1024}},
      "backends": {"mlx-main": {"base_url": "http://127.0.0.1:18080", "protocol": "openai-chat",
        "qualification_profile": "p",
        "managed": {"server": "mlx-lm", "python": "/opt/py/bin/python3", "model": "/models/m",
          "memory_limit": "8GiB"}}},
      "services": {"s": {"backend": "mlx-main", "upstream_model": "default_model",
        "frontend_apis": ["openai-chat"], "max_context_tokens": 1000}}
    }
    """#)
  let backend = try #require(config.inference.backends["mlx-main"])
  #expect(backend.runAs == "_isoinference")
  #expect(backend.managed?.confinement == .seatbelt)
  #expect(backend.managed?.memoryLimitBytes == 8 << 30)
  let reference = try #require(InferenceController.credential(backend, name: "mlx-main"))
  #expect(
    KeychainReference.parse(reference.command.expose())
      == KeychainReference(service: "iso-inference-backend", account: "mlx-main"))
}

@Test func configuredInterpretersMustBeRootOwned() throws {
  let provisioner = ManagedBackendProvisioner(log: { _ in })
  let mine = NSTemporaryDirectory() + "iso-python-" + UUID().uuidString
  try writeFile(mine + "/lib/site.py", "")
  defer { try? FileManager.default.removeItem(atPath: mine) }
  #expect(throws: HostError.self) { try provisioner.requireRootOwned(mine) }
  try provisioner.requireRootOwned("/usr/bin/true")
  let runtime = try provisioner.inspect(try requireSystemPython())
  #expect(runtime.executable.hasPrefix("/") && runtime.prefix == runtime.basePrefix)
}

/// H2: without the listing of this user's listeners, `run_as` is not
/// verified.
@Test func runAsFailsClosedWhenListenersCannotBeListed() throws {
  #expect(throws: HostError.self) {
    try BackendChecks.verifyRunAs("nobody", port: 1, managedJob: nil, listeners: { _ in nil })
  }
  try BackendChecks.verifyRunAs("nobody", port: 1, managedJob: nil, listeners: { _ in [] })
}

private func managedBackend(_ confinement: String = "seatbelt", isolation: String = "verified")
  throws -> InferenceBackendConfig
{
  let config = try testConfig(
    #"""
    "inference": {
      "mode": "required",
      "qualification_profiles": {"p": {"protocol": "openai-chat", "completion_evidence": "drain",
        "context_overflow": "truncate", "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
        "max_input_bytes": 1024}},
      "backends": {"mlx-main": {"base_url": "http://127.0.0.1:18080", "protocol": "openai-chat",
        "qualification_profile": "p", "isolation": "\#(isolation)",
        "managed": {"server": "mlx-lm", "python": "/opt/py/bin/python3", "model": "/models/m",
          "confinement": "\#(confinement)"}}},
      "services": {"s": {"backend": "mlx-main", "upstream_model": "default_model",
        "frontend_apis": ["openai-chat"], "max_context_tokens": 1000}}
    }
    """#)
  return try #require(config.inference.backends["mlx-main"])
}

/// H7: a managed backend must prove the listener is its job (the token
/// challenge) and, under Seatbelt, be verifiably sandboxed; an unknown answer
/// fails like a wrong one.
@Test func managedBackendChecksFailClosed() throws {
  let backend = try managedBackend()
  var good = BackendVerification()
  good.reachable = true
  good.managed = true
  good.runAs = .verified(account: "_isoinference")
  good.authenticated = true
  good.challenged = true
  good.confined = true
  try BackendChecks.require(name: "mlx-main", backend: backend, good)
  #expect(good.isolationVerified)
  for change in [
    { (v: inout BackendVerification) in v.authenticated = nil },
    { $0.authenticated = false }, { $0.challenged = nil }, { $0.challenged = false },
    { $0.confined = nil }, { $0.confined = false },
    { $0.runAs = .failed(account: "_isoinference", reason: "x") },
  ] as [(inout BackendVerification) -> Void] {
    var bad = good
    change(&bad)
    #expect(throws: HostError.self) {
      try BackendChecks.require(name: "mlx-main", backend: backend, bad)
    }
  }
  // `confinement: "none"` exempts only the sandbox check, and only for a
  // backend accepted as unverified.
  var open = good
  open.confined = false
  #expect(open.unverified == ["its sandbox"])
  #expect(throws: HostError.self) {
    try BackendChecks.require(name: "mlx-main", backend: try managedBackend("none"), open)
  }
  let accepted = try managedBackend("none", isolation: "unverified")
  try BackendChecks.require(name: "mlx-main", backend: accepted, open)
  open.challenged = nil
  #expect(throws: HostError.self) {
    try BackendChecks.require(name: "mlx-main", backend: accepted, open)
  }
}

/// An attached backend can never be verified: it needs the owner's explicit
/// acceptance, and then only the bind and run_as checks apply.
@Test func unverifiedBackendsNeedExplicitAcceptance() throws {
  func attached(_ isolation: String?) throws -> InferenceBackendConfig {
    let member = isolation.map { #", "isolation": "\#($0)""# } ?? ""
    let config = try testConfig(
      #"""
      "inference": {
        "mode": "required",
        "qualification_profiles": {"p": {"protocol": "openai-chat", "completion_evidence": "drain",
          "context_overflow": "truncate", "input_overhead": {"per_request_bytes": 0, "per_message_bytes": 0},
          "max_input_bytes": 1024}},
        "backends": {"local": {"base_url": "http://127.0.0.1:18080", "protocol": "openai-chat",
          "qualification_profile": "p"\#(member)}},
        "services": {"s": {"backend": "local", "upstream_model": "m",
          "frontend_apis": ["openai-chat"], "max_context_tokens": 1000}}
      }
      """#)
    return try #require(config.inference.backends["local"])
  }
  var observed = BackendVerification()
  observed.reachable = true
  #expect(!observed.isolationVerified)
  #expect(try attached(nil).isolation == .verified)
  #expect(throws: HostError.self) {
    try BackendChecks.require(name: "local", backend: try attached(nil), observed)
  }
  #expect(throws: HostError.self) {
    try BackendChecks.require(name: "local", backend: try attached("verified"), observed)
  }
  try BackendChecks.require(name: "local", backend: try attached("unverified"), observed)
  // Acceptance does not lift the bind check.
  observed.exposedAddresses = ["192.168.1.2"]
  #expect(throws: HostError.self) {
    try BackendChecks.require(name: "local", backend: try attached("unverified"), observed)
  }
  #expect(throws: (any Error).self) { try attached("trusted") }
}

/// The challenge is answered only by a holder of the token, and the probe
/// sends no token.
@Test func theBackendChallengeNeedsTheToken() throws {
  let root = try scratchDirectory("challenge")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let port = try TCPListener(address: "127.0.0.1")
  let chosen = port.port
  port.close()
  try writeFile(
    root + "/server.py",
    """
    import hashlib, hmac, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer
    key = sys.argv[2].encode()
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            assert "Authorization" not in self.headers
            body = hmac.new(key, self.path.rsplit("/", 1)[1].encode(), hashlib.sha256).hexdigest().encode()
            self.send_response(200)
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *a): pass
    HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
    """)
  let server = Process()
  server.executableURL = URL(fileURLWithPath: try requireSystemPython())
  server.arguments = [root + "/server.py", String(chosen), token]
  try server.run()
  defer { server.terminate() }
  // A loaded machine can take a while to start the interpreter.
  let deadline = ContinuousClock.now + .seconds(60)
  while !InferenceController.backendAccepts(port: chosen), ContinuousClock.now < deadline {
    usleep(100_000)
  }
  #expect(BackendProbe.answersChallenge(port: chosen, token: Secret(token)))
  #expect(
    !BackendProbe.answersChallenge(port: chosen, token: Secret(String(repeating: "d", count: 64))))
}

/// The H8 race: the role account swaps a weight file for a link to a file it
/// wants root to chmod while root walks the tree. Nothing follows the link.
@Test func restrictingATreeNeverFollowsASwappedLink() throws {
  let root = try scratchDirectory("restrict")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let outside = root + "/outside"
  try writeFile(outside, "secret", mode: 0o600)
  try writeFile(root + "/weights/model.safetensors", "weights", mode: 0o600)
  var tools = SystemTools()
  tools.privilegedUID = getuid()
  tools.chown = { path, _, _ in
    if path.hasSuffix("/model.safetensors") {
      unlink(path)
      symlink(outside, path)
    }
    return 0
  }
  let provisioner = ManagedBackendProvisioner(tools: tools, log: { _ in })
  #expect(throws: HostError.self) { try provisioner.restrict(root + "/weights") }
  #expect(mode(outside) == 0o600)
  try? provisioner.restrict(root + "/weights", allowLinks: true)
  #expect(mode(outside) == 0o600)
}

/// A configured interpreter is checked before root runs it: a user-owned
/// one never executes.
@Test func aUserOwnedInterpreterIsNeverRunAsRoot() throws {
  let root = try scratchDirectory("python")
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeFile(root + "/bin/python3", "#!/bin/sh\ntouch \"\(root)/ran\"\n", mode: 0o755)
  var tools = SystemTools()
  tools.privilegedUID = 0
  let provisioner = ManagedBackendProvisioner(tools: tools, log: { _ in })
  let layout = ManagedBackendLayout(name: mlxMain, prefix: root)
  #expect(throws: HostError.self) {
    _ = try provisioner.runtime(
      plan(
        runtime: .python(HostPath(absolute: root + "/bin/python3")),
        model: .directory(HostPath(absolute: "/m"))),
      layout: layout, uid: 400, gid: 400)
  }
  #expect(!FileManager.default.fileExists(atPath: root + "/ran"))
}

/// The final owner each path was given.
private final class OwnerLog: Sendable {
  let owners = Mutex<[String: [UInt32]]>([:])
  func owner(_ path: String) -> [UInt32]? { owners.withLock { $0[path] } }
}

/// `install` against fake tools: a stand-in `sudo` logs each role-account
/// run (and whether a token exists during it), then does what the real tool
/// would. `curl` writes `download` to its `--output`; `tar` unpacks a
/// minimal Python tree into its `-C` directory; `venv` links the venv's
/// interpreter to that tree's. The pinned archive is `verified-archive`.
private func installSystem(download: String) throws -> (
  FakeSystem, SystemTools, OwnerLog, ManagedBackendPlan
) {
  let port = try TCPListener(address: "127.0.0.1")
  let chosen = port.port
  port.close()
  let system = try FakeSystem(port: chosen)
  let layout = ManagedBackendLayout(name: mlxMain, prefix: system.prefix)
  try writeFile(system.root + "/download", download)
  try writeFile(system.root + "/weights/config.json", "{}")
  try writeFile(
    system.root + "/sudo",
    """
    #!/bin/sh
    if [ -e "\(layout.token)" ]; then echo "token present during a role run" >> "\(system.log)"; fi
    echo "sudo $*" >> "\(system.log)"
    previous=""
    for argument; do
      case "$previous" in
        --output) output="$argument" ;;
        -C) unpack="$argument" ;;
      esac
      previous="$argument"
    done
    case "$*" in
      *" /usr/bin/curl "*) cp "\(system.root)/download" "$output" ;;
      *" /usr/bin/tar "*)
        mkdir -p "$unpack/bin" "$unpack/lib/python3.12"
        printf '#!/bin/sh\\n' > "$unpack/bin/python3.12"
        chmod 700 "$unpack/bin/python3.12"
        ln -s python3.12 "$unpack/bin/python3"
        echo stdlib > "$unpack/lib/python3.12/os.py" ;;
      *" -m venv "*)
        mkdir -p "$previous/bin"
        ln -s "\(layout.python)/bin/python3.12" "$previous/bin/python" ;;
    esac
    exit 0
    """, mode: 0o755)
  let log = OwnerLog()
  var tools = system.tools
  tools.sudo = system.root + "/sudo"
  tools.chown = { path, uid, gid in
    log.owners.withLock { $0[path] = [uid, gid] }
    return 0
  }
  let pinned = "verified-archive"
  tools.pythonArchive = PythonArchive(
    url: "https://example.invalid/python.tar.gz", size: pinned.utf8.count,
    sha256: SHA256.hash(data: Data(pinned.utf8)).map { String(format: "%02x", $0) }.joined())
  let request = plan(
    port: chosen, runtime: .install(version: "0.31.3"),
    model: .directory(HostPath(absolute: system.root + "/weights")))
  return (system, tools, log, request)
}

/// How the stand-in `sudo` logs a run as the role account.
private func roleRun(_ layout: ManagedBackendLayout) -> String {
  "sudo -u _isoinference -- /usr/bin/env -i HOME=\(layout.cache) PATH=/usr/bin:/bin HF_HOME=\(layout.cache)/huggingface PIP_NO_CACHE_DIR=1 "
}

/// H1: `install` downloads the pinned standalone Python and the locked
/// wheels as the role account, never as root; root checks the archive,
/// owns the Python tree and the lock, and builds the venv on that Python.
@Test func installRunsPipAsTheRoleAccount() throws {
  let (system, tools, owners, request) = try installSystem(download: "verified-archive")
  defer { system.stop() }
  let layout = ManagedBackendLayout(name: mlxMain, prefix: system.prefix)
  try ManagedBackendProvisioner(tools: tools, prefix: system.prefix, log: { _ in })
    .provision(request)
  let calls = readFile(system.log) ?? ""
  let lines = calls.split(separator: "\n").map(String.init)
  let role = roleRun(layout)
  let download = layout.directory + "/python.download/python.tar.gz"
  #expect(
    lines.contains(
      role
        + "/usr/bin/curl --disable --fail --silent --show-error --location --proto =https --proto-redir =https --tlsv1.2 --max-filesize 16 --output \(download) https://example.invalid/python.tar.gz"
    ))
  // tar reads root's verified copy, never the role account's download.
  #expect(
    lines.contains(
      role
        + "/usr/bin/tar -x -z -f \(layout.directory)/python.tar.gz --strip-components 1 -C \(layout.directory)/python.staging"
    ))
  #expect(
    lines.contains(
      role + "\(layout.python)/bin/python3.12 -I -m venv \(layout.directory)/venv.staging"))
  let pip = try #require(lines.first { $0.contains(" -m pip install ") })
  #expect(pip.hasPrefix(role + "\(layout.directory)/venv.staging/bin/python -I -m pip install "))
  for flag in [
    "--require-hashes", "--no-deps", "--only-binary :all:", "--isolated",
    "--index-url https://pypi.org/simple", "-r \(layout.lock)",
  ] {
    #expect(pip.contains(" \(flag)"), "pip runs with \(flag)")
  }
  #expect(pip.hasSuffix(" -r \(layout.lock)"), "pip installs only what the lock names")
  #expect(!calls.contains("/usr/bin/python3"), "the system Python is not used")
  #expect(!calls.contains("token present"))
  #expect(readFile(layout.token) == token)

  // The lock and the Python tree are root's; the tree keeps its executable.
  #expect(readFile(layout.lock) == EmbeddedInference.mlxLMLock && mode(layout.lock) == 0o644)
  #expect(owners.owner(layout.lock) == [0, 0])
  let staged = layout.directory + "/python.staging"
  let tree = try ManagedBackendProvisioner.entries(under: layout.python)
  #expect(tree.count == 7)
  for (path, info) in tree {
    let relative = String(path.dropFirst(layout.python.count))
    #expect(owners.owner(staged + relative) == [0, 0], "\(relative) taken over")
    let expected: mode_t? =
      switch info.st_mode & S_IFMT {
      case S_IFLNK: nil
      case S_IFDIR: 0o755
      default: relative == "/bin/python3.12" ? 0o755 : 0o644
      }
    if let expected { #expect(mode(path) == expected, "\(relative)") }
  }
  #expect(!FileManager.default.fileExists(atPath: layout.directory + "/python.download"))
  #expect(!FileManager.default.fileExists(atPath: layout.directory + "/python.tar.gz"))

  // The job runs the venv on the standalone Python, confined to both.
  #expect(canonicalPath(layout.venv + "/bin/python") == layout.python + "/bin/python3.12")
  let document = try #require(
    try PropertyListSerialization.propertyList(
      from: Data(contentsOf: URL(fileURLWithPath: layout.plist)), format: nil) as? [String: Any])
  let arguments = try #require(document["ProgramArguments"] as? [String])
  #expect(arguments.contains("PYTHON=\(layout.venv)/bin/python"))
  #expect(arguments.contains("PYTHON_EXECUTABLE=\(layout.python)/bin/python3.12"))
  #expect(arguments.contains("PYTHON_PREFIX=\(layout.venv)"))
  #expect(arguments.contains("PYTHON_BASE_PREFIX=\(layout.python)"))
}

/// An archive that does not match the pinned SHA-256 is refused before
/// anything unpacks or runs it: no tar, no venv, no pip, no token, no job.
@Test func installChecksThePythonArchiveBeforeUnpackingIt() throws {
  // The pinned size, so the hash check is what refuses it.
  let (system, tools, _, request) = try installSystem(download: "tampered-archive")
  defer { system.stop() }
  let layout = ManagedBackendLayout(name: mlxMain, prefix: system.prefix)
  // A token left by an earlier provisioning is gone, and no new one is written.
  try writeFile(layout.token, "old")
  let error = try #require(throws: HostError.self) {
    try ManagedBackendProvisioner(tools: tools, prefix: system.prefix, log: { _ in })
      .provision(request)
  }
  #expect(error.message.contains("SHA-256"))
  let calls = readFile(system.log) ?? ""
  #expect(calls.contains(" /usr/bin/curl "))
  for step in [" /usr/bin/tar ", " -m venv ", " -m pip ", "launchctl bootstrap"] {
    #expect(!calls.contains(step), "\(step) never ran")
  }
  for path in [
    layout.token, layout.python, layout.venv, layout.directory + "/python.tar.gz",
    layout.directory + "/python.download",
  ] {
    #expect(!FileManager.default.fileExists(atPath: path), "\(path)")
  }
}

/// Root reads the role account's download only as one regular file of the
/// pinned size: not through a link, and not a second name for another file.
@Test func theDownloadMustBeOneRegularFileOfThePinnedSize() throws {
  let root = try scratchDirectory("download")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let archive = root + "/python.tar.gz"
  try writeFile(archive, "verified-archive")
  #expect(
    try ManagedBackendProvisioner.readDownload(archive, size: 16) == Array("verified-archive".utf8))
  for size in [15, 17] {
    #expect(throws: HostError.self) {
      try ManagedBackendProvisioner.readDownload(archive, size: size)
    }
  }
  symlink(archive, root + "/symbolic")
  #expect(throws: HostError.self) {
    try ManagedBackendProvisioner.readDownload(root + "/symbolic", size: 16)
  }
  mkfifo(root + "/fifo", 0o600)
  #expect(throws: HostError.self) {
    try ManagedBackendProvisioner.readDownload(root + "/fifo", size: 16)
  }
  link(archive, root + "/hard")
  #expect(throws: HostError.self) {
    try ManagedBackendProvisioner.readDownload(root + "/hard", size: 16)
  }
}

/// The provisioner's chmod never follows a final link.
@Test func theRestrictChmodDoesNotFollowLinks() throws {
  let root = try scratchDirectory("nofollow")
  defer { try? FileManager.default.removeItem(atPath: root) }
  try writeFile(root + "/outside", "secret", mode: 0o600)
  symlink(root + "/outside", root + "/link")
  _ = SystemTools().chmod(root + "/link", 0o644)
  #expect(mode(root + "/outside") == 0o600)
}
