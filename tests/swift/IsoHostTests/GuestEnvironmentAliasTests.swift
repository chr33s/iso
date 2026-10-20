import Foundation
import IsoCore
import Testing

@testable import IsoHost

/// Runs `prepared.remote` the way sshd does: the login shell gets it with
/// `-c`, in an environment holding only what the client sent plus sshd's own
/// values. Returns stdout and the exit code.
private func runAsGuest(
  _ prepared: PreparedGuestCommand, shell: String, sent: [String: String]? = nil
) throws -> (stdout: String, code: Int32) {
  var environment = sent ?? prepared.environment([:])
  environment["SHELL"] = shell
  environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin"
  let output = try ProcessRunner().capture(
    .init(
      executable: shell, arguments: ["-c", prepared.remote], environment: environment,
      deadline: .seconds(20)))
  let code: Int32 =
    switch output.termination {
    case .exited(let code): code
    case .signaled: -1
    }
  return (String(decoding: output.stdout, as: UTF8.self), code)
}

private let guestShells = ["/bin/sh", "/bin/bash", "/bin/zsh"].filter {
  FileManager.default.isExecutableFile(atPath: $0)
}

@Test func requestedGuestNamesNeverReachTheHostEnvironment() throws {
  var env = EnvForward()
  for name in ["SHELL", "PATH", "HOME", "DYLD_INSERT_LIBRARIES", "SSH_ASKPASS", "GIT_SSH"] {
    env.set(name, Secret("guest-\(name)"))
  }
  let prepared = try env.prepare("true", terminal: .requested)
  let host = ["PATH": "/usr/bin:/bin", "HOME": "/Users/host", "SHELL": "/bin/zsh"]
  let child = prepared.environment(host.merging(["ISO_SSH_ENV_9": "stale"]) { $1 })
  #expect(child["PATH"] == "/usr/bin:/bin" && child["HOME"] == "/Users/host")
  #expect(child["SHELL"] == "/bin/zsh" && child["DYLD_INSERT_LIBRARIES"] == nil)
  #expect(child["ISO_SSH_ENV_9"] == nil)
  #expect(child["ISO_SSH_ENV_0"] == "guest-SHELL" && child["ISO_SSH_ENV_5"] == "guest-GIT_SSH")
  #expect(prepared.options.allSatisfy { $0 == "-o" || $0.hasPrefix("SendEnv=ISO_SSH_ENV_") })
  #expect(!prepared.options.contains("SendEnv=HOME"))
  #expect(!prepared.remote.contains("guest-"))
}

@Test func noRequestedVariablesLeavesTheCommandUnwrapped() throws {
  let prepared = try EnvForward().prepare("cd /workspace && ls", terminal: .requested)
  #expect(prepared.remote == "cd /workspace && ls" && prepared.options.isEmpty)
  #expect(prepared.environment(["PATH": "/bin"]) == ["PATH": "/bin"])
}

@Test(arguments: guestShells)
func guestRestoresExactValuesDespiteCollisions(shell: String) throws {
  var env = EnvForward()
  let values: [String: String] = [
    "EMPTY": "", "UNICODE": "héllo ✓", "QUOTES": #"it's "quoted" $HOME `x` \n"#,
    "NEWLINES": "a\nb\n", "ISO_SSH_ENV_1": "collides-with-alias",
    "ISO_SSH_ENV_0": "collides-too", "SHELL": "/guest/requested/shell",
  ]
  for name in values.keys.sorted() { env.set(name, Secret(values[name]!)) }
  let script =
    #"for n in EMPTY UNICODE QUOTES NEWLINES ISO_SSH_ENV_1 ISO_SSH_ENV_0 SHELL; do printf '%s=[%s]\n' "$n" "$(printenv "$n" | od -An -tx1 | tr -d ' \n')"; done"#
  let result = try runAsGuest(env.prepare(script, terminal: .requested), shell: shell)
  #expect(result.code == 0)
  let lines = result.stdout.split(separator: "\n")
  #expect(lines.count == 7)
  for line in lines {
    let name = String(line.prefix { $0 != "=" })
    let hex = line.dropFirst(name.count + 2).dropLast()
    // printenv appends one newline.
    let expected = (values[name] ?? "<missing>") + "\n"
    #expect(hex == expected.utf8.map { String(format: "%02x", $0) }.joined(), "\(name) in \(shell)")
  }
}

