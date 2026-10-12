import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

@Suite struct HostControlLedgerTests {
  @Test func duplicateCreateReturnsTheSameAllocation() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let op = HostOperationID.generate()
    let spec = try f.spec()
    let first = try f.receipt(.vmCreate(spec), operation: op)
    #expect(first.disposition == .accepted)
    // Lost reply: the same id before and after execution yields one instance.
    let again = try f.receipt(.vmCreate(spec), operation: op)
    #expect(again.disposition == .existing)
    #expect(again.instance == first.instance)
    f.supervisor.runPending()
    let done = try f.receipt(.vmCreate(spec), operation: op)
    #expect(done.state == .succeeded)
    #expect(done.instance == first.instance)
    #expect(f.native.calls("create") == 1)
    #expect(f.supervisor.store.instanceIDs().count == 1)
  }

  @Test func conflictingPayloadHasNoEffect() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let op = HostOperationID.generate()
    _ = try f.receipt(.vmCreate(f.spec(name: "a")), operation: op)
    let before = f.supervisor.store.usedSlots()
    #expect(
      failure(f.call(.vmCreate(try f.spec(name: "b")), operation: op)) == .operationIDConflict)
    #expect(f.supervisor.store.usedSlots() == before)
    #expect(f.supervisor.store.instanceIDs().count == 1)
  }

  @Test func duplicateIsAnsweredBeforeDynamicChecks() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let op = HostOperationID.generate()
    let spec = try f.spec()
    _ = try f.receipt(.vmCreate(spec), operation: op)
    f.supervisor.runPending()
    // Runtime qualification changed after acceptance (A28).
    f.native.set { $0.qualified = false }
    #expect(try f.receipt(.vmCreate(spec), operation: op).state == .succeeded)
    // A genuinely new request now fails admission.
    #expect(failure(f.call(.vmCreate(spec), operation: .generate())) == .hostRuntimeUnqualified)
  }

  @Test func ordinaryExhaustionStillAdmitsExactCleanup() throws {
    var settings = HostSupervisor.Settings()
    settings.ledger = .init(maxReceipts: 14, maxBytes: 1 << 30)
    let f = try SupervisorFixture(settings: settings)
    defer { f.cleanup() }
    let (instance, _) = try f.running()
    // Fill ordinary capacity with an unrelated create (rejected once full).
    var refused = false
    for index in 0..<4 {
      if failure(f.call(.vmCreate(try f.spec(name: "fill\(index)")), operation: .generate()))
        == .limitExceeded
      {
        refused = true
        break
      }
      f.supervisor.runPending()
    }
    #expect(refused)
    #expect(f.supervisor.freeSlots() < 6)
    // Stop and destroy use reservations made at admission (A29).
    let current = try VMObservation(wire: f.call(.vmInspect(instance)).get())
    let stop = try f.receipt(.vmStop(instance, expectedGeneration: current.generation))
    #expect(stop.disposition == .accepted)
    f.supervisor.runPending()
    #expect(try f.operation(stop.operationID).state == .succeeded)
    let stopped = try VMObservation(wire: f.call(.vmInspect(instance)).get())
    let destroy = try f.receipt(.vmDestroy(instance, expectedGeneration: stopped.generation))
    #expect(destroy.disposition == .accepted)
    f.supervisor.runPending()
    #expect(try f.operation(destroy.operationID).state == .succeeded)
    #expect(f.native.vm(instance.runtimeID) == nil)
  }

  @Test func repeatedCleanupCoalescesOrIsUnchanged() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let stop = try f.receipt(.vmStop(instance, expectedGeneration: observation.generation))
    let second = try f.receipt(.vmStop(instance, expectedGeneration: observation.generation))
    #expect(second.disposition == .existingCleanup)
    #expect(second.operationID == stop.operationID)
    f.supervisor.runPending()
    let slots = f.supervisor.store.usedSlots()
    let stopped = try VMObservation(wire: f.call(.vmInspect(instance)).get())
    let noop = try f.receipt(.vmStop(instance, expectedGeneration: stopped.generation))
    #expect(noop.disposition == .unchanged)
    #expect(f.supervisor.store.usedSlots() == slots)
    #expect((try? f.supervisor.store.loadOperation(noop.operationID)) == nil)
  }
}

