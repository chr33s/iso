import Foundation
import IsoConfiguration
import IsoCore
import Synchronization
import Testing

@testable import IsoHost

private let canary = "iso-editor-canary-must-not-leak"
private let callerSecrets = [
  "OPENAI_API_KEY": canary, "AWS_SECRET_ACCESS_KEY": canary, "SSH_AUTH_SOCK": "/tmp/agent.sock",
  "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "NODE_OPTIONS": "--require /tmp/x.js",
  "VSCODE_IPC_HOOK_CLI": "/tmp/x.sock", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
]

// MARK: - Launcher

@Test func unsafeLaunchersInheritNoCallerSecrets() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let dump = guest.root + "/env.dump"
  try writeFile(guest.root + "/editors/code", "#!/bin/sh\n/usr/bin/env > '\(dump)'\n", mode: 0o755)
  let running = try workloadRunning(guest, identity: nil)
  var environment = callerSecrets
  environment["PATH"] = guest.root + "/editors"
  try EditorLauncher(
    environment: environment, diagnostics: guest.sink.diagnostics,
    security: EditorConfig(security: .unsafe, allow: [])
  ).launch(
    running, SSHConnectionTarget(running, guestPath: guestWorkspace, egress: .open),
    choice: .only(VSCodeEditorProvider()), revalidate: {})
  let seen = try #require(readFile(dump))
  #expect(!seen.contains(canary))
  for name in ["SSH_AUTH_SOCK", "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "VSCODE_IPC_HOOK_CLI"] {
    #expect(!seen.contains(name + "="))
  }
  #expect(seen.contains("LANG=en_US.UTF-8"))
  #expect(guest.sink.text.contains("Editor security is 'unsafe'"))
}

@Test func aSandboxedLaunchNeverFallsBackToTheEditorCLI() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let log = guest.root + "/cli.log"
  try writeFile(guest.root + "/editors/zed", "#!/bin/sh\necho ran > '\(log)'\n", mode: 0o755)
  let running = try workloadRunning(guest, identity: nil)
  var launcher = EditorLauncher(
    environment: ["PATH": guest.root + "/editors"], diagnostics: guest.sink.diagnostics,
    home: guest.root + "/hosthome")
  launcher.locateApp = { _, _ in nil }
  let target = SSHConnectionTarget(running, guestPath: guestWorkspace, egress: .open)
  let missing = try #require(throws: HostFailure.self) {
    try launcher.launch(running, target, choice: .only(ZedEditorProvider()), revalidate: {})
  }
  #expect(missing.reason == .editorNotFound([.zed]))
  #expect("\(missing)".contains("/Applications/Zed.app"))

  // Failed verification stops even auto-detection.
  launcher.locateApp = { provider, _ in
    throw HostError("\(provider.displayName) failed verification")
  }
  #expect(throws: HostError("Visual Studio Code failed verification")) {
    try launcher.launch(
      running, target, choice: .firstAvailable(EditorProviderID.allCases.map(\.provider)),
      revalidate: {})
  }
  #expect(readFile(log) == nil)
}

@Test func aSandboxedLaunchRefusesALateHandoffFailureBeforeAnySetup() throws {
  let guest = try FakeGuest()
  defer { guest.remove() }
  let base = try workloadRunning(guest, identity: nil)
  let running = AppleBackend.Running(
    instance: base.instance, sidecar: base.sidecar, ready: base.ready,
    target: base.target.validating { throw HostError("readiness revoked") }, handoffIdentity: nil)
  var launcher = EditorLauncher(environment: guest.environment, diagnostics: guest.sink.diagnostics)
  launcher.locateApp = { _, _ in
    TrustedEditorApp(bundle: "/Applications/Zed.app", executable: "/nonexistent", version: "1")
  }
  #expect(throws: GuestHandoffFailure.self) {
    try launcher.launch(
      running, SSHConnectionTarget(running, guestPath: guestWorkspace, egress: .open),
      choice: .only(ZedEditorProvider()), revalidate: {})
  }
  #expect(guest.log("commands.log").isEmpty)
}

// MARK: - Trusted application

