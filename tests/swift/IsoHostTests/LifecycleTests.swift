import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

// Throwaway keys generated with `ssh-keygen -t ed25519` (shared with the Rust tests).
private let key =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINiqkOnkRV06x+SuorkF+O3KdBTVFznIV0+b58cidW1N root@guest"
private let otherKey =
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKB2Bohi4Rqvfx9oW+/9UovsYrOdYeFuWqvUuZpjig+1 x"

@Test func hostKeysParseAndFingerprintLikeSSHKeygen() throws {
  #expect(
    try HostPublicKey(parsing: key).fingerprint
      == "SHA256:10O2vYbKkmA/sBuRrfwbSNiR5pAFM/qtkqldbUJESvk")
  #expect(try HostPublicKey(parsing: "\n  \(key)  \n\n").base64.hasPrefix("AAAAC3"))
  for bad in [
    "", "\(key)\n\(key)", "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ== x", "ssh-ed25519 not*base64",
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5", "ssh-ed25519",
  ] {
    #expect(throws: RuntimeError.self) { try HostPublicKey(parsing: bad) }
  }
  do {
    _ = try HostPublicKey(parsing: "ssh-rsa AAAA x")
  } catch {
    #expect(
      error.description
        == "APPLE_HOST_KEY_CHANGED: guest host public key has type \"ssh-rsa\", not ssh-ed25519")
  }
  #expect(lenientBase64Decode("Zm9v") == Array("foo".utf8))
  #expect(lenientBase64Decode("Zg==") == Array("f".utf8))
  #expect(lenientBase64Decode("Zg") == Array("f".utf8))
  #expect(lenientBase64Decode("Z!") == nil)
}

@Test func enrollOnceThenThePinIsEnforced() throws {
  let directory = FileManager.default.temporaryDirectory.appending(
    path: "iso-pin-\(UUID().uuidString)"
  ).path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: directory) }
  let instance = Instance(
    name: try InstanceName("t"), index: InstanceIndex(0)!, directory: directory, image: .default)
  let machine = try MachineName("iso-0a1b2c3d-00112233445566ff")
  let parsed = try HostPublicKey(parsing: key)
  #expect(throws: RuntimeError.self) {
    try HostKeyPin.apply(.requirePin, instance: instance, machine: machine, key: parsed)
  }
  try HostKeyPin.apply(.enroll, instance: instance, machine: machine, key: parsed)
  var status = stat()
  lstat(instance.knownHostsPath, &status)
  #expect(status.st_mode & 0o777 == 0o600)
  #expect(
    try String(contentsOfFile: instance.knownHostsPath, encoding: .utf8)
      == "iso-0a1b2c3d-00112233445566ff.iso ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINiqkOnkRV06x+SuorkF+O3KdBTVFznIV0+b58cidW1N\n"
  )
  try HostKeyPin.apply(.requirePin, instance: instance, machine: machine, key: parsed)
  #expect(throws: RuntimeError.self) {
    try HostKeyPin.apply(.enroll, instance: instance, machine: machine, key: parsed)
  }
  let other = try HostPublicKey(parsing: otherKey)
  #expect(throws: RuntimeError.self) {
    try HostKeyPin.apply(.requirePin, instance: instance, machine: machine, key: other)
  }
  try HostKeyPin.apply(.reenrollAfterRestore, instance: instance, machine: machine, key: other)
  try HostKeyPin.apply(.requirePin, instance: instance, machine: machine, key: other)
}

@Test func buildContextIsDeterministicAndHashesEveryInput() throws {
  let profiles = [try Profiles.lookup("rust", config: try emptyConfig())]
  let a = BuildContext.render(publicKey: key, profiles: profiles, guestUser: .default)
  let b = BuildContext.render(publicKey: key, profiles: profiles, guestUser: .default)
  #expect(a == b)
  let id = a.manifestID(guestUser: .default, publicKeyFingerprint: "SHA256:x")
  #expect(id.count == 64)
  #expect(id == b.manifestID(guestUser: .default, publicKeyFingerprint: "SHA256:x"))
  #expect(id != a.manifestID(guestUser: try GuestUser("dev"), publicKeyFingerprint: "SHA256:x"))
  #expect(id != a.manifestID(guestUser: .default, publicKeyFingerprint: "SHA256:y"))
  let other = BuildContext.render(publicKey: otherKey, profiles: profiles, guestUser: .default)
  #expect(id != other.manifestID(guestUser: .default, publicKeyFingerprint: "SHA256:x"))
  #expect(
    a.files.map(\.name) == [
      "Dockerfile", "provision.sh", "machine-setup.sh", "iso-ssh-hostkeys.service", "10-iso.conf",
    ])
  let provision = a.files[1].content
  #expect(provision.contains("echo '\(key)' > \"/home/ubuntu/.ssh/authorized_keys\""))
  #expect(provision.contains("rustup"))
  #expect(
    BuildContext.imageRef(
      owner: try OwnerID(String(repeating: "a", count: 32)), manifestID: id, buildID: "01234567")
      == "local/iso-aaaaaaaa:\(id.prefix(16))-01234567")
}

