import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private func temporaryDirectory() throws -> String {
  let path = FileManager.default.temporaryDirectory.appending(
    path: "iso-host-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return path
}

private func mode(_ path: String) -> mode_t {
  var status = stat()
  lstat(path, &status)
  return status.st_mode & 0o777
}

private func sh(_ script: String, deadline: Duration = .seconds(5), limit: Int = 1 << 20)
  throws(ProcessRunner.Failure)
  -> ProcessRunner.Output
{
  try ProcessRunner().capture(
    .init(
      executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"],
      deadline: deadline, outputLimit: limit))
}

// MARK: - ProcessRunner (S-03)

@Test func capturesBothStreamsAndExitStatus() throws {
  let output = try sh("printf out; printf err >&2; exit 3")
  #expect(output.termination == .exited(3))
  #expect(String(decoding: output.stdout, as: UTF8.self) == "out")
  #expect(String(decoding: output.stderr, as: UTF8.self) == "err")
  #expect(try sh("kill -TERM $$").termination == .signaled(SIGTERM))
}

@Test func largeInterleavedOutputDoesNotDeadlock() throws {
  // Each stream exceeds the pipe buffer; draining only one would block.
  let output = try sh(
    "head -c 300000 /dev/zero; head -c 300000 /dev/zero >&2; head -c 300000 /dev/zero")
  #expect(output.stdout.count == 600_000)
  #expect(output.stderr.count == 300_000)
}

@Test func deadlineKillsTheWholeProcessGroup() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let marker = directory + "/grandchild-survived"
  let start = ContinuousClock.now
  #expect(throws: ProcessRunner.Failure.timedOut) {
    try sh("(sleep 2; touch \(marker)) & sleep 30", deadline: .milliseconds(300))
  }
  #expect(ContinuousClock.now - start < .seconds(5))
  Thread.sleep(forTimeInterval: 2.5)
  #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test func inputReachesStdinAndIsClosed() throws {
  let big = [UInt8](repeating: UInt8(ascii: "x"), count: 300_000)
  let output = try ProcessRunner().capture(
    .init(
      executable: "/bin/sh", arguments: ["-c", "wc -c; head -c 300000 /dev/zero >&2"],
      environment: ["PATH": "/usr/bin:/bin"], deadline: .seconds(5), input: big))
  #expect(output.termination == .exited(0))
  #expect(
    String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespaces)
      .hasPrefix("300000"))
  // A child that never reads its input still finishes normally.
  let ignored = try ProcessRunner().capture(
    .init(
      executable: "/bin/sh", arguments: ["-c", "exit 4"], environment: [:],
      deadline: .seconds(5), input: big))
  #expect(ignored.termination == .exited(4))
}

@Test func attachedModeFeedsInputAndReportsStatus() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let file = directory + "/got"
  let termination = try ProcessRunner().attached(
    .init(
      executable: "/bin/sh", arguments: ["-c", "cat > '\(file)'; exit 5"],
      environment: ["PATH": "/usr/bin:/bin"], deadline: .seconds(5), input: Array("token".utf8)),
    inheritStdin: false, deadline: nil)
  #expect(termination == .exited(5))
  #expect(termination.description == "exit status: 5")
  #expect(ProcessRunner.Termination.signaled(9).description == "signal: 9 (SIGKILL)")
  #expect(try String(contentsOfFile: file, encoding: .utf8) == "token")
}

@Test func attachedModeKillsAChildAtItsDeadline() throws {
  let request = ProcessRunner.Request(
    executable: "/bin/sleep", arguments: ["30"], environment: [:], deadline: .seconds(30))
  let start = ContinuousClock.now
  #expect(throws: ProcessRunner.Failure.timedOut) {
    try ProcessRunner().attached(request, inheritStdin: false, deadline: .milliseconds(200))
  }
  #expect(ContinuousClock.now - start < .seconds(10))
}

@Test func remoteCommandEscapesArgumentsOnce() {
  let command = RemoteCommand().literal("tar xf - -C ").arg("/a b/it's").literal("/.git")
  #expect(command.rendered == "tar xf - -C '/a b/it'\\''s'/.git")
  #expect(InteractiveSSH.render([]) == "cd /workspace && exec $SHELL -l")
  #expect(InteractiveSSH.render(["echo", "$HOME"]) == "cd /workspace && 'echo' '$HOME'")
  #expect(InteractiveSSH.guestTerm(["TERM": "xterm-ghostty"]) == "xterm-256color")
  var env = EnvForward()
  env.set("OPENAI_API_KEY", Secret("sk-secret"))
  #expect(!env.description.contains("sk-secret"))
  #expect(env.sendEnvOptions == ["-o", "SendEnv=OPENAI_API_KEY"])
}