@Suite struct HostControlLifecycleTests {
  @Test func startPersistsDeadlineBeforeBootAndRemoteTTLIsBounded() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let created = try f.receipt(.vmCreate(f.spec()))
    f.supervisor.runPending()
    let instance = try #require(created.instance)
    let policy = try f.spec().policyHash
    #expect(
      failure(
        f.call(
          .vmStart(instance, expectedGeneration: 1, ttlSeconds: 25 * 3_600, policy: policy),
          operation: .generate()))
        == .invalidRequest)
    // Remote start without TTL gets the finite default.
    let start = try f.receipt(
      .vmStart(instance, expectedGeneration: 1, ttlSeconds: nil, policy: policy))
    let accepted = try #require(try f.supervisor.store.loadOperation(start.operationID))
    #expect(accepted.deadline == WireTime(f.clock.now()).seconds + 8 * 3_600)
    f.supervisor.runPending()
    #expect(f.native.state.withLock { $0.lastExpiry } == WireTime(seconds: accepted.deadline!).date)
    let running = try VMObservation(wire: f.call(.vmInspect(instance)).get())
    #expect(running.state == .running)
    #expect(running.generation == 2)
    #expect(running.expiresAt?.seconds == accepted.deadline)
  }

  @Test func localStartMayOmitTTL() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let created = try f.receipt(.vmCreate(f.spec()), transport: .local)
    f.supervisor.runPending()
    let instance = try #require(created.instance)
    let start = try f.receipt(
      .vmStart(instance, expectedGeneration: 1, ttlSeconds: nil, policy: try f.spec().policyHash),
      transport: .local)
    #expect(try f.supervisor.store.loadOperation(start.operationID)?.deadline == nil)
  }

  @Test func staleGenerationAndBusyAreRefused() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    #expect(
      failure(
        f.call(
          .vmStop(instance, expectedGeneration: observation.generation - 1), operation: .generate())
      ) == .generationConflict)
    #expect(
      failure(
        f.call(
          .vmStart(
            instance, expectedGeneration: observation.generation, ttlSeconds: 60,
            policy: try f.spec().policyHash), operation: .generate()))
        == .instanceAlreadyRunning)
    _ = try f.receipt(.vmStop(instance, expectedGeneration: observation.generation))
    #expect(
      failure(
        f.call(
          .vmStart(
            instance, expectedGeneration: observation.generation, ttlSeconds: 60,
            policy: try f.spec().policyHash), operation: .generate()))
        == .instanceBusy)
  }

  @Test func identityFieldsMustAllMatch() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let wrongRuntime = QualifiedInstance(
      hostID: instance.hostID, ownerID: instance.ownerID, instanceID: instance.instanceID,
      runtimeID: try MachineName("iso-abababab-0000000000000000"), guestOS: .linux)
    #expect(
      failure(
        f.call(
          .vmStop(wrongRuntime, expectedGeneration: observation.generation), operation: .generate())
      ) == .instanceIncompatible)
    let wrongHost = QualifiedInstance(
      hostID: .generate(), ownerID: instance.ownerID, instanceID: instance.instanceID,
      runtimeID: instance.runtimeID, guestOS: .linux)
    #expect(failure(f.call(.vmInspect(wrongHost))) == .hostIdentityChanged)
  }

  @Test func remoteMacOSAndLocalOnlyMethodsRefuseBeforeAllocation() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let mac = try VMSpec.make(
      name: InstanceName("m"), image: .default, imageDigest: nil, cpus: 2, memoryMiB: 4096,
      diskGiB: 8, guestOS: .macos, egress: .open)
    #expect(failure(f.call(.vmCreate(mac), operation: .generate())) == .unsupportedCapability)
    let (instance, _) = try f.running()
    #expect(
      failure(
        f.call(
          .maintenance(
            instance, expectedGeneration: 2, .resize(cpus: 4, memoryMiB: nil, diskGiB: nil)),
          operation: .generate())
      )
        == .unsupportedCapability)
    #expect(f.native.calls("create") == 1)
  }

  @Test func deadlineSweepStopsAndCommits() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    f.clock.advance(.seconds(3_601))
    f.supervisor.enforceDeadlines()
    #expect(f.native.vm(instance.runtimeID) == .stopped)
    let after = try VMObservation(wire: f.call(.vmInspect(instance)).get())
    #expect(after.state == .stopped)
    #expect(after.generation == observation.generation + 1)
    // Expiry does not block observation or cleanup.
    let destroy = try f.receipt(.vmDestroy(instance, expectedGeneration: after.generation))
    f.supervisor.runPending()
    #expect(try f.operation(destroy.operationID).state == .succeeded)
  }

  @Test func unreachableRuntimeIsUnknownNotStopped() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, _) = try f.running()
    f.native.inject("observe", .unavailable("runtime down"))
    let observation = try VMObservation(wire: f.call(.vmInspect(instance)).get())
    #expect(observation.state == .unknown)
    #expect(f.native.vm(instance.runtimeID) != .stopped)
  }
}