@Test(arguments: [0, 42]) func imageAPTCommandsExposeProgressAndBoundRepositoryReads(
  aptExit: Int
) throws {
  let context = BuildContext.render(publicKey: key, profiles: [], guestUser: .default)
  let dockerfile = try #require(context.files.first { $0.name == "Dockerfile" }?.content)
  let provision = try #require(context.files.first { $0.name == "provision.sh" }?.content)
  let options =
    "-o Acquire::Retries=2 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30"
  #expect(dockerfile.contains("apt-get \(options) update;"))
  #expect(dockerfile.contains("apt-get \(options) install -y --no-install-recommends"))
  #expect(!dockerfile.contains("-qq"))

  let start = try #require(provision.range(of: "echo '  [guest] Updating package lists...'"))
  let end = try #require(provision[start.lowerBound...].range(of: " < /dev/null\n"))
  let header = provision.components(separatedBy: "\n").prefix(6).joined(separator: "\n")
  let stub = "apt-get() { printf '<%s>\\n' \"$@\"; return \(aptExit); }\n"
  let script = header + "\n" + stub + provision[start.lowerBound..<end.upperBound]
  let output = try ProcessRunner().capture(
    .init(
      executable: "/bin/bash", arguments: [], environment: [:], deadline: .seconds(5),
      input: Array(script.utf8)))
  #expect(output.termination == .exited(Int32(aptExit)))
  let arguments = String(decoding: output.stdout, as: UTF8.self)
  let calls = aptExit == 0 ? 2 : 1
  for option in ["Acquire::Retries=2", "Acquire::http::Timeout=30", "Acquire::https::Timeout=30"] {
    #expect(arguments.components(separatedBy: "<\(option)>").count - 1 == calls)
  }
  #expect(arguments.contains("<update>"))
  #expect(arguments.contains("<install>") == (aptExit == 0))
  #expect(!arguments.contains("<-qq>"))
}

private func emptyConfig(_ extra: String = "") throws -> IsoConfig {
  try ConfigLoader.decode(
    ConfigLoader.parse(Array("{\(extra)}".utf8), format: .jsonc, path: "c", limits: .configuration),
    path: "c",
    environment: .empty)
}

// MARK: - End to end against the stateful fake runtime

private let fakes = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .appending(path: "../../fixtures/fake-runtime").standardized

/// A private installation driven by `tests/fixtures/fake-runtime` and a
/// no-op `ssh`, with its own key and owner.
private struct FakeInstallation {
  let root: String
  let config: IsoConfig
  let backend: AppleBackend

  init(extra: String = "") throws {
    root = BinaryResolver.canonicalPath(
      FileManager.default.temporaryDirectory.appending(path: "iso-e2e-\(UUID().uuidString)").path)
    let bin = root + "/bin"
    try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
    for tool in ["iso-sandbox", "container"] {
      try FileManager.default.copyItem(
        atPath: fakes.appending(path: tool).path, toPath: bin + "/" + tool)
      chmod(bin + "/" + tool, 0o755)
    }
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: bin + "/ssh"))
    chmod(bin + "/ssh", 0o755)
    try Data("kernel".utf8).write(to: URL(fileURLWithPath: root + "/kernel"))
    config = try emptyConfig(
      #""data_dir": "\#(root)/data", "apple_container": {"binary": "\#(bin)/iso-sandbox", "builder": "\#(bin)/container", "kernel": "\#(root)/kernel", "boot_timeout_seconds": 5}"#
        + extra)
    backend = AppleBackend(
      config: config,
      environment: [
        "HOME": root, "PATH": "\(bin):/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory(),
      ],
      executable: nil)
  }

  func calls() -> [[String]] {
    let log = root + "/bin/calls.log"
    defer { try? FileManager.default.removeItem(atPath: log) }
    guard let text = try? String(contentsOfFile: log, encoding: .utf8) else { return [] }
    return rustLines(text).compactMap {
      try? JSONDecoder().decode([String].self, from: Data($0.utf8))
    }
  }

  func remove() { try? FileManager.default.removeItem(atPath: root) }
}

@Test func bootstrapCompletionDoesNotAdoptAReplacementProof() throws {
  let install = try FakeInstallation()
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  let instance = try Instance.allocate(
    install.config, name: InstanceName("completion"), image: .default, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  let running = try #require(try backend.asBootstrapRunning(instance))
  let healthy = try backend.completeBootstrap(running)
  #expect(healthy.ready == running.ready)
  let preparation = AppleBackend.Running(
    instance: instance, sidecar: running.sidecar, ready: running.ready, target: running.target,
    handoffIdentity: .init(
      policy: .init(bootID: "original-boot", policyHash: "original-policy"),
      egressKey: "original-egress", brokerKeys: [:]))
  #expect(throws: HostError.self) { _ = try backend.completeBootstrap(preparation) }
}

@Test func createStopStartAndDestroyAgainstTheFakeRuntime() throws {
  let install = try FakeInstallation()
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  _ = install.calls()

  let directory = install.config.instancesDirectory.appending("proj").path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("proj"), index: InstanceIndex(0)!, directory: directory, image: .default)
  try instance.save()
  try backend.createAndStart(instance, diskGiB: nil)
  let created = install.calls().map { $0.first ?? "" }
  #expect(created.contains("create") && created.contains("start"))
  #expect(try Journal.loadIfPresent(instance) == nil)
  let sidecar = try #require(try MachineSidecar.loadIfPresent(instance))
  #expect(sidecar.hostKeyFingerprint == "SHA256:10O2vYbKkmA/sBuRrfwbSNiR5pAFM/qtkqldbUJESvk")
  #expect(sidecar.lastObservedOwnerPID == 4242)
  #expect(FileManager.default.fileExists(atPath: instance.knownHostsPath))

  let running = try #require(try backend.asRunning(instance))
  #expect(running.target.hostKeyOptions.contains("HostKeyAlias=\(sidecar.machineID).iso"))
  guard case .running = try backend.probeHealth(instance) else {
    Issue.record("an open running instance has no readiness proof to fail")
    return
  }
  #expect(throws: (any Error).self) { try backend.createAndStart(instance, diskGiB: nil) }
  #expect(throws: (any Error).self) { try backend.startExisting(instance) }

  try backend.stop(running)
  #expect(try backend.asRunning(instance) == nil)
  try backend.startExisting(instance)
  #expect(try backend.asRunning(instance) != nil)

  try backend.destroyInstance(instance)
  #expect(!FileManager.default.fileExists(atPath: directory))
  #expect(try backend.runtime().list().isEmpty)
}