@Test func ownGroupChildrenAreRegisteredWhileTheyRun() throws {
  var seen: [pid_t] = []
  _ = try ProcessRunner().stream(
    .init(
      executable: "/bin/sh", arguments: ["-c", "echo $$"], environment: [:],
      deadline: .seconds(5)), deadline: .seconds(5)
  ) { _, bytes in
    if let pid = pid_t(
      String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    {
      seen.append(pid)
      #expect(ChildGroups.live.contains(pid))
    }
  }
  #expect(seen.count == 1)
  #expect(!ChildGroups.live.contains(seen[0]))
}

@Test func outputBeyondTheLimitFails() {
  #expect(throws: ProcessRunner.Failure.outputLimitExceeded) {
    try sh("head -c 5000 /dev/zero", limit: 4096)
  }
}

@Test func drainPolicyKeepsTheChildRunningAndFlagsTruncation() throws {
  let output = try ProcessRunner().capture(
    .init(
      executable: "/bin/sh", arguments: ["-c", "head -c 100000 /dev/zero; exit 7"],
      environment: [:], deadline: .seconds(5), outputLimit: 1000, overflow: .drain))
  #expect(output.termination == .exited(7))
  #expect(output.stdout.count == 1000)
  #expect(output.truncated)
}

@Test func childSeesOnlyTheExplicitEnvironmentAndNoExtraDescriptors() throws {
  setenv("ISO_TEST_AMBIENT", "leak", 1)
  defer { unsetenv("ISO_TEST_AMBIENT") }
  // Hold extra descriptors open in this process; none may reach the child.
  let held = (0..<4).map { _ in open("/dev/null", O_RDONLY) }
  defer { for fd in held { close(fd) } }
  let paths = held.map { "/dev/fd/\($0)" }.joined(separator: " ")
  let output = try sh(
    "printf '%s\\n' \"${ISO_TEST_AMBIENT-unset}\"; /bin/ls -d \(paths) 2>/dev/null")
  #expect(String(decoding: output.stdout, as: UTF8.self) == "unset\n")
  #expect(try sh("cat").stdout.isEmpty)  // stdin is /dev/null
}

@Test func spawnFailureIsReported() {
  #expect(throws: ProcessRunner.Failure.self) {
    try ProcessRunner().capture(
      .init(executable: "/nonexistent/bin", arguments: [], environment: [:], deadline: .seconds(1)))
  }
}

@Test func noDescriptorsLeakAcrossRuns() throws {
  func openDescriptors() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0
  }
  // Other tests run in parallel and briefly hold descriptors of their own,
  // so the count is noisy; a per-run leak of even one pipe end would add
  // 200+ across these runs. Settled readings (the lowest of a few) keep
  // the parallel noise well under the threshold.
  func settled() -> Int {
    (0..<5).map { _ in
      usleep(20_000)
      return openDescriptors()
    }.min() ?? 0
  }
  let before = settled()
  for _ in 0..<200 { _ = try sh("true") }
  for _ in 0..<5 { _ = try? sh("sleep 5", deadline: .milliseconds(20)) }
  #expect(settled() - before < 100)
}

// MARK: - Credential resolution

@Test func resolvesCommandReferencesJustInTime() throws {
  let resolver = CredentialResolver(environment: ["PATH": "/usr/bin:/bin"])
  #expect(try resolver.resolve(Secret("literal")).expose() == "literal")
  #expect(
    try resolver.resolve(Secret("cmd: printf '  synthetic-token \\n'")).expose()
      == "synthetic-token")
  #expect(throws: HostError("Empty command after 'cmd:' prefix")) {
    try resolver.resolve(Secret("cmd:   "))
  }
  #expect(throws: HostError.self) { try resolver.resolve(Secret("cmd:true")) }
  do {
    _ = try resolver.resolve(Secret("cmd:printf 'SYN''THETIC-OUT'; echo oops >&2; exit 4"))
    Issue.record("expected failure")
  } catch {
    #expect(error.message.contains("exit 4"))
    #expect(error.message.contains("oops"))
    #expect(!error.message.contains("SYNTHETIC-OUT"))
  }
  let reference = CredentialReference("cmd:printf ref-token")!
  #expect(try resolver.resolve(reference).expose() == "ref-token")
}

// MARK: - Atomic files and locks (S-04)

@Test func atomicWriteNeverWidensAnExistingMode() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/config.jsonc"
  try AtomicFile.write(Array("a".utf8), to: path, mode: .atMost(0o644))
  #expect(mode(path) == 0o644)
  chmod(path, 0o600)
  try AtomicFile.write(Array("b".utf8), to: path, mode: .atMost(0o644))
  #expect(mode(path) == 0o600)
  #expect(try String(contentsOfFile: path, encoding: .utf8) == "b")
  try AtomicFile.write(Array("c".utf8), to: path, mode: .preserveExisting(default: 0o644))
  #expect(mode(path) == 0o600)
  let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory).filter {
    $0.hasSuffix(".tmp")
  }
  #expect(leftovers.isEmpty)
}

@Test func atomicWriteTakesTheModeOfASymlinkTarget() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let target = directory + "/dotfiles-config"
  try Data("old".utf8).write(to: URL(fileURLWithPath: target))
  chmod(target, 0o600)
  for policy: AtomicFile.ModePolicy in [.atMost(0o644), .preserveExisting(default: 0o644)] {
    let link = directory + "/link-\(UUID().uuidString)"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    try AtomicFile.write(Array("new".utf8), to: link, mode: policy)
    // Replaced by a regular file (as Rust does) that keeps the target's mode.
    #expect(mode(link) == 0o600)
  }
}