@Suite struct HostControlRecoveryTests {
  @Test func lostCreateReplyReconcilesWithoutReallocation() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let op = HostOperationID.generate()
    let spec = try f.spec()
    f.native.injectAfterEffect("create", .uncertain("reply lost"))
    let accepted = try f.receipt(.vmCreate(spec), operation: op)
    f.supervisor.runPending()
    #expect(try f.operation(op).state == .reconciling)
    // Supervisor restart: new epoch, same durable operation (A10/A11).
    let restarted = try f.restarted()
    #expect(restarted.supervisor.epoch != f.supervisor.epoch)
    #expect(restarted.hostID == f.hostID)
    restarted.supervisor.runPending()
    let done = try restarted.receipt(.vmCreate(spec), operation: op)
    #expect(done.state == .succeeded)
    #expect(done.instance == accepted.instance)
    #expect(f.native.calls("create") == 1)
  }

  @Test func reconcilingStartNeverBootsTwiceOrMovesTheDeadline() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let created = try f.receipt(.vmCreate(f.spec()))
    f.supervisor.runPending()
    let instance = try #require(created.instance)
    let op = HostOperationID.generate()
    let body = HostRequestBody.vmStart(
      instance, expectedGeneration: 1, ttlSeconds: 600, policy: try f.spec().policyHash)
    f.native.inject("observe", .uncertain("lost"))
    _ = try f.receipt(body, operation: op)
    f.supervisor.runPending()
    let deadline = try f.supervisor.store.loadOperation(op)?.deadline
    f.clock.advance(.seconds(30))
    let restarted = try f.restarted()
    restarted.supervisor.runPending()
    #expect(f.native.calls("start") == 1)
    let receipt = try restarted.receipt(body, operation: op)
    #expect(receipt.state == .succeeded)
    #expect(receipt.expiresAt?.seconds == deadline)
  }

  @Test func delayedCreateReplayAfterDestroyIsHistorical() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let op = HostOperationID.generate()
    let spec = try f.spec()
    let created = try f.receipt(.vmCreate(spec), operation: op)
    f.supervisor.runPending()
    let instance = try #require(created.instance)
    _ = try f.receipt(.vmDestroy(instance, expectedGeneration: 1))
    f.supervisor.runPending()
    let replay = try f.receipt(.vmCreate(spec), operation: op)
    #expect(replay.state == .succeeded)
    #expect(replay.disposition == .existing)
    #expect(replay.instance == instance)
    #expect(try VMObservation(wire: f.call(.vmInspect(instance)).get()).state == .destroyed)
    #expect(f.native.calls("create") == 1)
    #expect(f.native.vm(instance.runtimeID) == nil)
    // Destroy again is a no-op observation.
    #expect(try f.receipt(.vmDestroy(instance, expectedGeneration: 2)).disposition == .unchanged)
  }

  @Test func interruptedCreateKeepsItsIdentityForExplicitDestroy() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    // The runtime was asked, then the reply was lost and nothing appeared.
    f.native.inject("create", .uncertain("reply lost"))
    let created = try f.receipt(.vmCreate(f.spec()))
    f.supervisor.runPending()
    #expect(try f.operation(created.operationID).state == .reconciling)
    f.supervisor.runPending()
    let failed = try f.operation(created.operationID)
    #expect(failed.state == .failed)
    // No second create; the reserved identity is retained, not tombstoned.
    #expect(f.native.calls("create") == 1)
    let instance = try #require(created.instance)
    #expect(try VMObservation(wire: f.call(.vmInspect(instance)).get()).state == .unknown)
    let destroy = try f.receipt(.vmDestroy(instance, expectedGeneration: 0))
    f.supervisor.runPending()
    #expect(try f.operation(destroy.operationID).state == .succeeded)
    #expect(try VMObservation(wire: f.call(.vmInspect(instance)).get()).state == .destroyed)
  }

  @Test func unavailableRuntimeRetriesTheCreateItNeverAttempted() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    f.native.inject("create", .unavailable("runtime not running"))
    let created = try f.receipt(.vmCreate(f.spec()))
    f.supervisor.runPending()
    #expect(try f.operation(created.operationID).state == .reconciling)
    f.supervisor.runPending()
    #expect(try f.operation(created.operationID).state == .succeeded)
    #expect(f.native.calls("create") == 2)
  }

  @Test func aStartThatFailedItsChecksIsStoppedNotHandedOut() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let created = try f.receipt(.vmCreate(f.spec()))
    f.supervisor.runPending()
    let instance = try #require(created.instance)
    // The boot happened but its isolation/pin check failed.
    f.native.injectAfterEffect("start", .failed("isolation gate refused"))
    let start = try f.receipt(
      .vmStart(instance, expectedGeneration: 1, ttlSeconds: 600, policy: try f.spec().policyHash))
    f.supervisor.runPending()
    #expect(try f.operation(start.operationID).state == .failed)
    #expect(f.native.vm(instance.runtimeID) == .stopped)
    #expect(try VMObservation(wire: f.call(.vmInspect(instance)).get()).state == .stopped)
  }

  @Test func uncertainStopStaysReconcilingUntilVerified() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    f.native.inject("stop", .uncertain("timeout"))
    let stop = try f.receipt(.vmStop(instance, expectedGeneration: observation.generation))
    f.supervisor.runPending()
    #expect(try f.operation(stop.operationID).state == .reconciling)
    #expect(f.native.vm(instance.runtimeID) != .stopped)
    f.supervisor.runPending()
    #expect(try f.operation(stop.operationID).state == .succeeded)
    #expect(f.native.vm(instance.runtimeID) == .stopped)
  }
}