@Test func filteredReadinessFailureIsUnhealthyWhileGateFailuresStayErrors() throws {
  let install = try FakeInstallation(extra: #", "egress": "filtered""#)
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  let instance = try Instance.allocate(
    install.config, name: InstanceName("health"), image: .default, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)

  // No companion was started for this boot: the readiness proof fails.
  let failure = try #require(throws: InstanceUnhealthy.self) { try backend.asRunning(instance) }
  #expect(failure.instance == instance.name)
  #expect(failure.reason.hasPrefix("FILTERED_EGRESS_NOT_READY: "))
  #expect(
    "\(failure)".hasPrefix(
      "Instance 'health' is running but cannot be reached safely; `iso stop health`"))
  guard case .unhealthy(let listed) = try backend.probeHealth(instance) else {
    Issue.record("a running filtered instance without readiness must list as unhealthy")
    return
  }
  #expect(listed.reason == failure.reason)

  // A changed allowlist is a policy error, not a readiness failure.
  let changed = backend.reconfigured(
    install.config.overridingEgress(.filtered, extraHosts: [try ExactHostname("example.com")]))
  #expect(throws: ContextError.self) { try changed.asRunning(instance) }

  // A different egress mode is a policy error for the listing too.
  let unfiltered = backend.reconfigured(install.config.overridingEgress(.open, extraHosts: []))
  #expect(throws: HostError.self) { try unfiltered.probeHealth(instance) }
  #expect(throws: (any Error).self) { try changed.probeHealth(instance) }
  _ = try backend.runtime().stop(try MachineSidecar.load(instance).machineID)
  guard case .stopped = try backend.probeHealth(instance) else {
    Issue.record("a stopped instance lists as stopped")
    return
  }
}

@Test func stoppedBootReplacesAllowlistOnlyAfterSuccessfulBoot() throws {
  let install = try FakeInstallation(extra: #", "egress": "filtered""#)
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  let instance = try Instance.allocate(
    install.config, name: InstanceName("policy"), image: .default, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  let original = try #require(try NetworkPolicy.load(instance))
  let changed = install.config.overridingEgress(
    .filtered, extraHosts: [try ExactHostname("example.com")])
  let updated = backend.reconfigured(changed)
  #expect(throws: HostError.self) { try NetworkPolicy.enforce(instance, config: changed) }
  #expect(throws: HostError.self) { try updated.startExisting(instance) }
  #expect(try NetworkPolicy.load(instance) == original)
  let sidecar = try MachineSidecar.load(instance)
  let runtime = try backend.runtime()
  let statePath = runtime.root + "/fake-state.json"
  let stateBytes = try Data(contentsOf: URL(fileURLWithPath: statePath))
  let state = try #require(JSONSerialization.jsonObject(with: stateBytes) as? [String: Any])
  for status in ["crashed", "booting"] {
    var changedState = state
    var sandboxes = try #require(state["sandboxes"] as? [String: [String: Any]])
    sandboxes[sidecar.machineID.rawValue]?["status"] = status
    changedState["sandboxes"] = sandboxes
    try JSONSerialization.data(withJSONObject: changedState).write(
      to: URL(fileURLWithPath: statePath))
    #expect(throws: (any Error).self) { try updated.startExisting(instance) }
    #expect(try NetworkPolicy.load(instance) == original)
  }
  try stateBytes.write(to: URL(fileURLWithPath: statePath))
  _ = try runtime.stop(sidecar.machineID)

  // A new policy must not survive a boot that fails the pinned-host-key check.
  let pin = try Data(contentsOf: URL(fileURLWithPath: instance.knownHostsPath))
  try Data("invalid pin\n".utf8).write(to: URL(fileURLWithPath: instance.knownHostsPath))
  #expect(throws: (any Error).self) { try updated.startExisting(instance) }
  #expect(try runtime.inspect(sidecar.machineID).status == .stopped)
  #expect(try NetworkPolicy.load(instance) == original)
  try pin.write(to: URL(fileURLWithPath: instance.knownHostsPath))

  try updated.startExisting(instance)
  #expect(try NetworkPolicy.load(instance) == NetworkPolicy.make(changed))
  try NetworkPolicy.enforce(instance, config: changed)
  #expect(throws: HostError.self) { try NetworkPolicy.enforce(instance, config: install.config) }
  try updated.destroyInstance(instance)
}

@Test func interruptedCreateIsCleanedUpByDestroy() throws {
  let install = try FakeInstallation()
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  let directory = install.config.instancesDirectory.appending("half").path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("half"), index: InstanceIndex(1)!, directory: directory, image: .default)
  try instance.save()
  // A pin already present makes enrollment fail after the sandbox exists.
  try Data("stale\n".utf8).write(to: URL(fileURLWithPath: instance.knownHostsPath))
  #expect(throws: RuntimeError.self) { try backend.createAndStart(instance, diskGiB: nil) }
  let journal = try #require(try Journal.loadIfPresent(instance))
  #expect(journal.op == .create(stage: .machineCreated))
  #expect(try backend.runtime().listed(journal.machineID) == .stopped)
  #expect(throws: RuntimeError.self) { try backend.startExisting(instance) }
  try backend.destroyInstance(instance)
  #expect(try backend.runtime().list().isEmpty)
}

@Test func destroyRemovesStagesWithGuestChosenModes() throws {
  let install = try FakeInstallation()
  defer { install.remove() }
  let directory = install.config.instancesDirectory.appending("staged").path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("staged"), index: InstanceIndex(1)!, directory: directory,
    image: .default)
  try instance.save()
  let locked = directory + "/stage/tree/locked"
  try FileManager.default.createDirectory(
    atPath: locked + "/inner", withIntermediateDirectories: true)
  chmod(locked, 0o000)
  try install.backend.destroyInstance(instance)
  #expect(!FileManager.default.fileExists(atPath: directory))
}

