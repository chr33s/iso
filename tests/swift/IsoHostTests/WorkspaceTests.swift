import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

private let fakeSSH = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../fixtures/fake-ssh").standardized.path

private func scratch() throws -> String {
  let path = FileManager.default.temporaryDirectory.appending(path: "iso-ws-\(UUID().uuidString)")
    .path
  try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  return canonicalPath(path)!
}

private func instance(_ directory: String) throws -> Instance {
  Instance(
    name: try InstanceName("test"), index: InstanceIndex(1)!, directory: directory,
    image: try ImageName("default"))
}

private func target(knownHosts: String = "/state/known_hosts") throws -> SSHTarget {
  SSHTarget(
    host: "192.168.64.5", port: 22, user: .default, keyPath: "/data/vm key",
    knownHosts: knownHosts, alias: "iso-0a1b2c3d-00112233445566ff.iso")
}

private func transfer() -> WorkspaceTransfer {
  WorkspaceTransfer(
    client: SSHClient(environment: ["PATH": "\(fakeSSH):/usr/bin:/bin"]),
    diagnostics: Diagnostics(verbosity: 0, sink: { _ in }))
}

@Test func workspaceStateRoundTrips() throws {
  let directory = try scratch()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let state = WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: "/p/app"))
  try state.save(try instance(directory))
  let text = try String(contentsOfFile: directory + "/workspace.json", encoding: .utf8)
  #expect(
    try canonicalJSON(text)
      == canonicalJSON(
        "{\n  \"guest_path\": \"/workspace\",\n  \"source\": {\n    \"kind\": \"workspace\",\n    \"host_path\": \"/p/app\"\n  }\n}"
      ))
  #expect(try WorkspaceState.load(try instance(directory)) == state)
  try Data(
    #"{"guest_path":"/workspace","source":{"kind":"git_repo","url":"https://github.com/o/r"}}"#.utf8
  )
  .write(to: URL(fileURLWithPath: directory + "/workspace.json"))
  #expect(
    try WorkspaceState.load(try instance(directory))?.source
      == .gitRepo(url: "https://github.com/o/r"))
  try Data(#"{"guest_path":"rel","source":{"kind":"mount","host_path":"/x"}}"#.utf8)
    .write(to: URL(fileURLWithPath: directory + "/workspace.json"))
  #expect(throws: (any Error).self) { try WorkspaceState.load(try instance(directory)) }
}

@Test func mountSetsRejectWorkspaceCollisionsAndDuplicates() throws {
  let directory = try scratch()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let project = try Mount(host: directory, guest: guestWorkspace)
  let data = try Mount.parse("\(directory):/data")
  #expect(project.hostPath == directory)
  #expect(throws: (any Error).self) { try ValidatedMounts(.copyProject, [project]) }
  #expect(throws: (any Error).self) { try ValidatedMounts(.gitRepoClone, [project]) }
  #expect(throws: (any Error).self) {
    try ValidatedMounts(.projectMountedOrNone, [project, project])
  }
  #expect(try ValidatedMounts(.copyProject, [data]).mounts == [data])
  #expect(throws: (any Error).self) { try Mount.parse("/does/not/exist") }
  #expect(throws: (any Error).self) { try Mount.parse("\(directory):relative") }
}

