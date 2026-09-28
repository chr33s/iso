import CoopConfiguration
import CoopCore
import Foundation
import Synchronization
import Testing

@testable import CoopHost

/// Scripted `coop-sandbox`: maps an argument vector to canned output and
/// records every call.
final class ScriptedRuntime: RuntimeExecutor {
  private let reply: @Sendable ([String]) -> Result<ProcessRunner.Output, RuntimeError>
  let calls = Mutex<[[String]]>([])

  init(_ reply: @escaping @Sendable ([String]) -> Result<ProcessRunner.Output, RuntimeError>) {
    self.reply = reply
  }

  func run(_ arguments: [String], deadline: Duration, outputLimit: Int, cancellable: Bool)
    throws(RuntimeError) -> ProcessRunner.Output
  {
    calls.withLock { $0.append(arguments) }
    return try reply(arguments).get()
  }

  func stream(
    _ arguments: [String], deadline: Duration?, cancellable: Bool,
    onOutput: (ProcessRunner.Stream, ArraySlice<UInt8>) throws -> Void
  ) throws -> ProcessRunner.Termination {
    let output = try run(arguments, deadline: deadline ?? .seconds(1), outputLimit: .max)
    try onOutput(.stdout, output.stdout[...])
    try onOutput(.stderr, output.stderr[...])
    return output.termination
  }

  static func ok(_ text: String) -> Result<ProcessRunner.Output, RuntimeError> {
    .success(.init(termination: .exited(0), stdout: Array(text.utf8), stderr: [], truncated: false))
  }

  static func failure(_ stderr: String) -> Result<ProcessRunner.Output, RuntimeError> {
    .success(
      .init(termination: .exited(1), stdout: [], stderr: Array(stderr.utf8), truncated: false))
  }
}

let qualifiedVersion =
  #"{"name":"coop-sandbox","version":"0.4.0","protocol":4,"containerization":"0.45.0"}"#

@Test func qualificationAcceptsOnlyTheValidatedRuntime() throws {
  let good = try RuntimeProtocol.parseVersion(Array(qualifiedVersion.utf8))
  #expect(try SandboxRuntime.qualify(good).hasPrefix("coop-sandbox 0.4.0"))
  for bad in [
    #"{"name":"container","version":"1","protocol":4,"containerization":"0.45.0"}"#,
    #"{"name":"coop-sandbox","version":"0.3.0","protocol":3,"containerization":"0.45.0"}"#,
    #"{"name":"coop-sandbox","version":"0.2.0","protocol":2,"containerization":"0.45.0"}"#,
    #"{"name":"coop-sandbox","version":"1","protocol":1,"containerization":"0.45.0"}"#,
    #"{"name":"coop-sandbox","version":"1","protocol":4,"containerization":"0.46.0"}"#,
  ] {
    #expect(throws: RuntimeError.self) {
      try SandboxRuntime.qualify(RuntimeProtocol.parseVersion(Array(bad.utf8)))
    }
  }
}