@Test func cancellableRequestsStopWhenAsked() throws {
  var request = ProcessRunner.Request(
    executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [:], deadline: .seconds(60))
  request.isCancelled = { true }
  let start = ContinuousClock.now
  #expect(throws: ProcessRunner.Failure.cancelled) { try ProcessRunner().capture(request) }
  #expect(ContinuousClock.now - start < .seconds(5))
}

@Test func attachedAndPipelineRequestsStopWhenCancelled() throws {
  var attached = ProcessRunner.Request(
    executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [:], deadline: .seconds(60))
  attached.isCancelled = { true }
  let start = ContinuousClock.now
  #expect(throws: ProcessRunner.Failure.cancelled) {
    try ProcessRunner().attached(attached, inheritStdin: false, deadline: nil)
  }
  var producer = ProcessRunner.Request(
    executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: [:], deadline: .seconds(60))
  producer.isCancelled = { true }
  let consumer = ProcessRunner.Request(
    executable: "/bin/cat", arguments: [], environment: [:], deadline: .seconds(60))
  #expect(throws: ProcessRunner.Failure.cancelled) {
    try ProcessRunner().pipeline(producer, consumer)
  }
  #expect(ContinuousClock.now - start < .seconds(5))
}

@Test func cancellingAnAttachedRequestKillsItsDescendants() throws {
  let marker = FileManager.default.temporaryDirectory
    .appending(path: "iso-orphan-\(UUID().uuidString)").path
  defer { try? FileManager.default.removeItem(atPath: marker) }
  // The shell forks a grandchild that would write the marker if it survived.
  var request = ProcessRunner.Request(
    executable: "/bin/sh",
    arguments: ["-c", "(sleep 2; touch '\(marker)') & wait"], environment: [:],
    deadline: .seconds(60))
  let started = ContinuousClock.now
  request.isCancelled = { ContinuousClock.now - started > .milliseconds(400) }
  #expect(throws: ProcessRunner.Failure.cancelled) {
    try ProcessRunner().attached(request, inheritStdin: false, deadline: nil)
  }
  Thread.sleep(forTimeInterval: 2.5)
  #expect(!FileManager.default.fileExists(atPath: marker))
}

@Test func destroyLeavesForeignSandboxesUntouched() throws {
  let install = try FakeInstallation()
  defer { install.remove() }
  try install.backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  let directory = install.config.instancesDirectory.appending("foreign").path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("foreign"), index: InstanceIndex(2)!, directory: directory,
    image: .default)
  try instance.save()
  let stranger = try OwnerID(String(repeating: "f", count: 32))
  let journal = Journal(
    schemaVersion: 2, backend: "apple-container", ownerID: stranger,
    machineID: try MachineName("iso-ffffffff-0000000000000001"),
    op: .create(stage: .machineCreated))
  try StateStore.writeControlFile(journal, to: Journal.path(instance))
  do {
    try install.backend.destroyInstance(instance)
    Issue.record("foreign sandbox destroyed")
  } catch let error as RuntimeError {
    guard case .identityConflict = error else { throw error }
  }
  #expect(FileManager.default.fileExists(atPath: directory))
  _ = install.calls()
}

@Test func durationsPrintLikeRustDebug() {
  #expect(rustDuration(.seconds(120)) == "120s")
  #expect(rustDuration(.milliseconds(119_558)) == "119.558s")
  #expect(rustDuration(.milliseconds(250)) == "250ms")
  #expect(rustDuration(.microseconds(1500)) == "1.5ms")
}

@Test func egressNoneCreatesAHostOnlySandboxAndPinsIt() throws {
  let install = try FakeInstallation(extra: #", "egress": "none""#)
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  _ = install.calls()
  let directory = install.config.instancesDirectory.appending("iso").path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("iso"), index: InstanceIndex(0)!, directory: directory, image: .default)
  try instance.save()
  try backend.createAndStart(instance, diskGiB: nil)
  let create = try #require(install.calls().first { $0.first == "create" })
  #expect(create.suffix(2) == ["--network", "host-only"])
  let running = try #require(try backend.asRunning(instance))
  try backend.stop(running)

  // The configuration flipping back to open is refused, not silently widened.
  // The creation-time policy record answers before the runtime is asked.
  let open = try emptyConfig(
    #""data_dir": "\#(install.root)/data", "apple_container": {"binary": "\#(install.root)/bin/iso-sandbox", "builder": "\#(install.root)/bin/container", "kernel": "\#(install.root)/kernel", "boot_timeout_seconds": 5}"#
  )
  let error = try #require(throws: HostError.self) {
    try backend.reconfigured(open).startExisting(instance)
  }
  #expect("\(error)".contains("POLICY_CHANGE_REQUIRES_RESTART"))
  try backend.destroyInstance(instance)
}

