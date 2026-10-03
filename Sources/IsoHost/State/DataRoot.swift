// Derived from trailofbits/coop.
// Modified by chr33s: ported/adapted for the Swift implementation.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import IsoCore

/// Require the default data directory to be a real directory when present.
package enum DataRoot {
  /// Run before any command that reads state; explicit `--config` paths are
  /// untouched.
  package static func check(home: String, usesDefaultConfiguration: Bool) throws {
    guard usesDefaultConfiguration else { return }
    try checkRoot(home + "/.iso")
  }

  /// A real directory, or absent.
  static func checkRoot(_ root: String) throws {
    var status = stat()
    guard lstat(root, &status) == 0 else {
      if errno == ENOENT { return }
      throw HostError.posix("Failed to inspect", root)
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
      throw HostError("\(root) must be a real directory")
    }
  }
}