@Test func sshConfigBlocksLeaveOtherNamespacesAlone() throws {
  let block = SSHConfigFile.block(try target(), try instance("/i"))
  #expect(
    block == """
      # iso START iso-test
      Host iso-test
          HostName 192.168.64.5
          Port 22
          User ubuntu
          IdentityFile "/data/vm key"
          IdentitiesOnly yes
          StrictHostKeyChecking yes
          UserKnownHostsFile /state/known_hosts
          GlobalKnownHostsFile /dev/null
          HostKeyAlias iso-0a1b2c3d-00112233445566ff.iso
          UpdateHostKeys no
          ForwardAgent no
          IdentityAgent none
          LogLevel ERROR
      # iso END
      """)
  let upstream =
    "# user-managed START\nHost user-test\n    HostName 172.16.0.2\n# user-managed END\n"
  #expect(SSHConfigBlocks.removeMarkerBlocks(upstream) == upstream)
  #expect(SSHConfigBlocks.removeMarkerBlocks(upstream + block + "\n") == upstream)
  #expect(
    SSHConfigBlocks.removeNamedMarkerBlock(upstream + block + "\n", host: "iso-other")
      == upstream
      + block + "\n")

  let directory = try scratch()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let file = SSHConfigFile(
    path: directory + "/.ssh/config", diagnostics: Diagnostics(verbosity: 0, sink: { _ in }))
  try file.refreshIfPresent(try target(), try instance(directory))
  #expect(!FileManager.default.fileExists(atPath: file.path))
  try file.update(try target(), try instance(directory))
  var status = stat()
  stat(file.path, &status)
  #expect(status.st_mode & 0o777 == 0o600)
  try file.update(try target(), try instance(directory))
  #expect(try String(contentsOfFile: file.path, encoding: .utf8) == block + "\n")
  try file.remove(try instance(directory))
  #expect(try String(contentsOfFile: file.path, encoding: .utf8) == "")
  try Data("Host iso-test\n".utf8).write(to: URL(fileURLWithPath: file.path))
  #expect(throws: (any Error).self) { try file.update(try target(), try instance(directory)) }
}

@Test func tarPipeCopiesTheProjectAndSkipsExcludes() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let source = root + "/src"
  let guest = root + "/guest"
  for path in ["\(source)/lib", "\(source)/node_modules/x", "\(source)/.git", guest] {
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }
  try Data("a".utf8).write(to: URL(fileURLWithPath: source + "/lib/a.txt"))
  try Data("b".utf8).write(to: URL(fileURLWithPath: source + "/node_modules/x/b"))
  try Data("c".utf8).write(to: URL(fileURLWithPath: source + "/.git/HEAD"))
  try transfer().tarPipe(try target(), source: source, to: GuestPath(guest), excludeGit: true)
  #expect(FileManager.default.fileExists(atPath: guest + "/lib/a.txt"))
  #expect(!FileManager.default.fileExists(atPath: guest + "/node_modules"))
  #expect(!FileManager.default.fileExists(atPath: guest + "/.git"))

  let back = root + "/back"
  try FileManager.default.createDirectory(atPath: back, withIntermediateDirectories: true)
  try transfer().tarPull(try target(), guest: GuestPath(guest), to: back, excludeGit: false)
  #expect(try String(contentsOfFile: back + "/lib/a.txt", encoding: .utf8) == "a")

  // A remote extraction failure reports the remote stderr.
  #expect {
    try transfer().tarPipe(
      try target(), source: source, to: GuestPath(root + "/missing/dir"), excludeGit: false)
  } throws: { error in
    "\(error)".contains("Remote stderr")
  }
}

@Test func forwardStateRoundTripsAndBusyPortsAreRefused() throws {
  let directory = try scratch()
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let diagnostics = Diagnostics(verbosity: 0, sink: { _ in })
  let forwards = [
    try PortForward(guest: 3000), try PortForward(guest: 8080, host: 9090, label: "api"),
  ]
  try PortForwards.save(forwards, try instance(directory), diagnostics: diagnostics)
  #expect(
    try canonicalJSON(String(contentsOfFile: directory + "/forwards.json", encoding: .utf8))
      == canonicalJSON(
        "{\n  \"forwards\": [\n    {\n      \"guest\": 3000,\n      \"host\": 3000\n    },\n    {\n      \"guest\": 8080,\n      \"host\": 9090,\n      \"label\": \"api\"\n    }\n  ]\n}"
      ))
  #expect(try PortForwards.load(try instance(directory)) == forwards)
  try PortForwards.save([], try instance(directory), diagnostics: diagnostics)
  #expect(!FileManager.default.fileExists(atPath: directory + "/forwards.json"))
  #expect(throws: (any Error).self) {
    try PortForwards.checkCollisions([
      try PortForward(guest: 1, host: 4000), try PortForward(guest: 2, host: 4000),
    ])
  }
  let fd = socket(AF_INET, SOCK_STREAM, 0)
  defer { close(fd) }
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  _ = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  listen(fd, 1)
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
  }
  let busy = UInt16(bigEndian: address.sin_port)
  #expect {
    try PortForwards.checkCollisions([try PortForward(guest: 80, host: busy)])
  } throws: { error in
    "\(error)".contains("Host port \(busy) is already in use")
  }
}

