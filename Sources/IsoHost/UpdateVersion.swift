// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What this binary is, for `iso update` and the background check. A
/// release build is produced only by the release entrypoint (S-05), which
/// compiles with `-D ISO_RELEASE_BUILD`; every other build is a dev build,
/// which `iso update` refuses to replace and the background check skips.
public struct IsoBuild: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case dev
    case release
  }

  /// Package version without the dev suffix (Rust `CARGO_PKG_VERSION`).
  public let version: String
  public let kind: Kind
  /// `--version` text without the leading `iso ` (Rust `ISO_VERSION_STR`).
  public let versionString: String

  public init(version: String, kind: Kind, versionString: String) {
    self.version = version
    self.kind = kind
    self.versionString = versionString
  }

  public static let packageVersion = "0.6.0"

  /// `0.6.0 (abc1234)` for a release, `0.6.0-dev (abc1234+dirty)` for a
  /// development build (Rust `ISO_VERSION_STR`).
  #if ISO_RELEASE_BUILD
    public static let current = IsoBuild(
      version: packageVersion, kind: .release,
      versionString: packageVersion + " (\(buildRevision ?? "unknown"))")
  #else
    public static let current = IsoBuild(
      version: packageVersion, kind: .dev,
      versionString: packageVersion + "-dev (\(buildRevision ?? "swift host"))")
  #endif
}

/// A semantic version with the Rust `semver` crate's parsing and ordering:
/// strict `MAJOR.MINOR.PATCH`, no leading zeros in numeric fields or numeric
/// pre-release identifiers, optional `-pre` and `+build`, and build metadata
/// taking part in ordering after the pre-release.
public struct SemanticVersion: Sendable, Equatable, Comparable, CustomStringConvertible {
  public let major: UInt64
  public let minor: UInt64
  public let patch: UInt64
  public let prerelease: String
  public let build: String

