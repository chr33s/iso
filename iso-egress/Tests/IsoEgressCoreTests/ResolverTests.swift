import Darwin
import Dispatch
import Foundation
import Testing

@testable import IsoEgressCore

private func numericResult(
  status: Int32 = 0, freed: @escaping @Sendable () -> Void = {}
) -> ResolvedAddresses? {
  var hints = addrinfo()
  hints.ai_family = AF_INET
  hints.ai_socktype = SOCK_STREAM
  hints.ai_flags = AI_NUMERICHOST
  var info: UnsafeMutablePointer<addrinfo>?
  guard getaddrinfo("127.0.0.1", "443", &hints, &info) == 0 else {
    if let info { freeaddrinfo(info) }
    Issue.record("numeric address fixture failed")
    return nil
  }
  return ResolvedAddresses.adopting(info, status: status) {
    freeaddrinfo($0)
    freed()
  }
}

private final class StalledResolver: @unchecked Sendable {
  let started = DispatchSemaphore(value: 0)
  let gate = DispatchSemaphore(value: 0)
  let freed = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var active = 0
  private var peak = 0
  private var calls = 0
  private var releases = 0

  var counts: (active: Int, peak: Int, calls: Int, releases: Int) {
    lock.withLock { (active, peak, calls, releases) }
  }

  func resolve() -> ResolvedAddresses? {
    lock.withLock {
      active += 1
      calls += 1
      peak = max(peak, active)
    }
    defer { lock.withLock { active -= 1 } }
    started.signal()
    guard gate.wait(timeout: .now() + .seconds(5)) == .success else {
      Issue.record("stalled resolver fixture was not released")
      return nil
    }
    return numericResult { [self] in
      lock.withLock { releases += 1 }
      freed.signal()
    }
  }

  func release(_ count: Int) {
    for _ in 0..<count { gate.signal() }
  }
}

@Test func resolverTimeoutKeepsActualWorkAdmittedAndFreesLateResults() throws {
  let admission = Admission()
  let fixture = StalledResolver()
  defer { fixture.release(EgressBudgets.maxDNS + 2) }
  for _ in 0..<EgressBudgets.maxDNS {
    #expect(
      Resolver.lookup(
        admission: admission, deadline: .milliseconds(20), resolve: fixture.resolve) == nil)
    try #require(fixture.started.wait(timeout: .now() + .seconds(1)) == .success)
  }
  #expect(fixture.counts.active == EgressBudgets.maxDNS)
  let spare = admission.tryDNS()
  #expect(!spare)
  if spare { admission.endDNS() }
  #expect(
    Resolver.lookup(
      admission: admission, deadline: .milliseconds(20), resolve: fixture.resolve) == nil)
  #expect(fixture.started.wait(timeout: .now() + .milliseconds(50)) == .timedOut)
  #expect(fixture.counts.calls == EgressBudgets.maxDNS)

  fixture.release(1)
  try #require(fixture.freed.wait(timeout: .now() + .seconds(1)) == .success)
  #expect(fixture.counts.active == EgressBudgets.maxDNS - 1)
  #expect(
    Resolver.lookup(
      admission: admission, deadline: .milliseconds(20), resolve: fixture.resolve) == nil)
  try #require(fixture.started.wait(timeout: .now() + .seconds(1)) == .success)
  #expect(fixture.counts.active == EgressBudgets.maxDNS)
  #expect(fixture.counts.calls == EgressBudgets.maxDNS + 1)

  fixture.release(EgressBudgets.maxDNS)
  let deadline = DispatchTime.now() + .seconds(2)
  for _ in 0..<EgressBudgets.maxDNS {
    #expect(fixture.freed.wait(timeout: deadline) == .success)
  }
  #expect(fixture.counts.active == 0)
  #expect(fixture.counts.peak == EgressBudgets.maxDNS)
  #expect(fixture.counts.releases == EgressBudgets.maxDNS + 1)
  for _ in 0..<EgressBudgets.maxDNS { #expect(admission.tryDNS()) }
  #expect(!admission.tryDNS())
  for _ in 0..<EgressBudgets.maxDNS { admission.endDNS() }
}

@Test func resolverSuccessOwnsItsListAndReleasesTheWorkSlot() throws {
  let admission = Admission()
  let freed = DispatchSemaphore(value: 0)
  var answer = Resolver.lookup(admission: admission, deadline: .seconds(1)) {
    numericResult { freed.signal() }
  }
  try #require(answer != nil)
  withExtendedLifetime(answer) {
    answer?.withAddressInfo { info in
      #expect(info.pointee.ai_family == AF_INET)
      #expect(info.pointee.ai_addrlen == MemoryLayout<sockaddr_in>.size)
    }
    #expect(freed.wait(timeout: .now()) == .timedOut)
    for _ in 0..<EgressBudgets.maxDNS { #expect(admission.tryDNS()) }
    #expect(!admission.tryDNS())
    for _ in 0..<EgressBudgets.maxDNS { admission.endDNS() }
  }
  answer = nil
  #expect(freed.wait(timeout: .now() + .seconds(1)) == .success)
  #expect(freed.wait(timeout: .now()) == .timedOut)
}

@Test func deadlineRejectsAResultFinishedAfterItsMonotonicDeadline() {
  let box = Box<Int>(deadline: .now() - .milliseconds(1))
  box.finish(7)
  #expect(box.value() == nil)
}

@Test func productionResolverBorrowsANumericListWithoutDialing() throws {
  let result = try #require(Resolver.lookup("127.0.0.1", admission: Admission()))
  result.withAddressInfo { info in
    #expect(info.pointee.ai_family == AF_INET)
    #expect(info.pointee.ai_socktype == SOCK_STREAM)
    if let address = info.pointee.ai_addr {
      address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        #expect($0.pointee.sin_addr.s_addr == inet_addr("127.0.0.1"))
        #expect($0.pointee.sin_port == UInt16(443).bigEndian)
      }
    } else {
      Issue.record("numeric lookup returned no socket address")
    }
  }
}

@Test func resolverFailureReleasesItsSlotAndAnyReturnedList() {
  let admission = Admission()
  let freed = DispatchSemaphore(value: 0)
  #expect(
    Resolver.lookup(admission: admission, deadline: .seconds(1)) {
      numericResult(status: EAI_FAIL) { freed.signal() }
    } == nil)
  #expect(freed.wait(timeout: .now() + .seconds(1)) == .success)
  #expect(freed.wait(timeout: .now()) == .timedOut)
  #expect(ResolvedAddresses.adopting(nil, status: 0) == nil)
  for _ in 0..<EgressBudgets.maxDNS { #expect(admission.tryDNS()) }
  #expect(!admission.tryDNS())
  for _ in 0..<EgressBudgets.maxDNS { admission.endDNS() }
}