@Test func allocationPicksAvailableIndexAndName() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let config = try ConfigLoader.decode(
    .object(["data_dir": .string(root)]), path: "c", environment: .empty)
  let first = try Instance.allocate(
    config, name: nil, image: .default, workspacePath: "/src/my.project")
  #expect(first.name.rawValue == "my-project")
  #expect(first.index.value == 0)
  #expect(
    try canonicalJSON(String(contentsOfFile: first.directory + "/instance.json", encoding: .utf8))
      == canonicalJSON(
        "{\n  \"name\": \"my-project\",\n  \"index\": 0,\n  \"image\": \"default\"\n}"))
  let second = try Instance.allocate(
    config, name: nil, image: .default, workspacePath: "/other/my.project")
  #expect(second.name.rawValue == "my-project-2")
  #expect(second.index.value == 1)
  let unnamed = try Instance.allocate(config, name: nil, image: .default, workspacePath: nil)
  #expect(unnamed.name.rawValue == "2")
  #expect(throws: (any Error).self) {
    try Instance.allocate(
      config, name: try InstanceName("my-project"), image: .default, workspacePath: nil)
  }
  #expect(Instance.sanitizedBasename("") == "workspace")
  #expect(Instance.sanitizedBasename(String(repeating: "a", count: 80)).count == 60)
}

@Test func execDoesNotHandTheCallersStdinToTheGuest() throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(atPath: root) }
  let log = root + "/ssh.log"
  let client = SSHClient(environment: ["PATH": "\(fakeSSH):/usr/bin:/bin", "FAKE_SSH_LOG": log])
  try InteractiveSSH.exec(
    client,
    WorkloadSession(
      session: SSHSession(target: try target()), supervision: nil, revalidate: {}),
    ["sh", "-c", "cat > \(root)/stdin-seen"],
    diagnostics: Diagnostics(verbosity: 0, sink: { _ in }))
  #expect(try String(contentsOfFile: root + "/stdin-seen", encoding: .utf8) == "")
}

@Test func hugeDurationsSaturateInsteadOfTrapping() {
  #expect(Duration.seconds(Int64.max).milliseconds == .max)
  #expect(Duration.seconds(5).milliseconds == 5000)
}

@Test func guestTransportCarriesOnlyForwardedVariables() throws {
  let client = SSHClient(environment: [
    "PATH": "/usr/bin:/bin", "HOME": "/h", "LC_ALL": "C", "ANTHROPIC_API_KEY": "sk-raw",
    "GITHUB_TOKEN": "ghp-raw", "AWS_SECRET_ACCESS_KEY": "raw",
  ])
  #expect(client.environment == ["PATH": "/usr/bin:/bin", "HOME": "/h", "LC_ALL": "C"])
  // A user's own `SendEnv *` can send only what the child has: the
  // transport base plus what iso forwards on purpose.
  var forward = EnvForward()
  forward.set("OPENAI_API_KEY", Secret("capability"))
  let child = forward.overlay(client.environment)
  #expect(child["ANTHROPIC_API_KEY"] == nil && child["GITHUB_TOKEN"] == nil)
  #expect(child["OPENAI_API_KEY"] == "capability")
}

// MARK: - Staged pulls: transfer cap and stage lock

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = false
  var value: Bool {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}

/// Runs `body` on another thread while this one holds the stage lock, and
/// reports whether it finished, and whether the stage directory existed,
/// before the lock was released.
private func runWhileStageIsLocked(
  _ location: StageLocation, _ body: @escaping @Sendable () -> Void
) throws -> (finished: Bool, stageExisted: Bool) {
  let held = try location.lock()
  let finished = Flag()
  let done = DispatchSemaphore(value: 0)
  // A dedicated thread: the shared global pool can be starved by sibling
  // tests that block on subprocesses, delaying the body past the timeout.
  let worker = Thread {
    body()
    finished.value = true
    done.signal()
  }
  worker.start()
  Thread.sleep(forTimeInterval: 0.4)
  let early = (finished.value, location.exists)
  held.release()
  _ = done.wait(timeout: .now() + 20)
  return early
}

private func finishesWhileStageIsLocked(
  _ location: StageLocation, _ body: @escaping @Sendable () -> Void
) throws -> Bool {
  try runWhileStageIsLocked(location, body).finished
}

