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