@Test func sessionTTLPassesAnExpiryToEveryBoot() throws {
  let install = try FakeInstallation(extra: #", "limits": {"session_ttl": "2h"}"#)
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  _ = install.calls()
  let directory = install.config.instancesDirectory.appending("ttl").path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("ttl"), index: InstanceIndex(0)!, directory: directory, image: .default)
  try instance.save()
  let before = Int64(Date().timeIntervalSince1970)
  try backend.createAndStart(instance, diskGiB: nil)
  let start = try #require(install.calls().first { $0.first == "start" })
  let index = try #require(start.firstIndex(of: "--expires-at"))
  let expires = try #require(Int64(start[index + 1]))
  #expect(expires >= before + 7200 && expires <= before + 7200 + 60)

  // A restart begins a new window too.
  let running = try #require(try backend.asRunning(instance))
  try backend.stop(running)
  _ = install.calls()
  try backend.startExisting(instance)
  let restart = try #require(install.calls().first { $0.first == "start" })
  #expect(restart.contains("--expires-at"))
  try backend.destroyInstance(instance)
}

@Test func withoutASessionTTLNoExpiryIsPassed() throws {
  let install = try FakeInstallation()
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  let directory = install.config.instancesDirectory.appending("plain").path
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  let instance = Instance(
    name: try InstanceName("plain"), index: InstanceIndex(0)!, directory: directory,
    image: .default)
  try instance.save()
  _ = install.calls()
  try backend.createAndStart(instance, diskGiB: nil)
  let start = try #require(install.calls().first { $0.first == "start" })
  #expect(start.first == "start" && !start.contains("--expires-at"))
  try backend.destroyInstance(instance)
}

@Test func filteredStartSpawnsNoPortForwardBeforeReadiness() throws {
  let install = try FakeInstallation(extra: #", "egress": "filtered""#)
  defer { install.remove() }
  let log = install.root + "/ssh.log"
  try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log)'\nexit 0\n".utf8)
    .write(to: URL(fileURLWithPath: install.root + "/bin/ssh"))
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  let instance = try Instance.allocate(
    install.config, name: InstanceName("ordered"), image: .default, workspacePath: nil)
  let environment = ConfigEnvironment(
    home: install.root,
    variables: ["HOME": install.root, "PATH": "\(install.root)/bin:/usr/bin:/bin"])
  let lifecycle = ProjectLifecycle(
    context: CommandContext(
      environment: environment, config: install.config, backend: backend,
      output: SilentOutput(), diagnostics: Diagnostics(verbosity: 0) { _ in },
      ssh: SSHClient(environment: environment.variables)),
    noGitHub: true, secretResolver: NoSecrets(), executable: nil,
    prepareGitHub: { config, _, _, _ in config })
  let port = UInt16.random(in: 40000...49999)
  let options = BootOptions(
    noAgents: true, noPrompt: true, forwardPorts: [try PortForward(guest: 8080, host: port)],
    configTarget: ConfigTarget(path: install.root + "/c.jsonc", format: .jsonc))
  // No egress companion can start here, so the composite proof never completes.
  #expect(throws: (any Error).self) {
    try lifecycle.startInstance(instance, CreationRequest(boot: options))
  }
  let calls = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
  #expect(!calls.isEmpty, "the guest was waited on over ssh")
  #expect(!calls.contains("-L"), "port forwards were spawned before readiness")
  #expect(try PortForwards.load(instance) == [try PortForward(guest: 8080, host: port)])

  // A restart reuses the saved forwards under the same ordering.
  _ = try backend.runtime().stop(try MachineSidecar.load(instance).machineID)
  try FileManager.default.removeItem(atPath: log)
  #expect(throws: (any Error).self) {
    try lifecycle.restart(instance, RestartRequest(boot: options))
  }
  let restarted = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
  #expect(!restarted.isEmpty, "the restarted guest was waited on over ssh")
  #expect(!restarted.contains("-L"), "port forwards were spawned before readiness on restart")

  // `up` does not report the running but unproven instance as reused.
  let project = install.root + "/project"
  try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
  try WorkspaceState(guestPath: guestWorkspace, source: .workspace(hostPath: project))
    .save(instance)
  var request = UpRequest(configTarget: options.configTarget)
  request.dir = project
  request.noPrompt = true
  #expect(backend.isRunning(instance))
  #expect(throws: InstanceUnhealthy.self) {
    try UpWorkflow(request: request, lifecycle: lifecycle, target: nil).run()
  }
  try backend.destroyInstance(instance)
}

@Test func projectStopReportsWhetherItStoppedAnything() throws {
  let install = try FakeInstallation()
  defer { install.remove() }
  let backend = install.backend
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  let instance = try Instance.allocate(
    install.config, name: InstanceName("stopper"), image: .default, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  let environment = ConfigEnvironment(
    home: install.root,
    variables: ["HOME": install.root, "PATH": "\(install.root)/bin:/usr/bin:/bin"])
  let diagnostics = Diagnostics(verbosity: 0) { _ in }
  let lifecycle = ProjectLifecycle(
    context: CommandContext(
      environment: environment, config: install.config, backend: backend,
      output: SilentOutput(), diagnostics: diagnostics,
      ssh: SSHClient(environment: environment.variables)),
    noGitHub: true, secretResolver: NoSecrets(), executable: nil,
    prepareGitHub: { config, _, _, _ in config })
  #expect(try lifecycle.stop(instance) == .stopped)
  #expect(try backend.asRunning(instance) == nil)
  #expect(try lifecycle.stop(instance) == .unchanged)
  try backend.destroyInstance(instance)
}

// MARK: - macOS guests

private func macSetup(_ install: FakeInstallation, image: ImageName) throws {
  let ipsw = install.root + "/restore.ipsw"
  FileManager.default.createFile(atPath: ipsw, contents: Data("ipsw".utf8))
  try install.backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: image, guestUser: .default, builderTimeout: nil,
      macOSRestoreImage: ipsw))
}