@Test func unqualifiedRuntimeIsKeptButRefusedForHandOut() throws {
  let executor = ScriptedRuntime { args in
    args == ["version"]
      ? ScriptedRuntime.ok(
        #"{"name":"coop-sandbox","version":"0","protocol":1,"containerization":"x"}"#)
      : ScriptedRuntime.ok("[]")
  }
  let runtime = SandboxRuntime(executor: executor, root: "/r", settings: .defaults)
  #expect(throws: RuntimeError.self) { try runtime.requireQualified() }
  // Read-only listing still works, for cleanup of owned resources.
  #expect(try runtime.list().isEmpty)
  #expect(executor.calls.withLock { $0 } == [["version"], ["list", "--root", "/r"]])
}

@Test func runtimeCallsPassTheRootAndCheckStatus() throws {
  let executor = ScriptedRuntime { args in
    switch args.first {
    case "version": ScriptedRuntime.ok(qualifiedVersion)
    case "image": ScriptedRuntime.failure("\u{1B}[31mno service\n")
    default: ScriptedRuntime.ok(#"[{"id":"coop-a","status":"crashed"}]"#)
    }
  }
  let runtime = SandboxRuntime(executor: executor, root: "/state/runtime", settings: .defaults)
  #expect(try runtime.requireQualified().contains("protocol 4"))
  #expect(try runtime.list() == [ListedSandbox(id: "coop-a", status: .crashed)])
  do {
    _ = try runtime.images()
    Issue.record("failure accepted")
  } catch {
    #expect(
      error == .failed("`coop-sandbox image list --root /state/runtime` failed: ?[31mno service"))
  }
}

@Test func realExecutorSanitizesEnvironmentAndBoundsOutput() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "coop-rt-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let script = directory + "/coop-sandbox"
  try Data(
    """
    #!/bin/sh
    case "$1" in
      env) env | sort ;;
      big) head -c 5000 /dev/zero ;;
      slow) sleep 10 ;;
    esac

    """.utf8
  ).write(to: URL(fileURLWithPath: script))
  chmod(script, 0o755)
  let executor = ProcessRuntimeExecutor(
    binary: script,
    parentEnvironment: [
      "HOME": "/h", "SSH_AUTH_SOCK": "/agent", "ANTHROPIC_API_KEY": "k", "PATH": "/project/bin",
      "LANG": "C",
    ])
  let env = String(
    decoding: try executor.run(["env"], deadline: .seconds(5), outputLimit: 4096).stdout,
    as: UTF8.self)
  let names = Set(env.split(separator: "\n").map { String($0.split(separator: "=")[0]) })
  #expect(
    names.isSubset(
      of: ProcessRuntimeExecutor.inheritedVariables.union(["PATH", "PWD", "SHLVL", "_"])))
  #expect(env.contains("PATH=/usr/bin:/bin:/usr/sbin:/sbin"))
  #expect(!env.contains("SSH_AUTH_SOCK") && !env.contains("ANTHROPIC_API_KEY"))
  #expect(throws: RuntimeError.self) {
    try executor.run(["big"], deadline: .seconds(5), outputLimit: 1000)
  }
  do {
    _ = try executor.run(["slow"], deadline: .milliseconds(200), outputLimit: 10)
    Issue.record("deadline ignored")
  } catch {
    guard case .operationUncertain = error else {
      Issue.record("expected uncertain outcome, got \(error)")
      return
    }
  }
}

@Test func binaryResolutionRefusesUntrustedLocations() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "coop-bin-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let binary = directory + "/coop-sandbox"
  try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: binary))
  chmod(binary, 0o755)
  let real = BinaryResolver.canonicalPath(binary)
  #expect(throws: RuntimeError.self) {
    try BinaryResolver.resolve(configured: "relative/coop-sandbox", defaults: [], tool: .runtime)
  }
  #expect(throws: RuntimeError.self) {
    try BinaryResolver.resolve(configured: directory + "/missing", defaults: [], tool: .runtime)
  }
  // Temporary directories live under sticky or user-owned parents.
  #expect(try BinaryResolver.resolve(configured: binary, defaults: [], tool: .runtime) == real)
  chmod(binary, 0o775)
  #expect(throws: RuntimeError.self) {
    try BinaryResolver.resolve(configured: binary, defaults: [], tool: .runtime)
  }
  chmod(binary, 0o644)
  #expect(throws: RuntimeError.self) {
    try BinaryResolver.resolve(configured: binary, defaults: [], tool: .runtime)
  }
  chmod(binary, 0o755)
  chmod(directory, 0o777)
  #expect(throws: RuntimeError.self) {
    try BinaryResolver.resolve(configured: binary, defaults: [], tool: .runtime)
  }
  chmod(directory, 0o755)
  // The configured path is the only candidate; defaults are not consulted.
  #expect(throws: RuntimeError.self) {
    try BinaryResolver.resolve(
      configured: directory + "/missing", defaults: [binary], tool: .runtime)
  }
  #expect(
    try BinaryResolver.resolve(
      configured: nil, defaults: [directory + "/missing", binary], tool: .runtime) == real)
}

@Test func untrustedDirectoryRules() {
  let me: uid_t = 501
  #expect(BinaryResolver.untrustedDirectory(mode: 0o755, owner: 0, group: 0, me: me) == nil)
  #expect(
    BinaryResolver.untrustedDirectory(mode: 0o755, owner: 502, group: 20, me: me)
      == "is owned by another user")
  #expect(BinaryResolver.untrustedDirectory(mode: 0o1777, owner: 0, group: 0, me: me) == nil)
  #expect(
    BinaryResolver.untrustedDirectory(mode: 0o757, owner: me, group: 20, me: me)
      == "is world-writable")
  #expect(
    BinaryResolver.untrustedDirectory(mode: 0o775, owner: me, group: 20, me: me)
      == "is group-writable")
  #expect(BinaryResolver.untrustedDirectory(mode: 0o775, owner: 0, group: 80, me: me) == nil)
}

@Test func canonicalPathKeepsAMissingTail() throws {
  let base = BinaryResolver.canonicalPath(FileManager.default.temporaryDirectory.path)
  #expect(
    BinaryResolver.canonicalPath(FileManager.default.temporaryDirectory.path + "/nope/deeper")
      == base + "/nope/deeper")
}