@Test(arguments: guestShells)
func theLoginShellRunsTheCommandEvenWhenTheGuestRequestsSHELL(shell: String) throws {
  var env = EnvForward()
  env.set("SHELL", Secret("/nonexistent/shell"))
  env.set("PATH", Secret("/guest/bin:/usr/bin:/bin"))
  let result = try runAsGuest(
    env.prepare(#"printf '%s|%s' "$SHELL" "$PATH""#, terminal: .requested), shell: shell)
  #expect(result.code == 0)
  #expect(result.stdout == "/nonexistent/shell|/guest/bin:/usr/bin:/bin")
}

@Test(arguments: guestShells)
func aMissingAliasAbortsBeforeTheWorkloadRuns(shell: String) throws {
  var env = EnvForward()
  env.set("A", Secret("1"))
  env.set("B", Secret(""))
  let prepared = try env.prepare("echo ran", terminal: .requested)
  // An sshd that refuses one alias: the command never runs, and the raw
  // name the guest might also have is not a fallback.
  let result = try runAsGuest(prepared, shell: shell, sent: ["ISO_SSH_ENV_0": "1", "B": ""])
  #expect(result.code == 125 && !result.stdout.contains("ran"))
  // An intentionally empty value still arrives.
  #expect(try runAsGuest(prepared, shell: shell).stdout == "ran\n")
}

@Test func aFailedAssignmentAbortsBeforeTheWorkloadRuns() throws {
  var env = EnvForward()
  env.set("PPID", Secret("1"))  // readonly in POSIX shells that enforce it
  env.set("EUID", Secret("0"))  // readonly in bash
  let prepared = try env.prepare("echo ran", terminal: .requested)
  for shell in guestShells {
    let remote = prepared.remote.replacingOccurrences(
      of: "exec /bin/sh -c", with: "exec /bin/bash -c")
    guard FileManager.default.isExecutableFile(atPath: "/bin/bash") else { return }
    let output = try ProcessRunner().capture(
      .init(
        executable: shell, arguments: ["-c", remote],
        environment: prepared.environment(["PATH": "/usr/bin:/bin", "SHELL": shell]),
        deadline: .seconds(20)))
    #expect(!output.termination.succeeded)
    #expect(!String(decoding: output.stdout, as: UTF8.self).contains("ran"))
  }
}

@Test func invalidOrOversizedEnvironmentsFailWithoutTheirValues() throws {
  func refusal(_ build: (inout EnvForward) -> Void) -> String? {
    var env = EnvForward()
    build(&env)
    do {
      _ = try env.prepare("true", terminal: .requested)
      return nil
    } catch { return "\(error)" }
  }
  let nul = refusal { $0.set("NUL", Secret("secret-a\0b")) }
  #expect(nul?.contains("NUL") == true && nul?.contains("secret-a") == false)
  #expect(refusal { $0.set("BAD-NAME", Secret("v")) } != nil)
  #expect(refusal { $0.set("BIG", Secret(String(repeating: "x", count: 8 * 1024))) } == nil)
  let big = refusal { $0.set("BIG", Secret("s" + String(repeating: "x", count: 8 * 1024))) }
  #expect(big?.contains("8192") == true && big?.contains("sxxx") == false)
  #expect(refusal { for i in 0..<64 { $0.set("V\(i)", Secret("")) } } == nil)
  #expect(refusal { for i in 0..<65 { $0.set("V\(i)", Secret("")) } }?.contains("64") == true)
  #expect(
    refusal { for i in 0..<9 { $0.set("V\(i)", Secret(String(repeating: "x", count: 8000))) } }?
      .contains("65536") == true)
}

@Test func aPTYAttachNormalizesARequestedTERMBeforeEncoding() throws {
  var env = EnvForward()
  env.set("TERM", Secret("xterm-ghostty"))
  let normalized = try env.prepare("true", terminal: .normalized("xterm-256color"))
  #expect(normalized.environment([:])["ISO_SSH_ENV_0"] == "xterm-256color")
  let requested = try env.prepare("true", terminal: .requested)
  #expect(requested.environment([:])["ISO_SSH_ENV_0"] == "xterm-ghostty")
}

@Test func launchPutsAliasOptionsBeforeTheAddressAndChecksTheHostLimit() throws {
  let target = SSHTarget(
    host: "127.0.0.1", port: 2222, user: .default, keyPath: "/k", knownHosts: "/kh", alias: "g")
  var env = EnvForward()
  env.set("HOME", Secret("/guest"))
  let launch = try env.prepare("ls", terminal: .requested).launch(
    target, base: ["HOME": "/Users/host"], pty: true)
  #expect(Array(launch.arguments.suffix(5).prefix(3)) == ["-e", "~", "-t"])
  #expect(launch.arguments.contains("SendEnv=ISO_SSH_ENV_0"))
  #expect(!launch.arguments.contains("SendEnv=HOME"))
  #expect(launch.environment["HOME"] == "/Users/host")
  #expect(launch.arguments.last?.hasPrefix("exec /bin/sh -c ") == true)
  let huge = String(repeating: "x", count: PreparedGuestCommand.hostArgumentLimit)
  #expect(throws: HostError.self) {
    try EnvForward().prepare(huge, terminal: .requested).launch(target, base: [:], pty: false)
  }
}

