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

/// The slash-separated components of `path` as the kernel sees them: split on
/// the byte, not on `Character`, which joins `/` with a following combining
/// mark.
private func byteComponents(_ path: String) -> [String] {
  path.utf8.split(separator: UInt8(ascii: "/")).map { String(decoding: $0, as: UTF8.self) }
}

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
    for component in byteComponents(link).dropLast() { directory += "/" + component }
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    var walk = directory
    for component in byteComponents(target) {
      walk += "/" + component
      try FileManager.default.createDirectory(atPath: walk, withIntermediateDirectories: true)
    }
    guard let resolved = realpath(walk, nil) else { throw POSIXError(.ENOENT) }
    defer { free(resolved) }
    let path = String(cString: resolved)
    guard let realRoot = realpath(root, nil) else { throw POSIXError(.ENOENT) }
    defer { free(realRoot) }
    let rootPath = String(cString: realRoot)
    if Array(path.utf8) == Array(rootPath.utf8) { return .root }
    guard path.utf8.starts(with: (rootPath + "/").utf8) else { return .outside }
    return .inside(String(decoding: path.utf8.dropFirst(rootPath.utf8.count + 1), as: UTF8.self))
  }

  enum Resolution: Equatable {
    case outside, root
    case inside(String)
  }
}

@Test func returnedSymlinkContainmentAgreesWithTheFilesystem() throws {
  let oracle = try ContainmentOracle()
  defer { try? FileManager.default.removeItem(atPath: oracle.base) }
  // Combining marks and joiners right after a `/` share its `Character`.
  let names = [
    "a", "b", "x y", "...", "\u{E9}", "\u{FF0E}\u{FF0E}", ".git", "\u{301}", "\u{301}x", "\u{200D}",
  ]
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
        if target.isEmpty || target.utf8.first == UInt8(ascii: "/") {
          return inside ? "an empty or absolute target stays inside" : nil
        }
        // A `/` that shares its `Character` is refused wherever it leads.
        if target.contains(where: { $0 != "/" && $0.unicodeScalars.contains("/") }) {
          return inside ? "a target with a joined separator was accepted" : nil
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
          // Canonical equivalence: Foundation creates the oracle's
          // directories in decomposed form.
          return resolved == path ? nil : "resolved to \(resolved ?? "nil"), expected \(path)"
        }
      }))
  if let oracleError { Issue.record("containment oracle failed: \(oracleError)") }

  // Absolute targets and C0, DEL and C1 controls are refused whatever they resolve to.
  expectHolds(
    checkProperty(
      "StageBuilder.staysInside refuses", iterations: 400,
      generate: { rng -> String in
        var target = rng.path(maxComponents: 4, names + ["."])
        let control = String(rng.scalar([.c0Control, .c1Control]))
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

/// The documented set: C0/C1 controls, DEL, and the Unicode Bidi_Control
/// scalars (ALM, LRM/RLM, embeddings, overrides, isolates), listed
/// independently of the production predicate.
private func documentedDisplayControl(_ scalar: Unicode.Scalar) -> Bool {
  switch scalar.value {
  case 0..<0x20, 0x7F...0x9F, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
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

@Test func hostControlErrorSanitizeNeutralizesTheArabicLetterMark() {
  #expect(HostControlError.sanitize("a\u{061C}b", limit: 16) == "a?b")
}

// MARK: - Folded name collisions

/// The code points HFS+ and Git's `is_hfs_dotgit` ignore, listed
/// independently of `NameFolding`.
private let ignorableScalars: [Unicode.Scalar] = [
  "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}",
  "\u{202E}", "\u{206A}", "\u{206B}", "\u{206C}", "\u{206D}", "\u{206E}", "\u{206F}", "\u{FEFF}",
]

/// A spelling a case-insensitive APFS volume (or Git's HFS rules) resolves to
/// the same entry as `name`, generated without `NameFolding`: ASCII case
/// flips, `ſ`/`K`/`Å` for `s`/`k`/`å`, HFS+ ignorables, and either
/// normalization form.
private func sameEntrySpelling(_ name: String, _ rng: inout PropertyRNG) -> String {
  var out = String.UnicodeScalarView()
  for scalar in name.unicodeScalars {
    if rng.oneIn(4) { out.append(rng.element(ignorableScalars)) }
    switch scalar {
    case "s" where rng.oneIn(2), "S" where rng.oneIn(2): out.append("\u{17F}")
    case "k" where rng.oneIn(2), "K" where rng.oneIn(2): out.append("\u{212A}")
    case "\u{E5}" where rng.oneIn(2): out.append("\u{212B}")
    case _ where scalar.isASCII && scalar.properties.isAlphabetic && rng.oneIn(2):
      let text = String(scalar)
      out.append(
        contentsOf: (text == text.uppercased() ? text.lowercased() : text.uppercased())
          .unicodeScalars)
    default: out.append(scalar)
    }
  }
  let spelled = String(out)
  return rng.oneIn(2)
    ? spelled.decomposedStringWithCanonicalMapping : spelled.precomposedStringWithCanonicalMapping
}

@Test func destinationListingReportsEveryHostSpellingOfTheSameEntry() {
  let pool = ["README.md", "src", "\u{E9}t\u{E9}", "e\u{301}", "Makefile", "task\u{17F}", ".git"]
  expectHolds(
    checkProperty(
      "DestinationListing.spellingMismatch", iterations: 1000,
      generate: { rng -> ([String], String) in
        let names = (0..<rng.int(1...5)).map { _ in
          rng.oneIn(3) ? rng.string(maxScalars: 8) : rng.element(pool)
        }
        return (names, sameEntrySpelling(rng.element(names), &rng))
      },
      property: { (names: [String], query: String) -> String? in
        let listing = DestinationListing(
          names: names.map { Array($0.utf8) }, volume: .caseInsensitive)
        let exact = names.contains { Array($0.utf8) == Array(query.utf8) }
        switch (exact, listing.spellingMismatch(query)) {
        case (true, nil), (false, _?): break
        case (true, _?): return "exact name reported as a different spelling"
        case (false, nil): return "a same-entry spelling was not reported"
        }
        // A case-sensitive volume still equates canonical equivalents.
        let sensitive = DestinationListing(
          names: names.map { Array($0.utf8) }, volume: .caseSensitive)
        let nfd = names[0].decomposedStringWithCanonicalMapping
        if Array(nfd.utf8) != Array(names[0].utf8), !names.contains(nfd),
          sensitive.spellingMismatch(nfd) == nil
        {
          return "case-sensitive volume missed a normalization variant"
        }
        return nil
      }))
}

@Test func protectedAndSensitivePathsMatchEverySameEntrySpelling() {
  let checks: [(path: String, matches: (String) -> Bool)] = [
    (".git", ProtectedPaths.isReserved),
    (".git/config", ProtectedPaths.isReserved),
    (".husky/pre-commit", { SensitivePaths.classify($0) != nil }),
    (".envrc", { SensitivePaths.classify($0) != nil }),
    (".vscode/tasks.json", { SensitivePaths.classify($0) != nil }),
    (".ssh/id_ed25519", { LocalSecretNames.match($0) != nil }),
    (".aws/credentials", { LocalSecretNames.match($0) != nil }),
    (".docker/config.json", { LocalSecretNames.match($0) != nil }),
    (".kube/config", { LocalSecretNames.match($0) != nil }),
    (".env", { LocalSecretNames.match($0) != nil }),
    (".env.local", { LocalSecretNames.match($0) != nil }),
    (".git-credentials", { LocalSecretNames.match($0) != nil }),
  ]
  expectHolds(
    checkProperty(
      "protected and sensitive path spellings", iterations: 1000,
      generate: { rng -> (Int, String) in
        let index = rng.below(checks.count)
        let parent = rng.path(maxComponents: 2, ["a", "pkg", "\u{E9}"])
        let spelled = checks[index].path.split(separator: "/")
          .map { sameEntrySpelling(String($0), &rng) }.joined(separator: "/")
        return (index, parent.isEmpty ? spelled : parent + "/" + spelled)
      },
      property: { (index: Int, path: String) -> String? in
        // Only paths the stage accepts reach these checks; a joiner right
        // after `/` makes the path invalid instead.
        guard StageManifestValidator.validPath(path) else { return nil }
        return checks[index].matches(path)
          ? nil : "\(checks[index].path) spelled \(printable(path)) missed"
      }))
}

@Test func archiveKeysRefuseExactlyTheComponentsThatVanishOrJoinTheirSeparator() {
  expectHolds(
    checkProperty(
      "ArchiveValidator.key", iterations: 1000,
      generate: { rng -> [String] in
        (0..<rng.int(1...4)).map { _ in
          switch rng.below(3) {
          case 0:
            String(
              String.UnicodeScalarView(
                (0..<rng.int(1...3)).map { _ in rng.element(ignorableScalars) }))
          case 1: sameEntrySpelling(rng.element(["a", "Src", "\u{E9}", ".git"]), &rng)
          default: rng.string(maxScalars: 6, [.asciiWord, .nonASCII, .combining, .format])
          }
        }.filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.unicodeScalars.contains("/") }
      },
      property: { (components: [String]) -> String? in
        guard !components.isEmpty else { return nil }
        let path = components.joined(separator: "/")
        // Refused: a component that folds to nothing, or one that (raw or
        // folded) starts with a scalar `Character` joins to the `/` before it.
        let refusal = components.indices.contains { index in
          let folded = NameFolding.key(components[index])
          return folded.isEmpty
            || (index > 0 && [components[index], folded].contains { ("/" + $0).first != "/" })
        }
        let result = Result { () throws(HostControlError) in
          try ArchiveValidator.key(ArchiveValidator.normalize(path, limits: .standard))
        }
        switch result {
        case .success(let key):
          if refusal { return "a vanishing or separator-joining component was accepted" }
          return Array(key.utf8) == Array(NameFolding.key(path).utf8)
            ? nil : "key differs from the folded path"
        case .failure(let error):
          return refusal ? nil : "refused \(error)"
        }
      }))
}
