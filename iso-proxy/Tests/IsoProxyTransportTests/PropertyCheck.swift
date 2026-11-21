// A minimal copy of the root package's seeded property checker
// (tests/swift/IsoPropertyTesting), which this package cannot depend on; see
// docs/testing.md "Property tests". Test support only.

import Foundation
import Testing

/// SplitMix64: fully determined by its seed, so a printed case seed
/// reproduces the exact input on any machine.
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

  mutating func bytes(count: Int) -> [UInt8] {
    (0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }
  }

  /// A size in `0...limit` biased toward the boundaries `0`, `1`,
  /// `pivot - 1`, `pivot` and `pivot + 1`.
  mutating func size(upTo limit: Int, pivot: Int) -> Int {
    switch below(4) {
    case 0: min(limit, max(0, element([0, 1, pivot - 1, pivot, pivot + 1])))
    default: int(0...limit)
    }
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
      + "  reproduce: ISO_PROPERTY_CASE=0x\(String(caseSeed, radix: 16)) swift test --filter <test>"
  }
}

private func environment(_ name: String) -> UInt64? {
  guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
  return raw.hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
}

/// The base seed when `ISO_PROPERTY_SEED` is unset; fixed so CI is repeatable.
let defaultPropertySeed: UInt64 = 0x150_2026_1115

/// Runs `property` on `iterations` generated inputs, each from its own RNG
/// seeded from the base seed and the iteration, so the reported case seed
/// alone reproduces the input. `ISO_PROPERTY_CASE` replays one case seed,
/// `ISO_PROPERTY_SEED` changes the base seed and `ISO_PROPERTY_SCALE`
/// multiplies the iteration count. `property` returns nil when it holds.
func checkProperty<Input>(
  _ name: String,
  iterations: Int = 500,
  generate: (inout PropertyRNG) -> Input,
  property: (Input) -> String?
) -> PropertyFailure? {
  let base = environment("ISO_PROPERTY_SEED") ?? defaultPropertySeed
  let scale = Int(environment("ISO_PROPERTY_SCALE") ?? 1)
  let only = environment("ISO_PROPERTY_CASE")
  let count = only == nil ? iterations * max(scale, 1) : 1
  for iteration in 0..<count {
    var mixer = PropertyRNG(seed: base ^ (UInt64(iteration) &* 0xD1B5_4A32_D192_ED03))
    let caseSeed = only ?? mixer.next()
    var rng = PropertyRNG(seed: caseSeed)
    let input = generate(&rng)
    if let message = property(input) {
      return PropertyFailure(
        property: name, caseSeed: caseSeed, iteration: iteration,
        input: printable(String(reflecting: input)), message: printable(message))
    }
  }
  return nil
}

/// `text` with every non-printable-ASCII scalar as `\u{…}`, so a failing
/// input neither drives the terminal nor hides in the log.
func printable(_ text: String) -> String {
  var out = ""
  for scalar in text.unicodeScalars {
    if (0x20..<0x7F).contains(scalar.value) {
      out.unicodeScalars.append(scalar)
    } else {
      out += "\\u{\(String(scalar.value, radix: 16))}"
    }
  }
  return out
}

/// Records `failure`, if any, as a test issue at the caller.
func expectHolds(_ failure: PropertyFailure?, sourceLocation: SourceLocation = #_sourceLocation) {
  if let failure {
    Issue.record(Comment(rawValue: failure.description), sourceLocation: sourceLocation)
  }
}