@Suite struct HostControlCancellationTests {
  @Test func cancelWinsOnlyBeforeTheEffect() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let created = try f.receipt(.vmCreate(f.spec()))
    let cancelled = try OperationReceipt(
      wire: f.call(.operationCancel(target: created.operationID)).get())
    #expect(cancelled.state == .cancelled)
    // Repeated cancellation returns the same disposition.
    let again = try OperationReceipt(
      wire: f.call(.operationCancel(target: created.operationID)).get())
    #expect(again.state == .cancelled)
    f.supervisor.runPending()
    #expect(f.native.calls("create") == 0)
    let instance = try #require(created.instance)
    #expect(try VMObservation(wire: f.call(.vmInspect(instance)).get()).state == .destroyed)
  }

  @Test func lateCancelIsRefusedWithoutRelabeling() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    f.native.injectAfterEffect("create", .uncertain("lost"))
    let created = try f.receipt(.vmCreate(f.spec()))
    f.supervisor.runPending()
    #expect(failure(f.call(.operationCancel(target: created.operationID))) == .cancelTooLate)
    #expect(try f.operation(created.operationID).state == .reconciling)
    f.supervisor.runPending()
    #expect(try f.operation(created.operationID).state == .succeeded)
    let terminal = try OperationReceipt(
      wire: f.call(.operationCancel(target: created.operationID)).get())
    #expect(terminal.state == .succeeded)
  }

  @Test func cleanupCannotBeCancelled() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let stop = try f.receipt(.vmStop(instance, expectedGeneration: observation.generation))
    #expect(failure(f.call(.operationCancel(target: stop.operationID))) == .unsupportedCapability)
    #expect(failure(f.call(.operationCancel(target: .generate()))) == .operationNotFound)
  }
}

@Suite struct HostControlImageTests {
  func request(_ name: String, os: GuestOS = .linux) throws -> HostRequestBody {
    .imageEnsure(
      try ImageRequest(
        image: ImageName(name), guestOS: os, profiles: ["rust"], guestUser: .default,
        rebuild: false))
  }

