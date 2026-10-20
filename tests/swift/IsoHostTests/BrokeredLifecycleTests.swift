import Foundation
import IsoConfiguration
import IsoCore
import IsoSecrets
import Testing

@testable import IsoHost

// Brokered create, restart, refusal, restore/commit and relay selection
// through `AppleBackend` against the stateful fake runtime
// (tests/fixtures/fake-runtime/iso-sandbox).

private let brokeredNone = #", "network": {"transport": "brokered"}, "egress": "none""#

private func installed(_ extra: String = brokeredNone, mode: [String: Bool] = [:]) throws
  -> FakeInstallation
{
  let install = try FakeInstallation(extra: extra)
  if !mode.isEmpty {
    try JSONSerialization.data(withJSONObject: mode).write(
      to: URL(fileURLWithPath: install.root + "/bin/fake-mode.json"))
  }
  try install.backend.setup(
    SetupOptions(
      rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
  _ = install.calls()
  return install
}

private func option(_ call: [String], _ name: String) -> String? {
  call.firstIndex(of: name).map { call.index(after: $0) }.flatMap {
    $0 < call.count ? call[$0] : nil
  }
}

@Test func aBrokeredBootIsCreatedNICLessAndBoundToItsRecordedDigest() throws {
  let install = try installed()
  defer { install.remove() }
  let backend = install.backend
  let instance = try Instance.allocate(
    install.config, name: InstanceName("brk"), image: .default, workspacePath: nil)
  // The --env provider secret this first boot records decides its grants.
  let pending: [EnvVarName: EnvValue] = [
    try EnvVarName("ANTHROPIC_API_KEY"): .secret(try SecretName("k"))
  ]
  try backend.createAndStart(instance, diskGiB: nil, guestEnvironment: pending)
  let calls = install.calls()
  let create = try #require(calls.first { $0.first == "create" })
  #expect(option(create, "--network") == "brokered")
  let start = try #require(calls.first { $0.first == "start" })
  let record = try #require(try NetworkPolicy.load(instance))
  let digest = try #require(record.brokeredDigest)
  #expect(option(start, "--network-policy") == digest.rawValue)
  #expect(record.brokered?.providerGrants == ["anthropic"])

  // The caller records the environment (ProjectLifecycle does); handoffs
  // then resolve the same digest.
  try GuestEnvState(entries: pending).save(instance)
  let running = try #require(try backend.asRunning(instance))
  guard case .brokered(let route) = running.ready.route else {
    Issue.record("a brokered instance was handed out on another route")
    return
  }
  #expect(route.networkPolicy == digest && route.networkDevices == 0)
  #expect(running.ready.ipv4 == nil)
  let proxy = try #require(running.target.proxyCommand)
  #expect(proxy.hasPrefix(install.root + "/bin/iso-sandbox connect --root "))
  #expect(proxy.hasSuffix("--network-policy \(digest)"))
  #expect(try backend.brokeredView(running)?.policy.providerGrants == ["anthropic"])
  #expect(try backend.describe(running).contains("Network: brokered (0 network devices"))

  // A restart is a new boot under the same digest; the old route is stale.
  try backend.stop(running)
  try backend.startExisting(instance)
  let restart = try #require(install.calls().first { $0.first == "start" })
  #expect(option(restart, "--network-policy") == digest.rawValue)
  let again = try #require(try backend.asRunning(instance))
  guard case .brokered(let next) = again.ready.route else { return }
  #expect(next.bootID != route.bootID)
  #expect(throws: (any Error).self) { try WorkloadHandoff.require(running) { again } }

  // A widened grant is refused at the next handoff until a restart.
  try GuestEnvState(
    entries: pending.merging(
      [try EnvVarName("OPENAI_API_KEY"): .secret(try SecretName("o"))]) { a, _ in a }
  ).save(instance)
  #expect(throws: (any Error).self) { try backend.asRunning(instance) }
}

@Test func brokeredCreatesAreRefusedBeforeAnyRecordOrVM() throws {
  func expectRefusedBeforeCreate(
    _ install: FakeInstallation, _ backend: AppleBackend, _ name: String, because reason: String,
    prepare: (Instance) throws -> Void = { _ in }
  ) throws {
    let instance = try Instance.allocate(
      install.config, name: InstanceName(name), image: .default, workspacePath: nil)
    try prepare(instance)
    do {
      try backend.createAndStart(instance, diskGiB: nil)
      Issue.record("\(name): a brokered create was not refused")
    } catch {
      #expect("\(error)".contains(reason), "\(name): \(error)")
    }
    #expect(!install.calls().contains { $0.first == "create" }, "\(name)")
    #expect(try NetworkPolicy.load(instance) == nil, "\(name)")
    #expect(try Journal.loadIfPresent(instance) == nil, "\(name)")
  }

  // A runtime without the feature.
  let old = try installed(mode: ["noBrokeredFeature": true])
  defer { old.remove() }
  try expectRefusedBeforeCreate(old, old.backend, "no-feature", because: "brokered-transport")

  let install = try installed(
    brokeredNone
      + #", "claude": {"local_model": {"host_url": "http://192.168.1.5:11434", "model": "m"}}"#)
  defer { install.remove() }
  // A local model the guest would have to reach directly.
  try expectRefusedBeforeCreate(
    install, install.backend, "lan-model", because: "BROKERED_UNSUPPORTED"
  ) { instance in
    var model = ModelState()
    model.mode = .local
    try model.save(instance)
  }
  // `--egress open` on a brokered configuration.
  try expectRefusedBeforeCreate(
    install, install.backend.reconfigured(install.config.overridingEgress(.open)), "open",
    because: #"egress "open" is invalid"#)
  // An image that predates the guest adapter.
  let manifest = try ImageManifest.load(install.config, .default)
  #expect(manifest.supportsBrokered)
  var stripped = manifest
  stripped.guestAdapters = nil
  try stripped.save(install.config, .default)
  try expectRefusedBeforeCreate(
    install, install.backend, "no-adapter", because: "predates the brokered transport")
}

@Test func commitCarriesTheAdapterAndRestoreRefusesADiskWithout() throws {
  let install = try installed()
  defer { install.remove() }
  let backend = install.backend
  let instance = try Instance.allocate(
    install.config, name: InstanceName("snap"), image: .default, workspacePath: nil)
  try backend.createAndStart(instance, diskGiB: nil)
  try backend.stop(try #require(try backend.asRunning(instance)))
  let snapshot = try ImageName("brk-snap")
  try backend.commitDisk(try backend.asStopped(instance), image: snapshot)
  var committed = try ImageManifest.load(install.config, snapshot)
  #expect(committed.guestAdapters == BuildContext.guestAdapters)
  try backend.restoreDisk(try backend.asStopped(instance), image: snapshot)
  committed.guestAdapters = nil
  try committed.save(install.config, snapshot)
  _ = install.calls()
  #expect(throws: HostError.self) {
    try backend.restoreDisk(try backend.asStopped(instance), image: snapshot)
  }
  #expect(!install.calls().contains { $0.first == "restore" })
}

@Test func aRemoteRelayReachesABrokeredGuestOnlyThroughTheConnector() throws {
  let install = try installed()
  defer { install.remove() }
  let id = InstanceID.generate()
  let instance = try Instance.allocate(
    install.config, name: AppleNativeHost.instanceName(id), image: .default, workspacePath: nil)
  try install.backend.createAndStart(instance, diskGiB: nil)
  let machine = try install.backend.ownedSidecar(instance).machineID
  let endpoint = try AppleNativeHost(backend: install.backend).guestEndpoint(id, runtime: machine)
  guard case .brokered(let command) = endpoint.route else {
    Issue.record("a brokered guest was given an address endpoint")
    return
  }
  #expect(command.executable == install.root + "/bin/iso-sandbox")
  #expect(command.arguments.first == "connect")
  #expect(option(command.arguments, "--boot") == "fixture-boot-1")
  #expect(option(command.arguments, "--channel-policy") == BrokeredChannel.digest.rawValue)

  // The same worker serving a vmnet VM keeps the address route.
  let vmnet = try installed("")
  defer { vmnet.remove() }
  let vid = InstanceID.generate()
  let plain = try Instance.allocate(
    vmnet.config, name: AppleNativeHost.instanceName(vid), image: .default, workspacePath: nil)
  try vmnet.backend.createAndStart(plain, diskGiB: nil)
  let vmachine = try vmnet.backend.ownedSidecar(plain).machineID
  let tcp = try AppleNativeHost(backend: vmnet.backend).guestEndpoint(vid, runtime: vmachine)
  guard case .tcp = tcp.route else {
    Issue.record("a vmnet guest lost its address route")
    return
  }
}

@Test func theAdvertisedRunPolicyIsTheDigestAFreshHostRunBootsUnder() throws {
  let install = try installed()
  defer { install.remove() }
  let native = AppleNativeHost(backend: install.backend)
  let capability = native.networkCapability()
  #expect(capability.transport == .brokered)
  #expect(capability.runtimeBrokered)
  #expect(capability.liveTuple["transport"] == "brokered")
  let advertised = try #require(capability.runPolicies[.none])
  #expect(advertised.providerGrants.isEmpty && advertised.localServices.isEmpty)
  // A host-control VM: the reserved `hc-<id>` record, created and booted the
  // way `vm.create`/`run.create` do it, then proven through the gate.
  let id = InstanceID.generate()
  let instance = try Instance.allocate(
    install.config, name: AppleNativeHost.instanceName(id), image: .default, workspacePath: nil)
  try install.backend.createAndStart(instance, diskGiB: nil)
  let machine = try install.backend.ownedSidecar(instance).machineID
  let proof = try #require(try native.networkProof(id, runtime: machine))
  #expect(proof.networkPolicy == advertised.digest)
  #expect(native.imageDigest(.default) == (try ImageManifest.load(install.config, .default)).digest)

  // A vmnet worker advertises no run policy.
  let vmnet = try installed("")
  defer { vmnet.remove() }
  let plain = AppleNativeHost(backend: vmnet.backend).networkCapability()
  #expect(plain.transport == .vmnet)
  #expect(plain.runPolicies.isEmpty)
}

/// Records filtered-egress companion calls; `failure` makes `start` throw.
private final class RecordingEgress: FilteredEgressCompanion, @unchecked Sendable {
  private let lock = NSLock()
  private var events: [String] = []
  let failure: Bool
  init(failure: Bool = false) { self.failure = failure }
  func start(_ instance: Instance, backend: AppleBackend) throws {
    lock.withLock { events.append("start \(instance.name) \(backend.config.egress.rawValue)") }
    if failure { throw HostError("companion refused") }
  }
  func stop(_ instance: Instance) { lock.withLock { events.append("stop \(instance.name)") } }
  var calls: [String] { lock.withLock { events } }
}

private let brokeredFiltered =
  #", "network": {"transport": "brokered"}, "egress": "filtered", "egress_filter": {"allowed_hosts": ["api.github.com"]}"#

private func hostVM(_ install: FakeInstallation, _ native: AppleNativeHost, egress: EgressMode)
  throws -> (InstanceID, MachineName)
{
  let owner = try Owner.load(install.config).id
  let id = InstanceID.generate()
  let machine = try MachineName.generate(for: owner, randomHex: "0123456789abcdef")
  let spec = try VMSpec.make(
    name: InstanceName("ci"), image: .default, imageDigest: nil, cpus: 2, memoryMiB: 4096,
    diskGiB: 8, guestOS: .linux, egress: egress)
  try native.create(id, runtime: machine, spec: spec, owner: owner)
  return (id, machine)
}

@Test func aFilteredHostControlBootStartsItsEgressCompanionAndStopsItWithTheVM() throws {
  let install = try installed(brokeredFiltered)
  defer { install.remove() }
  let egress = RecordingEgress()
  let native = AppleNativeHost(backend: install.backend, egress: egress)
  let (id, machine) = try hostVM(install, native, egress: .filtered)
  // The enrollment boot inside create needs no companion.
  #expect(egress.calls.isEmpty)
  try native.start(id, runtime: machine, expiresAt: nil)
  let name = AppleNativeHost.instanceName(id)
  #expect(egress.calls == ["start \(name) filtered"])
  try native.stop(id, runtime: machine)
  #expect(egress.calls.last == "stop \(name)")
  try native.delete(id, runtime: machine, owner: try Owner.load(install.config).id)
  #expect(egress.calls.last == "stop \(name)")
}

@Test func aFilteredBootWhoseCompanionFailsIsStoppedNotLeftRunning() throws {
  let install = try installed(brokeredFiltered)
  defer { install.remove() }
  let egress = RecordingEgress(failure: true)
  let native = AppleNativeHost(backend: install.backend, egress: egress)
  let (id, machine) = try hostVM(install, native, egress: .filtered)
  do {
    try native.start(id, runtime: machine, expiresAt: nil)
    Issue.record("a filtered boot without its companion was reported started")
  } catch {
    guard case .failed(let reason) = error else {
      Issue.record("unexpected failure \(error)")
      return
    }
    #expect(reason.hasPrefix("FILTERED_EGRESS_NOT_READY"))
  }
  #expect(try native.observe(id, runtime: machine) == .stopped)
  #expect(egress.calls.last == "stop \(AppleNativeHost.instanceName(id))")
}

@Test func anUnfilteredHostControlBootNeedsNoCompanion() throws {
  let install = try installed()
  defer { install.remove() }
  let egress = RecordingEgress(failure: true)
  let native = AppleNativeHost(backend: install.backend, egress: egress)
  let (id, machine) = try hostVM(install, native, egress: .none)
  try native.start(id, runtime: machine, expiresAt: nil)
  #expect(!egress.calls.contains { $0.hasPrefix("start") })
}
