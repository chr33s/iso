import Foundation

/// The one comparison key for file names checked on the host (returned stage
/// entries, link targets, protected and sensitive paths, archive members), so
/// no caller compares with its own `lowercased()`: lowercasing misses folds a
/// case-insensitive volume makes, such as U+017F LATIN SMALL LETTER LONG S to `s`.
package enum NameFolding {
  package enum Volume: Sendable, Equatable {
    case caseInsensitive
    case caseSensitive
  }

  /// Code points HFS+ ignores in names, which Git also treats as equivalent
  /// (`is_hfs_dotgit`). APFS does not ignore them; dropping them only makes
  /// a comparison stricter.
  static let ignorable: Set<UInt32> = Set(
    [0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0xFEFF]
      + Array(0x206A...0x206F))

  /// `name` as `volume` compares it. Case-insensitive: ignorable code points
  /// removed, then canonical caseless matching (Unicode full case folding of
  /// the canonical decomposition, recomposed), which may equate more names
  /// than the volume does (`ß` and `ss`); callers only use it to refuse.
  /// Case-sensitive APFS still treats canonical equivalents as one name.
  package static func key(_ name: String, on volume: Volume = .caseInsensitive) -> String {
    switch volume {
    case .caseSensitive:
      return name.precomposedStringWithCanonicalMapping
    case .caseInsensitive:
      var scalars = String.UnicodeScalarView()
      for scalar in name.unicodeScalars where !ignorable.contains(scalar.value) {
        scalars.append(scalar)
      }
      return String(scalars).decomposedStringWithCanonicalMapping
        .folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
    }
  }
}

/// Whether `split(separator: "/")`, `hasPrefix("/")` and `hasSuffix("/")` see
/// every `/` in `path`. They compare `Character`s, and a combining mark or
/// joiner right after `/` joins it into one `Character`: they read
/// `../\u{301}x` as one component where the kernel reads `..` then `\u{301}x`.
/// Guest-authored paths that fail are refused, so `Character`-based path
/// code stays exact on the rest.
package func slashesAreWholeCharacters(_ path: String) -> Bool {
  path.allSatisfy { $0 == "/" || !$0.unicodeScalars.contains("/") }
}