@Test func failedAtomicWriteLeavesThePreviousFile() throws {
  let directory = try temporaryDirectory()
  defer {
    chmod(directory, 0o755)
    try? FileManager.default.removeItem(atPath: directory)
  }
  let path = directory + "/config.jsonc"
  try AtomicFile.write(Array("original".utf8), to: path, mode: .atMost(0o644))
  chmod(directory, 0o555)
  if getuid() != 0 {
    #expect(throws: HostError.self) {
      try AtomicFile.write(Array("new".utf8), to: path, mode: .atMost(0o644))
    }
  }
  chmod(directory, 0o755)
  #expect(try String(contentsOfFile: path, encoding: .utf8) == "original")
}

@Test func exclusiveCreateRefusesExistingEntriesAndSymlinks() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/new.jsonc"
  try AtomicFile.createExclusive(Array("x".utf8), at: path, mode: 0o600)
  #expect(mode(path) == 0o600)
  #expect(throws: HostError.self) {
    try AtomicFile.createExclusive(Array("y".utf8), at: path, mode: 0o600)
  }
  let link = directory + "/link.jsonc"
  symlink(directory + "/target-does-not-exist", link)
  #expect(throws: HostError.self) {
    try AtomicFile.createExclusive(Array("y".utf8), at: link, mode: 0o600)
  }
  #expect(!FileManager.default.fileExists(atPath: directory + "/target-does-not-exist"))
  #expect(try String(contentsOfFile: path, encoding: .utf8) == "x")
}

@Test func siblingLockUsesTheRustPathAndExcludesOtherHolders() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let target = directory + "/config.jsonc"
  let lock = try FileLock.sibling(of: target)
  #expect(FileManager.default.fileExists(atPath: directory + "/.config.jsonc.lock"))
  // A separate process (as the Rust host would be) cannot take the lock.
  let probe = try sh(
    "/usr/bin/python3 -c 'import fcntl,sys; f=open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)' \(directory)/.config.jsonc.lock"
  )
  #expect(probe.termination != .exited(0))
  lock.release()
  let after = try sh(
    "/usr/bin/python3 -c 'import fcntl,sys; f=open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX|fcntl.LOCK_NB)' \(directory)/.config.jsonc.lock"
  )
  #expect(after.termination == .exited(0))
}

// MARK: - Config store

@Test func templateCreationIsIdempotentAndNonDestructive() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/nested/config.jsonc"
  #expect(try ConfigStore.createTemplate(at: path, format: .jsonc))
  #expect(try String(contentsOfFile: path, encoding: .utf8) == ConfigTemplate.jsonc)
  try Data("{\"ssh_port\": 2}".utf8).write(to: URL(fileURLWithPath: path))
  #expect(try ConfigStore.createTemplate(at: path, format: .jsonc) == false)
  #expect(try String(contentsOfFile: path, encoding: .utf8) == "{\"ssh_port\": 2}")
}

@Test func strictJSONTemplateIsValidJSON() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/config.json"
  #expect(try ConfigStore.createTemplate(at: path, format: .json))
  let config = try ConfigLoader.load(.file(path: path, format: .json), environment: .empty)
  #expect(config.sshPort == 22)
}

@Test func concurrentProxyEditsAreAllRetained() async throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/config.jsonc"
  try Data("{\"ssh_port\": 2222} // keep".utf8).write(to: URL(fileURLWithPath: path))
  let environment = ConfigEnvironment(home: directory, variables: [:])
  try await withThrowingTaskGroup(of: Void.self) { group in
    for (index, provider) in [ProxyProvider.anthropic, .openai, .anthropic, .openai].enumerated() {
      group.addTask {
        try ConfigStore.upsertProxy(
          at: path, format: .jsonc, provider: provider,
          credential: CredentialReference("cmd:echo \(index)")!,
          auth: .bearer, environment: environment)
      }
    }
    try await group.waitForAll()
  }
  let config = try ConfigLoader.load(.file(path: path, format: .jsonc), environment: environment)
  #expect(config.sshPort == 2222)
  #expect(config.proxy.anthropic != nil)
  #expect(config.proxy.openai != nil)
  #expect(mode(path) == 0o644)
}

@Test func failedEditLeavesTheFileUntouched() throws {
  let directory = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let path = directory + "/config.jsonc"
  let original = "{\"proxy\": {\"openai\": \"not an object\"}}"
  try Data(original.utf8).write(to: URL(fileURLWithPath: path))
  #expect(throws: ConfigError.self) {
    try ConfigStore.upsertProxy(
      at: path, format: .jsonc, provider: .openai, credential: CredentialReference("cmd:x")!,
      auth: .bearer,
      environment: .empty)
  }
  #expect(try String(contentsOfFile: path, encoding: .utf8) == original)
}