@Test func macOSSetupRecordsATemplateAndSkipsLinuxPreparation() throws {
  let install = try FakeInstallation(extra: #", "vm": {"vcpu_count": 4, "mem_size_mib": 8192}"#)
  defer { install.remove() }
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  let calls = install.calls()
  #expect(calls.contains { $0.starts(with: ["macos", "template", "build"]) })
  #expect(!calls.contains { $0.first == "init" || $0.first == "maintenance" })
  let build = try #require(calls.first { $0.starts(with: ["macos", "template", "build"]) })
  let script = try String(
    contentsOfFile: build[build.firstIndex(of: "--provision")! + 1], encoding: .utf8)
  #expect(script == MacProvision.script())
  let manifest = try ImageManifest.load(install.config, image)
  #expect(manifest.guestOS == .macos)
  #expect(manifest.guestUser == MacProvision.guestUser)
  try install.backend.runtime().verifyImage(manifest)
  // Unchanged inputs: no second build.
  try macSetup(install, image: image)
  #expect(!install.calls().contains { $0.starts(with: ["macos", "template", "build"]) })
  // A different restore image: rebuilt.
  let other = install.root + "/other.ipsw"
  FileManager.default.createFile(atPath: other, contents: Data("other".utf8))
  try install.backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: image, guestUser: .default, builderTimeout: nil,
      macOSRestoreImage: other))
  #expect(install.calls().contains { $0.starts(with: ["macos", "template", "build"]) })
}

@Test func macOSInstancesRunThroughTheMacRuntimeAndTheMacGate() throws {
  let install = try FakeInstallation(extra: #", "vm": {"vcpu_count": 4, "mem_size_mib": 8192}"#)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  _ = install.calls()
  let instance = try Instance.allocate(
    install.config, name: InstanceName("mac1"), image: image, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  let calls = install.calls()
  let create = try #require(calls.first { $0.starts(with: ["macos", "create"]) })
  let publicKey = try String(
    contentsOfFile: install.config.sshKeyPath.path + ".pub", encoding: .utf8)
  #expect(
    create[create.firstIndex(of: "--authorized-key")! + 1]
      == publicKey.split(separator: " ").prefix(2).joined(separator: " "))
  #expect(create[create.firstIndex(of: "--network")! + 1] == "shared")
  #expect(!calls.contains { $0.first == "create" || $0.first == "exec" })
  let sidecar = try MachineSidecar.load(instance)
  #expect(sidecar.kind == .macos)
  #expect(sidecar.guestUser == MacProvision.guestUser)
  #expect(sidecar.hostKeyFingerprint == "SHA256:10O2vYbKkmA/sBuRrfwbSNiR5pAFM/qtkqldbUJESvk")
  #expect(sidecar.lastObservedOwnerPID == 4343)

  let running = try #require(try backend.asRunning(instance))
  #expect(running.target.user == MacProvision.guestUser)
  #expect(try backend.describe(running).contains("macOS guest"))
  #expect(throws: HostError.self) {
    try backend.streamLogs(running, follow: false, line: { _ in }, stderr: { _ in })
  }
  #expect(throws: HostError.self) { _ = try backend.asStopped(instance) }
  try backend.stop(running)
  #expect(try backend.asRunning(instance) == nil)
  try backend.startExisting(instance)
  #expect(try backend.asRunning(instance) != nil)
  try backend.destroyInstance(instance)
  #expect(try backend.runtime().macList().isEmpty)
  try backend.destroyImage(image)
  #expect(try backend.runtime().macTemplates().isEmpty)
}

