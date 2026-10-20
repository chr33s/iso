import Foundation
import IsoConfiguration
import IsoCore
import Testing

@testable import IsoHost

/// `run.retain`: host-owned live and stopped-disk retention of disposable runs.
@Suite struct HostControlRetentionTests {
  func create(_ f: SupervisorFixture, ttl: UInt64 = 3_600) throws -> RunID {
    let run = RunID.generate()
    _ = try f.receipt(
      .runCreate(
        run: run, spec: try f.spec(name: "run", egress: .none), outputLimitBytes: 1 << 20,
        ttlSeconds: ttl))
    f.supervisor.runPending()
    return run
  }

  func inspect(_ f: SupervisorFixture, _ run: RunID) throws -> RunObservation {
    try RunObservation(wire: f.call(.runInspect(run)).get())
  }

  func retain(
    _ f: SupervisorFixture, _ run: RunID, _ mode: RetentionMode, _ seconds: UInt64,
    operation: HostOperationID = .generate()
  ) throws -> OperationReceipt {
    let state = try inspect(f, run)
    let receipt = try f.receipt(
      .runRetain(run: run, expectedGeneration: state.generation, mode: mode, seconds: seconds),
      operation: operation)
    f.supervisor.runPending()
    return receipt
  }

  @Test func liveRetentionKeepsTheRunWithoutAControllerUntilItsDeadline() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    let before = try inspect(f, run)
    #expect(before.liveRetentionUntil == nil)
    #expect(f.call(.runInspect(run)).map { $0["live_retention_until"] } == .success(nil))
    let receipt = try retain(f, run, .live, 600)
    #expect(receipt.disposition == .accepted)
    #expect(try f.operation(receipt.operationID).state == .succeeded)
    let retained = try inspect(f, run)
    let until = try #require(retained.liveRetentionUntil)
    #expect(until.seconds == f.supervisor.now.seconds + 600)
    // No controlling session for longer than the grace: still running.
    f.clock.advance(.seconds(Int64(RunStore.controllerGraceSeconds) + 5))
    f.supervisor.runPending()
    #expect(try inspect(f, run).phase == .running)
    // At the deadline it stops, with no implicit export.
    let exports = f.native.calls("export")
    f.clock.advance(.seconds(600))
    f.supervisor.runPending()
    let ended = try inspect(f, run)
    #expect(ended.phase == .stoppedDiskPendingExport)
    #expect(f.native.calls("export") == exports)
  }

  @Test func liveRetentionNeverPassesTheVMHardDeadline() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f, ttl: 900)
    let instance = try #require(try inspect(f, run).instanceID)
    let expires = try #require(try f.supervisor.store.loadInstance(instance)?.expiresAt)
    _ = try retain(f, run, .live, RunStore.maxLiveRetentionSeconds)
    #expect(try inspect(f, run).liveRetentionUntil?.seconds == expires)
  }

  @Test func liveRetentionIsCappedFromTheFirstRequest() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f, ttl: 86_400)
    let start = f.supervisor.now.seconds
    _ = try retain(f, run, .live, RunStore.maxLiveRetentionSeconds)
    f.clock.advance(.seconds(10_000))
    f.supervisor.runPending()
    // A renewal inside the window does not move the cap.
    _ = try retain(f, run, .live, RunStore.maxLiveRetentionSeconds)
    #expect(
      try inspect(f, run).liveRetentionUntil?.seconds == start + RunStore.maxLiveRetentionSeconds)
  }

  @Test func liveRetentionRevokesExistingGrants() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    let id = try #require(try inspect(f, run).instanceID)
    let instance = try #require(try f.supervisor.store.loadInstance(id)?.qualified)
    let observation = try VMObservation(wire: f.call(.vmInspect(instance)).get())
    _ = try AccessGrant(wire: f.open(try f.openRequest(instance, observation)).get())
    #expect(f.supervisor.sessions.hasLiveSession(instance: id))
    _ = try retain(f, run, .live, 600)
    #expect(!f.supervisor.sessions.hasLiveSession(instance: id))
  }

  @Test func anOpenDebugSessionDoesNotOutliveLiveRetention() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    _ = try retain(f, run, .live, 600)
    let id = try #require(try inspect(f, run).instanceID)
    let instance = try #require(try f.supervisor.store.loadInstance(id)?.qualified)
    let observation = try VMObservation(wire: f.call(.vmInspect(instance)).get())
    let request = try f.openRequest(instance, observation)
    let grant = try AccessGrant(wire: f.open(request).get())
    // Keep the debug grant renewed past the window's end.
    for _ in 0..<31 {
      f.clock.advance(.seconds(20))
      _ = f.call(
        .accessRenew(
          session: grant.session, bearer: request.bearer, epoch: grant.epoch, boot: grant.bootID,
          policy: grant.policyHash))
    }
    #expect(f.supervisor.sessions.hasLiveSession(instance: id))
    f.supervisor.runPending()
    #expect(try inspect(f, run).phase == .stoppedDiskPendingExport)
  }

  @Test func aLiveRetainedRunIsReleasedByDiscardAndCompleteStillWorks() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    // Discarding a running run without live retention is refused.
    let plain = try create(f)
    let state = try inspect(f, plain)
    #expect(
      failure(
        f.call(
          .runResultsDiscard(run: plain, expectedGeneration: state.generation),
          operation: .generate())) == .resultsUnavailable)
    _ = try retain(f, plain, .live, 600)
    let instance = try #require(try inspect(f, plain).instanceID)
    let runtime = try #require(try f.supervisor.store.loadInstance(instance)?.runtimeID)
    _ = try f.receipt(
      .runResultsDiscard(run: plain, expectedGeneration: try inspect(f, plain).generation))
    f.supervisor.runPending()
    #expect(try inspect(f, plain).phase == .destroyed)
    #expect(f.native.vm(runtime) == nil)

    // run.complete still exports during live retention.
    let other = try create(f)
    _ = try retain(f, other, .live, 600)
    _ = try f.receipt(
      .runComplete(run: other, expectedGeneration: try inspect(f, other).generation, exitStatus: 0))
    f.supervisor.runPending()
    #expect(try inspect(f, other).phase == .resultsPending)
  }

  @Test func stoppedRetentionExtendsButNeverShortensAndStaysFinite() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    _ = try f.receipt(
      .runComplete(run: run, expectedGeneration: try inspect(f, run).generation, exitStatus: 0))
    f.supervisor.runPending()
    let first = try #require(try inspect(f, run).retentionDeadline)
    _ = try retain(f, run, .stopped, 7_200)
    let extended = try #require(try inspect(f, run).retentionDeadline)
    #expect(extended.seconds == f.supervisor.now.seconds + 7_200)
    #expect(extended > first)
    _ = try retain(f, run, .stopped, 60)
    #expect(try inspect(f, run).retentionDeadline == extended)
    // A maximal request made later is capped from the first stop.
    let stopped = try #require(try f.supervisor.runs.load(run)?.firstStopAt)
    f.clock.advance(.seconds(7_000))
    _ = try retain(f, run, .stopped, RunStore.maxStoppedRetentionSeconds)
    let capped = stopped + RunStore.maxStoppedRetentionSeconds
    #expect(try inspect(f, run).retentionDeadline?.seconds == capped)
    // Past the cap the run is destroyed like any other expiry, and an expired
    // window is not extended.
    f.clock.advance(.seconds(Int64(RunStore.maxStoppedRetentionSeconds)))
    #expect(
      failure(
        f.call(
          .runRetain(
            run: run, expectedGeneration: try inspect(f, run).generation, mode: .stopped,
            seconds: 60), operation: .generate())) == .resultsUnavailable)
    f.supervisor.runPending()
    #expect(try inspect(f, run).phase == .destroyed)
  }

  @Test func retainIsPhaseCheckedAndIdempotentByOperationID() throws {
    let f = try SupervisorFixture()
    defer { f.cleanup() }
    let run = try create(f)
    let state = try inspect(f, run)
    // Stopped retention needs a stopped run.
    #expect(
      failure(
        f.call(
          .runRetain(run: run, expectedGeneration: state.generation, mode: .stopped, seconds: 60),
          operation: .generate())) == .resultsUnavailable)
    // Stale generation.
    #expect(
      failure(
        f.call(
          .runRetain(run: run, expectedGeneration: state.generation + 9, mode: .live, seconds: 60),
          operation: .generate())) == .generationConflict)
    let id = HostOperationID.generate()
    let body = HostRequestBody.runRetain(
      run: run, expectedGeneration: state.generation, mode: .live, seconds: 60)
    #expect(try f.receipt(body, operation: id).disposition == .accepted)
    #expect(try f.receipt(body, operation: id).disposition == .existing)
    let other = HostRequestBody.runRetain(
      run: run, expectedGeneration: state.generation, mode: .live, seconds: 61)
    #expect(failure(f.call(other, operation: id)) == .operationIDConflict)
    f.supervisor.runPending()
    // An unknown run.
    #expect(
      failure(
        f.call(
          .runRetain(run: .generate(), expectedGeneration: 1, mode: .live, seconds: 60),
          operation: .generate())) == .resultsUnavailable)
  }

  @Test func retainDecodingIsStrict() throws {
    func decode(_ params: String, operation: Bool = true) -> HostControlError.Code? {
      let id = operation ? #","operation_id":"\#(HostOperationID.generate())""# : ""
      let frame =
        #"{"protocol":"iso.host/v1","request_id":"\#(RequestID.generate())","host_id":"\#(HostID.generate())","owner_id":"\#(String(repeating: "ab", count: 16))","method":"run.retain"\#(id),"params":\#(params)}"#
      do {
        _ = try HostRequest.decode(frame: Array(frame.utf8))
        return nil
      } catch {
        switch error {
        case .correlated(_, let failure), .uncorrelated(let failure): return failure.code
        }
      }
    }
    let run = RunID.generate()
    let base = #""run_id":"\#(run)","expected_generation":1"#
    #expect(decode(#"{\#(base),"mode":"live","seconds":60}"#) == nil)
    #expect(decode(#"{\#(base),"mode":"live","seconds":60}"#, operation: false) == .invalidRequest)
    #expect(decode(#"{\#(base),"mode":"forever","seconds":60}"#) == .invalidRequest)
    #expect(decode(#"{\#(base),"mode":"live","seconds":0}"#) == .invalidRequest)
    #expect(decode(#"{\#(base),"mode":"live","seconds":14401}"#) == .invalidRequest)
    #expect(decode(#"{\#(base),"mode":"stopped","seconds":604801}"#) == .invalidRequest)
    #expect(decode(#"{\#(base),"mode":"live","seconds":60,"extra":1}"#) == .invalidRequest)
  }
}
