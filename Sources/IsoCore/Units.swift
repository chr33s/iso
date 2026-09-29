/// Rust `str::parse::<uN>()`: an optional `+` then ASCII digits, no overflow.
public func parseUnsigned<T: FixedWidthInteger & UnsignedInteger>(
  _ text: String, as _: T.Type = T.self
) -> T? {
  var digits = Substring(text).utf8[...]
  if digits.first == UInt8(ascii: "+") { digits = digits.dropFirst() }
  guard !digits.isEmpty else { return nil }
  var value: T = 0
  for byte in digits {
    guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else { return nil }
    let (shifted, overflowA) = value.multipliedReportingOverflow(by: 10)
    let (sum, overflowB) = shifted.addingReportingOverflow(T(byte - UInt8(ascii: "0")))
    guard !overflowA, !overflowB else { return nil }
    value = sum
  }
  return value
}

/// Non-zero memory quantity in mebibytes.
public struct MiB: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let value: UInt32
  public init?(_ value: UInt32) {
    guard value > 0 else { return nil }
    self.value = value
  }
  public static func parseCLI(_ text: String) throws(ValidationError) -> MiB {
    guard let n = parseUnsigned(text, as: UInt32.self) else {
      throw ValidationError("expected positive integer MiB, got '\(text)'")
    }
    guard let mib = MiB(n) else { throw ValidationError("MiB must be > 0, got '\(text)'") }
    return mib
  }
  public var gibibytes: Double { Double(value) / 1024 }
  public var description: String { String(value) }
  public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

/// Non-zero disk quantity in gibibytes.
public struct GiB: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let value: UInt32
  public init?(_ value: UInt32) {
    guard value > 0 else { return nil }
    self.value = value
  }
  public static func parseCLI(_ text: String) throws(ValidationError) -> GiB {
    guard let n = parseUnsigned(text, as: UInt32.self) else {
      throw ValidationError("expected positive integer GiB, got '\(text)'")
    }
    guard let gib = GiB(n) else { throw ValidationError("GiB must be > 0, got '\(text)'") }
    return gib
  }
  public var description: String { String(value) }
  public static func < (a: Self, b: Self) -> Bool { a.value < b.value }
}

/// Non-zero byte budget: plain bytes, or an integer with a `KiB`, `MiB` or
/// `GiB` suffix (`"256MiB"`).
public struct ByteCount: Hashable, Comparable, Sendable, CustomStringConvertible {
  public let bytes: UInt64

  public init?(bytes: UInt64) {
    guard bytes > 0 else { return nil }
    self.bytes = bytes
  }

  static let suffixes: [(String, UInt64)] = [("KiB", 1 << 10), ("MiB", 1 << 20), ("GiB", 1 << 30)]

  public init(parsing text: String) throws(ValidationError) {
    var digits = text
    var scale: UInt64 = 1
    if let (suffix, factor) = Self.suffixes.first(where: { text.hasSuffix($0.0) }) {
      digits = String(text.dropLast(suffix.count))
      scale = factor
    }
    guard let n = parseUnsigned(digits, as: UInt64.self) else {
      throw ValidationError(
        "expected a byte count such as 1048576, \"512KiB\", \"256MiB\" or \"1GiB\", got '\(text)'")
    }
    let (value, overflow) = n.multipliedReportingOverflow(by: scale)
    guard !overflow else { throw ValidationError("byte count '\(text)' is too large") }
    guard let count = ByteCount(bytes: value) else {
      throw ValidationError("byte count must be > 0, got '\(text)'")
    }
    self = count
  }

  /// The largest exact binary unit: `1GiB`, `1536KiB`, `100`.
  public var description: String {
    for (suffix, factor) in Self.suffixes.reversed() where bytes % factor == 0 {
      return "\(bytes / factor)\(suffix)"
    }
    return String(bytes)
  }

  public static func < (a: Self, b: Self) -> Bool { a.bytes < b.bytes }
}

/// A session length: plain seconds or an `s`/`m`/`h` suffix, from one
/// minute to 30 days.
/// A duration written as plain seconds or with an `s`/`m`/`h` suffix. Range
/// checks stay with the caller.
public enum DurationText: Equatable, Sendable {
  case seconds(UInt64)
  case invalid
  case overflow

  public init(parsing text: String) {
    var digits = Substring(text)
    var scale: UInt64 = 1
    switch digits.last {
    case "s": digits = digits.dropLast()
    case "m":
      digits = digits.dropLast()
      scale = 60
    case "h":
      digits = digits.dropLast()
      scale = 3600
    default: break
    }
    guard let number = parseUnsigned(String(digits), as: UInt64.self) else {
      self = .invalid
      return
    }
    let (seconds, overflow) = number.multipliedReportingOverflow(by: scale)
    self = overflow ? .overflow : .seconds(seconds)
  }
}

public struct SessionTTL: Hashable, Sendable, CustomStringConvertible {
  public static let range: ClosedRange<UInt32> = 60...(30 * 24 * 3600)
  public let seconds: UInt32

  public init(seconds: UInt32) throws(ValidationError) {
    guard Self.range.contains(seconds) else {
      throw ValidationError("session_ttl must be between 1m and 720h")
    }
    self.seconds = seconds
  }

  public init(parsing text: String) throws(ValidationError) {
    switch DurationText(parsing: text) {
    case .invalid:
      throw ValidationError("expected a duration such as 3600, \"30m\" or \"8h\", got '\(text)'")
    case .overflow:
      throw ValidationError("session_ttl must be between 1m and 720h")
    case .seconds(let value):
      guard let seconds = UInt32(exactly: value) else {
        throw ValidationError("session_ttl must be between 1m and 720h")
      }
      try self.init(seconds: seconds)
    }
  }