@Test func applyAndDiscardWaitForTheStageLock() throws {
  let directory = try scratch()
  defer { StageLocation.grantOwnerAccess(directory) }
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let inst = try instance(directory)
  let location = StageLocation(inst)
  try location.prepare()
  let transfer = transfer()
  let discarded = try finishesWhileStageIsLocked(location) {
    _ = try? transfer.discardStage(inst)
  }
  #expect(!discarded)
  #expect(!location.exists)

  try location.prepare()
  let destination = directory + "/dest"
  try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
  var builder = StageBuilder(tree: location.tree, destination: destination, limits: .defaults)
  try location.saveManifest(try builder.build(id: "00c0ffee", instance: "test", excludeGit: false))
  let applied = try finishesWhileStageIsLocked(location) {
    _ = try? transfer.applyStage(inst, stageID: nil, force: true)
  }
  #expect(!applied)
  #expect(!location.exists)
}

/// A guest workspace of ten 20 KiB files, a PATH of only the fake ssh and a
/// shim directory, and the transfer tool named by `viaRsync` lingering for
/// 6 s after it has sent everything, so only the growth watch can end the
/// pull early.
private func stagedPullTakes(viaRsync: Bool) throws -> (elapsed: Duration, error: (any Error)?) {
  let directory = try scratch()
  defer { StageLocation.grantOwnerAccess(directory) }
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let bin = directory + "/bin"
  try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    atPath: bin + "/which", withDestinationPath: "/usr/bin/which")
  func shim(_ name: String, _ script: String) throws {
    try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: URL(fileURLWithPath: bin + "/" + name))
    chmod(bin + "/" + name, 0o755)
  }
  try shim(
    "tar",
    """
    # The guest's GNU tar takes --sparse; the host's bsdtar does not.
    count=$#
    while [ "$count" -gt 0 ]; do
      arg=$1; shift; count=$((count - 1))
      [ "$arg" = --sparse ] || set -- "$@" "$arg"
    done
    if [ "$1" = cf ]; then /usr/bin/tar "$@"; status=$?; /bin/sleep 6; exit $status; fi
    exec /usr/bin/tar "$@"
    """)
  if viaRsync {
    try shim(
      "rsync",
      """
      for last; do source=$dest; dest=$last; done
      guest=${source#*:}
      /bin/cp -R "$guest". "$dest" && /bin/sleep 6
      """)
  }
  let guest = directory + "/guest"
  try FileManager.default.createDirectory(atPath: guest, withIntermediateDirectories: true)
  for index in 0..<10 {
    try Data(repeating: 0x61, count: 20 << 10).write(to: URL(fileURLWithPath: "\(guest)/f\(index)"))
  }
  let inst = try instance(directory + "/instance")
  try FileManager.default.createDirectory(atPath: inst.directory, withIntermediateDirectories: true)
  try WorkspaceState(guestPath: GuestPath(guest), source: .workspace(hostPath: directory + "/dest"))
    .save(inst)
  let transfer = WorkspaceTransfer(
    client: SSHClient(environment: ["PATH": "\(fakeSSH):\(bin)"]),
    diagnostics: Diagnostics(verbosity: 0, sink: { _ in }))
  let limits = StageLimits(
    maxFiles: 100, maxBytes: ByteCount(bytes: 64 << 10)!, maxFileBytes: ByteCount(bytes: 1 << 30)!)
  let location = StageLocation(inst)

  let outcome = Box<(any Error)?>(nil)
  let started = ContinuousClock.now
  let held = try runWhileStageIsLocked(location) {
    do {
      _ = try transfer.stage(
        instance: inst, target: try! target(), directory: nil, excludeGit: false, limits: limits)
    } catch { outcome.value = error }
  }
  #expect(!held.finished && !held.stageExisted)
  #expect(!location.exists)
  return (ContinuousClock.now - started, outcome.value)
}

@Test(arguments: [false, true])
func stagedTransferWaitsForTheLockAndStopsWhenItOutgrowsTheBudget(viaRsync: Bool) throws {
  let (elapsed, error) = try stagedPullTakes(viaRsync: viaRsync)
  #expect(elapsed < .seconds(5))
  let breach = try #require(error as? StageBudgetExceeded, "got \(String(describing: error))")
  #expect(breach.description.contains("max_bytes"))
}

private final class Box<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
