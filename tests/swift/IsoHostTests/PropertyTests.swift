// Property tests for host checks on guest-authored names and text; the
// generator and reproduction knobs are in IsoPropertyTesting.

import Foundation
import IsoCore
import IsoPropertyTesting
import Testing

@testable import IsoHost
@testable import IsoHostControl

private func expectHolds(
  _ failure: PropertyFailure?, sourceLocation: SourceLocation = #_sourceLocation
) {
  if let failure {
    Issue.record(Comment(rawValue: failure.description), sourceLocation: sourceLocation)
  }
}

// MARK: - Returned symlink containment

/// The filesystem as the oracle for lexical containment: every directory the
/// link and target walk through is created (no symlinks), so `realpath`
/// resolves `..` exactly as a returned tree would. The workspace root sits
/// eight levels deep so a target can climb out without leaving the fixture.
private struct ContainmentOracle {
  let base: String
  let root: String

  init() throws {
    base =
      FileManager.default.temporaryDirectory
      .appendingPathComponent("iso-containment-\(UUID().uuidString)").path
    root = base + "/p1/p2/p3/p4/p5/p6/p7/p8/root"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  /// The target's resolution relative to `root`: `.outside`, `.root`, or a path.
  func resolve(link: String, target: String) throws -> Resolution {
    var directory = root
    for component in link.split(separator: "/").dropLast() { directory += "/" + component }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    var walk = directory
    for component in target.split(separator: "/") {
      walk += "/" + component
      try FileManager.default.createDirectory(atPath: walk, withIntermediateDirectories: true)
    }
    guard let resolved = realpath(walk, nil) else { throw POSIXError(.ENOENT) }
    defer { free(resolved) }
    let path = String(cString: resolved)
    guard let realRoot = realpath(root, nil) else { throw POSIXError(.ENOENT) }
    defer { free(realRoot) }
    let rootPath = String(cString: realRoot)
    if path == rootPath { return .root }
    guard path.hasPrefix(rootPath + "/") else { return .outside }
    return .inside(String(path.dropFirst(rootPath.count + 1)))
  }

  enum Resolution: Equatable {
    case outside, root
    case inside(String)
  }
}

@Test func returnedSymlinkContainmentAgreesWithTheFilesystem() throws {
  let oracle = try ContainmentOracle()
  defer { try? FileManager.default.removeItem(atPath: oracle.base) }
  let names = ["a", "b", "x y", "...", "\u{E9}", "\u{FF0E}\u{FF0E}", ".git"]
  let steps = names + ["..", "..", ".", ""]
  var oracleError: (any Error)?
  expectHolds(
    checkProperty(
      "StageBuilder.staysInside/resolve", iterations: 400,
      generate: { rng -> (String, String) in
        let link = (0..<rng.int(1...4)).map { _ in rng.element(["a", "b", "c"]) }
          .joined(separator: "/")
        return (link, rng.path(maxComponents: 7, steps))
      },
      property: { (link: String, target: String) -> String? in
        let inside = StageBuilder.staysInside(link: link, target: target)
        let resolved = StageBuilder.resolve(link: link, target: target)
        if target.isEmpty || target.hasPrefix("/") {
          return inside ? "an empty or absolute target stays inside" : nil
        }
        let expected: ContainmentOracle.Resolution
        do { expected = try oracle.resolve(link: link, target: target) } catch {
          oracleError = error
          return nil
        }
        switch expected {
        case .outside: return inside ? "escaping target accepted" : nil
        case .root:
          guard inside else { return "target resolving to the root rejected" }
          return resolved == nil ? nil : "root resolved to \(resolved ?? "")"
        case .inside(let path):
          guard inside else { return "contained target rejected" }
          return resolved == path ? nil : "resolved to \(resolved ?? "nil"), expected \(path)"
        }
      }))
  if let oracleError { Issue.record("containment oracle failed: \(oracleError)") }

  // Absolute targets and control bytes are refused whatever they resolve to.
  expectHolds(
    checkProperty(
      "StageBuilder.staysInside refuses", iterations: 400,
      generate: { rng -> String in
        var target = rng.path(maxComponents: 4, names + ["."])
        let control = String(rng.scalar([.c0Control]))
        switch rng.below(3) {
        case 0: target = "/" + target
        case 1: target += rng.element([control, "\u{7F}"])
        default: target = rng.element([control, "\u{7F}"]) + "/" + target
        }
        return target
      },
      property: { target in
        StageBuilder.staysInside(link: "a/l", target: target) ? "accepted" : nil
      }))
}

// MARK: - Instance names from host directory names

@Test func sanitizedBasenameAlwaysYieldsAValidUniqueInstanceName() {
  let allowed = Set(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".unicodeScalars)
  expectHolds(
    checkProperty(
      "Instance.sanitizedBasename", iterations: 2000,
      generate: { rng in rng.string(maxScalars: rng.oneIn(4) ? 90 : 12) },
      property: { name in
        let base = Instance.sanitizedBasename(name)
        guard base.unicodeScalars.allSatisfy(allowed.contains) else { return "unsafe character" }
        guard Instance.sanitizedBasename(base) == base else { return "not idempotent" }
        // `uniqueName` appends at most "-99" before `InstanceName` validates.
        for candidate in [base, base + "-99"] {
          guard (try? InstanceName(candidate)) != nil else { return "invalid name \(candidate)" }
        }
        return nil
      }))
}

// MARK: - Host-control error text

/// The documented set: C0/C1 controls, DEL, and bidirectional marks,
/// overrides and isolates.
private func documentedDisplayControl(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 0..<0x20, 0x7F...0x9F, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
  default: false
  }
}

@Test func hostControlErrorSanitizeIsTheLongestNeutralizedPrefixWithinTheLimit() {
  expectHolds(
    checkProperty(
      "HostControlError.sanitize", iterations: 2000,
      generate: { rng in (rng.string(maxScalars: 40), rng.int(0...48)) },
      property: { (text: String, limit: Int) -> String? in
        let mapped = text.unicodeScalars.map { documentedDisplayControl($0) ? "?" : $0 }
        let output = Array(HostControlError.sanitize(text, limit: limit).unicodeScalars)
        guard output.count <= mapped.count, Array(mapped.prefix(output.count)) == output else {
          return "not a neutralized prefix of the input"
        }
        let bytes = output.reduce(0) { $0 + String($1).utf8.count }
        guard bytes <= limit else { return "\(bytes) bytes exceeds limit \(limit)" }
        if output.count < mapped.count, bytes + String(mapped[output.count]).utf8.count <= limit {
          return "stopped early at \(bytes) of \(limit) bytes"
        }
        return nil
      }))
}
