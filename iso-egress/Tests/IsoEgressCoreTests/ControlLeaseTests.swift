import Darwin
import Testing

@testable import IsoEgressCore

private func renewalPipe() throws -> [Int32] {
  var descriptors: [Int32] = [-1, -1]
  try #require(pipe(&descriptors) == 0)
  return descriptors
}

private func renew(_ descriptor: Int32, byte: UInt8 = 1) throws {
  var value = byte
  try #require(write(descriptor, &value, 1) == 1)
}

@Test func controlLeaseReadsAPipeAndExtendsItsDeadline() throws {
  let descriptors = try renewalPipe()
  defer {
    close(descriptors[0])
    close(descriptors[1])
  }
  let lease = ControlLease(descriptor: descriptors[0], startedAt: 0)
  let second: UInt64 = 1_000_000_000
  try renew(descriptors[1])
  #expect(lease.alive(at: second))
  // Beyond the initial grace period, but within the renewed lease.
  #expect(lease.alive(at: second * 3 - 1))
  try renew(descriptors[1])
  #expect(lease.alive(at: second * 3))
  #expect(lease.alive(at: second * 5 - 1))
  #expect(!lease.alive(at: second * 5 + 1))
  try renew(descriptors[1])
  #expect(!lease.alive(at: second * 5 + 2))
}

@Test func controlLeaseCannotReviveFromAQueuedLateRenewal() throws {
  let descriptors = try renewalPipe()
  defer {
    close(descriptors[0])
    close(descriptors[1])
  }
  let lease = ControlLease(descriptor: descriptors[0], startedAt: 0)
  try renew(descriptors[1])
  #expect(!lease.alive(at: Monotonic.nanoseconds(EgressBudgets.lease) + 1))
  #expect(!lease.alive(at: 1))
}

@Test func controlLeaseClosesOnEOFDespiteBufferedRenewals() throws {
  let descriptors = try renewalPipe()
  defer { close(descriptors[0]) }
  let lease = ControlLease(descriptor: descriptors[0], startedAt: 0)
  try renew(descriptors[1])
  close(descriptors[1])
  #expect(!lease.alive(at: 1))
  #expect(!lease.alive(at: 2))
}

@Test func controlLeaseRejectsInvalidRenewalsAndDescriptors() throws {
  let descriptors = try renewalPipe()
  defer {
    close(descriptors[0])
    close(descriptors[1])
  }
  let lease = ControlLease(descriptor: descriptors[0], startedAt: 0)
  try renew(descriptors[1], byte: 0)
  #expect(!lease.alive(at: 1))
  try renew(descriptors[1])
  #expect(!lease.alive(at: 2))
  #expect(!ControlLease(descriptor: .max, startedAt: 0).alive(at: 1))
  #expect(!ControlLease(descriptor: -1, startedAt: 0).alive(at: 1))
  #expect(!ControlLease(descriptor: descriptors[0], startedAt: 2).alive(at: 1))
}
