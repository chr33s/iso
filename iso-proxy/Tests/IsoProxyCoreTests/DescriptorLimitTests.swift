import Darwin
import Testing

@testable import IsoProxyCore

/// Darwin's `RLIM_INFINITY`, a macro Swift does not import.
private let unlimited = UInt64(Int64.max)

@Test func descriptorLimitCoversEveryDocumentedSocket() {
  // Each guest connection and each upstream socket holds a descriptor at once.
  #expect(Limits.descriptors >= Limits.connections + Limits.upstreamSockets + 16)
}

@Test func descriptorLimitRaisesOnlyAsFarAsNeeded() throws {
  let required = UInt64(Limits.descriptors)
  // The launchd default soft limit is raised to exactly what the limits need.
  #expect(try DescriptorLimit.plan(soft: 256, hard: unlimited, required: required) == required)
  #expect(try DescriptorLimit.plan(soft: 256, hard: required, required: required) == required)
  #expect(
    try DescriptorLimit.plan(soft: required - 1, hard: 10_240, required: required) == required)
  // A sufficient soft limit is left alone, never lowered.
  #expect(try DescriptorLimit.plan(soft: required, hard: required, required: required) == nil)
  #expect(try DescriptorLimit.plan(soft: 1_048_576, hard: unlimited, required: required) == nil)
}

@Test func descriptorLimitRefusesAHardLimitBelowTheNeed() {
  let required = UInt64(Limits.descriptors)
  for hard in [UInt64(256), required - 1] {
    #expect(throws: DescriptorLimit.Failure.hardLimitTooLow(hard: hard, required: required)) {
      try DescriptorLimit.plan(soft: min(hard, 256), hard: hard, required: required)
    }
  }
  #expect(
    DescriptorLimit.Failure.hardLimitTooLow(hard: 300, required: 576).description
      == "open-file hard limit 300 is below the 576 descriptors the proxy limits need")
}

@Test func descriptorLimitRaiseKeepsASufficientProcessLimit() throws {
  var before = rlimit()
  try #require(getrlimit(RLIMIT_NOFILE, &before) == 0)
  // Raising never lowers the limit, so this is safe in a shared test process.
  _ = try DescriptorLimit.raise(to: Limits.descriptors)
  var after = rlimit()
  try #require(getrlimit(RLIMIT_NOFILE, &after) == 0)
  #expect(after.rlim_cur >= max(before.rlim_cur, UInt64(Limits.descriptors)))
  #expect(after.rlim_max == before.rlim_max)
}
