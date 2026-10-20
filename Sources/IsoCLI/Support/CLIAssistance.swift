import ArgumentParser
import Foundation
import IsoHost

/// `--exclude-git`, kept so old scripts still parse: no transfer carries
/// `.git` any more, so it only warns, in every mode.
enum DeprecatedExcludeGit {
  static let help = "Deprecated, no effect: transfers never carry `.git`"

  static func warn(_ set: Bool, _ diagnostics: Diagnostics) {
    if set {
      diagnostics.warn("--exclude-git is deprecated and has no effect: transfers never carry .git")
    }
  }
}

/// Deterministic help for ordinary mistakes: a mistyped subcommand gets a
/// nearest-name suggestion, and conflicting flags are named exactly as given.
/// Nothing here guesses intent beyond spelling distance.
enum CommandSuggestion {
  /// "Did you mean 'pull'?" for an unknown subcommand token, when one
  /// sibling name is clearly closest (edit distance at most 2, or a unique
  /// prefix). Nil otherwise.
  static func hint(for error: any Error, arguments: [String]) -> String? {
    // "Unexpected argument 'x'" or "3 unexpected arguments: 'x', …": the
    // first quoted token is the one that failed to name a subcommand.
    let message = IsoCommand.message(for: error)
    guard
      message.hasPrefix("Unexpected argument '") || message.contains(" unexpected arguments: '"),
      let open = message.firstIndex(of: "'")
    else { return nil }
    let unknown = String(message[message.index(after: open)...].prefix { $0 != "'" })
    var command: any ParsableCommand.Type = IsoCommand.self
    for token in arguments.dropFirst() where !token.hasPrefix("-") {
      if token == unknown { break }
      guard let next = subcommands(of: command).first(where: { names(of: $0).contains(token) })
      else { break }
      command = next
    }
    let candidates = subcommands(of: command).flatMap(names(of:))
    guard !candidates.isEmpty, let best = nearest(unknown, in: candidates) else { return nil }
    return "Did you mean '\(best)'?"
  }

  static func subcommands(of command: any ParsableCommand.Type) -> [any ParsableCommand.Type] {
    command.configuration.subcommands
  }

  static func names(of command: any ParsableCommand.Type) -> [String] {
    [command._commandName] + command.configuration.aliases
  }

  static func nearest(_ word: String, in candidates: [String]) -> String? {
    let prefixed = candidates.filter { $0.hasPrefix(word) }
    if word.count >= 2, prefixed.count == 1 { return prefixed[0] }
    let scored = candidates.map { ($0, distance(word, $0)) }.sorted { $0.1 < $1.1 }
    guard let first = scored.first, first.1 <= 2, first.1 < word.count else { return nil }
    // Ambiguous between equally close names: suggest nothing.
    if scored.count > 1 && scored[1].1 == first.1 { return nil }
    return first.0
  }

  /// Optimal string alignment distance (adjacent transpositions count once).
  static func distance(_ a: String, _ b: String) -> Int {
    let a = Array(a)
    let b = Array(b)
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { table[i][0] = i }
    for j in 0...b.count { table[0][j] = j }
    for i in 1...a.count {
      for j in 1...b.count {
        let cost = a[i - 1] == b[j - 1] ? 0 : 1
        table[i][j] = min(table[i - 1][j] + 1, table[i][j - 1] + 1, table[i - 1][j - 1] + cost)
        if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
          table[i][j] = min(table[i][j], table[i - 2][j - 2] + 1)
        }
      }
    }
    return table[a.count][b.count]
  }

  /// A usage error naming exactly the mutually exclusive flags that were
  /// given, nil when at most one was.
  static func exclusive(_ flags: KeyValuePairs<String, Bool>, why: String) -> UsageError? {
    let given = flags.filter(\.value).map(\.key)
    guard given.count > 1 else { return nil }
    let list =
      given.count == 2
      ? "\(given[0]) and \(given[1])"
      : given.dropLast().joined(separator: ", ") + " and " + given.last!
    return UsageError("\(list) cannot be combined: \(why)")
  }
}
