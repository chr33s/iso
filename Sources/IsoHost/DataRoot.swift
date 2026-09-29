import Foundation
import IsoCore

/// Guard against sharing the default data directory `~/.iso` with an
/// upstream coop installation.
public enum DataRoot {
  static let legacyUpstreamEntries = [
    "images", "instances", "vm_key", "lima-builder.yaml", "vmlinux", "firecracker",
  ]

  /// Run before any command that reads state; explicit `--config` paths are
  /// untouched.
  public static func check(home: String, usesDefaultConfiguration: Bool) throws {
    guard usesDefaultConfiguration else { return }
    try checkRoot(home + "/.iso")
  }

  /// A real directory (or absent) holding no upstream default-build state.
  static func checkRoot(_ root: String) throws {
    var status = stat()
    guard lstat(root, &status) == 0 else {
      if errno == ENOENT { return }
      throw HostError.posix("Failed to inspect", root)
    }
    guard (status.st_mode & S_IFMT) == S_IFDIR else {
      throw HostError("\(root) must be a real directory")
    }
    for name in legacyUpstreamEntries where lstat(root + "/" + name, &status) == 0 {
      throw HostError(
        "\(root) contains legacy upstream state (\(name)); refusing to share it. Select a separate data_dir and --config."
      )
    }
  }
}
