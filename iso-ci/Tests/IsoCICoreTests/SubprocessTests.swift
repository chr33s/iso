import Foundation
import Testing

@testable import IsoCICore

/// A descendant that leaves the process group (like an ssh ProxyCommand)
/// can keep the output pipes open; `run` must still return promptly.
@Suite struct SubprocessTests {
  /// Starts a detached session leader that inherits stdout and stderr and
  /// outlives the shell by `seconds`.
  static func escapee(seconds: Int) -> String {
    "( /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); sleep \(seconds)' & )"
  }

  @Test func anEscapedDescendantDoesNotHoldAnExitedChild() throws {
    let started = Date()
    let output = try Subprocess.run(
      .init(
        executable: "/bin/sh", arguments: ["-c", "\(Self.escapee(seconds: 20)); echo done"],
        timeout: .seconds(30)))
    #expect(Date().timeIntervalSince(started) < 8)
    #expect(output.status == 0)
    #expect(!output.timedOut)
    #expect(String(decoding: output.stdout, as: UTF8.self) == "done\n")
  }

  @Test func aTimedOutChildReturnsDespiteAnEscapedDescendant() throws {
    let started = Date()
    let output = try Subprocess.run(
      .init(
        executable: "/bin/sh", arguments: ["-c", "\(Self.escapee(seconds: 20)); sleep 30"],
        timeout: .seconds(1)))
    #expect(Date().timeIntervalSince(started) < 8)
    #expect(output.timedOut)
  }

  /// An interactive child (`iso-ci debug`'s ssh) stays in the caller's
  /// process group, so it keeps the terminal; others get their own group.
  @Test(arguments: [Subprocess.ProcessGroup.own, .caller, .session])
  func spawnPlacesTheChildInTheRequestedGroup(_ group: Subprocess.ProcessGroup) throws {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    let devNull = open("/dev/null", O_RDWR | O_CLOEXEC)
    defer { close(devNull) }
    let pid = try Subprocess.spawn(
      "/bin/sh", ["-c", "/bin/ps -o pgid= -p $$"], [:], stdin: devNull, stdout: fds[1],
      stderr: devNull, group: group)
    close(fds[1])
    let output = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let pgid = Int32(
      String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    switch group {
    case .own, .session: #expect(pgid == pid)
    case .caller: #expect(pgid == getpgrp())
    }
  }
}

/// Remote hosts may be reachable only through the operator's SSH agent; the
/// socket path is the only addition to the base environment.
@Suite struct HostConnectionEnvironmentTests {
  @Test func onlyAnAbsoluteAgentSocketIsAdded() {
    let source = [
      "HOME": "/Users/x", "SSH_AUTH_SOCK": "/private/tmp/agent.sock", "AWS_SECRET": "s",
      "DYLD_INSERT_LIBRARIES": "/x",
    ]
    let env = Subprocess.hostConnectionEnvironment(source)
    #expect(env["SSH_AUTH_SOCK"] == "/private/tmp/agent.sock")
    #expect(env["AWS_SECRET"] == nil && env["DYLD_INSERT_LIBRARIES"] == nil)
    #expect(Subprocess.baseEnvironment(source)["SSH_AUTH_SOCK"] == nil)
    for bad in ["relative.sock", "/tmp/a\nb", ""] {
      #expect(Subprocess.hostConnectionEnvironment(["SSH_AUTH_SOCK": bad])["SSH_AUTH_SOCK"] == nil)
    }
  }
}

/// The runner launch script is generated per mode: every variant must parse.
@Suite struct RunnerBootstrapScriptTests {
  @Test func everyLaunchModeIsValidBash() throws {
    for mode: RunnerBootstrap.LaunchMode in [
      .connected(docker: true), .connected(docker: false),
      .preflight(docker: true, guestPort: 47_311), .preflight(docker: false, guestPort: 47_311),
    ] {
      let command = RunnerBootstrap.start(
        runnerDirectory: "/opt/actions-runner", jit: RedactedSecret("{}"), mode: mode)
      let script = try #require(command.argv.dropFirst(2).first)
      let output = try Subprocess.run(
        .init(executable: "/bin/bash", arguments: ["-n", "-c", script], timeout: .seconds(10)))
      #expect(output.succeeded, "\(mode): \(String(decoding: output.stderr, as: UTF8.self))")
      #expect(!script.contains("{}"), "JIT material must stay on stdin")
    }
    #expect(RunnerBootstrap.StartFailure.describe(6).contains("endpoint"))
    #expect(RunnerBootstrap.StartFailure.describe(42) == "the runner did not start (exit 42)")
  }
}
