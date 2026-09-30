import Darwin
import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private let token = String(repeating: "c", count: 64)
private let hostSources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../../Sources/IsoHost").standardized

private let mlxMain = try! ManagedBackendName("mlx-main")

private func plan(
  port: UInt16 = 18090, runtime: ManagedBackendConfig.Runtime, model: ManagedBackendConfig.Model,
  confinement: ManagedBackendConfig.Confinement = .seatbelt
) -> ManagedBackendPlan {
  ManagedBackendPlan(
    name: mlxMain, port: port, runtime: runtime, model: model, memoryLimitBytes: 8 << 30,
    confinement: confinement, token: Secret(token))
}

private func python() throws -> String {
  for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3"]
  where FileManager.default.isExecutableFile(atPath: candidate) {
    return candidate
  }
  throw HostError("no python3")
}

@Test func embeddedLauncherAndProfileMatchTheirFiles() throws {
  #expect(
    EmbeddedManagedBackend.launcher
      == (try #require(readFile(hostSources.appending(path: "inference-launcher.py").path))))
  #expect(
    EmbeddedManagedBackend.profile
      == (try #require(readFile(hostSources.appending(path: "seatbelt-inference-backend.sb").path)))
  )
  let profile = EmbeddedManagedBackend.profile
  #expect(profile.contains("(deny default)"))
  #expect(!profile.contains("network-outbound"), "the backend makes no outbound connections")
  #expect(profile.contains(#"(literal (param "PYTHON_EXECUTABLE")))"#))
  #expect(profile.contains(#"(string-append "localhost:" (param "PORT"))"#))
  #expect(!profile.contains(#""localhost:*""#), "the backend binds its own port only")
}

@Test func planRoundTripsAndRejectsTampering() throws {
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
    text.replacingOccurrences(of: "\"version\": 1", with: "\"version\": 1, \"extra\": 1"),
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
      import sys
      from http.server import BaseHTTPRequestHandler, HTTPServer
      token = open(sys.argv[2]).read().strip()
      class H(BaseHTTPRequestHandler):
          def do_GET(self):
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
        bootstrap) /usr/bin/python3 "\(root)/backend.py" \(port) "\(layout.token)" >/dev/null 2>&1 &
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
    mode(layout.launcher) == 0o644 && readFile(layout.launcher) == EmbeddedManagedBackend.launcher)
  #expect(mode(layout.cache) == 0o700 && mode(layout.logs) == 0o700)
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
  let runtime = try provisioner.inspect("/usr/bin/python3")
  #expect(runtime.executable.hasPrefix("/") && runtime.prefix == runtime.basePrefix)
}
