// Seeded, dependency-free property checking for the host test targets; see
// docs/testing.md "Property tests". Not part of any product.

import Darwin

/// SplitMix64: small, fast, and fully determined by its seed, so a printed
/// case seed reproduces the exact input on any machine.
public struct PropertyRNG: Sendable {
  public private(set) var state: UInt64

  public init(seed: UInt64) { state = seed }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in `0..<bound`; `bound` must be positive.
  public mutating func below(_ bound: Int) -> Int {
    precondition(bound > 0, "PropertyRNG.below needs a positive bound")
    return Int(next() % UInt64(bound))
  }

  public mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + below(range.upperBound - range.lowerBound + 1)
  }

  /// True with probability 1/`n`.
  public mutating func oneIn(_ n: Int) -> Bool { below(n) == 0 }

  public mutating func element<T>(_ values: [T]) -> T { values[below(values.count)] }

  public mutating func bytes(maxCount: Int) -> [UInt8] {
    (0..<int(0...maxCount)).map { _ in UInt8(truncatingIfNeeded: next()) }
  }

  /// One scalar from a class chosen uniformly among `classes`.
  public mutating func scalar(_ classes: [ScalarClass]) -> Unicode.Scalar {
    element(classes).draw(&self)
  }

  public mutating func string(maxScalars: Int, _ classes: [ScalarClass] = ScalarClass.all) -> String
  {
    var out = String.UnicodeScalarView()
    for _ in 0..<int(0...maxScalars) { out.append(scalar(classes)) }
    return String(out)
  }

  /// Slash-joined components drawn from `components`.
  public mutating func path(maxComponents: Int, _ components: [String]) -> String {
    (0..<int(0...maxComponents)).map { _ in element(components) }.joined(separator: "/")
  }

  public mutating func json(depth: Int, strings: [ScalarClass] = ScalarClass.all) -> GeneratedJSON {
    let leaf = depth <= 0 || oneIn(3)
    switch leaf ? below(6) : 6 + below(2) {
    case 0: return .null
    case 1: return .bool(oneIn(2))
    case 2: return .int(Int64(bitPattern: next()) >> UInt64(below(64)))
    case 3: return .uint(UInt64(Int64.max) &+ 1 &+ (next() >> 1))
    case 4: return .double(Double(Int32(truncatingIfNeeded: next())) / 8)
    case 5: return .string(string(maxScalars: 12, strings))
    case 6: return .array((0..<below(4)).map { _ in json(depth: depth - 1, strings: strings) })
    default:
      var members: [(String, GeneratedJSON)] = []
      var keys: Set<String> = []
      for _ in 0..<below(4) {
        let key = string(maxScalars: 6, strings)
        guard keys.insert(key).inserted else { continue }
        members.append((key, json(depth: depth - 1, strings: strings)))
      }
      return .object(members)
    }
  }
}

/// Scalar populations weighted toward the bytes that break quoting,
/// display neutralization and path handling.
public enum ScalarClass: Sendable, CaseIterable {
  case asciiWord, shellMeta, whitespace, c0Control, c1Control, format, bidi, combining
  case pathSyntax, nonASCII, astral

  public static let all = allCases

  public func draw(_ rng: inout PropertyRNG) -> Unicode.Scalar {
    let pick: UInt32
    switch self {
    case .asciiWord:
      pick = rng.element(Array("abcXYZ019-_.".unicodeScalars)).value
    case .shellMeta:
      pick = rng.element(Array("'\"\\$`;|&<>()*?[]{}~#!=%^,".unicodeScalars)).value
    case .whitespace:
      pick = rng.element([0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0xA0, 0x2028, 0x3000])
    case .c0Control: pick = UInt32(rng.below(0x20))
    case .c1Control: pick = 0x7F + UInt32(rng.below(0x21))
    case .format: pick = rng.element([0x00AD, 0x061C, 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF])
    case .bidi:
      pick = rng.element([
        0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2069,
      ])
    case .combining: pick = 0x0300 + UInt32(rng.below(0x70))
    case .pathSyntax: pick = rng.element(Array("/./..".unicodeScalars)).value
    case .nonASCII: pick = rng.element([0xE9, 0x0661, 0x0430, 0x4E2D, 0xFF0F, 0x2215, 0xFF0E])
    case .astral: pick = 0x1_0000 + UInt32(rng.below(0x10_0000))
    }
    return Unicode.Scalar(pick) ?? "?"
  }
}

/// A JSON value tree for generators; test targets map it onto their own model.
public indirect enum GeneratedJSON: Sendable {
  case null
  case bool(Bool)
  case int(Int64)
  case uint(UInt64)
  case double(Double)
  case string(String)
  case array([GeneratedJSON])
  case object([(String, GeneratedJSON)])
}

/// A property that did not hold, with what is needed to reproduce it.
public struct PropertyFailure: Sendable, CustomStringConvertible {
  public let property: String
  public let caseSeed: UInt64
  public let iteration: Int
  public let input: String
  public let message: String

  public var description: String {
    "property '\(property)' failed at iteration \(iteration): \(message)\n"
      + "  input: \(input)\n"
      + "  reproduce: ISO_PROPERTY_CASE=0x\(String(caseSeed, radix: 16)) swift test --filter <test>"
  }
}

/// Reproduction and campaign knobs, read once from the environment:
/// `ISO_PROPERTY_CASE` replays one case seed; `ISO_PROPERTY_SEED` changes the
/// base seed; `ISO_PROPERTY_SCALE` multiplies every iteration count.
public enum PropertyEnvironment {
  static func value(_ name: String) -> UInt64? {
    guard let raw = getenvString(name) else { return nil }
    return raw.hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
  }

  private static func getenvString(_ name: String) -> String? {
    guard let pointer = unsafe getenv(name) else { return nil }
    return unsafe String(cString: pointer)
  }
}

/// The base seed when `ISO_PROPERTY_SEED` is unset; fixed so CI is repeatable.
public let defaultPropertySeed: UInt64 = 0x150_2026_1115

/// Runs `property` on `iterations` generated inputs. Each case draws from its
/// own RNG seeded from the base seed and the iteration, so the reported case
/// seed alone reproduces the input. `property` returns nil when it holds and
/// a reason otherwise; the first failure is returned.
public func checkProperty<Input>(
  _ name: String,
  iterations: Int = 500,
  generate: (inout PropertyRNG) -> Input,
  property: (Input) -> String?
) -> PropertyFailure? {
  let base = PropertyEnvironment.value("ISO_PROPERTY_SEED") ?? defaultPropertySeed
  let scale = Int(PropertyEnvironment.value("ISO_PROPERTY_SCALE") ?? 1)
  let only = PropertyEnvironment.value("ISO_PROPERTY_CASE")
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
public func printable(_ text: String) -> String {
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
