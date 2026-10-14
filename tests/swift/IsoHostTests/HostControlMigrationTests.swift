import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

/// The production `AppleNativeHost` adapter and migration, driven through the
/// real `AppleBackend` against the stateful fake runtime.
@Suite(.serialized) struct HostControlNativeAdapterTests {
  func supervisor(_ install: FakeInstallation) throws -> HostSupervisor {
    var settings = HostSupervisor.Settings()
    settings.dispatch = .manual
    return try HostSupervisor(
      root: HostService.root(install.config), owner: try Owner.load(install.config).id,
      native: AppleNativeHost(backend: install.backend), settings: settings)
  }

  func call(
    _ s: HostSupervisor, _ body: HostRequestBody, operation: HostOperationID? = nil,
    transport: HostTransportKind = .local
  ) -> Result<JSONValue, HostControlError> {
    s.handle(
      HostRequest(
        hostID: s.installation.hostID, ownerID: s.installation.ownerID, operationID: operation,
        body: body), transport: transport
    ).outcome
  }

  @Test func appleAdapterRunsTheLifecycleThroughAppleBackend() throws {
    let install = try FakeInstallation()
    defer { install.remove() }
    try install.backend.setup(
      SetupOptions(
        rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
    let s = try supervisor(install)
    let spec = try VMSpec.make(
      name: InstanceName("svc"), image: .default, imageDigest: nil, cpus: 2, memoryMiB: 2048,
      diskGiB: 8, guestOS: .linux, egress: .open)
    let created = try OperationReceipt(wire: call(s, .vmCreate(spec), operation: .generate()).get())
    s.runPending()
    let instance = try #require(created.instance)
    #expect(
      try OperationReceipt(wire: call(s, .operationGet(created.operationID)).get()).state
        == .succeeded)
    // The native record is an ordinary instance directory with a pinned key.
    let native = try #require(
      try InstanceStore.list(install.config).first {
        $0.name.rawValue == "hc-" + instance.instanceID.rawValue
      })
    #expect(FileManager.default.fileExists(atPath: native.knownHostsPath))
    #expect(try MachineSidecar.load(native).machineID == instance.runtimeID)
    let start = try OperationReceipt(
      wire: call(
        s, .vmStart(instance, expectedGeneration: 1, ttlSeconds: 600, policy: spec.policyHash),
        operation: .generate()
      ).get())
    s.runPending()
    #expect(
      try OperationReceipt(wire: call(s, .operationGet(start.operationID)).get()).state
        == .succeeded)
    let running = try VMObservation(wire: call(s, .vmInspect(instance)).get())
    #expect(running.state == .running)
    let stop = try OperationReceipt(
      wire: call(
        s, .vmStop(instance, expectedGeneration: running.generation), operation: .generate()
      ).get())
    s.runPending()
    #expect(
      try OperationReceipt(wire: call(s, .operationGet(stop.operationID)).get()).state == .succeeded
    )
    let stopped = try VMObservation(wire: call(s, .vmInspect(instance)).get())
    #expect(stopped.state == .stopped)
    let destroy = try OperationReceipt(
      wire: call(
        s, .vmDestroy(instance, expectedGeneration: stopped.generation), operation: .generate()
      ).get())
    s.runPending()
    #expect(
      try OperationReceipt(wire: call(s, .operationGet(destroy.operationID)).get()).state
        == .succeeded)
    #expect(try VMObservation(wire: call(s, .vmInspect(instance)).get()).state == .destroyed)
    #expect(try InstanceStore.list(install.config).isEmpty)
  }

  /// A stopped legacy instance made the old way.
  func legacy(_ install: FakeInstallation, _ name: String) throws -> Instance {
    try install.backend.setup(
      SetupOptions(
        rebuild: false, profiles: [], image: .default, guestUser: .default, builderTimeout: nil))
    let instance = try Instance.allocate(
      install.config, name: InstanceName(name), image: .default, workspacePath: nil)
    try install.backend.createAndStart(instance, diskGiB: nil)
    try install.backend.stopUnproven(instance)
    return instance
  }

  @Test func migrationAdoptsStoppedInstancesAndFencesTheRoot() throws {
    let install = try FakeInstallation()
    defer { install.remove() }
    let instance = try legacy(install, "old")
    let diagnostics = Diagnostics(verbosity: 0, sink: { _ in })
    let preview = try HostMigration.preview(
      config: install.config, backend: install.backend, diagnostics: diagnostics)
    #expect(preview.legacyInstances.map(\.name.rawValue) == ["old"])
    #expect(preview.legacyInstances.first?.adoptable == true)
    try #require(preview.eligible, "\(preview.blockers)")
    let prepared = try HostMigration.prepare(config: install.config, preview: preview)
    #expect(prepared.state == .prepared)
    // Between prepare and completion nothing but hello is dispatched.
    let pending = try supervisor(install)
    #expect(failure(call(pending, .vmList(cursor: nil, limit: 10))) == .migrationRequired)
    // The service completes activation (resumable: running it twice is harmless).
    try HostMigration.complete(
      config: install.config, backend: install.backend, diagnostics: diagnostics)
    try HostMigration.complete(
      config: install.config, backend: install.backend, diagnostics: diagnostics)
    #expect(try HostMigration.loadRecord(install.config)?.state == .active)
    // Older binaries (owner schema 1 only) now reject the root; this build reads it.
    let ownerBytes = try #require(try StateStore.readControlFile(Owner.path(install.config)))
    #expect(throws: (any Error).self) {
      try StateSchema.decode(
        Owner.self, ownerBytes, path: "owner.json", want: StateSchema.ownerVersion)
    }
    #expect(try Owner.load(install.config).isFenced)
    // The legacy path can no longer mutate it; the service can.
    let adopted = try #require(try ServiceAdoption.load(instance))
    #expect(throws: HostError.self) { try install.backend.stopUnproven(instance) }
    let s = try supervisor(install)
    let binding = try #require(
      try ClientBindingStore(config: install.config).load(s.installation.hostID, instance.name))
    #expect(binding.instanceID == adopted)
    let observation = try VMObservation(wire: call(s, .vmInspect(binding.instance)).get())
    #expect(observation.state == .stopped)
    let start = try OperationReceipt(
      wire: call(
        s,
        .vmStart(
          binding.instance, expectedGeneration: observation.generation, ttlSeconds: nil,
          policy: binding.policyHash),
        operation: .generate()
      ).get())
    s.runPending()
    #expect(
      try OperationReceipt(wire: call(s, .operationGet(start.operationID)).get()).state
        == .succeeded)
    #expect(try VMObservation(wire: call(s, .vmInspect(binding.instance)).get()).state == .running)
  }

  @Test func anUnreadableAdoptionMarkerStillFencesTheInstance() throws {
    let install = try FakeInstallation()
    defer { install.remove() }
    let instance = try legacy(install, "old")
    let diagnostics = Diagnostics(verbosity: 0, sink: { _ in })
    let preview = try HostMigration.preview(
      config: install.config, backend: install.backend, diagnostics: diagnostics)
    _ = try HostMigration.prepare(config: install.config, preview: preview)
    try HostMigration.complete(
      config: install.config, backend: install.backend, diagnostics: diagnostics)
    #expect(try ServiceAdoption.load(instance) != nil)
    // A corrupt marker is an error, not "not adopted": the fence holds.
    let marker = ServiceAdoption.path(instance)
    try Data("{".utf8).write(to: URL(fileURLWithPath: marker))
    #expect(chmod(marker, 0o600) == 0)
    #expect(throws: HostError.self) { try ServiceAdoption.load(instance) }
    let refusal = #expect(throws: (any Error).self) { try install.backend.stopUnproven(instance) }
    #expect("\(refusal.map { "\($0)" } ?? "")".contains("unreadable host-control marker"))
    // Only an absent marker reads as not adopted.
    ServiceAdoption.remove(instance)
    #expect(try ServiceAdoption.load(instance) == nil)
  }

  @Test func runningOrJournaledInstancesBlockAndRollbackRestores() throws {
    let install = try FakeInstallation()
    defer { install.remove() }
    let instance = try legacy(install, "busy")
    let diagnostics = Diagnostics(verbosity: 0, sink: { _ in })
    try install.backend.startExisting(instance)
    let running = try HostMigration.preview(
      config: install.config, backend: install.backend, diagnostics: diagnostics)
    #expect(running.blockers.contains { $0.contains("is running") })
    #expect(throws: HostControlError.self) {
      try HostMigration.prepare(config: install.config, preview: running)
    }
    // Migration never stopped it.
    #expect(install.backend.isRunning(instance))
    try install.backend.stopUnproven(instance)
    let ready = try HostMigration.preview(
      config: install.config, backend: install.backend, diagnostics: diagnostics)
    _ = try HostMigration.prepare(config: install.config, preview: ready)
    // The instance starts again before the service completes: completion refuses.
    try install.backend.startExisting(instance)
    #expect(throws: HostControlError.self) {
      try HostMigration.complete(
        config: install.config, backend: install.backend, diagnostics: diagnostics)
    }
    #expect(try ServiceAdoption.load(instance) == nil)
    try HostMigration.rollback(config: install.config)
    #expect(try HostMigration.loadRecord(install.config)?.state == .rolledBack)
    #expect(try !Owner.load(install.config).isFenced)
    try install.backend.stopUnproven(instance)
  }

  @Test func rollbackWaitsForAStoppingServiceToReleaseItsLock() throws {
    let install = try FakeInstallation()
    defer { install.remove() }
    _ = try legacy(install, "idle")
    let diagnostics = Diagnostics(verbosity: 0, sink: { _ in })
    let ready = try HostMigration.preview(
      config: install.config, backend: install.backend, diagnostics: diagnostics)
    _ = try HostMigration.prepare(config: install.config, preview: ready)
    // A service that could not complete activation still holds its lock.
    let store = try OperationStore(root: HostService.root(install.config))
    let service = try #require(try FileLock.attempt(path: store.serviceLockPath))
    #expect(throws: HostError.self) { try HostMigration.rollback(config: install.config) }
    #expect(try HostMigration.loadRecord(install.config)?.state == .prepared)
    // It exits shortly after being stopped; the rollback waits for that.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { service.release() }
    try HostMigration.rollback(config: install.config, waitingForService: .seconds(5))
    #expect(try HostMigration.loadRecord(install.config)?.state == .rolledBack)
  }
}
