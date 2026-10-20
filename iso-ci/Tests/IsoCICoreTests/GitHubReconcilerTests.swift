import Foundation
import Testing

@testable import IsoCICore

@Suite struct GitHubReconcilerTests {
  @Test func createsOneProvenRunnerAndDeliversJITOnlyOnStdin() throws {
    let h = try GitHubReconcilerHarness()
    let report = h.reconciler.reconcile()
    #expect(report.created.count == 1)
    let allocation = try #require(try h.open().first)
    #expect(allocation.registration == .registered)
    #expect(allocation.runnerID == 100)
    #expect(allocation.actualRunnerVersion == "2.338.0")
    #expect(
      allocation.runnerName
        == ConnectedPoolReconciler.runnerName(controller: h.controller, allocation: allocation.id))
    // The VM is proven before any bootstrap material is requested or sent.
    let order = h.provider.calls.map(\.name)
    #expect(order.firstIndex(of: "provision")! < order.firstIndex(of: "execute")!)
    let bootstrap = try #require(
      h.provider.state.withLock {
        $0.commands.first { $0.command.argv.contains("iso-ci-bootstrap") }
      })
    let encoded = GitHubFakeRunners.encodedJIT(id: 100)
    #expect(String(decoding: bootstrap.command.stdin, as: UTF8.self) == encoded)
    #expect(!bootstrap.command.argv.joined().contains(encoded))
    #expect(!bootstrap.command.recordOutput)
    // The JIT intent was persisted and confirmed.
    let intents = try h.store.intents(allocation: allocation.id)
    #expect(intents.map(\.kind) == [.githubJITCreate])
    #expect(intents.first?.status == .confirmed)
    #expect(!(try h.store.events(after: 0).map(\.message).joined().contains(encoded)))
    // Second pass: the starting allocation fills the idle slot.
    let second = h.reconciler.reconcile()
    #expect(second.created.isEmpty)
    #expect(second.deficit == 0)
  }

  /// Regression: an unassigned warm allocation has no job identity, even
  /// while GitHub runs other jobs on other runners.
  // A per-account service host GitHub assigns but the approved policy does
  // not name: the runner is never started and the pool pauses explicitly.
  @Test func unapprovedJITServiceHostPausesThePoolBeforeBootstrap() throws {
    let h = try GitHubReconcilerHarness()
    let shard = "pipelines7.unreviewed-shard.example.net"
    h.runners.state.withLock { $0.serviceHost = shard }
    h.reconciler.reconcile()
    #expect(
      !h.provider.state.withLock {
        $0.commands.contains { $0.command.argv.contains("iso-ci-bootstrap") }
      })
    let status = try #require(try h.store.poolStatus("validation"))
    #expect(status.state == .paused)
    #expect(status.reason?.contains(shard) == true)
    #expect(try h.open().allSatisfy { $0.desired != .active })
    // The approved hosts pass; anything unreadable fails closed.
    let approved = GitHubJITConfig(
      runner: GitHubRunnerInfo(
        id: 1, name: "r", status: "online", busy: false, labels: [], runnerGroupID: 1),
      encoded: RedactedSecret(GitHubFakeRunners.encodedJIT(id: 1)))
    #expect(approved.serviceHosts() == ["broker.actions.githubusercontent.com", "github.com"])
    // A shard under the reviewed wildcard is approved without listing it.
    let reviewed = try GitHubReconcilerHarness()
    reviewed.runners.state.withLock {
      $0.serviceHost = "pipelinesghubeus21.actions.githubusercontent.com"
    }
    reviewed.reconciler.reconcile()
    #expect(try reviewed.store.poolStatus("validation")?.state == .active)
    #expect(
      reviewed.provider.state.withLock {
        $0.commands.contains { $0.command.argv.contains("iso-ci-bootstrap") }
      })
    let opaque = GitHubJITConfig(runner: approved.runner, encoded: RedactedSecret("opaque"))
    #expect(opaque.serviceHosts() == nil)
  }

  @Test func unassignedWarmAllocationHasNoJobIdentity() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    h.runners.addForeignRunner(name: "someone-else")
    h.runners.assign(jobID: 9, toRunnerNamed: "someone-else", repository: h.repository)
    h.reconciler.reconcile()
    let allocation = try #require(try h.open().first)
    #expect(allocation.job == nil)
    #expect(allocation.assignedAt == nil)
    #expect(allocation.execution == .pending)
    #expect(allocation.phase == "idle")
  }

  /// Regression: lost JIT response. The registration exists but its reply
  /// was lost: no blind retry; the exact owned registration is found by
  /// name in the right scope, removed by id, and only then re-requested.
  @Test func lostJITResponseReconcilesExactOwnedRegistration() throws {
    let h = try GitHubReconcilerHarness()
    h.runners.state.withLock { $0.loseNextJITReply = true }
    let first = h.reconciler.reconcile()
    var allocation = try #require(try h.open().first)
    #expect(allocation.registration == .uncertain)
    #expect(first.errors.contains { $0.contains("REGISTRATION_UNCERTAIN") })
    #expect(try h.store.intents(allocation: allocation.id).first?.status == .uncertain)
    #expect(h.runners.state.withLock { $0.jitCalls.count } == 1)

    let second = h.reconciler.reconcile()
    allocation = try #require(try h.store.allocation(allocation.id))
    #expect(h.runners.state.withLock { $0.deleted } == [100])
    #expect(h.runners.state.withLock { $0.jitCalls.count } == 2)
    #expect(allocation.registration == .registered)
    #expect(allocation.runnerID == 101)
    #expect(second.created.isEmpty)
    let kinds = try h.store.intents(allocation: allocation.id).map {
      "\($0.kind.rawValue):\($0.status.rawValue)"
    }
    #expect(
      kinds == [
        "github.jit.create:confirmed", "github.runner.delete:confirmed",
        "github.jit.create:confirmed",
      ])
  }

  @Test func unresolvedRegistrationBlocksCapacityAndKeepsResources() throws {
    let h = try GitHubReconcilerHarness(desiredIdle: 2)
    h.runners.state.withLock {
      $0.jitFailure = CIError(.githubUnavailable, "reset", details: ["uncertain": "true"])
    }
    h.reconciler.reconcile()
    #expect(try h.open().count == 1)
    h.runners.state.withLock {
      $0.jitFailure = nil
      $0.lookupFailure = CIError(.githubRefused, "forbidden")
    }
    let report = h.reconciler.reconcile()
    let allocation = try #require(try h.open().first)
    #expect(allocation.registration == .uncertain)
    #expect(allocation.holdsResources)
    #expect(h.provider.calls("release").isEmpty)
    #expect(report.created.isEmpty)
    #expect(report.admissionPaused?.contains("uncertainty") == true)
    #expect(HostLoad.of(try h.open()).vms == 1)
    // Repeated failed lookups escalate to supervised resolution.
    for _ in 0..<ConnectedPoolReconciler.maxRegistrationLookups { h.reconciler.reconcile() }
    #expect(try h.store.allocation(allocation.id)?.uncertainty?.contains("supervised") == true)
    // The operator asserts no registration exists; the VM is then released.
    try h.reconciler.superviseRegistration(allocation.id, runnerID: nil)
    h.runners.state.withLock { $0.lookupFailure = nil }
    h.reconciler.reconcile()
    #expect(try h.store.allocation(allocation.id)?.vmCleanup == .verified)
  }

  @Test func deletionIsExactlyOwnedNeverByPrefix() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    let prefix = "iso-ci-\(h.controller.short)-"
    h.runners.addForeignRunner(name: prefix + "not-ours")
    h.runners.addForeignRunner(name: prefix)
    try PoolControl.drain("validation", store: h.store)
    let report = h.reconciler.reconcile()
    #expect(report.retired.count == 1)
    #expect(h.runners.state.withLock { $0.deleted } == [100])
    let names = h.runners.state.withLock { $0.runners.values.map(\.name) }
    #expect(Set(names) == [prefix + "not-ours", prefix])
  }

  @Test func drainWaitsForAssignedWorkAbortStopsIt() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    let id = try #require(try h.open().first).id
    let name = try #require(try h.store.allocation(id)?.runnerName)
    h.runners.assign(jobID: 1, toRunnerNamed: name, repository: h.repository)
    h.reconciler.reconcile()
    #expect(try h.store.allocation(id)?.job?.jobID == 1)
    #expect(try h.store.allocation(id)?.execution == .running)
    // The assigned runner no longer counts as idle, so a replacement exists.
    #expect(try h.open().count == 2)
    try PoolControl.drain("validation", store: h.store)
    h.reconciler.reconcile()
    // Drain retires the idle replacement but leaves the assigned job alone.
    #expect(!h.provider.calls("release").contains { $0.allocation == id })
    #expect(h.provider.calls("release").count == 1)
    #expect(try h.store.allocation(id)?.registration == .assigned)
    try PoolControl.abort(id, store: h.store)
    h.reconciler.reconcile()
    let after = try #require(try h.store.allocation(id))
    #expect(after.execution == .interrupted)
    #expect(after.vmCleanup == .verified)
    #expect(h.runners.state.withLock { $0.deleted }.contains(100))
    // The GitHub conclusion is never invented.
    #expect(after.job?.conclusion == nil)
  }

  @Test func idleRunnersRetireBeforeTheJobAllowanceRunsOut() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    let allocation = try #require(try h.open().first)
    let retire = try #require(allocation.idleRetireAt)
    #expect(retire <= allocation.hardDeadline - h.limits.jobSeconds - h.limits.stopGraceSeconds)
    h.clock.advance(retire - h.clock.now() + 1)
    let report = h.reconciler.reconcile()
    #expect(report.retired == [allocation.id])
    #expect(try h.store.allocation(allocation.id)?.vmCleanup == .verified)
    #expect(h.runners.state.withLock { $0.deleted } == [100])
    // Fresh capacity replaces it; the old VM is never reused.
    #expect(report.created.count == 1)
    #expect(report.created.first != allocation.id)
  }

  @Test func unreachableWorkerKeepsBudgetsAndInventsNoCleanup() throws {
    let h = try GitHubReconcilerHarness(desiredIdle: 2, maxLive: 2)
    h.reconciler.reconcile()
    h.provider.state.withLock { $0.downHosts = ["local"] }
    let ids = try h.open().map(\.id)
    for id in ids { try PoolControl.abort(id, store: h.store) }
    let report = h.reconciler.reconcile()
    #expect(!report.uncertain.isEmpty)
    #expect(h.provider.calls("release").isEmpty)
    #expect(report.created.isEmpty)
    for id in ids {
      let allocation = try #require(try h.store.allocation(id))
      #expect(allocation.holdsResources)
      #expect(allocation.vmCleanup != .verified)
    }
    #expect(HostLoad.of(try h.store.openAllocations(host: "local")).vms == UInt32(ids.count))
  }

  @Test func labelMismatchDeactivatesThePool() throws {
    let h = try GitHubReconcilerHarness()
    h.runners.state.withLock { $0.reportedLabels = ["self-hosted", "Linux", "X64", "other"] }
    h.reconciler.reconcile()
    #expect(try h.store.poolStatus("validation")?.state == .inactive)
    let allocation = try #require(try h.store.recentAllocations(limit: 1).first)
    #expect(allocation.desired == .stop || allocation.vmCleanup == .verified)
    h.reconciler.reconcile()
    #expect(try h.store.allocation(allocation.id)?.vmCleanup == .verified)
    #expect(h.runners.state.withLock { $0.deleted } == [100])
  }

  @Test func caseInsensitiveLabelsMatch() throws {
    let h = try GitHubReconcilerHarness()
    h.runners.state.withLock { $0.reportedLabels = ["SELF-HOSTED", "Linux", "arm64", "ISO-CI"] }
    h.reconciler.reconcile()
    #expect(try h.store.poolStatus("validation")?.state == .active)
  }

  @Test func unexpectedRunnerVersionDrainsBeforeAnyJIT() throws {
    let h = try GitHubReconcilerHarness()
    h.provider.state.withLock { $0.runnerVersion = "2.300.0" }
    h.reconciler.reconcile()
    #expect(h.runners.state.withLock { $0.jitCalls.isEmpty })
    #expect(try h.store.poolStatus("validation")?.state == .draining)
    let allocation = try #require(try h.store.recentAllocations(limit: 1).first)
    #expect(allocation.actualRunnerVersion == "2.300.0")
    #expect(allocation.vmCleanup == .verified)
  }

  @Test func consecutiveSmokeJobsUseDifferentVMsAndRegistrations() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    let first = try #require(try h.open().first)
    h.runners.assign(jobID: 1, toRunnerNamed: first.runnerName!, repository: h.repository)
    h.reconciler.reconcile()
    // Fresh replacement capacity was created as soon as the first runner
    // was assigned.
    let secondID = try #require(try h.open().first { $0.id != first.id }?.id)
    h.provider.state.withLock { $0.runnerStatus[first.id] = "exited 0" }
    h.runners.complete(jobID: 1, conclusion: "success")
    h.reconciler.reconcile()
    let finished = try #require(try h.store.allocation(first.id))
    #expect(finished.vmCleanup == .verified)
    #expect(finished.runnerExitStatus == 0)
    #expect(finished.job?.conclusion == "success")
    let second = try #require(try h.store.allocation(secondID))
    h.runners.assign(jobID: 2, toRunnerNamed: second.runnerName!, repository: h.repository)
    h.reconciler.reconcile()
    let a = SmokeVerification.Observation(finished)
    let b = SmokeVerification.Observation(try #require(try h.store.allocation(secondID)))
    try SmokeVerification.verify(a, b)
    #expect(throws: CIError.self) { try SmokeVerification.verify(a, a) }
  }

  @Test func runnerExitAndJobConclusionStayDistinctAndDriveRetention() throws {
    let h = try GitHubReconcilerHarness(retention: .live)
    h.reconciler.reconcile()
    let allocation = try #require(try h.open().first)
    h.runners.assign(jobID: 5, toRunnerNamed: allocation.runnerName!, repository: h.repository)
    h.reconciler.reconcile()
    h.provider.state.withLock { $0.runnerStatus[allocation.id] = "exited 0" }
    h.runners.complete(jobID: 5, conclusion: "failure")
    let report = h.reconciler.reconcile()
    let retained = try #require(try h.store.allocation(allocation.id))
    #expect(report.retained == [allocation.id])
    #expect(retained.runnerExitStatus == 0)
    #expect(retained.execution == .succeeded)
    #expect(retained.job?.conclusion == "failure")
    #expect(retained.desired == .retainLive)
    // Retention is finite: it ends with a release.
    h.clock.advance(h.limits.liveRetentionSeconds + 1)
    h.reconciler.reconcile()
    #expect(try h.store.allocation(allocation.id)?.vmCleanup == .verified)
  }

  @Test func aCleanExitWithoutAnObservedJobIsNotASuccess() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    let allocation = try #require(try h.open().first)
    h.provider.state.withLock { $0.runnerStatus[allocation.id] = "exited 0" }
    h.reconciler.reconcile()
    let ended = try #require(try h.store.allocation(allocation.id))
    #expect(ended.job == nil)
    #expect(ended.runnerExitStatus == 0)
    #expect(ended.execution == .unknown)
    #expect(ended.vmCleanup == .verified)
  }

  @Test func aJobThatFinishedBetweenPassesIsStillBound() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    let allocation = try #require(try h.open().first)
    h.runners.assign(jobID: 9, toRunnerNamed: allocation.runnerName!, repository: h.repository)
    h.runners.complete(jobID: 9, conclusion: "success")
    h.provider.state.withLock { $0.runnerStatus[allocation.id] = "exited 0" }
    h.reconciler.reconcile()
    let ended = try #require(try h.store.allocation(allocation.id))
    #expect(ended.job?.jobID == 9)
    #expect(ended.job?.conclusion == "success")
    #expect(ended.execution == .succeeded)
    #expect(ended.vmCleanup == .verified)
  }

  @Test func unconfirmedConclusionWaitsBoundedly() throws {
    let h = try GitHubReconcilerHarness(retention: .live)
    h.reconciler.reconcile()
    let allocation = try #require(try h.open().first)
    h.runners.assign(jobID: 6, toRunnerNamed: allocation.runnerName!, repository: h.repository)
    h.reconciler.reconcile()
    h.provider.state.withLock { $0.runnerStatus[allocation.id] = "exited 1" }
    h.reconciler.reconcile()
    #expect(try h.store.allocation(allocation.id)?.job?.conclusion == nil)
    #expect(h.provider.calls("retain").isEmpty)
    h.clock.advance(ConnectedPoolReconciler.conclusionWaitSeconds + 1)
    h.reconciler.reconcile()
    // Process failure decides retention once the wait is over; the
    // conclusion stays unknown rather than invented.
    #expect(h.provider.calls("retain").count == 1)
    #expect(try h.store.allocation(allocation.id)?.job?.conclusion == nil)
  }

  @Test func anInactivePoolRetiresItsIdleRunnersButNotAssignedWork() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    let busy = try #require(try h.open().first)
    h.runners.assign(jobID: 3, toRunnerNamed: busy.runnerName!, repository: h.repository)
    // The assignment creates fresh idle capacity.
    h.reconciler.reconcile()
    let idle = try #require(try h.open().first { $0.id != busy.id })
    try PoolControl.set("validation", .inactive, reason: "routing exclusivity lost", store: h.store)
    h.reconciler.reconcile()
    let retired = try #require(try h.store.allocation(idle.id))
    #expect(retired.registration == .removed)
    #expect(retired.vmCleanup == .verified)
    let assigned = try #require(try h.store.allocation(busy.id))
    #expect(assigned.vmCleanup != .verified)
    #expect(assigned.job?.jobID == 3)
  }

  @Test func pausedAndZeroIdlePoolsDoNotReplenish() throws {
    let zero = try GitHubReconcilerHarness(desiredIdle: 0)
    #expect(zero.reconciler.reconcile().created.isEmpty)
    let h = try GitHubReconcilerHarness()
    try PoolControl.pause("validation", store: h.store)
    let report = h.reconciler.reconcile()
    #expect(report.created.isEmpty)
    #expect(report.admissionPaused?.contains("paused") == true)
  }

  // A pause that lands while a pass is running stops that pass from
  // creating capacity from the state it read at the start.
  @Test func aPauseDuringAPassStopsItsReplenishment() throws {
    let h = try GitHubReconcilerHarness(desiredIdle: 2, maxLive: 3)
    #expect(h.reconciler.reconcile().created.count == 2)
    let first = try #require(try h.open().first)
    try PoolControl.abort(first.id, store: h.store)
    let store = h.store
    h.provider.onExecute.withLock {
      $0 = { try? PoolControl.pause("validation", store: store) }
    }
    let report = h.reconciler.reconcile()
    #expect(report.created.isEmpty)
    #expect(report.admissionPaused?.contains("paused") == true)
  }

  @Test func githubOutageAndRevocationPauseAdmission() throws {
    let h = try GitHubReconcilerHarness(desiredIdle: 2)
    h.reconciler.reconcile()
    #expect(try h.open().count == 2)
    h.runners.state.withLock { $0.lookupFailure = CIError(.githubUnavailable, "503") }
    let outage = h.reconciler.reconcile()
    #expect(outage.admissionPaused?.contains("GitHub") == true)
    h.runners.state.withLock { $0.lookupFailure = CIError(.unauthorized, "bad credentials") }
    h.reconciler.reconcile()
    #expect(try h.store.poolStatus("validation")?.state == .inactive)
  }

  @Test func removeOffboardsOwnedResourcesOnly() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    h.runners.addForeignRunner(name: "other-controller-runner")
    try PoolControl.remove("validation", store: h.store)
    h.reconciler.reconcile()
    #expect(try h.open().isEmpty)
    #expect(try h.store.poolStatus("validation")?.state == .removed)
    #expect(
      h.runners.state.withLock { $0.runners.values.map(\.name) } == ["other-controller-runner"])
  }

  /// C-T14: a worker that refuses admission does not stop the pool; the
  /// next host serves it in the same pass.
  /// C-T14: a provision interrupted by a controller restart, whose host run
  /// the host then stopped, frees its capacity on the next pass.
  @Test func anInterruptedProvisionWhoseRunStoppedIsReleasedPromptly() throws {
    let h = try GitHubReconcilerHarness()
    h.reconciler.reconcile()
    let ready = try #require(try h.open().first)
    try h.store.update(ready.id) {
      $0.readyAt = nil
      $0.registration = .intended
      $0.observedRunPhase = .stoppedDiskPendingExport
    }
    h.reconciler.reconcile()
    let released = try #require(try h.store.allocation(ready.id))
    #expect(released.desired == .release)
    #expect(released.vmCleanup == .verified)
  }

  @Test func aRefusingWorkerFailsOverToTheNextHost() throws {
    let h = try GitHubReconcilerHarness(hosts: ["qmba", "local"])
    h.provider.state.withLock { $0.refusingHosts = ["qmba"] }
    let report = h.reconciler.reconcile()
    let created = try #require(try h.open().first)
    #expect(created.host == "local")
    #expect(report.admissionPaused == nil)
    #expect(report.errors.contains { $0.contains("admission on qmba") })
    h.provider.state.withLock { $0.refusingHosts = ["qmba", "local"] }
    h.runners.assign(jobID: 4, toRunnerNamed: created.runnerName!, repository: h.repository)
    let refused = h.reconciler.reconcile()
    #expect(refused.admissionPaused?.contains("qmba: admission refused") == true)
    #expect(refused.admissionPaused?.contains("local: admission refused") == true)
  }

  @Test func defaultPlacementDelegatesToHostPlacement() throws {
    let h = try GitHubReconcilerHarness()
    let profile = try ResolvedProfile(name: "linux-validation", configuration: h.configuration)
    let none = try DefaultPlacementPolicy().choose(
      candidates: ["local"], profile: profile, configuration: h.configuration, store: h.store,
      fairnessKey: "validation", now: h.clock.now())
    #expect(none.choice == nil)
    #expect(none.refusals.first?.reason == "not enabled")
  }
}