@Test func macOSStartRefusesAChangedPinnedHostKey() throws {
  let install = try FakeInstallation(extra: #", "vm": {"vcpu_count": 4, "mem_size_mib": 8192}"#)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  let instance = try Instance.allocate(
    install.config, name: InstanceName("mac2"), image: image, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  try backend.stop(try #require(try backend.asRunning(instance)))
  let sidecar = try MachineSidecar.load(instance)
  let pinned = Data(
    "\(sidecar.machineID).iso ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDifferentKeyDifferentKeyDifferentKey00\n"
      .utf8)
  try pinned.write(to: URL(fileURLWithPath: instance.knownHostsPath))
  do {
    try backend.startExisting(instance)
    Issue.record("started with a changed host key")
  } catch RuntimeError.hostKeyChanged {
  } catch {
    Issue.record("unexpected error: \(error)")
  }
  #expect(FileManager.default.contents(atPath: instance.knownHostsPath) == pinned)
  #expect(try backend.runtime().macInspect(sidecar.machineID).status == .stopped)
}

@Test func destroyRemovesAMacOSSandboxLeftByAnInterruptedCreate() throws {
  let install = try FakeInstallation(extra: #", "vm": {"vcpu_count": 4, "mem_size_mib": 8192}"#)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  let instance = try Instance.allocate(
    install.config, name: InstanceName("mac3"), image: image, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  let sidecar = try MachineSidecar.load(instance)
  // As if the create had stopped before writing the sidecar.
  _ = try Journal.begin(
    instance, owner: try Owner.load(install.config), op: .create(stage: .machineCreated),
    machine: sidecar.machineID)
  try FileManager.default.removeItem(atPath: MachineSidecar.path(instance))
  try backend.destroyInstance(instance)
  #expect(try backend.runtime().macList().isEmpty)
}

@Test func macOSProvisioningScriptIsValidBash() throws {
  let script = MacProvision.script()
  #expect(!script.contains("\\("))
  #expect(script.contains("gh_\(MacProvision.ghVersion)_macOS_arm64.zip"))
  let path = FileManager.default.temporaryDirectory.appending(path: "provision-\(UUID()).sh").path
  try Data(script.utf8).write(to: URL(fileURLWithPath: path))
  defer { try? FileManager.default.removeItem(atPath: path) }
  let check = try ProcessRunner().capture(
    .init(
      executable: "/bin/bash", arguments: ["-n", path], environment: [:], deadline: .seconds(10)))
  #expect(check.termination == .exited(0))
}

@Test func filteredMacOSInstancesUseTheMacRuntimePathsAndRequireReadiness() throws {
  let install = try FakeInstallation(
    extra: #", "vm": {"vcpu_count": 4, "mem_size_mib": 8192}, "egress": "filtered""#)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  _ = install.calls()
  let instance = try Instance.allocate(
    install.config, name: InstanceName("macf"), image: image, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  let create = try #require(install.calls().first { $0.starts(with: ["macos", "create"]) })
  #expect(create[create.firstIndex(of: "--network")! + 1] == "host-only")
  let runtime = try backend.runtime()
  let sidecar = try MachineSidecar.load(instance)
  let boot = try runtime.requireFilteredBoot(sidecar.machineID, .macos)
  #expect(boot.bootID == "mac-boot" && boot.ownerPID == 4343)
  #expect(boot.livePath.hasSuffix("/macos/sandboxes/\(sidecar.machineID)/live.json"))
  // No companion was started for this boot: the readiness proof fails.
  let failure = try #require(throws: InstanceUnhealthy.self) { try backend.asRunning(instance) }
  #expect(failure.reason.hasPrefix("FILTERED_EGRESS_NOT_READY: "))
}

private func macMode(_ install: FakeInstallation, _ knobs: [String: Any]) throws {
  try JSONSerialization.data(withJSONObject: knobs).write(
    to: URL(fileURLWithPath: install.root + "/bin/fake-mode.json"))
}

private let macVM = #", "vm": {"vcpu_count": 4, "mem_size_mib": 8192}"#

@Test func macOSBootWaitsForTheHelperAndRefusesAStopOrAKeyMismatch() throws {
  let install = try FakeInstallation(extra: macVM)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  // Pending for a few inspects, then enrolled: the boot waits for it.
  try macMode(install, ["pendingInspects": 3])
  let waited = try Instance.allocate(
    install.config, name: InstanceName("macw"), image: image, workspacePath: nil)
  try backend.createAndStart(waited, diskGiB: nil)
  #expect(try backend.asRunning(waited) != nil)
  // A guest that stops during boot fails the create.
  try macMode(install, ["stopDuringBoot": true])
  let stopped = try Instance.allocate(
    install.config, name: InstanceName("macs"), image: image, workspacePath: nil)
  let bootError = try #require(throws: RuntimeError.self) {
    try backend.createAndStart(stopped, diskGiB: nil)
  }
  guard case .bootTimeout = bootError else {
    Issue.record("expected a boot failure, got \(bootError)")
    return
  }
  // A confirmed key that differs from the runtime's pin is refused.
  try macMode(
    install,
    [
      "confirmedKey":
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherKeyOtherKeyOtherKeyOtherKeyOtherKeyOt"
    ])
  let mismatched = try Instance.allocate(
    install.config, name: InstanceName("mack"), image: image, workspacePath: nil)
  let keyError = try #require(throws: RuntimeError.self) {
    try backend.createAndStart(mismatched, diskGiB: nil)
  }
  guard case .hostKeyChanged = keyError else {
    Issue.record("expected a host-key refusal, got \(keyError)")
    return
  }
  #expect(!FileManager.default.fileExists(atPath: mismatched.knownHostsPath))
}

@Test func macOSSetupRefusesWhatItCannotBuild() throws {
  let install = try FakeInstallation(extra: macVM)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  let ipsw = install.root + "/restore.ipsw"
  FileManager.default.createFile(atPath: ipsw, contents: Data("ipsw".utf8))
  func setup(_ image: ImageName, user: GuestUser = .default, restore: String? = nil) throws {
    try backend.setup(
      SetupOptions(
        rebuild: false, profiles: [], image: image, guestUser: user, builderTimeout: nil,
        macOSRestoreImage: restore ?? ipsw))
  }
  #expect(throws: HostError.self) { try setup(image, user: try GuestUser("vscode")) }
  #expect(throws: HostError.self) { try setup(image, restore: install.root + "/missing.ipsw") }
  // A template recording another script than iso supplied is refused and removed.
  try macMode(install, ["provisionSha": String(repeating: "0", count: 64)])
  #expect(throws: RuntimeError.self) { try setup(image) }
  #expect(try backend.runtime().macTemplates().isEmpty)
  #expect(try ImageManifest.loadIfPresent(install.config, image) == nil)
  // A runtime without macOS support is refused before anything is built.
  try macMode(install, ["noMacFeature": true])
  let unsupported = AppleBackend(
    config: install.config,
    environment: [
      "HOME": install.root, "PATH": "\(install.root)/bin:/usr/bin:/bin",
      "TMPDIR": NSTemporaryDirectory(),
    ], executable: nil)
  #expect(throws: RuntimeError.self) {
    try unsupported.setup(
      SetupOptions(
        rebuild: false, profiles: [], image: image, guestUser: .default, builderTimeout: nil,
        macOSRestoreImage: ipsw))
  }
  // An image keeps its guest OS unless replaced with --rebuild.
  try macMode(install, [:])
  try backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  #expect(throws: HostError.self) { try setup(.default) }
  try setup(image)
  #expect(throws: HostError.self) {
    try backend.setup(
      SetupOptions(
        rebuild: false, profiles: [], image: image, guestUser: .default, builderTimeout: nil))
  }
}

@Test func aRebuiltMacOSImageKeepsItsOldTemplateForItsInstances() throws {
  let install = try FakeInstallation(extra: macVM)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  let first = try ImageManifest.load(install.config, image).imageRef
  let instance = try Instance.allocate(
    install.config, name: InstanceName("macr"), image: image, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  let ipsw = install.root + "/restore.ipsw"
  _ = install.calls()
  try backend.setup(
    SetupOptions(
      rebuild: true, profiles: [], image: image, guestUser: .default, builderTimeout: nil,
      macOSRestoreImage: ipsw))
  // iso itself keeps the template: it never asks the runtime to delete it.
  #expect(!install.calls().contains { $0.starts(with: ["macos", "template", "delete"]) })
  let templates = try backend.runtime().macTemplates().map(\.name)
  #expect(templates.count == 2 && templates.contains(first))
  try backend.stop(try #require(try backend.asRunning(instance)))
  try backend.startExisting(instance)
  try backend.destroyInstance(instance)
  #expect(
    try backend.runtime().macTemplates().map(\.name) == [
      try ImageManifest.load(install.config, image).imageRef
    ])
}

@Test func macOSInstancesRefuseADiskSizeAndCodexAccountAuth() throws {
  let install = try FakeInstallation(extra: macVM + #", "codex": {"auth": "chatgpt"}"#)
  defer { install.remove() }
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  let instance = try Instance.allocate(
    install.config, name: InstanceName("macd"), image: image, workspacePath: nil)
  #expect(throws: HostError.self) { try install.backend.createAndStart(instance, diskGiB: 100) }
  let error = try #require(throws: HostError.self) {
    try install.backend.createAndStart(instance, diskGiB: nil)
  }
  #expect("\(error)".contains("Secret Service"))
  #expect(try install.backend.runtime().macList().isEmpty)
  // Refused before any state: nothing blocks a retry once fixed.
  #expect(try Journal.loadIfPresent(instance) == nil)
  #expect(try MachineSidecar.loadIfPresent(instance) == nil)
}

@Test func aMacOSImageMissingFromTheRuntimeIsRefused() throws {
  let install = try FakeInstallation(extra: macVM)
  defer { install.remove() }
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  let runtime = try install.backend.runtime()
  try runtime.macDeleteTemplate(try MachineName(ImageManifest.load(install.config, image).imageRef))
  let instance = try Instance.allocate(
    install.config, name: InstanceName("macm"), image: image, workspacePath: nil)
  #expect(throws: RuntimeError.self) { try install.backend.createAndStart(instance, diskGiB: nil) }
}

@Test func macOSBootsCarryTheSessionDeadline() throws {
  let install = try FakeInstallation(extra: macVM + #", "limits": {"session_ttl": "2h"}"#)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  _ = install.calls()
  let instance = try Instance.allocate(
    install.config, name: InstanceName("macttl"), image: image, workspacePath: nil)
  let before = Int64(Date().timeIntervalSince1970)
  try backend.createAndStart(instance, diskGiB: nil)
  let start = try #require(install.calls().first { $0.starts(with: ["macos", "start"]) })
  let index = try #require(start.firstIndex(of: "--expires-at"))
  let expires = try #require(Int64(start[index + 1]))
  #expect(expires >= before + 7200 && expires <= before + 7200 + 60)
  // A restart begins a new window too.
  try backend.stop(try #require(try backend.asRunning(instance)))
  _ = install.calls()
  let restarted = Int64(Date().timeIntervalSince1970)
  try backend.startExisting(instance)
  let restart = try #require(install.calls().first { $0.starts(with: ["macos", "start"]) })
  let restartIndex = try #require(restart.firstIndex(of: "--expires-at"))
  let renewed = try #require(Int64(restart[restartIndex + 1]))
  #expect(renewed >= restarted + 7200 && renewed <= restarted + 7200 + 60)
}

@Test func anUnreadableInstanceKeepsTheMacOSTemplateItMayUse() throws {
  let install = try FakeInstallation(extra: macVM)
  defer { install.remove() }
  let backend = install.backend
  let image = try ImageName("mac")
  try macSetup(install, image: image)
  let instance = try Instance.allocate(
    install.config, name: InstanceName("macu"), image: image, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  try backend.stop(try #require(try backend.asRunning(instance)))
  try Data("{".utf8).write(to: URL(fileURLWithPath: instance.directory + "/instance.json"))
  _ = install.calls()
  try backend.setup(
    SetupOptions(
      rebuild: true, profiles: [], image: image, guestUser: .default, builderTimeout: nil,
      macOSRestoreImage: install.root + "/restore.ipsw"))
  #expect(!install.calls().contains { $0.starts(with: ["macos", "template", "delete"]) })
}