  public struct ParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
  }

  enum Position: String {
    case major = "major version number"
    case minor = "minor version number"
    case patch = "patch version number"
    case pre = "pre-release identifier"
    case build = "build metadata"
  }

  public init(parsing text: String) throws(ParseError) {
    guard !text.isEmpty else {
      throw ParseError(description: "empty string, expected a semver version")
    }
    var rest = Substring(text)
    major = try Self.numeric(&rest, .major)
    try Self.dot(&rest, .major)
    minor = try Self.numeric(&rest, .minor)
    try Self.dot(&rest, .minor)
    patch = try Self.numeric(&rest, .patch)
    var position = Position.patch
    if rest.first == "-" {
      rest = rest.dropFirst()
      position = .pre
      prerelease = try Self.identifier(&rest, .pre)
      if prerelease.isEmpty {
        throw Self.error("empty identifier segment in \(Position.pre.rawValue)")
      }
    } else {
      prerelease = ""
    }
    if rest.first == "+" {
      rest = rest.dropFirst()
      position = .build
      build = try Self.identifier(&rest, .build)
      if build.isEmpty {
        throw Self.error("empty identifier segment in \(Position.build.rawValue)")
      }
    } else {
      build = ""
    }
    if let unexpected = rest.first {
      throw Self.error("unexpected character \(Self.quoted(unexpected)) after \(position.rawValue)")
    }
  }

  public var description: String {
    var text = "\(major).\(minor).\(patch)"
    if !prerelease.isEmpty { text += "-" + prerelease }
    if !build.isEmpty { text += "+" + build }
    return text
  }

  public static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
    compare(a, b) == .orderedAscending
  }

  static func compare(_ a: SemanticVersion, _ b: SemanticVersion) -> ComparisonResult {
    for (x, y) in [(a.major, b.major), (a.minor, b.minor), (a.patch, b.patch)] where x != y {
      return x < y ? .orderedAscending : .orderedDescending
    }
    let pre = comparePrerelease(a.prerelease, b.prerelease)
    if pre != .orderedSame { return pre }
    return compareBuild(a.build, b.build)
  }

  static func comparePrerelease(_ a: String, _ b: String) -> ComparisonResult {
    if a == b { return .orderedSame }
    // A release sorts above any of its pre-releases.
    if a.isEmpty { return .orderedDescending }
    if b.isEmpty { return .orderedAscending }
    return compareIdentifiers(a, b) { x, y in
      // Numeric identifiers compare numerically (no leading zeros here).
      x.count != y.count
        ? (x.count < y.count ? .orderedAscending : .orderedDescending) : bytes(x, y)
    }
  }

  static func compareBuild(_ a: String, _ b: String) -> ComparisonResult {
    if a == b { return .orderedSame }
    return compareIdentifiers(a, b) { x, y in
      // 0 < 00 < 1 < 01 < 001 < 2 ...
      let xv = x.drop { $0 == "0" }
      let yv = y.drop { $0 == "0" }
      if xv.count != yv.count {
        return xv.count < yv.count ? .orderedAscending : .orderedDescending
      }
      let value = bytes(Substring(xv), Substring(yv))
      if value != .orderedSame { return value }
      return x.count == y.count
        ? .orderedSame : (x.count < y.count ? .orderedAscending : .orderedDescending)
    }
  }

  private static func compareIdentifiers(
    _ a: String, _ b: String, numeric: (Substring, Substring) -> ComparisonResult
  ) -> ComparisonResult {
    let left = a.split(separator: ".", omittingEmptySubsequences: false)
    let right = b.split(separator: ".", omittingEmptySubsequences: false)
    for (index, x) in left.enumerated() {
      guard index < right.count else { return .orderedDescending }
      let y = right[index]
      let xDigits = x.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
      let yDigits = y.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
      let result: ComparisonResult
      switch (xDigits, yDigits) {
      case (true, true): result = numeric(x, y)
      case (true, false): return .orderedAscending
      case (false, true): return .orderedDescending
      case (false, false): result = bytes(x, y)
      }
      if result != .orderedSame { return result }
    }
    return left.count == right.count ? .orderedSame : .orderedAscending
  }

  private static func bytes(_ a: Substring, _ b: Substring) -> ComparisonResult {
    if a == b { return .orderedSame }
    return a.utf8.lexicographicallyPrecedes(b.utf8) ? .orderedAscending : .orderedDescending
  }

  private static func numeric(_ rest: inout Substring, _ position: Position) throws(ParseError)
    -> UInt64
  {
    var value: UInt64 = 0
    var length = 0
    while let byte = rest.utf8.first, byte >= 0x30, byte <= 0x39 {
      if value == 0 && length > 0 { throw error("invalid leading zero in \(position.rawValue)") }
      let (product, overflowA) = value.multipliedReportingOverflow(by: 10)
      let (sum, overflowB) = product.addingReportingOverflow(UInt64(byte - 0x30))
      if overflowA || overflowB { throw error("value of \(position.rawValue) exceeds u64::MAX") }
      value = sum
      length += 1
      rest = rest.dropFirst()
    }
    guard length > 0 else {
      if let unexpected = rest.first {
        throw error("unexpected character \(quoted(unexpected)) while parsing \(position.rawValue)")
      }
      throw error("unexpected end of input while parsing \(position.rawValue)")
    }
    return value
  }

  private static func dot(_ rest: inout Substring, _ position: Position) throws(ParseError) {
    if rest.first == "." {
      rest = rest.dropFirst()
      return
    }
    if let unexpected = rest.first {
      throw error("unexpected character \(quoted(unexpected)) after \(position.rawValue)")
    }
    throw error("unexpected end of input while parsing \(position.rawValue)")
  }

  /// Dot-separated `[0-9A-Za-z-]+` segments; stops at the first other byte.
  private static func identifier(_ rest: inout Substring, _ position: Position) throws(ParseError)
    -> String
  {
    let bytes = Array(rest.utf8)
    var accumulated = 0
    var segment = 0
    var hasNonDigit = false
    while true {
      let byte: UInt8? = accumulated + segment < bytes.count ? bytes[accumulated + segment] : nil
      switch byte {
      case .some(let b) where (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D:
        segment += 1
        hasNonDigit = true
      case .some(let b) where b >= 0x30 && b <= 0x39:
        segment += 1
      default:
        if segment == 0 {
          if accumulated == 0 && byte != 0x2E { return "" }
          throw error("empty identifier segment in \(position.rawValue)")
        }
        if position == .pre && segment > 1 && !hasNonDigit && bytes[accumulated] == 0x30 {
          throw error("invalid leading zero in \(position.rawValue)")
        }
        accumulated += segment
        if byte == 0x2E {
          accumulated += 1
          segment = 0
          hasNonDigit = false
        } else {
          let text = String(decoding: bytes[0..<accumulated], as: UTF8.self)
          rest = Substring(String(decoding: bytes[accumulated...], as: UTF8.self))
          return text
        }
      }
    }
  }

  private static func error(_ text: String) -> ParseError { ParseError(description: text) }

  /// Rust `QuotedChar`: `'x'` with `escape_debug`.
  private static func quoted(_ character: Character) -> String {
    let inner = String(character).unicodeScalars.map { scalar -> String in
      scalar == "'" ? "\\'" : scalar == "\"" ? "\"" : scalar.escaped(asASCII: false)
    }.joined()
    return "'" + inner + "'"
  }
}