private func fakeBundle(_ root: String, version: String = "1.2.3") throws -> String {
  let bundle = root + "/Zed.app"
  try writeFile(bundle + "/Contents/MacOS/zed", "#!/bin/sh\n", mode: 0o755)
  try writeFile(
    bundle + "/Contents/Info.plist",
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
    <key>CFBundleShortVersionString</key><string>\(version)</string>
    </dict></plist>
    """)
  return bundle
}

@Test func editorAppsComeOnlyFromVerifiedBundles() throws {
  let root = try scratchDirectory("app")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let identity = ZedEditorProvider().bundleIdentity
  #expect(
    TrustedEditorApp.candidates(identity, home: "/Users/me") == [
      "/Applications/Zed.app", "/Users/me/Applications/Zed.app",
    ])
  #expect(try TrustedEditorApp.locate(identity, candidates: [root + "/none.app"]) == nil)

  let bundle = try fakeBundle(root + "/first")
  let second = try fakeBundle(root + "/second")
  let app = try TrustedEditorApp.locate(identity, candidates: [bundle, second]) { _, _ in }
  #expect(
    app
      == TrustedEditorApp(
        bundle: bundle, executable: bundle + "/Contents/MacOS/zed", version: "1.2.3"))

  // A failed signature check never falls through to the next copy.
  let checked = Mutex<[String]>([])
  #expect(throws: HostError("bad signature")) {
    _ = try TrustedEditorApp.locate(identity, candidates: [bundle, second]) { path, _ in
      checked.withLock { $0.append(path) }
      throw HostError("bad signature")
    }
  }
  #expect(checked.withLock { $0 } == [bundle])

  // The real verifier refuses an unsigned bundle.
  #expect(throws: HostError.self) { try CodeSignature.verify(bundle, identity) }
  #expect(identity.requirement.contains("certificate leaf[subject.OU] = \"MQ55VZLNZQ\""))

  // Writable by another user: refused before any signature check.
  chmod(bundle + "/Contents/MacOS/zed", 0o775)
  #expect(throws: HostError.self) {
    _ = try TrustedEditorApp.locate(identity, candidates: [bundle]) { _, _ in }
  }
  chmod(bundle + "/Contents/MacOS/zed", 0o755)
  chmod(bundle, 0o777)
  #expect(throws: HostError.self) {
    _ = try TrustedEditorApp.locate(identity, candidates: [bundle]) { _, _ in }
  }
}

// MARK: - Enclave

@Test func enclavesArePrivateShortLivedAndCarryNoCallerEnvironment() throws {
  let parent = try scratchDirectory("enc")
  defer { try? FileManager.default.removeItem(atPath: parent) }
  let enclave = try EditorEnclave.create(in: parent)
  for path in [enclave.root, enclave.home, enclave.temporary, enclave.data, enclave.ssh] {
    var status = stat()
    #expect(lstat(path, &status) == 0 && status.st_mode & 0o777 == 0o700)
  }
  let config = try enclave.sshConfigText(
    tunnelPort: 41234, user: .default, hostKeyAlias: "iso-0a1b.iso")
  for line in [
    "Host \(enclave.alias)", "HostName 127.0.0.1", "Port 41234", "IdentityFile \(enclave.identity)",
    "IdentitiesOnly yes", "IdentityAgent none", "ForwardAgent no", "StrictHostKeyChecking yes",
    "UserKnownHostsFile \(enclave.knownHosts)", "GlobalKnownHostsFile /dev/null",
    "HostKeyAlias iso-0a1b.iso", "BatchMode yes",
  ] {
    #expect(config.contains("    \(line)\n") || config.hasPrefix(line))
  }
  #expect(
    EditorEnclave.authorizedKey("ssh-ed25519 AAAA c", options: ["port-forwarding"])
      == "restrict,from=\"127.0.0.1,::1\",port-forwarding ssh-ed25519 AAAA c")

  var caller = callerSecrets
  caller["LC_CTYPE"] = "bad\u{1b}]value"
  let environment = enclave.environment(caller: caller)
  #expect(Set(environment.keys) == ["HOME", "TMPDIR", "PATH", "USER", "LOGNAME", "LANG", "LC_ALL"])
  #expect(environment["HOME"] == enclave.home && environment["TMPDIR"] == enclave.temporary + "/")
  #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")

  let key = try enclave.generateIdentity()
  #expect(key.hasPrefix("ssh-ed25519 ") && key.hasSuffix(" " + enclave.keyComment))
  enclave.remove()
  #expect(!FileManager.default.fileExists(atPath: enclave.root))

  // Unix socket paths inside the enclave must fit in sockaddr_un.
  let long = parent + "/" + String(repeating: "x", count: 60)
  try FileManager.default.createDirectory(atPath: long, withIntermediateDirectories: true)
  #expect(throws: HostError.self) { _ = try EditorEnclave.create(in: long) }
}

@Test func staleEnclavesAreRemovedOnlyWhenTheirOwnerIsGone() throws {
  let parent = try scratchDirectory("stale")
  defer { try? FileManager.default.removeItem(atPath: parent) }
  let live = try EditorEnclave.create(in: parent)
  let dead = try EditorEnclave.create(in: parent)
  try writeFile(dead.root + "/owner", "999999\n")
  EditorEnclave.removeStale(in: parent)
  #expect(FileManager.default.fileExists(atPath: live.root))
  #expect(!FileManager.default.fileExists(atPath: dead.root))
}

@Test func theSessionsDirectoryMustBePrivateToThisUser() throws {
  let base = try scratchDirectory("sessions")
  defer { try? FileManager.default.removeItem(atPath: base) }
  let path = try EditorEnclave.sessionsDirectory(base: base)
  #expect(path == base + "/iso-editor-\(getuid())")
  chmod(path, 0o755)
  #expect(throws: HostError.self) { _ = try EditorEnclave.sessionsDirectory(base: base) }
  try FileManager.default.removeItem(atPath: path)
  try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: base)
  #expect(throws: HostError.self) { _ = try EditorEnclave.sessionsDirectory(base: base) }
}

// MARK: - Seatbelt profile

private func policy(
  forward: UInt16? = nil, terminal: Bool = false, capabilities: [EditorHostCapability] = []
) -> EditorSandboxPolicy {
  EditorSandboxPolicy(
    tunnelPort: 41000, forwardPort: forward, terminal: terminal, machServicePrefix: "dev.zed.Zed.",
    capabilities: capabilities)
}

@Test func theEditorProfileIsDenyByDefaultAndWidensOnlyOnRequest() {
  let profile = policy().profile
  let lines = profile.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
  #expect(lines.contains("(deny default)"))
  for blanket in [
    "(allow default)", "(allow file-read*)", "(allow file*)", "(allow mach-lookup)",
    "(allow network-outbound)", "(allow process-exec*)", "(allow mach-register)",
  ] {
    #expect(!lines.contains(blanket))
  }
  for service in [
    "com.apple.pasteboard.1", "com.apple.lsd.mapdb", "com.apple.lsd.modifydb",
    "com.apple.coreservices.appleevents", "com.apple.SecurityServer", "com.apple.securityd.xpc",
    "com.apple.tccd", "com.apple.trustd.agent", "com.apple.mDNSResponder", "*:443", "/bin/sh",
    "/private/var/run/mDNSResponder", "pseudo-tty",
  ] {
    #expect(!profile.contains(service))
  }
  #expect(profile.contains(#"(remote ip "localhost:41000")"#))
  #expect(!profile.contains("localhost:*"))

  #expect(policy(capabilities: [.clipboard]).profile.contains("com.apple.pasteboard.1"))
  let internet = policy(capabilities: [.internet]).profile
  #expect(
    internet.contains(#"(remote tcp "*:443")"#) && internet.contains("com.apple.trustd.agent"))
  #expect(!internet.contains("pasteboard"))
  let terminal = policy(forward: 41001, terminal: true).profile
  #expect(terminal.contains(#"(literal "/bin/sh")"#))
  #expect(terminal.contains(#"(extension "com.apple.sandbox.pty")"#))
  #expect(terminal.contains(#"(local ip "localhost:41001")"#))
  #expect(
    EditorSandboxPolicy.parameters(app: "/A.app", session: "/s", prefix: "p.")
      == ["-D", "APP=/A.app", "-D", "SESSION=/s", "-D", "MACH_PREFIX=p."])
}

/// Real kernel enforcement, with `/bin` standing in for the editor bundle.
@Test func seatbeltConfinesTheEditorToItsSessionAndTunnel() throws {
  let root = try scratchDirectory("seat")
  defer { try? FileManager.default.removeItem(atPath: root) }
  let enclave = try EditorEnclave.create(in: root)
  try writeFile(enclave.root + "/inside", "inside\n")
  try writeFile(root + "/outside", canary)
  let tunnel = try Listener()
  let other = try Listener()
  let profile = EditorSandboxPolicy(
    tunnelPort: tunnel.port, forwardPort: nil, terminal: false, machServicePrefix: "x.",
    capabilities: []
  ).profile
  func confined(_ arguments: [String]) throws -> ProcessRunner.Output {
    try ProcessRunner().capture(
      .init(
        executable: "/usr/bin/sandbox-exec",
        arguments: ["-p", profile]
          + EditorSandboxPolicy.parameters(app: "/bin", session: enclave.root, prefix: "x.")
          + arguments,
        environment: ["PATH": "/bin"], workingDirectory: enclave.root, deadline: .seconds(30)))
  }
  let inside = try confined(["/bin/cat", enclave.root + "/inside"])
  #expect(inside.termination == .exited(0) && inside.stdout == Array("inside\n".utf8))
  let outside = try confined(["/bin/cat", root + "/outside"])
  #expect(outside.termination != .exited(0) && !outside.stdout.contains(Array(canary.utf8)))
  #expect(
    try confined(["/bin/cp", enclave.root + "/inside", root + "/copied"]).termination != .exited(0))
  #expect(!FileManager.default.fileExists(atPath: root + "/copied"))
  #expect(try confined(["/bin/sh", "-c", "/usr/bin/true"]).termination != .exited(0))
  func reaches(_ port: UInt16) throws -> Bool {
    try confined(["/bin/bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/\(port)"]).termination
      == .exited(0)
  }
  #expect(try reaches(tunnel.port))
  #expect(try !reaches(other.port))
}

/// A loopback listener whose connections complete in the backlog.
private final class Listener {
  let fd: Int32
  let port: UInt16

  init() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    self.fd = fd
    var address = SandboxedEditorSession.loopback(0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, length) == 0 && listen(fd, 16) == 0 && getsockname(fd, $0, &length) == 0
      }
    }
    guard ok else { throw HostError("listener failed") }
    port = UInt16(bigEndian: address.sin_port)
  }

  deinit { close(fd) }
}

// MARK: - Session lifecycle

/// Fake guest whose `ssh -L` listens on loopback, and a fake `sandbox-exec`
/// that records argv/env and acts per `editor-mode`: `quit` exits 0, a
/// number exits with it, anything else keeps running.
private struct SessionFixture {
  let guest: FakeGuest
  let running: AppleBackend.Running
  let sandboxExec: String
  let app: TrustedEditorApp

  init() throws {
    guest = try FakeGuest()
    running = try workloadRunning(guest, identity: nil)
    try writeFile(guest.root + "/known_hosts", "iso-test.iso ssh-ed25519 AAAA\n")
    try FileManager.default.moveItem(
      atPath: guest.root + "/bin/ssh", toPath: guest.root + "/bin/ssh.orig")
    try writeFile(
      guest.root + "/bin/ssh",
      #"""
      #!/bin/sh
      S="$(cd "$(dirname "$0")/.." && pwd)"
      prev=""
      for a in "$@"; do
        if [ "$prev" = "-L" ]; then
          port="${a#127.0.0.1:}"; port="${port%%:*}"
          echo $$ > "$S/tunnel.pid"
          exec /usr/bin/nc -lk 127.0.0.1 "$port"
        fi
        prev="$a"
      done
      exec "$S/bin/ssh.orig" "$@"
      """#, mode: 0o755)
    sandboxExec = guest.root + "/sandbox-exec"
    try writeFile(
      sandboxExec,
      """
      #!/bin/sh
      S='\(guest.root)'
      for a in "$@"; do printf '%s\\n' "$a"; done > "$S/sandbox.args"
      /usr/bin/env > "$S/sandbox.env"
      cp "$S/home/.ssh/authorized_keys" "$S/keys.during" 2>/dev/null
      echo $$ > "$S/editor.pid"
      mode=$(cat "$S/editor-mode" 2>/dev/null)
      case "$mode" in
        quit) sleep 1; exit 0 ;;
        [0-9]*) exit "$mode" ;;
        *) exec /bin/sleep 60 ;;
      esac
      """, mode: 0o755)
    let bundle = guest.root + "/Zed.app"
    app = TrustedEditorApp(
      bundle: bundle, executable: bundle + "/Contents/MacOS/zed", version: "1.0")
  }

  func session(revalidate: @escaping @Sendable () throws -> Void = {}) -> SandboxedEditorSession {
    var caller = guest.environment
    caller.merge(callerSecrets) { $1 }
    var session = SandboxedEditorSession(
      provider: ZedEditorProvider(), app: app, running: running,
      target: SSHConnectionTarget(running, guestPath: guestWorkspace, egress: .open),
      capabilities: [], ssh: guest.client, callerEnvironment: caller, hostHome: nil,
      diagnostics: guest.sink.diagnostics, revalidate: revalidate)
    session.supervision = .milliseconds(100)
    session.enclaveParent = { [root = guest.root] in root + "/s" }
    session.sandboxExec = sandboxExec
    return session
  }

  var enclaves: [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: guest.root + "/s")) ?? []
  }

  func editorAlive() -> Bool {
    guard let text = readFile(guest.root + "/editor.pid"),
      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    else { return false }
    return kill(pid, 0) == 0
  }

  func mode(_ value: String) throws { try writeFile(guest.root + "/editor-mode", value) }
}

@Test func aSandboxedSessionAuthorizesConfinesAndCleansUp() throws {
  let fixture = try SessionFixture()
  defer { fixture.guest.remove() }
  try FileManager.default.createDirectory(
    atPath: fixture.guest.root + "/s", withIntermediateDirectories: true)
  try fixture.mode("quit")
  try fixture.session().run()

  let arguments = fixture.guest.log("sandbox.args")
  #expect(arguments.first == "-p")
  // The profile is one multi-line argument.
  #expect(arguments.contains("(deny default)"))
  #expect(arguments.contains("APP=\(fixture.app.bundle)"))
  #expect(arguments.contains("MACH_PREFIX=dev.zed.Zed."))
  let executable = try #require(arguments.firstIndex(of: fixture.app.executable))
  #expect(arguments[(executable + 1)...].first == "--user-data-dir")
  #expect(arguments.last?.hasPrefix("ssh://iso-editor-") == true)

  let environment = fixture.guest.log("sandbox.env").joined(separator: "\n")
  #expect(!environment.contains(canary) && !environment.contains("SSH_AUTH_SOCK"))
  #expect(environment.contains("HOME=\(fixture.guest.root)/s/iso-ed-"))

  // Key authorized during the session, revoked after; enclave removed.
  let during = readFile(fixture.guest.root + "/keys.during") ?? ""
  #expect(during.contains("restrict,from=\"127.0.0.1,::1\" ssh-ed25519 "))
  #expect(during.contains(" iso-editor-"))
  #expect(!(fixture.guest.guestFile(".ssh/authorized_keys") ?? "").contains("iso-editor-"))
  #expect(fixture.enclaves.isEmpty)
  #expect(!fixture.editorAlive())
}

@Test func aLostReadinessProofEndsTheEditorSession() throws {
  let fixture = try SessionFixture()
  defer { fixture.guest.remove() }
  try FileManager.default.createDirectory(
    atPath: fixture.guest.root + "/s", withIntermediateDirectories: true)
  let healthy = Mutex(true)
  let start = ContinuousClock.now
  Thread.detachNewThread {
    Thread.sleep(forTimeInterval: 1)
    healthy.withLock { $0 = false }
  }
  let error = try #require(throws: GuestHandoffFailure.self) {
    try fixture.session {
      guard healthy.withLock({ $0 }) else { throw HostError("instance 'test' stopped") }
    }.run()
  }
  #expect("\(error)".contains("readiness proof no longer holds"))
  #expect(ContinuousClock.now - start < .seconds(15))
  #expect(!fixture.editorAlive())
  #expect(fixture.enclaves.isEmpty)
  #expect(!(fixture.guest.guestFile(".ssh/authorized_keys") ?? "").contains("iso-editor-"))
}

@Test func aFailedEditorOrClosedTunnelEndsTheSession() throws {
  let fixture = try SessionFixture()
  defer { fixture.guest.remove() }
  try FileManager.default.createDirectory(
    atPath: fixture.guest.root + "/s", withIntermediateDirectories: true)
  try fixture.mode("3")
  let failed = try #require(throws: HostFailure.self) { try fixture.session().run() }
  #expect(failed.reason == .editorLaunchFailed(.zed))
  #expect(fixture.enclaves.isEmpty)

  try fixture.mode("run")
  Thread.detachNewThread { [root = fixture.guest.root] in
    Thread.sleep(forTimeInterval: 1)
    if let text = readFile(root + "/tunnel.pid"),
      let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      kill(pid, SIGKILL)
    }
  }
  #expect(throws: HostError("The SSH tunnel to instance 'dev' closed; the editor session ended")) {
    try fixture.session().run()
  }
  #expect(!fixture.editorAlive())
  #expect(fixture.enclaves.isEmpty)
}