/// SSH-01: guest transports ignore ambient ssh configuration and, with the
/// shipped lookup, never take ssh/scp/rsync from `PATH`.
@Test func guestTransportsIgnoreAmbientConfigAndPathTools() throws {
  let target = SSHTarget(
    host: "127.0.0.1", port: 22, user: .default, keyPath: "/k", knownHosts: "/kh", alias: "g")
  let options = target.sshOptions
  #expect(zip(options, options.dropFirst()).contains { $0 == ("-F", "none") })
  #expect(options.contains("PermitLocalCommand=no") && options.contains("IdentityAgent=none"))
  #expect(try target.rsyncSSHCommand(ssh: "/usr/bin/ssh").contains(" -F none "))
  // scp's nested ssh is pinned, not chosen by PATH or scp's default.
  #expect(target.scpOptions(ssh: "/usr/bin/ssh").starts(with: ["-q", "-S", "/usr/bin/ssh"]))
  // A ProxyCommand runs under a fixed shell, not the caller's.
  #expect(SSHClient.transportEnvironment(["SHELL": "/opt/evil"])["SHELL"] == "/bin/sh")
  // rsync's `-e` grammar: a spaced known-hosts path is grouped intact; a
  // word it cannot carry is refused instead of being split.
  let spaced = SSHTarget(
    host: "127.0.0.1", port: 22, user: .default, keyPath: "/k", knownHosts: "/a b/kh", alias: "g")
  #expect(
    try spaced.rsyncSSHCommand(ssh: "/usr/bin/ssh").contains(" 'UserKnownHostsFile=\"/a b/kh\"' "))
  let quoted = SSHTarget(
    host: "127.0.0.1", port: 22, user: .default, keyPath: "/k'", knownHosts: "/kh", alias: "g")
  #expect(throws: HostError.self) { try quoted.rsyncSSHCommand(ssh: "/usr/bin/ssh") }
  let decoy = try scratchDirectory("decoy")
  try writeFile(decoy + "/ssh", "#!/bin/sh\n", mode: 0o755)
  let system = SSHClient(environment: ["PATH": decoy + ":/usr/bin"], tools: .system)
  #expect(system.sshExecutable() == "/usr/bin/ssh")
  #expect(system.executable(named: "scp") == "/usr/bin/scp")
  let doubles = SSHClient(environment: ["PATH": decoy + ":/usr/bin"], tools: .searchPath)
  #expect(doubles.sshExecutable() == decoy + "/ssh")
}

/// SSH-03: teardown with a missing control socket fails; it never dials the
/// guest to make a new connection.
@Test func controlTeardownNeverOpensANewConnection() throws {
  let target = SSHTarget(
    host: "192.0.2.1", port: 22, user: .default, keyPath: "/k", knownHosts: "/kh", alias: "g")
  let arguments = target.controlExitArguments("/nonexistent/iso-control")
  #expect(Array(arguments.prefix(2)) == ["-F", "none"] && arguments.contains("ControlMaster=no"))
  let start = ContinuousClock.now
  let output = try ProcessRunner().capture(
    .init(
      executable: "/usr/bin/ssh", arguments: arguments, environment: [:], deadline: .seconds(20)))
  #expect(!output.termination.succeeded)
  // A dial to the unroutable address would wait for its timeout instead.
  #expect(ContinuousClock.now - start < .seconds(5))
}
