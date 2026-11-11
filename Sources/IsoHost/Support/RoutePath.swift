import IsoCore

/// Paths that reach ssh's `ProxyCommand` (shell-run, `%`-expanded) or rsync's
/// `-e` must be plain: `[A-Za-z0-9/._-]` only.
package enum RoutePath {
  package static func requireSafe(_ path: String) throws {
    guard !path.isEmpty, path.unicodeScalars.allSatisfy({ $0 == "/" || isSafeNameCharacter($0) })
    else {
      throw HostError(
        "\(path) has characters the remote guest route cannot carry; use a data_dir and iso path of [A-Za-z0-9/._-]"
      )
    }
  }
}
