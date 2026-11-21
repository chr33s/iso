// A minimal copy of the root package's seeded property checker
// (tests/swift/IsoPropertyTesting), which this separate package cannot
// depend on. Same SplitMix64 stream, base seed and environment knobs, so a
// reported case seed reproduces the same way: `ISO_PROPERTY_CASE` replays one
// case, `ISO_PROPERTY_SEED` changes the base seed, `ISO_PROPERTY_SCALE`
// multiplies every iteration count.

import Foundation

/// SplitMix64: fully determined by its seed.
struct PropertyRNG {
  private(set) var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in `0..<bound`; `bound` must be positive.
  mutating func below(_ bound: Int) -> Int {
    precondition(bound > 0, "PropertyRNG.below needs a positive bound")
    return Int(next() % UInt64(bound))
  }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + below(range.upperBound - range.lowerBound + 1)
  }

  /// True with probability 1/`n`.
  mutating func oneIn(_ n: Int) -> Bool { below(n) == 0 }

  mutating func element<T>(_ values: [T]) -> T { values[below(values.count)] }

  /// Fisher-Yates.
  mutating func shuffled<T>(_ values: [T]) -> [T] {
    var out = values
    for index in stride(from: out.count - 1, to: 0, by: -1) {
      out.swapAt(index, below(index + 1))
    }
    return out
  }

  /// A random subset of `values` in random order, of size `0...values.count`.
  mutating func subset<T>(_ values: [T], minCount: Int = 0) -> [T] {
    Array(shuffled(values).prefix(int(min(minCount, values.count)...values.count)))
  }
}

/// A property that did not hold, with what is needed to reproduce it.
struct PropertyFailure: CustomStringConvertible {
  let property: String
  let caseSeed: UInt64
  let iteration: Int
  let input: String
  let message: String

  var description: String {
    "property '\(property)' failed at iteration \(iteration): \(message)\n"
      + "  input: \(input)\n"
      + "  reproduce: ISO_PROPERTY_CASE=0x\(String(caseSeed, radix: 16)) "
      + "swift test --package-path iso-policy --filter <test>"
  }
}

private func environmentValue(_ name: String) -> UInt64? {
  guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
  return raw.hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
}

/// The base seed when `ISO_PROPERTY_SEED` is unset; the root package's value.
let defaultPropertySeed: UInt64 = 0x150_2026_1115

/// Runs `property` on `iterations` generated inputs, each from its own RNG
/// seeded from the base seed and the iteration, and returns the first
/// failure. `property` returns nil when it holds and a reason otherwise.
func checkProperty<Input>(
  _ name: String,
  iterations: Int = 500,
  generate: (inout PropertyRNG) -> Input,
  property: (Input) -> String?
) -> PropertyFailure? {
  let base = environmentValue("ISO_PROPERTY_SEED") ?? defaultPropertySeed
  let scale = Int(environmentValue("ISO_PROPERTY_SCALE") ?? 1)
  let only = environmentValue("ISO_PROPERTY_CASE")
  let count = only == nil ? iterations * max(scale, 1) : 1
  for iteration in 0..<count {
    var mixer = PropertyRNG(seed: base ^ (UInt64(iteration) &* 0xD1B5_4A32_D192_ED03))
    let caseSeed = only ?? mixer.next()
    var rng = PropertyRNG(seed: caseSeed)
    let input = generate(&rng)
    if let message = property(input) {
      return PropertyFailure(
        property: name, caseSeed: caseSeed, iteration: iteration,
        input: String(reflecting: input), message: message)
    }
  }
  return nil
}