  public var description: String {
    seconds % 3600 == 0
      ? "\(seconds / 3600)h" : seconds % 60 == 0 ? "\(seconds / 60)m" : "\(seconds)s"
  }
}

/// Guest RAM at or above the bootable floor, enforced on every entry point.
public struct VmMemory: Hashable, Comparable, Sendable, CustomStringConvertible {
  public static let minimum = MiB(128)!
  public let mib: MiB

  public init(_ mib: MiB) throws(ValidationError) {
    guard mib >= Self.minimum else {
      throw ValidationError("mem_size_mib=\(mib) is too low (minimum \(Self.minimum))")
    }
    self.mib = mib
  }
  public static func parseCLI(_ text: String) throws(ValidationError) -> VmMemory {
    try VmMemory(MiB.parseCLI(text))
  }
  public var description: String { mib.description }
  public static func < (a: Self, b: Self) -> Bool { a.mib < b.mib }
}

/// Disk size specification: absolute (`150`, `150G`) or relative (`+20`).
public enum DiskSize: Hashable, Sendable {
  case absolute(GiB)
  case relative(GiB)

  public static func parse(_ text: String) throws(ValidationError) -> DiskSize {
    var rest = Substring(text)
    let relative = rest.unicodeScalars.first == "+"
    if relative { rest = Substring(rest.unicodeScalars.dropFirst()) }
    if let last = rest.unicodeScalars.last, last == "G" || last == "g" {
      rest = Substring(rest.unicodeScalars.dropLast())
    }
    guard let value = parseUnsigned(String(rest), as: UInt32.self) else {
      throw ValidationError("Invalid disk size: \(text)")
    }
    guard let gib = GiB(value) else { throw ValidationError("Disk size must be > 0: \(text)") }
    return relative ? .relative(gib) : .absolute(gib)
  }

  public func resolve(current: GiB) throws(ValidationError) -> GiB {
    switch self {
    case .absolute(let gib): return gib
    case .relative(let delta):
      let (sum, overflow) = current.value.addingReportingOverflow(delta.value)
      guard !overflow else { throw ValidationError("Disk size overflow") }
      return GiB(sum)!
    }
  }
}

/// A deadline in whole seconds, `1...86_400`.
public struct TimeoutSecs: Hashable, Sendable, CustomStringConvertible {
  public static let maximum: UInt32 = 86_400
  public let seconds: UInt32

  public init(_ seconds: UInt32) throws(ValidationError) {
    guard seconds > 0, seconds <= Self.maximum else {
      throw ValidationError(
        "timeout must be between 1 and \(Self.maximum) seconds, got \(seconds)")
    }
    self.seconds = seconds
  }
  public var duration: Duration { .seconds(Int64(seconds)) }
  public var description: String { String(seconds) }
}

/// Instance index `0...252`; persisted in `instance.json`.
public struct InstanceIndex: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
  public static let maximum: UInt16 = 252
  public let value: UInt16

  public init?(_ value: UInt16) {
    guard value <= Self.maximum else { return nil }
    self.value = value
  }
  public var description: String { String(value) }
  public static func < (a: Self, b: Self) -> Bool { a.value < b.value }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(UInt16.self)
    guard let index = InstanceIndex(raw) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "instance index \(raw) out of range 0..=\(Self.maximum)"))
    }
    self = index
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

/// A guest port forwarded to the host for the VM's lifetime.
public struct PortForward: Hashable, Sendable {
  public let guest: UInt16
  public let host: UInt16
  public let label: String?

  public init(guest: UInt16, host: UInt16? = nil, label: String? = nil) throws(ValidationError) {
    guard guest > 0 else { throw ValidationError("port must be > 0") }
    guard host != 0 else { throw ValidationError("port must be > 0") }
    self.guest = guest
    self.host = host ?? guest
    self.label = label
  }

  /// CLI spec `GUEST[:HOST]`.
  public static func parse(_ spec: String) throws(ValidationError) -> PortForward {
    let scalars = spec.unicodeScalars
    let colon = scalars.firstIndex(of: ":")
    let guestText = String(scalars[..<(colon ?? scalars.endIndex)]).trimmingUnicodeWhitespace()
    guard let guest = parseUnsigned(guestText, as: UInt16.self) else {
      throw ValidationError(
        "Invalid forward-port spec '\(spec)': guest port must be a number 1..=65535")
    }
    guard guest > 0 else {
      throw ValidationError("Invalid forward-port spec '\(spec)': guest port must be > 0")
    }
    var host = guest
    if let colon {
      let hostText = String(scalars[scalars.index(after: colon)...]).trimmingUnicodeWhitespace()
      guard let parsed = parseUnsigned(hostText, as: UInt16.self) else {
        throw ValidationError(
          "Invalid forward-port spec '\(spec)': host port must be a number 1..=65535")
      }
      guard parsed > 0 else {
        throw ValidationError("Invalid forward-port spec '\(spec)': host port must be > 0")
      }
      host = parsed
    }
    return try PortForward(guest: guest, host: host)
  }

  /// Config entries first, then CLI entries; a later duplicate guest port wins
  /// in place.
  public static func merge(config: [PortForward], cli: [PortForward]) -> [PortForward] {
    var out: [PortForward] = []
    for forward in config + cli {
      if let index = out.firstIndex(where: { $0.guest == forward.guest }) {
        out[index] = forward
      } else {
        out.append(forward)
      }
    }
    return out
  }
}

/// A value that never appears in `description`, `debugDescription`,
/// reflection or string interpolation. Reading it requires `expose()`.
public struct Secret<Value: Sendable & Equatable>: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  private let value: Value
  public init(_ value: Value) { self.value = value }
  public func expose() -> Value { value }
  public var description: String { "<redacted>" }
  public var debugDescription: String { "Secret(<redacted>)" }
  public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
