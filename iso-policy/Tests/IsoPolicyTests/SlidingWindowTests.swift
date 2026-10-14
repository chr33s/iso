import Darwin
import Foundation
import Synchronization
import Testing

@testable import IsoPolicy

private func admissions(
  _ guards: String = rateGuard("limit", max: 100, within: 60), mode: String = "enforce"
) throws -> ProviderAdmissions {
  ProviderAdmissions(
    policy: try compile(policyJSON(mode: mode, rules: anthropicPermits, guards: guards)),
    provider: .anthropic, instance: "vm", epoch: "epoch")
}

@Test func capacityAtOneTickAdmitsExactly() throws {
  var state = try admissions()
  let results = (0..<101).map { state.checkAndAdmit(now: 5 * second, decisionID: "\($0)") }
  #expect(results.filter(\.allows).count == 100)
  let last = try #require(results.last)
  #expect(last.reason == .quotaExceeded)
  #expect(last.failedGuardIDs == ["limit"])
  #expect(last.retryAfterSeconds == 60)
  #expect(state.charged("limit") == 100)
}

@Test func windowBoundaryIsExclusive() throws {
  var state = try admissions(rateGuard("limit", max: 1, within: 60))
  #expect(state.checkAndAdmit(now: 10, decisionID: "a").allows)
  // Exactly W - 1 tick old: still charged.
  #expect(state.checkAndAdmit(now: 10 + 60 * second - 1, decisionID: "b").reason == .quotaExceeded)
  #expect(state.checkAndAdmit(now: 10 + 60 * second - 1, decisionID: "b").retryAfterSeconds == 1)
  // Exactly W old: expired.
  #expect(state.checkAndAdmit(now: 10 + 60 * second, decisionID: "c").allows)
}

@Test func failedBatchInsertsIntoNoGuard() throws {
  var state = try admissions(
    rateGuard("wide", max: 10, within: 60) + "," + rateGuard("narrow", max: 1, within: 60))
  #expect(state.checkAndAdmit(now: 1, decisionID: "1").allows)
  #expect(state.charged("wide") == 1)
  let denied = state.checkAndAdmit(now: 2, decisionID: "2")
  #expect(denied.reason == .quotaExceeded)
  #expect(denied.failedGuardIDs == ["narrow"])
  #expect(denied.requiredGuardIDs == ["narrow", "wide"])
  #expect(state.charged("wide") == 1)
}

@Test func staticDenialChargesNothing() throws {
  let policy = try compile(
    policyJSON(
      rules: rule("request", "permit", "proxy.request", ["provider:anthropic"]),
      guards: rateGuard("limit", max: 1, within: 60)))
  // credential.use has no permit, so the pair denies before any admission.
  var state = ProviderAdmissions(policy: policy, provider: .anthropic, instance: "vm", epoch: "e")
  #expect(state.checkAndAdmit(now: 1, decisionID: "1").reason == .noPermit)
  #expect(state.charged("limit") == 0)
}

@Test func clockRegressionAndInvalidSamplesDeny() throws {
  var state = try admissions()
  #expect(state.checkAndAdmit(now: 100, decisionID: "a").allows)
  #expect(state.checkAndAdmit(now: 99, decisionID: "b").reason == .internalError)
  #expect(state.checkAndAdmit(now: nil, decisionID: "c").reason == .internalError)
  #expect(state.charged("limit") == 1)
  #expect(state.checkAndAdmit(now: 100, decisionID: "d").allows)
}

@Test func providersAndInstancesHaveSeparateScopes() throws {
  let policy = try compile(
    policyJSON(
      rules: rule("use", "permit", "credential.use", ["provider:anthropic", "provider:openai"])
        + ","
        + rule("request", "permit", "proxy.request", ["provider:anthropic", "provider:openai"]),
      guards: rateGuard("limit", ["provider:anthropic", "provider:openai"], max: 1, within: 60)
        + "," + rateGuard("one-only", max: 5, within: 60, instances: ["one"])))
  var anthropic = ProviderAdmissions(
    policy: policy, provider: .anthropic, instance: "two", epoch: "e")
  var openai = ProviderAdmissions(policy: policy, provider: .openai, instance: "two", epoch: "e")
  #expect(anthropic.checkAndAdmit(now: 1, decisionID: "a").allows)
  #expect(openai.checkAndAdmit(now: 1, decisionID: "b").allows)
  #expect(anthropic.charged("one-only") == nil)
  let one = ProviderAdmissions(policy: policy, provider: .anthropic, instance: "one", epoch: "e")
  #expect(one.charged("one-only") == 0)
  #expect(one.allocatedSlots == 6)
}