  @Test func createRequiresAWorkerPreparedImage() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let spec = try VMSpec.make(
      name: InstanceName("p"), image: ImageName("custom"), imageDigest: nil, cpus: 2,
      memoryMiB: 4096, diskGiB: 8, guestOS: .linux, egress: .open)
    #expect(failure(f.call(.vmCreate(spec), operation: .generate())) == .instanceIncompatible)
    let ensure = try f.receipt(try request("custom"))
    f.supervisor.runPending()
    let done = try f.operation(ensure.operationID)
    #expect(done.state == .succeeded)
    #expect(done.outcome?.contains("custom") == true)
    #expect(try f.receipt(.vmCreate(spec)).disposition == .accepted)
  }

  @Test func oneBuildPerImageAndRetriesAreIdempotent() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let op = HostOperationID.generate()
    let body = try request("custom")
    _ = try f.receipt(body, operation: op)
    #expect(failure(f.call(body, operation: .generate())) == .instanceBusy)
    // A restarted service still treats the image as busy.
    let restarted = try f.restarted()
    #expect(failure(restarted.call(body, operation: .generate())) == .instanceBusy)
    f.native.injectAfterEffect("image", .uncertain("lost"))
    f.supervisor.runPending()
    #expect(try f.operation(op).state == .reconciling)
    f.supervisor.runPending()
    #expect(try f.operation(op).state == .succeeded)
    // Same id after success: history, no third build.
    #expect(try f.receipt(body, operation: op).disposition == .existing)
    #expect(f.native.state.withLock { $0.builds } == 2)
    _ = try f.receipt(body)
  }

  @Test func macOSImagesAreRefusedBeforeWork() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    #expect(
      failure(f.call(try request("mac", os: .macos), operation: .generate()))
        == .unsupportedCapability)
    #expect(f.native.state.withLock { $0.builds } == 0)
    #expect(throws: ValidationError.self) {
      try ImageRequest(
        image: .default, guestOS: .linux, profiles: ["../x"], guestUser: .default, rebuild: false)
    }
  }
}

@Suite struct HostControlLocalCapabilitiesTests {
  @Test func stoppedMaintenanceRunsLocallyAndUpdatesPolicy() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let created = try f.receipt(.vmCreate(f.spec()), transport: .local)
    f.supervisor.runPending()
    let instance = try #require(created.instance)
    let resize = try f.receipt(
      .maintenance(instance, expectedGeneration: 1, .resize(cpus: 4, memoryMiB: nil, diskGiB: 32)),
      transport: .local)
    f.supervisor.runPending()
    #expect(try f.operation(resize.operationID).state == .succeeded)
    let after = try VMObservation(wire: f.call(.vmInspect(instance), transport: .local).get())
    #expect(after.generation == 2)
    #expect(after.policyHash != (try f.spec().policyHash))
    // The old policy no longer starts it; the new one does.
    #expect(
      failure(
        f.call(
          .vmStart(
            instance, expectedGeneration: 2, ttlSeconds: nil, policy: try f.spec().policyHash),
          operation: .generate(), transport: .local))
        == .instanceIncompatible)
    let started = try f.receipt(
      .vmStart(
        instance, expectedGeneration: 2, ttlSeconds: nil, policy: try #require(after.policyHash)),
      transport: .local)
    #expect(started.disposition == .accepted)
  }

  @Test func maintenanceNeedsAStoppedVMAndIsLocalOnly() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let (instance, observation) = try f.running()
    let commit = HostRequestBody.maintenance(
      instance, expectedGeneration: observation.generation, .commit(try ImageName("snap")))
    #expect(failure(f.call(commit, operation: .generate(), transport: .local)) == .instanceBusy)
    #expect(
      failure(f.call(commit, operation: .generate(), transport: .ssh)) == .unsupportedCapability)
    #expect(
      failure(
        f.call(
          .localCapability(.macosComputerUseInput, instance, expectedGeneration: 2),
          operation: .generate(), transport: .local))
        == .unsupportedCapability)
    #expect(f.native.calls("maintain") == 0)
    let local = f.supervisor.hello(transport: .local).methods
    let remote = f.supervisor.hello(transport: .ssh).methods
    #expect(local.contains(.vmResize) && !remote.contains(.vmResize))
  }
}
