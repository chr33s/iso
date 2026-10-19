import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

// A boot that ended outside the service (a worker reboot or a crashed owner)
// must not leave the ledger claiming `running`: found by the two-Mac N-T12
// reboot run, where `vm.start` refused a VM `vm.inspect` showed stopped.

@Test func aStartAfterTheBootEndedBehindTheServiceIsAdmitted() throws {
  let f = try SupervisorFixture()
  defer { f.cleanup() }
  let (instance, running) = try f.running()
  #expect(running.state == .running)
  // The worker rebooted: the runtime now reports the VM stopped, and no
  // sweep has committed it yet.
  f.native.set { $0.vms[instance.runtimeID] = .stopped }
  let observed = try VMObservation(wire: f.call(.vmInspect(instance)).get())
  #expect(observed.state == .stopped)
  let start = try f.receipt(
    .vmStart(
      instance, expectedGeneration: observed.generation, ttlSeconds: 3_600,
      policy: try f.spec().policyHash))
  #expect(start.disposition == .accepted)
  f.supervisor.runPending()
  let restarted = try VMObservation(wire: f.call(.vmInspect(instance)).get())
  #expect(restarted.state == .running)
  #expect(restarted.bootID != nil && restarted.bootID != running.bootID)
}

@Test func aStartIsStillRefusedWhileTheRuntimeReportsTheBootRunning() throws {
  let f = try SupervisorFixture()
  defer { f.cleanup() }
  let (instance, running) = try f.running()
  #expect(
    failure(
      f.call(
        .vmStart(
          instance, expectedGeneration: running.generation, ttlSeconds: 3_600,
          policy: try f.spec().policyHash), operation: .generate())) == .instanceAlreadyRunning)
}