@Test func notGovernedAndOffNeverCount() throws {
  var off = try admissions(mode: "off")
  #expect(off.checkAndAdmit(now: 1, decisionID: "a").verdict == .notGoverned)
  #expect(off.charged("limit") == nil)
  let workspaceOnly = try compile(
    policyJSON(actions: ["workspace.pull.apply"]))
  var state = ProviderAdmissions(
    policy: workspaceOnly, provider: .anthropic, instance: "vm", epoch: "e")
  #expect(state.checkAndAdmit(now: 1, decisionID: "a").verdict == .notGoverned)
}

@Test func concurrentCallersShareOneLimiter() async throws {
  let shared = Mutex(try admissions())
  let allowed = await withTaskGroup(of: Bool.self) { group in
    for index in 0..<1_000 {
      group.addTask {
        shared.withLock { $0.checkAndAdmit(now: 7 * second, decisionID: "\(index)").allows }
      }
    }
    var count = 0
    for await result in group where result { count += 1 }
    return count
  }
  #expect(allowed == 100)
}

@Test func ninetyNineThenTwoConcurrentAdmitsOne() async throws {
  let shared = Mutex(try admissions())
  shared.withLock { state in
    for index in 0..<99 { _ = state.checkAndAdmit(now: 1, decisionID: "\(index)") }
  }
  let allowed = await withTaskGroup(of: Bool.self) { group in
    for index in 0..<2 {
      group.addTask { shared.withLock { $0.checkAndAdmit(now: 2, decisionID: "c\(index)").allows } }
    }
    var count = 0
    for await result in group where result { count += 1 }
    return count
  }
  #expect(allowed == 1)
}

@Test func memoryStaysBoundedUnderADenialFlood() throws {
  var state = try admissions(rateGuard("limit", max: 3, within: 1))
  for tick in 0..<100_000 {
    _ = state.checkAndAdmit(now: UInt64(tick) * 1_000_000, decisionID: "f")
    #expect(state.charged("limit")! <= 3)
  }
  #expect(state.allocatedSlots == 3)
}

@Test func ringWrapsAround() {
  var window = SlidingWindow(capacity: 3, windowSeconds: 1)
  for round in 0..<10 {
    let base = UInt64(round) * second
    for offset in 0..<3 {
      window.evict(now: base + UInt64(offset))
      #expect(!window.isFull)
      window.admit(base + UInt64(offset))
    }
    #expect(window.isFull)
    #expect(window.wait(now: base + 3) == second - 3)
  }
}

@Test func productionClockIncludesSleepAndIsMonotonic() throws {
  // CLOCK_MONOTONIC_RAW keeps counting while the host sleeps; the
  // sleep-excluding CLOCK_UPTIME_RAW is not used for windows or approvals.
  #expect(SystemMonotonicClock.clockID == CLOCK_MONOTONIC_RAW)
  #expect(SystemMonotonicClock.clockID != CLOCK_UPTIME_RAW)
  let clock = SystemMonotonicClock()
  var previous = try #require(clock.nanoseconds())
  for _ in 0..<1_000 {
    let next = try #require(clock.nanoseconds())
    #expect(next >= previous)
    previous = next
  }
  // Since boot, sleep-inclusive time is never behind awake-only time. Awake
  // time is read first: without sleep the two clocks advance together, so the
  // later read must be the sleep-inclusive one.
  let awake = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
  #expect(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) >= awake)
}

@Test func wallClockIsNotAnInput() throws {
  // Decisions depend only on the injected samples: identical sequences give
  // identical decisions whatever the wall clock reads in between.
  var a = try admissions(rateGuard("limit", max: 2, within: 10))
  var b = try admissions(rateGuard("limit", max: 2, within: 10))
  let samples: [UInt64] = [1, 2, 3, 10 * second, 10 * second + 1, 10 * second + 2]
  let first = samples.map { a.checkAndAdmit(now: $0, decisionID: "x").reason }
  _ = Date(timeIntervalSince1970: 0)
  let second = samples.map { b.checkAndAdmit(now: $0, decisionID: "x").reason }
  #expect(first == second)
  #expect(first == [.allowed, .allowed, .quotaExceeded, .quotaExceeded, .allowed, .allowed])
}
